#!/usr/bin/env bash

# The single place from which this machine sends notifications.
#
# Everything that wants to report something calls this script. The point of
# having exactly one is spam protection: it works only while the state is kept
# in one place.
#
#   notify.sh --key disk:/ --level crit --title "disk / is 93% full"
#   echo "detail" | notify.sh --key foo --level warn --title "..."
#   notify.sh --key disk:/ --resolve --title "disk / is back to normal"
#   notify.sh --unit devbox-backup.service     # OnFailure handler mode
#   notify.sh --heartbeat                      # the weekly digest
#   notify.sh --test                           # exercise the channel now
#
# WHY DEDUPLICATION IS MANDATORY. A unit failing hourly produces 24 messages a
# day without it. The channel stops being read within a week, and from then on
# monitoring exists but does not work — an outcome worse than having none,
# because it creates false confidence.
#
# THIS SCRIPT MUST NOT HAVE AN OnFailure. A handler whose failure starts a
# handler is a loop.

set -uo pipefail

DIR0="$( cd -P "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# The MACHINE's directory, not the platform's. Normally set by a wrapper in the
# machine root; the fallback is two levels up from platform/bin.
if [ -z "${ROOT_DIR:-}" ]; then
  ROOT_DIR="$( cd "$DIR0/../.." && pwd )"
  # On a machine, platform/ is a symlink into .stackyard/, and the `cd -P`
  # above has already resolved it: two levels up lands inside .stackyard
  # rather than in the machine. state/ would then be created INSIDE the downloaded
  # layer and vanish on the next ./bootstrap, and until then the password
  # files, certificates and databases.yaml would sit where no container looks
  # for them. The wrappers in the machine root set ROOT_DIR themselves, but
  # every script documents being called as ./platform/bin/<name>.sh — that is
  # the path this fixes.
  # Everything from .stackyard on is cut: the platform sits two levels deeper
  # there (versions/<commit>/), and a machine still on the flat layout lands
  # on .stackyard itself.
  ROOT_DIR="${ROOT_DIR%%/.stackyard/*}"; ROOT_DIR="${ROOT_DIR%/.stackyard}"
fi
LIB_DIR="$( cd "$DIR0/../lib" && pwd )"

# shellcheck source=platform/lib/lib-env.sh
. "$LIB_DIR/lib-env.sh"

# Overridable only for tests: the production path is /var/lib/devbox-notify and
# the units do not override it. Without this, deduplication and recovery could
# be exercised only as root on a live machine.
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
Usage:
  notify.sh --key <key> --level <info|warn|crit> --title <title> [--force]
        send an alert. The body may be supplied on stdin.
        --force ignores the cooldown.

  notify.sh --key <key> --resolve --title <title>
        report that the problem behind this key is over. Sent only if an alert
        was previously raised for that key.

  notify.sh --unit <unit>      OnFailure handler mode: the title and a journal
                               excerpt are assembled automatically
  notify.sh --heartbeat        a digest of the machine's state
  notify.sh --test             check that the channel is configured and works

Configuration: .env-notify (see .env-notify.example).
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
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

log() { echo "$*"; }
die() { echo "Error: $*" >&2; exit 2; }

# --------------------------------------------------------------- configuration

ENV_NOTIFY="$ROOT_DIR/.env-notify"
[ -f "$ENV_NOTIFY" ] || die "no $ENV_NOTIFY — cp .env-notify.example .env-notify && chmod 600"

env_load_files "$ROOT_DIR/.env" "$ROOT_DIR/.env-backup" "$ENV_NOTIFY"

TOKEN=$(env_get Notify_Telegram_Token)
CHAT_ID=$(env_get Notify_Telegram_Chat_Id)
ENABLED=$(env_get Notify_Enabled true)
COOLDOWN_H=$(env_get Notify_Cooldown_Hours 6)

[ -n "$TOKEN" ]   || die "Notify_Telegram_Token is not set"
[ -n "$CHAT_ID" ] || die "Notify_Telegram_Chat_Id is not set"
case "$COOLDOWN_H" in ''|*[!0-9]*) die "Notify_Cooldown_Hours must be an integer" ;; esac

# What to call this machine in an alert.
#
# The default is the name of the machine's directory — the same name fleet.sh
# and audit-isolation.sh print, so one machine is called one thing everywhere.
# The EC2-style hostname alone ("ip-172-30-2-248") answers "which instance",
# never "which machine", and an alert whose subject has to be looked up is an
# alert that gets postponed.
#
# The hostname goes into the footer rather than the title: in the title it
# reads as the subject and pushes the machine's name out of the notification
# preview. It is kept at all because after a rebuild the label stays the same
# while the instance changes, and that difference is occasionally the whole
# story.
MACHINE=$(env_get Notify_Machine "$(basename "$ROOT_DIR")")
HOSTNAME_S=$(hostname -s 2>/dev/null || hostname)
[ "$MACHINE" = "$HOSTNAME_S" ] && HOSTNAME_S=""
NOW=$(date -u +%s)

# ------------------------------------------------------------------ sending

