#!/usr/bin/env bash

# Готов ли стек sanya к установке своих юнитов.
#
# Ротировать нечего, если стек здесь не развёрнут, а таймер, который каждую
# ночь падает, хуже отсутствующего. Ненулевой код = юниты не ставить; причину
# scripts/systemd.sh печатает как есть, поэтому она пишется в stdout и
# по-человечески.
#
# Заодно генерирует harness.conf из шаблона: logrotate не знает ни cwd, ни
# ${...}-подстановок, поэтому путь к логам обязан быть подставлен заранее.
# Делает это стек, а не платформа — платформе незачем знать про Sanya_*.

set -uo pipefail

DIR0="$( cd -P "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
STACK_DIR="$( dirname "$DIR0" )"
ROOT_DIR="$( cd "$STACK_DIR/../.." && pwd )"

# shellcheck source=../../../scripts/lib-env.sh
. "$ROOT_DIR/scripts/lib-env.sh"
env_load_files "$ROOT_DIR/.env" "$STACK_DIR/.env"

home=$(env_get Sanya_Host_Home_Dir)

if [ -z "$home" ]; then
  echo "нет Sanya_Host_Home_Dir в stacks/sanya/.env (cp .env.example .env)"
  exit 1
fi

# Абсолютный путь обязателен: ни юниты systemd, ни конфиг logrotate не знают
# ни cwd, ни ${...}-подстановок, которые здесь разворачивает docker compose.
case "$home" in
  /*) ;;
  *)  echo "Sanya_Host_Home_Dir не абсолютный путь: '$home'"; exit 1 ;;
esac

if [ ! -d "$home/logs" ]; then
  echo "нет каталога $home/logs — стек sanya здесь не развёрнут"
  exit 1
fi

# Проверяем РОВНО тот путь, который стоит в ExecStart юнита, а не просто
# наличие команды в $PATH. Юниты systemd требуют абсолютного пути и про $PATH
# ничего не знают, поэтому `command -v` здесь ответил бы не на тот вопрос: он
# сказал бы «logrotate есть», а таймер всё равно падал бы каждый час на
# несуществующем файле.
LOGROTATE_BIN=/usr/sbin/logrotate
if [ ! -x "$LOGROTATE_BIN" ]; then
  found=$(command -v logrotate || true)
  if [ -n "$found" ]; then
    echo "logrotate есть в $found, а юнит ждёт $LOGROTATE_BIN — поправьте ExecStart в stacks/sanya/systemd/"
  else
    echo "logrotate не установлен (sudo dnf install -y logrotate)"
  fi
  exit 1
fi

TEMPLATE="$STACK_DIR/logrotate/harness.conf.template"
if [ ! -f "$TEMPLATE" ]; then
  echo "нет шаблона $TEMPLATE"
  exit 1
fi

sed "s#@SANYA_HOME@#${home}#g" "$TEMPLATE" > "$STACK_DIR/logrotate/harness.conf"
chmod 644 "$STACK_DIR/logrotate/harness.conf"

exit 0
