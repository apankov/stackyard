#!/usr/bin/env bash

# Заводит базы, пользователей и их права в общем MySQL по databases.yaml.
#
# Файл СГЕНЕРИРОВАН scripts/stack.sh из Mysql_* в stacks/*/stack.conf, то есть
# в конечном счёте из .env самих стеков. Руками его не правят: правка переживёт
# ровно до следующего `stack.sh sync`.
#
# Идемпотентен, и это главное его свойство: контейнер одноразовый, но
# поднимается при КАЖДОМ `up -d`. Существующие пользователи и базы не
# пересоздаются, данные не трогаются.
#
# Чего он не делает НИКОГДА:
#   * не меняет пароль существующему пользователю;
#   * не отзывает права, которых нет в декларации;
#   * не удаляет и не перезаписывает существующую базу.
# Всё это — тихие разрушительные действия, а расхождение он вместо них
# печатает и делает прогон проваленным.

set -uo pipefail

MYSQL_HOST=mysqld

# Пользователь заводится РОВНО как 'имя'@'%'.
#
# В MySQL учётка — это пара (user, host), и 'app'@'%' с 'app'@'localhost' —
# две разные записи с разными правами и разными паролями. Контейнеры ходят сюда
# по bridge-сети со случайных адресов, поэтому единственная работающая форма —
# '%'. Завести вторую пару значило бы получить учётку, под которую попадает
# половина подключений, — с «Access denied» при заведомо верном пароле.
USER_HOST='%'

echo "Ожидание готовности MySQL..."
for _ in $(seq 1 60); do
  mysqladmin ping -h"$MYSQL_HOST" -uroot -p"$MYSQL_ROOT_PASSWORD" --silent >/dev/null 2>&1 && break
  sleep 1
done
mysqladmin ping -h"$MYSQL_HOST" -uroot -p"$MYSQL_ROOT_PASSWORD" --silent >/dev/null 2>&1 \
  || { echo "Ошибка: MySQL не поднялся за 60 секунд." >&2; exit 1; }
echo "MySQL готов! Читаем YAML..."

if [ ! -s /config/databases.yaml ]; then
  echo "Ошибка: /config/databases.yaml пуст или отсутствует." >&2
  echo "  Он генерируется: ./scripts/stack.sh sync" >&2
  exit 1
fi

# Пароль root уходит через MYSQL_PWD, а не аргументом: всё, что стоит в argv,
# видно в `ps` любому процессу контейнера.
export MYSQL_PWD="$MYSQL_ROOT_PASSWORD"
root_q() { mysql -h"$MYSQL_HOST" -uroot -N -B -e "$1"; }

problems=0

# Строковый литерал MySQL. Экранируем и обратный слэш, и кавычку — в пароле
# бывает и то, и другое, а оборванный на спецсимволе литерал либо сломает
# запрос, либо (хуже) заведёт пользователя с усечённым паролем.
sql_str() { local v="$1"; v="${v//\\/\\\\}"; v="${v//\'/\\\'}"; printf "'%s'" "$v"; }

# Идентификаторы (имя базы, имя пользователя) в кавычки не заворачиваем, а
# ПРОВЕРЯЕМ. Обратные кавычки вокруг имени спасают от пробелов, но не от имени,
# в котором сама обратная кавычка, — а декларация приходит из .env, который
# правит человек.
valid_ident() { [[ "$1" =~ ^[A-Za-z0-9_]+$ ]]; }

# Права, объявленные стеком, — в верхнем регистре, по одному на строку.
norm_grants() {
  printf '%s' "$1" | tr ',' '\n' | tr 'a-z' 'A-Z' \
    | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | sed '/^$/d' | sort -u
}

# Права, которые у пользователя РЕАЛЬНО есть на эту базу.
#
# `SHOW GRANTS` отдаёт строки вида
#   GRANT SELECT, INSERT ON `db`.* TO 'u'@'%'
# плюс обязательную GRANT USAGE ON *.* — это «учётка существует», не право, и
# в сравнение она не идёт.
current_grants() {
  local user="$1" db="$2"
  root_q "SHOW GRANTS FOR $(sql_str "$user")@$(sql_str "$USER_HOST")" 2>/dev/null \
    | grep -F "ON \`${db}\`.*" \
    | sed -E 's/^GRANT (.*) ON .*/\1/' \
    | tr ',' '\n' | tr 'a-z' 'A-Z' \
    | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | sed '/^$/d' | sort -u
}

