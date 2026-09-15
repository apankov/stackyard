#!/usr/bin/env bash
#
# Хостовая часть стека php-fpm: шим /usr/local/bin/php.
#
# `php` на хосте должен означать «PHP 5.6 в контейнере»: современного php на
# машине нет и быть не должно, а утилиты сайтов (composer, миграции) зовут
# именно `php`. Шим ходит в ту же сеть, что и сайты, поэтому из него видны
# контейнеры СУБД по именам.
#
# Живёт в стеке, а не в платформе: платформа не обязана знать, что такое PHP.
# Вызывается из platform/bin/host-setup.sh, потому что этот файл здесь есть.

set -euo pipefail

CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

# shellcheck source=platform/lib/lib-env.sh
. "${ROOT_DIR:?}/platform/lib/lib-env.sh"
ENV_VARS=(); env_load_files "$ROOT_DIR/.env" "$ROOT_DIR/stacks/php-fpm/.env"

VHOSTS="$(env_get Platform_Vhosts_Dir)"
NET="$(env_get Platform_Network)"
SHIM=/usr/local/bin/php

[ -n "$VHOSTS" ] && [ -n "$NET" ] || {
  echo "[FAIL] шим не собрать: в .env нет Platform_Vhosts_Dir и/или Platform_Network"; exit 1; }

render() {
  cat <<INNER
#!/bin/bash
# СГЕНЕРИРОВАН stacks/php-fpm/scripts/host-setup.sh — правки будут перезаписаны.
docker run -it --rm \\
    -e HOME="\$HOME" \\
    -u \$(id -u):\$(id -g) \\
    -v "\$HOME":"\$HOME" \\
    -v "\$PWD":"\$PWD" \\
    -v ${VHOSTS}:${VHOSTS} \\
    --network ${NET} \\
    -w "\$PWD" \\
    php5.6-fpm \\
    php5 "\$@"
exit \$?
INNER
}

if [ -f "$SHIM" ] && [ "$(cat "$SHIM")" = "$(render)" ]; then
  echo "[ok] $SHIM на месте и актуален"
elif [ "$CHECK_ONLY" -eq 1 ]; then
  echo "[FAIL] $SHIM отсутствует или разошёлся с .env — sudo ./host-setup"; exit 1
else
  render > "$SHIM"; chmod +x "$SHIM"
  echo "[ok] $SHIM записан"
fi
