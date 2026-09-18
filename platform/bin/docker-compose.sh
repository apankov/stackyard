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
if [ -z "${ROOT_DIR:-}" ]; then
  ROOT_DIR="$( cd "$DIR0/../.." && pwd )"
  # On a machine, platform/ is a symlink into .stackyard/, and the `cd -P`
  # above has already resolved it: two levels up lands in .stackyard rather
  # than in the machine. state/ would then be created INSIDE the downloaded
  # layer and vanish on the next ./bootstrap, and until then the password
  # files, certificates and databases.yaml would sit where no container looks
  # for them. The wrappers in the machine root set ROOT_DIR themselves, but
  # every script documents being called as ./platform/bin/<name>.sh — that is
  # the path this fixes.
  [ "${ROOT_DIR##*/}" = .stackyard ] && ROOT_DIR="${ROOT_DIR%/*}"
fi
LIB_DIR="$( cd "$DIR0/../lib" && pwd )"
ENV_FILE="$ROOT_DIR/.env"

# Все `-f` и `--env-file` ниже — относительные. Переход гарантирует, что вызов
# из любого места (юнит systemd, чужой скрипт) найдёт эти файлы; каталог
# проекта задаётся отдельно, через --project-directory ниже.
cd "$ROOT_DIR"

# shellcheck source=platform/lib/lib-stacks.sh
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
  local f ex
  f="$(stack_env_file "$1")"
  # Образец ищем РЯДОМ СО СТЕКОМ, а не по машинному пути: у профильного стека
  # .env машинный, а .env.example лежит в profile/. Поиск образца по машинному
  # пути не нашёл бы его никогда, и `--examples` падал бы на профильном стеке
  # ровно там, где он существует, чтобы не падать.
  ex="$(stack_dir "$1")/.env.example"
  if [ -f "$f" ]; then printf '%s' "$f"
  elif [ "$USE_EXAMPLES" -eq 1 ] && [ -f "$ex" ]; then printf '%s' "$ex"
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
ensure_state_dirs

for gen in "$(stacks_static_file)" "$(stacks_include_file)"; do
  [ -f "$gen" ] && continue
  mkdir -p "$(dirname "$gen")"
  # Сравниваем со значением, а не с образцом имени. Образец был *00-enabled.conf
  # и пережил переименование файла в 10-: ветка перестала совпадать молча, и
  # генерируемый include не создавался вовсе.
  if [ "$gen" = "$(stacks_static_file)" ]; then
    stacks_static_content  > "$gen"
  else
    stacks_include_content > "$gen"
  fi
done

# Файл со списком баз тоже генерируемый, но живёт внутри стека pg и нужен
# только когда этот стек включён. Здесь его лишь СОЗДАЁМ пустым, если нет:
# docker на отсутствующий файл в bind-mount заводит КАТАЛОГ от root, и
# db-initializer потом падает на нём невнятно. Содержимое пишет stack.sh sync —
# сгенерировать его здесь нечем, docker-compose.sh намеренно не грузит
# lib-env.sh (см. заголовок lib-stacks.sh).
# Пусто, когда поставщик БД не включён вовсе — а это законное состояние: у
# машины с одним прокси-стеком общей СУБД нет. Без проверки на пустоту здесь
# получался `: > ""`, то есть любая compose-команда падала на машине, которой
# база не нужна, с сообщением про несуществующий файл.
DB_FILE="$(stacks_databases_file)"
if [ -n "$DB_FILE" ] && [ ! -f "$DB_FILE" ]; then
  mkdir -p "$(dirname "$DB_FILE")"
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

# Путь генерируемого файла спрашиваем у библиотеки. Второй раз написанное имя
# переживает переименование молча — ровно так `*00-enabled.conf` перестал
# совпадать после фикса A15, и генерируемый include не создавался вовсе.
STATIC_REL="$(stacks_static_file)"; STATIC_REL="${STATIC_REL#"$ROOT_DIR"/}"

DOCKER_COMPOSE_BASE+=(
  -f platform/compose/nginx.yaml
  -f "$STATIC_REL"
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

# Логин в реестры образов — перед командами, которые могут потянуть образ.
#
# Ровно то место, где логин обязан случиться: токен ECR живёт 12 часов, и
# «залогинься заранее» означает отказ pull'а в непредсказуемый момент. Здесь он
# всегда свежий, а лишних обращений нет — registry.sh держит штамп и молчит,
# если логин моложе восьми часов, и завершается сразу, если внешних реестров у
# включённых стеков нет вовсе. Машина без реестра платит один выход процесса.
#
# Отдельным процессом, а не через source: registry.sh грузит lib-env.sh,
# которого этот скрипт намеренно не знает (см. заголовок lib-stacks.sh).
#
# --soft: неудачный логин — предупреждение, а не отказ. Команде вроде
# `up -d nginx` реестр не нужен вовсе, и ронять её здесь значило бы делать
# машину зависимой от чужого сервиса там, где она от него не зависит.
#
# Проверки на существование файла тут НЕТ намеренно: registry.sh — часть
# платформы и обязан быть на месте. Guard `[ -x ]` (он был в оригинале) молча
# проглотил бы сломанную или пропавшую платформу, а это как раз то, о чём надо
# узнать сразу.
for arg in "$@"; do
  case "$arg" in
    -*) continue ;;
    pull|up|create|run)
      [ "$USE_EXAMPLES" -eq 0 ] && ROOT_DIR="$ROOT_DIR" "$DIR0/registry.sh" login --soft || true ;;
  esac
  break
done

# Выполняем сборную команду, подставляя все переданные аргументы ($@)
"${DOCKER_COMPOSE_BASE[@]}" "$@"
