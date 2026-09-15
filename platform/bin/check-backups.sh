#!/usr/bin/env bash

# Проверка, что бэкапы действительно есть.
#
# Существует по той же причине, что и check-certs.sh: скрипт, отработавший
# успешно, и скрипт, решивший что источников ноль и честно вышедший с кодом 0,
# выглядят одинаково. Поэтому здесь ожидаемый список источников строится
# ЗАНОВО — у самой СУБД, — а результат спрашивается у S3, а не у backup.sh.
#
# Коды возврата (как в check-certs.sh):
#   0 — все источники свежие и непустые
#   1 — есть проблемные: устарел, пуст или отсутствует
#   2 — проверить не удалось (нет конфига, S3 или СУБД недоступны)
#
# Ненулевой код -> юнит в состоянии failed -> виден в `systemctl --failed`,
# а не тонет в журнале. Внешнего канала оповещений пока нет; этот скрипт —
# точка, к которой он будет подключён.

set -uo pipefail

DIR0="$( cd -P "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# Каталог МАШИНЫ, а не платформы. Обычно его задаёт обёртка в корне машины;
# запасной вариант — на два уровня вверх от platform/bin.
ROOT_DIR="${ROOT_DIR:-$( cd "$DIR0/../.." && pwd )}"
LIB_DIR="$( cd "$DIR0/../lib" && pwd )"

# shellcheck source=platform/lib/lib-env.sh
. "$LIB_DIR/lib-env.sh"
# lib-stacks нужен с самого начала: поставщика БД спрашиваем ещё при разборе
# конфига. Раньше на его месте стояла константа с именем контейнера postgres,
# и библиотека подключалась сильно позже, по месту первой надобности.
# shellcheck source=platform/lib/lib-stacks.sh
. "$LIB_DIR/lib-stacks.sh"

ENV_BACKUP="$ROOT_DIR/.env-backup"
[ -f "$ENV_BACKUP" ] || { echo "Ошибка: нет $ENV_BACKUP" >&2; exit 2; }

env_load_files "$ROOT_DIR/.env" "$ENV_BACKUP"

S3_BUCKET=$(env_get Backup_S3_Bucket)
[ -n "$S3_BUCKET" ] || { echo "Ошибка: Backup_S3_Bucket не задан" >&2; exit 2; }
S3_PREFIX=$(backup_s3_prefix)
AWS_REGION=$(env_get Backup_AWS_Region us-east-1)
AWS_KEY=$(env_get Backup_AWS_Access_Key_Id)
AWS_SECRET=$(env_get Backup_AWS_Secret_Access_Key)
DB_PREFIX=$(backup_db_prefix)
MAX_AGE_HOURS=$(env_get Backup_Max_Age_Hours 26)
MIN_OBJ_BYTES=$(env_get Backup_Min_Object_Bytes 1024)

aws_cli() {
  if [ -n "$AWS_KEY" ]; then
    AWS_ACCESS_KEY_ID="$AWS_KEY" AWS_SECRET_ACCESS_KEY="$AWS_SECRET" \
      aws --region "$AWS_REGION" "$@"
  else
    aws --region "$AWS_REGION" "$@"
  fi
}

# BSD date (macOS) и GNU date (Linux) разбирают ISO-8601 по-разному — та же
# развилка, что и в check-certs.sh.
to_epoch() {
  local s="$1"
  date -d "$s" +%s 2>/dev/null && return 0
  s="${s%%+*}"; s="${s%%.*}"
  date -j -f '%Y-%m-%dT%H:%M:%S' "$s" +%s 2>/dev/null && return 0
  return 1
}

command -v aws >/dev/null 2>&1 || { echo "Ошибка: нет команды 'aws'" >&2; exit 2; }
aws_cli s3api head-bucket --bucket "$S3_BUCKET" >/dev/null 2>&1 \
  || { echo "Ошибка: бакет '$S3_BUCKET' недоступен" >&2; exit 2; }

# ---------------------------------------------- ожидаемый список источников

EXPECTED=()
DEGRADED=0

