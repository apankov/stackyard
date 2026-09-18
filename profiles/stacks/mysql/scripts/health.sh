#!/usr/bin/env bash
#
# Liveness of the shared MySQL for `stack.sh --check`.
#
# We ask the running server instead of looking at files: the config on disk can
# be correct while the image reads its configs from a different directory, and
# then sql_mode is not the declared one on a container that looks perfectly
# healthy.
#
# Contract: no root, changes nothing, finishes within 10 seconds, and the first
# line of output becomes the reason in the report. STACK_DIR and ROOT_DIR are in
# the environment.

set -uo pipefail

# Through lib-env.sh rather than grep: the password lives in the stack's .env,
# and lib-env.sh is the only thing that knows about expanding ${...} and
# stripping quotes. A one-liner would return the password with the quotes still
# on it, and health.sh would report a dead database against a live one.
#
# The library path is platform/lib/. A path from an older layout once sat here,
# and the check failed on EVERY `--check` run with "No such file or directory".
# The neighbouring stack scripts (check-decl.sh, host-setup.sh, backup-dump.sh)
# had the right path -- the typo was in exactly one place and survived because
# its effect looked like "the stack does not answer" rather than a broken
# script.
#
# shellcheck source=platform/lib/lib-stacks.sh
. "${ROOT_DIR:?}/platform/lib/lib-stacks.sh"
# shellcheck source=platform/lib/lib-env.sh
. "$ROOT_DIR/platform/lib/lib-env.sh"

# The stack's .env comes through stack_env_file, not from STACK_DIR. For a
# profile stack STACK_DIR points into profile/, where no .env lives by
# construction: the secret belongs to the machine. With STACK_DIR there the
# check would lie "no Mysql_Root_Password" against a healthy file -- and a
# permanently red block stops being read at all, real findings included.
ENV_VARS=(); env_load_files "$ROOT_DIR/.env" "$(stack_env_file mysql)"

PW="$(env_get Mysql_Root_Password)"
[ -n "$PW" ] || { echo "stacks/mysql/.env has no Mysql_Root_Password"; exit 1; }

# The password goes through MYSQL_PWD rather than an argument: anything in argv
# is visible in `ps` to every process in the container.
q() { docker exec -e MYSQL_PWD="$PW" mysqld mysql -uroot -N -B -e "$1" 2>/dev/null; }

q 'SELECT 1' >/dev/null || { echo "mysqld does not answer a query"; exit 1; }

# We check the effective mode. A forgotten or unapplied sql_mode line breaks
# individual queries in legacy code rather than the connection -- a failure that
# looks like an application bug, not like a misconfigured DBMS.
mode="$(q 'SELECT @@GLOBAL.sql_mode')"
case "$mode" in
  *ONLY_FULL_GROUP_BY*) echo "sql_mode contains ONLY_FULL_GROUP_BY -- legacy queries will fail: $mode"; exit 1 ;;
esac

echo "mysqld answers, sql_mode=${mode:-<empty>}"
