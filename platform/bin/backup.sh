#!/usr/bin/env bash

# Бэкап баз девбокса: дамп → GPG → S3.
#
# Дизайн и обоснование решений — docs/architecture/backup-design.md.
# Коротко о том, что здесь важно и неочевидно:
#
#   * Источники обрабатываются ПО ОДНОМУ, файл покидает диск (или переезжает в
#     каталог поколений) до начала следующего. Пиковое потребление — один самый
#     крупный дамп, а не сумма всех: /mnt/data лежит на том же разделе, что и
#     данные postgres.
#   * Файл существует под финальным именем, только если весь конвейер прошёл
#     (.part → mv). Битый дамп не выглядит как бэкап ни для выгрузки, ни для
#     ротации, ни для check-backups.sh.
#   * Список баз спрашивается у postgres, а не берётся из конфига. Иначе
#     следующая заведённая база молча останется без бэкапа.
#   * Пароль postgres разворачивается ВНУТРИ контейнера и не появляется ни в
#     конфиге бэкапа, ни в `ps`.
#   * Провал одного источника не отменяет остальные, но делает весь прогон
#     проваленным: код возврата ненулевой, юнит уходит в failed.
#
#   sudo ./platform/bin/backup.sh            # полный прогон
#   sudo ./platform/bin/backup.sh --dry-run  # показать план, ничего не делая

set -euo pipefail

DIR0="$( cd -P "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# Каталог МАШИНЫ, а не платформы. Обычно его задаёт обёртка в корне машины;
# запасной вариант — на два уровня вверх от platform/bin.
ROOT_DIR="${ROOT_DIR:-$( cd "$DIR0/../.." && pwd )}"
LIB_DIR="$( cd "$DIR0/../lib" && pwd )"

# shellcheck source=scripts/lib-env.sh
. "$LIB_DIR/lib-env.sh"
# lib-stacks нужен с самого начала: поставщика БД спрашиваем ещё при разборе
# конфига. Раньше на его месте стояла константа с именем контейнера postgres,
# и библиотека подключалась сильно позже, по месту первой надобности.
# shellcheck source=../lib/lib-stacks.sh
. "$LIB_DIR/lib-stacks.sh"

# Состояние скрипта — в /var/lib, по тому же принципу:
# не в репозитории (его переносят и пересоздают) и не в /tmp (чистится).
STATE_DIR=/var/lib/devbox-backup
GNUPGHOME_DIR="$STATE_DIR/gnupg"
LOCK_FILE="$STATE_DIR/backup.lock"
SIZES_FILE="$STATE_DIR/last-sizes"

DRY_RUN=0

