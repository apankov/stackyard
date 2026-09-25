#!/usr/bin/env bash

# Backing up a machine: dump -> GPG -> S3.
#
# The things that matter here and are not obvious:
#
#   * Sources are processed ONE AT A TIME, and a file leaves the disk (or moves
#     into the generations directory) before the next one starts. Peak disk use
#     is the single largest dump, not the sum of all of them — the scratch
#     directory usually shares a partition with the data being dumped.
#   * A file exists under its final name only if the whole pipeline succeeded
#     (.part -> mv). A truncated dump therefore looks like a backup to nothing:
#     not to the upload, not to rotation, not to check-backups.sh.
#   * The list of databases is asked of the DBMS rather than taken from a
#     config. Otherwise the next database someone creates silently goes
#     unbacked.
#   * The database password is expanded INSIDE the container and appears
#     neither in the backup config nor in `ps`.
#   * One failed source does not cancel the others, but it does fail the whole
#     run: the exit code is non-zero and the systemd unit goes to failed.
#
#   sudo ./platform/bin/backup.sh            # full run
#   sudo ./platform/bin/backup.sh --dry-run  # print the plan, change nothing

set -euo pipefail

DIR0="$( cd -P "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# The MACHINE's directory, not the platform's. Normally set by a wrapper in the
# machine root; the fallback is two levels up from platform/bin.
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
# lib-stacks is needed from the very start: the DB provider is asked for while
# the config is still being parsed.
# shellcheck source=platform/lib/lib-stacks.sh
. "$LIB_DIR/lib-stacks.sh"

# The script's own state lives in /var/lib, on the same principle: not in the
# repository (which gets moved and recreated) and not in /tmp (which is
# cleaned).
STATE_DIR=/var/lib/devbox-backup
GNUPGHOME_DIR="$STATE_DIR/gnupg"
LOCK_FILE="$STATE_DIR/backup.lock"
SIZES_FILE="$STATE_DIR/last-sizes"

DRY_RUN=0

