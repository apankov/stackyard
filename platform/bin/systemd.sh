#!/usr/bin/env bash

# Installing the systemd timers: certificate renewal through getssl, an expiry
# check, a daily backup to S3 with its own independent check, notifications (an
# OnFailure handler, host watching, a weekly digest) — plus the units the
# stacks bring with them.
#
# systemd rather than cron because systemd is already present on the machine
# and needs nothing installed.
#
# The script is idempotent: running it again reinstalls the units and reloads
# the configuration without breaking anything.
#
#   sudo ./platform/bin/systemd.sh           install the units, enable the timers
#   ./platform/bin/systemd.sh --check        compare what is installed with what
#                                            this would install; change nothing
#
# --check exists because an installed unit is invisible until it fires. After
# the move to stackyard one machine kept units running scripts/backup.sh, a
# path the new layout no longer had: enabled, so every "is it enabled" check
# passed, and failing with 203/EXEC every night for three days.

set -euo pipefail

CHECK=0
case "${1-}" in
  --check) CHECK=1 ;;
  '') ;;
  *) echo "Usage: sudo $0 [--check]" >&2; exit 2 ;;
esac

DIR0="$( cd -P "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# The MACHINE's directory, not the platform's. Normally set by a wrapper in the
# machine root; the fallback is two levels up from platform/bin, so the script
# also works when invoked directly.
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
ENV_FILE="$ROOT_DIR/.env"
UNIT_SRC="$ROOT_DIR/platform/systemd"
# Overridable so the selftest can install into and check a scratch directory;
# a machine always uses the system one.
UNIT_DST="${STACKYARD_UNIT_DIR:-/etc/systemd/system}"

BACKUP_ENV_FILE="$ROOT_DIR/.env-backup"
NOTIFY_ENV_FILE="$ROOT_DIR/.env-notify"

# Sourced here rather than at block 4, where it used to be: which units exist
# at all now depends on the stacks, and that decision has to be made before
# block 3 writes them out.
# shellcheck source=platform/lib/lib-stacks.sh
. "$LIB_DIR/lib-stacks.sh"
# shellcheck source=platform/lib/lib-env.sh
. "$LIB_DIR/lib-env.sh"

# A finding. Installing, it stops the run; checking, it is counted and the
# check goes on, so one run names every problem rather than the first.
PROBLEMS=0
WARNINGS=0
problem() {
  if [ "$CHECK" -eq 1 ]; then
    printf '  [FAIL] %s\n' "$1"
    PROBLEMS=$((PROBLEMS + 1))
  else
    echo "Error: $1" >&2
    exit 1
  fi
}

# The backup and notification units are appended below when the machine has
# those parts configured.
#
# Certificate renewal is installed only when some enabled stack still wants
# this machine to issue a certificate. With every domain behind Certs=
# "external" the timers would run nightly and could never succeed: getssl
# would answer a challenge that a load balancer in front never forwards. That
# is not a quiet no-op — it is a red journal every night, and a journal that
# is always red is one nobody opens on the night a real renewal breaks.
#
# STACK units are not listed here at all: they are picked up by the pass over
# stacks/<stack>/systemd/ (block 4). Otherwise a stack that needed a timer
# would have to edit this script.
GETSSL_UNITS=(getssl-renew.service getssl-renew.timer getssl-check.service getssl-check.timer)
UNITS=()
TIMERS=()
INSTALL_GETSSL=0
if stacks_getssl_any; then
  INSTALL_GETSSL=1
  UNITS+=("${GETSSL_UNITS[@]}")
  TIMERS+=(getssl-renew.timer getssl-check.timer)
fi

# 1. The .env file must exist
if [ ! -f "$ENV_FILE" ]; then
  echo "Error: environment file '$ENV_FILE' not found" >&2
  exit 1
fi

