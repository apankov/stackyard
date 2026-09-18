#!/usr/bin/env bash
#
# Dumps and restores for the shared PostgreSQL. Called by the platform
# (platform/bin/{backup,check-backups,backup-restore}.sh).
#
# It lives here and not in the platform because pg_dump is knowledge about
# Postgres. A platform that knew these commands would need a fork for every
# machine with a different DBMS -- i.e. it would bring back the very copy of the
# platform we were moving away from.
#
#   check                                  is the DBMS answering? code and reason on stderr
#   list                                   database names, one per line
#   dump <db>                              dump of the database on stdout, already compressed
#   globals                                roles and grants on stdout; empty is legitimate
#   ext                                    the dump file's extension
#   detect <file>                          the format in one word
#   inspect <format> <file>                show the contents
#   restore <format> <target> <file> <clean> load a dump

set -uo pipefail

C=postgres
x() { docker exec "$@"; }

case "${1:-}" in
  check)
    x "$C" sh -c 'pg_isready -U $POSTGRES_USER -d postgres' >/dev/null 2>&1 \
      || { echo "container $C does not answer pg_isready" >&2; exit 1; }
    ;;

  list)
    # We ask the DBMS itself: a hardcoded list would mean the next database
    # created silently goes without a backup.
    x -e SQL="SELECT datname FROM pg_database WHERE NOT datistemplate AND datname <> 'postgres' ORDER BY datname" "$C" \
      sh -c 'PGPASSWORD=$POSTGRES_PASSWORD psql -U $POSTGRES_USER -d postgres -tAqc "$SQL"'
    ;;

  dump)
    # -Fc: a format that allows selective restore and is compressed itself.
    x -e DB="${2:?a database name is required}" "$C" \
      sh -c 'PGPASSWORD=$POSTGRES_PASSWORD pg_dump -U $POSTGRES_USER -d "$DB" -Fc -Z 9'
    ;;

  globals)
    # Roles, passwords and grants. Without them the restored database exists
    # but there is nobody to connect to it with.
    x "$C" sh -c 'PGPASSWORD=$POSTGRES_PASSWORD pg_dumpall -U $POSTGRES_USER --globals-only'
    ;;

  ext) echo ".dump" ;;

  detect)
    case "$(od -An -v -tx1 -N16 "${2:?}" | tr -d ' \n')" in
      5047444d50*) echo custom ;;
      *)           echo sql ;;
    esac
    ;;

  inspect)
    case "${2:?}" in
      custom) x -i "$C" pg_restore --list < "${3:?}" | head -40 ;;
      sql)    head -20 "${3:?}" ;;
      *)      exit 1 ;;
    esac
    ;;

  restore)
    fmt="${2:?}"; target="${3:?}"; file="${4:?}"; clean="${5:-0}"
    case "$fmt" in
      custom)
        # The database must exist: pg_restore -d connects to it, it does not
        # create it. Databases are created by the initializer from
        # databases.yaml.
        exists=$(x -e DB="$target" "$C" \
          sh -c 'PGPASSWORD=$POSTGRES_PASSWORD psql -U $POSTGRES_USER -d postgres -tAqc "SELECT 1 FROM pg_database WHERE datname='"'"'$DB'"'"'"' 2>/dev/null | tr -d '\r')
        [ "$exists" = "1" ] || { echo "database $target does not exist -- create it (./dc up -d db-initializer) and retry" >&2; exit 1; }
        args="--no-password"; [ "$clean" -eq 1 ] && args="$args --clean --if-exists"
        x -i -e DB="$target" -e ARGS="$args" "$C" \
          sh -c 'PGPASSWORD=$POSTGRES_PASSWORD pg_restore -U $POSTGRES_USER -d "$DB" $ARGS' < "$file"
        ;;
      sql)
        x -i "$C" sh -c 'PGPASSWORD=$POSTGRES_PASSWORD psql -U $POSTGRES_USER -d postgres -v ON_ERROR_STOP=1' < "$file"
        ;;
      *) echo "unknown format: $fmt" >&2; exit 1 ;;
    esac
    ;;

  *) echo "usage: $0 check|list|dump <db>|globals|ext|detect <f>|inspect <fmt> <f>|restore <fmt> <db> <f> <clean>" >&2; exit 2 ;;
esac
