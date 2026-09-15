#!/usr/bin/env bash

# Восстановление из бэкапа.
#
# ВАЖНОЕ СЛЕДСТВИЕ ШИФРОВАНИЯ, о котором лучше узнать не в аварийный день:
# расшифровать бэкап НА ЭТОЙ МАШИНЕ нельзя. Приватного GPG-ключа здесь нет и
# быть не должно — иначе шифрование не защищало бы ровно от того сценария, ради
# которого оно есть. Поэтому восстановление — два шага:
#
#   1. На машине, где есть приватный ключ (ноутбук):
#        aws s3 cp s3://<бакет>/<префикс>/postgres/<база>/<TS>.dump.gpg - \
#          | gpg --decrypt > <база>.dump
#        scp <база>.dump ec2-user@devbox:/tmp/
#
#   2. Здесь — этот скрипт, он принимает УЖЕ РАСШИФРОВАННЫЙ файл:
#        ./scripts/backup-restore.sh --check /tmp/<база>.dump
#        ./scripts/backup-restore.sh --apply /tmp/<база>.dump --into <база> --yes
#
# Порядок при полном восстановлении: сначала _globals (роли и пароли), потом
# базы. Наоборот — pg_restore упрётся в «role does not exist».

set -euo pipefail

DIR0="$( cd -P "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ROOT_DIR="${ROOT_DIR:-$( cd "$DIR0/../.." && pwd )}"
LIB_DIR="$( cd "$DIR0/../lib" && pwd )"

# shellcheck source=platform/lib/lib-env.sh
. "$LIB_DIR/lib-env.sh"
# lib-stacks нужен с самого начала: поставщика БД спрашиваем ещё при разборе
# конфига. Раньше на его месте стояла константа с именем контейнера postgres,
# и библиотека подключалась сильно позже, по месту первой надобности.
# shellcheck source=platform/lib/lib-stacks.sh
. "$LIB_DIR/lib-stacks.sh"

MODE=""
FILE=""
TARGET=""
CLEAN=0
ASSUME_YES=0

usage() {
  cat <<'EOF'
Использование:
  ./scripts/backup-restore.sh --list [<подпуть>]
        показать, что лежит в S3. Без аргумента — источники верхнего уровня,
        например: --list mysql/orders

  ./scripts/backup-restore.sh --check <файл>
        распознать расшифрованный дамп и показать его содержимое.
        Ничего не меняет.

  ./scripts/backup-restore.sh --apply <файл> --into <цель> [--clean] [--yes]
        восстановить. <цель> — имя базы postgres либо путь к файлу SQLite.
        --clean   удалить существующие объекты перед восстановлением
                  (pg_restore --clean --if-exists). БЕЗ него восстановление
                  в непустую базу упрётся в конфликты имён.
        --yes     не спрашивать подтверждение (для неинтерактивного запуска)

Файлы .gpg этот скрипт не принимает намеренно — см. комментарий в его начале.
EOF
}

[ $# -gt 0 ] || { usage >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --list)  MODE=list;  shift; TARGET="${1-}"; [ $# -gt 0 ] && shift ;;
    --check) MODE=check; shift; FILE="${1-}"; shift || true ;;
    --apply) MODE=apply; shift; FILE="${1-}"; shift || true ;;
    --into)  shift; TARGET="${1-}"; shift || true ;;
    --clean) CLEAN=1; shift ;;
    --yes)   ASSUME_YES=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Неизвестный аргумент: $1" >&2; usage >&2; exit 2 ;;
  esac
done

die() { echo "Ошибка: $*" >&2; exit 2; }

ENV_BACKUP="$ROOT_DIR/.env-backup"
[ -f "$ENV_BACKUP" ] || die "нет $ENV_BACKUP"
env_load_files "$ROOT_DIR/.env" "$ENV_BACKUP"

S3_BUCKET=$(env_get Backup_S3_Bucket)
S3_PREFIX=$(backup_s3_prefix)
AWS_REGION=$(env_get Backup_AWS_Region us-east-1)
AWS_KEY=$(env_get Backup_AWS_Access_Key_Id)
AWS_SECRET=$(env_get Backup_AWS_Secret_Access_Key)
DB_PROVIDER="$(stacks_db_provider)"

# Восстановление в СУБД делает поставщик: pg_restore и `mysql <` — знание
# движка, ровно как дамп. Платформа отвечает за S3, GPG, распознавание файла и
# подтверждения; что делать с содержимым — знает стек.
db_hook() {
  [ -n "$DB_PROVIDER" ] || die "поставщик общей БД не включён — восстанавливать некуда"
  local h; h="$(stack_dir "$DB_PROVIDER")/scripts/backup-dump.sh"
  [ -x "$h" ] || die "у поставщика '$DB_PROVIDER' нет scripts/backup-dump.sh"
  ROOT_DIR="$ROOT_DIR" STACK_DIR="$(stack_dir "$DB_PROVIDER")" "$h" "$@"
}

