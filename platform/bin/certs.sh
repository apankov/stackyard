#!/usr/bin/env bash

# Подготовка TLS: per-host конфиги getssl из шаблона и заглушки сертификатов.
#
# Заглушки нужны ДО того, как nginx увидит новый vhost: `listen 443 ssl` без
# существующего файла сертификата — это отказ старта, а с `restart: always`
# краш-луп, уносящий ВСЕ vhost'ы (CLAUDE.md §3.1, §6).
#
# Список доменов берётся из Domains= включённых стеков, а не из набора
# каталогов в getssl-config/: два отдельных списка разъезжаются незаметно в обе
# стороны — домен без стека продлевается вечно, стек без домена остаётся с
# заглушкой до первого посетителя.
#
# Запускать от владельца репозитория, НЕ от root: под тем же пользователем
# работает таймер getssl и должен уметь перезаписать заглушку.
#
#   ./platform/bin/certs.sh            подготовить
#   ./platform/bin/certs.sh --check    только сказать, чего не хватает (код 1)

set -euo pipefail

DIR0="$( cd -P "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# Каталог МАШИНЫ, а не платформы. Обычно его задаёт обёртка ./stack в корне
# машины; запасной вариант — на два уровня вверх от platform/bin, чтобы скрипт
# работал и при прямом вызове.
ROOT_DIR="${ROOT_DIR:-$( cd "$DIR0/../.." && pwd )}"
LIB_DIR="$( cd "$DIR0/../lib" && pwd )"
ENV_FILE="$ROOT_DIR/.env"

# shellcheck source=platform/lib/lib-stacks.sh
. "$LIB_DIR/lib-stacks.sh"

CHECK_ONLY=0
case "${1:-}" in
  --check) CHECK_ONLY=1 ;;
  "")      ;;
  *)       echo "Неизвестный аргумент: $1 (ожидался --check)" >&2; exit 2 ;;
esac

[ -f "$ENV_FILE" ] || { echo "Ошибка: нет $ENV_FILE" >&2; exit 2; }

Platform_Deploy_Dir=$(grep -E '^Platform_Deploy_Dir=' "$ENV_FILE" | head -n 1 | cut -d '=' -f2- | tr -d '"'"'" || true)
[ -n "$Platform_Deploy_Dir" ] || { echo "Ошибка: Platform_Deploy_Dir не задан в $ENV_FILE" >&2; exit 2; }

CERTS_DIR="$ROOT_DIR/state/certs"
GETSSL_DIR="$ROOT_DIR/state/getssl-config"
# Шаблон и общий конфиг — платформенные, они одинаковы у всех машин.
# Результат работы getssl и ключ ACME-аккаунта — машинные, в state/.
TEMPLATE="$ROOT_DIR/platform/getssl-config/getssl.cfg.template"
SHARED_CFG="$ROOT_DIR/platform/getssl-config/getssl.cfg"

problems=0
note() { printf '  %s\n' "$1"; }
lack() { printf '  [нет] %s\n' "$1"; problems=$((problems + 1)); }

[ -f "$TEMPLATE" ] || { echo "Ошибка: нет шаблона $TEMPLATE" >&2; exit 2; }

# ---------------------------------------------- 0. изоляция ACME-аккаунта
#
# Ключ ACME-аккаунта обязан быть СВОИМ у каждой машины, и это не гигиена.
# Один аккаунт на всех клиентов означает общие лимиты Let's Encrypt
# (зациклившееся продление у одного жжёт квоту другому) и общий доступ на
# отзыв чужих сертификатов. Заметить это нельзя ничем, кроме проверки здесь:
# работает такая конфигурация идеально ровно до первого инцидента.
#
# Отказ, а не предупреждение: ключ, лежащий в платформе, размножится по всем
# машинам следующей же вендорной копией.
if [ -e "$ROOT_DIR/platform/getssl-config/account.key" ]; then
  echo "ОТКАЗ: platform/getssl-config/account.key существует." >&2
  echo "  Платформа раздаётся всем машинам — ключ ACME-аккаунта в ней означает" >&2
  echo "  один аккаунт Let's Encrypt на всех: общие лимиты и общий отзыв." >&2
  echo "  Аккаунт машины живёт в state/getssl-config/account.key." >&2
  exit 2
fi

echo "== общий конфиг getssl"
mkdir -p "$GETSSL_DIR"
# Материализуем копией, а не симлинком: getssl читает конфиг относительно cwd,
# и симлинк в платформу пережил бы не всякую вендорную копию.
if [ -f "$GETSSL_DIR/getssl.cfg" ] && cmp -s "$SHARED_CFG" "$GETSSL_DIR/getssl.cfg"; then
  note "getssl.cfg совпадает с платформенным"
elif [ "$CHECK_ONLY" -eq 1 ]; then
  lack "getssl.cfg отсутствует или разошёлся с платформенным"
else
  cp "$SHARED_CFG" "$GETSSL_DIR/getssl.cfg"
  note "getssl.cfg записан из платформы"
fi

# --------------------------------------------------- 1. конфиги getssl