# `|| true` is mandatory: under set -euo pipefail a line missing from .env makes
# grep exit non-zero, pipefail carries that through the pipeline, and set -e
# kills the script right at the assignment — before the check below, which was
# supposed to explain what is wrong.
Platform_Deploy_Dir=$(grep -E '^Platform_Deploy_Dir=' "$ENV_FILE" | head -n 1 | cut -d '=' -f2- | tr -d '"'\' || true)

if [ -z "$Platform_Deploy_Dir" ]; then
  echo "Error: Platform_Deploy_Dir is not set in $ENV_FILE" >&2
  exit 1
fi

# 2. Preflight checks. Each of them is a failure that would otherwise surface
#    only a day later, in the middle of the night, and silently.
# Checking reads the unit files and changes nothing, so it needs neither
# systemctl nor root; installing into the system directory needs both.
if [ "$CHECK" -eq 0 ] && ! command -v systemctl >/dev/null 2>&1; then
  echo "Error: systemd not found. This machine needs a different scheduler." >&2
  exit 1
fi

if [ "$CHECK" -eq 0 ] && [ "$UNIT_DST" = /etc/systemd/system ] && [ "$(id -u)" -ne 0 ]; then
  echo "Error: root privileges are required. Run: sudo $0" >&2
  exit 1
fi

# Both of these are about getssl, so neither is a reason to refuse on a
# machine that is not going to run it. Demanding a getssl binary from a
# machine whose every domain is terminated upstream would make Certs=
# "external" impossible to actually adopt.
if [ "$INSTALL_GETSSL" -eq 1 ]; then
  # Platform_Deploy_Dir is a path ON the machine, and this runs on that machine.
  if [ ! -d "$Platform_Deploy_Dir/state/getssl-config" ]; then
    problem "no $Platform_Deploy_Dir/state/getssl-config — Platform_Deploy_Dir in .env does not point at the repository"
  fi

  # getssl is a machine artifact under state/, not a platform file: it is
  # downloaded by getssl-fetch.sh according to platform/getssl.lock. Installing
  # the units before it exists is pointless: there would be a timer and no
  # renewals, which looks exactly like "getssl is quiet because there is nothing
  # to renew".
  if [ ! -x "$Platform_Deploy_Dir/state/bin/getssl" ]; then
    problem "no $Platform_Deploy_Dir/state/bin/getssl — download it with ./platform/bin/getssl-fetch.sh"
  fi
fi

# Which user the timers run as: the owner of the repository directory. That
# same user owns state/certs, where getssl writes its results.
SERVICE_USER=$(stat -c '%U' "$Platform_Deploy_Dir" 2>/dev/null || stat -f '%Su' "$Platform_Deploy_Dir")

if [ -z "$SERVICE_USER" ] || [ "$SERVICE_USER" = "root" ]; then
  echo "Error: $Platform_Deploy_Dir is owned by '$SERVICE_USER'." >&2
  echo "  An ordinary user was expected — the one the deployment runs as." >&2
  exit 1
fi

# RELOAD_CMD in every getssl.cfg is "docker exec nginx nginx -s reload".
# Without membership in the docker group the renewal succeeds while nginx keeps
# the old certificate in memory: the worst kind of failure — quiet and partial.
# The membership test avoids `| grep -q`: under `set -o pipefail` grep exits on
# the first match while the writer is still writing, the writer dies of SIGPIPE
# and the pipeline returns 141 — measured at about 1.3% of calls on a live
# machine. A check that says "you are not in the docker group" once in eighty
# runs is worse than none. lib-stacks is not sourced yet at this point (it is
# loaded further down, after the values it needs), so the loop is written out.
user_in_docker_group() {
  local g
  for g in $(id -nG "$SERVICE_USER" 2>/dev/null); do
    [ "$g" = docker ] && return 0
  done
  return 1
}
# Only where getssl runs: the reload after a renewal is the one thing in these
# units that needs docker as $SERVICE_USER (the rest run as root).
if [ "$INSTALL_GETSSL" -eq 1 ] && ! user_in_docker_group; then
  problem "user '$SERVICE_USER' is not in the docker group: RELOAD_CMD ('docker exec nginx nginx -s reload') will not work, and nginx will keep serving the old certificate after a renewal (sudo usermod -aG docker $SERVICE_USER)"
fi

# 2c. Backups. Two different states, told apart on purpose.
#
#     No .env-backup at all is a decision: a fresh install, or a machine that
#     is backed up some other way. That is no reason to leave certificates
#     unrenewed, so it is a skip, said on stderr — and any backup units still
#     installed are removed (block 4d), because a timer for a backup nobody
#     configured only fails.
#
#     An .env-backup that exists but cannot work (no bucket, no key, no aws) is
#     a mistake, not a decision. It fails the run, and the installed units are
#     LEFT: taking a machine's backup timers away because its config broke
#     would trade a loud nightly failure for silence.
#
#     The values are read through lib-env.sh, the way backup.sh reads them, so
#     both see one .env-backup the same way, ${VAR} references included.
BACKUP_UNITS=(devbox-backup.service devbox-backup.timer devbox-backup-check.service devbox-backup-check.timer)
INSTALL_BACKUP=1
BACKUP_BROKEN=0
BACKUP_SKIP=""
BACKUP_BUCKET=""
BACKUP_PUBKEY=""
env_load_files "$ENV_FILE" "$BACKUP_ENV_FILE"

if [ ! -f "$BACKUP_ENV_FILE" ]; then
  INSTALL_BACKUP=0
  BACKUP_SKIP="no $BACKUP_ENV_FILE (cp .env-backup.example .env-backup && chmod 600)"
else
  BACKUP_BUCKET=$(env_get Backup_S3_Bucket)
  BACKUP_PUBKEY=$(backup_pubkey_path)

  if [ -z "$BACKUP_BUCKET" ]; then
    INSTALL_BACKUP=0; BACKUP_BROKEN=1
    BACKUP_SKIP="Backup_S3_Bucket is not set in $BACKUP_ENV_FILE"
  elif [ ! -f "$BACKUP_PUBKEY" ]; then
    INSTALL_BACKUP=0; BACKUP_BROKEN=1
    BACKUP_SKIP="no GPG public key at $BACKUP_PUBKEY (Backup_GPG_Pubkey; generated OFF this machine, see the README)"
  elif ! command -v aws >/dev/null 2>&1; then
    INSTALL_BACKUP=0; BACKUP_BROKEN=1
    BACKUP_SKIP="no aws command — install awscli from your distribution"
  fi
fi

# How often to back up, and the promise the freshness check makes about it.
#
# These two values must agree, and they are the kind of pair that drifts: set
# the schedule to weekly and forget the threshold, and the check screams six
# days out of seven; move the threshold and forget the schedule, and a missed
# run goes unnoticed. So the period is MEASURED here, from the schedule itself,
# with systemd's own calendar parser — and a threshold shorter than the period
# is reported rather than left to be discovered at three in the morning.
BACKUP_SCHEDULE=$(env_get Backup_Schedule '*-*-* 03:40:00')

# The distance between two consecutive firings IS the period, and systemd is
# what parses the expression — we do not reimplement calendar syntax here.
#
# The labels differ between systemd versions — "Next elapse:", "Iter. #2:",
# "Iteration: #2" — so nothing is matched on a label at all: the TIMESTAMP is
# what is extracted, from any line that is not one of the echoes systemd prints
# beside it ("(in UTC):", "From now:"). Guessing a label would silently find
# nothing on the next version, and a warning that never fires is
# indistinguishable from one that has nothing to say.
backup_period_hours() {
  local first second
  read -r first second < <(
    systemd-analyze calendar --iterations=2 "$BACKUP_SCHEDULE" 2>/dev/null \
      | grep -vE '\(in UTC\)|From now' \
      | grep -oE '[A-Z][a-z]{2} [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}( [A-Z]{2,5})?' \
      | while IFS= read -r line; do date -d "$line" +%s 2>/dev/null; done \
      | tr '\n' ' '
  )
  [ -n "${first:-}" ] && [ -n "${second:-}" ] || return 1
  [ "$second" -gt "$first" ] || return 1
  echo $(( (second - first) / 3600 ))
}

if [ "$INSTALL_BACKUP" -eq 1 ]; then
  MAX_AGE=$(env_get Backup_Max_Age_Hours 26)
  if PERIOD=$(backup_period_hours); then
    echo "  backups: every ${PERIOD}h ($BACKUP_SCHEDULE), stale after ${MAX_AGE}h"
    if [ "$MAX_AGE" -le "$PERIOD" ]; then
      echo "WARNING: Backup_Schedule fires every ${PERIOD}h while Backup_Max_Age_Hours is ${MAX_AGE}h." >&2
      echo "  check-backups.sh will call every source stale between runs. Raise it above" >&2
      echo "  the period, with room for RandomizedDelaySec — e.g. $(( PERIOD + PERIOD / 10 + 2 ))." >&2
    fi
  else
    # Said out loud rather than skipped: the whole point of measuring is to
    # catch a schedule and a threshold that disagree, and an unmeasured
    # schedule is exactly where they would.
    echo "NOTE: could not measure the period of Backup_Schedule='$BACKUP_SCHEDULE'." >&2
    echo "  Check by hand that Backup_Max_Age_Hours (${MAX_AGE}) exceeds it." >&2
  fi
  UNITS+=("${BACKUP_UNITS[@]}")
  TIMERS+=(devbox-backup.timer devbox-backup-check.timer)
elif [ "$BACKUP_BROKEN" -eq 1 ]; then
  if [ "$CHECK" -eq 1 ]; then
    problem "backups are configured in .env-backup but cannot be installed — $BACKUP_SKIP"
  else
    echo "ERROR: backups are configured in .env-backup but cannot be installed —" >&2
    echo "  $BACKUP_SKIP" >&2
    echo "  Installed backup units are left as they are. The rest is installed, and" >&2
    echo "  this run exits non-zero until the backup config is fixed." >&2
  fi
else
  echo "NOTE: backups skipped — $BACKUP_SKIP" >&2
fi

# 2d. Notifications. The @ONFAILURE@ substitution in EVERY other unit depends on
#     them, so this block comes before the install loop.
#
#     A unit with OnFailure pointing at an undeclared handler would still work,
#     but every failure would add an error about a missing unit to the
#     journal — noise in exactly the place someone looks while investigating a
#     failure.
INSTALL_NOTIFY=1
NOTIFY_SKIP=""
ONFAILURE_LINE=""

if [ ! -f "$NOTIFY_ENV_FILE" ]; then
  INSTALL_NOTIFY=0
  NOTIFY_SKIP="no $NOTIFY_ENV_FILE (cp .env-notify.example .env-notify && chmod 600)"
else
  NOTIFY_TOKEN=$(grep -E '^Notify_Telegram_Token=' "$NOTIFY_ENV_FILE" | head -n 1 | cut -d '=' -f2- | tr -d '"'\' || true)
  NOTIFY_CHAT=$(grep -E '^Notify_Telegram_Chat_Id=' "$NOTIFY_ENV_FILE" | head -n 1 | cut -d '=' -f2- | tr -d '"'\' || true)
  if [ -z "$NOTIFY_TOKEN" ] || [ -z "$NOTIFY_CHAT" ]; then
    INSTALL_NOTIFY=0
    NOTIFY_SKIP="Notify_Telegram_Token and/or Notify_Telegram_Chat_Id are empty in $NOTIFY_ENV_FILE"
  elif ! command -v curl >/dev/null 2>&1; then
    INSTALL_NOTIFY=0
    NOTIFY_SKIP="no curl command"
  fi
fi

if [ "$INSTALL_NOTIFY" -eq 1 ]; then
  # The devbox-notify@.service template is copied, not enabled: template units
  # have no [Install] section — OnFailure starts them by instance name.
  UNITS+=(devbox-notify@.service devbox-watch.service devbox-watch.timer
          devbox-heartbeat.service devbox-heartbeat.timer)
  TIMERS+=(devbox-watch.timer devbox-heartbeat.timer)
  ONFAILURE_LINE="OnFailure=devbox-notify@%n.service"
else
  echo "NOTE: notifications skipped — $NOTIFY_SKIP" >&2
  echo "      failures will be visible only in \`systemctl --failed\`." >&2
fi

if [ "$CHECK" -eq 1 ]; then
  echo "** Checking the units in $UNIT_DST against what would be installed"
else
  echo "** Installing timers into $UNIT_DST"
fi
echo "   repository: $Platform_Deploy_Dir"
echo "   user:       $SERVICE_USER"
if [ "$INSTALL_GETSSL" -eq 1 ]; then
  echo "   certs:      getssl, for $(stacks_domains_getssl | tr '\n' ' ')"
else
  echo "   certs:      external for every domain — no getssl timers"
fi
if [ "$INSTALL_BACKUP" -eq 1 ]; then
  echo "   backups:    s3://$BACKUP_BUCKET"
fi
if [ "$INSTALL_NOTIFY" -eq 1 ]; then
  echo "   notify:     chat $NOTIFY_CHAT"
fi

# 3. Path substitution. systemd units support no variables and require absolute
#    paths, so in the repository they are templates carrying @DEPLOY_DIR@.
platform_unit_render() {
  sed -e "s#@DEPLOY_DIR@#${Platform_Deploy_Dir}#g" \
      -e "s#@SERVICE_USER@#${SERVICE_USER}#g" \
      -e "s#@ONFAILURE@#${ONFAILURE_LINE}#g" \
      -e "s#@BACKUP_SCHEDULE@#${BACKUP_SCHEDULE}#g" \
      "$UNIT_SRC/$1"
}

# --check: the installed file against the text this run would write. Compared
# whole, because any difference means the machine runs something other than
# its platform version says — an old path, an old schedule, a missing
# OnFailure.
unit_compare() {
  local name="$1" want="$2" f="$UNIT_DST/$1"
  if [ ! -f "$f" ]; then
    problem "$name is not installed — sudo $0"
  elif [ "$(cat "$f")" != "$want" ]; then
    problem "$name differs from its template — sudo $0 reinstalls it"
  else
    printf '  [ok]   %s\n' "$name"
  fi
}

# The units this run owns, whatever it does with them: installed, checked, or
# neither. Block 6 uses it to tell a leftover from a unit of ours.
EXPECTED_UNITS=" ${UNITS[*]+${UNITS[*]}} "

for unit in ${UNITS[@]+"${UNITS[@]}"}; do
  if [ ! -f "$UNIT_SRC/$unit" ]; then
    echo "Error: template $UNIT_SRC/$unit is missing" >&2
    exit 1
  fi
  if [ "$CHECK" -eq 1 ]; then
    unit_compare "$unit" "$(platform_unit_render "$unit")"
    continue
  fi
  platform_unit_render "$unit" > "$UNIT_DST/$unit"
  chmod 644 "$UNIT_DST/$unit"
  echo "    -> $unit"
done

# 4. Units of the enabled stacks. A stack that needs a timer puts the unit in
# stacks/<stack>/systemd/ and leaves this script alone.

export DEPLOY_DIR="$Platform_Deploy_Dir"
export SERVICE_USER
export ONFAILURE="$ONFAILURE_LINE"

STACK_TIMERS=()
while IFS= read -r stack; do
  [ -n "$stack" ] || continue
  units=$(stack_units "$stack")
  [ -n "$units" ] || continue

  # The stack's preflight check. A non-zero exit means the units are NOT
  # installed, and the reason is said out loud.
  #
  # A condition inside the unit itself (ConditionPathExists) will not do: it is
  # silent. The timer fires, does nothing, and from the outside is
  # indistinguishable from a healthy one — a failure that looks like normal
  # operation, which is the worst outcome. A timer failing every night is bad;
  # a timer quietly doing nothing is worse.
  #
  # Via stack_dir rather than a built path: a stack may live in the machine's
  # stacks/ or in the profile's. A string-built path is blind to the second, so
  # a profile stack's preflight would silently not run — and units would be
  # installed for a stack that is not ready. Exactly the silence this preflight
  # guards against.
  preflight="$(stack_dir "$stack")/scripts/preflight.sh"
  if [ -x "$preflight" ]; then
    if ! reason=$("$preflight" 2>&1); then
      echo "NOTE: units of stack '$stack' skipped — ${reason:-preflight.sh returned an error}" >&2
      continue
    fi
  fi

  while IFS= read -r unit; do
    [ -n "$unit" ] || continue
    name=$(basename "$unit")
    # /etc/systemd/system is flat: without a prefix two stacks fight over a
    # name, and whichever was installed last wins.
    case "$name" in
      devbox-"$stack"-*) ;;
      *) echo "NOTE: $name skipped — a stack unit's name must start with devbox-$stack-" >&2
         continue ;;
    esac
    EXPECTED_UNITS="$EXPECTED_UNITS$name "
    if [ "$CHECK" -eq 1 ]; then
      unit_compare "$name" "$(unit_render "$unit" "$stack")"
      continue
    fi
    unit_render "$unit" "$stack" > "$UNIT_DST/$name"
    chmod 644 "$UNIT_DST/$name"
    case "$name" in *.timer) STACK_TIMERS+=("$name") ;; esac
    echo "    -> $name (stack $stack)"
  done <<< "$units"
