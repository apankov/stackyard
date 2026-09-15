#!/usr/bin/env bash
#
# Аудит изоляции машин. Запускается в РАБОЧЕМ ПРОСТРАНСТВЕ, а не на машине, и
# это не мелочь: машина по определению не видит соседей и «общий на всех бакет»
# для неё выглядит ровно как правильно настроенный свой.
#
# Что ищем — значения, общие у двух и более машин. Каждое из них означает, что
# изоляция клиентов существует только на бумаге:
#
#   * один ключ ACME-аккаунта  -> общие лимиты Let's Encrypt и общий отзыв
#                                 чужих сертификатов;
#   * один бакет/префикс бэкапа -> дампы клиента A там, где их берёт клиент B;
#   * один GPG-получатель       -> и там же расшифрует;
#   * один чат оповещений       -> аварии всех клиентов у одного читателя;
#   * одна docker-сеть или один
#     каталог развёртывания      -> почти наверняка копипаста .env, за которой
#                                 тянется и всё остальное.
#
#   ./bin/audit-isolation.sh          # отчёт, ненулевой код при находках
#
# Ничего не меняет.

set -uo pipefail

ROOT="$( cd -P "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
PROBLEMS=0
WARNINGS=0

ok()   { printf '  [ok]   %s\n' "$1"; }
warn() { printf '  [!]    %s\n' "$1"; WARNINGS=$((WARNINGS + 1)); }
bad()  { printf '  [FAIL] %s\n' "$1"; PROBLEMS=$((PROBLEMS + 1)); }
step() { printf '\n== %s\n' "$1"; }

machines=()
for d in "$ROOT"/machines/*/; do [ -d "$d" ] && machines+=("$(basename "${d%/}")"); done
[ ${#machines[@]} -gt 0 ] || { echo "Машин не найдено"; exit 0; }

# --------------------------------------------- 1. в платформе нет секретов

step "Секреты в общих слоях"

# Платформа и профиль уезжают на КАЖДУЮ машину. Секрет в них — это секрет,
# размноженный по всем клиентам, и обнаружить это постфактум нечем.
found=0
while IFS= read -r f; do
  case "$f" in *.example) continue ;; esac
  bad "секрет в общем слое: ${f#"$ROOT"/}"
  found=1
done < <(find "$ROOT/platform" "$ROOT/profiles" \
              \( -name '.env' -o -name '*.key' -o -name '*.pem' -o -name 'account.key' \
                 -o -name 'databases.yaml' -o -name '*.asc' \) 2>/dev/null)
[ "$found" -eq 0 ] && ok "в platform/ и profiles/ секретов нет"

# ------------------------------------- 2. значения, общие у разных машин

step "Значения, общие у нескольких машин"

# Ключи, совпадение которых по любым двум машинам — это отказ, а не совпадение.
# Список поимённый, а не «всё, что похоже на секрет»: у Platform_Vhosts_Mount
# значение обязано совпадать (это путь ВНУТРИ контейнера), и ловить его здесь
# значило бы приучить читать отчёт по диагонали.
MUST_DIFFER="Platform_Network Platform_Deploy_Dir
Backup_S3_Bucket Backup_S3_Prefix Backup_GPG_Recipient
Backup_AWS_Access_Key_Id Backup_AWS_Secret_Access_Key
Notify_Telegram_Token Notify_Telegram_Chat_Id"

# Собираем «ключ<TAB>значение<TAB>машина» по всем env-файлам всех машин.
pairs=$(
  for m in "${machines[@]}"; do
    for f in "$ROOT/machines/$m"/.env "$ROOT/machines/$m"/.env-backup \
             "$ROOT/machines/$m"/.env-notify "$ROOT/machines/$m"/stacks/*/.env; do
      [ -f "$f" ] || continue
      # Построчно, без source: значение с пробелами или обратными кавычками
      # иначе стало бы исполняемым кодом.
      while IFS= read -r line; do
        case "$line" in \#*|'') continue ;; esac
        case "$line" in *=*) ;; *) continue ;; esac
        key="${line%%=*}"; val="${line#*=}"
        val="${val%\"}"; val="${val#\"}"; val="${val%\'}"; val="${val#\'}"
        [ -n "$val" ] || continue
        printf '%s\t%s\t%s\n' "$key" "$val" "$m"
      done < "$f"
    done
  done
)

shared=0
for key in $MUST_DIFFER; do
  dupes=$(printf '%s\n' "$pairs" | awk -F'\t' -v k="$key" '$1 == k { print $2 "\t" $3 }' \
          | sort | awk -F'\t' '{ if ($1 == prev) print prev "\t" prevm "\t" $2; prev = $1; prevm = $2 }')
  [ -n "$dupes" ] || continue
  while IFS=$'\t' read -r val m1 m2; do
    bad "$key одинаков у машин $m1 и $m2 (значение: ${val:0:24}…)"
    shared=1
  done <<< "$dupes"
done

# Любой пароль/токен, совпавший у двух машин по ЗНАЧЕНИЮ.
#
# Сравниваем именно значения, а не пары ключ-значение. Mysql_Root_Password на
# одной машине и Pg_Root_Password на другой — разные ключи, но если строка
# одна, то и секрет один: утёк он у любой из них, а достанет обе. Сверка по
# парам этот случай пропускает, и пропускает молча.
dupes=$(printf '%s\n' "$pairs" \
  | awk -F'\t' 'tolower($1) ~ /password|secret|token|_key$/ { print $2 "\t" $1 "\t" $3 }' \
  | sort -u | sort -t$'\t' -k1,1 \
  | awk -F'\t' '{ if ($1 == pv && $3 != pm) print $2 "\t" pm "\t" $3; pv = $1; pm = $3 }')
if [ -n "$dupes" ]; then
  while IFS=$'\t' read -r key m1 m2; do
    bad "секрет переиспользован машинами $m1 и $m2 (ключ вида $key)"
    shared=1
  done <<< "$dupes"
fi
[ "$shared" -eq 0 ] && ok "совпадающих значений не найдено"

# ------------------------------------------- 3. ключи ACME-аккаунтов

step "Ключи ACME-аккаунтов"

# Сравниваем по содержимому: путь у каждой машины свой по построению, а вот
# скопированный файл выглядит настроенным правильно.
sums=""
for m in "${machines[@]}"; do
  k="$ROOT/machines/$m/state/getssl-config/account.key"
  if [ ! -f "$k" ]; then
    warn "$m: ключа ACME-аккаунта ещё нет (заведёт getssl при первом выпуске)"
    continue
  fi
  sums="$sums$(shasum -a 256 "$k" | cut -d' ' -f1)	$m"$'\n'
done
dupes=$(printf '%s' "$sums" | sort | awk -F'\t' '{ if ($1 == prev) print prevm "\t" $2; prev = $1; prevm = $2 }')
if [ -n "$dupes" ]; then
  while IFS=$'\t' read -r m1 m2; do
    bad "машины $m1 и $m2 используют ОДИН ключ ACME-аккаунта — общие лимиты и общий отзыв"
  done <<< "$dupes"
elif [ -n "$sums" ]; then
  ok "у каждой машины свой ключ"
fi

# ------------------------------------------------------------------ итог

echo
if [ "$PROBLEMS" -gt 0 ]; then
  echo "Изоляция нарушена: проблем — $PROBLEMS, предупреждений — $WARNINGS."
  exit 1
fi
echo "Изоляция в порядке. Предупреждений: $WARNINGS."
