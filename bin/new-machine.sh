#!/usr/bin/env bash
#
# Create a new machine's repository.
#
# A machine is a SEPARATE, private repository. It is not in stackyard and
# cannot be: stackyard is public, and one client's domains and stack names must
# not sit where another client can read them.
#
# What goes into a machine: the directory skeleton, the wrappers, the .env
# examples, a .gitignore and a bootstrap pinned to a stackyard version. The
# platform itself is NOT placed there: bootstrap fetches it and keeps it in
# .stackyard/, outside git.
#
#   ./bin/new-machine.sh ~/dev/machines/client-acme
#   ./bin/new-machine.sh ~/dev/machines/client-acme --repo https://github.com/me/stackyard.git

set -euo pipefail

ROOT="$( cd -P "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
DEST=""; REPO="https://github.com/apankov/stackyard.git"

while [ $# -gt 0 ]; do
  case "$1" in
    # ${2-} rather than "$2": under set -u a forgotten value gives "$2: unbound
    # variable" instead of a clear "--repo requires a value".
    --repo) REPO="${2-}"; [ -n "$REPO" ] || { echo "Error: --repo requires a value" >&2; exit 2; }; shift 2 ;;
    -*) echo "Unknown argument: $1" >&2; exit 2 ;;
    *)  DEST="$1"; shift ;;
  esac
done
[ -n "$DEST" ] || { echo "Usage: $0 <path-to-new-machine> [--repo <url>]" >&2; exit 2; }
[ -e "$DEST" ] && { echo "Error: $DEST already exists" >&2; exit 2; }

NAME="$(basename "$DEST")"
VERSION="v$(cat "$ROOT/platform/VERSION")"
COMMIT="$( cd "$ROOT" && git rev-parse HEAD )"

mkdir -p "$DEST"/{stacks,state/htpasswd,state/certs,dumps,gpg,nginx}
touch "$DEST/state/.keepit" "$DEST/dumps/.keepit" "$DEST/gpg/.keepit" "$DEST/nginx/.keepit"

# The backup and notification examples. Separate files from .env on purpose:
# they are NOT in docker-compose.sh's --env-file list, and one more mandatory
# env file would be another way to break every compose command at once.
cp "$ROOT/templates/machine/.env-backup.example" "$DEST/.env-backup.example"
cp "$ROOT/templates/machine/.env-notify.example" "$DEST/.env-notify.example"

cp "$ROOT/templates/machine/bootstrap" "$DEST/bootstrap"
chmod +x "$DEST/bootstrap"

cat > "$DEST/stackyard.lock" <<EOF
# Which stackyard version this machine runs.
#
# Pinned by COMMIT rather than by an archive hash: automatically generated
# archives are not guaranteed byte-stable, while a commit is immutable by
# definition. The tag only makes cloning cheap; if someone moves it, bootstrap
# refuses to work rather than substituting someone else's code.
#
# To update: ./bin/pin.sh <this-machine> from stackyard, then ./bootstrap here.
repo=$REPO
version=$VERSION
commit=$COMMIT
EOF

# The wrappers. A few lines each, and the only reason ./stack can be typed from
# the machine root instead of a full path into the platform.
while IFS=: read -r name target; do
  case "$name" in ''|\#*) continue ;; esac
  sed "s/@TARGET@/$target/g" "$ROOT/templates/machine/wrapper" > "$DEST/$name"
  chmod +x "$DEST/$name"
done < "$ROOT/templates/machine/wrappers"

cat > "$DEST/.gitignore" <<'EOF'
# The platform. Deliberately absent from a machine's git: it arrives according
# to stackyard.lock, and a copy in the repository would be a second source of
# truth about which code the machine runs.
/.stackyard/
/platform
/profile

# Secrets and machine state.
.env
.env-stacks
.env-backup
.env-notify
stacks/*/.env
!.env.example
!.env-stacks.example
!stacks/*/.env.example
!.env-backup.example
!.env-notify.example
state/*
!state/.keepit
dumps/*
!dumps/.keepit
EOF

cat > "$DEST/.env.example" <<EOF
# Platform-level values. Loaded always, for every compose command.
#   cp .env.example .env && chmod 600 .env

# Where THIS repository is deployed on the server.
Platform_Deploy_Dir=/mnt/data/$NAME
# The sites' document roots, outside the repository.
Platform_Vhosts_Dir=/mnt/data/vhosts
Platform_Vhosts_Mount=/var/www/vhosts
# The docker network's name. Unique per machine — audit-isolation checks that.
Platform_Network=$NAME-net
# A separate data volume. Empty if there is no such volume.
Platform_Data_Mount=/mnt/data
EOF

cat > "$DEST/.env-stacks.example" <<'EOF'
# Which stacks are enabled. The single source of truth about a machine's
# composition. Stacks come from profile/stacks (shared) and stacks/ (its own).
Enabled_Stacks=""
EOF

cat > "$DEST/README.md" <<EOF
# $NAME

A stackyard machine. The platform is not kept in git — \`./bootstrap\` fetches
it at the version recorded in \`stackyard.lock\`.

## Deploy

\`\`\`sh
git clone <this repository> /mnt/data/$NAME
cd /mnt/data/$NAME
./bootstrap                     # platform $VERSION
cp .env.example .env && \$EDITOR .env
cp .env-stacks.example .env-stacks && \$EDITOR .env-stacks
sudo ./host-setup
./stack enable <stacks>
\`\`\`

## Update the platform

From stackyard on your laptop: \`./bin/pin.sh <path-to-this-machine>\`, commit
here, then on the server \`git pull && ./bootstrap && ./stack --check\`.
EOF

echo "Machine created: $DEST"
echo "  stackyard: $VERSION ($COMMIT)"
echo
echo "Next:"
echo "  cd $DEST && git init && ./bootstrap"
echo "  fill in .env and .env-stacks, describe the stacks in stacks/"
