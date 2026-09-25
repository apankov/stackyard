#!/usr/bin/env bash

# Preparing a machine: the things done once that belong to no single stack —
# packages, placeholder certificates, systemd timers. A stack's own host-level
# needs are handled by its scripts/host-setup.sh.
#
# Why it exists: these steps used to be done by hand and from memory, and a
# forgotten one does not show up immediately. Forget the timers and
# certificates stop being renewed — which becomes visible only once they have
# expired.
#
# The script is idempotent: it installs only what is missing, and running it
# again is safe.
#
#   sudo ./host-setup      # check and install what is missing
#   ./host-setup --check   # check only, without root and without changes;
#                          # exit code 1 means something is missing
#
# What it does NOT do, and must not: it does not fill in secrets, does not
# touch DNS, does not bring stacks up. Those are interactive steps and live in
# the README.

set -euo pipefail

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

# Who the deployment belongs to. Derived from the directory rather than named,
# and derived ONCE: the same answer is needed by the ACME webroot check, by
# certs.sh and by systemd.sh, and three derivations of one fact are three
# chances for them to disagree about who the machine runs as.
DEPLOY_OWNER=$(stat -c '%U' "$ROOT_DIR" 2>/dev/null || stat -f '%Su' "$ROOT_DIR" 2>/dev/null || echo "")
ENV_FILE="$ROOT_DIR/.env"

CHECK_ONLY=0
if [ "${1:-}" = "--check" ]; then
  CHECK_ONLY=1
elif [ $# -gt 0 ]; then
  echo "Unknown argument: $1" >&2
  echo "Usage: sudo $0 [--check]" >&2
  exit 2
fi

PROBLEMS=0
WARNINGS=0

# shellcheck source=platform/lib/lib-stacks.sh
. "$LIB_DIR/lib-stacks.sh"
# shellcheck source=platform/lib/lib-env.sh
. "$LIB_DIR/lib-env.sh"

# Platform-level values only. Read through lib-env.sh rather than with grep: it
# is the only thing that expands ${...} and strips quotes the way docker
# compose does — otherwise the check and the container would see different
# values.
#
# Stack .env files are NOT read here: the platform does not know which keys
# they hold. A stack validates its own values, in its scripts/host-setup.sh.
ENV_VARS=(); env_load_files "$ENV_FILE"

ok()   { echo "  [ok]   $1"; }
warn() { echo "  [!]    $1"; WARNINGS=$((WARNINGS + 1)); }
bad()  { echo "  [FAIL] $1"; PROBLEMS=$((PROBLEMS + 1)); }
step() { echo; echo "== $1"; }

# The packages this script installs. Each one is a precondition for a specific
# step rather than a "just in case": openssl produces the placeholder
# certificates and dhparam, bzip2 compresses dumps, gnupg encrypts backups,
# logrotate rotates the nginx logs (there is no nginx package on the host, so
# there is no /etc/logrotate.d/nginx either).
#
# The list is platform-level rather than per-stack on purpose: disabling a
# stack must not remove a package someone else needs.
#
# The names here are GENERIC; pkg_name below translates them into a
# distribution's names. Generic because a precondition is a capability (to
# encrypt, to compress), not a line from one distribution's package index.
PACKAGES=(logrotate openssl bzip2 gnupg sqlite curl git)

# The package manager is detected, not assumed: the platform is distributed,
# and a hardcoded one means that on another distribution the first install runs
# into "command not found" — with advice that cannot be followed.
PKG_MGR=""
for m in apt-get dnf yum apk zypper; do  # pkg-mgr-ok
  command -v "$m" >/dev/null 2>&1 && { PKG_MGR="$m"; break; }
done

# The package name in a distribution's own terms. They do not always match:
# gnupg versus gnupg2, sqlite3 versus sqlite. A mistake here looks like "no
# such package" — that is, like the machine's problem rather than ours.
pkg_name() {
  case "$PKG_MGR:$1" in
    apt-get:gnupg|apk:gnupg)   echo gnupg ;;
    dnf:gnupg|yum:gnupg|zypper:gnupg) echo gnupg2 ;;
    apt-get:sqlite)            echo sqlite3 ;;
    apk:sqlite)                echo sqlite ;;
    *:sqlite)                  echo sqlite ;;
    *)                         echo "$1" ;;
  esac
}

