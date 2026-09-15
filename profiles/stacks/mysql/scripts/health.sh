#!/usr/bin/env bash
#
# Живость общего MySQL для `stack.sh --check`.
#
# Спрашиваем у работающего сервера, а не смотрим на файлы: конфиг на диске
# может быть верным, а образ — читать конфиги из другого каталога, и тогда
# sql_mode не тот, что объявлен, при полностью исправном на вид контейнере.
#
# Контракт: без root, ничего не меняет, укладывается в 10 секунд, первая строка
# вывода становится причиной в отчёте. В окружении есть STACK_DIR и ROOT_DIR.

set -uo pipefail

# Через lib-env.sh, а не grep'ом: пароль лежит в .env стека, и он единственный,
# кто знает про разворачивание ${...} и снятие кавычек. Однострочник вернул бы
# пароль вместе с кавычками, и health.sh докладывал бы о мёртвой базе при живой.
#
# Путь к библиотеке — platform/lib/. Здесь стоял scripts/lib-env.sh из devbox6,
# и проверка падала на КАЖДОМ прогоне `--check` с «No such file or directory».
# Соседние скрипты стека (check-decl.sh, host-setup.sh, backup-dump.sh) путь
# имели верный — опечатка была ровно в одном месте и жила, потому что её
# следствие выглядело как «стек не отвечает», а не как сломанный скрипт.
#
# shellcheck source=platform/lib/lib-stacks.sh
. "${ROOT_DIR:?}/platform/lib/lib-stacks.sh"
# shellcheck source=platform/lib/lib-env.sh
. "$ROOT_DIR/platform/lib/lib-env.sh"

# .env стека — через stack_env_file, а не от STACK_DIR. У профильного стека
# STACK_DIR указывает в profile/, где .env не лежит по построению: секрет
# принадлежит машине. Подставив туда STACK_DIR, проверка врала бы «нет
# Mysql_Root_Password» при исправном файле — и вечно красный блок перестал бы
# читаться целиком, вместе с настоящими находками.
ENV_VARS=(); env_load_files "$ROOT_DIR/.env" "$(stack_env_file mysql)"

PW="$(env_get Mysql_Root_Password)"
[ -n "$PW" ] || { echo "в stacks/mysql/.env нет Mysql_Root_Password"; exit 1; }

# Пароль уходит через MYSQL_PWD, а не аргументом: всё, что стоит в argv, видно
# в `ps` любому процессу контейнера.
q() { docker exec -e MYSQL_PWD="$PW" mysqld mysql -uroot -N -B -e "$1" 2>/dev/null; }

q 'SELECT 1' >/dev/null || { echo "mysqld не отвечает на запрос"; exit 1; }

# Режим проверяем именно эффективный. Забытая или неприменённая строка sql_mode
# ломает не соединение, а отдельные запросы legacy-кода — то есть отказ,
# который выглядит как баг приложения, а не как неверная настройка СУБД.
mode="$(q 'SELECT @@GLOBAL.sql_mode')"
case "$mode" in
  *ONLY_FULL_GROUP_BY*) echo "в sql_mode есть ONLY_FULL_GROUP_BY — legacy-запросы будут падать: $mode"; exit 1 ;;
esac

echo "mysqld отвечает, sql_mode=${mode:-<пусто>}"
