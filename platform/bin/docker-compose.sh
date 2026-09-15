#!/usr/bin/env bash

# Единственная точка входа в docker compose на этой машине.
#
# Собирает один вызов `docker compose` из платформенных файлов и файлов
# ВКЛЮЧЁННЫХ стеков. Состав берётся из Enabled_Stacks в .env-stacks — см.
# scripts/lib-stacks.sh и scripts/stack.sh. Списков файлов внутри скриптов нет:
# второе место с тем же знанием разъезжается с манифестом молча.
#
# Что из этого следует: файл выключенного стека не парсится вовсе, поэтому
# отсутствующий .env у ВЫКЛЮЧЕННОГО стека ничего не ломает. У включённого —
# роняет любую compose-команду на машине (CLAUDE.md §3.2), и это правильно: с
# ним стек всё равно не работает. Скрипт говорит, какого файла какого стека не
# хватает, вместо портянки от compose.
#
#   ./dc up -d                    # включённые стеки
#   ./dc --all-stacks config -q   # проверить ВСЕ файлы, включая
#                                                # выключенные стеки
#   ./dc --all-stacks --examples config -q
#                                                # то же на машине без секретов

set -e

DIR0="$( cd -P "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# Каталог МАШИНЫ, а не платформы. Обычно его задаёт обёртка ./stack в корне
# машины; запасной вариант — на два уровня вверх от platform/bin, чтобы скрипт
# работал и при прямом вызове.
ROOT_DIR="${ROOT_DIR:-$( cd "$DIR0/../.." && pwd )}"
LIB_DIR="$( cd "$DIR0/../lib" && pwd )"
ENV_FILE="$ROOT_DIR/.env"

# Все `-f` и `--env-file` ниже — относительные. Переход гарантирует, что вызов
# из любого места (юнит systemd, чужой скрипт) найдёт эти файлы; каталог
# проекта задаётся отдельно, через --project-directory ниже.
cd "$ROOT_DIR"

# shellcheck source=scripts/lib-stacks.sh
. "$LIB_DIR/lib-stacks.sh"

# Флаги — только перед командой.
#
# --all-stacks нужен для валидации всего репозитория (`config -q`) и для CI:
# манифест описывает конкретную машину, а сломать синтаксис можно в файле
# стека, который на ней выключен.
#
# --examples подставляет .env-<стек>.example там, где настоящего файла нет. На
# машине разработчика секретов нет вовсе, и проверить сборку конфига всех
# стеков надо ДО того, как ветка уедет на сервер. На сервере флаг ничего не
# меняет — настоящие файлы там есть, и приоритет у них.
ALL_STACKS=0
USE_EXAMPLES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --all-stacks) ALL_STACKS=1; shift ;;
    --examples)   USE_EXAMPLES=1; shift ;;
    *)            break ;;
  esac
done

# 1. Проверяем наличие самого .env файла
if [ ! -f "$ENV_FILE" ]; then
  if [ "$USE_EXAMPLES" -eq 1 ] && [ -f "$ENV_FILE.example" ]; then
    ENV_FILE="$ENV_FILE.example"
  else
    echo "Ошибка: Файл окружения '$ENV_FILE' не найден!" >&2
    exit 1
  fi
fi

# 2. Извлекаем имя сети из .env (игнорируя пробелы и кавычки)
TARGET_NETWORK=$(grep -E '^Platform_Network=' "$ENV_FILE" | head -n 1 | cut -d '=' -f2- | tr -d '"'\')

# 3. Проверяем, что переменная Platform_Network не пустая
if [ -z "$TARGET_NETWORK" ]; then
  echo "Ошибка: Переменная Platform_Network не задана в файле $ENV_FILE" >&2
  exit 1
fi

# Экспортируем переменную в окружение текущей сессии Bash.
# Теперь Docker Compose железно увидит её при парсинге YAML-файлов.
export Platform_Network="${TARGET_NETWORK}"

# ------------------------------------------------------- состав команды

if [ "$ALL_STACKS" -eq 1 ]; then
  STACKS=$(stacks_available)
else
  STACKS=$(stacks_enabled)
fi

# Какой env-файл брать для стека: настоящий, иначе образец под --examples,
# иначе ничего (стек без .env-<стек>.example обходится корневым .env).
env_file_for() {
  local f
  f="$(stack_env_file "$1")"
  if [ -f "$f" ]; then printf '%s' "$f"
  elif [ "$USE_EXAMPLES" -eq 1 ] && [ -f "$f.example" ]; then printf '%s' "$f.example"
  fi
}

# Чего не хватает включённым стекам. Проверяем ДО вызова compose: сообщение
# «какого файла какого стека нет» полезнее, чем ошибка интерполяции из
# середины десятого yaml. Под --examples не проверяем вовсе: там отсутствие
# настоящего файла — норма, а не поломка.
MISSING=""
if [ "$USE_EXAMPLES" -eq 0 ]; then
  for stack in $STACKS; do
    for f in $(stack_missing_files "$stack"); do
      MISSING="$MISSING  $stack: нет $f"$'\n'
    done
  done
fi
if [ -n "$MISSING" ]; then
  echo "Ошибка: у включённых стеков не хватает файлов:" >&2
  printf '%s' "$MISSING" >&2
  echo "Заведите их из образцов (cp stacks/<стек>/.env.example stacks/<стек>/.env && chmod 600 ...)" >&2
  echo "либо выключите стек: ./stack disable <стек>" >&2
  exit 1
fi

# Генерируемого файла статики на свежем чекауте нет, а compose падает на
# отсутствующем -f. Пишем его молча: предупреждение про рассинхрон человек
# получит ниже, а отказ здесь означал бы, что после `git pull` не работает ни
# одна команда — ровно тот класс поломок, который этот репозиторий лечит.
for gen in "$(stacks_static_file)" "$(stacks_include_file)"; do
  [ -f "$gen" ] && continue
  mkdir -p "$(dirname "$gen")"
  case "$gen" in
    *nginx-static.generated.yaml) stacks_static_content  > "$gen" ;;
    *00-enabled.conf)             stacks_include_content > "$gen" ;;
  esac