# Список баз строим ЗАНОВО, у самой СУБД, а не берём у backup.sh: проверка,
# спрашивающая у проверяемого, подтверждает только его собственное мнение.
# Спрашиваем через хук поставщика — про pg_dump и mysqldump платформа не знает.
DB_PROVIDER="$(stacks_db_provider)"
databases=""
if [ -n "$DB_PROVIDER" ]; then
  hook="$(stack_dir "$DB_PROVIDER")/scripts/backup-dump.sh"
  if [ -x "$hook" ]; then
    databases=$(ROOT_DIR="$ROOT_DIR" STACK_DIR="$(stack_dir "$DB_PROVIDER")" "$hook" list 2>/dev/null \
                | tr -d '\r' | sed '/^[[:space:]]*$/d')
    [ -n "$(ROOT_DIR="$ROOT_DIR" STACK_DIR="$(stack_dir "$DB_PROVIDER")" "$hook" globals 2>/dev/null | head -c 1)" ] \
      && EXPECTED+=("$DB_PREFIX/_globals")
  fi

  if [ -z "$databases" ]; then
    # Список не построить — значит нельзя утверждать, что все базы охвачены.
    # Свежесть того, что есть, всё равно проверяем: это полезнее молчания. Но
    # итоговый код будет 2, потому что «не смогли проверить» — не то же самое,
    # что «всё хорошо».
    echo "ВНИМАНИЕ: список баз у поставщика '$DB_PROVIDER' получить не удалось — полнота не проверена." >&2
    DEGRADED=1
    while IFS= read -r p; do
      [ -n "$p" ] && EXPECTED+=("$DB_PREFIX/$p")
    done < <(aws_cli s3 ls "s3://$S3_BUCKET/$S3_PREFIX/$DB_PREFIX/" 2>/dev/null \
             | awk '$1 == "PRE" { sub(/\/$/, "", $2); print $2 }' | grep -v '^_globals$')
  else
    while IFS= read -r db; do
      [ -n "$db" ] && EXPECTED+=("$DB_PREFIX/$db")
    done <<< "$databases"
  fi
fi

# Ожидаемый набор строится из ТЕХ ЖЕ деклараций, из которых backup.sh строит
# фактический, и той же формулой префикса из общего lib-env.sh. Две копии одной
# формулы разъезжаются легко, а замечается это как «нет ни одного бэкапа» при
# исправных бэкапах — так уже было.
while IFS= read -r stack; do
  [ -n "$stack" ] || continue
  while IFS= read -r src; do
    [ -n "$src" ] || continue
    case "${src%%:*}" in
      sqlite) EXPECTED+=("$(sqlite_s3_subpath "${src#*:}")") ;;
      files)  EXPECTED+=("files/$stack") ;;
      volume) EXPECTED+=("volume/${src#*:}") ;;
    esac
  done < <(stack_backup_sources "$stack")
  ENV_VARS=(); env_load_files "$ROOT_DIR/.env" "$ENV_BACKUP"
done < <(stacks_enabled 2>/dev/null)

# --------------------------------------------------------------- проверка

now=$(date -u +%s)
problems=0

for src in "${EXPECTED[@]}"; do
  newest=$(aws_cli s3api list-objects-v2 \
             --bucket "$S3_BUCKET" --prefix "$S3_PREFIX/$src/" \
             --query 'sort_by(Contents, &LastModified)[-1].[Size,LastModified]' \
             --output text 2>/dev/null)

  if [ -z "$newest" ] || [ "$newest" = "None" ] || [ "$newest" = "None	None" ]; then
    printf '%-34s НЕТ НИ ОДНОГО БЭКАПА\n' "$src"
    problems=$((problems + 1))
    continue
  fi

  size=$(printf '%s' "$newest" | awk '{print $1}')
  modified=$(printf '%s' "$newest" | awk '{print $2}')

  if ! ts=$(to_epoch "$modified"); then
    printf '%-34s ОШИБКА: не разобрана дата "%s"\n' "$src" "$modified"
    problems=$((problems + 1))
    continue
  fi

  age_h=$(( (now - ts) / 3600 ))

  if [ "$size" -lt "$MIN_OBJ_BYTES" ]; then
    # Оборванный дамп почти всегда крошечный. Без этой проверки «файл есть»
    # неотличимо от «бэкап есть».
    printf '%-34s ПУСТОЙ: %s б при пороге %s б\n' "$src" "$size" "$MIN_OBJ_BYTES"
    problems=$((problems + 1))
  elif [ "$age_h" -ge "$MAX_AGE_HOURS" ]; then
    printf '%-34s УСТАРЕЛ: %s ч назад (порог %s ч)\n' "$src" "$age_h" "$MAX_AGE_HOURS"
    problems=$((problems + 1))
  else
    printf '%-34s ok, %s ч назад, %s КиБ\n' "$src" "$age_h" "$((size / 1024))"
  fi
done

echo
if [ "$problems" -gt 0 ]; then
  echo "Проблемных источников: $problems из ${#EXPECTED[@]}." >&2
  echo "Разбор: journalctl -u devbox-backup --since '-3 days'" >&2
  exit 1
fi

if [ "$DEGRADED" -eq 1 ]; then
  echo "Все найденные источники свежие, но список баз не проверен — см. предупреждение выше." >&2
  exit 2
fi

echo "Проверено источников: ${#EXPECTED[@]}. Все свежее $MAX_AGE_HOURS ч и непустые."