done < <(stacks_enabled)

# ${arr[@]+"${arr[@]}"} and not plain "${arr[@]}": the platform requires bash
# >= 4.2, and before 4.4 expanding an EMPTY array under `set -u` is an unbound
# variable, not an empty list. Every one of these arrays can now legitimately
# be empty — a machine whose every domain is Certs="external", with no backup
# and no notifications, installs no units of its own at all.
TIMERS+=(${STACK_TIMERS[@]+"${STACK_TIMERS[@]}"})

# 4b. Removing the units of disabled stacks.
#
# Without this, a disabled stack would keep waking the machine on its own
# timer. `stack disable` cannot do it — it runs without root — so it only
# advises running this script.
enabled_now=" $(stacks_enabled 2>/dev/null | tr '\n' ' ') "
while IFS= read -r stack; do
  [ -n "$stack" ] || continue
  case "$enabled_now" in *" $stack "*) continue ;; esac
  while IFS= read -r unit; do
    [ -n "$unit" ] || continue
    name=$(basename "$unit")
    [ -f "$UNIT_DST/$name" ] || continue
    if [ "$CHECK" -eq 1 ]; then
      problem "$name is installed, but stack $stack is disabled — sudo $0 removes it"
      continue
    fi
    systemctl disable --now "$name" >/dev/null 2>&1 || true
    rm -f "$UNIT_DST/$name"
    echo "    removed $name (stack $stack is disabled)"
  done < <(stack_units "$stack")
