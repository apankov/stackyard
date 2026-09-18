#!/usr/bin/env bash

# A periodic sweep of the machine's state: disk, inodes, containers.
#
# systemd units report THEIR OWN failures through OnFailure, while the host's
# state reports nothing at all: a disk filling up and a container crash loop
# are visible only to whoever logs in to look.
#
# EXIT CODE. 0 when the checks ran, regardless of what they found: the script
# sends its findings itself, with detail. A non-zero code only when the checks
# could not be performed. Otherwise OnFailure would deliver a second, less
# informative message about something already reported.
#
#   sudo ./platform/bin/watch-host.sh            # sweep and notify
#   sudo ./platform/bin/watch-host.sh --dry-run  # show findings, send nothing

set -uo pipefail

DIR0="$( cd -P "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# The MACHINE's directory, not the platform's. Normally set by a wrapper in the
# machine root; the fallback is two levels up from platform/bin.
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

# shellcheck source=platform/lib/lib-env.sh
. "$LIB_DIR/lib-env.sh"

# Overridable only for tests: the production path is /var/lib/devbox-notify and
# the units do not override it. Without this, deduplication and recovery could
# be exercised only as root on a live machine.
STATE_DIR="${DEVBOX_NOTIFY_STATE_DIR:-/var/lib/devbox-notify}"
RESTARTS_STATE="$STATE_DIR/restarts.state"

DRY_RUN=0
[ "${1-}" = "--dry-run" ] && DRY_RUN=1
[ "${1-}" = "--help" ] && { echo "Usage: sudo $0 [--dry-run]"; exit 0; }

die() { echo "Error: $*" >&2; exit 2; }

ENV_NOTIFY="$ROOT_DIR/.env-notify"
[ -f "$ENV_NOTIFY" ] || die "no $ENV_NOTIFY"
env_load_files "$ROOT_DIR/.env" "$ENV_NOTIFY"

WARN_PCT=$(env_get Notify_Disk_Warn_Percent 80)
CRIT_PCT=$(env_get Notify_Disk_Crit_Percent 90)
MOUNTS=$(env_get Notify_Watch_Mounts /)
RESTART_DELTA=$(env_get Notify_Restart_Delta 3)
IGNORE=$(env_get Notify_Ignore_Containers)

for n in WARN_PCT CRIT_PCT RESTART_DELTA; do
  case "${!n}" in ''|*[!0-9]*) die "$n must be an integer, not '${!n}'" ;; esac
done

install -d -m 700 "$STATE_DIR" 2>/dev/null || die "cannot create $STATE_DIR (root required)"

notify() {
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "  [dry-run] notify.sh $*"
    return 0
  fi
  "$DIR0/notify.sh" "$@" || echo "  [!] sending failed: $*" >&2
}

echo "== Host sweep, $(date -u '+%Y-%m-%d %H:%M') UTC"

# ------------------------------------------------------------------ 1. disk

echo
echo "-- Disk"

# check_usage <ascii key> <human label> <mount point> <percent> <detail>
#
# The key is SEPARATE from the title and must be ASCII: the key becomes a state
# file's name, and the sanitiser in notify.sh replaces every non-ASCII
# character with an underscore. Two different non-ASCII labels of the same
# length would collapse into one file, so two distinct alerts would silently
# suppress each other.
check_usage() {
  local kind="$1" label="$2" mp="$3" pct="$4" detail="$5"
  # A separate statement rather than a sixth assignment above: `local` declares
  # ALL the names first and assigns afterwards, so $kind on that same line is
  # still empty — and under `set -u` that is not an empty string but the death
  # of the script.
  local key="disk-$kind:$mp"

  if [ "$pct" -ge "$CRIT_PCT" ]; then
    printf '  [!!]   %-7s %-10s %s%%\n' "$label" "$mp" "$pct"
    notify --key "$key" --level crit \
           --title "$label on $mp — $pct% (threshold $CRIT_PCT%)" <<< "$detail"
  elif [ "$pct" -ge "$WARN_PCT" ]; then
    printf '  [!]    %-7s %-10s %s%%\n' "$label" "$mp" "$pct"
    notify --key "$key" --level warn \
           --title "$label on $mp — $pct% (threshold $WARN_PCT%)" <<< "$detail"
  else
    printf '  [ok]   %-7s %-10s %s%%\n' "$label" "$mp" "$pct"
    notify --key "$key" --resolve --title "$label on $mp is back to normal — $pct%"
  fi
}

