#!/usr/bin/env bash

# Checking the RESULT of the nginx log rotation, not the mechanism.
#
# A rotation that stopped running looks exactly like one with nothing to do:
# logrotate is quiet both when it worked and when it never ran. So the files
# themselves are looked at:
#
#   * a live log with content not written to for 3 days — a nightly run has
#     passed it by, since `daily` rotates every non-empty file it has seen;
#   * rotated generations exist, none newer than 3 days, while live logs have
#     content — the rotation has stopped (the first point misses this on a busy
#     machine: its live logs are written every second);
#   * no generation at all while live logs have content, and the rotation has
#     either never run or has not run for 2 days — the state directory is
#     rewritten by every run, and its age is readable without root;
#   * a generation older than Platform_Nginx_Log_Days + 1 — the retention is
#     not kept (a day of slack: a generation lives until the next run);
#   * a file nginx writes that matches none of the rotated patterns — it grows
#     without bound, whatever the timer does.
#
# 3 days rather than 2 for the first two: a file seen for the first time is
# recorded and rotated only at the run after, and a missed night is the
# timer's Persistent= catching up, not a failure.
#
# Exit codes: 0 ok, 1 problems, 2 could not check. A non-zero code fails the
# unit, and OnFailure reports it.
#
#   ./platform/bin/check-nginx-logs.sh

set -uo pipefail

DIR0="$( cd -P "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# The MACHINE's directory: see nginx-logrotate.sh.
if [ -z "${ROOT_DIR:-}" ]; then
  ROOT_DIR="$( cd "$DIR0/../.." && pwd )"
  ROOT_DIR="${ROOT_DIR%%/.stackyard/*}"; ROOT_DIR="${ROOT_DIR%/.stackyard}"
fi
LIB_DIR="$( cd "$DIR0/../lib" && pwd )"
ENV_FILE="$ROOT_DIR/.env"

# shellcheck source=platform/lib/lib-env.sh
. "$LIB_DIR/lib-env.sh"

if [ ! -f "$ENV_FILE" ]; then
  echo "Error: environment file '$ENV_FILE' not found" >&2
  exit 2
fi
env_load_files "$ENV_FILE"
DAYS=$(nginx_log_days) || exit 2

if [ ! -d "$NGINX_LOG_DIR" ]; then
  echo "Error: no $NGINX_LOG_DIR — the platform nginx has never run on this machine" >&2
  exit 2
fi
if ! [ -r "$NGINX_LOG_DIR" ] || ! [ -x "$NGINX_LOG_DIR" ]; then
  echo "Error: $NGINX_LOG_DIR cannot be listed as $(id -un)" >&2
  exit 2
fi

# A rotated generation: the name plus dateext's -YYYYMMDD, maybe .gz.
GEN='*-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]'
generations() {
  find "$NGINX_LOG_DIR" -maxdepth 1 -type f \( -name "$GEN" -o -name "$GEN.gz" \) "$@"
}
# A live log: what the config's patterns match.
live() {
  find "$NGINX_LOG_DIR" -maxdepth 1 -type f -size +0 \
    \( -name '*-access' -o -name '*-error' -o -name '*.log' \) "$@"
}
count() { grep -c . || true; }

problems=0
fail() { echo "  [FAIL] $1"; problems=$((problems + 1)); }
list() { while IFS= read -r f; do [ -n "$f" ] && echo "         ${f##*/}"; done; }

live_n=$(live | count)

stuck=$(live -mtime +2)
if [ -n "$stuck" ]; then
  fail "live logs with content untouched for 3 days — a nightly run passed them by:"
  printf '%s\n' "$stuck" | list
fi

gen_all=$(generations | count)
gen_recent=$(generations -mtime -3 | count)
if [ "$live_n" -gt 0 ] && [ "$gen_all" -gt 0 ] && [ "$gen_recent" -eq 0 ]; then
  fail "no generation newer than 3 days while $live_n live logs have content — the rotation has stopped"
fi
if [ "$live_n" -gt 0 ] && [ "$gen_all" -eq 0 ]; then
  if [ ! -d "$NGINX_LOGROTATE_DIR" ]; then
    fail "the rotation has never run ($NGINX_LOGROTATE_DIR does not exist), and $live_n live logs have content"
  elif [ -n "$(find "$NGINX_LOGROTATE_DIR" -maxdepth 0 -mtime +1)" ]; then
    fail "no generation at all, and the rotation has not run for 2 days"
  fi
fi

stale=$(generations -mtime +"$DAYS")
if [ -n "$stale" ]; then
  fail "generations older than $((DAYS + 1)) days — Platform_Nginx_Log_Days=$DAYS is not kept:"
  printf '%s\n' "$stale" | list
fi

# Everything in the directory that is neither a rotated name nor a generation.
# Empty files too: a vhost that has not logged yet still has a name that will
# never be rotated.
unrotated=$(find "$NGINX_LOG_DIR" -maxdepth 1 -type f \
  ! -name '*-access' ! -name '*-error' ! -name '*.log' ! -name "$GEN" ! -name "$GEN.gz")
if [ -n "$unrotated" ]; then
  fail "files named outside the convention (<name>-access, <name>-error, *.log) are never rotated:"
  printf '%s\n' "$unrotated" | list
fi

if [ "$problems" -gt 0 ]; then
  echo
  echo "  journalctl -u devbox-nginx-logrotate --since '-7 days'"
  echo "  sudo $ROOT_DIR/platform/bin/nginx-logrotate.sh -d     # the plan, no changes"
  exit 1
fi

echo "  [ok]   nginx logs: $live_n live with content, $gen_recent generations from the last 3 days, none older than $((DAYS + 1)) days"
exit 0
