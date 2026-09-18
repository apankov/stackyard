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
HEAD_COMMIT="$( cd "$ROOT" && git rev-parse HEAD )"
HEAD_VERSION="v$(cat "$ROOT/platform/VERSION")"

paths=("$@")
if [ ${#paths[@]} -eq 0 ]; then
  list="${HOME}/.stackyard-fleet"
  [ -f "$list" ] || { echo "Give the paths to the machines, or create $list" >&2; exit 2; }
  # The tilde is expanded here by hand: people write it in the file, and the
  # shell does not expand it inside a variable — the path simply is not found,
  # and the fleet silently looks empty.
  while IFS= read -r l; do
    case "$l" in ''|\#*) continue ;; esac
    paths+=("${l/#\~/$HOME}")
  done < "$list"
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
    n="$( cd "$ROOT" && git rev-list --count "$c..$HEAD_COMMIT" -- platform profiles 2>/dev/null || echo '?' )"
    lag="$n"
    [ "$n" != "0" ] && behind=$((behind + 1))
  fi
  printf '%-24s %-10s %-10s %s\n' "$name" "$v" "$lag" "${c:0:12}"
done

echo
echo "In stackyard: $HEAD_VERSION (${HEAD_COMMIT:0:12})"
[ "$behind" -gt 0 ] && echo "Behind on the platform: $behind. Update with: ./bin/pin.sh <machine>"
exit 0
