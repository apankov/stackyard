#!/usr/bin/env bash

# The single entry point to docker compose on this machine.
#
# It assembles one `docker compose` invocation from the platform's files and
# the files of the ENABLED stacks. Which stacks those are comes from
# Enabled_Stacks in .env-stacks. No script holds its own list of files: a
# second place with the same knowledge drifts from the manifest silently.
#
# A consequence: a disabled stack's file is never parsed, so a missing .env in
# a DISABLED stack breaks nothing. In an enabled one it breaks every compose
# command on the machine — which is correct, because the stack would not work
# anyway. This script names which file of which stack is missing, instead of
# leaving compose to print a wall of interpolation errors.
#
#   ./dc up -d                              # the enabled stacks
#   ./dc --all-stacks config -q             # validate ALL files, disabled
#                                           # stacks included
#   ./dc --all-stacks --examples config -q  # the same on a machine that holds
#                                           # no secrets

set -e

DIR0="$( cd -P "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# The MACHINE's directory, not the platform's. Normally set by a wrapper in the
# machine root; the fallback is two levels up from platform/bin, so the script
# also works when invoked directly.
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
ENV_FILE="$ROOT_DIR/.env"

# Every `-f` and `--env-file` below is relative. This cd guarantees that a call
# from anywhere (a systemd unit, someone else's script) still finds those
# files; the project directory is set separately, via --project-directory.
cd "$ROOT_DIR"

# shellcheck source=platform/lib/lib-stacks.sh
. "$LIB_DIR/lib-stacks.sh"

# Flags come before the command only.
#
# --all-stacks is for validating the whole repository (`config -q`) and for CI:
# the manifest describes one machine, while a syntax error can be introduced in
# the file of a stack that is disabled there.
#
# --examples substitutes a stack's .env.example wherever the real file is
# absent. A developer's machine holds no secrets at all, and the config of
# every stack has to be validated BEFORE the branch reaches a server. On a
# server the flag changes nothing — the real files are there and take
# precedence.
ALL_STACKS=0
USE_EXAMPLES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --all-stacks) ALL_STACKS=1; shift ;;
    --examples)   USE_EXAMPLES=1; shift ;;
    *)            break ;;
  esac
done

# 1. The .env file itself
if [ ! -f "$ENV_FILE" ]; then
  if [ "$USE_EXAMPLES" -eq 1 ] && [ -f "$ENV_FILE.example" ]; then
    ENV_FILE="$ENV_FILE.example"
  else
    echo "Error: environment file '$ENV_FILE' not found" >&2
    exit 1
  fi
fi

