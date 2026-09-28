# shellcheck shell=bash
# Where the workspace tools ask their git questions, and which commit they are.
# Sourced by bin/*.sh after they set ROOT; never run on its own.
#
# The tools run from one of two places. From a checkout of stackyard, ROOT is a
# git working tree and every question goes to it. From a version the operator
# CLI installed (~/.local/share/stackyard/versions/<commit>/), ROOT is a
# `git archive` with no .git at all: the history pin shows and fleet counts
# lives in the mirror next to the versions, ~/.local/share/stackyard/repo.git.

# The commit a tree was installed from. Only an installed version has it.
ws_installed() { [ -f "$ROOT/.commit" ]; }

ws_git() {
  if ws_installed; then
    git --git-dir="${STACKYARD_GIT_DIR:-$ROOT/../../repo.git}" "$@"
  else
    ( cd "$ROOT" && git "$@" )
  fi
}

# The commit THESE tools are, which is what `new` and `pin` write into a lock.
#
# Not the mirror's HEAD: the mirror is fetched on every install, so its HEAD is
# whatever the default branch was last time, while the tools running are the
# version the operator chose. A lock written from HEAD would pin a machine to
# code nobody looked at.
ws_commit() {
  if ws_installed; then
    cat "$ROOT/.commit"
  else
    ws_git rev-parse HEAD
  fi
}

# The store: installed versions, the mirror and the fleet list, in one
# directory and nowhere else in the home. An installed version lives two levels
# down in it; a checkout finds it where install.sh puts it by default, so the
# fleet list is the same one whichever copy of the tools is running.
ws_store() {
  if ws_installed; then
    ( cd "$ROOT/../.." && pwd )
  else
    printf '%s' "${STACKYARD_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/stackyard}"
  fi
}

# The fleet: the machines fleet and audit look at when given none. Read here
# once, because fleet and audit each had a copy of the loop and a fix to one
# would not have reached the other.
#
# Two kinds of line. `machines_dir=<dir>` is every directory directly under
# <dir> that holds a stackyard.lock, found afresh on every run: a machine
# created there is in the fleet without anyone remembering to add it, which is
# the step that gets forgotten. Any other line is the path of one machine
# living somewhere else. A machine reached both ways is listed once.
#
# The tilde is expanded by hand: people write it in the file, and the shell
# does not expand it inside a variable — the path simply is not found, and the
# fleet silently looks empty.
ws_fleet_file() { printf '%s/fleet' "$(ws_store)"; }

# The list lived in ~/.stackyard-fleet before the store existed. It is still
# read, with a note, rather than the fleet turning up empty after an update.
ws_fleet_source() {
  local f; f="$(ws_fleet_file)"
  if [ ! -f "$f" ] && [ -f "$HOME/.stackyard-fleet" ]; then
    echo "Note: reading ~/.stackyard-fleet; move it into the store: mv ~/.stackyard-fleet $f" >&2
    f="$HOME/.stackyard-fleet"
  fi
  printf '%s' "$f"
}

ws_fleet_machines() {
  local f l d p
  f="$(ws_fleet_source)"
  [ -f "$f" ] || return 1
  while IFS= read -r l || [ -n "$l" ]; do
    case "$l" in ''|\#*) continue ;; esac
    case "$l" in
      machines_dir=*)
        d="${l#machines_dir=}"; d="${d/#\~/$HOME}"
        for p in "${d%/}"/*/; do
          [ -f "$p/stackyard.lock" ] && printf '%s\n' "${p%/}"
        done
        ;;
      *) l="${l/#\~/$HOME}"; printf '%s\n' "${l%/}" ;;
    esac
  done < "$f" | awk '!seen[$0]++'
  # Explicitly: under pipefail the loop's status is that of its last test, and
  # a machines_dir whose last entry is not a machine would read as "no list".
  return 0
}