aws_cli() {
  if [ -n "$AWS_KEY" ]; then
    AWS_ACCESS_KEY_ID="$AWS_KEY" AWS_SECRET_ACCESS_KEY="$AWS_SECRET" \
      aws --region "$AWS_REGION" "$@"
  else
    aws --region "$AWS_REGION" "$@"
  fi
}

# ------------------------------------------------------------------- список

if [ "$MODE" = list ]; then
  [ -n "$S3_BUCKET" ] || die "Backup_S3_Bucket не задан"
  path="s3://$S3_BUCKET/$S3_PREFIX/${TARGET:+$TARGET/}"
  echo "== $path"
  aws_cli s3 ls "$path" --recursive --human-readable 2>/dev/null \
    | tail -50 \
    || die "не удалось прочитать $path"
  echo
  echo "Расшифровать (на машине с приватным ключом):"
  echo "  aws s3 cp s3://$S3_BUCKET/<ключ> - | gpg --decrypt > дамп"
  exit 0
fi

# ------------------------------------------------------- распознавание файла

[ -n "$FILE" ] || die "не указан файл"

# Проверка на .gpg — ДО проверки существования. Файл, которого нет, чаще всего
# и есть тот самый случай: человек назвал ключ из S3, ожидая, что скрипт сам
# скачает и расшифрует. Сообщение про два шага полезнее, чем «нет файла».
case "$FILE" in
  *.gpg)
    echo "Ошибка: '$FILE' зашифрован, а приватного ключа на этой машине нет и быть не должно." >&2
    echo >&2
    echo "Расшифруйте там, где ключ есть, и принесите результат:" >&2
    echo "  gpg --decrypt '$(basename "$FILE")' > дамп     # на ноутбуке" >&2
    echo "  scp дамп ec2-user@devbox:/tmp/" >&2
    exit 2
    ;;
esac

[ -f "$FILE" ] || die "нет файла '$FILE'"

# Распознаём по содержимому, а не по имени: имя мог поменять кто угодно, а
# перепутать формат при восстановлении — это применить SQLite-базу поверх
# postgres или наоборот.
#
# Через od, а не через `head | tr`: дамп — двоичный файл, и `tr` на нём падает
# с «Illegal byte sequence», как только в первых байтах попадётся
# невалидная для текущей локали последовательность. Вывод od — чистый ASCII,
# и разбирать его безопасно при любой локали.
# Распознавание — в lib-env.sh (backup_file_kind): оно смотрит ВНУТРЬ gzip, а
# не на обёртку. Здесь остаётся только то, чего библиотека знать не должна, —
# вопрос поставщику про его собственные форматы.
KIND="$(backup_file_kind "$FILE")"
[ "$KIND" = unknown ] && KIND="db:$(db_hook detect "$FILE" 2>/dev/null || echo unknown)"

human_kind() {
  case "$KIND" in
    db:*)         echo "дамп СУБД '$DB_PROVIDER', формат: ${KIND#db:}" ;;
    sqlite_gz)    echo "база SQLite, сжатая gzip" ;;
    sqlite_plain) echo "база SQLite" ;;
    tar_gz)       echo "архив каталога или тома (tar.gz)" ;;
    db:unknown)   echo "формат не опознан ни платформой, ни поставщиком" ;;
  esac
}

# ------------------------------------------------------------------ проверка

if [ "$MODE" = check ]; then
  bytes=$(stat -c %s "$FILE" 2>/dev/null || stat -f %z "$FILE")
  echo "Файл:   $FILE"
  echo "Размер: $bytes б ($((bytes / 1024)) КиБ)"
  echo "Тип:    $(human_kind)"
  echo

  case "$KIND" in
    tar_gz)
      echo "== Первые 20 записей архива"
      tar -tzf "$FILE" | head -20
      ;;
    db:*)
      # Показать, что внутри дампа, умеет только сам движок. Хук печатает это
      # сам; платформе достаточно знать, что предпросмотр есть не всегда.
      db_hook inspect "${KIND#db:}" "$FILE" 2>/dev/null \
        || echo "  (поставщик '$DB_PROVIDER' не умеет показывать содержимое этого дампа)"
      ;;
    sqlite_gz|sqlite_plain)
      tmp=$(mktemp)
      trap 'rm -f "$tmp"' EXIT
      if [ "$KIND" = sqlite_gz ]; then gunzip -c "$FILE" > "$tmp"; else cp "$FILE" "$tmp"; fi
      echo "== integrity_check"
      sqlite3 "$tmp" 'PRAGMA integrity_check;'
      echo
      echo "== Таблицы и число строк"
      while IFS= read -r t; do
        printf '  %-34s %s\n' "$t" "$(sqlite3 "$tmp" "SELECT count(*) FROM \"$t\";")"
      done < <(sqlite3 "$tmp" "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name;")
      ;;
  esac
  echo
  echo "Проверка завершена, ничего не изменено."
  exit 0
