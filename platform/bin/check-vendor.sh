#!/usr/bin/env bash
#
# Сверка вендоренных слоёв с .vendor.lock: та ли версия платформы стоит на
# машине и не правил ли её кто-нибудь на месте.
#
# Зачем это нужно отдельной проверкой. Вендорная копия удобна тем, что машина
# самодостаточна, и опасна ровно тем же: правка платформы прямо на машине
# работает, выглядит нормально и исчезает при следующем обновлении слоя. Между
# правкой и пропажей проходят недели, и связать одно с другим уже некому.
#
#   ./platform/bin/check-vendor.sh   # ничего не меняет, ненулевой код при расхождении

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
LOCK="$ROOT_DIR/.vendor.lock"

# Нужен ровно ради sha256_file: голый `shasum` есть не везде.
# shellcheck source=platform/lib/lib-env.sh
. "$LIB_DIR/lib-env.sh"

problems=0
ok()   { printf '  [ok]   %s\n' "$1"; }
warn() { printf '  [!]    %s\n' "$1"; }
bad()  { printf '  [FAIL] %s\n' "$1"; problems=$((problems + 1)); }

# Режим разработки: слои подключены симлинками в рабочее пространство. Тогда
# сверять нечего — они и есть источник, разойтись не с чем.
if [ -L "$ROOT_DIR/platform" ]; then
  ok "platform подключена симлинком — режим разработки, вендорной копии нет"
  [ -f "$LOCK" ] && warn ".vendor.lock остался от вендорной копии — удалите, он вводит в заблуждение"
  exit 0
fi

if [ ! -f "$LOCK" ]; then
  bad "нет .vendor.lock — неизвестно, какой версией платформы пользуется машина"
  echo "         Завести: ./bin/vendor.sh <машина> из рабочего пространства" >&2
  exit 1
fi

ok "платформа $(grep '^platform_version=' "$LOCK" | cut -d= -f2), профиль $(grep '^profile_version=' "$LOCK" | cut -d= -f2)"

# Сверяем суммы. Читаем из lock, а не пересчитываем «как в vendor.sh»: вторая
# копия формулы разъезжается с первой молча, и проверка начинает докладывать о
# расхождении там, где его нет, — после чего её перестают читать.
# Инструмент проверяем ОДИН раз и до цикла. Иначе на каждый файл печатается и
# ошибка «нечем считать», и [FAIL] «изменён на месте»: отчёт на сотню строк, в
# котором настоящая причина стоит первой строкой и в нём тонет.
sha256_file /dev/null >/dev/null || {
  echo "Ошибка: проверить вендорную копию нечем." >&2
  echo "  Поставьте coreutils (sha256sum) или perl (shasum)." >&2
  exit 2
}

changed=0; missing=0
while read -r sum path; do
  case "$sum" in \#*|platform_version=*|profile_version=*|---) continue ;; esac
  [ -n "${path:-}" ] || continue
  f="$ROOT_DIR/$path"
  if [ ! -f "$f" ]; then
    bad "файл пропал: $path"; missing=$((missing + 1)); continue
  fi
  if [ "$(sha256_file "$f")" != "$sum" ]; then
    bad "изменён на месте: $path"; changed=$((changed + 1))
  fi
done < "$LOCK"

# Лишние файлы: слой мог обрасти чем-то, чего в манифесте нет. Это тоже правка
# на месте, только с другой стороны.
for layer in platform profile; do
  [ -d "$ROOT_DIR/$layer" ] || continue
  while IFS= read -r f; do
    rel="$layer/${f#./}"
    grep -qF "  $rel" "$LOCK" || bad "файл вне манифеста: $rel"
  done < <(cd "$ROOT_DIR/$layer" && find . -type f -not -name '.DS_Store')
done

if [ "$problems" -eq 0 ]; then
  echo "  Вендоренные слои соответствуют .vendor.lock."
  exit 0
fi
echo
echo "Расхождений: $problems. Правка вендоренного слоя пропадёт при следующем обновлении." >&2
echo "  Перенесите её в рабочее пространство и повторите ./bin/vendor.sh <машина>." >&2
exit 1
