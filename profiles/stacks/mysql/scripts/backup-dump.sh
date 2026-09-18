#!/usr/bin/env bash
#
# Dumps and restores for the shared MySQL. The same contract as the pg
# provider's -- see profiles/stacks/pg/scripts/backup-dump.sh. The platform does
# not know about mysqldump and must not.
#
# The root password always goes through MYSQL_PWD rather than an argument:
# anything in argv is visible in `ps` to every process in the container.

set -uo pipefail

C=mysqld

# The password is read LAZILY, only when it is actually needed.
#
# ext and detect are pure functions: the first answers with a string, the second
# looks at the file's magic. Reading the password at startup would make the
# script fail on those on a machine with no configured .env -- i.e. a check that
# needs no credentials would demand credentials.
PW=""
need_pw() {
  [ -n "$PW" ] && return 0
  # shellcheck source=platform/lib/lib-env.sh
  . "${ROOT_DIR:?}/platform/lib/lib-env.sh"
  ENV_VARS=(); env_load_files "$ROOT_DIR/.env" "$ROOT_DIR/stacks/mysql/.env"
  PW="$(env_get Mysql_Root_Password)"
  [ -n "$PW" ] || { echo "stacks/mysql/.env has no Mysql_Root_Password" >&2; exit 2; }
}

q() { need_pw; docker exec -e MYSQL_PWD="$PW" "$C" mysql -uroot -N -B -e "$1" 2>/dev/null; }

case "${1:-}" in
  check)
    need_pw
    docker exec -e MYSQL_PWD="$PW" "$C" mysqladmin ping -uroot --silent >/dev/null 2>&1 \
      || { echo "container $C does not answer mysqladmin ping" >&2; exit 1; }
    ;;

  list)
    # System databases are excluded: information_schema and performance_schema
    # are views and their dump cannot be restored; mysql holds the accounts, and
    # those go separately, through globals.
    q "SELECT schema_name FROM information_schema.schemata
       WHERE schema_name NOT IN ('information_schema','performance_schema','mysql','sys')
       ORDER BY schema_name"
    ;;

  dump)
    need_pw
    # --single-transaction: a snapshot without locking the tables, which InnoDB
    # supports. Without it, dumping a production database stops writes for the
    # whole duration of the dump.
    # --routines and --events: otherwise procedures and the scheduler silently
    # stay behind.
    docker exec -e MYSQL_PWD="$PW" -e DB="${2:?a database name is required}" "$C" \
      sh -c 'mysqldump -uroot --single-transaction --routines --events --default-character-set=utf8 "$DB"' \
      | gzip -9
    ;;

  globals)
    # The equivalent of pg_dumpall --globals-only: accounts and their grants.
    # Without them the restored database exists but there is nobody to connect
    # to it with.
    #
    # Through SHOW GRANTS rather than a dump of the mysql.user table: that
    # table's layout changes between versions, and a dump from 5.5 does not load
    # into 8.0 at all.
    while IFS= read -r acct; do
      [ -n "$acct" ] || continue
      echo "-- $acct"
      q "SHOW GRANTS FOR $acct" | sed 's/$/;/'
    done < <(q "SELECT CONCAT(QUOTE(user),'@',QUOTE(host)) FROM mysql.user
               WHERE user NOT IN ('root','mysql.sys','mysql.session','mysql.infoschema','')")
    ;;

  ext) echo ".sql.gz" ;;

  detect)
    case "$(od -An -v -tx1 -N4 "${2:?}" | tr -d ' \n')" in
      1f8b*) echo sqlgz ;;
      *)     echo sql ;;
    esac
    ;;

  inspect)
    case "${2:?}" in
      sqlgz) gunzip -c "${3:?}" | head -40 ;;
      sql)   head -40 "${3:?}" ;;
      *)     exit 1 ;;
    esac
    ;;

  restore)
    need_pw
    fmt="${2:?}"; target="${3:?}"; file="${4:?}"; clean="${5:-0}"
    # We do not create the database: the initializer creates it from
    # databases.yaml, and creating it here would mean a second place deciding
    # the character set and the owner.
    exists="$(q "SELECT 1 FROM information_schema.schemata WHERE schema_name='$target'")"
    [ "$exists" = "1" ] || { echo "database $target does not exist -- create it (./dc up -d mysql-initializer) and retry" >&2; exit 1; }

    # MySQL has no --clean: the equivalent is DROPping every table before
    # loading. We do it only on explicit request, because it is irreversible.
    if [ "$clean" -eq 1 ]; then
      while IFS= read -r t; do
        [ -n "$t" ] || continue
        q "SET FOREIGN_KEY_CHECKS=0; DROP TABLE IF EXISTS \`$target\`.\`$t\`; SET FOREIGN_KEY_CHECKS=1"
      done < <(q "SELECT table_name FROM information_schema.tables WHERE table_schema='$target'")
    fi

    case "$fmt" in
      sqlgz) gunzip -c "$file" | docker exec -i -e MYSQL_PWD="$PW" -e DB="$target" "$C" sh -c 'mysql -uroot "$DB"' ;;
      sql)   docker exec -i -e MYSQL_PWD="$PW" "$C" sh -c 'mysql -uroot' < "$file" ;;
      *)     echo "unknown format: $fmt" >&2; exit 1 ;;
    esac
    ;;

  *) echo "usage: $0 check|list|dump <db>|globals|ext|detect <f>|inspect <fmt> <f>|restore <fmt> <db> <f> <clean>" >&2; exit 2 ;;
esac
