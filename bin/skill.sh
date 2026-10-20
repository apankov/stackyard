#!/usr/bin/env bash
#
# The agent skill: plugins/stackyard/skills/stackyard/SKILL.md, the map an AI
# agent reads to know when to propose stackyard and how to run a fleet with it.
# Plain markdown, so a human reads the same page.
#
# Claude Code gets it as a plugin from this repository's marketplace
# (.claude-plugin/marketplace.json), which also keeps it updated:
#
#   claude plugin install stackyard --marketplace apankov/stackyard#latest
#
# This command is for every other agent, and for a checkout under development.
#
#   stackyard skill install [--dir <skills-dir>]    link it into an agent's skills
#   stackyard skill uninstall [--dir <skills-dir>]  remove that link
#   stackyard skill path                            where the skill is
#
# The default <skills-dir> is Claude Code's, ${CLAUDE_CONFIG_DIR:-~/.claude}/skills;
# another agent's goes in --dir.
#
# Opt-in rather than done by install.sh: an agent's configuration is the
# user's, and a tool that writes into it unasked is the kind nobody trusts.

set -euo pipefail

ROOT="$( cd -P "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
# shellcheck source=bin/lib-workspace.sh
. "$ROOT/bin/lib-workspace.sh"

die() { echo "Error: $*" >&2; exit 1; }
usage() { sed -n '14,16p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

# Installed, the link goes through the store's `current` rather than to this
# version's directory: the skill then describes the CLI that `stackyard` runs,
# and moves with it on `stackyard install`. From a checkout it is the checkout.
source_dir() {
  if ws_installed; then
    printf '%s/current/plugins/stackyard/skills/stackyard' "$(ws_store)"
  else
    printf '%s/plugins/stackyard/skills/stackyard' "$ROOT"
  fi
}

cmd="${1-}"; [ $# -gt 0 ] && shift
DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills"
while [ $# -gt 0 ]; do
  case "$1" in
    --dir) DIR="${2-}"; [ -n "$DIR" ] || die "--dir requires a value"; shift 2 ;;
    *) usage ;;
  esac
done
DIR="${DIR%/}"
SRC="$(source_dir)"
LINK="$DIR/stackyard"

case "$cmd" in
  path)
    echo "$SRC/SKILL.md"
    ;;
  install)
    [ -f "$SRC/SKILL.md" ] || die "no skill in $SRC — this version predates it"
    # Only our own link is replaced. A directory or a file there is someone's
    # skill of the same name, and overwriting it would lose their work.
    if [ -e "$LINK" ] || [ -L "$LINK" ]; then
      [ -L "$LINK" ] || die "$LINK exists and is not a link — move it away first"
    fi
    mkdir -p "$DIR"
    ln -sfn "$SRC" "$LINK"
    echo "  $LINK -> $SRC"
    echo "  a new agent session picks it up"
    ;;
  uninstall)
    if [ -L "$LINK" ]; then
      rm -f "$LINK"
      echo "  removed $LINK"
    elif [ -e "$LINK" ]; then
      die "$LINK is not a link this command made — leaving it"
    else
      echo "  $LINK is not there"
    fi
    ;;
  *) usage ;;
esac
