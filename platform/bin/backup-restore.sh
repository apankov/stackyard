#!/usr/bin/env bash

# Restoring from a backup.
#
# AN IMPORTANT CONSEQUENCE OF ENCRYPTION, better learned on a calm day than
# during an incident: a backup CANNOT be decrypted ON THIS MACHINE. The private
# GPG key is not here and must not be — otherwise the encryption would not
# protect against the very scenario it exists for. So a restore takes two
# steps:
#
#   1. On a machine that holds the private key (a laptop):
#        aws s3 cp s3://<bucket>/<prefix>/<provider>/<db>/<TS>.dump.gpg - \
#          | gpg --decrypt > <db>.dump
#        scp <db>.dump user@machine:/tmp/
#
#   2. Here — this script, which accepts an ALREADY DECRYPTED file:
#        ./platform/bin/backup-restore.sh --check /tmp/<db>.dump
#        ./platform/bin/backup-restore.sh --apply /tmp/<db>.dump --into <db> --yes
#
# The order for a full restore: cluster-level objects (roles and passwords)
# first, then the databases. The other way round, the restore fails on a role
# that does not exist.

set -euo pipefail

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

# shellcheck source=platform/lib/lib-env.sh
. "$LIB_DIR/lib-env.sh"
# lib-stacks is needed from the very start: the DB provider is asked for while
# the config is still being parsed.
# shellcheck source=platform/lib/lib-stacks.sh
. "$LIB_DIR/lib-stacks.sh"

MODE=""
FILE=""
TARGET=""
CLEAN=0
ASSUME_YES=0

usage() {
  cat <<'EOF'
Usage:
  ./platform/bin/backup-restore.sh --list [<subpath>]
        show what is in S3. With no argument, the top-level sources;
        for example: --list mysql/orders

  ./platform/bin/backup-restore.sh --check <file>
        recognise a decrypted dump and show what is inside it.
        Changes nothing.

  ./platform/bin/backup-restore.sh --apply <file> --into <target> [--clean] [--yes]
        restore. <target> is a database name or the path to a SQLite file.
        --clean   drop existing objects before restoring. WITHOUT it, a
                  restore into a non-empty database runs into name conflicts.
        --yes     do not ask for confirmation (for non-interactive runs)

This script deliberately does not accept .gpg files — see the header comment.
EOF
}

[ $# -gt 0 ] || { usage >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --list)  MODE=list;  shift; TARGET="${1-}"; [ $# -gt 0 ] && shift ;;
    --check) MODE=check; shift; FILE="${1-}"; shift || true ;;
    --apply) MODE=apply; shift; FILE="${1-}"; shift || true ;;
    --into)  shift; TARGET="${1-}"; shift || true ;;
    --clean) CLEAN=1; shift ;;
    --yes)   ASSUME_YES=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

die() { echo "Error: $*" >&2; exit 2; }

ENV_BACKUP="$ROOT_DIR/.env-backup"
[ -f "$ENV_BACKUP" ] || die "no $ENV_BACKUP"
env_load_files "$ROOT_DIR/.env" "$ENV_BACKUP"

S3_BUCKET=$(env_get Backup_S3_Bucket)
S3_PREFIX=$(backup_s3_prefix)
AWS_REGION=$(env_get Backup_AWS_Region us-east-1)
AWS_KEY=$(env_get Backup_AWS_Access_Key_Id)
AWS_SECRET=$(env_get Backup_AWS_Secret_Access_Key)
DB_PROVIDER="$(stacks_db_provider)"

# Restoring into the DBMS is the provider's job: the restore command is engine
# knowledge, exactly like the dump command. The platform handles S3, GPG, file
# recognition and confirmations; what to do with the contents is the stack's
# business.
db_hook() {
  [ -n "$DB_PROVIDER" ] || die "no shared-DB provider is enabled — there is nowhere to restore to"
  local h; h="$(stack_dir "$DB_PROVIDER")/scripts/backup-dump.sh"
  [ -x "$h" ] || die "provider '$DB_PROVIDER' has no scripts/backup-dump.sh"
  ROOT_DIR="$ROOT_DIR" STACK_DIR="$(stack_dir "$DB_PROVIDER")" "$h" "$@"
}

