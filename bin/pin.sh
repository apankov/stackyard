#!/usr/bin/env bash
#
# Закрепить машину на текущей версии stackyard: переписать её stackyard.lock.
#
# Это и есть «обновить платформу у клиента». Обновление всегда для ОДНОЙ
# названной машины: команды «обновить всех» нет намеренно — клиент, которого не
# трогали, продолжает работать на своей версии сколько угодно долго.
#
#   ./bin/pin.sh ~/dev/machines/client-acme
#   ./bin/pin.sh ~/dev/machines/client-acme --version v0.2.0   # закрепить старую

set -euo pipefail

ROOT="$( cd -P "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
DEST=""; WANT=""

while [ $# -gt 0 ]; do
  case "$1" in
    # ${2-} и явная проверка, а не голый "$2": под set -u забытое значение
    # даёт «$2: unbound variable» — сообщение про внутренности скрипта вместо
    # сообщения про то, что пользователь недописал в командной строке.
    --version) WANT="${2-}"; [ -n "$WANT" ] || { echo "Ошибка: --version требует значение" >&2; exit 2; }; shift 2 ;;
    -*) echo "Неизвестный аргумент: $1" >&2; exit 2 ;;
    *)  DEST="$1"; shift ;;
  esac
done
[ -n "$DEST" ] || { echo "Использование: $0 <путь-к-машине> [--version <тег>]" >&2; exit 2; }
LOCK="$DEST/stackyard.lock"
[ -f "$LOCK" ] || { echo "Ошибка: нет $LOCK — это точно машина stackyard?" >&2; exit 2; }

if [ -n "$WANT" ]; then
  COMMIT="$( cd "$ROOT" && git rev-parse "$WANT^{commit}" )"
  VERSION="$WANT"
else
  VERSION="v$(cat "$ROOT/platform/VERSION")"
  COMMIT="$( cd "$ROOT" && git rev-parse HEAD )"
  # Незакоммиченные правки в платформе до машины не доедут: bootstrap забирает
  # именно коммит. Молчать об этом нельзя — человек увидел бы «обновил» и не
  # получил своей правки.
  if ! ( cd "$ROOT" && git diff --quiet HEAD -- platform profiles ); then
    echo "Предупреждение: в platform/ или profiles/ есть незакоммиченные правки." >&2
    echo "  До машины доедет только закоммиченное ($COMMIT)." >&2
  fi
fi

OLD_V="$(grep -E '^version=' "$LOCK" | cut -d= -f2-)"
OLD_C="$(grep -E '^commit='  "$LOCK" | cut -d= -f2-)"

# Машинные файлы платформы (bootstrap и обёртки) обновляются ДО проверки
# версии: они лежат в git машины и потому способны отстать независимо от того,
# менялась ли версия. Ровно так машина и осталась со старым сообщением обёртки
# после починки — pin.sh выходил раньше, чем до них доходило.
if ! cmp -s "$ROOT/templates/machine/bootstrap" "$DEST/bootstrap"; then
  cp "$ROOT/templates/machine/bootstrap" "$DEST/bootstrap"
  chmod +x "$DEST/bootstrap"
  echo "  bootstrap обновлён из шаблона"
fi

# Обёртки — по той же причине, что bootstrap: они лежат в git машины, значит
# способны отстать. Обновляем только существующие: набор точек входа у машины
# свой, и заводить здесь новые — не дело обновления версии.
for w in stack:stack.sh dc:docker-compose.sh host-setup:host-setup.sh certs:certs.sh registry:registry.sh; do
  name="${w%%:*}"; target="${w#*:}"
  [ -f "$DEST/$name" ] || continue
  rendered="$(sed "s/@TARGET@/$target/g" "$ROOT/templates/machine/wrapper")"
  [ "$(cat "$DEST/$name")" = "$rendered" ] && continue
  printf '%s\n' "$rendered" > "$DEST/$name"
  chmod +x "$DEST/$name"
  echo "  обёртка $name обновлена из шаблона"
done


if [ "$OLD_C" = "$COMMIT" ]; then
  echo "Машина уже закреплена на $VERSION ($COMMIT)."
  exit 0
fi

# Что именно приедет. Дифф платформы показывается ДО правки lock: решение
# обновляться принимается по нему, а не по номеру версии.
echo "== что изменится в платформе"
( cd "$ROOT" && git --no-pager diff --stat "$OLD_C..$COMMIT" -- platform profiles 2>/dev/null ) \
  || echo "  (старый коммит $OLD_C в этом репозитории не найден)"

python3 - "$LOCK" "$VERSION" "$COMMIT" <<'PY'
import io, re, sys
lock, version, commit = sys.argv[1], sys.argv[2], sys.argv[3]
s = io.open(lock, encoding='utf-8').read()
s = re.sub(r'^version=.*$', 'version=' + version, s, flags=re.M)
s = re.sub(r'^commit=.*$',  'commit='  + commit,  s, flags=re.M)
io.open(lock, 'w', encoding='utf-8').write(s)
PY

# bootstrap — единственный файл платформы, который лежит в git машины (иначе
# машине нечем было бы забрать платформу). Значит, он единственный, кто может
# отстать. Обновляем его тем же действием, что и версию: отдельный шаг, о
# котором надо помнить, рано или поздно забудут.
echo
echo "Закреплено: $OLD_V ($OLD_C) -> $VERSION ($COMMIT)"
echo "Дальше в машине: ./bootstrap && ./stack --check, затем git commit stackyard.lock"