done < <(stacks_available)

# 4c. Removing the getssl units when no enabled stack wants them.
#
# The same reason as 4b: this is the only step that runs as root, so nothing
# else can take a timer away. Without it, switching the last stack to Certs=
# "external" would change what the platform generates and change nothing at
# all about what the machine does at five in the morning.
if [ "$INSTALL_GETSSL" -eq 0 ]; then
  for name in "${GETSSL_UNITS[@]}"; do
    [ -f "$UNIT_DST/$name" ] || continue
    if [ "$CHECK" -eq 1 ]; then
      problem "$name is installed, but no enabled stack has Certs=getssl — sudo $0 removes it"
      continue
    fi
    systemctl disable --now "$name" >/dev/null 2>&1 || true
    rm -f "$UNIT_DST/$name"
    echo "    removed $name (no enabled stack has Certs=getssl)"
  done
fi

# 4d. Removing the backup units when the machine has no .env-backup.
#
# The same reason as 4c, and only for a missing file: a timer for a backup
# nobody configured can do nothing but fail. A broken .env-backup is the other
# case (block 2c) — its units stay, and the run fails instead.
if [ "$INSTALL_BACKUP" -eq 0 ] && [ "$BACKUP_BROKEN" -eq 0 ]; then
  for name in "${BACKUP_UNITS[@]}"; do
    [ -f "$UNIT_DST/$name" ] || continue
    if [ "$CHECK" -eq 1 ]; then
      problem "$name is installed, but there is no .env-backup — sudo $0 removes it"
      continue
    fi
    systemctl disable --now "$name" >/dev/null 2>&1 || true
    rm -f "$UNIT_DST/$name"
    echo "    removed $name (no .env-backup)"
  done
