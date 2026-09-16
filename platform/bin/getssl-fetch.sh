#!/usr/bin/env bash

# Доставка getssl на машину: скачать закреплённую версию, сверить сумму,
# положить в state/bin/.
#
# Зачем отдельным шагом, а не копией в репозитории. getssl — чужой скрипт под
# GPL-3, и его копия в публичном MIT-репозитории неудобна и юридически, и по
# существу: копию правят на месте, правки забываются, а разойтись с upstream
# она успевает молча. Здесь в git лежит только getssl.lock — три строки.
#
# Почему state/, а не platform/. Это МАШИННЫЙ артефакт, как сертификаты и как
# ключ ACME-аккаунта: он скачан на этой машине, из сети, и в репозиторий его
# класть незачем. state/ у машины уже в .gitignore.
#
#   ./platform/bin/getssl-fetch.sh           # скачать, если нужно
#   ./platform/bin/getssl-fetch.sh --check   # ничего не менять, ненулевой код
#   ./platform/bin/getssl-fetch.sh --force   # перекачать поверх

set -uo pipefail

DIR0="$( cd -P "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
if [ -z "${ROOT_DIR:-}" ]; then
  ROOT_DIR="$( cd "$DIR0/../.." && pwd )"
  # На машине platform/ — симлинк в .stackyard/, и `cd -P` выше его уже
  # развернул: два уровня приводят не в машину, а в .stackyard. Тогда state/
  # заводится ВНУТРИ скачиваемого слоя и пропадает при следующем ./bootstrap,
  # а до того htpasswd, сертификаты и databases.yaml лежат не там, где их ищут
  # контейнеры. Обёртки в корне машины ROOT_DIR задают сами, но документация
  # каждого скрипта зовёт его как ./platform/bin/<имя>.sh — этот путь и чиним.
  [ "${ROOT_DIR##*/}" = .stackyard ] && ROOT_DIR="${ROOT_DIR%/*}"
fi
LIB_DIR="$( cd "$DIR0/../lib" && pwd )"
LOCK="$DIR0/../getssl.lock"

# shellcheck source=platform/lib/lib-env.sh
. "$LIB_DIR/lib-env.sh"

CHECK_ONLY=0; FORCE=0
for a in "$@"; do
  case "$a" in
    --check) CHECK_ONLY=1 ;;
    --force) FORCE=1 ;;
    *) echo "Неизвестный аргумент: $a" >&2; exit 2 ;;
  esac
done

[ -f "$LOCK" ] || { echo "Ошибка: нет $LOCK" >&2; exit 2; }

lock_get() { sed -n "s/^$1=//p" "$LOCK" | head -n 1; }
REPO=$(lock_get repo); VERSION=$(lock_get version); WANT_SUM=$(lock_get sha256)
for v in REPO VERSION WANT_SUM; do
  [ -n "${!v}" ] || { echo "Ошибка: в $LOCK не хватает поля ($v)" >&2; exit 2; }
done

DEST="$ROOT_DIR/state/bin/getssl"

# Сумма — единственный ответ на вопрос «тот ли это getssl». Ни тега, ни
# VERSION= внутри скрипта не хватает: `getssl -u` переписывает файл свежей
# версией, оставляя тег в lock прежним, и машина уезжает на код, которого никто
# не закреплял. Отсюда и сравнение здесь, а не только при скачивании.
have_sum=""
[ -f "$DEST" ] && have_sum=$(sha256_file "$DEST")

if [ "$have_sum" = "$WANT_SUM" ] && [ "$FORCE" -eq 0 ]; then
  echo "  [ok]   getssl $VERSION на месте ($DEST)"
  exit 0
fi

if [ "$CHECK_ONLY" -eq 1 ]; then
  if [ -z "$have_sum" ]; then
    echo "  [FAIL] нет $DEST — ./platform/bin/getssl-fetch.sh" >&2
  else
    echo "  [FAIL] $DEST не совпадает с getssl.lock ($VERSION)" >&2
    echo "         Так выглядит 'getssl -u', запущенный руками: скрипт обновил сам себя." >&2
    echo "         Вернуть закреплённый: ./platform/bin/getssl-fetch.sh --force" >&2
  fi
  exit 1
fi

# raw.githubusercontent по ТЕГУ, а не по ветке: ветка меняется под ногами, и
# сумма перестала бы сходиться на ровном месте.
URL="${REPO/github.com/raw.githubusercontent.com}/$VERSION/getssl"

command -v curl >/dev/null 2>&1 || { echo "Ошибка: нет curl — нечем скачать getssl" >&2; exit 2; }

TMP="$DEST.tmp.$$"
mkdir -p "$(dirname "$DEST")" || exit 2
trap 'rm -f "$TMP"' EXIT

echo "  ... качаю getssl $VERSION"
if ! curl -fsSL --max-time 60 -o "$TMP" "$URL"; then
  echo "Ошибка: не скачался $URL" >&2
  exit 2
fi

# Сверяем ДО того, как файл встанет на место. Иначе при подменённом ответе
# машина получила бы рабочий по виду getssl, а узнала бы об этом в лучшем
# случае при следующей проверке.
got_sum=$(sha256_file "$TMP") || exit 2
if [ "$got_sum" != "$WANT_SUM" ]; then
  echo "Ошибка: сумма скачанного не совпадает с getssl.lock." >&2
  echo "  ожидалась: $WANT_SUM" >&2
  echo "  получена:  $got_sum" >&2
  echo "  Если версию сдвигали намеренно — обновите sha256 в platform/getssl.lock." >&2
  exit 1
fi

chmod +x "$TMP" && mv -f "$TMP" "$DEST" || exit 2
trap - EXIT
echo "  [ok]   getssl $VERSION -> $DEST"