# The command a package is wanted FOR. A package counts as present when its
# command is present, whatever the package is called locally.
#
# Distributions ship the same command under different package names, and some
# ship a stripped variant that CONFLICTS with the full one: on Amazon Linux
# 2023 gnupg2-minimal and curl-minimal provide gpg and curl while refusing to
# coexist with gnupg2 and curl. Checking the package name there asks for an
# install that cannot succeed, on a machine where nothing is actually missing.
pkg_command() {
  case "$1" in
    gnupg)  echo gpg ;;
    sqlite) echo sqlite3 ;;
    *)      echo "$1" ;;
  esac
}

pkg_installed() {
  case "$PKG_MGR" in
    apt-get) dpkg -s "$1" >/dev/null 2>&1 ;;  # pkg-mgr-ok
    dnf|yum|zypper) rpm -q "$1" >/dev/null 2>&1 ;;  # pkg-mgr-ok
    apk)     apk info -e "$1" >/dev/null 2>&1 ;;  # pkg-mgr-ok
    *)       return 1 ;;
  esac
}

pkg_install() {
  case "$PKG_MGR" in
    apt-get) apt-get update -qq && apt-get install -y "$@" ;;  # pkg-mgr-ok
    dnf|yum) "$PKG_MGR" install -y "$@" ;;  # pkg-mgr-ok
    apk)     apk add "$@" ;;  # pkg-mgr-ok
    zypper)  zypper install -y "$@" ;;  # pkg-mgr-ok
    *)       return 1 ;;
  esac
}

pkg_install_cmd() {
  case "$PKG_MGR" in
    apt-get) echo "sudo apt-get install -y" ;;  # pkg-mgr-ok
    dnf)     echo "sudo dnf install -y" ;;  # pkg-mgr-ok
    yum)     echo "sudo yum install -y" ;;  # pkg-mgr-ok
    apk)     echo "sudo apk add" ;;  # pkg-mgr-ok
    zypper)  echo "sudo zypper install -y" ;;  # pkg-mgr-ok
    *)       echo "(package manager not detected)" ;;
  esac
}

# ---------------------------------------------------------------- 1. basics

step "Environment"

if [ "$CHECK_ONLY" -eq 0 ] && [ "$(id -u)" -ne 0 ]; then
  echo "Error: root privileges are required. Run: sudo $0" >&2
  echo "  Or see what is missing, without changing anything: $0 --check" >&2
  exit 1
fi

command -v systemctl >/dev/null 2>&1 \
  && ok "systemd is present" \
  || bad "no systemctl — there is nothing to install timers into; this machine needs another scheduler"

if command -v docker >/dev/null 2>&1; then
  ok "docker: $(docker --version 2>/dev/null | head -n 1)"
  if docker compose version >/dev/null 2>&1; then
    ok "docker compose (v2 plugin)"
  else
    bad "no 'docker compose' — docker-compose.sh will not work (the v2 plugin is required, not docker-compose v1)"
  fi
  docker info >/dev/null 2>&1 \
    && ok "the docker daemon is responding" \
    || bad "the docker daemon is not responding: sudo systemctl enable --now docker"
else
  # Installing docker is deliberately not automated: it entails membership in
  # the docker group, which takes effect only after a re-login — so the script
  # could not finish the job in one pass anyway.
  bad "no docker. Install it from your distribution, then: sudo systemctl enable --now docker && sudo usermod -aG docker \$USER (and log in again)"
fi

# ------------------------------------------------------ 2. the external volume

