#!/usr/bin/env bash

# Проверка сроков TLS-сертификатов.
#
# Существует потому, что таймер, переставший срабатывать, выглядит ровно как
# таймер, которому нечего делать. getssl молчит, когда продлевать нечего, и
# молчит же, когда он не запускался. Отличить одно от другого может только
# независимая проверка результата.
#
# Ненулевой код возврата -> systemd помечает юнит как failed, и он всплывает
# в `systemctl --failed`, а не тонет в журнале.

set -uo pipefail

DIR0="$( cd -P "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# Каталог МАШИНЫ, а не платформы. Обычно его задаёт обёртка ./stack в корне
# машины; запасной вариант — на два уровня вверх от platform/bin, чтобы скрипт
# работал и при прямом вызове.
if [ -z "${ROOT_DIR:-}" ]; then
  ROOT_DIR="$( cd "$DIR0/../.." && pwd )"
  # On a machine, platform/ is a symlink into .stackyard/, and the `cd -P`
  # above has already resolved it: two levels up lands in .stackyard rather
  # than in the machine. state/ would then be created INSIDE the downloaded
  # layer and vanish on the next ./bootstrap, and until then the password
  # files, certificates and databases.yaml would sit where no container looks
  # for them. The wrappers in the machine root set ROOT_DIR themselves, but
  # every script documents being called as ./platform/bin/<name>.sh — that is
  # the path this fixes.
  [ "${ROOT_DIR##*/}" = .stackyard ] && ROOT_DIR="${ROOT_DIR%/*}"
fi
LIB_DIR="$( cd "$DIR0/../lib" && pwd )"
ENV_FILE="$ROOT_DIR/.env"

# shellcheck source=platform/lib/lib-stacks.sh
. "$LIB_DIR/lib-stacks.sh"

if [ ! -f "$ENV_FILE" ]; then
  echo "Ошибка: Файл окружения '$ENV_FILE' не найден!" >&2
  exit 2
fi

Platform_Deploy_Dir=$(grep -E '^Platform_Deploy_Dir=' "$ENV_FILE" | head -n 1 | cut -d '=' -f2- | tr -d '"'\')

if [ -z "$Platform_Deploy_Dir" ]; then
  echo "Ошибка: Переменная Platform_Deploy_Dir не задана в файле $ENV_FILE" >&2
  exit 2
fi

CERTS_DIR="$Platform_Deploy_Dir/state/certs"

# RENEW_ALLOW в getssl-config/getssl.cfg равен 30: продление должно произойти,
# когда до конца осталось меньше 30 дней. Порог тревоги ниже, чтобы у getssl
# было десять суток и несколько попыток, прежде чем шуметь.
THRESHOLD_DAYS="${THRESHOLD_DAYS:-20}"

# Сертификат-заглушка из scripts/certs.sh: самоподписанный, живёт год, поэтому
# по одному только сроку неотличим от здорового. Узнаём его по issuer.
PLACEHOLDER_CN='CN=devbox'

if [ ! -d "$CERTS_DIR" ]; then
  echo "Ошибка: нет каталога сертификатов $CERTS_DIR" >&2
  exit 2
fi

shopt -s nullglob
certs=( "$CERTS_DIR"/*-fullchain.crt )
shopt -u nullglob

if [ ${#certs[@]} -eq 0 ]; then
  echo "Ошибка: в $CERTS_DIR нет ни одного *-fullchain.crt" >&2
  exit 2
fi

now=$(date +%s)
problems=0

for cert in "${certs[@]}"; do
  host=$(basename "$cert" -fullchain.crt)

  if ! end_date=$(openssl x509 -noout -enddate -in "$cert" 2>/dev/null | cut -d= -f2); then
    printf '%-40s ОШИБКА: файл нечитаем как сертификат\n' "$host"
    problems=$((problems + 1))
    continue
  fi

  issuer=$(openssl x509 -noout -issuer -in "$cert" 2>/dev/null)

  # BSD date (macOS) и GNU date (Linux) разбирают эту строку по-разному.
  if ! end_ts=$(date -d "$end_date" +%s 2>/dev/null); then
    end_ts=$(date -j -f '%b %e %T %Y %Z' "$end_date" +%s 2>/dev/null) || {
      printf '%-40s ОШИБКА: не разобрана дата "%s"\n' "$host" "$end_date"
      problems=$((problems + 1))
      continue
    }
  fi

  days=$(( (end_ts - now) / 86400 ))

  if [[ "$issuer" == *"$PLACEHOLDER_CN"* ]]; then
    printf '%-40s ЗАГЛУШКА: настоящий сертификат ни разу не выпускался\n' "$host"
    problems=$((problems + 1))
  elif [ "$days" -lt "$THRESHOLD_DAYS" ]; then
    printf '%-40s ИСТЕКАЕТ через %s дн. — продление не сработало\n' "$host" "$days"
    problems=$((problems + 1))
  else
    printf '%-40s ok, %s дн.\n' "$host" "$days"
  fi
done

# Домен включённого стека, у которого нет ни одного сертификата, — отказ, а не
# тишина. Цикл выше обходит ФАЙЛЫ и поэтому не может заметить недостающий: нет
# файла — нет и итерации. Без этой проверки новый стек живёт с заглушкой ровно
# до тех пор, пока кто-нибудь не откроет его в браузере.
declared=0
while IFS= read -r domain; do
  [ -n "$domain" ] || continue
  declared=$((declared + 1))
  if [ ! -f "$CERTS_DIR/$domain-fullchain.crt" ]; then
    printf '%-40s НЕТ ФАЙЛА: домен объявлен в stack.conf, сертификата нет\n' "$domain"
    problems=$((problems + 1))
  fi
done < <(stacks_domains)

if [ "$declared" -eq 0 ]; then
  # Ни одного домена ни у одного включённого стека — почти наверняка сломанный
  # манифест или пустые stack.conf, а не машина без сайтов. Молчаливый успех
  # здесь был бы худшим исходом.
  echo "Предупреждение: ни один включённый стек не объявляет доменов" >&2
fi

if [ "$problems" -gt 0 ]; then
  echo
  echo "Проблемных сертификатов: $problems из ${#certs[@]}." >&2
  echo "Разбор: journalctl -u getssl-renew --since '-14 days'" >&2
  exit 1
fi

echo
echo "Проверено сертификатов: ${#certs[@]}. Все действительны дольше $THRESHOLD_DAYS дней."
