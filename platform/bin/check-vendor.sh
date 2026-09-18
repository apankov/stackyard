#!/usr/bin/env bash
#
# Comparing the vendored layers against .vendor.lock: is the platform on this
# machine the version it claims, and has anyone edited it in place?
#
# Why this needs a check of its own. A vendored copy is convenient because the
# machine is self-contained, and dangerous for exactly the same reason: editing
# the platform directly on the machine works, looks normal, and disappears at
# the next update of that layer. Weeks pass between the edit and its
# disappearance, and by then nobody connects the two.
#
#   ./platform/bin/check-vendor.sh   # changes nothing, non-zero exit on a mismatch

set -uo pipefail

DIR0="$( cd -P "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
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
LOCK="$ROOT_DIR/.vendor.lock"

# Needed purely for sha256_file: a bare `shasum` is not available everywhere.
# shellcheck source=platform/lib/lib-env.sh
. "$LIB_DIR/lib-env.sh"

problems=0
ok()   { printf '  [ok]   %s\n' "$1"; }
warn() { printf '  [!]    %s\n' "$1"; }
bad()  { printf '  [FAIL] %s\n' "$1"; problems=$((problems + 1)); }

# Development mode: the layers are symlinked into the workspace. Then there is
# nothing to compare — they ARE the source, and nothing can drift from it.
if [ -L "$ROOT_DIR/platform" ]; then
  ok "platform is a symlink — development mode, there is no vendored copy"
  [ -f "$LOCK" ] && warn ".vendor.lock is left over from a vendored copy — remove it, it is misleading"
  exit 0
fi

if [ ! -f "$LOCK" ]; then
  bad "no .vendor.lock — it is unknown which platform version this machine uses"
  echo "         Create it with: ./bin/vendor.sh <machine> from the workspace" >&2
  exit 1
fi

ok "platform $(grep '^platform_version=' "$LOCK" | cut -d= -f2), profile $(grep '^profile_version=' "$LOCK" | cut -d= -f2)"

# Comparing checksums. They are read from the lock rather than recomputed "the
# way vendor.sh does it": a second copy of the formula drifts from the first
# silently, and the check starts reporting a mismatch where there is none —
# after which it stops being read.
# The tool is checked ONCE, before the loop. Otherwise every file produces both
# a "nothing to compute checksums with" error and a [FAIL] "edited in place": a
# hundred-line report in which the real cause is the first line and drowns.
sha256_file /dev/null >/dev/null || {
  echo "Error: nothing available to verify the vendored copy with." >&2
  echo "  Install coreutils (sha256sum) or perl (shasum)." >&2
  exit 2
}

changed=0; missing=0
while read -r sum path; do
  case "$sum" in \#*|platform_version=*|profile_version=*|---) continue ;; esac
  [ -n "${path:-}" ] || continue
  f="$ROOT_DIR/$path"
  if [ ! -f "$f" ]; then
    bad "file is gone: $path"; missing=$((missing + 1)); continue
  fi
  if [ "$(sha256_file "$f")" != "$sum" ]; then
    bad "edited in place: $path"; changed=$((changed + 1))
  fi
done < "$LOCK"

# Extra files: the layer may have grown something the manifest does not list.
# That is an in-place edit too, from the other direction.
for layer in platform profile; do
  [ -d "$ROOT_DIR/$layer" ] || continue
  while IFS= read -r f; do
    rel="$layer/${f#./}"
    grep -qF "  $rel" "$LOCK" || bad "file outside the manifest: $rel"
  done < <(cd "$ROOT_DIR/$layer" && find . -type f -not -name '.DS_Store')
done

if [ "$problems" -eq 0 ]; then
  echo "  The vendored layers match .vendor.lock."
  exit 0
fi
echo
echo "Mismatches: $problems. An edit to a vendored layer is lost at the next update." >&2
echo "  Move it into the workspace and re-run ./bin/vendor.sh <machine>." >&2
exit 1
