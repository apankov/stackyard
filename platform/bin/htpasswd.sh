#!/usr/bin/env bash
#
# Create a basic-auth user for a vhost.
#
# Through the nginx container rather than an apache2-utils package on the host:
# htpasswd is needed twice a year, while the package would stay on the machine
# forever. On this platform it is also the only way — host-setup.sh does not
# install those tools.
#
# The point is not convenience: the command can be typed by hand. The point is
# that when it is typed by hand, it is typed from whatever tutorial came up
# first — that is, with the default APR1-MD5 — while the file sits on a machine
# facing the internet. Here bcrypt is baked in and cannot be forgotten.
#
#   ./platform/bin/htpasswd.sh <file> <login>    add a user or change a password
#   ./platform/bin/htpasswd.sh <file> --list     who is registered
#
# <file> is a name inside state/htpasswd/, the same one the vhost uses in
# auth_basic_user_file as /etc/nginx/htpasswd/<file>. A name rather than a
# constant: a machine has more than one vhost behind authentication, and a
# shared file would mean access to one site opens the others.

set -euo pipefail

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

# shellcheck source=platform/lib/lib-env.sh
. "$LIB_DIR/lib-env.sh"
# shellcheck source=platform/lib/lib-stacks.sh
. "$LIB_DIR/lib-stacks.sh"
env_load_files "$ROOT_DIR/.env"
# state/, not platform/: the platform is a shared layer, downloaded onto every
# machine and overwritten as a whole. A basic-auth file placed there would
# vanish at the next platform update, and until then would be a secret sitting
# in a layer distributed to everyone.
HT_DIR="$ROOT_DIR/state/htpasswd"

NAME="${1:-}"
case "$NAME" in
  ''|--*) echo "usage: $0 <file> <login> | $0 <file> --list" >&2; exit 2 ;;
esac
# The file name becomes a path inside the container — it is validated rather
# than escaped: a slash or a dot-dot here means writing outside the directory.
case "$NAME" in
  *[!A-Za-z0-9._-]*|*..*) echo "Error: the file name may contain letters, digits, . _ - only" >&2; exit 2 ;;
esac
FILE="$HT_DIR/$NAME"

if [ "${2:-}" = "--list" ]; then
  [ -s "$FILE" ] || { echo "empty: $FILE"; exit 0; }
  cut -d: -f1 "$FILE"
  exit 0
fi

USER_NAME="${2:-}"
[ -n "$USER_NAME" ] || { echo "usage: $0 <file> <login> | $0 <file> --list" >&2; exit 2; }

read -r -s -p "password for $USER_NAME in $NAME: " PASS; echo
[ -n "$PASS" ] || { echo "an empty password will not do" >&2; exit 2; }

mkdir -p "$HT_DIR"

# bcrypt (-B) rather than the default APR1-MD5: the file lives on a machine
# facing the internet, and a weak hash is the only thing between a guessed
# password and whatever the authentication protects.
#
# The password goes in on STDIN (-i), not as an argument. An argument would be
# visible in `ps` for the duration of the command and would land in the shell
# history inside `sh -c`. For the same reason the login is passed as an
# environment variable rather than interpolated into the command string: a
# login containing a quote would break the parsing.
#
# An existing file is APPENDED to: `-c` would recreate it and silently drop
# every other user.
#
# -i and -b never go together: -b means "the password is the THIRD argument",
# and htpasswd, not finding a third one, prints its usage and exits. The
# password here comes from stdin, so -i and only -i.
FLAGS="-iB"
[ -s "$FILE" ] || FLAGS="-ciB"

# The permissions and ownership are set by the CONTAINER itself, while it is
# still root. They cannot be set on the host: the file is created by the
# container as root, and `chmod` from an ordinary user fails with EPERM.
#
# Owner: the caller. Group: nginx from THE SAME image. Mode: 640. Every part is
# required — the owner is how a person reads the file (--list), the group is
# how the nginx worker reads it (it runs as an unprivileged user, not root),
# and 640 keeps the file closed to everyone else. Owning it root:root would
# make basic auth answer 403, because nobody would be able to read it.
#
# The gid comes from the image rather than a constant: it belongs to that image,
# not to us.
#
# The command is assembled into one single-line variable for a reason: the
# # pkg-mgr-ok marker must sit on the same line as apk (the guard is
# line-based), and inside a multi-line `sh -c "..."` every line ends in a
# backslash, leaving nowhere to put a comment.
IN_CONTAINER="apk add --no-cache apache2-utils >/dev/null 2>&1 && htpasswd $FLAGS \"/ht/\$HTFILE\" \"\$HTUSER\" && chown \"\$HTOWNER\":\"\$(id -g nginx)\" \"/ht/\$HTFILE\" && chmod 640 \"/ht/\$HTFILE\""  # pkg-mgr-ok: apk runs inside the nginx:alpine image, not on the host

printf '%s' "$PASS" | docker run --rm -i \
  -e HTUSER="$USER_NAME" -e HTFILE="$NAME" -e HTOWNER="$(id -u)" \
  -v "$HT_DIR":/ht \
  "$(nginx_image)" \
  sh -c "$IN_CONTAINER"

echo "done: $FILE"
echo "in the vhost: auth_basic_user_file /etc/nginx/htpasswd/$NAME;"
echo "reload the config: docker exec nginx nginx -s reload"