aws_cli() {
  if [ -n "$AWS_KEY" ]; then
    AWS_ACCESS_KEY_ID="$AWS_KEY" AWS_SECRET_ACCESS_KEY="$AWS_SECRET" \
      aws --region "$AWS_REGION" "$@"
  else
    aws --region "$AWS_REGION" "$@"
  fi
}

# ------------------------------------------------------------------- listing

if [ "$MODE" = list ]; then
  [ -n "$S3_BUCKET" ] || die "Backup_S3_Bucket is not set"
  path="s3://$S3_BUCKET/$S3_PREFIX/${TARGET:+$TARGET/}"
  echo "== $path"
  aws_cli s3 ls "$path" --recursive --human-readable 2>/dev/null \
    | tail -50 \
    || die "could not read $path"
  echo
  echo "To decrypt (on the machine that holds the private key):"
  echo "  aws s3 cp s3://$S3_BUCKET/<key> - | gpg --decrypt > dump"
  exit 0
fi

# ------------------------------------------------------- recognising the file

[ -n "$FILE" ] || die "no file given"

# The .gpg test comes BEFORE the existence test. A file that does not exist is
# most often exactly this case: someone named an S3 key expecting the script to
# download and decrypt it. The message about the two steps is more useful than
# "no such file".
case "$FILE" in
  *.gpg)
    echo "Error: '$FILE' is encrypted, and the private key is not on this machine and must not be." >&2
    echo >&2
    echo "Decrypt it where the key is and bring the result here:" >&2
    echo "  gpg --decrypt '$(basename "$FILE")' > dump     # on your laptop" >&2
    echo "  scp dump user@machine:/tmp/" >&2
    exit 2
    ;;
esac

[ -f "$FILE" ] || die "no such file '$FILE'"

# The format is recognised by CONTENT, not by name: anyone could have renamed
# the file, and confusing formats during a restore means applying a SQLite
# database over a relational one or the other way round.
#
# The recognition itself lives in lib-env.sh (backup_file_kind): it looks
# INSIDE the gzip rather than at the wrapper. What remains here is the one
# thing the library must not know — asking the provider about its own
# formats.
KIND="$(backup_file_kind "$FILE")"
[ "$KIND" = unknown ] && KIND="db:$(db_hook detect "$FILE" 2>/dev/null || echo unknown)"

human_kind() {
  case "$KIND" in
    db:*)         echo "a dump from DBMS '$DB_PROVIDER', format: ${KIND#db:}" ;;
    sqlite_gz)    echo "a SQLite database, gzip-compressed" ;;
    sqlite_plain) echo "a SQLite database" ;;
    tar_gz)       echo "an archive of a directory or volume (tar.gz)" ;;
    db:unknown)   echo "the format was recognised neither by the platform nor by the provider" ;;
  esac
}

# ------------------------------------------------------------------ check

if [ "$MODE" = check ]; then
  bytes=$(stat -c %s "$FILE" 2>/dev/null || stat -f %z "$FILE")
  echo "File: $FILE"
  echo "Size: $bytes B ($((bytes / 1024)) KiB)"
  echo "Type: $(human_kind)"
  echo

  case "$KIND" in
    tar_gz)
      echo "== The first 20 entries of the archive"
      tar -tzf "$FILE" | head -20
      ;;
    db:*)
      # Only the engine itself can show what is inside a dump. The hook prints
      # that; all the platform needs to know is that a preview is not always
      # available.
      db_hook inspect "${KIND#db:}" "$FILE" 2>/dev/null \
        || echo "  (provider '$DB_PROVIDER' cannot display the contents of this dump)"
      ;;
    sqlite_gz|sqlite_plain)
      tmp=$(mktemp)
      trap 'rm -f "$tmp"' EXIT
      if [ "$KIND" = sqlite_gz ]; then gunzip -c "$FILE" > "$tmp"; else cp "$FILE" "$tmp"; fi
      echo "== integrity_check"
      sqlite3 "$tmp" 'PRAGMA integrity_check;'
      echo
      echo "== Tables and row counts"
      while IFS= read -r t; do
        printf '  %-34s %s\n' "$t" "$(sqlite3 "$tmp" "SELECT count(*) FROM \"$t\";")"
      done < <(sqlite3 "$tmp" "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name;")
      ;;
  esac
  echo
  echo "Check complete, nothing was changed."
  exit 0