usage() {
  cat <<'EOF'
Использование: sudo ./platform/bin/backup.sh [--dry-run]

  --dry-run   показать, что было бы сделано, и выйти. Проверки окружения
              выполняются полностью, дампы не снимаются и в S3 ничего не уходит.
  --help      эта справка

Настройка — .env-backup (образец: .env-backup.example).
Проверка результата — ./platform/bin/check-backups.sh
Восстановление — ./platform/bin/backup-restore.sh
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Неизвестный аргумент: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# ------------------------------------------------------------------ вывод

log()  { echo "$*"; }
warn() { echo "  [!]    $*" >&2; }
die()  { echo "Ошибка: $*" >&2; exit 2; }

FAILED=()
fail_source() { FAILED+=("$1"); echo "  [FAIL] $1: $2" >&2; }

# --------------------------------------------------------------- конфигурация

ENV_BACKUP="$ROOT_DIR/.env-backup"
[ -f "$ENV_BACKUP" ] || die "нет $ENV_BACKUP — cp .env-backup.example .env-backup && chmod 600 .env-backup"

# .env стеков здесь НЕ грузится: источники стеков читает stack_backup_sources,
# каждый со своим набором переменных. Смешивать их в одном ENV_VARS нельзя —
# значения одного стека протекали бы в подстановки другого.
env_load_files "$ROOT_DIR/.env" "$ENV_BACKUP"

S3_BUCKET=$(env_require Backup_S3_Bucket "имя бакета без s3:// и без слэшей") || exit 2
S3_PREFIX=$(backup_s3_prefix)
AWS_REGION=$(env_get Backup_AWS_Region us-east-1)
AWS_KEY=$(env_get Backup_AWS_Access_Key_Id)
AWS_SECRET=$(env_get Backup_AWS_Secret_Access_Key)

GPG_RECIPIENT=$(env_require Backup_GPG_Recipient "отпечаток или email получателя") || exit 2
GPG_PUBKEY=$(env_get Backup_GPG_Pubkey "gpg/backup-pubkey.asc")
case "$GPG_PUBKEY" in /*) ;; *) GPG_PUBKEY="$ROOT_DIR/$GPG_PUBKEY" ;; esac

LOCAL_DIR=$(env_get Backup_Local_Dir /mnt/data/backups)
LOCAL_KEEP=$(env_get Backup_Local_Keep 1)
MIN_FREE_MB=$(env_get Backup_Min_Free_MB 1024)
MIN_OBJ_BYTES=$(env_get Backup_Min_Object_Bytes 1024)

# Числовые настройки проверяем сразу. Нечисловое значение иначе взорвётся
# посреди прогона, в арифметике `[ "$x" -gt 0 ]`, — то есть уже после того, как
# часть дампов снята, и с сообщением, по которому не догадаться о причине.
for pair in "Backup_Local_Keep:LOCAL_KEEP" "Backup_Min_Free_MB:MIN_FREE_MB" "Backup_Min_Object_Bytes:MIN_OBJ_BYTES"; do
  key="${pair%%:*}"; var="${pair##*:}"
  case "${!var}" in
    ''|*[!0-9]*) die "$key должно быть целым числом, а не '${!var}'" ;;
  esac
done

DB_PROVIDER="$(stacks_db_provider)"
# Префикс в S3 для дампов общей СУБД. По умолчанию — имя стека-поставщика.
#
# Переопределяется потому, что смена префикса на РАБОТАЮЩЕЙ машине означает:
# новые дампы уезжают в другое место, а check-backups.sh смотрит туда же и
# докладывает «бэкапов нет» при исправном бэкапе. Машине, которая уже пишет в
# postgres/, достаточно оставить Backup_DB_Prefix=postgres.
DB_PREFIX=$(backup_db_prefix)

# Временный каталог — рядом с каталогом поколений, НА ТОМ ЖЕ разделе. Иначе
# завершающий `mv` из /tmp был бы копированием, и пик по диску удвоился бы
# ровно в тот момент, когда мы его старательно ограничиваем.
TMP_DIR="$LOCAL_DIR/.tmp"

TS=$(date -u +%Y%m%dT%H%M%SZ)

# ------------------------------------------------------------------ утилиты

free_mb() { df -Pk "$1" | awk 'NR == 2 { print int($4 / 1024) }'; }
file_size() { stat -c %s "$1" 2>/dev/null || stat -f %z "$1"; }

aws_cli() {
  if [ -n "$AWS_KEY" ]; then
    AWS_ACCESS_KEY_ID="$AWS_KEY" AWS_SECRET_ACCESS_KEY="$AWS_SECRET" \
      aws --region "$AWS_REGION" "$@"
  else
    # Ключей нет — значит работаем от IAM instance role. Это предпочтительный
    # путь: на машине не лежит ни одного долгоживущего ключа.
    aws --region "$AWS_REGION" "$@"
  fi
}

# --compress-algo none: pg_dump уже сжал (-Z 9), SQLite прошёл через gzip.
# Второй проход сжатия на машине с 200 МБ свободной памяти — чистая трата.
#
# --trust-model always: ключ импортирован из репозитория и ownertrust ему никто
# не выставлял; без этого gpg в неинтерактивном режиме откажется шифровать.
#
# Но самой опции может не быть. gnupg2-minimal на AL2023 собирается без моделей
# доверия (--disable-trust-models): в такой сборке gpg вообще не знает слова
# --trust-model, отвечает `invalid option "--trust-model"` и выходит с кодом 2
# ещё до того, как посмотрит на остальные аргументы. Опция там и не нужна —
# модель доверия в этой сборке жёстко равна always, то есть ровно та, которую мы
# просим. Пакет подменяется очередным `dnf upgrade` без нашего участия, поэтому
# спрашиваем сам бинарник, а не гадаем по имени пакета и не разбираем stderr.
GPG_TRUST_OPT=""
gpg_detect_trust_opt() {
  if gpg --homedir "$GNUPGHOME_DIR" --batch --no-tty \
         --trust-model always --version >/dev/null 2>&1; then
    GPG_TRUST_OPT="--trust-model always"
  fi
}

gpg_encrypt() {
  # $GPG_TRUST_OPT обязан разбиться на два слова, поэтому без кавычек.
  # shellcheck disable=SC2086
  gpg --homedir "$GNUPGHOME_DIR" --batch --yes --quiet --no-tty \
      $GPG_TRUST_OPT --compress-algo none \
      --encrypt --recipient "$GPG_RECIPIENT" --output -
}

# ------------------------------------------------- дампы общей СУБД
#
# Платформа не знает, какая на машине СУБД, и знать не должна: pg_dump и
# mysqldump — это знание поставщика, ровно как список прав MySQL живёт в его же
# check-decl.sh. Иначе backup.sh пришлось бы форкать на каждую машину с другой
# базой — то есть возвращать ту самую копию платформы, от которой уходили.
#
# Контракт хука <поставщик>/scripts/backup-dump.sh:
#   check     — СУБД отвечает? ненулевой код и причина в stderr
#   list      — имена баз, по одной на строку, системные исключены
#   dump <db> — дамп одной базы в stdout, уже сжатый
#   globals   — объекты уровня кластера (роли, гранты) в stdout; пусто, если
#               у движка их нет
#   ext       — расширение файла дампа (.dump для pg -Fc, .sql.gz для mysql)
#
# Хук получает ROOT_DIR и STACK_DIR; работает от имени того же пользователя.
db_hook() {
  local provider; provider="$(stacks_db_provider)"
  [ -n "$provider" ] || return 1
  local h; h="$(stack_dir "$provider")/scripts/backup-dump.sh"
  [ -x "$h" ] || return 1
  ROOT_DIR="$ROOT_DIR" STACK_DIR="$(stack_dir "$provider")" "$h" "$@"
}

dump_db()      { db_hook dump "$1"; }
dump_globals() { db_hook globals; }

# `.backup`, а не `cp`: копия живой базы под писателем — это повреждённая копия.
# Промежуточный несжатый файл неизбежен (sqlite3 не умеет отдавать бэкап в
# stdout) и учтён в preflight.
dump_sqlite() {
  local src="$1" tmp="$TMP_DIR/sqlite-$$.db" rc=0
  sqlite3 "$src" ".backup '$tmp'" || { rm -f "$tmp"; return 1; }
  gzip -9 -c "$tmp" || rc=$?
  rm -f "$tmp"
  return "$rc"
}

# Каталог или файл на хосте. Через `-C`, а не с абсолютным путём: tar с
# абсолютным путём предупреждает и срезает ведущий слэш, а восстанавливать
# такое потом приходится вслепую.
dump_files() {
  local path="$1"
  [ -e "$path" ] || return 1
  tar -czf - -C "$(dirname "$path")" "$(basename "$path")"
}

# Named volume читается через одноразовый контейнер: содержимое тома живёт
# внутри /var/lib/docker и с хоста напрямую не читается, а лазить туда руками
# значит менять права под работающим контейнером.
dump_volume() {
  local vol="$1"
  docker volume inspect "$vol" >/dev/null 2>&1 || return 1
  docker run --rm -v "$vol":/v:ro alpine tar -czf - -C /v .
}

# Оставить в каталоге не больше N новейших файлов.
rotate_dir() {
  local dir="$1" keep="$2" n=0 f
  [ -d "$dir" ] || return 0
  while IFS= read -r f; do
    n=$((n + 1))
    [ "$n" -le "$keep" ] && continue
    rm -f "$dir/$f"
    log "    ротация: удалено поколение $f"
  done < <(ls -1t "$dir" 2>/dev/null)
}

# ------------------------------------------------- один источник целиком

# run_job <метка> <подпуть в S3> <имя файла> <команда, пишущая дамп в stdout...>
run_job() {
  local label="$1" sub="$2" fname="$3"; shift 3
  local key="$S3_PREFIX/$sub/$fname"
  # Имя временного файла включает источник, а не только метку времени.
  # Иначе все базы делят одно имя ($TS.dump.gpg): при упавшей выгрузке файл
  # базы А намеренно остаётся на диске как единственная копия — и дамп базы Б
  # перезаписал бы его, а сообщение «файл оставлен в …» стало бы неправдой.
  local stem="${sub//\//_}"
  local part="$TMP_DIR/$stem-$fname.part" final="$TMP_DIR/$stem-$fname"
  local bytes remote

  if [ "$DRY_RUN" -eq 1 ]; then
    log "  [dry-run] $label → s3://$S3_BUCKET/$key"
    return 0
  fi

  # pipefail обязателен: без него падение дампа маскируется успешным gpg,
  # и в S3 уезжает аккуратно зашифрованная пустота.
  if ! { "$@" | gpg_encrypt > "$part"; }; then
    rm -f "$part"
    fail_source "$label" "дамп или шифрование не прошли"
    return 1
  fi

  bytes=$(file_size "$part")
  if [ "$bytes" -lt "$MIN_OBJ_BYTES" ]; then
    rm -f "$part"
    fail_source "$label" "дамп подозрительно мал ($bytes б < $MIN_OBJ_BYTES б)"
    return 1
  fi

  mv "$part" "$final"

  if ! aws_cli s3 cp "$final" "s3://$S3_BUCKET/$key" --only-show-errors; then
    # Файл НЕ удаляем: выгрузка не прошла, локальная копия — всё, что есть.
    fail_source "$label" "выгрузка в S3 не прошла, файл оставлен в $final"
    return 1
  fi

  remote=$(aws_cli s3api head-object --bucket "$S3_BUCKET" --key "$key" \
             --query ContentLength --output text 2>/dev/null || echo "")
  if [ "$remote" != "$bytes" ]; then
    fail_source "$label" "размер в S3 ($remote) не совпал с локальным ($bytes)"
    return 1
  fi

  echo "$label $bytes" >> "$SIZES_FILE.new"
  log "  [ok]   $label — $((bytes / 1024)) КиБ → s3://$S3_BUCKET/$key"

  # Локальная копия — удобство, а не часть контракта. Не помещается — молча
  # пропускаем: бэкап уже в S3, а доведение диска до нуля превратило бы
  # страховку во вторую аварию.
  if [ "$LOCAL_KEEP" -gt 0 ] && [ "$(free_mb "$LOCAL_DIR")" -gt "$MIN_FREE_MB" ]; then
    install -d -m 700 "$LOCAL_DIR/$sub"
    mv "$final" "$LOCAL_DIR/$sub/$fname"
    rotate_dir "$LOCAL_DIR/$sub" "$LOCAL_KEEP"
  else
    rm -f "$final"
    [ "$LOCAL_KEEP" -gt 0 ] && warn "$label: локальная копия пропущена, свободно меньше ${MIN_FREE_MB} МиБ"
  fi
  return 0
}

# ------------------------------------------------------------- 1. подготовка

log "== Бэкап девбокса, метка прогона $TS"

# Проверка до первого действия: иначе первым сообщением было бы
# «install: mkdir /var/lib/devbox-backup: Permission denied», по которому не
# догадаться, что не хватает именно sudo. Root нужен и для --dry-run: он
# выполняет предполётные проверки целиком, включая связку ключей.
if [ "$(id -u)" -ne 0 ]; then
  suffix=""; [ "$DRY_RUN" -eq 1 ] && suffix=" --dry-run"
  die "нужны права root. Запустите: sudo $0$suffix"
fi

install -d -m 700 "$STATE_DIR" "$GNUPGHOME_DIR"

# Один прогон за раз. Два одновременных pg_dump на машине с ~200 МБ свободной
# памяти встречаются с OOM-killer'ом; ручной запуск поверх таймера — самый
# вероятный способ это устроить.
command -v flock >/dev/null 2>&1 || die "нет команды 'flock' (пакет util-linux)"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  die "другой прогон уже идёт (блокировка $LOCK_FILE)"
fi

# --------------------------------------------------------- 2. предполётные

log
log "== Проверки"

for cmd in docker gpg aws gzip; do
  command -v "$cmd" >/dev/null 2>&1 || die "нет команды '$cmd'"
done
log "  [ok]   docker, gpg, aws, gzip на месте"

docker info >/dev/null 2>&1 || die "демон docker не отвечает"

# Источники стеков собираем ЗДЕСЬ, до дампов: неразвёрнутая подстановка или
# отсутствующий файл должны обрывать прогон до того, как снята половина копий,
# а не посреди него.
STACK_SOURCES=()
while IFS= read -r stack; do
  [ -n "$stack" ] || continue
  while IFS= read -r src; do
    [ -n "$src" ] || continue
    STACK_SOURCES+=("$stack|$src")
  done < <(stack_backup_sources "$stack") \
    || die "не удалось прочитать источники бэкапа стека '$stack'"
  # ENV_VARS затёрт stack_backup_sources — вернуть платформенное окружение,
  # иначе следующая итерация и весь остаток скрипта увидят переменные стека.
  ENV_VARS=(); env_load_files "$ROOT_DIR/.env" "$ENV_BACKUP"
done < <(stacks_enabled)

for entry in "${STACK_SOURCES[@]}"; do
  src="${entry#*|}"
  case "${src%%:*}" in
    sqlite)
      command -v sqlite3 >/dev/null 2>&1 \
        || die "нет sqlite3 (sudo dnf install -y sqlite), а стек объявил источник SQLite"
      [ -f "${src#*:}" ] \
        || die "нет файла SQLite '${src#*:}' — проверьте Backup_Sqlite в stack.conf стека '${entry%%|*}'"
      ;;
    files)
      [ -e "${src#*:}" ] \
        || die "нет пути '${src#*:}' — проверьте Backup_Files в stack.conf стека '${entry%%|*}'"
      ;;
    volume)
      docker volume inspect "${src#*:}" >/dev/null 2>&1 \
        || die "нет тома '${src#*:}' — проверьте Backup_Volume в stack.conf стека '${entry%%|*}'"
      ;;
  esac
done
if [ ${#STACK_SOURCES[@]} -gt 0 ]; then
  log "  [ok]   источников от стеков: ${#STACK_SOURCES[@]}"
fi

[ -f "$GPG_PUBKEY" ] || die "нет публичного ключа $GPG_PUBKEY (см. README, раздел про бэкапы)"

# Импорт намеренно НЕ является точкой отказа.
#
# На Amazon Linux 2023 установлен gnupg2-minimal — сборка для проверки подписей
# RPM, в которой нет ни gpg-agent, ни модулей сжатия. Импорт публичного ключа в
# ней проходит успешно, но печатает в stderr «error running gpg-agent» и
# «preference for compression algorithm ZLIB», хотя ключ оказывается в связке и
# `--list-keys` отдаёт его с кодом 0.
#
# Отличить в этом шуме настоящую поломку от косметики по коду возврата
# невозможно, поэтому судим по результату, а не по механизму — тот же принцип,
# по которому устроены check-certs.sh и check-backups.sh.
# Поддержку --trust-model выясняем до первого содержательного вызова gpg:
# в сборке без моделей доверия эта опция роняет ЛЮБУЮ команду, включая импорт.
gpg_detect_trust_opt

gpg --homedir "$GNUPGHOME_DIR" --batch --quiet --import "$GPG_PUBKEY" 2>/dev/null || true

if ! gpg --homedir "$GNUPGHOME_DIR" --batch --list-keys "$GPG_RECIPIENT" >/dev/null 2>&1; then
  die "в ключе $GPG_PUBKEY нет получателя '$GPG_RECIPIENT' — сверьте Backup_GPG_Recipient"
fi

# И вот это — настоящая проверка: получается ли этим ключом зашифровать.
# Она разом закрывает и отсутствующий gpg-agent, и сборку gpg без поддержки
# шифрования, и несовпадение алгоритмов. Стоит миллисекунды и происходит ДО
# того, как мы сняли хоть один дамп: узнать, что шифровать нечем, после
# часового pg_dump — худший из возможных моментов.
gpg_err=$(mktemp)
if ! printf 'canary' | gpg_encrypt > /dev/null 2>"$gpg_err"; then
  echo "Ошибка: gpg не может шифровать ключом '$GPG_RECIPIENT'." >&2
  sed 's/^/  gpg: /' "$gpg_err" >&2
  rm -f "$gpg_err"
  echo "  На Amazon Linux 2023 обычная причина — пакет gnupg2-minimal без gpg-agent." >&2
  echo "  Полная сборка: sudo dnf install -y gnupg2   (заменит gnupg2-minimal)" >&2
  exit 2
fi
rm -f "$gpg_err"
log "  [ok]   публичный ключ на месте, пробное шифрование для '$GPG_RECIPIENT' прошло"

if [ -n "$DB_PROVIDER" ]; then
  db_hook check >/dev/null 2>&1 \
    || die "поставщик БД '$DB_PROVIDER' не отвечает — дампы снимать не с чего"
  log "  [ok]   поставщик БД '$DB_PROVIDER' отвечает"
else
  log "  [ok]   поставщика общей БД нет — дампы баз не снимаются"
fi

aws_cli s3api head-bucket --bucket "$S3_BUCKET" >/dev/null 2>&1 \
  || die "бакет '$S3_BUCKET' недоступен — проверьте IAM-роль инстанса и Backup_S3_Bucket"
log "  [ok]   бакет s3://$S3_BUCKET доступен"

install -d -m 700 "$LOCAL_DIR" "$TMP_DIR"

# Оценка «сколько понадобится» — по прошлому прогону. На первом прогоне её нет,
# и это не повод отказываться: проверяем только нижнюю границу.
LARGEST_KB=0
if [ -f "$SIZES_FILE" ]; then
  LARGEST_KB=$(awk '{ if ($2 > max) max = $2 } END { print int(max / 1024) }' "$SIZES_FILE")
fi
FREE_MB=$(free_mb "$LOCAL_DIR")
NEED_MB=$(( MIN_FREE_MB + LARGEST_KB / 1024 ))
if [ "$FREE_MB" -lt "$NEED_MB" ]; then
  die "мало места: свободно ${FREE_MB} МиБ, нужно ${NEED_MB} МиБ (порог ${MIN_FREE_MB} + запас под крупнейший дамп прошлого прогона)"
fi
log "  [ok]   место: свободно ${FREE_MB} МиБ при пороге ${NEED_MB} МиБ"

# Мусор от прогона, убитого по питанию или таймауту. Удаляем только `.part`:
# наличие такого файла означает, что тот прогон не дошёл до `mv`, то есть дамп
# заведомо неполон.
find "$TMP_DIR" -maxdepth 1 -name '*.part' -type f -print -delete 2>/dev/null \
  | sed 's/^/  [!]    убран незавершённый файл прошлого прогона: /' || true

# А вот файлы БЕЗ .part здесь — это дампы, которые снялись целиком, но не
# уехали в S3 (run_job оставляет их намеренно: это единственная копия).
# Удалять их нельзя, но и молчать нельзя: иначе они копятся и медленно съедают
# тот самый диск, ради которого весь этот скрипт так осторожен.
leftovers=$(find "$TMP_DIR" -maxdepth 1 -type f ! -name '*.part' 2>/dev/null | wc -l | tr -d ' ')
if [ "${leftovers:-0}" -gt 0 ]; then
  warn "в $TMP_DIR лежит невыгруженных дампов: $leftovers"
  warn "это остатки прогонов, где упала выгрузка в S3. Выгрузите вручную или удалите:"
  find "$TMP_DIR" -maxdepth 1 -type f ! -name '*.part' -printf '           %s\t%p\n' 2>/dev/null >&2 || true
fi

# ------------------------------------------------------------ 3. источники

log
log "== Источники"

rm -f "$SIZES_FILE.new"

# Список баз спрашиваем у самой СУБД, а не берём из конфига. Захардкоженный
# список означал бы, что следующая заведённая стеком база молча останется без
# бэкапа — а отсутствующий бэкап выглядит ровно как источник, которого нет.
DATABASES=""
DB_EXT=".dump"
if [ -n "$DB_PROVIDER" ]; then
  DATABASES=$(db_hook list | tr -d '\r' | sed '/^[[:space:]]*$/d')
  DB_EXT=$(db_hook ext 2>/dev/null || echo '.dump')

  if [ -z "$DATABASES" ]; then
    # Ноль баз — это не «нечего делать», а почти наверняка сломанный запрос или
    # не тот контейнер. Молчаливый успех здесь был бы худшим исходом.
    die "поставщик '$DB_PROVIDER' вернул пустой список баз — это не похоже на правду, разбирайтесь"
  fi

  log "  базы ($DB_PROVIDER): $(echo "$DATABASES" | tr '\n' ' ')"

  # Объекты уровня кластера: роли, пароли, гранты. Без них восстановленная база
  # есть, а подключиться к ней некому. Пустой вывод — законно: у части движков
  # таких объектов нет вовсе, и тогда шага просто не будет.
  if [ -n "$(db_hook globals 2>/dev/null | head -c 1)" ]; then
    run_job "$DB_PREFIX/_globals" "$DB_PREFIX/_globals" "$TS.sql.gpg" dump_globals || true
  fi
fi

if [ -n "$DATABASES" ]; then
  while IFS= read -r db; do
    [ -n "$db" ] || continue
    run_job "$DB_PREFIX/$db" "$DB_PREFIX/$db" "$TS$DB_EXT.gpg" dump_db "$db" || true
  done <<< "$DATABASES"
fi

# Источники, объявленные стеками. Собраны и проверены выше.
for entry in "${STACK_SOURCES[@]}"; do
  stack="${entry%%|*}"; src="${entry#*|}"
  kind="${src%%:*}"; val="${src#*:}"
  case "$kind" in
    db)       run_job "$DB_PREFIX/$val" "$DB_PREFIX/$val" "$TS$DB_EXT.gpg" dump_db "$val" || true ;;
    sqlite)   sub=$(sqlite_s3_subpath "$val")
              run_job "$sub" "$sub" "$TS.db.gz.gpg" dump_sqlite "$val" || true ;;
    files)    run_job "files/$stack" "files/$stack" "$TS.tar.gz.gpg" dump_files "$val" || true ;;
    volume)   run_job "volume/$val" "volume/$val" "$TS.tar.gz.gpg" dump_volume "$val" || true ;;
  esac
done

# --------------------------------------------------------------- 4. итог

if [ "$DRY_RUN" -eq 1 ]; then
  log
  log "Пробный прогон завершён, ничего не изменено."
  exit 0
fi

[ -f "$SIZES_FILE.new" ] && mv "$SIZES_FILE.new" "$SIZES_FILE"

log
if [ ${#FAILED[@]} -gt 0 ]; then
  echo "Провалено источников: ${#FAILED[@]} — ${FAILED[*]}" >&2
  echo "Разбор: journalctl -u devbox-backup -n 100" >&2
  exit 1
fi

log "Готово. Метка прогона: $TS"
log "Проверить независимо: ./platform/bin/check-backups.sh"
