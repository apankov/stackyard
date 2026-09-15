#!/usr/bin/env bash
#
# Дампы и восстановление общего PostgreSQL. Зовётся платформой
# (platform/bin/{backup,check-backups,backup-restore}.sh).
#
# Здесь, а не в платформе, потому что pg_dump — знание про Postgres. Платформа,
# знающая эти команды, требовала бы форка под каждую машину с другой СУБД, то
# есть возвращала бы ту самую копию платформы, от которой мы уходили.
#
#   check                                 СУБД отвечает? код и причина в stderr
#   list                                  имена баз, по одной на строку
#   dump <db>                             дамп базы в stdout, уже сжатый
#   globals                               роли и гранты в stdout; пусто — законно
#   ext                                   расширение файла дампа
#   detect <файл>                         формат одним словом
#   inspect <формат> <файл>               показать содержимое
#   restore <формат> <цель> <файл> <clean> залить дамп

set -uo pipefail

C=postgres
x() { docker exec "$@"; }

case "${1:-}" in
  check)
    x "$C" sh -c 'pg_isready -U $POSTGRES_USER -d postgres' >/dev/null 2>&1 \
      || { echo "контейнер $C не отвечает на pg_isready" >&2; exit 1; }
    ;;

  list)
    # Спрашиваем у самой СУБД: захардкоженный список означал бы, что следующая
    # заведённая база молча останется без бэкапа.
    x -e SQL="SELECT datname FROM pg_database WHERE NOT datistemplate AND datname <> 'postgres' ORDER BY datname" "$C" \
      sh -c 'PGPASSWORD=$POSTGRES_PASSWORD psql -U $POSTGRES_USER -d postgres -tAqc "$SQL"'
    ;;

  dump)
    # -Fc: формат, из которого можно восстановить выборочно и который сам сжат.
    x -e DB="${2:?нужно имя базы}" "$C" \
      sh -c 'PGPASSWORD=$POSTGRES_PASSWORD pg_dump -U $POSTGRES_USER -d "$DB" -Fc -Z 9'
    ;;

  globals)
    # Роли, пароли и гранты. Без них восстановленная база есть, а подключиться
    # к ней некому.
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
        # База должна существовать: pg_restore -d в неё подключается, а не
        # создаёт. Заводит базы инициализатор из databases.yaml.
        exists=$(x -e DB="$target" "$C" \
          sh -c 'PGPASSWORD=$POSTGRES_PASSWORD psql -U $POSTGRES_USER -d postgres -tAqc "SELECT 1 FROM pg_database WHERE datname='"'"'$DB'"'"'"' 2>/dev/null | tr -d '\r')
        [ "$exists" = "1" ] || { echo "базы $target нет — создайте её (./dc up -d db-initializer) и повторите" >&2; exit 1; }
        args="--no-password"; [ "$clean" -eq 1 ] && args="$args --clean --if-exists"
        x -i -e DB="$target" -e ARGS="$args" "$C" \
          sh -c 'PGPASSWORD=$POSTGRES_PASSWORD pg_restore -U $POSTGRES_USER -d "$DB" $ARGS' < "$file"
        ;;
      sql)
        x -i "$C" sh -c 'PGPASSWORD=$POSTGRES_PASSWORD psql -U $POSTGRES_USER -d postgres -v ON_ERROR_STOP=1' < "$file"
        ;;
      *) echo "неизвестный формат: $fmt" >&2; exit 1 ;;
    esac
    ;;

  *) echo "usage: $0 check|list|dump <db>|globals|ext|detect <f>|inspect <fmt> <f>|restore <fmt> <db> <f> <clean>" >&2; exit 2 ;;
esac