# Конвейер намеренно не `| while`: тело цикла в подоболочке потеряло бы счётчик
# problems, и скрипт завершался бы нулём при найденных расхождениях.
while read -r row; do
    [ -n "$row" ] || continue
    DB_NAME=$(echo "$row"   | yq e '.db' -)
    DB_USER=$(echo "$row"   | yq e '.user' -)
    DB_PASS=$(echo "$row"   | yq e '.password' -)
    DB_GRANTS=$(echo "$row" | yq e '.grants // "SELECT,INSERT,UPDATE,DELETE"' -)
    # Ключ 'dump', а не 'dump_file': генератор пишет имя ключа в нижнем регистре
    # без префикса (Mysql_Dump -> dump), и второе написание здесь означало бы,
    # что seed молча не накатывается — база заведена, схема пуста, приложение
    # стартует на ней и падает уже в рантайме.
    DUMP_FILE=$(echo "$row" | yq e '.dump // ""' -)

    if ! valid_ident "$DB_NAME" || ! valid_ident "$DB_USER"; then
        echo "--> [ОШИБКА] имя базы '$DB_NAME' или пользователя '$DB_USER' содержит недопустимые символы." >&2
        echo "             Разрешены латиница, цифры и подчёркивание." >&2
        problems=$((problems + 1)); continue
    fi

    # 1. Пользователь.
    USER_EXISTS=$(root_q "SELECT 1 FROM mysql.user WHERE User=$(sql_str "$DB_USER") AND Host=$(sql_str "$USER_HOST")")
    if [ "$USER_EXISTS" != "1" ]; then
        echo "--> Создание пользователя: ${DB_USER}@${USER_HOST}"
        root_q "CREATE USER $(sql_str "$DB_USER")@$(sql_str "$USER_HOST") IDENTIFIED BY $(sql_str "$DB_PASS");" \
          || { echo "--> [ОШИБКА] не удалось создать пользователя $DB_USER" >&2; problems=$((problems + 1)); continue; }
    else
        # Пользователь уже есть — значит пароль в базе ставили не мы и мы не
        # знаем, совпадает ли он с объявленным. Проверяем пробным подключением.
        #
        # SET PASSWORD здесь намеренно НЕ делается: пароль, поменянный руками и
        # не записанный в .env стека, был бы молча перезаписан при следующем
        # `up -d`. Худший вид сюрприза — тихий.
        #
        # А молчать нельзя: расхождение проявляется как `Access denied for user`
        # в логах приложения через часы после запуска, и связать это с
        # инициализатором уже трудно.
        if ! MYSQL_PWD="$DB_PASS" mysql -h"$MYSQL_HOST" -u"$DB_USER" -N -B -e 'SELECT 1' >/dev/null 2>&1; then
            echo "--> [ОШИБКА] пароль пользователя '${DB_USER}@${USER_HOST}' в базе НЕ совпадает с объявленным." >&2
            echo "             Объявление: <Префикс>_Password в stack.conf стека," >&2
            echo "             значение   — в stacks/<стек>/.env." >&2
            echo "             Починить можно двумя способами:" >&2
            echo "               1) записать в .env тот пароль, что стоит в базе;" >&2
            echo "               2) сменить пароль в базе под объявленный:" >&2
            echo "                  docker exec -it mysqld mysql -uroot -p -e \\" >&2
            echo "                    \"SET PASSWORD FOR '${DB_USER}'@'${USER_HOST}' = PASSWORD('<новый>');\"" >&2
            echo "             Затем ./scripts/stack.sh sync && ./docker-compose.sh up -d mysql-initializer" >&2
            problems=$((problems + 1)); continue
        fi
    fi

    # 2. База.
    DB_EXISTS=$(root_q "SELECT 1 FROM information_schema.SCHEMATA WHERE SCHEMA_NAME=$(sql_str "$DB_NAME")")
    if [ "$DB_EXISTS" != "1" ]; then
        # utf8, а не utf8mb4, намеренно. В MySQL 5.5 предел длины индексного
        # ключа InnoDB — 767 байт, и VARCHAR(255) под utf8mb4 (255*4 = 1020) в
        # индекс не влезает: приложение падает на миграции, а не при запросе.
        # Стеку, которому нужен utf8mb4, придётся сузить такие колонки.
        echo "--> Создание базы данных: $DB_NAME"
        root_q "CREATE DATABASE \`${DB_NAME}\` CHARACTER SET utf8 COLLATE utf8_general_ci;" \
          || { echo "--> [ОШИБКА] не удалось создать базу $DB_NAME" >&2; problems=$((problems + 1)); continue; }

        # Дамп накатывается ТОЛЬКО при создании базы. Иначе каждый `up -d`
        # заливал бы seed поверх живых данных.
        if [ -n "$DUMP_FILE" ] && [ "$DUMP_FILE" != "null" ] && [ -f "/dumps/$DUMP_FILE" ]; then
            echo "--> [!] Накатываем дамп $DUMP_FILE в базу $DB_NAME..."
            mysql -h"$MYSQL_HOST" -uroot "$DB_NAME" < "/dumps/$DUMP_FILE" \
              || { echo "--> [ОШИБКА] дамп $DUMP_FILE не накатился" >&2; problems=$((problems + 1)); }
            echo "--> Дамп развёрнут."
        fi
    else
        echo " База $DB_NAME уже существует. Не трогаем."
    fi

    # 3. Права.
    #
    # Выдаём недостающие и НЕ отзываем лишние. GRANT аддитивен, поэтому повторная
    # выдача объявленного набора сама по себе ничего не отберёт, — а молчаливый
    # REVOKE снёс бы право, выданное руками под конкретную задачу, и сломал бы
    # приложение в момент, никак с этим не связанный.
    #
    # Но и молчать про лишнее нельзя: смысл ограниченных прав в том, что их
    # набор известен. Поэтому расхождение — громкая ошибка с готовой командой.
    want="$(norm_grants "$DB_GRANTS")"
    have="$(current_grants "$DB_USER" "$DB_NAME")"

    missing="$(comm -23 <(printf '%s\n' "$want") <(printf '%s\n' "$have"))"
    if [ -n "$missing" ]; then
        list="$(printf '%s' "$missing" | tr '\n' ',' | sed 's/,$//')"
        echo "--> Выдача прав ${list} на ${DB_NAME} пользователю ${DB_USER}@${USER_HOST}"
        root_q "GRANT ${list} ON \`${DB_NAME}\`.* TO $(sql_str "$DB_USER")@$(sql_str "$USER_HOST");" \
          || { echo "--> [ОШИБКА] не удалось выдать права на $DB_NAME" >&2; problems=$((problems + 1)); }
    fi

    extra="$(comm -13 <(printf '%s\n' "$want") <(printf '%s\n' "$have") | grep -vx 'USAGE')"
    if [ -n "$extra" ]; then
        list="$(printf '%s' "$extra" | tr '\n' ',' | sed 's/,$//')"
        echo "--> [ОШИБКА] у '${DB_USER}@${USER_HOST}' на базе ${DB_NAME} есть права сверх объявленных: ${list}" >&2
        echo "             Сами их не отзываем: снятое право ломает приложение в момент," >&2
        echo "             никак с этим не связанный. Решите, что верно:" >&2
        echo "               1) права нужны — допишите их в <Префикс>_Grants стека и \`stack.sh sync\`;" >&2
        echo "               2) права лишние — отзовите вручную:" >&2
        echo "                  docker exec -it mysqld mysql -uroot -p -e \\" >&2
        echo "                    \"REVOKE ${list} ON \\\`${DB_NAME}\\\`.* FROM '${DB_USER}'@'${USER_HOST}';\"" >&2
        problems=$((problems + 1))
    fi

done < <(yq e '.[] | @json' /config/databases.yaml)

if [ "$problems" -gt 0 ]; then
  echo >&2
  echo "Расхождений: $problems. Базы, которых это касается, не тронуты." >&2
  exit 1
fi

echo "Все базы и права синхронизированы!"
