#!/usr/bin/env bash

# Проверка результата ротации логов харнесса, а не самого механизма.
#
# Существует по той же причине, что check-certs.sh и check-backups.sh: таймер,
# переставший срабатывать, выглядит ровно как таймер, которому нечего делать.
# logrotate молчит и когда отработал, и когда его не запускали, и когда конфиг
# указывает не туда. Отличить одно от другого может только независимый взгляд
# на результат — то есть на сами файлы.
#
# История, ради которой это есть: 26.08.2026 залипшая очередь outbox дала
# 278k строк cli_error и файл на 5.9 ГБ за сутки. Диск на этой машине 25 ГБ.
#
# Ненулевой код -> systemd помечает юнит как failed, и он всплывает в
# `systemctl --failed`, а не тонет в журнале.
#
#   ./scripts/check-logrotate.sh

set -uo pipefail

DIR0="$( cd -P "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
STACK_DIR="$( dirname "$DIR0" )"
ROOT_DIR="$( cd "$STACK_DIR/../.." && pwd )"

# shellcheck source=../../../scripts/lib-env.sh
. "$ROOT_DIR/scripts/lib-env.sh"
env_load_files "$ROOT_DIR/.env" "$STACK_DIR/.env"

home=$(env_get Sanya_Host_Home_Dir)
[ -n "$home" ] || { echo "Ошибка: нет Sanya_Host_Home_Dir в stacks/sanya/.env" >&2; exit 2; }

LOGS_DIR="$home/logs"
[ -d "$LOGS_DIR" ] || { echo "Ошибка: нет каталога $LOGS_DIR" >&2; exit 2; }

# Порог тревоги выше порога ротации (`size 200M` в harness.conf), но заметно
# ниже того, что убивает диск. Ровно 200 МБ брать нельзя: файл законно растёт
# до порога между часовыми запусками, и проверка кричала бы на исправной
# машине.
THRESHOLD_MB="${THRESHOLD_MB:-400}"

problems=0
found=0

while IFS= read -r f; do
  found=$((found + 1))
  # GNU stat (Linux) и BSD stat (macOS) разбирают это по-разному.
  bytes=$(stat -c '%s' "$f" 2>/dev/null || stat -f '%z' "$f")
  mb=$((bytes / 1024 / 1024))
  if [ "$mb" -ge "$THRESHOLD_MB" ]; then
    printf '%-50s %s МБ — ротация не отрабатывает\n' "$(basename "$f")" "$mb"
    problems=$((problems + 1))
  else
    printf '%-50s %s МБ, ok\n' "$(basename "$f")" "$mb"
  fi
done < <(find "$LOGS_DIR" -maxdepth 1 -name '*.jsonl' -type f 2>/dev/null)

if [ "$found" -eq 0 ]; then
  # Ни одного лога — это не «всё хорошо». Либо харнесс не пишет (то есть стек
  # не работает), либо ротация уводит файлы не туда. И то и другое стоит
  # заметить, а молчаливый успех здесь был бы худшим исходом.
  echo "Ошибка: в $LOGS_DIR нет ни одного *.jsonl — харнесс не пишет либо конфиг указывает не туда" >&2
  exit 1
fi

if [ "$problems" -gt 0 ]; then
  echo
  echo "Логов сверх порога: $problems из $found (порог $THRESHOLD_MB МБ)." >&2
  echo "Разбор: journalctl -u devbox-sanya-logrotate --since '-7 days'" >&2
  echo "Проверить конфиг, ничего не меняя:" >&2
  echo "  sudo logrotate -d --state /var/lib/sanya-logrotate/harness.state $STACK_DIR/logrotate/harness.conf" >&2
  exit 1
fi

echo
echo "Проверено логов: $found. Все меньше $THRESHOLD_MB МБ."
