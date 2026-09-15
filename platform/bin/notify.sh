#!/usr/bin/env bash

# Единственная точка отправки оповещений девбокса в Telegram.
#
# Всё, что хочет о чём-то сообщить, зовёт этот скрипт. Смысл единственности —
# в защите от спама: она работает, только если состояние ведётся в одном месте.
#
#   notify.sh --key disk:/ --level crit --title "Диск / заполнен на 93%"
#   echo "детали" | notify.sh --key foo --level warn --title "..."
#   notify.sh --key disk:/ --resolve --title "Диск / снова в норме"
#   notify.sh --unit devbox-backup.service     # режим обработчика OnFailure
#   notify.sh --heartbeat                      # еженедельная сводка
#   notify.sh --test                           # проверить канал прямо сейчас
#
# ПОЧЕМУ ДЕДУПЛИКАЦИЯ ОБЯЗАТЕЛЬНА. Юнит, падающий ежечасно, без неё даёт 24
# сообщения в сутки. Канал перестают читать за неделю, и дальше мониторинг
# существует, но не работает — исход хуже, чем его отсутствие, потому что
# создаёт ложную уверенность.
#
# ЭТОТ СКРИПТ НЕ ДОЛЖЕН ИМЕТЬ OnFailure. Обработчик, падение которого запускает
# обработчик, — это цикл.

set -uo pipefail

DIR0="$( cd -P "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# Каталог МАШИНЫ, а не платформы. Обычно его задаёт обёртка в корне машины;
# запасной вариант — на два уровня вверх от platform/bin.
ROOT_DIR="${ROOT_DIR:-$( cd "$DIR0/../.." && pwd )}"
LIB_DIR="$( cd "$DIR0/../lib" && pwd )"

# shellcheck source=scripts/lib-env.sh
. "$LIB_DIR/lib-env.sh"

# Переопределяется только ради тестов: боевой путь — /var/lib/devbox-notify,
# и юниты его не переопределяют. Без этого проверить дедупликацию и
# восстановление можно было бы только от root на живой машине.
STATE_DIR="${DEVBOX_NOTIFY_STATE_DIR:-/var/lib/devbox-notify}"
TG_LIMIT=4096

KEY=""
LEVEL="warn"
TITLE=""
BODY=""
MODE="send"
FORCE=0

usage() {
  cat <<'EOF'
Использование:
  notify.sh --key <ключ> --level <info|warn|crit> --title <заголовок> [--force]
        отправить оповещение. Тело можно подать в stdin.
        --force — игнорировать cooldown.

  notify.sh --key <ключ> --resolve --title <заголовок>
        сообщить, что проблема с этим ключом кончилась. Отправляется, только
        если по ключу до этого было оповещение.

  notify.sh --unit <юнит>      режим обработчика OnFailure: заголовок и выжимка
                               из журнала собираются сами
  notify.sh --heartbeat        сводка о состоянии машины
  notify.sh --test             проверить, что канал настроен и работает

Настройка — .env-notify (образец: .env-notify.example).
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --key)       shift; KEY="${1-}"; shift || true ;;
    --level)     shift; LEVEL="${1-}"; shift || true ;;
    --title)     shift; TITLE="${1-}"; shift || true ;;
    --resolve)   MODE=resolve; shift ;;
    --unit)      MODE=unit; shift; KEY="unit:${1-}"; UNIT="${1-}"; shift || true ;;
    --heartbeat) MODE=heartbeat; shift ;;
    --test)      MODE=test; shift ;;
    --force)     FORCE=1; shift ;;
    --help|-h)   usage; exit 0 ;;
    *) echo "Неизвестный аргумент: $1" >&2; usage >&2; exit 2 ;;
  esac
done

log() { echo "$*"; }
die() { echo "Ошибка: $*" >&2; exit 2; }

# --------------------------------------------------------------- конфигурация

ENV_NOTIFY="$ROOT_DIR/.env-notify"
[ -f "$ENV_NOTIFY" ] || die "нет $ENV_NOTIFY — cp .env-notify.example .env-notify && chmod 600"

env_load_files "$ROOT_DIR/.env" "$ROOT_DIR/.env-backup" "$ENV_NOTIFY"

