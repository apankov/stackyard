#!/usr/bin/env bash
#
# Pin a machine to the current stackyard version: rewrite its stackyard.lock.
#
# This is what "update the platform for a client" means. An update is always
# for ONE named machine: there is deliberately no "update everyone" command — a
# client nobody touched keeps running its own version for as long as it
# likes.
#
#   ./bin/pin.sh ~/dev/machines/client-acme
#   ./bin/pin.sh ~/dev/machines/client-acme --version v0.2.0   # pin an older one

set -euo pipefail

ROOT="$( cd -P "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
DEST=""; WANT=""

while [ $# -gt 0 ]; do
  case "$1" in
    # ${2-} plus an explicit test rather than a bare "$2": under set -u a
    # forgotten value gives "$2: unbound variable" — a message about the
    # script's internals instead of one about what is missing on the command
    # line.
    --version) WANT="${2-}"; [ -n "$WANT" ] || { echo "Error: --version requires a value" >&2; exit 2; }; shift 2 ;;
    -*) echo "Unknown argument: $1" >&2; exit 2 ;;
    *)  DEST="$1"; shift ;;
  esac
done
[ -n "$DEST" ] || { echo "Usage: $0 <machine-path> [--version <tag>]" >&2; exit 2; }
LOCK="$DEST/stackyard.lock"
[ -f "$LOCK" ] || { echo "Error: no $LOCK — is this really a stackyard machine?" >&2; exit 2; }

if [ -n "$WANT" ]; then
  COMMIT="$( cd "$ROOT" && git rev-parse "$WANT^{commit}" )"
  VERSION="$WANT"
else
  VERSION="v$(cat "$ROOT/platform/VERSION")"
  COMMIT="$( cd "$ROOT" && git rev-parse HEAD )"
  # Uncommitted edits to the platform never reach a machine: bootstrap fetches
  # a commit. Staying quiet about that is not an option — someone would see
  # "updated" and not get their own change.
  if ! ( cd "$ROOT" && git diff --quiet HEAD -- platform profiles ); then
    echo "Warning: platform/ or profiles/ has uncommitted changes." >&2
    echo "  Only what is committed ($COMMIT) will reach the machine." >&2
  fi
fi

OLD_V="$(grep -E '^version=' "$LOCK" | cut -d= -f2-)"
OLD_C="$(grep -E '^commit='  "$LOCK" | cut -d= -f2-)"

# The machine-side platform files (bootstrap and the wrappers) are updated
# BEFORE the version check: they live in the machine's git and can therefore
# fall behind regardless of whether the version changed. Checking the version
# first would let a machine keep an outdated wrapper indefinitely.
if ! cmp -s "$ROOT/templates/machine/bootstrap" "$DEST/bootstrap"; then
  cp "$ROOT/templates/machine/bootstrap" "$DEST/bootstrap"
  chmod +x "$DEST/bootstrap"
  echo "  bootstrap updated from the template"
fi

# The wrappers, for the same reason as bootstrap: they live in the machine's
# git and can fall behind. Only existing ones are updated: a machine's set of
# entry points is its own, and introducing new ones is not the business of a
# version update.
while IFS=: read -r name target; do
  case "$name" in ''|\#*) continue ;; esac
  [ -f "$DEST/$name" ] || continue
  rendered="$(sed "s/@TARGET@/$target/g" "$ROOT/templates/machine/wrapper")"
  [ "$(cat "$DEST/$name")" = "$rendered" ] && continue
  printf '%s\n' "$rendered" > "$DEST/$name"
  chmod +x "$DEST/$name"
  echo "  wrapper $name updated from the template"
done < "$ROOT/templates/machine/wrappers"


if [ "$OLD_C" = "$COMMIT" ]; then
  echo "The machine is already pinned to $VERSION ($COMMIT)."
  exit 0
fi

# What exactly will arrive. The platform diff is shown BEFORE the lock is
# edited: the decision to update is made from it, not from a version number.
echo "== what changes in the platform"
( cd "$ROOT" && git --no-pager diff --stat "$OLD_C..$COMMIT" -- platform profiles 2>/dev/null ) \
  || echo "  (the old commit $OLD_C was not found in this repository)"

python3 - "$LOCK" "$VERSION" "$COMMIT" <<'PY'
import io, re, sys
lock, version, commit = sys.argv[1], sys.argv[2], sys.argv[3]
s = io.open(lock, encoding='utf-8').read()
s = re.sub(r'^version=.*$', 'version=' + version, s, flags=re.M)
s = re.sub(r'^commit=.*$',  'commit='  + commit,  s, flags=re.M)
io.open(lock, 'w', encoding='utf-8').write(s)
PY

# bootstrap is the one platform file that lives in a machine's git (otherwise
# the machine would have nothing to fetch the platform with). It is therefore
# the only one that can fall behind. It is updated by the same action as the
# version: a separate step that has to be remembered will eventually be
# forgotten.
echo
echo "Pinned: $OLD_V ($OLD_C) -> $VERSION ($COMMIT)"
echo "Next, on the machine: ./bootstrap && ./stack --check, then git commit stackyard.lock"
