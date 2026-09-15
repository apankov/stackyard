#!/usr/bin/env bash

# Готов ли стек ingester к установке своих юнитов.
#
# Проверять конвейер, которого здесь нет, бессмысленно, а таймер, падающий
# каждый час, хуже отсутствующего. Ненулевой код = юниты не ставить; причину
# scripts/systemd.sh печатает как есть, поэтому она пишется в stdout
# и по-человечески.

set -uo pipefail

DIR0="$( cd -P "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
STACK_DIR="$( dirname "$DIR0" )"
ROOT_DIR="$( cd "$STACK_DIR/../.." && pwd )"

# shellcheck source=../../../scripts/lib-env.sh
. "$ROOT_DIR/scripts/lib-env.sh"
env_load_files "$ROOT_DIR/.env" "$STACK_DIR/.env"

home=$(env_get Ingester_Host_Home_Dir)
data=$(env_get Ingester_Data_Dir)

if [ -z "$home" ] || [ -z "$data" ]; then
  echo "нет Ingester_Host_Home_Dir или Ingester_Data_Dir в stacks/ingester/.env (cp .env.example .env)"
  exit 1
fi

# Абсолютный путь обязателен: юниты systemd не знают ни cwd, ни ${...}.
for path in "$home" "$data"; do
  case "$path" in
    /*) ;;
    *)  echo "путь не абсолютный: '$path'"; exit 1 ;;
  esac
done

if [ ! -d "$home" ]; then
  echo "нет чекаута $home — стек ingester здесь не развёрнут"
  exit 1
fi

# Каталоги данных создаёт человек, а не docker: отсутствующий host-путь
# bind-mount'а docker заводит САМ И ОТ ROOT, и тогда контейнер под
# Ingester_Run_As в них не запишет, а bind-mount уже будет занят.
missing=""
for sub in raw machine inbox derived codex; do
  [ -d "$data/$sub" ] || missing="$missing $data/$sub"
done
if [ -n "$missing" ]; then
  echo "нет каталогов данных:$missing"
  echo "создайте их владельцем Ingester_Run_As, до первого up -d (см. README стека)"
  exit 1
fi

# Волт без гита — не «немного хуже», а другая система: пропадают история,
# мост с маком и правило «сначала зафиксировать чужую правку». Каталоги при
# этом на месте, так что предыдущая проверка такое пропускает — и конвейер
# узнаёт об этом пятью мёртвыми работами позже.
no_git=""
for sub in raw machine; do
  [ -d "$data/$sub/.git" ] || no_git="$no_git $data/$sub"
done
if [ -n "$no_git" ]; then
  echo "волты не инициализированы:$no_git"
  echo "запустите: $home/scripts/bootstrap-vaults.sh $data/raw $data/machine"
  exit 1
fi

# Конфиг приложения приезжает из гита и копировать его не надо — но если
# смонтирован не тот каталог, контейнер падает на старте с «Конфигурация
# не найдена». Проверяем ровно тот путь, который уйдёт в bind-mount.
if [ ! -f "$home/config/ingester.yaml" ]; then
  echo "нет $home/config/ingester.yaml — это не тот чекаут или он неполный"
  exit 1
fi

exit 0