TOKEN=$(env_get Notify_Telegram_Token)
CHAT_ID=$(env_get Notify_Telegram_Chat_Id)
ENABLED=$(env_get Notify_Enabled true)
COOLDOWN_H=$(env_get Notify_Cooldown_Hours 6)

[ -n "$TOKEN" ]   || die "Notify_Telegram_Token не задан"
[ -n "$CHAT_ID" ] || die "Notify_Telegram_Chat_Id не задан"
case "$COOLDOWN_H" in ''|*[!0-9]*) die "Notify_Cooldown_Hours должно быть целым числом" ;; esac

HOSTNAME_S=$(hostname -s 2>/dev/null || hostname)
NOW=$(date -u +%s)

# ------------------------------------------------------------------ отправка

# Простой текст, БЕЗ parse_mode. Вывод journalctl регулярно содержит символы,
# на которых разбор Markdown у Telegram падает с 400, — и алерт молча не
# доходит. Это отказ ровно того класса, который мы здесь чиним.
tg_send() {
  local text="$1" attempt code resp

  # Лимит Telegram — 4096 символов. Режем по символам, а не по байтам:
  # кириллица иначе обрубается посреди символа.
  if [ "${#text}" -gt "$TG_LIMIT" ]; then
    text="${text:0:$((TG_LIMIT - 40))}"$'\n'"… (обрезано)"
  fi

  resp=$(mktemp) || return 1
  for attempt in 1 2 3; do
    # --max-time обязателен: зависший curl в обработчике OnFailure держал бы
    # юнит, а Type=oneshot по умолчанию без таймаута старта.
    code=$(curl -sS --max-time 15 -o "$resp" -w '%{http_code}' \
             -X POST "https://api.telegram.org/bot${TOKEN}/sendMessage" \
             --data-urlencode "chat_id=${CHAT_ID}" \
             --data-urlencode "text=${text}" \
             --data-urlencode "disable_web_page_preview=true" 2>/dev/null)

    if [ "$code" = "200" ] && grep -q '"ok":true' "$resp"; then
      rm -f "$resp"
      return 0
    fi
    echo "  попытка $attempt: HTTP $code, ответ: $(head -c 300 "$resp" 2>/dev/null)" >&2
    [ "$attempt" -lt 3 ] && sleep 5
  done
  rm -f "$resp"
  return 1
}

emoji_for() {
  case "$1" in
    crit) printf '[!!]' ;;
    warn) printf '[!]'  ;;
    ok)   printf '[ok]' ;;
    *)    printf '[i]'  ;;
  esac
}

compose() {
  local level="$1" title="$2" body="$3" key="$4"
  printf '%s devbox/%s — %s\n' "$(emoji_for "$level")" "$HOSTNAME_S" "$title"
  if [ -n "$body" ]; then printf '\n%s\n' "$body"; fi
  printf '\n--\n'
  [ -n "$key" ] && printf 'ключ:  %s\n' "$key"
  printf 'время: %s UTC\n' "$(date -u '+%Y-%m-%d %H:%M')"
}

# Ключ становится именем файла — вычищаем всё, что может из него выбраться.
state_file() {
  printf '%s/%s.state' "$STATE_DIR" "$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_')"
}

if [ "$ENABLED" != "true" ]; then
  log "Notify_Enabled=$ENABLED — сообщение не отправлено (заглушено намеренно):"
  log "  [$LEVEL] $TITLE"
  exit 0
fi

install -d -m 700 "$STATE_DIR" 2>/dev/null || die "не создать $STATE_DIR (нужен root)"

# ------------------------------------------------------------------- режимы