# HTML rather than Markdown. MarkdownV2 reserves eighteen characters, and
# journalctl or docker logs contain some of them in almost every line: one
# unescaped dot and Telegram answers 400, and the alert never arrives. HTML
# reserves three — & < > — and escaping those is a single sed.
html_escape() {
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

emoji_for() {
  case "$1" in
    crit) printf '🔴' ;;
    warn) printf '🟠' ;;
    ok)   printf '✅' ;;
    *)    printf 'ℹ️'  ;;
  esac
}

# compose <html|plain> <level> <title> <body> <key>
#
# The body is truncated HERE, on the raw text, and not after composing:
# cutting finished HTML can split a tag or an entity, and Telegram rejects the
# whole message. The limit is 4096 characters of VISIBLE text, so the markup
# itself does not count against it.
compose() {
  local fmt="$1" level="$2" title="$3" body="$4" key="$5" time footer budget
  time="$(date -u '+%Y-%m-%d %H:%M') UTC"

  budget=$(( TG_LIMIT - ${#MACHINE} - ${#title} - ${#HOSTNAME_S} - ${#key} - ${#time} - 80 ))
  if [ "${#body}" -gt "$budget" ]; then
    body="${body:0:$budget}"$'\n'"... (truncated)"
  fi

  if [ "$fmt" = plain ]; then
    printf '%s %s — %s\n' "$(emoji_for "$level")" "$MACHINE" "$title"
    if [ -n "$body" ]; then printf '\n%s\n' "$body"; fi
    printf '\n--\n'
    [ -n "$HOSTNAME_S" ] && printf 'host: %s\n' "$HOSTNAME_S"
    [ -n "$key" ] && printf 'key:  %s\n' "$key"
    printf 'time: %s\n' "$time"
    return 0
  fi

  printf '%s <b>%s</b> — %s\n' "$(emoji_for "$level")" \
    "$(html_escape "$MACHINE")" "$(html_escape "$title")"
  # Collapsed: 25 lines of logs are the evidence, not the message. Telegram
  # shows the first few and folds the rest behind a tap.
  if [ -n "$body" ]; then
    printf '\n<blockquote expandable>%s</blockquote>\n' "$(html_escape "$body")"
  fi
  footer=""
  [ -n "$HOSTNAME_S" ] && footer+="$(html_escape "$HOSTNAME_S") · "
  [ -n "$key" ] && footer+="<code>$(html_escape "$key")</code> · "
  footer+="$time"
  printf '\n<i>%s</i>\n' "$footer"
}

# tg_post <text> [parse_mode] — one message, with retries. The response is left
# in $TG_RESP for the caller to inspect.
tg_post() {
  local text="$1" mode="${2-}" attempt code
  local args=(--data-urlencode "chat_id=${CHAT_ID}"
              --data-urlencode "text=${text}"
              --data-urlencode "disable_web_page_preview=true")
  [ -n "$mode" ] && args+=(--data-urlencode "parse_mode=${mode}")

  for attempt in 1 2 3; do
    # --max-time is mandatory: a hung curl inside an OnFailure handler would
    # hold the unit, and Type=oneshot has no start timeout by default.
    code=$(curl -sS --max-time 15 -o "$TG_RESP" -w '%{http_code}' \
             -X POST "https://api.telegram.org/bot${TOKEN}/sendMessage" \
             "${args[@]}" 2>/dev/null)

    if [ "$code" = "200" ] && grep -q '"ok":true' "$TG_RESP"; then
      return 0
    fi
    echo "  attempt $attempt: HTTP $code, response: $(head -c 300 "$TG_RESP" 2>/dev/null)" >&2
    # A 400 is the message itself, not the network: repeating it verbatim
    # gets the same answer three times.
    [ "$code" = "400" ] && return 1
    [ "$attempt" -lt 3 ] && sleep 5
  done
  return 1
}

# tg_send <level> <title> <body> <key>
#
# If Telegram still refuses the markup ("can't parse entities"), the same
# message goes out once more as plain text. An ugly alert is a nuisance; a
# lost one is the failure this script exists to prevent.
tg_send() {
  local level="$1" title="$2" body="$3" key="$4" rc=1
  if [ "$ENABLED" != "true" ]; then
    log "Notify_Enabled=$ENABLED — not sent (muted deliberately). The message:"
    compose plain "$level" "$title" "$body" "$key" | sed 's/^/  | /'
    return 0
  fi

  TG_RESP=$(mktemp) || return 1
  if tg_post "$(compose html "$level" "$title" "$body" "$key")" HTML; then
    rc=0
  elif grep -q "can't parse entities" "$TG_RESP"; then
    echo "  the markup was rejected — resending as plain text" >&2
    tg_post "$(compose plain "$level" "$title" "$body" "$key")" && rc=0
  fi
  rm -f "$TG_RESP"
  return "$rc"
}

# The key becomes a file name — everything that could escape it is stripped.
state_file() {
  printf '%s/%s.state' "$STATE_DIR" "$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_')"
}

# Muting is handled inside tg_send, not here. Checking it at this point meant
# leaving before any mode had composed its message, so the one command whose
# job is to show what WOULD be sent printed an empty title. A dry run that
# shows nothing is worse than no dry run: it looks like the message is empty.
if [ "$ENABLED" = "true" ]; then
  install -d -m 700 "$STATE_DIR" 2>/dev/null || die "cannot create $STATE_DIR (root required)"
else
  # Muted runs are how a person inspects the text, and they must not demand
  # root for a directory nothing will be written to.
  install -d -m 700 "$STATE_DIR" 2>/dev/null || true
fi

# ------------------------------------------------------------------- modes

case "$MODE" in

  test)
    if tg_send info 'channel test' 'If you are reading this, notifications are configured and working.' ''; then
      log "Sent. Check the chat."
    else
      die "sending failed — see the output above"
    fi
    exit 0
    ;;

  heartbeat)
    # A digest rather than a bare "I am alive": the same cost, more use. The
    # point is that silence in the channel should be corroborated — otherwise a
    # broken notifier is indistinguishable from an absence of problems.
    body=""
    body+="uptime:   $(uptime | sed 's/.*up //; s/,  *[0-9]* user.*//')"$'\n'
    body+="memory:   $(free -m 2>/dev/null | awk '/^Mem:/ {printf "%d/%d MiB used", $3, $2}')"$'\n'
    body+="disk:     $(df -Ph / | awk 'NR==2 {printf "%s of %s (%s)", $3, $2, $5}')"$'\n'
    body+="inode:    $(df -Pi / | awk 'NR==2 {print $5}')"$'\n'

    running=$(docker ps -q 2>/dev/null | wc -l | tr -d ' ')
    total=$(docker ps -aq 2>/dev/null | wc -l | tr -d ' ')
    body+="containers: $running of $total running"$'\n'

    failed=$(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}' | paste -sd' ' -)
    body+="failed units: ${failed:-none}"$'\n'

    if [ -x "$DIR0/check-backups.sh" ] && [ -f "$ROOT_DIR/.env-backup" ]; then
      body+=$'\n'"backups:"$'\n'
      body+="$("$DIR0/check-backups.sh" 2>&1 | grep -vE '^\s*$' | tail -8)"
    fi

    tg_send info 'weekly digest' "$body" '' || die "could not send the digest"
    log "Digest sent."
    exit 0
    ;;

  unit)
    [ -n "${UNIT:-}" ] || die "--unit without a unit name"
    LEVEL=crit
    TITLE="unit $UNIT failed"
    result=$(systemctl show "$UNIT" -p Result --value 2>/dev/null)
    BODY="result: ${result:-unknown}"$'\n\n'
    BODY+="$(journalctl -u "$UNIT" -n 25 --no-pager -o cat 2>/dev/null | tail -25)"
    ;;

  resolve)
    [ -n "$KEY" ] || die "--resolve without --key"
    sf=$(state_file "$KEY")
    if [ ! -f "$sf" ]; then
      # Nobody raised an alert for this key — there is nothing to report.
      # Silence is correct here: otherwise every watch-host run would send an
      # "all is well" for every key.
      exit 0
    fi
    rm -f "$sf"
    tg_send ok "${TITLE:-$KEY recovered}" '' "$KEY" \
      || die "could not send the recovery message"
    log "Recovery for key '$KEY' sent."
    exit 0
    ;;

  send) ;;