fi

# --------------------------------------------------------------- applying

[ "$MODE" = apply ] || die "no mode given (--list / --check / --apply)"
[ -n "$TARGET" ] || die "no target given: --into <database or path>"

echo "File:   $FILE"
echo "Type:   $(human_kind)"
echo "Target: $TARGET"
[ "$CLEAN" -eq 1 ] && echo "Mode:   --clean — existing objects will be DROPPED"
echo

if [ "$ASSUME_YES" -ne 1 ]; then
  printf 'Restoring will change data. Continue? [type: yes] '
  read -r answer
  [ "$answer" = "yes" ] || { echo "Cancelled."; exit 1; }
fi

case "$KIND" in
  db:unknown)
    die "the file format was not recognised. Check that the file is decrypted (.gpg is not accepted here) and not truncated"
    ;;

  tar_gz)
    # NOT unpacked automatically. files: and volume: sources are directories
    # something may be writing to right now: unpacking over a live writer gives
    # a mixture of old and new, silently. The platform does not know who the
    # writer is: a volume can be mounted into any container of any stack.
    #
    # So the ready-made command is printed and the script stops. This is the
    # only place where it refuses to finish the job, and the refusal is
    # deliberate.
    echo "This is an archive of a directory or volume. Not unpacking it automatically."
    echo
    echo "  1. stop whatever writes to '$TARGET' (./stack disable <stack> or ./dc stop <service>)"
    echo "  2. tar -xzf $FILE -C $(dirname "$TARGET")"
    echo "  3. bring it back up"
    echo
    echo "Contents: ./platform/bin/backup-restore.sh --check $FILE"
    exit 1
    ;;

  db:*)
    # Everything DBMS-related is done by its provider: whether the database
    # exists, what loads a dump, whether --clean is needed. The platform stays
    # out of it — otherwise this script would have to be forked per engine.
    db_hook restore "${KIND#db:}" "$TARGET" "$FILE" "$CLEAN"
    echo "Done: '$TARGET' has been restored."
    ;;

  sqlite_gz|sqlite_plain)
    # Writing into a database under a running application is not allowed: it
    # holds the file open and will write its own pages over yours. Stopping is
    # a deliberate, manual step.
    #
    # The owner is found from declarations rather than a list of container
    # names: a hardcoded list goes stale silently when a service is renamed —
    # and then the check waves through a restore over a live writer, which is
    # exactly the failure it guards against.
        owner=""
    while IFS= read -r st; do
      [ -n "$st" ] || continue
      while IFS= read -r src; do
        [ "$src" = "sqlite:$TARGET" ] && owner="$st"
      done < <(stack_backup_sources "$st" 2>/dev/null)
      ENV_VARS=(); env_load_files "$ROOT_DIR/.env" "$ENV_BACKUP"
    done < <(stacks_enabled 2>/dev/null)

    if [ -z "$owner" ]; then
      echo "Warning: no enabled stack declares '$TARGET' as Backup_Sqlite." >&2
      echo "  You will have to make sure nobody holds the database open yourself." >&2
    else
      while IFS= read -r svc; do
        [ -n "$svc" ] || continue
        while IFS= read -r cid; do
          [ -n "$cid" ] || continue
          [ "$(docker inspect -f '{{.State.Status}}' "$cid" 2>/dev/null)" = running ] || continue
          die "container '$(docker inspect -f '{{.Name}}' "$cid" | sed 's|^/||')' of stack '$owner' is running.
  Stop the stack and try again:  ./stack disable $owner"
        done < <(service_containers "$svc")
      done < <(stack_services "$owner" 2>/dev/null)
    fi
    if [ -f "$TARGET" ]; then
      backup_of_current="$TARGET.before-restore.$(date -u +%Y%m%dT%H%M%SZ)"
      cp "$TARGET" "$backup_of_current"
      echo "The previous database was saved as: $backup_of_current"
    fi
    if [ "$KIND" = sqlite_gz ]; then gunzip -c "$FILE" > "$TARGET"; else cp "$FILE" "$TARGET"; fi
    sqlite3 "$TARGET" 'PRAGMA integrity_check;'
    echo "Done: '$TARGET' has been restored. Bring the stack back up: ./stack enable ${owner:-<stack>}"
    ;;
esac