DATA_MOUNT="$(env_get Platform_Data_Mount)"
if [ -n "$DATA_MOUNT" ]; then
  step "External volume $DATA_MOUNT"

  # A machine whose data lives on a SEPARATE volume declares it in
  # Platform_Data_Mount. If that volume is not mounted, `docker run -v` creates
  # empty directories under the mount point and the DBMS initialises a fresh
  # data directory inside them. From the outside this is indistinguishable from
  # data loss: the site comes up, the databases are empty, and everything has
  # been written to the wrong disk. Hence [FAIL] rather than a warning.
  #
  # An empty value is a legitimate state, not forgetfulness: on a machine where
  # the data directory is just a directory on the root partition, this check
  # would be a permanent false alarm — and a false alarm quickly teaches people
  # not to read the report.
  if mountpoint -q "$DATA_MOUNT" 2>/dev/null; then
    ok "$DATA_MOUNT is mounted"
  else
    bad "$DATA_MOUNT is NOT a mount point — the external volume is not attached; do not start databases"
    echo "         Check with: lsblk; findmnt $DATA_MOUNT"
  fi
else
  step "External volume"
  ok "Platform_Data_Mount is not set — this machine has no separate volume"
fi

# ------------------------------------------------------------------ 3. .env

step "Vendored layers"

# Before every other check: if the platform on the machine is not the version
# it claims, or was edited in place, then everything checked below is being
# checked by the wrong code.
"$DIR0/check-vendor.sh" | sed 's/^/  /' || PROBLEMS=$((PROBLEMS + 1))

step "Environment files"

if [ ! -f "$ENV_FILE" ]; then
  bad "no $ENV_FILE — cp .env.example .env && chmod 600 .env, then fill it in"
else
  ok ".env is present"

  DEPLOY=$(env_get Platform_Deploy_Dir)
  # A common way to shoot yourself in the foot: .env was copied from another
  # machine and points at that machine's path. Everything afterwards "works"
  # while mounting the wrong directory.
  if [ "$DEPLOY" != "$ROOT_DIR" ]; then
    bad "Platform_Deploy_Dir='$DEPLOY', while the repository is at '$ROOT_DIR'"
  else
    ok "Platform_Deploy_Dir matches the repository directory"
  fi

  NET=$(env_get Platform_Network)

  if [ -z "$NET" ]; then
    bad "Platform_Network is not set in .env"
  elif docker network inspect "$NET" >/dev/null 2>&1; then
    ok "docker network '$NET' exists"
  else
    warn "docker network '$NET' does not exist yet — docker-compose.sh will create it on first use"
  fi
fi

# Which stacks are enabled and what they are missing is asked of lib-stacks.sh
# rather than listed here: the set is defined by Enabled_Stacks in .env-stacks,
# and a second list would be exactly the drift this script guards against.
if [ -f "$ROOT_DIR/.env-stacks" ]; then
  ok ".env-stacks (enabled: $(stacks_enabled 2>/dev/null | tr '\n' ' '))"
else
  warn "no .env-stacks — every stack with a complete file set counts as enabled (cp .env-stacks.example .env-stacks)"
fi

for stack in $(stacks_enabled 2>/dev/null); do
  missing=$(stack_missing_files "$stack" | tr '\n' ' ')
  if [ -z "$(echo $missing)" ]; then
    ok "stack $stack: all files present"
  else
    for f in $missing; do
      if [ -f "$ROOT_DIR/$f.example" ]; then
        bad "stack $stack: no $f — cp $f.example $f && chmod 600 $f, then fill in the secrets"
      else
        bad "stack $stack: no $f"
      fi
    done
  fi
done

# ---------------------------------------------------------------- 4. packages

step "Unfilled secrets"

