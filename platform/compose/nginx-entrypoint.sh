#!/bin/sh
# The nginx container's entry point: link the platform's directories into
# /etc/nginx, then hand over to the image's own entrypoint.
#
# They are links rather than mounts on purpose. A mount pins the directory it
# was started on, and ./bootstrap installs every platform version into a new
# directory: a mounted /etc/nginx/snippets would keep the version nginx started
# with, and then nothing at all. The container mounts the stable .stackyard
# instead (platform/compose/nginx.yaml), and a link is resolved on every read,
# so an nginx reload after ./bootstrap sees the new version. The paths nginx
# configs use (/etc/nginx/snippets/…) stay the same.
#
# POSIX sh: this runs inside the image, where bash is not guaranteed.
set -eu

: "${STACKYARD_PLATFORM_DIR:?not set — see platform/compose/nginx.yaml}"
: "${STACKYARD_PROFILE_DIR:?not set — see platform/compose/nginx.yaml}"

# A target that is missing is a refusal to start, not a warning: a link to
# nothing means an nginx that starts and serves no domains, and that looks
# from outside exactly like a machine that is down.
link() {
  [ -d "$1" ] || { echo "stackyard: $1 does not exist in the container" >&2; exit 1; }
  # The image ships /etc/nginx/conf.d as a directory; after the first start it
  # is our link, and `rm -rf` on a link removes the link, not what it points to.
  rm -rf "$2"
  ln -s "$1" "$2"
}

link "$STACKYARD_PLATFORM_DIR/nginx-snippets" /etc/nginx/snippets
link "$STACKYARD_PLATFORM_DIR/nginx-vhosts"   /etc/nginx/conf.d
link "$STACKYARD_PROFILE_DIR/stacks"          /etc/nginx/profile-stacks

# The official image does its own preparation there (docker-entrypoint.d); an
# image without it just runs the command.
[ -x /docker-entrypoint.sh ] && exec /docker-entrypoint.sh "$@"
exec "$@"