echo "== конфиги getssl"
while IFS= read -r spec; do
  [ -n "$spec" ] || continue
  domain="$(domain_primary "$spec")"
  # Алиасы уходят в тот же сертификат строкой SANS. Пустая строка, когда их
  # нет: getssl трактует SANS="" как «дополнительных имён нет», а забытая
  # строка оставила бы www-имя с сертификатом на голый домен.
  sans="$(domain_sans "$spec" | tr ' ' ',')"
  cfg="$GETSSL_DIR/$domain/getssl.cfg"
  want=$(sed -e "s|@DOMAIN@|$domain|g" -e "s|@DEPLOY_DIR@|$Platform_Deploy_Dir|g" \
             -e "s|@SANS@|$sans|g" "$TEMPLATE")
  if [ -f "$cfg" ] && [ "$(cat "$cfg")" = "$want" ]; then
    note "$domain — ok"
  elif [ "$CHECK_ONLY" -eq 1 ]; then
    lack "$domain — конфига нет или он разошёлся с шаблоном"
  else
    mkdir -p "$GETSSL_DIR/$domain"
    printf '%s\n' "$want" > "$cfg"
    note "$domain — записан $cfg"
  fi
done < <(stacks_domain_specs)

# Конфиги без стека. Не отказ, но и не норма: продлевать сертификат для домена,
# которого больше нет ни в одном stack.conf, значит тратить лимиты Let's Encrypt
# и получать письма про домены-призраки.
domains_now=" $(stacks_domains | tr '\n' ' ') "
for d in "$GETSSL_DIR"/*/; do
  [ -d "$d" ] || continue
  name=$(basename "$d")
  case "$domains_now" in
    *" $name "*) ;;
    *) printf '  [!] %s — конфиг есть, а стека с таким доменом нет\n' "$name" ;;
  esac
done

# ------------------------------------------------------- 2. заглушки

echo
echo "== заглушки сертификатов"
[ "$CHECK_ONLY" -eq 1 ] || mkdir -p "$CERTS_DIR"

# Генерация dhparam на пустом месте занимает минуты, поэтому только когда файла
# действительно нет.
if [ ! -f "$CERTS_DIR/dhparam.pem" ]; then
  if [ "$CHECK_ONLY" -eq 1 ]; then
    lack "dhparam.pem"
  else
    note "генерация dhparam.pem (4096 bit), это пара минут"
    openssl dhparam -out "$CERTS_DIR/dhparam.pem" 4096 2>/dev/null
  fi
fi

if [ ! -f "$CERTS_DIR/nginx-selfsigned.key" ]; then
  if [ "$CHECK_ONLY" -eq 1 ]; then
    lack "nginx-selfsigned.key"
  else
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
      -subj "/C=US/ST=New York/L=New York City/O=devbox/OU=devbox/CN=devbox" \
      -keyout "$CERTS_DIR/nginx-selfsigned.key" \
      -out "$CERTS_DIR/nginx-selfsigned.crt"
    note "создан базовый самоподписанный сертификат"
  fi
fi

# Файлы, которых ждут vhost'ы. Источник правды — сами конфиги nginx:
# ssl_certificate/ssl_certificate_key могут называть что угодно, и выводить
# имена из доменов означало бы гадать.
#
# Ключ от сертификата отличаем по расширению, а не по порядку двух проходов:
# `grep 'ssl_certificate\s'` матчит и строки с ssl_certificate_key, и тогда
# результат зависит от того, какой цикл отработал первым.
while IFS= read -r path; do
  [ -n "$path" ] || continue
  filename=$(basename "$path")
  [ -f "$CERTS_DIR/$filename" ] && continue
  if [ "$CHECK_ONLY" -eq 1 ]; then
    lack "$filename (ждёт vhost)"
  else
    case "$filename" in
      *.key) cp "$CERTS_DIR/nginx-selfsigned.key" "$CERTS_DIR/$filename" ;;
      *)     cp "$CERTS_DIR/nginx-selfsigned.crt" "$CERTS_DIR/$filename" ;;
    esac
    note "заглушка: $filename"
  fi
done < <(stacks_cert_paths | awk '{print $2}' | tr -d ';' | sort -u)

# ------------------------------------------------- 3. ACME-аккаунт

# Проверка, а не создание. Ключ аккаунта getssl заводит сам при первом запуске,
# но заводит его ОТНОСИТЕЛЬНО текущего каталога (ACCOUNT_KEY="./getssl-config/
# account.key" в общем getssl.cfg). Запуск не из platform/ создаёт новый
# ACME-аккаунт и теряет существующий — отказ тихий, поэтому его называют вслух.
echo
echo "== ACME-аккаунт"
if [ -f "$GETSSL_DIR/account.key" ]; then
  # Права важны не меньше наличия: по этому ключу отзывают сертификаты машины.
  perm=$(stat -c '%a' "$GETSSL_DIR/account.key" 2>/dev/null || stat -f '%OLp' "$GETSSL_DIR/account.key")
  case "$perm" in
    600|400) note "account.key на месте ($perm)" ;;
    *) lack "account.key имеет права $perm вместо 600 — chmod 600 $GETSSL_DIR/account.key" ;;
  esac
else
  printf '  [!] %s\n' "нет $GETSSL_DIR/account.key — getssl заведёт новый аккаунт при следующем запуске"
  printf '  %s\n' "Если аккаунт был, найдите ключ и положите сюда, а не выпускайте новый."
fi

if [ "$problems" -gt 0 ]; then
  echo
  echo "Не хватает: $problems. Запустите без --check." >&2
  exit 1
fi
echo
echo "Готово."