done

# Файл со списком баз тоже генерируемый, но живёт внутри стека pg и нужен
# только когда этот стек включён. Здесь его лишь СОЗДАЁМ пустым, если нет:
# docker на отсутствующий файл в bind-mount заводит КАТАЛОГ от root, и
# db-initializer потом падает на нём невнятно. Содержимое пишет stack.sh sync —
# сгенерировать его здесь нечем, docker-compose.sh намеренно не грузит
# lib-env.sh (см. заголовок lib-stacks.sh).
DB_FILE="$(stacks_databases_file)"
if [ -d "$(dirname "$DB_FILE")" ] && [ ! -f "$DB_FILE" ]; then
  : > "$DB_FILE"
  chmod 600 "$DB_FILE"
fi

# Платформенные файлы — всегда. nginx-static.generated.yaml здесь именно
# затем, чтобы спека nginx не зависела от набора стеков (см. его заголовок).
#
# --project-directory и -p заданы ЯВНО. Compose считает каталогом проекта
# каталог первого -f, а первый -f лежит в platform/compose/: без этих двух
# строк туда уедут относительные bind-mount'ы, а имя проекта станет "compose" —
# и stack.sh перестанет находить существующие контейнеры по меткам.
DOCKER_COMPOSE_BASE=(
  docker compose
  --project-directory "$ROOT_DIR"
  -p "$(compose_project)"
  --env-file "$ENV_FILE"
)

for stack in $STACKS; do
  ef="$(env_file_for "$stack")"
  [ -n "$ef" ] && DOCKER_COMPOSE_BASE+=(--env-file "${ef#"$ROOT_DIR"/}")
done

DOCKER_COMPOSE_BASE+=(
  -f platform/compose/nginx.yaml
  -f state/nginx-static.generated.yaml
)

# Стек без собственных контейнеров (сайт на платформенных nginx/php-fpm)
# compose-файла не имеет вовсе — см. stack_missing_files в lib-stacks.sh.
# Несуществующий -f для compose не «пустой файл», а отказ выполнить команду.
# Путь к файлу стека спрашиваем у stack_dir: стек может лежать и в машинном
# stacks/, и в профильном profile/stacks/. Собранный строчно путь работал бы
# только для одного из двух режимов.
for stack in $STACKS; do
  f="$(stack_compose_file "$stack")"
  [ -f "$f" ] && DOCKER_COMPOSE_BASE+=(-f "${f#"$ROOT_DIR"/}")
done

# Проверяем, передал ли пользователь хотя бы один аргумент
if [ $# -eq 0 ]; then
  echo "Ошибка: Не указана команда (например: up, down, config)" >&2
  echo "Использование: $0 [--all-stacks] [--examples] [команда] [аргументы...]" >&2
  echo "Включённые стеки: $(echo $STACKS | tr '\n' ' ')" >&2
  exit 1
fi

# 4. Проверка и создание внешней сети.
#
# Под --examples сеть не трогаем: это режим проверки конфига на машине
# разработчика, и создавать там docker-сеть — менять состояние ради команды,
# которая ничего запускать не собирается.
if [ "$USE_EXAMPLES" -eq 0 ] && ! docker network inspect "${TARGET_NETWORK}" >/dev/null 2>&1; then
  echo "Сеть '${TARGET_NETWORK}' не найдена. Создаю..."
  docker network create "${TARGET_NETWORK}"
fi

# 5. Рассинхрон nginx с манифестом — предупреждение, а не отказ.
#
# Это единственное место, где его заметит человек, набравший `up -d` после
# `git pull`: include-файл сгенерирован и в git не лежит, поэтому на свежем
# чекауте его просто нет, и nginx после ЛЮБОЙ следующей перезагрузки останется
# без всех vhost'ов. Отказом делать нельзя: `up` бывает нужен именно чтобы
# поднять приложение перед тем, как nginx впервые увидит его vhost.
# STACK_SH_APPLYING выставляет scripts/stack.sh: он вызывает `up -d` РОВНО в
# том окне, когда include-файл ещё не переписан, и предупреждать здесь значит
# пугать человека тем, что скрипт исправит следующей строкой.
if [ "$ALL_STACKS" -eq 0 ] && [ -z "${STACK_SH_APPLYING:-}" ]; then
  INCLUDE_FILE="$(stacks_include_file)"
  STATIC_FILE="$(stacks_static_file)"
  if [ ! -f "$INCLUDE_FILE" ] || [ "$(cat "$INCLUDE_FILE")" != "$(stacks_include_content)" ] \
     || [ "$(cat "$STATIC_FILE")" != "$(stacks_static_content)" ]; then
    echo "Предупреждение: генерируемые файлы nginx не соответствуют stacks/." >&2
    echo "  Приведите в соответствие: ./stack sync" >&2
  fi
fi

# Выполняем сборную команду, подставляя все переданные аргументы ($@)
"${DOCKER_COMPOSE_BASE[@]}" "$@"
