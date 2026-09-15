#!/bin/bash

# Заводит базы и пользователей общего postgres по databases.yaml.
#
# Файл СГЕНЕРИРОВАН scripts/stack.sh из <Префикс>_* в stacks/*/stack.conf, то
# есть в конечном счёте из .env самих стеков. Руками его не правят: правка
# переживёт ровно до следующего `stack.sh sync`.
#
# Идемпотентен: существующие пользователи и базы не пересоздаются.

set -uo pipefail

echo "Ожидание готовности PostgreSQL..."
until pg_isready -h postgres -U "$POSTGRES_USER"; do
  sleep 1
done
echo "PostgreSQL готов! Читаем YAML..."

if [ ! -s /config/databases.yaml ]; then
  echo "Ошибка: /config/databases.yaml пуст или отсутствует." >&2
  echo "  Он генерируется: ./scripts/stack.sh sync" >&2
  exit 1
fi

export PGPASSWORD="$POSTGRES_PASSWORD"
problems=0

# yq конвертирует каждый элемент массива в компактный JSON на одну строку, и он
# же умеет читать точечные значения из этих мини-json строк.
#
# Конвейер намеренно не `| while`: тело цикла в подоболочке потеряло бы счётчик
# problems, и скрипт завершался бы нулём при найденных расхождениях.
while read -r row; do
    [ -n "$row" ] || continue
    DB_NAME=$(echo "$row" | yq e '.db' -)
    DB_USER=$(echo "$row" | yq e '.user' -)
    DB_PASS=$(echo "$row" | yq e '.password' -)
    DUMP_FILE=$(echo "$row" | yq e '.dump_file // ""' -)

    # 1. Пользователь.
    USER_EXISTS=$(psql -h postgres -U "$POSTGRES_USER" -d postgres -tAc \
      "SELECT 1 FROM pg_roles WHERE rolname='$DB_USER'")
    if [ "$USER_EXISTS" != "1" ]; then
        echo "--> Создание пользователя: $DB_USER"
        psql -h postgres -U "$POSTGRES_USER" -d postgres \
          -c "CREATE USER $DB_USER WITH PASSWORD '$DB_PASS';"
    else
        # Пользователь уже есть — значит пароль в базе мы не ставили и не знаем,
        # совпадает ли он с объявленным. Проверяем пробным подключением.
        #
        # ALTER USER здесь намеренно НЕ делается: пароль, поменянный руками в
        # psql и не записанный в .env стека, был бы молча перезаписан при
        # следующем `up -d`. Худший вид сюрприза — тихий.
        #
        # А молчать нельзя: расхождение проявляется как
        # `P1000 / password authentication failed` в логах приложения через
        # часы после запуска, и связать это с db-initializer уже трудно.
        if ! PGPASSWORD="$DB_PASS" psql -h postgres -U "$DB_USER" -d postgres \
             -tAc 'SELECT 1' >/dev/null 2>&1; then
            echo "--> [ОШИБКА] пароль пользователя '$DB_USER' в базе НЕ совпадает с объявленным." >&2
            echo "             Объявление: <Префикс>_Password в stack.conf стека," >&2
            echo "             значение   — в stacks/<стек>/.env." >&2
            echo "             Починить можно двумя способами:" >&2
            echo "               1) записать в .env тот пароль, что стоит в базе;" >&2
            echo "               2) сменить пароль в базе под объявленный:" >&2
            echo "                  docker exec -it postgres psql -U \$POSTGRES_USER -c \\\\" >&2
            echo "                    \"ALTER USER $DB_USER WITH PASSWORD '<новый>';\"" >&2
            echo "             Затем ./scripts/stack.sh sync && ./docker-compose.sh up -d db-initializer" >&2
            problems=$((problems + 1))
            continue
        fi
    fi

    # 2. База.
    DB_EXISTS=$(psql -h postgres -U "$POSTGRES_USER" -d postgres -tAc \
      "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'")
    if [ "$DB_EXISTS" != "1" ]; then
        echo "--> Создание базы данных: $DB_NAME"
        psql -h postgres -U "$POSTGRES_USER" -d postgres \
          -c "CREATE DATABASE $DB_NAME OWNER $DB_USER;"
        psql -h postgres -U "$POSTGRES_USER" -d postgres \
          -c "GRANT ALL PRIVILEGES ON DATABASE $DB_NAME TO $DB_USER;"

        # Дамп накатывается ТОЛЬКО при создании базы. Иначе каждый `up -d`
        # заливал бы seed поверх живых данных.
        if [ -n "$DUMP_FILE" ] && [ "$DUMP_FILE" != "null" ] && [ -f "/dumps/$DUMP_FILE" ]; then
            echo "--> [!] Накатываем дамп $DUMP_FILE в базу $DB_NAME..."
            psql -h postgres -U "$POSTGRES_USER" -d "$DB_NAME" -f "/dumps/$DUMP_FILE"
            echo "--> Дамп успешно развернут!"
        fi
    else
        echo " База $DB_NAME уже существует. Пропускаем."
    fi
done < <(yq e '.[] | @json' /config/databases.yaml)

if [ "$problems" -gt 0 ]; then
  echo >&2
  echo "Расхождений паролей: $problems. Базы, которых это касается, не тронуты." >&2
  exit 1
fi

echo "Все базы данных синхронизированы!"
