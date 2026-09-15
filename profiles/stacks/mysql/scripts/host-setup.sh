#!/usr/bin/env bash
#
# Хостовая часть стека mysql: конфиг для тулкита _db, если он на машине есть.
#
# _db — ручные инструменты работы с базой (dbquery, dbconsole, dbdump). Его
# db.conf раньше появлялся побочным эффектом провижнинга MySQL; без этого шага
# dbquery.sh молча читал бы пустые значения.
#
# Тулкит опционален: машина без каталога _db/ пропускается молча, а не падает.

set -euo pipefail

CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

DB_DIR="${ROOT_DIR:?}/_db"
[ -d "$DB_DIR" ] || { echo "[ok] каталога _db/ нет — тулкит на этой машине не используется"; exit 0; }

# shellcheck source=platform/lib/lib-env.sh
. "$ROOT_DIR/platform/lib/lib-env.sh"
ENV_VARS=(); env_load_files "$ROOT_DIR/.env" "$ROOT_DIR/stacks/mysql/.env"

PW="$(env_get Mysql_Root_Password)"
NET="$(env_get Platform_Network)"
[ -n "$PW" ] || { echo "[FAIL] в stacks/mysql/.env нет Mysql_Root_Password"; exit 1; }

render() {
  cat <<INNER
# СГЕНЕРИРОВАН stacks/mysql/scripts/host-setup.sh из .env — правки перезапишутся.
DBNAME=mysql
DBUSER=root
DBPASS='${PW}'
DBHOST=localhost
DBDUMP=./dump.sql

DOCKER_MYSQLD_CONTAINER=mysqld
DOCKER_NETWORK=${NET}
DOCKER_COMPOSE_SERVICE=
INNER
}

if [ -f "$DB_DIR/db.conf" ] && [ "$(cat "$DB_DIR/db.conf")" = "$(render)" ]; then
  echo "[ok] _db/db.conf актуален"
elif [ "$CHECK_ONLY" -eq 1 ]; then
  echo "[FAIL] _db/db.conf отсутствует или разошёлся с .env — sudo ./host-setup"; exit 1
else
  render > "$DB_DIR/db.conf"
  # Внутри пароль root от общей СУБД.
  chmod 600 "$DB_DIR/db.conf"
  echo "[ok] _db/db.conf записан"
fi
