#!/usr/bin/env bash
#
# Дампы и восстановление общего MySQL. Тот же контракт, что у поставщика pg —
# см. profiles/stacks/pg/scripts/backup-dump.sh. Платформа про mysqldump не
# знает и знать не должна.
#
# Пароль root везде уходит через MYSQL_PWD, а не аргументом: всё, что стоит в
# argv, видно в `ps` любому процессу контейнера.

set -uo pipefail

C=mysqld

# Пароль читается ЛЕНИВО, только когда он действительно нужен.
#
# ext и detect — чистые функции: первая отвечает строкой, вторая смотрит на
# магию файла. Читая пароль при старте, скрипт падал бы на них на машине без
# настроенного .env — то есть проверка, которой credentials не нужны, требовала
# бы credentials.
PW=""
need_pw() {
  [ -n "$PW" ] && return 0
  # shellcheck source=../../../../platform/lib/lib-env.sh
  . "${ROOT_DIR:?}/platform/lib/lib-env.sh"
  ENV_VARS=(); env_load_files "$ROOT_DIR/.env" "$ROOT_DIR/stacks/mysql/.env"
  PW="$(env_get Mysql_Root_Password)"
  [ -n "$PW" ] || { echo "в stacks/mysql/.env нет Mysql_Root_Password" >&2; exit 2; }
}

q() { need_pw; docker exec -e MYSQL_PWD="$PW" "$C" mysql -uroot -N -B -e "$1" 2>/dev/null; }

case "${1:-}" in
  check)
    need_pw
    docker exec -e MYSQL_PWD="$PW" "$C" mysqladmin ping -uroot --silent >/dev/null 2>&1 \
      || { echo "контейнер $C не отвечает на mysqladmin ping" >&2; exit 1; }
    ;;

  list)
    # Системные базы исключены: information_schema и performance_schema —
    # представления, их дамп не восстанавливается; mysql — учётки, они уходят
    # отдельно, через globals.
    q "SELECT schema_name FROM information_schema.schemata
       WHERE schema_name NOT IN ('information_schema','performance_schema','mysql','sys')
       ORDER BY schema_name"
    ;;

  dump)
    need_pw
    # --single-transaction: снимок без блокировки таблиц, InnoDB это умеет.
    # Без него дамп боевой базы останавливает запись на всё время дампа.
    # --routines и --events: иначе процедуры и планировщик молча не уедут.
    docker exec -e MYSQL_PWD="$PW" -e DB="${2:?нужно имя базы}" "$C" \
      sh -c 'mysqldump -uroot --single-transaction --routines --events --default-character-set=utf8 "$DB"' \
      | gzip -9
    ;;

  globals)
    # Аналог pg_dumpall --globals-only: учётки и их гранты. Без них
    # восстановленная база есть, а подключиться к ней некому.
    #
    # Через SHOW GRANTS, а не дампом таблицы mysql.user: формат этой таблицы
    # меняется между версиями, и дамп из 5.5 в 8.0 не заливается вовсе.
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
    # Базу не создаём: её заводит инициализатор из databases.yaml, и создание
    # здесь означало бы второе место, решающее про кодировку и владельца.
    exists="$(q "SELECT 1 FROM information_schema.schemata WHERE schema_name='$target'")"
    [ "$exists" = "1" ] || { echo "базы $target нет — создайте её (./dc up -d mysql-initializer) и повторите" >&2; exit 1; }

    # --clean у MySQL нет: аналог — DROP всех таблиц перед заливкой. Делаем
    # только по явному запросу, потому что это необратимо.
    if [ "$clean" -eq 1 ]; then
      while IFS= read -r t; do
        [ -n "$t" ] || continue
        q "SET FOREIGN_KEY_CHECKS=0; DROP TABLE IF EXISTS \`$target\`.\`$t\`; SET FOREIGN_KEY_CHECKS=1"
      done < <(q "SELECT table_name FROM information_schema.tables WHERE table_schema='$target'")
    fi

    case "$fmt" in
      sqlgz) gunzip -c "$file" | docker exec -i -e MYSQL_PWD="$PW" -e DB="$target" "$C" sh -c 'mysql -uroot "$DB"' ;;
      sql)   docker exec -i -e MYSQL_PWD="$PW" "$C" sh -c 'mysql -uroot' < "$file" ;;
      *)     echo "неизвестный формат: $fmt" >&2; exit 1 ;;
    esac
    ;;

  *) echo "usage: $0 check|list|dump <db>|globals|ext|detect <f>|inspect <fmt> <f>|restore <fmt> <db> <f> <clean>" >&2; exit 2 ;;
esac
