#!/usr/bin/env bash
#
# Which stackyard version each machine in the fleet runs.
#
# It exists for one question that otherwise has no quick answer: did the fix
# reach everyone? With the platform pinned by commit, that is one line per
# machine.
#
#   ./bin/fleet.sh ~/dev/machines/*        # by path
#   ./bin/fleet.sh                         # from ~/.stackyard-fleet, one path per line

set -uo pipefail

ROOT="$( cd -P "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
# shellcheck source=bin/lib-workspace.sh
. "$ROOT/bin/lib-workspace.sh"
HEAD_COMMIT="$(ws_commit)"
HEAD_VERSION="v$(cat "$ROOT/platform/VERSION")"

paths=("$@")
if [ ${#paths[@]} -eq 0 ]; then
  fleet="$(ws_fleet_machines)" \
    || { echo "Give the paths to the machines, or create $(ws_fleet_file)" >&2; exit 2; }
  while IFS= read -r l; do [ -n "$l" ] && paths+=("$l"); done <<< "$fleet"
fi

printf '%-24s %-10s %-10s %s\n' MACHINE VERSION BEHIND COMMIT
behind=0
for p in "${paths[@]}"; do
  [ -d "$p" ] || continue
  lock="$p/stackyard.lock"
  name="$(basename "$p")"
  if [ ! -f "$lock" ]; then
    printf '%-24s %-10s %-10s %s\n' "$name" "-" "-" "not a stackyard machine"
    continue
  fi
  v="$(grep -E '^version=' "$lock" | cut -d= -f2-)"
  c="$(grep -E '^commit='  "$lock" | cut -d= -f2-)"
  if [ "$c" = "$HEAD_COMMIT" ]; then
    lag="no"
  else
    # What is counted is commits that TOUCH the platform: a machine twenty
    # README commits behind is behind on nothing.
    n="$(ws_git rev-list --count "$c..$HEAD_COMMIT" -- platform profiles 2>/dev/null || echo '?')"
    lag="$n"
    [ "$n" != "0" ] && behind=$((behind + 1))
  fi
  printf '%-24s %-10s %-10s %s\n' "$name" "$v" "$lag" "${c:0:12}"
done

echo
echo "In stackyard: $HEAD_VERSION (${HEAD_COMMIT:0:12})"
# The command the operator actually has: an installed CLI has no ./bin.
pin_cmd="./bin/pin.sh"; ws_installed && pin_cmd="stackyard pin"
[ "$behind" -gt 0 ] && echo "Behind on the platform: $behind. Update with: $pin_cmd <machine>"
exit 0