fi
[ "$BACKUP_BROKEN" -eq 1 ] && EXPECTED_UNITS="$EXPECTED_UNITS${BACKUP_UNITS[*]} "

# 6. --check only: what the installed units would actually run. A unit whose
# ExecStart names a file that is not there fails with 203/EXEC the moment it
# fires, and nothing before that moment shows it. And a devbox-* or getssl-*
# unit that no part of this run accounts for is a leftover — of an older
# layout, or of a stack that no longer exists.
if [ "$CHECK" -eq 1 ]; then
  for f in "$UNIT_DST"/getssl-* "$UNIT_DST"/devbox-*; do
    [ -f "$f" ] || continue
    name="${f##*/}"
    while IFS= read -r line; do
      cmd="${line#ExecStart=}"
      # systemd's prefixes (-, @, +, !, :) say how to run it, not what.
      # The dash last in the set: anywhere else it makes a range.
      cmd="${cmd#"${cmd%%[!@+:!-]*}"}"
      cmd="${cmd%% *}"
      case "$cmd" in
        /*) [ -e "$cmd" ] || problem "$name runs $cmd, which does not exist" ;;
      esac
    done < <(grep -E '^[[:space:]]*ExecStart=' "$f" || true)
    case "$EXPECTED_UNITS" in
      *" $name "*) ;;
      *) printf '  [!]    %s\n' "$name is installed but not one this platform version installs — a leftover?"
         WARNINGS=$((WARNINGS + 1)) ;;
    esac
  done

  echo
  echo "  problems: $PROBLEMS, warnings: $WARNINGS"
  [ "$PROBLEMS" -eq 0 ] || exit 1
  exit 0
fi

# 5. Reload and enable
systemctl daemon-reload

for timer in ${TIMERS[@]+"${TIMERS[@]}"}; do
  systemctl enable --now "$timer"
done

echo
echo "Done. Schedule:"
systemctl list-timers --all 'getssl-*' 'devbox-*'
echo
echo "To check right now, without waiting for the schedule:"
if [ "$INSTALL_GETSSL" -eq 1 ]; then
  echo "  sudo systemctl start getssl-check.service && systemctl status getssl-check.service"
  echo "  sudo systemctl start getssl-renew.service && journalctl -u getssl-renew -n 50"
fi
if [ "$INSTALL_NOTIFY" -eq 1 ]; then
  echo "  sudo $Platform_Deploy_Dir/platform/bin/notify.sh --test      # exercise the channel now"
  echo "  sudo $Platform_Deploy_Dir/platform/bin/watch-host.sh --dry-run"
fi
if [ "$INSTALL_BACKUP" -eq 1 ]; then
  echo "  sudo $Platform_Deploy_Dir/platform/bin/backup.sh --dry-run   # the backup plan, no changes"
  echo "  sudo systemctl start devbox-backup.service && journalctl -u devbox-backup -n 50"
  echo "  $Platform_Deploy_Dir/platform/bin/check-backups.sh"
fi

# Last, after everything else was installed: a broken backup config must not
# cost the machine its certificate renewals, and must not pass for success.
if [ "$BACKUP_BROKEN" -eq 1 ]; then
  echo >&2
  echo "FAILED: backups — $BACKUP_SKIP" >&2
  exit 1
fi