case "$MODE" in

  test)
    if tg_send "$(compose info 'проверка канала' 'Если вы это читаете — оповещения настроены и работают.' '')"; then
      log "Отправлено. Проверьте группу."
    else
      die "отправить не удалось — см. вывод выше"
    fi
    exit 0
    ;;

  heartbeat)
    # Не «я жив», а сводка: той же ценой, а пользы больше. Смысл в том, чтобы
    # тишина в канале имела подтверждение — иначе неработающий нотификатор
    # неотличим от отсутствия проблем.
    body=""
    body+="аптайм:   $(uptime | sed 's/.*up //; s/,  *[0-9]* user.*//')"$'\n'
    body+="память:   $(free -m 2>/dev/null | awk '/^Mem:/ {printf "%d/%d МиБ занято", $3, $2}')"$'\n'
    body+="диск:     $(df -Ph / | awk 'NR==2 {printf "%s из %s (%s)", $3, $2, $5}')"$'\n'
    body+="inode:    $(df -Pi / | awk 'NR==2 {print $5}')"$'\n'

    running=$(docker ps -q 2>/dev/null | wc -l | tr -d ' ')
    total=$(docker ps -aq 2>/dev/null | wc -l | tr -d ' ')
    body+="контейнеры: $running из $total запущено"$'\n'

    failed=$(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}' | paste -sd' ' -)
    body+="упавшие юниты: ${failed:-нет}"$'\n'

    if [ -x "$DIR0/check-backups.sh" ] && [ -f "$ROOT_DIR/.env-backup" ]; then
      body+=$'\n'"бэкапы:"$'\n'
      body+="$("$DIR0/check-backups.sh" 2>&1 | grep -vE '^\s*$' | tail -8)"
    fi

    tg_send "$(compose info 'еженедельная сводка' "$body" '')" || die "сводку отправить не удалось"
    log "Сводка отправлена."
    exit 0
    ;;

  unit)
    [ -n "${UNIT:-}" ] || die "--unit без имени юнита"
    LEVEL=crit
    TITLE="юнит $UNIT — сбой"
    result=$(systemctl show "$UNIT" -p Result --value 2>/dev/null)
    BODY="результат: ${result:-неизвестен}"$'\n\n'
    BODY+="$(journalctl -u "$UNIT" -n 25 --no-pager -o cat 2>/dev/null | tail -25)"
    ;;

  resolve)
    [ -n "$KEY" ] || die "--resolve без --key"
    sf=$(state_file "$KEY")
    if [ ! -f "$sf" ]; then
      # По этому ключу никто не тревожился — сообщать не о чем. Молчание здесь
      # правильное: иначе каждый прогон watch-host слал бы «всё хорошо» по
      # каждому ключу.
      exit 0
    fi
    rm -f "$sf"
    tg_send "$(compose ok "${TITLE:-$KEY — восстановлено}" '' "$KEY")" \
      || die "сообщение о восстановлении отправить не удалось"
    log "Восстановление по ключу '$KEY' отправлено."
    exit 0
    ;;

  send) ;;
esac

# --------------------------------------------------- обычное оповещение

[ -n "$KEY" ]   || die "не задан --key"
[ -n "$TITLE" ] || die "не задан --title"

# Тело из stdin, если его туда ДЕЙСТВИТЕЛЬНО подали.
#
# Проверять `[ ! -t 0 ]` здесь нельзя, и это не теоретическая придирка: когда
# скрипт зовут из другого скрипта без перенаправления, stdin просто наследуется
# от родителя, «не терминал» истинно, а `cat` ждёт EOF, которого никогда не
# будет. Юнит systemd это скрыл бы (там stdin — /dev/null), а ручной вызов из
# watch-host.sh повис бы навсегда.
#
# Канал (`echo … |`) и обычный файл (bash разворачивает `<<<` во временный
# файл) — единственные два случая, когда данные для нас есть.
if [ -z "$BODY" ] && { [ -p /dev/stdin ] || [ -f /dev/stdin ]; }; then
  BODY=$(cat)
fi

sf=$(state_file "$KEY")

if [ "$FORCE" -ne 1 ] && [ -f "$sf" ]; then
  last=$(cut -d' ' -f1 "$sf" 2>/dev/null)
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  age_h=$(( (NOW - last) / 3600 ))
  if [ "$age_h" -lt "$COOLDOWN_H" ]; then
    log "Подавлено: по ключу '$KEY' уже сообщали $age_h ч назад (cooldown $COOLDOWN_H ч)."
    exit 0
  fi
fi

if tg_send "$(compose "$LEVEL" "$TITLE" "$BODY" "$KEY")"; then
  echo "$NOW $LEVEL" > "$sf"
  log "Отправлено: [$LEVEL] $TITLE"
  exit 0
fi

# Состояние НЕ обновляем: сообщение не дошло, и следующий прогон должен
# попробовать снова, а не считать, что уже сообщил.
die "отправить не удалось: [$LEVEL] $TITLE"
