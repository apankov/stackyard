#!/usr/bin/env bash

# Rotating the platform nginx's logs in /var/log/nginx: what
# devbox-nginx-logrotate.service runs every night, and the same thing by hand.
# One path for the timer and for a person: were they two, a manual run would
# test something other than what runs at night.
#
# Why the platform does it: nginx writes to a bind mount on the host, and the
# host has no nginx package, so there is no /etc/logrotate.d/nginx. Without
# this the logs grow until the disk is full — and access logs hold the IP and
# time of every request, so how long they are kept is a privacy matter too.
#
#   sudo ./platform/bin/nginx-logrotate.sh        # as the timer does
#   sudo ./platform/bin/nginx-logrotate.sh -f     # force a rotation now
#   sudo ./platform/bin/nginx-logrotate.sh -d     # logrotate's plan, no changes
#   ./platform/bin/nginx-logrotate.sh --print-config   # the config in force; no root
#
# Any other arguments go to logrotate as they are.

set -euo pipefail

DIR0="$( cd -P "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# The MACHINE's directory, not the platform's. Normally set by a wrapper in the
# machine root; the fallback is two levels up from platform/bin, so the script
# also works when invoked directly — which is how the unit invokes it.
if [ -z "${ROOT_DIR:-}" ]; then
  ROOT_DIR="$( cd "$DIR0/../.." && pwd )"
  # On a machine, platform/ is a symlink into .stackyard/, and the `cd -P`
  # above has already resolved it: two levels up lands inside .stackyard
  # rather than in the machine, where there is no .env. Everything from
  # .stackyard on is cut.
  ROOT_DIR="${ROOT_DIR%%/.stackyard/*}"; ROOT_DIR="${ROOT_DIR%/.stackyard}"
fi
LIB_DIR="$( cd "$DIR0/../lib" && pwd )"
ENV_FILE="$ROOT_DIR/.env"
TEMPLATE="$DIR0/../logrotate/nginx.conf"

# shellcheck source=platform/lib/lib-env.sh
. "$LIB_DIR/lib-env.sh"

if [ ! -f "$ENV_FILE" ]; then
  echo "Error: environment file '$ENV_FILE' not found" >&2
  exit 2
fi
env_load_files "$ENV_FILE"
DAYS=$(nginx_log_days) || exit 2

render() {
  sed -e "s#@ROTATE@#$((DAYS - 1))#g" -e "s#@DAYS@#${DAYS}#g" "$TEMPLATE"
}

if [ "${1-}" = "--print-config" ]; then
  render
  exit 0
fi

[ "$(id -u)" -eq 0 ] || { echo "Error: root is required (sudo $0 $*)" >&2; exit 2; }

# Resolved here rather than left to fail inside logrotate: a missing logrotate
# is "no such file" from systemd, and a missing docker is a postrotate error
# AFTER the files were renamed — nginx then keeps writing into yesterday's file.
for cmd in logrotate docker; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "Error: no $cmd command (logrotate is installed by sudo ./host-setup)" >&2
    exit 2
  }
done

# 077: the state file and the compressed generations are root's alone. The
# generations of an access log hold visitors' IPs, and logrotate treats a
# world-readable state as a threat to its lock and warns on every run.
umask 077
mkdir -p "$NGINX_LOGROTATE_DIR"
chmod 700 "$NGINX_LOGROTATE_DIR"

# The first run forces a rotation. logrotate only records a file it has not
# seen and rotates it a day later; without -f, the history a machine's logs
# already hold — months of it, where the platform has just taken over — would
# stay in the live file a day longer, and until then there would be no
# generation at all, which check-nginx-logs.sh cannot tell from a rotation
# that never runs. systemd.sh starts this once at install for the same reason.
FORCE=()
[ -f "$NGINX_LOGROTATE_DIR/state" ] || FORCE=(-f)

conf="$NGINX_LOGROTATE_DIR/nginx.conf"
render > "$conf.tmp"
chmod 644 "$conf.tmp"
mv -f "$conf.tmp" "$conf"

exec logrotate ${FORCE[@]+"${FORCE[@]}"} "$@" --state "$NGINX_LOGROTATE_DIR/state" "$conf"
