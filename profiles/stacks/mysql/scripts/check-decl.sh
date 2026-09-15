#!/usr/bin/env bash
#
# Проверка заказа базы у ЭТОГО поставщика. Зовётся платформой (check_db_decl)
# для каждого стека-потребителя; в окружении STACK_NAME, DB_PREFIX, ROOT_DIR.
#
# Здесь, а не в платформе, потому что список допустимых прав — это знание про
# MySQL. Платформа, знающая слово GRANT, снова стала бы непереносимой на
# машину с другой СУБД — ровно то, от чего мы ушли.
#
# Печатает по строке на проблему и молчит, когда её нет.

set -uo pipefail

# Обе библиотеки: lib-stacks знает, в каком корне лежит стек, lib-env — как
# читать .env. Собирать пути руками здесь было нельзя вдвойне: профильный
# stack.conf грузился ПОСЛЕ машинного и перебивал его — наоборот к stack_dir,
# где машинный корень первый. Стек, скопированный из профиля и поправленный,
# проверялся бы по старому, профильному значению.
# shellcheck source=../../../../platform/lib/lib-stacks.sh
. "${ROOT_DIR:?}/platform/lib/lib-stacks.sh"
# shellcheck source=../../../../platform/lib/lib-env.sh
. "$ROOT_DIR/platform/lib/lib-env.sh"
s="${STACK_NAME:?}"; prefix="${DB_PREFIX:?}"
ENV_VARS=(); env_load_files "$ROOT_DIR/.env" "$(stack_env_file "$s")" "$(stack_conf_file "$s")"

user="$(env_get "${prefix}_User")"
[ -n "$user" ] || exit 0

# Предел длины имени пользователя в MySQL 5.5 — 16 символов (в 8.0 их 32).
# Более длинное имя обрезается при создании, и объявленное перестаёт совпадать
# с существующим: инициализатор заводит пользователя заново на каждом прогоне и
# каждый раз докладывает о расхождении пароля.
[ "${#user}" -le 16 ] || \
  printf 'стек %s: имя пользователя %s длиннее 16 символов — MySQL 5.5 его обрежет\n' "$s" "$user"

# Права разбираем здесь, а не в контейнере: опечатка иначе всплывает
# синтаксической ошибкой MySQL в логе одноразового контейнера, который снаружи
# выглядит просто как `exited`.
for g in $(env_get "${prefix}_Grants" "SELECT,INSERT,UPDATE,DELETE" | tr ',' ' '); do
  case "$(printf '%s' "$g" | tr 'a-z' 'A-Z')" in
    SELECT|INSERT|UPDATE|DELETE|CREATE|DROP|INDEX|ALTER|REFERENCES|TRIGGER| \
    EXECUTE|LOCK|"CREATE VIEW"|"SHOW VIEW"|"CREATE ROUTINE"|"ALTER ROUTINE"|"CREATE TEMPORARY TABLES") ;;
    ALL|"ALL PRIVILEGES")
      printf 'стек %s: %s_Grants=ALL включает DROP и GRANT OPTION — перечислите нужное явно\n' "$s" "$prefix" ;;
    *) printf 'стек %s: непонятное право в %s_Grants: %s\n' "$s" "$prefix" "$g" ;;
  esac
done