# 2. The network name from .env (ignoring whitespace and quotes)
TARGET_NETWORK=$(grep -E '^Platform_Network=' "$ENV_FILE" | head -n 1 | cut -d '=' -f2- | tr -d '"'\')

# 3. Platform_Network must not be empty
if [ -z "$TARGET_NETWORK" ]; then
  echo "Error: Platform_Network is not set in $ENV_FILE" >&2
  exit 1
fi

# Exported into the environment so compose reliably sees it while parsing the
# YAML files.
export Platform_Network="${TARGET_NETWORK}"

# ------------------------------------------------------- building the command

if [ "$ALL_STACKS" -eq 1 ]; then
  STACKS=$(stacks_available)
else
  STACKS=$(stacks_enabled)
fi

# Which env file to use for a stack: the real one, otherwise the example under
# --examples, otherwise none (a stack without an .env.example gets by on the
# root .env).
env_file_for() {
  local f ex
  f="$(stack_env_file "$1")"
  # The example is looked for NEXT TO THE STACK rather than along the machine
  # path: a profile stack's .env is the machine's, while its .env.example lives
  # under profile/. Looking along the machine path would never find it, and
  # --examples would fail on a profile stack in exactly the situation it exists
  # to survive.
  ex="$(stack_dir "$1")/.env.example"
  if [ -f "$f" ]; then printf '%s' "$f"
  elif [ "$USE_EXAMPLES" -eq 1 ] && [ -f "$ex" ]; then printf '%s' "$ex"
  fi
}

# What the enabled stacks are missing. Checked BEFORE calling compose: "which
# file of which stack is absent" is more useful than an interpolation error
# from the middle of the tenth YAML file. Under --examples this is skipped
# entirely: there, a missing real file is normal rather than a breakage.
MISSING=""
if [ "$USE_EXAMPLES" -eq 0 ]; then
  for stack in $STACKS; do
    for f in $(stack_missing_files "$stack"); do
      MISSING="$MISSING  $stack: missing $f"$'\n'
    done
  done
fi
if [ -n "$MISSING" ]; then
  echo "Error: enabled stacks are missing files:" >&2
  printf '%s' "$MISSING" >&2
  echo "Create them from the examples (cp stacks/<stack>/.env.example stacks/<stack>/.env && chmod 600 ...)" >&2
  echo "or disable the stack: ./stack disable <stack>" >&2
  exit 1
fi

# On a fresh checkout the generated statics file does not exist, and compose
# fails on a missing -f. It is written silently: a warning about drift comes
# later, whereas refusing here would mean no command works after a `git pull` —
# exactly the class of breakage this repository exists to prevent.
ensure_state_dirs

for gen in "$(stacks_static_file)" "$(stacks_include_file)"; do
  [ -f "$gen" ] && continue
  mkdir -p "$(dirname "$gen")"
  # Compared against the value rather than a name pattern. A pattern survives a
  # rename of the file it matches: the branch stops matching silently, and the
  # generated include is never created at all.
  if [ "$gen" = "$(stacks_static_file)" ]; then
    stacks_static_content  > "$gen"
  else
    stacks_include_content > "$gen"
  fi
done

# The database list is generated too, but it lives inside the provider stack's
# state and is needed only while that stack is enabled. Here it is merely
# CREATED empty when absent: docker turns a missing bind-mount file into a
# root-owned DIRECTORY, and the initializer then fails on it obscurely. The
# contents are written by `stack sync` — there is nothing here to generate them
# with, because this script deliberately does not load lib-env.sh (see the
# lib-stacks.sh header).
#
# The path is empty when no DB provider is enabled, which is a legitimate
# state: a machine with a single proxy stack has no shared DBMS. Without the
# emptiness check this became `: > ""`, so every compose command failed on a
# machine that needs no database, complaining about a file that does not
# exist.
DB_FILE="$(stacks_databases_file)"
if [ -n "$DB_FILE" ] && [ ! -f "$DB_FILE" ]; then
  mkdir -p "$(dirname "$DB_FILE")"
  : > "$DB_FILE"
  chmod 600 "$DB_FILE"
fi

# Platform files always. The generated statics file is included here precisely
# so that the nginx spec does not depend on which stacks are enabled (see its
# own header).
#
# --project-directory and -p are set EXPLICITLY. Compose treats the directory
# of the first -f as the project directory, and the first -f lives in
# platform/compose/: without these two lines relative bind mounts would resolve
# there, and the project name would become "compose" — after which stack.sh
# would no longer find existing containers by their labels.
DOCKER_COMPOSE_BASE=(
  docker compose
  --project-directory "$ROOT_DIR"
  -p "$(compose_project)"
  --env-file "$ENV_FILE"
)

for stack in $STACKS; do
  ef="$(env_file_for "$stack")"
  [ -n "$ef" ] && DOCKER_COMPOSE_BASE+=(--env-file "${ef#"$ROOT_DIR"/}")
done

# The generated file's path is asked of the library. A name written a second
# time survives a rename silently — and a consumer that no longer matches stops
# doing its job without saying so.
STATIC_REL="$(stacks_static_file)"; STATIC_REL="${STATIC_REL#"$ROOT_DIR"/}"

DOCKER_COMPOSE_BASE+=(
  -f platform/compose/nginx.yaml
  -f "$STATIC_REL"
)

# A stack with no containers of its own (a site running on the platform's
# nginx/php-fpm) has no compose file at all — see stack_missing_files in
# lib-stacks.sh. To compose, a non-existent -f is not "an empty file" but a
# refusal to run the command.
#
# The path is asked of stack_dir: a stack may live in the machine's stacks/ or
# in the profile's. A string-built path would work for only one of the two.
for stack in $STACKS; do
  f="$(stack_compose_file "$stack")"
  [ -f "$f" ] && DOCKER_COMPOSE_BASE+=(-f "${f#"$ROOT_DIR"/}")
done

# At least one argument is required
if [ $# -eq 0 ]; then
  echo "Error: no command given (for example: up, down, config)" >&2
  echo "Usage: $0 [--all-stacks] [--examples] <command> [arguments...]" >&2
  echo "Enabled stacks: $(echo $STACKS | tr '\n' ' ')" >&2
  exit 1
fi

# 4. The external network: check and create.
#
# Under --examples the network is left alone: that mode validates a config on a
# developer's machine, and creating a docker network there would change state
# for a command that is not going to start anything.
if [ "$USE_EXAMPLES" -eq 0 ] && ! docker network inspect "${TARGET_NETWORK}" >/dev/null 2>&1; then
  echo "Network '${TARGET_NETWORK}' not found. Creating it..."
  docker network create "${TARGET_NETWORK}"
fi

# 5. nginx being out of step with the manifest is a warning, not a refusal.
#
# This is the only place where someone typing `up -d` after a `git pull` will
# notice it: the include file is generated and kept out of git, so on a fresh
# checkout it simply does not exist, and after ANY subsequent reload nginx
# would be left with no vhosts at all. Refusing is not an option: `up` is
# sometimes needed precisely to start an application before nginx first sees
# its vhost.
#
# STACK_SH_APPLYING is set by stack.sh: it calls `up -d` in exactly the window
# where the include file has not been rewritten yet, and warning here would
# alarm someone about something the next line of that script fixes.
if [ "$ALL_STACKS" -eq 0 ] && [ -z "${STACK_SH_APPLYING:-}" ]; then
  INCLUDE_FILE="$(stacks_include_file)"
  STATIC_FILE="$(stacks_static_file)"
  if [ ! -f "$INCLUDE_FILE" ] || [ "$(cat "$INCLUDE_FILE")" != "$(stacks_include_content)" ] \
     || [ "$(cat "$STATIC_FILE")" != "$(stacks_static_content)" ]; then
    echo "Warning: the generated nginx files do not match stacks/." >&2
    echo "  Bring them in line with: ./stack sync" >&2
  fi
fi

# Logging in to image registries, before commands that may pull an image.
#
# This is exactly where the login has to happen: a registry token is
# short-lived, and "log in beforehand" means a pull failing at an unpredictable
# moment. Here it is always fresh, and there are no wasted calls — registry.sh
# keeps a stamp and stays quiet while the login is recent, and exits
# immediately when the enabled stacks use no external registry at all. A
# machine without a registry pays for one process exit.
#
# As a separate process rather than via source: registry.sh loads lib-env.sh,
# which this script deliberately does not know about (see the lib-stacks.sh
# header).
#
# --soft: a failed login is a warning, not a refusal. A command such as
# `up -d nginx` needs no registry at all, and failing here would make the
# machine depend on someone else's service where it does not.
#
# There is deliberately NO test for the file's existence: registry.sh is part
# of the platform and must be there. An `[ -x ]` guard would silently swallow a
# broken or missing platform, which is precisely what should be learned about
# at once.
for arg in "$@"; do
  case "$arg" in
    -*) continue ;;
    pull|up|create|run)
      [ "$USE_EXAMPLES" -eq 0 ] && ROOT_DIR="$ROOT_DIR" "$DIR0/registry.sh" login --soft || true ;;
  esac
  break
done

# Run the assembled command with every argument passed through
"${DOCKER_COMPOSE_BASE[@]}" "$@"