usage() {
  cat <<'EOF'
Usage: sudo ./platform/bin/backup.sh [--dry-run]

  --dry-run   print what would be done and exit. Environment checks run in
              full; no dump is taken and nothing is uploaded to S3.
  --help      this help

Configuration: .env-backup (see .env-backup.example).
Verifying the result: ./platform/bin/check-backups.sh
Restoring: ./platform/bin/backup-restore.sh
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# ------------------------------------------------------------------ output

log()  { echo "$*"; }
warn() { echo "  [!]    $*" >&2; }
die()  { echo "Error: $*" >&2; exit 2; }

FAILED=()
fail_source() { FAILED+=("$1"); echo "  [FAIL] $1: $2" >&2; }

# --------------------------------------------------------------- configuration

ENV_BACKUP="$ROOT_DIR/.env-backup"
[ -f "$ENV_BACKUP" ] || die "missing $ENV_BACKUP — cp .env-backup.example .env-backup && chmod 600 .env-backup"

# Stack .env files are NOT loaded here: stack sources are read by
# stack_backup_sources, each with its own variable set. Mixing them into one
# ENV_VARS is not allowed — one stack's values would leak into another's
# substitutions.
env_load_files "$ROOT_DIR/.env" "$ENV_BACKUP"

S3_BUCKET=$(env_require Backup_S3_Bucket "the bucket name, without s3:// and without slashes") || exit 2
S3_PREFIX=$(backup_s3_prefix)
AWS_REGION=$(env_get Backup_AWS_Region us-east-1)
AWS_KEY=$(env_get Backup_AWS_Access_Key_Id)
AWS_SECRET=$(env_get Backup_AWS_Secret_Access_Key)

GPG_RECIPIENT=$(env_require Backup_GPG_Recipient "the recipient's fingerprint or email") || exit 2
GPG_PUBKEY=$(env_get Backup_GPG_Pubkey "gpg/backup-pubkey.asc")
case "$GPG_PUBKEY" in /*) ;; *) GPG_PUBKEY="$ROOT_DIR/$GPG_PUBKEY" ;; esac

LOCAL_DIR=$(env_get Backup_Local_Dir /mnt/data/backups)
LOCAL_KEEP=$(env_get Backup_Local_Keep 1)
MIN_FREE_MB=$(env_get Backup_Min_Free_MB 1024)
MIN_OBJ_BYTES=$(env_get Backup_Min_Object_Bytes 1024)
MIN_GLOBALS_BYTES=$(backup_min_globals_bytes)

# Numeric settings are validated up front. A non-numeric value would otherwise
# blow up mid-run, inside `[ "$x" -gt 0 ]` — that is, after some dumps have
# already been taken, and with a message that gives no hint of the cause.
for pair in "Backup_Local_Keep:LOCAL_KEEP" "Backup_Min_Free_MB:MIN_FREE_MB" "Backup_Min_Object_Bytes:MIN_OBJ_BYTES"; do
  key="${pair%%:*}"; var="${pair##*:}"
  case "${!var}" in
    ''|*[!0-9]*) die "$key must be an integer, not '${!var}'" ;;
  esac
done

DB_PROVIDER="$(stacks_db_provider)"
# The S3 prefix for the shared DBMS's dumps. Defaults to the provider stack's
# name.
#
# It is overridable because changing the prefix on a RUNNING machine means new
# dumps go somewhere else while check-backups.sh keeps looking in the old place
# and reports "no backups" for healthy backups. A machine already writing under
# an older prefix just keeps Backup_DB_Prefix set to it.
DB_PREFIX=$(backup_db_prefix)

# The scratch directory sits next to the generations directory, ON THE SAME
# partition. Otherwise the final `mv` out of /tmp would be a copy, doubling the
# disk peak at exactly the moment this script works to keep it low.
TMP_DIR="$LOCAL_DIR/.tmp"

TS=$(date -u +%Y%m%dT%H%M%SZ)

# ------------------------------------------------------------------ helpers

free_mb() { df -Pk "$1" | awk 'NR == 2 { print int($4 / 1024) }'; }

# Bytes below a kilobyte are printed AS bytes. Rounding them to "0 KiB" makes a
# perfectly good globals dump — a few hundred bytes of GRANT lines — read as
# "we uploaded nothing", which is the exact conclusion the size floor above
# exists to prevent anyone from drawing by accident.
human_size() {
  awk -v b="${1:-0}" 'BEGIN {
    if (b < 1024)       { printf "%d B", b }
    else if (b < 1048576) { printf "%.1f KiB", b / 1024 }
    else                { printf "%.1f MiB", b / 1048576 } }'
}
file_size() { stat -c %s "$1" 2>/dev/null || stat -f %z "$1"; }

aws_cli() {
  if [ -n "$AWS_KEY" ]; then
    AWS_ACCESS_KEY_ID="$AWS_KEY" AWS_SECRET_ACCESS_KEY="$AWS_SECRET" \
      aws --region "$AWS_REGION" "$@"
  else
    # No keys means we run under an IAM instance role. That is the preferred
    # path: no long-lived key is stored on the machine at all.
    aws --region "$AWS_REGION" "$@"
  fi
}

# --compress-algo none: the dump is already compressed by the provider's hook.
# A second compression pass on a small machine is pure waste.
#
# --trust-model always: the key is imported from the repository and nobody has
# set ownertrust on it; without this, gpg in batch mode refuses to encrypt.
#
# But that option may not exist. Some distributions build gnupg without trust
# models (--disable-trust-models): there gpg does not know the word
# --trust-model at all, answers `invalid option "--trust-model"` and exits with
# code 2 before it even looks at the rest of the arguments. The option is not
# needed in such a build — its trust model is hardwired to always, exactly what
# we ask for. The package can be swapped by an unattended upgrade, so the
# binary itself is asked rather than guessing from a package name or parsing
# stderr.
GPG_TRUST_OPT=""
gpg_detect_trust_opt() {
  if gpg --homedir "$GNUPGHOME_DIR" --batch --no-tty \
         --trust-model always --version >/dev/null 2>&1; then
    GPG_TRUST_OPT="--trust-model always"
  fi
}

gpg_encrypt() {
  # $GPG_TRUST_OPT must split into two words, hence no quotes.
  # shellcheck disable=SC2086
  gpg --homedir "$GNUPGHOME_DIR" --batch --yes --quiet --no-tty \
      $GPG_TRUST_OPT --compress-algo none \
      --encrypt --recipient "$GPG_RECIPIENT" --output -
}

# ------------------------------------------------- dumps of the shared DBMS
#
# The platform does not know which DBMS a machine runs, and must not: the dump
# command is the provider's knowledge, just as the list of valid privileges
# lives in the provider's own check-decl.sh. Otherwise this script would have
# to be forked per machine — reintroducing the very copy of the platform this
# design avoids.
#
# The contract of the <provider>/scripts/backup-dump.sh hook:
#   check     — is the DBMS answering? non-zero exit and a reason on stderr
#   list      — database names, one per line, system ones excluded
#   dump <db> — a dump of one database on stdout, already compressed
#   globals   — cluster-level objects (roles, grants) on stdout; empty if the
#               engine has none
#   ext       — the dump file's extension
#
# The hook receives ROOT_DIR and STACK_DIR and runs as the same user.
db_hook() {
  local provider; provider="$(stacks_db_provider)"
  [ -n "$provider" ] || return 1
  local h; h="$(stack_dir "$provider")/scripts/backup-dump.sh"
  [ -x "$h" ] || return 1
  ROOT_DIR="$ROOT_DIR" STACK_DIR="$(stack_dir "$provider")" "$h" "$@"
}

dump_db()      { db_hook dump "$1"; }
dump_globals() { db_hook globals; }

# `.backup` rather than `cp`: copying a live database while a writer is active
# produces a corrupted copy.
# An intermediate uncompressed file is unavoidable (sqlite3 cannot write a
# backup to stdout) and is accounted for in the preflight checks.
dump_sqlite() {
  local src="$1" tmp="$TMP_DIR/sqlite-$$.db" rc=0
  sqlite3 "$src" ".backup '$tmp'" || { rm -f "$tmp"; return 1; }
  gzip -9 -c "$tmp" || rc=$?
  rm -f "$tmp"
  return "$rc"
}

# A directory or file on the host. Via `-C` rather than an absolute path: tar
# given an absolute path warns and strips the leading slash, and restoring such
# an archive later has to be done blind.
dump_files() {
  local path="$1"
  [ -e "$path" ] || return 1
  tar -czf - -C "$(dirname "$path")" "$(basename "$path")"
}

# A named volume is read through a throwaway container: the volume's contents
# live inside docker's own storage and are not readable from the host directly,
# and reaching in by hand means changing permissions under a running
# container.
dump_volume() {
  local vol="$1"
  docker volume inspect "$vol" >/dev/null 2>&1 || return 1
  docker run --rm -v "$vol":/v:ro alpine tar -czf - -C /v .
}

# Keep at most N newest files in a directory.
rotate_dir() {
  local dir="$1" keep="$2" n=0 f
  [ -d "$dir" ] || return 0
  while IFS= read -r f; do
    n=$((n + 1))
    [ "$n" -le "$keep" ] && continue
    rm -f "$dir/$f"
    log "    rotation: removed generation $f"
  done < <(ls -1t "$dir" 2>/dev/null)
}

# ------------------------------------------------- one source, end to end

# run_job <label> <S3 subpath> <file name> <command writing the dump to stdout...>
run_job() {
  local label="$1" sub="$2" fname="$3"; shift 3
  local key="$S3_PREFIX/$sub/$fname"
  # The temporary file's name includes the source, not just the timestamp.
  # Otherwise every database would share one name: when an upload fails, the
  # first database's file is deliberately left on disk as the only copy — and
  # the next database's dump would overwrite it, making the message "file left
  # at ..." a lie.
  local stem="${sub//\//_}"
  local part="$TMP_DIR/$stem-$fname.part" final="$TMP_DIR/$stem-$fname"
  local bytes remote

  if [ "$DRY_RUN" -eq 1 ]; then
    log "  [dry-run] $label → s3://$S3_BUCKET/$key"
    return 0
  fi

  # pipefail is mandatory: without it a failed dump is masked by a successful
  # gpg, and neatly encrypted emptiness is uploaded to S3.
  if ! { "$@" | gpg_encrypt > "$part"; }; then
    rm -f "$part"
    fail_source "$label" "the dump or the encryption failed"
    return 1
  fi

  bytes=$(file_size "$part")
  # A globals dump is judged by its own floor: see backup_min_globals_bytes.
  floor="$MIN_OBJ_BYTES"
  case "$label" in *_globals) floor="$MIN_GLOBALS_BYTES" ;; esac
  if [ "$bytes" -lt "$floor" ]; then
    rm -f "$part"
    fail_source "$label" "the dump is suspiciously small ($bytes B < $floor B)"
    return 1
  fi

  mv "$part" "$final"

  if ! aws_cli s3 cp "$final" "s3://$S3_BUCKET/$key" --only-show-errors; then
    # The file is NOT deleted: the upload failed, and the local copy is all
    # there is.
    fail_source "$label" "the upload to S3 failed, the file was left at $final"
    return 1
  fi

  remote=$(aws_cli s3api head-object --bucket "$S3_BUCKET" --key "$key" \
             --query ContentLength --output text 2>/dev/null || echo "")
  if [ "$remote" != "$bytes" ]; then
    fail_source "$label" "the size in S3 ($remote) does not match the local one ($bytes)"
    return 1
  fi

  echo "$label $bytes" >> "$SIZES_FILE.new"
  log "  [ok]   $label — $(human_size "$bytes") -> s3://$S3_BUCKET/$key"

  # The local copy is a convenience, not part of the contract. If it does not
  # fit, it is skipped: the backup is already in S3, and filling the disk to
  # zero would turn the safety net into a second incident.
  if [ "$LOCAL_KEEP" -gt 0 ] && [ "$(free_mb "$LOCAL_DIR")" -gt "$MIN_FREE_MB" ]; then
    install -d -m 700 "$LOCAL_DIR/$sub"
    mv "$final" "$LOCAL_DIR/$sub/$fname"
    rotate_dir "$LOCAL_DIR/$sub" "$LOCAL_KEEP"
  else
    rm -f "$final"
    [ "$LOCAL_KEEP" -gt 0 ] && warn "$label: local copy skipped, less than ${MIN_FREE_MB} MiB free"
  fi
  return 0
}

# ------------------------------------------------------------- 1. preparation

log "== Backup run $TS"

# Checked before the first action: otherwise the first message would be
# "install: mkdir /var/lib/devbox-backup: Permission denied", which does not
# say that sudo is what is missing. Root is needed for --dry-run too: it runs
# the preflight checks in full, keyring included.
if [ "$(id -u)" -ne 0 ]; then
  suffix=""; [ "$DRY_RUN" -eq 1 ] && suffix=" --dry-run"
  die "root privileges are required. Run: sudo $0$suffix"
fi

install -d -m 700 "$STATE_DIR" "$GNUPGHOME_DIR"

# One run at a time. Two simultaneous dumps on a small machine meet the
# OOM killer; a manual run on top of the timer is the likeliest way to arrange
# that.
command -v flock >/dev/null 2>&1 || die "no 'flock' command (util-linux package)"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  die "another run is already in progress (lock $LOCK_FILE)"
fi

# --------------------------------------------------------- 2. preflight

log
log "== Checks"

for cmd in docker gpg aws gzip; do
  command -v "$cmd" >/dev/null 2>&1 || die "no '$cmd' command"
done
log "  [ok]   docker, gpg, aws, gzip are present"

docker info >/dev/null 2>&1 || die "the docker daemon is not responding"

# Stack sources are collected HERE, before any dump: an unexpanded
# substitution or a missing file must abort the run before half the copies have
# been taken, not in the middle of it.
STACK_SOURCES=()
while IFS= read -r stack; do
  [ -n "$stack" ] || continue
  while IFS= read -r src; do
    [ -n "$src" ] || continue
    STACK_SOURCES+=("$stack|$src")
  done < <(stack_backup_sources "$stack") \
    || die "could not read the backup sources of stack '$stack'"
  # stack_backup_sources has overwritten ENV_VARS — restore the machine-level
  # environment, or the next iteration and the whole rest of the script would
  # see that stack's variables.
  ENV_VARS=(); env_load_files "$ROOT_DIR/.env" "$ENV_BACKUP"
done < <(stacks_enabled)

for entry in "${STACK_SOURCES[@]}"; do
  src="${entry#*|}"
  case "${src%%:*}" in
    sqlite)
      command -v sqlite3 >/dev/null 2>&1 \
        || die "no sqlite3, but a stack declares a SQLite source — install it (sudo ./host-setup does)"
      [ -f "${src#*:}" ] \
        || die "no SQLite file '${src#*:}' — check Backup_Sqlite in the stack.conf of '${entry%%|*}'"
      ;;
    files)
      [ -e "${src#*:}" ] \
        || die "no such path '${src#*:}' — check Backup_Files in the stack.conf of '${entry%%|*}'"
      ;;
    volume)
      docker volume inspect "${src#*:}" >/dev/null 2>&1 \
        || die "no such volume '${src#*:}' — check Backup_Volume in the stack.conf of '${entry%%|*}'"
      ;;
  esac
done
if [ ${#STACK_SOURCES[@]} -gt 0 ]; then
  log "  [ok]   sources declared by stacks: ${#STACK_SOURCES[@]}"
fi

[ -f "$GPG_PUBKEY" ] || die "no public key at $GPG_PUBKEY (see the backups section of the README)"

# The import is deliberately NOT a failure point.
#
# Some distributions ship a minimal gnupg build, meant for verifying package
# signatures, with neither gpg-agent nor the compression modules. Importing a
# public key there succeeds, yet prints "error running gpg-agent" and a
# complaint about the preferred compression algorithm to stderr — while the key
# does land in the keyring and `--list-keys` returns it with exit code 0.
#
# Telling a real failure from cosmetic noise by exit code is impossible there,
# so the result is judged rather than the mechanism — the same principle the
# check-* scripts follow.
#
# Support for --trust-model is determined before the first meaningful gpg call:
# in a build without trust models that option breaks ANY command, the import
# included.
gpg_detect_trust_opt

gpg --homedir "$GNUPGHOME_DIR" --batch --quiet --import "$GPG_PUBKEY" 2>/dev/null || true

if ! gpg --homedir "$GNUPGHOME_DIR" --batch --list-keys "$GPG_RECIPIENT" >/dev/null 2>&1; then
  die "the key at $GPG_PUBKEY does not contain recipient '$GPG_RECIPIENT' — check Backup_GPG_Recipient"
fi

# And this is the real check: can this key actually encrypt? It covers a
# missing gpg-agent, a gpg build without encryption support and an algorithm
# mismatch in one go. It costs milliseconds and happens BEFORE a single dump is
# taken: finding out that there is nothing to encrypt with after an hour-long
# dump is the worst possible moment.
gpg_err=$(mktemp)
if ! printf 'canary' | gpg_encrypt > /dev/null 2>"$gpg_err"; then
  echo "Error: gpg cannot encrypt with key '$GPG_RECIPIENT'." >&2
  sed 's/^/  gpg: /' "$gpg_err" >&2
  rm -f "$gpg_err"
  echo "  The usual cause is a minimal gnupg package without gpg-agent." >&2
  echo "  Install the full gnupg build from your distribution instead." >&2
  exit 2
fi
rm -f "$gpg_err"
log "  [ok]   public key present, a test encryption for '$GPG_RECIPIENT' succeeded"

if [ -n "$DB_PROVIDER" ]; then
  db_hook check >/dev/null 2>&1 \
    || die "DB provider '$DB_PROVIDER' is not responding — there is nothing to dump from"
  log "  [ok]   DB provider '$DB_PROVIDER' is responding"
else
  log "  [ok]   no shared-DB provider — no database dumps are taken"
fi

aws_cli s3api head-bucket --bucket "$S3_BUCKET" >/dev/null 2>&1 \
  || die "bucket '$S3_BUCKET' is not reachable — check the instance's IAM role and Backup_S3_Bucket"
log "  [ok]   bucket s3://$S3_BUCKET is reachable"

install -d -m 700 "$LOCAL_DIR" "$TMP_DIR"

# The "how much will be needed" estimate comes from the previous run. On the
# first run there is none, and that is no reason to refuse: only the lower
# bound is checked.
LARGEST_KB=0
if [ -f "$SIZES_FILE" ]; then
  LARGEST_KB=$(awk '{ if ($2 > max) max = $2 } END { print int(max / 1024) }' "$SIZES_FILE")
fi
FREE_MB=$(free_mb "$LOCAL_DIR")
NEED_MB=$(( MIN_FREE_MB + LARGEST_KB / 1024 ))
if [ "$FREE_MB" -lt "$NEED_MB" ]; then
  die "not enough space: ${FREE_MB} MiB free, ${NEED_MB} MiB needed (threshold ${MIN_FREE_MB} plus room for the previous run's largest dump)"
fi
log "  [ok]   space: ${FREE_MB} MiB free against a ${NEED_MB} MiB threshold"

# Leftovers from a run killed by a power loss or a timeout. Only `.part` files
# are deleted: the presence of one means that run never reached its `mv`, so
# the dump is certainly incomplete.
find "$TMP_DIR" -maxdepth 1 -name '*.part' -type f -print -delete 2>/dev/null \
  | sed 's/^/  [!]    removed an unfinished file from a previous run: /' || true

# Files here WITHOUT .part are different: those are dumps that completed but
# never reached S3 (run_job leaves them deliberately — they are the only copy).
# They must not be deleted, but they must not be passed over in silence either:
# they accumulate and slowly eat the very disk this script is careful about.
leftovers=$(find "$TMP_DIR" -maxdepth 1 -type f ! -name '*.part' 2>/dev/null | wc -l | tr -d ' ')
if [ "${leftovers:-0}" -gt 0 ]; then
  warn "$TMP_DIR holds $leftovers dump(s) that were never uploaded"
  warn "they are left over from runs whose S3 upload failed. Upload or delete them by hand:"
  # The size is computed here rather than with `find -printf`: -printf exists in
  # GNU find and not in BSD find, where the whole call fails — the counter above
  # would say "N dumps" while the list below it came out empty.
  while IFS= read -r f; do
    printf '           %s\t%s\n' "$(wc -c < "$f" | tr -d ' ')" "$f" >&2
  done < <(find "$TMP_DIR" -maxdepth 1 -type f ! -name '*.part' 2>/dev/null)
fi

# ------------------------------------------------------------ 3. sources

log
log "== Sources"

rm -f "$SIZES_FILE.new"

# The list of databases is asked of the DBMS itself rather than taken from a
# config. A hardcoded list would mean the next database a stack creates
# silently goes unbacked — and a missing backup looks exactly like a source
# that does not exist.
DATABASES=""
DB_EXT=".dump"
if [ -n "$DB_PROVIDER" ]; then
  DATABASES=$(db_hook list | tr -d '\r' | sed '/^[[:space:]]*$/d')
  DB_EXT=$(db_hook ext 2>/dev/null || echo '.dump')

  if [ -z "$DATABASES" ]; then
    # Zero databases is not "nothing to do" but almost certainly a broken query
    # or the wrong container. A silent success here would be the worst outcome.
    die "provider '$DB_PROVIDER' returned an empty database list — that is not plausible, investigate"
  fi

  log "  databases ($DB_PROVIDER): $(echo "$DATABASES" | tr '\n' ' ')"

  # Cluster-level objects: roles, passwords, grants. Without them a restored
  # database exists but nobody can connect to it. Empty output is legitimate:
  # some engines have no such objects at all, and then the step simply does not
  # happen.
  if [ -n "$(db_hook globals 2>/dev/null | head -c 1)" ]; then
    run_job "$DB_PREFIX/_globals" "$DB_PREFIX/_globals" "$TS.sql.gpg" dump_globals || true
  fi
fi

if [ -n "$DATABASES" ]; then
  while IFS= read -r db; do
    [ -n "$db" ] || continue
    run_job "$DB_PREFIX/$db" "$DB_PREFIX/$db" "$TS$DB_EXT.gpg" dump_db "$db" || true
  done <<< "$DATABASES"
fi

# Sources declared by stacks. Collected and validated above.
for entry in "${STACK_SOURCES[@]}"; do
  stack="${entry%%|*}"; src="${entry#*|}"
  kind="${src%%:*}"; val="${src#*:}"
  case "$kind" in
    db)       run_job "$DB_PREFIX/$val" "$DB_PREFIX/$val" "$TS$DB_EXT.gpg" dump_db "$val" || true ;;
    sqlite)   sub=$(sqlite_s3_subpath "$val")
              run_job "$sub" "$sub" "$TS.db.gz.gpg" dump_sqlite "$val" || true ;;
    files)    run_job "files/$stack" "files/$stack" "$TS.tar.gz.gpg" dump_files "$val" || true ;;
    volume)   run_job "volume/$val" "volume/$val" "$TS.tar.gz.gpg" dump_volume "$val" || true ;;
  esac
done

# --------------------------------------------------------------- 4. summary

if [ "$DRY_RUN" -eq 1 ]; then
  log
  log "Dry run complete, nothing was changed."
  exit 0
fi

[ -f "$SIZES_FILE.new" ] && mv "$SIZES_FILE.new" "$SIZES_FILE"

log
if [ ${#FAILED[@]} -gt 0 ]; then
  echo "Failed sources: ${#FAILED[@]} — ${FAILED[*]}" >&2
  echo "Investigate with: journalctl -u devbox-backup -n 100" >&2
  exit 1
fi

log "Done. Run timestamp: $TS"
log "Verify independently with: ./platform/bin/check-backups.sh"