for mp in $MOUNTS; do
  if ! df -Ph "$mp" >/dev/null 2>&1; then
    echo "  [FAIL] mount point '$mp' is not reachable" >&2
    continue
  fi

  pct=$(df -Ph "$mp" | awk 'NR==2 {gsub(/%/, "", $5); print $5}')
  detail=$(df -Ph "$mp" | sed -n '1p;2p')
  # The biggest consumers are more useful inside the message than a command to
  # run: the alert arrives at night, and one more login costs time.
  detail+=$'\n\n'"largest docker objects:"$'\n'
  detail+=$(docker system df 2>/dev/null | head -5 || echo "  docker is not responding")
  check_usage space "space" "$mp" "$pct" "$detail"

  ipct=$(df -Pi "$mp" | awk 'NR==2 {gsub(/%/, "", $5); print $5}')
  # On some filesystems (btrfs, overlay without its own inode accounting) df -i
  # returns a dash. That is not a failure — there is simply nothing to check.
  case "$ipct" in
    ''|*[!0-9]*) echo "  [--]   inode  $mp           inode accounting unavailable" ;;
    *) check_usage inode "inode" "$mp" "$ipct" "$(df -Pi "$mp" | sed -n '1p;2p')" ;;
  esac
done

# ------------------------------------------------------------ 2. containers

echo
echo "-- Containers"

if ! docker info >/dev/null 2>&1; then
  # An unresponsive daemon is an alert in itself, and the containers cannot be
  # inspected. The only place where this script exits non-zero.
  notify --key "docker:daemon" --level crit --title "the docker daemon is not responding" \
    <<< "$(systemctl status docker --no-pager -n 10 2>&1 | tail -12)"
  die "the docker daemon is not responding"
fi
notify --key "docker:daemon" --resolve --title "the docker daemon is responding again"

NEW_RESTARTS=$(mktemp)
trap 'rm -f "$NEW_RESTARTS"' EXIT

while IFS= read -r name; do
  [ -n "$name" ] || continue

  for skip in $IGNORE; do
    [ "$name" = "$skip" ] && continue 2
  done

  read -r state health restarts policy < <(
    docker inspect -f '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}-{{end}} {{.RestartCount}} {{.HostConfig.RestartPolicy.Name}}' \
      "$name" 2>/dev/null
  ) || continue
  [ -n "${state:-}" ] || continue

  echo "$name $restarts" >> "$NEW_RESTARTS"

  # Containers that are supposed to exit (initializers, migrators) are filtered
  # out by their restart policy rather than by a list of names: such a list
  # would need editing for every new stack.
  case "$policy" in
    always|unless-stopped) ;;
    *) printf '  [--]   %-22s %s (one-shot, not watched)\n' "$name" "$state"; continue ;;
  esac

  # 2a. not running
  if [ "$state" != "running" ]; then
    printf '  [!!]   %-22s %s\n' "$name" "$state"
    notify --key "container:$name" --level crit \
           --title "container $name is not running ($state)" \
           <<< "$(docker logs --tail 25 "$name" 2>&1 | tail -25)"
    continue
  fi
  notify --key "container:$name" --resolve --title "container $name is running again"

  # 2b. crash loop. What is watched is the DELTA of the restart counter, not the
  #     status: `restart: always` shows "Up 3 seconds" forever, and in docker ps
  #     a crash loop is indistinguishable from a healthy container.
  prev=$(awk -v n="$name" '$1 == n {print $2}' "$RESTARTS_STATE" 2>/dev/null)
  case "$prev" in ''|*[!0-9]*) prev="$restarts" ;; esac
  delta=$(( restarts - prev ))

  if [ "$delta" -ge "$RESTART_DELTA" ]; then
    printf '  [!!]   %-22s crash loop: +%s restarts\n' "$name" "$delta"
    notify --key "container-loop:$name" --level crit \
           --title "container $name restarted $delta times since the last check" \
           <<< "$(docker logs --tail 25 "$name" 2>&1 | tail -25)"
  else
    notify --key "container-loop:$name" --resolve --title "container $name stopped restarting"
  fi

  # 2c. healthcheck
  if [ "$health" = "unhealthy" ]; then
    printf '  [!]    %-22s unhealthy\n' "$name"
    notify --key "container-health:$name" --level warn \
           --title "container $name is unhealthy" \
           <<< "$(docker inspect -f '{{range .State.Health.Log}}{{.Output}}{{end}}' "$name" 2>/dev/null | tail -10)"
  else
    notify --key "container-health:$name" --resolve --title "container $name is healthy again"
    printf '  [ok]   %-22s running%s\n' "$name" "$([ "$health" != "-" ] && echo ", $health")"
  fi

done < <(docker ps -a --format '{{.Names}}' 2>/dev/null)

if [ "$DRY_RUN" -eq 0 ]; then
  mv "$NEW_RESTARTS" "$RESTARTS_STATE"
  trap - EXIT
fi

echo
echo "Sweep complete."
