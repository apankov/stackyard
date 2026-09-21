#!/usr/bin/env bash
#
# Validation of a database order against THIS provider. Called by the platform
# (check_db_decl) for every consumer stack; STACK_NAME, DB_PREFIX and ROOT_DIR
# are in the environment.
#
# It lives here and not in the platform because the list of valid privileges is
# knowledge about MySQL. A platform that knows the word GRANT would again be
# unportable to a machine with a different DBMS -- exactly what we moved away
# from.
#
# Prints one line per problem and stays silent when there is none.

set -uo pipefail

# Both libraries: lib-stacks knows which root the stack lives in, lib-env knows
# how to read a .env. Assembling the paths by hand here was doubly wrong: the
# profile stack.conf was loaded AFTER the machine one and shadowed it -- the
# reverse of stack_dir, where the machine root comes first. A stack copied out
# of the profile and edited would be validated against the old profile value.
# shellcheck source=platform/lib/lib-stacks.sh
. "${ROOT_DIR:?}/platform/lib/lib-stacks.sh"
# shellcheck source=platform/lib/lib-env.sh
. "$ROOT_DIR/platform/lib/lib-env.sh"
s="${STACK_NAME:?}"; prefix="${DB_PREFIX:?}"
ENV_VARS=(); env_load_files "$ROOT_DIR/.env" "$(stack_env_file "$s")" "$(stack_conf_file "$s")"

user="$(env_get "${prefix}_User")"
[ -n "$user" ] || exit 0

# The user name length limit in MySQL 5.5 is 16 characters (32 in 8.0). A
# longer name is truncated at creation, and the declared one stops matching the
# existing one: the initializer creates the user afresh on every run and reports
# a password divergence every time.
[ "${#user}" -le 16 ] || \
  printf 'stack %s: user name %s is longer than 16 characters -- MySQL 5.5 will truncate it\n' "$s" "$user"

# Privileges are parsed here rather than in the container: otherwise a typo
# surfaces as a MySQL syntax error in the log of a one-shot container that from
# the outside looks simply like `exited`.
#
# Split on COMMAS only, never on whitespace. Half the privileges MySQL has are
# two words -- ALL PRIVILEGES, CREATE VIEW, LOCK TABLES, CREATE TEMPORARY
# TABLES -- and splitting on spaces turns each of them into tokens that match
# nothing. The check then reports a correct declaration as an unrecognized
# privilege, which is worse than not checking: it teaches you to ignore it.
# `|| [ -n "$g" ]` because the producer does not end with a newline: env_get
# uses printf without one, so a single-element list is one unterminated line
# and a bare `read` returns non-zero on it. The loop body would then never run
# at all, and EVERY declaration with one privilege would pass unchecked.
while IFS= read -r g || [ -n "$g" ]; do
  g="$(printf '%s' "$g" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | tr 'a-z' 'A-Z')"
  [ -n "$g" ] || continue
  case "$g" in
    SELECT|INSERT|UPDATE|DELETE|CREATE|DROP|INDEX|ALTER|REFERENCES|TRIGGER|EVENT| \
    EXECUTE|"LOCK TABLES"|"CREATE VIEW"|"SHOW VIEW"|"CREATE ROUTINE"|"ALTER ROUTINE"|"CREATE TEMPORARY TABLES") ;;
    ALL|"ALL PRIVILEGES")
      # On one database ALL does not include GRANT OPTION, but it does include
      # DROP and ALTER: a stolen application password then drops the schema.
      printf 'stack %s: %s_Grants=ALL includes DROP and ALTER -- list what you need explicitly\n' "$s" "$prefix" ;;
    *) printf 'stack %s: unrecognized privilege in %s_Grants: %s\n' "$s" "$prefix" "$g" ;;
  esac
done < <(env_get "${prefix}_Grants" "SELECT,INSERT,UPDATE,DELETE" | tr ',' '\n')
