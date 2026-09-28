#!/usr/bin/env bash
#
# Which stackyard version each machine in the fleet runs.
#
# It exists for one question that otherwise has no quick answer: did the fix
# reach everyone? With the platform pinned by commit, that is one line per
# machine.
#
#   ./bin/fleet.sh ~/dev/machines/*        # by path
#   ./bin/fleet.sh                         # from the fleet list in the store
#   ./bin/fleet.sh add <machine>...        # put a machine on the list
#   ./bin/fleet.sh add-dir <dir>           # every machine under <dir>, now and later
#   ./bin/fleet.sh list                    # the machines the list resolves to

set -uo pipefail

ROOT="$( cd -P "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
# shellcheck source=bin/lib-workspace.sh
. "$ROOT/bin/lib-workspace.sh"
HEAD_COMMIT="$(ws_commit)"
HEAD_VERSION="v$(cat "$ROOT/platform/VERSION")"

die() { echo "Error: $*" >&2; exit 2; }

# The list is written by these rather than by hand in the usual case: a path
# mistyped into the file is a machine silently missing from every report.
fleet_add_line() {
  local f; f="$(ws_fleet_file)"
  mkdir -p "$(dirname "$f")"
  if [ ! -f "$f" ]; then
    # The first add must not start an empty list next to an old one: every
    # machine in ~/.stackyard-fleet would drop out of the fleet at once.
    if [ -f "$HOME/.stackyard-fleet" ]; then
      cp "$HOME/.stackyard-fleet" "$f"
      echo "copied ~/.stackyard-fleet into $f; the old file can be removed"
    else
      printf '%s\n' \
        "# The stackyard fleet. machines_dir=<dir> is every machine directly under <dir>;" \
        "# any other line is the path of one machine." > "$f"
    fi
  fi
  if grep -qxF "$1" "$f"; then
    echo "already listed: $1"
  else
    printf '%s\n' "$1" >> "$f"
    echo "added: $1"
  fi
}

case "${1-}" in
  add)
    shift
    [ $# -gt 0 ] || die "usage: stackyard fleet add <machine>..."
    for p in "$@"; do
      [ -f "$p/stackyard.lock" ] || die "$p is not a stackyard machine (no stackyard.lock)"
      fleet_add_line "$(cd "$p" && pwd)"
    done
    exit 0 ;;
  add-dir)
    [ $# -eq 2 ] && [ -d "$2" ] || die "usage: stackyard fleet add-dir <existing directory>"
    fleet_add_line "machines_dir=$(cd "$2" && pwd)"
    n=0; for p in "$2"/*/; do [ -f "$p/stackyard.lock" ] && n=$((n + 1)); done
    echo "machines under it now: $n"
    exit 0 ;;
  list)
    ws_fleet_machines || die "no fleet list yet — stackyard fleet add-dir <dir>, or add <machine>"
    exit 0 ;;
esac

paths=("$@")
if [ ${#paths[@]} -eq 0 ]; then
  fleet="$(ws_fleet_machines)" \
    || { echo "Give the paths to the machines, or: stackyard fleet add-dir ~/dev/machines" >&2; exit 2; }
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
