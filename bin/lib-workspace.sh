# shellcheck shell=bash
# Where the workspace tools ask their git questions, and which commit they are.
# Sourced by bin/*.sh after they set ROOT; never run on its own.
#
# The tools run from one of two places. From a checkout of stackyard, ROOT is a
# git working tree and every question goes to it. From a version the operator
# CLI installed (~/.stackyard/versions/<commit>/), ROOT is a `git archive`
# with no .git at all: the history pin shows and fleet counts lives in the
# mirror next to the versions, ~/.stackyard/repo.git.

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
