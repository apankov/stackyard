#!/bin/sh
# Exercises `health-watch.sh` against local stubs. No network, no secrets, no
# Telegram: the "bot" here is a file the stub appends to.
#
#   ./test-health-watch.sh
#
# It is a shell script and not a vitest suite because the thing under test is a
# shell script that runs from cron on a machine that has no repo checked out.
# Testing it through a Node harness would test something else.
set -eu

# Тест лежит в tests/, предмет — в external/: health-watch.sh ставится на
# ноутбук, а не на девбокс, и в каталог рядом с тестами ему попадать незачем.
DIR=$(cd "$(dirname "$0")/../external" && pwd)
WORK=$(mktemp -d)
# `wait` after the kill, so the shell reaps the stubs quietly instead of
# printing "Terminated: 15" over the test's own output.
cleanup() {
  kill ${HEALTH_PID:-} ${TG_PID:-} 2>/dev/null || true
  wait ${HEALTH_PID:-} ${TG_PID:-} 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

failures=0
check() {
  if [ "$2" = "$3" ]; then
    echo "  ✓ $1"
  else
    echo "  ✗ $1: expected [$3], got [$2]"
    failures=$((failures + 1))
  fi
}

# --- stubs ----------------------------------------------------------------
# The health endpoint answers whatever `$WORK/code` says, so an outage is one
# `echo` away. The Telegram stub records every message it is asked to send.
cat > "$WORK/stub.py" <<'PY'
import os, sys, urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer

WORK = sys.argv[1]
KIND = sys.argv[2]

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        code = int(open(os.path.join(WORK, 'code')).read().strip())
        self.send_response(code)
        self.end_headers()
        self.wfile.write(b'{"status":"ok","database":"ok"}' if code == 200 else b'bad gateway')

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get('content-length', 0))).decode()
        # Decoded and flattened to one line: the script sends the text
        # percent-encoded and multi-line, and the assertions below want to
        # grep for what a person would read.
        fields = dict(urllib.parse.parse_qsl(body))
        with open(os.path.join(WORK, 'sent'), 'a') as f:
            f.write(' '.join(fields.get('text', '').split()) + '\n')
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b'{"ok":true}')

HTTPServer(('127.0.0.1', int(sys.argv[3])), Handler).serve_forever()
PY

: > "$WORK/sent"
echo 200 > "$WORK/code"
python3 "$WORK/stub.py" "$WORK" health 18771 &
HEALTH_PID=$!
python3 "$WORK/stub.py" "$WORK" telegram 18772 &
TG_PID=$!

# Wait for both to accept connections rather than sleeping a guessed amount.
i=0
while [ $i -lt 100 ]; do
  if curl -sS -o /dev/null -m 1 http://127.0.0.1:18771/health 2>/dev/null; then break; fi
  i=$((i + 1))
done

cat > "$WORK/config" <<EOF
SAGE_HEALTH_URL=http://127.0.0.1:18771/health
SAGE_HEALTH_BOT_TOKEN=stub-token
SAGE_HEALTH_CHAT_ID=42
SAGE_HEALTH_STATE=$WORK/state
SAGE_HEALTH_TIMEOUT=3
SAGE_HEALTH_TELEGRAM_API=http://127.0.0.1:18772
EOF

run() { sh "$DIR/health-watch.sh" "$WORK/config" >/dev/null 2>&1 || true; }
messages() { wc -l < "$WORK/sent" | tr -d ' '; }

# --- the state machine ----------------------------------------------------
run
check "a healthy API says nothing" "$(messages)" "0"

echo 502 > "$WORK/code"
run
check "one failure is not an outage yet" "$(messages)" "0"

run
check "the second failure is reported" "$(messages)" "1"
check "the message names the status code" "$(grep -c '502' "$WORK/sent")" "1"

run
run
check "a continuing outage is not repeated every two minutes" "$(messages)" "1"

echo 200 > "$WORK/code"
run
check "recovery is reported" "$(messages)" "2"
check "the recovery message says so" "$(grep -c 'снова' "$WORK/sent")" "1"

run
check "staying up stays quiet" "$(messages)" "2"

# --- no answer at all -----------------------------------------------------
# Distinct from a status code, and the more alarming of the two: the host is
# not merely broken, it is not there.
kill "$HEALTH_PID" 2>/dev/null || true
wait "$HEALTH_PID" 2>/dev/null || true
HEALTH_PID=
run
run
check "an unreachable host is reported" "$(messages)" "3"
check "and is not called an HTTP code" "$(grep -c 'нет ответа' "$WORK/sent")" "1"

# --- refusing to run half-configured --------------------------------------
sh "$DIR/health-watch.sh" >/dev/null 2>&1 && rc=0 || rc=$?
check "no config file is a usage error, not a silent success" "$rc" "2"

sh "$DIR/health-watch.sh" "$WORK/nope" >/dev/null 2>&1 && rc=0 || rc=$?
check "an unreadable config is an error" "$rc" "2"

grep -v BOT_TOKEN "$WORK/config" > "$WORK/config-partial"
sh "$DIR/health-watch.sh" "$WORK/config-partial" >/dev/null 2>&1 && rc=0 || rc=$?
check "a missing token stops the run rather than sending nowhere" "$rc" "1"

if [ "$failures" -eq 0 ]; then
  echo "health-watch: всё сошлось"
else
  echo "health-watch: провалов: $failures"
  exit 1
fi
