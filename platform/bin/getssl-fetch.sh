#!/usr/bin/env bash

# Delivering getssl to a machine: download the pinned version, verify its
# checksum, put it in state/bin/.
#
# Why a step rather than a copy in the repository. getssl is third-party code
# under GPL-3, and a copy of it inside an MIT-licensed public repository is
# awkward both legally and practically: a copy gets edited in place, the edits
# are forgotten, and it drifts from upstream silently. What git holds here is
# getssl.lock — three lines.
#
# Why state/ and not platform/. This is a MACHINE artifact, like the
# certificates and the ACME account key: it was downloaded on this machine,
# from the network, and there is no reason to keep it in the repository.
#
#   ./platform/bin/getssl-fetch.sh           # download when needed
#   ./platform/bin/getssl-fetch.sh --check   # change nothing, non-zero on drift
#   ./platform/bin/getssl-fetch.sh --force   # re-download over the top

set -uo pipefail

DIR0="$( cd -P "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
if [ -z "${ROOT_DIR:-}" ]; then
  ROOT_DIR="$( cd "$DIR0/../.." && pwd )"
  # On a machine, platform/ is a symlink into .stackyard/, and the `cd -P`
  # above has already resolved it: two levels up lands inside .stackyard
  # rather than in the machine. state/ would then be created INSIDE the downloaded
  # layer and vanish on the next ./bootstrap, and until then the password
  # files, certificates and databases.yaml would sit where no container looks
  # for them. The wrappers in the machine root set ROOT_DIR themselves, but
  # every script documents being called as ./platform/bin/<name>.sh — that is
  # the path this fixes.
  # Everything from .stackyard on is cut: the platform sits two levels deeper
  # there (versions/<commit>/), and a machine still on the flat layout lands
  # on .stackyard itself.
  ROOT_DIR="${ROOT_DIR%%/.stackyard/*}"; ROOT_DIR="${ROOT_DIR%/.stackyard}"
fi
LIB_DIR="$( cd "$DIR0/../lib" && pwd )"
LOCK="$DIR0/../getssl.lock"

# shellcheck source=platform/lib/lib-env.sh
. "$LIB_DIR/lib-env.sh"

CHECK_ONLY=0; FORCE=0
for a in "$@"; do
  case "$a" in
    --check) CHECK_ONLY=1 ;;
    --force) FORCE=1 ;;
    *) echo "Unknown argument: $a" >&2; exit 2 ;;
  esac
done

[ -f "$LOCK" ] || { echo "Error: no $LOCK" >&2; exit 2; }

lock_get() { sed -n "s/^$1=//p" "$LOCK" | head -n 1; }
REPO=$(lock_get repo); VERSION=$(lock_get version); WANT_SUM=$(lock_get sha256)
for v in REPO VERSION WANT_SUM; do
  [ -n "${!v}" ] || { echo "Error: $LOCK is missing a field ($v)" >&2; exit 2; }
done

DEST="$ROOT_DIR/state/bin/getssl"

# The checksum is the only answer to "is this the right getssl". Neither the
# tag nor the VERSION inside the script is enough: `getssl -u` overwrites the
# file with a newer version while the tag in the lock stays put, and the
# machine drifts onto code nobody pinned. Hence the comparison here, not only
# at download time.
have_sum=""
[ -f "$DEST" ] && have_sum=$(sha256_file "$DEST")

if [ "$have_sum" = "$WANT_SUM" ] && [ "$FORCE" -eq 0 ]; then
  echo "  [ok]   getssl $VERSION is in place ($DEST)"
  exit 0
fi

if [ "$CHECK_ONLY" -eq 1 ]; then
  if [ -z "$have_sum" ]; then
    echo "  [FAIL] no $DEST — ./platform/bin/getssl-fetch.sh" >&2
  else
    echo "  [FAIL] $DEST does not match getssl.lock ($VERSION)" >&2
    echo "         This is what 'getssl -u' run by hand looks like: it updated itself." >&2
    echo "         Restore the pinned version: ./platform/bin/getssl-fetch.sh --force" >&2
  fi
  exit 1
fi

# raw.githubusercontent by TAG, not by branch: a branch moves under your feet,
# and the checksum would stop matching for no reason of ours.
URL="${REPO/github.com/raw.githubusercontent.com}/$VERSION/getssl"

command -v curl >/dev/null 2>&1 || { echo "Error: no curl — nothing to download getssl with" >&2; exit 2; }

TMP="$DEST.tmp.$$"
mkdir -p "$(dirname "$DEST")" || exit 2
trap 'rm -f "$TMP"' EXIT

echo "  ... downloading getssl $VERSION"
if ! curl -fsSL --max-time 60 -o "$TMP" "$URL"; then
  echo "Error: could not download $URL" >&2
  exit 2
fi

# Verified BEFORE the file is put in place. Otherwise a substituted response
# would leave the machine with a plausible-looking getssl, and it would find
# out at best on the next check.
got_sum=$(sha256_file "$TMP") || exit 2
if [ "$got_sum" != "$WANT_SUM" ]; then
  echo "Error: the downloaded file's checksum does not match getssl.lock." >&2
  echo "  expected: $WANT_SUM" >&2
  echo "  got:      $got_sum" >&2
  echo "  If the version was moved deliberately, update sha256 in platform/getssl.lock." >&2
  exit 1
fi

chmod +x "$TMP" && mv -f "$TMP" "$DEST" || exit 2
trap - EXIT
echo "  [ok]   getssl $VERSION -> $DEST"