esac

# --------------------------------------------------- an ordinary alert

[ -n "$KEY" ]   || die "--key is required"
[ -n "$TITLE" ] || die "--title is required"

# The body comes from stdin only when something was ACTUALLY put there.
#
# Testing `[ ! -t 0 ]` will not do, and that is not a theoretical quibble: when
# this script is called from another script without a redirection, stdin is
# simply inherited from the parent, "not a terminal" is true, and `cat` waits
# for an EOF that never comes. A systemd unit would hide this (stdin is
# /dev/null there), while a manual call from watch-host.sh would hang forever.
#
# A pipe (`echo ... |`) and a regular file (bash expands `<<<` into a temporary
# file) are the only two cases where there is data for us.
if [ -z "$BODY" ] && { [ -p /dev/stdin ] || [ -f /dev/stdin ]; }; then
  BODY=$(cat)
fi

sf=$(state_file "$KEY")

if [ "$FORCE" -ne 1 ] && [ -f "$sf" ]; then
  last=$(cut -d' ' -f1 "$sf" 2>/dev/null)
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  age_h=$(( (NOW - last) / 3600 ))
  if [ "$age_h" -lt "$COOLDOWN_H" ]; then
    log "Suppressed: key '$KEY' was already reported ${age_h}h ago (cooldown ${COOLDOWN_H}h)."
    exit 0
  fi
fi

if tg_send "$LEVEL" "$TITLE" "$BODY" "$KEY"; then
  echo "$NOW $LEVEL" > "$sf"
  log "Sent: [$LEVEL] $TITLE"
  exit 0
fi

# The state is NOT updated: the message did not get through, and the next run
# must try again rather than assume it already reported.
die "sending failed: [$LEVEL] $TITLE"