fi

# --------------------------------------------------------------- применение

[ "$MODE" = apply ] || die "не указан режим (--list / --check / --apply)"
[ -n "$TARGET" ] || die "не указана цель: --into <база или путь>"

echo "Файл:   $FILE"
echo "Тип:    $(human_kind)"
echo "Цель:   $TARGET"
[ "$CLEAN" -eq 1 ] && echo "Режим:  --clean — существующие объекты будут УДАЛЕНЫ"
echo

if [ "$ASSUME_YES" -ne 1 ]; then
  printf 'Восстановление изменит данные. Продолжить? [напечатайте: да] '
  read -r answer
  [ "$answer" = "да" ] || { echo "Отменено."; exit 1; }
fi

case "$KIND" in
  db:unknown)
    die "формат файла не опознан. Проверьте, что файл расшифрован (.gpg этот скрипт не принимает) и не обрезан"
    ;;

  tar_gz)
    # Автоматически НЕ раскладываем. Источники files: и volume: — это каталоги,
    # в которые кто-то пишет прямо сейчас: распаковка поверх живого писателя
    # даёт смесь старого и нового, причём молча. Кто именно пишет, платформа не
    # знает: том может быть смонтирован в любой контейнер любого стека.
    #
    # Поэтому печатаем готовую команду и останавливаемся. Это единственное
    # место скрипта, где он отказывается доделать работу, и отказ намеренный.
    echo "Это архив каталога или тома. Автоматически не раскладываю."
    echo
    echo "  1. остановите то, что пишет в '$TARGET' (./stack disable <стек> либо ./dc stop <сервис>)"
    echo "  2. tar -xzf $FILE -C $(dirname "$TARGET")"
    echo "  3. поднимите обратно"
    echo
    echo "Содержимое: ./platform/bin/backup-restore.sh --check $FILE"
    exit 1
    ;;

  db:*)
    # Всё, что относится к СУБД, делает её поставщик: существует ли база, чем
    # заливать дамп, нужен ли --clean. Платформа сюда не лезет — иначе этот
    # скрипт пришлось бы форкать под каждый движок.
    db_hook restore "${KIND#db:}" "$TARGET" "$FILE" "$CLEAN"
    echo "Готово: '$TARGET' восстановлена."
    ;;

  sqlite_gz|sqlite_plain)
    # Писать в базу под работающим приложением нельзя: оно держит её открытой и
    # запишет поверх свои страницы. Останавливаем осознанно, руками.
    #
    # Владельца базы ищем по декларациям, а не по списку имён контейнеров:
    # захардкоженный список молча устаревает при переименовании сервиса — и
    # тогда проверка пропускает восстановление поверх живого писателя, то есть
    # ровно та поломка, от которой она защищает.
        owner=""
    while IFS= read -r st; do
      [ -n "$st" ] || continue
      while IFS= read -r src; do
        [ "$src" = "sqlite:$TARGET" ] && owner="$st"
      done < <(stack_backup_sources "$st" 2>/dev/null)
      ENV_VARS=(); env_load_files "$ROOT_DIR/.env" "$ENV_BACKUP"
    done < <(stacks_enabled 2>/dev/null)

    if [ -z "$owner" ]; then
      echo "Предупреждение: ни один включённый стек не объявляет '$TARGET' как Backup_Sqlite." >&2
      echo "  Проверить, что базу никто не держит открытой, придётся самостоятельно." >&2
    else
      while IFS= read -r svc; do
        [ -n "$svc" ] || continue
        while IFS= read -r cid; do
          [ -n "$cid" ] || continue
          [ "$(docker inspect -f '{{.State.Status}}' "$cid" 2>/dev/null)" = running ] || continue
          die "контейнер '$(docker inspect -f '{{.Name}}' "$cid" | sed 's|^/||')' стека '$owner' работает.
  Остановите стек и повторите:  ./scripts/stack.sh disable $owner"
        done < <(service_containers "$svc")
      done < <(stack_services "$owner" 2>/dev/null)
    fi
    if [ -f "$TARGET" ]; then
      backup_of_current="$TARGET.before-restore.$(date -u +%Y%m%dT%H%M%SZ)"
      cp "$TARGET" "$backup_of_current"
      echo "Прежняя база сохранена: $backup_of_current"
    fi
    if [ "$KIND" = sqlite_gz ]; then gunzip -c "$FILE" > "$TARGET"; else cp "$FILE" "$TARGET"; fi
    sqlite3 "$TARGET" 'PRAGMA integrity_check;'
    echo "Готово: '$TARGET' восстановлена. Поднимите стек: ./scripts/stack.sh enable ${owner:-<стек>}"
    ;;
esac
