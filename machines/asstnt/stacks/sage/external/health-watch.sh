#!/bin/sh

# Проверка живости sage СНАРУЖИ девбокса.
#
#   */2 * * * * /path/to/devbox-asstnt/stacks/sage/external/health-watch.sh \
#                ~/.sage-health-watch.env
#
# Ставится на любую машину, кроме проверяемой, — например на ноутбук. Проверка,
# работающая на проверяемой машине, не может сообщить, что машины нет: мёртвый
# таймер, отозванный токен и упавший хост выглядят снаружи одинаково —
# тишиной. Спящий ноутбук пропускает проверки, и пропущенная проверка означает
# «никто не смотрел», а не «всё хорошо».
#
# На POSIX sh, без зависимостей кроме curl: ставится в чужой crontab на машине,
# про которую ничего не известно.
#
# Коды возврата: 0 — отработал, 1 — не настроен или не смог отправить,
# 2 — вызван неправильно.

set -eu

CONFIG="${1:-}"

if [ -z "$CONFIG" ]; then
  echo "Использование: $0 <файл-конфигурации>" >&2
  echo "  Образец — .env.example рядом с этим скриптом." >&2
  exit 2
fi

if [ ! -r "$CONFIG" ]; then
  echo "Ошибка: файл '$CONFIG' не читается" >&2
  exit 2
fi

# Читаем построчно, а не через `.`: значение с пробелами или обратными кавычками
# в токене стало бы исполняемым кодом. Здесь же — файл с секретом.
SAGE_HEALTH_URL=""
SAGE_HEALTH_BOT_TOKEN=""
SAGE_HEALTH_CHAT_ID=""
SAGE_HEALTH_STATE=""
SAGE_HEALTH_TIMEOUT=""
SAGE_HEALTH_FAILURES=""
SAGE_HEALTH_TELEGRAM_API=""

while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    ''|'#'*) continue ;;
    *=*) ;;
    *) continue ;;
  esac
  key=${line%%=*}
  val=${line#*=}
  # Обрезать кавычки вокруг значения, если есть.
  case "$val" in
    \"*\") val=${val#\"}; val=${val%\"} ;;
    \'*\') val=${val#\'}; val=${val%\'} ;;
  esac
  case "$key" in
    SAGE_HEALTH_URL)          SAGE_HEALTH_URL=$val ;;
    SAGE_HEALTH_BOT_TOKEN)    SAGE_HEALTH_BOT_TOKEN=$val ;;
    SAGE_HEALTH_CHAT_ID)      SAGE_HEALTH_CHAT_ID=$val ;;
    SAGE_HEALTH_STATE)        SAGE_HEALTH_STATE=$val ;;
    SAGE_HEALTH_TIMEOUT)      SAGE_HEALTH_TIMEOUT=$val ;;
    SAGE_HEALTH_FAILURES)     SAGE_HEALTH_FAILURES=$val ;;
    SAGE_HEALTH_TELEGRAM_API) SAGE_HEALTH_TELEGRAM_API=$val ;;
  esac
done < "$CONFIG"

[ -n "$SAGE_HEALTH_URL" ]       || { echo "Ошибка: не задан SAGE_HEALTH_URL в $CONFIG" >&2; exit 1; }
[ -n "$SAGE_HEALTH_BOT_TOKEN" ] || { echo "Ошибка: не задан SAGE_HEALTH_BOT_TOKEN в $CONFIG" >&2; exit 1; }
[ -n "$SAGE_HEALTH_CHAT_ID" ]   || { echo "Ошибка: не задан SAGE_HEALTH_CHAT_ID в $CONFIG" >&2; exit 1; }

STATE=${SAGE_HEALTH_STATE:-$HOME/.sage-health-watch.state}
TIMEOUT=${SAGE_HEALTH_TIMEOUT:-10}
API=${SAGE_HEALTH_TELEGRAM_API:-https://api.telegram.org}

# Сколько провалов подряд считать авариёй. 1 превращает моргнувший wifi в
# тревогу, а watcher, который кричит волки, довольно быстро отключают.
FAILURES=${SAGE_HEALTH_FAILURES:-2}

# ------------------------------------------------------------- состояние

fails=0
alerted=0
if [ -r "$STATE" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      fails=*)   fails=${line#fails=} ;;
      alerted=*) alerted=${line#alerted=} ;;
    esac
  done < "$STATE"
fi
case "$fails"   in ''|*[!0-9]*) fails=0 ;;   esac
case "$alerted" in ''|*[!0-9]*) alerted=0 ;; esac

save_state() {
  # Через временный файл: прерванная запись оставила бы состояние, из которого
  # не понять, докладывали уже об аварии или нет, — и watcher начал бы либо
  # молчать, либо повторяться.
  tmp="$STATE.tmp.$$"
  printf 'fails=%s\nalerted=%s\n' "$1" "$2" > "$tmp"
  mv "$tmp" "$STATE"
}

# ------------------------------------------------------------- отправка

# Percent-encoding без внешних зависимостей: текст многострочный и по-русски, а
# на машине может не быть ни python, ни jq.
urlencode() {
  printf '%s' "$1" | od -An -tx1 -v | tr -d '\n' | tr -s ' ' '\n' | while IFS= read -r b; do
    [ -n "$b" ] || continue
    case "$b" in
      2d|2e|30|31|32|33|34|35|36|37|38|39|41|42|43|44|45|46|47|48|49|4a|4b|4c|4d|4e|4f|50|51|52|53|54|55|56|57|58|59|5a|5f|61|62|63|64|65|66|67|68|69|6a|6b|6c|6d|6e|6f|70|71|72|73|74|75|76|77|78|79|7a|7e)
        printf '%b' "\\x$b" ;;
      *) printf '%%%s' "$(printf '%s' "$b" | tr 'a-f' 'A-F')" ;;
    esac
  done
}

notify() {
  body="chat_id=$(urlencode "$SAGE_HEALTH_CHAT_ID")&text=$(urlencode "$1")"
  if ! curl -sS -o /dev/null -m "$TIMEOUT" \
       -X POST "$API/bot$SAGE_HEALTH_BOT_TOKEN/sendMessage" \
       --data-binary "$body" 2>/dev/null; then
    echo "Ошибка: не удалось отправить сообщение в Telegram" >&2
    return 1
  fi
}

# --------------------------------------------------------------- проверка

# Код ответа и факт ответа — разные вещи, и путать их нельзя: 502 значит, что
# машина жива и что-то отвечает, а отсутствие ответа значит, что её, возможно,
# нет вовсе. Второе тревожнее, и в сообщении это должно быть видно.
code=$(curl -sS -o /dev/null -w '%{http_code}' -m "$TIMEOUT" "$SAGE_HEALTH_URL" 2>/dev/null) || code=""
case "$code" in ''|*[!0-9]*) code="" ;; esac
[ "$code" = "000" ] && code=""

if [ "$code" = "200" ]; then
  if [ "$alerted" -eq 1 ]; then
    notify "sage: снова отвечает. $SAGE_HEALTH_URL — 200." || exit 1
  fi
  save_state 0 0
  exit 0
fi

fails=$((fails + 1))

if [ "$fails" -ge "$FAILURES" ] && [ "$alerted" -eq 0 ]; then
  if [ -z "$code" ]; then
    notify "sage: нет ответа от $SAGE_HEALTH_URL (проверок подряд: $fails). Хост может быть недоступен целиком." || exit 1
  else
    notify "sage: $SAGE_HEALTH_URL отвечает $code (проверок подряд: $fails)." || exit 1
  fi
  alerted=1
fi

save_state "$fails" "$alerted"
exit 0