# The .env examples carry CHANGE_ME wherever a value must be supplied: without
# it, `--examples` could not validate compose syntax on a machine that holds no
# secrets. The price of that convenience is a placeholder which is easy to copy
# and overlook, so it is checked here. Searched for by VALUE rather than
# against a list of keys: the platform does not know which keys the next stack
# will introduce.
left=0
for f in "$ROOT_DIR"/.env "$ROOT_DIR"/.env-backup "$ROOT_DIR"/.env-notify "$ROOT_DIR"/stacks/*/.env; do
  [ -f "$f" ] || continue
  while IFS= read -r line; do
    case "$line" in \#*|'') continue ;; esac
    case "${line#*=}" in
      CHANGE_ME|'"CHANGE_ME"'|"'CHANGE_ME'")
        bad "${f#"$ROOT_DIR"/}: ${line%%=*} is not filled in (still CHANGE_ME)"; left=$((left + 1)) ;;
    esac
  done < "$f"
done
[ "$left" -eq 0 ] && ok "no unfilled values"

step "Packages"

if [ -z "$PKG_MGR" ]; then
  bad "package manager not recognised (looked for apt-get, dnf, yum, apk, zypper)"
  echo "         Install by hand: ${PACKAGES[*]}"
else
  MISSING_PKGS=()
  for pkg in "${PACKAGES[@]}"; do
    real="$(pkg_name "$pkg")"
    if command -v "$(pkg_command "$pkg")" >/dev/null 2>&1 || pkg_installed "$real"; then
      ok "$real"
    else
      MISSING_PKGS+=("$real")
    fi
  done

  if [ ${#MISSING_PKGS[@]} -gt 0 ]; then
    if [ "$CHECK_ONLY" -eq 1 ]; then
      bad "not installed: ${MISSING_PKGS[*]} ($(pkg_install_cmd) ${MISSING_PKGS[*]})"
    else
      echo "  ... installing ($PKG_MGR): ${MISSING_PKGS[*]}"
      # The install runs inside `if` on purpose. Under set -e a failing package
      # manager would otherwise end the whole run right here — and everything
      # after this step is the part that actually provisions the machine: the
      # stacks' host parts, the placeholder certificates, the systemd timers.
      # A machine would then be left without timers because one package name
      # was wrong, and the exit code would blame the packages.
      if pkg_install "${MISSING_PKGS[@]}"; then
        for pkg in "${MISSING_PKGS[@]}"; do ok "$pkg (installed)"; done
      else
        bad "could not install: ${MISSING_PKGS[*]} — install by hand and re-run"
      fi
    fi
  fi
fi

# The packages are installed — but what has to be checked is the COMMANDS. Each
# distribution names its packages differently (that difference has already
# caught us once), while a missing `gpg` breaks dump encryption identically
# everywhere. The list matches exactly what the scripts in platform/bin call.
#
# A missing command is a warning rather than a failure: sqlite3 is needed only
# by a machine with SQLite sources, curl only by a machine with notifications,
# and a [FAIL] for a capability nobody uses quickly teaches people not to read
# the report. The exceptions are openssl and git: without the first not even a
# placeholder certificate can be produced, without the second the layers cannot
# be updated by ./bootstrap.
step "Platform commands"

# A command and its package are named differently more often than one expects:
# gpg arrives in gnupg, sqlite3 in sqlite. Advice to "install the gpg package"
# cannot be followed while looking perfectly workable, and someone spends time
# on a package that does not exist.
pkg_for_cmd() {
  case "$1" in
    gpg)     echo gnupg ;;
    sqlite3) echo sqlite ;;
    *)       echo "$1" ;;
  esac
}

check_cmd() {
  local cmd="$1" sev="$2" why="$3" hint
  hint="$(pkg_install_cmd) $(pkg_name "$(pkg_for_cmd "$cmd")")"
  if command -v "$cmd" >/dev/null 2>&1; then
    ok "$cmd — $why"
  elif [ "$sev" = bad ]; then
    bad "no $cmd — $why ($hint)"
  else
    warn "no $cmd — $why ($hint)"
  fi
}

check_cmd openssl bad  "placeholder certificates and dhparam (certs.sh)"
check_cmd git     bad  "updating the layers (./bootstrap)"
check_cmd gpg     warn "encrypting dumps (backup.sh)"
check_cmd bzip2   warn "compressing dumps (backup.sh)"
check_cmd gzip    warn "reading and writing dumps (backup.sh, backup-restore.sh)"
check_cmd tar     warn "archiving file sources (backup.sh)"
check_cmd sqlite3 warn "taking copies of SQLite databases (backup.sh)"
check_cmd curl    warn "notifications (notify.sh)"

# aws is the one command whose necessity is declared rather than constant. It
# is asked of the stacks and of .env-backup rather than kept in a list here:
# otherwise a second stack pulling from a registry would require an edit here,
# and that edit would be forgotten.
#
# Whether the instance's role answers is a separate question, asked by
# registry.sh --check: having the command and having the permissions are not
# the same thing, and the second cannot be learned without the network.
# shellcheck disable=SC2119  # the stack list is optional for stacks_registries
REGISTRIES="$(stacks_registries 2>/dev/null | tr '\n' ' ')"
if [ -n "${REGISTRIES// /}" ]; then
  command -v aws >/dev/null 2>&1 \
    && ok "aws — images from registries: $REGISTRIES" \
    || bad "no aws, while stacks pull images from a registry ($REGISTRIES) — pulls will fail"
elif [ -f "$ROOT_DIR/.env-backup" ]; then
  if ! command -v aws >/dev/null 2>&1; then
    bad "no aws, while .env-backup is configured — backup.sh will not upload dumps"
  else
    ok "aws — uploading backups to S3"
    # Having the command and being able to use it are different questions, and
    # only the second one decides whether a backup exists. Credentials come
    # from .env-backup or from the instance's IAM role; with neither, backup.sh
    # dies at its own head-bucket — at three in the morning, into a journal
    # nobody reads. Asked here, while a person is looking.
    #
    # The same three lines of credential handling live in backup.sh and
    # check-backups.sh; a third copy is a fair price for not importing the rest
    # of their config parsing into a preflight check.
    s3probe="$(
      ENV_VARS=(); env_load_files "$ROOT_DIR/.env-backup" >/dev/null 2>&1
      b="$(env_get Backup_S3_Bucket)"
      k="$(env_get Backup_AWS_Access_Key_Id)"
      sec="$(env_get Backup_AWS_Secret_Access_Key)"
      r="$(env_get Backup_AWS_Region us-east-1)"
      [ -n "$b" ] || { printf 'nobucket'; exit 0; }
      printf '%s\t' "$b"
      if [ -n "$k" ]; then
        AWS_ACCESS_KEY_ID="$k" AWS_SECRET_ACCESS_KEY="$sec" \
          run_with_timeout 20 aws --region "$r" s3api head-bucket --bucket "$b" >/dev/null 2>&1 \
          && printf 'ok' || printf 'fail'
      else
        run_with_timeout 20 aws --region "$r" s3api head-bucket --bucket "$b" >/dev/null 2>&1 \
          && printf 'role' || printf 'fail'
      fi
    )"
    case "$s3probe" in
      nobucket) bad "Backup_S3_Bucket is empty in .env-backup — there is nowhere to upload to" ;;
      *$'\t'ok)   ok "s3://${s3probe%%$'\t'*} answers with the keys from .env-backup" ;;
      *$'\t'role) ok "s3://${s3probe%%$'\t'*} answers through the instance's IAM role" ;;
      *)        bad "s3://${s3probe%%$'\t'*} does not answer — neither .env-backup keys nor an instance role work; backup.sh will fail at upload" ;;
    esac
  fi
else
  ok "aws is not needed: no image registries, no .env-backup"
fi

# --------------------------------------------------- 5. stacks' host-level needs

step "Stacks' host-level needs"

# Not everything a stack needs lives inside a container: one may need a shim on
# the host's PATH, another a configuration file for an external toolkit. Doing
# that here would mean the platform knowing about each stack's technology.
#
# Instead the stack does it itself: the presence of scripts/host-setup.sh IS
# the declaration, no separate key is needed for it, just as with health.sh.
# The contract: idempotent, understands --check (change nothing, non-zero exit
# when something is missing), receives ROOT_DIR and STACK_DIR in its
# environment.
for stack in $(stacks_enabled 2>/dev/null); do
  hook="$(stack_dir "$stack")/scripts/host-setup.sh"
  [ -x "$hook" ] || continue
  if [ "$CHECK_ONLY" -eq 1 ]; then
    ROOT_DIR="$ROOT_DIR" STACK_DIR="$(stack_dir "$stack")" "$hook" --check 2>&1 | sed "s/^/  [$stack] /" \
      || PROBLEMS=$((PROBLEMS + 1))
  else
    ROOT_DIR="$ROOT_DIR" STACK_DIR="$(stack_dir "$stack")" "$hook" 2>&1 | sed "s/^/  [$stack] /"
  fi
done

# ------------------------------------------------------------------ 7. swap

TOTAL_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)
SWAP_MB=$(awk '/SwapTotal/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)
if [ "${TOTAL_MB:-0}" -gt 0 ]; then
  step "Memory"
  if [ "$SWAP_MB" -eq 0 ] && [ "$TOTAL_MB" -lt 4096 ]; then
    warn "RAM ${TOTAL_MB}M, no swap — an image build may fail for lack of memory"
  else
    ok "RAM ${TOTAL_MB}M, swap ${SWAP_MB}M"
  fi
fi

# ------------------------------------------------- 8. certificates and timers

# The ACME webroot: getssl writes the challenge into it as the repository's
# owner, and nginx serves it. A directory docker created on its own is owned by
# root, and then renewal fails — but only the day a certificate actually needs
# renewing. Until then every run exits cleanly with nothing to do, which is
# indistinguishable from a healthy machine.
ACME_DIR="$ROOT_DIR/state/acme/.well-known/acme-challenge"
if ! stacks_getssl_any; then
  # Nothing on this machine answers an HTTP-01 challenge, so there is no
  # webroot to get wrong. Said rather than skipped: an absent line reads as a
  # check that was forgotten.
  ok "no ACME webroot needed — every domain is Certs=external"
elif [ ! -d "$ACME_DIR" ]; then
  if [ "$CHECK_ONLY" -eq 1 ]; then
    bad "no $ACME_DIR — getssl will have nowhere to put the challenge (./stack sync creates it)"
  else
    install -d -o "$DEPLOY_OWNER" -m 755 "$ROOT_DIR/state/acme" "$ROOT_DIR/state/acme/.well-known" "$ACME_DIR" \
      && ok "the ACME webroot is in place" \
      || bad "could not create $ACME_DIR"
  fi
elif [ "$(stat -c %U "$ACME_DIR" 2>/dev/null || stat -f %Su "$ACME_DIR")" != "$DEPLOY_OWNER" ]; then
  if [ "$CHECK_ONLY" -eq 1 ]; then
    bad "$ACME_DIR is not owned by $DEPLOY_OWNER — getssl cannot write the challenge there (sudo chown -R $DEPLOY_OWNER $ROOT_DIR/state/acme)"
  else
    chown -R "$DEPLOY_OWNER" "$ROOT_DIR/state/acme" \
      && ok "the ACME webroot now belongs to $DEPLOY_OWNER" \
      || bad "could not chown $ROOT_DIR/state/acme"
  fi
else
  ok "the ACME webroot belongs to $DEPLOY_OWNER"
fi

step "Placeholder certificates and timers"

# getssl is not kept in the repository — it is downloaded according to
# platform/getssl.lock. Before the timer checks: without it there is nowhere to
# install the units, and a failure of the form "there is a timer but no
# renewals" would look exactly like a healthy machine with nothing to renew.
if ! stacks_getssl_any; then
  ok "getssl is not needed — every domain is Certs=external"
elif [ "$CHECK_ONLY" -eq 1 ]; then
  "$DIR0/getssl-fetch.sh" --check || PROBLEMS=$((PROBLEMS + 1))
else
  "$DIR0/getssl-fetch.sh" | sed 's/^/  /' || PROBLEMS=$((PROBLEMS + 1))
fi

if [ "$CHECK_ONLY" -eq 1 ]; then
  [ -f "$ROOT_DIR/state/certs/nginx-selfsigned.crt" ] \
    && ok "the placeholder certificate exists" \
    || bad "no placeholder certificates — ./platform/bin/certs.sh (without them nginx will not start with a new vhost)"

  # Platform timers always; stack timers according to what is enabled. A list
  # by name would mean that on a machine without such a stack the check demands
  # a timer that has no business being there.
  # The renewal timers belong in the list only where getssl runs at all: with
  # every domain external, systemd.sh removes them, and demanding them back
  # here would be this check contradicting its own installer.
  EXPECTED_TIMERS=()
  stacks_getssl_any && EXPECTED_TIMERS+=(getssl-renew.timer getssl-check.timer)
  while IFS= read -r stack; do
    [ -n "$stack" ] || continue
    while IFS= read -r unit; do
      case "$unit" in *.timer) EXPECTED_TIMERS+=("$(basename "$unit")") ;; esac
    done < <(stack_units "$stack")
  done < <(stacks_enabled 2>/dev/null)
  [ -f "$ROOT_DIR/.env-backup" ] && EXPECTED_TIMERS+=(devbox-backup.timer devbox-backup-check.timer)
  [ -f "$ROOT_DIR/.env-notify" ] && EXPECTED_TIMERS+=(devbox-watch.timer devbox-heartbeat.timer)

  # See the note on empty arrays in systemd.sh: bash 4.2 has no other way.
  for t in ${EXPECTED_TIMERS[@]+"${EXPECTED_TIMERS[@]}"}; do
    systemctl is-enabled "$t" >/dev/null 2>&1 \
      && ok "$t is enabled" \
      || bad "$t is not installed — sudo ./platform/bin/systemd.sh"
  done

  # The old scheduler. A leftover cron line means getssl runs twice — from cron
  # and from the timer — and two parallel renewals fight over one ACME account
  # and one directory.
  if sudo -n true 2>/dev/null || [ "$(id -u)" -eq 0 ]; then
    # Searched for by THIS machine's paths rather than a hardcoded name: a
    # specific machine's name inside the platform would mean the check silently
    # passes on every other machine, having found nothing.
    if grep -qsF "$ROOT_DIR" /etc/crontab /etc/cron.d/* 2>/dev/null \
       || grep -qsE 'getssl|backup\.sh' /etc/crontab /etc/cron.d/* 2>/dev/null; then
      bad "cron still holds jobs for this machine — they duplicate the systemd timers; remove them"
      grep -nsE "$ROOT_DIR|getssl|backup\.sh" /etc/crontab /etc/cron.d/* 2>/dev/null | sed 's/^/         /'
    else
      ok "cron holds no jobs for this machine"
    fi
  fi
else
  # certs.sh runs as the repository's owner, NOT as root: the getssl timer runs
  # as that same user and will later overwrite the placeholders with real
  # certificates. Root-owned files it cannot silently replace.
  echo "  ... placeholder certificates (as $DEPLOY_OWNER)"
  # ROOT_DIR is passed EXPLICITLY through env: sudo resets the environment, so a
  # variable exported by the wrapper never reaches the child process. Without
  # it certs.sh derives the root from its own path — which is inside
  # .stackyard/platform/bin, making .stackyard the root, and the script looks
  # for .env there. The failure reads as "no .env" on a machine that has one.
  sudo -u "$DEPLOY_OWNER" env ROOT_DIR="$ROOT_DIR" "$DIR0/certs.sh" | sed 's/^/      /'

  echo "  ... systemd timers"
  "$DIR0/systemd.sh" | sed 's/^/      /'
fi

# ------------------------------------------------------------------ 9. summary

echo
if [ "$PROBLEMS" -gt 0 ]; then
  echo "Not ready: problems — $PROBLEMS, warnings — $WARNINGS."
  [ "$CHECK_ONLY" -eq 1 ] && echo "Fix what can be fixed automatically: sudo $0"
  exit 1
fi

echo "The host is ready. Warnings: $WARNINGS."
echo
echo "To check the state at any time:"
echo "  $0 --check"
echo "  ./stack --check"
echo "  systemctl list-timers 'getssl-*' 'devbox-*'"
