#!/usr/bin/env bash
#
# Install the stackyard operator CLI on a laptop.
#
#   curl -o- https://raw.githubusercontent.com/apankov/stackyard/v0.36.1/install.sh | bash
#   curl -o- https://raw.githubusercontent.com/apankov/stackyard/latest/install.sh | bash
#
# The second is the newest release: `latest` is a branch that
# .github/workflows/latest.yml moves onto each release tag.
#
# or, to read it before it runs (a pipe into bash cannot be inspected first):
#
#   curl -o install.sh https://raw.githubusercontent.com/apankov/stackyard/v0.36.1/install.sh
#   less install.sh && bash install.sh
#
# This is for the operator's tools only. A machine never runs it: a machine
# gets the platform from its own stackyard.lock through ./bootstrap, so the
# version it runs stays recorded in its repository (ADR 0001).
#
# What it leaves behind:
#
#   ~/.local/share/stackyard/                the store, and nothing outside it but
#                                            the link below:
#     repo.git                               a mirror of stackyard: tags, and the
#                                            history pin shows and fleet counts
#     versions/<commit>/                     each installed version, side by side
#     current                                -> the version `stackyard` runs
#     fleet                                  your machines (stackyard fleet add),
#                                            the one file in here written by hand
#   ~/.local/bin/stackyard                   -> current/bin/stackyard
#
# Under $XDG_DATA_HOME when that is set. Nothing in the home directory itself:
# the store is data, and its versions/ keeps the layout of a machine's
# .stackyard/ on purpose — one release tree, whichever end it is used from.
#
# Nothing here deletes the store or anything in it but a version directory
# being replaced: the fleet file sits among files that can be refetched, and
# is the one that cannot.
#
# Settings: STACKYARD_VERSION (a tag, a commit, or `latest`), STACKYARD_DIR,
# STACKYARD_REPO, STACKYARD_BIN_DIR; --no-modify-path. Needs git and tar only.
# Running it again is safe: an installed version is switched to, not refetched.

set -euo pipefail

# The release this script belongs to. Fetched by its tag, the script installs
# that tag and nothing newer. selftest holds this equal to platform/VERSION, so
# the release commit bumps both.
STACKYARD_RELEASE=v0.36.1

VERSION="${STACKYARD_VERSION:-$STACKYARD_RELEASE}"
DIR="${STACKYARD_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/stackyard}"
REPO="${STACKYARD_REPO:-https://github.com/apankov/stackyard.git}"
BIN_DIR="${STACKYARD_BIN_DIR:-$HOME/.local/bin}"
MODIFY_PATH=1

for a in "$@"; do
  case "$a" in
    --no-modify-path) MODIFY_PATH=0 ;;
    -h|--help)
      echo "Usage: [STACKYARD_VERSION=<tag>|latest] bash install.sh [--no-modify-path]"
      exit 0 ;;
    *) echo "Error: unknown argument: $a" >&2; exit 2 ;;
  esac
done

die() { echo "Error: $*" >&2; exit 1; }
for c in git tar; do command -v "$c" >/dev/null 2>&1 || die "$c is required"; done

MIRROR="$DIR/repo.git"
mgit() { git --git-dir="$MIRROR" "$@"; }

# Swapping a link must be a rename, for the reason bootstrap gives: `ln -sfn`
# is an unlink followed by a symlink, and a `stackyard` started between the two
# finds nothing. GNU spells "do not follow the link" -T, BSD -h.
swap_link() {
  rm -f "$2.tmp"
  ln -s "$1" "$2.tmp"
  mv -T "$2.tmp" "$2" 2>/dev/null || mv -h "$2.tmp" "$2"
}

mkdir -p "$DIR/versions"
if [ -d "$MIRROR" ]; then
  # A failed fetch is not fatal: switching to a version already installed, or
  # to a tag already in the mirror, needs no network.
  mgit fetch --quiet --prune origin 2>/dev/null \
    || echo "  could not fetch $(mgit config remote.origin.url) — using the mirror as it is" >&2
else
  echo "cloning $REPO"
  git clone --quiet --mirror "$REPO" "$MIRROR.tmp" || { rm -rf "$MIRROR.tmp"; die "could not clone $REPO"; }
  mv "$MIRROR.tmp" "$MIRROR"
fi

if [ "$VERSION" = latest ]; then
  VERSION="$(mgit for-each-ref --sort=-v:refname --format='%(refname:short)' 'refs/tags/v*' | head -n 1)"
  [ -n "$VERSION" ] || die "the repository has no v* tags to call latest"
fi
# The tag is resolved to a commit HERE and the commit is what gets installed
# and later written into locks. A tag only names a commit; if it is moved, the
# next install says so by printing a different commit, rather than a machine
# quietly receiving code nobody pinned.
COMMIT="$(mgit rev-parse --verify --quiet "$VERSION^{commit}")" \
  || die "no $VERSION in $(mgit config remote.origin.url)"
echo "stackyard $VERSION -> $COMMIT"

# A release older than the CLI has the tools but not the command that runs
# them, and making it current would leave ~/.local/bin/stackyard pointing at
# nothing. Machines can still be pinned to it: stackyard pin --version.
mgit cat-file -e "$COMMIT:bin/stackyard" 2>/dev/null \
  || die "$VERSION predates the operator CLI; pin machines to it with: stackyard pin <machine> --version $VERSION"

NEW="$DIR/versions/$COMMIT"
if [ "$(cat "$NEW/.commit" 2>/dev/null)" = "$COMMIT" ]; then
  echo "  already installed"
else
  rm -rf "$NEW.tmp" "$NEW"
  mkdir -p "$NEW.tmp"
  mgit archive "$COMMIT" | tar -x -C "$NEW.tmp"
  printf '%s\n' "$COMMIT" > "$NEW.tmp/.commit"
  printf '%s\n' "$VERSION" > "$NEW.tmp/.version"
  mv "$NEW.tmp" "$NEW"
  echo "  installed into $NEW"
fi
swap_link "versions/$COMMIT" "$DIR/current"

mkdir -p "$BIN_DIR"
if [ -e "$BIN_DIR/stackyard" ] && [ ! -L "$BIN_DIR/stackyard" ]; then
  die "$BIN_DIR/stackyard exists and is not the link this script makes — move it away first"
fi
ln -sfn "$DIR/current/bin/stackyard" "$BIN_DIR/stackyard"
echo "  $BIN_DIR/stackyard -> $DIR/current/bin/stackyard"

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *)
    line="export PATH=\"$BIN_DIR:\$PATH\"  # stackyard"
    case "${SHELL##*/}" in
      zsh)  rc="${ZDOTDIR:-$HOME}/.zshrc" ;;
      bash) rc="$HOME/.bashrc" ;;
      *)    rc="" ;;
    esac
    if [ "$MODIFY_PATH" -eq 0 ] || [ -z "$rc" ]; then
      echo "  $BIN_DIR is not in PATH; add it: $line"
    elif grep -qF "$line" "$rc" 2>/dev/null; then
      echo "  $rc already adds $BIN_DIR to PATH; open a new shell"
    else
      printf '\n%s\n' "$line" >> "$rc"
      echo "  added $BIN_DIR to PATH in $rc; open a new shell"
    fi
    ;;
esac
