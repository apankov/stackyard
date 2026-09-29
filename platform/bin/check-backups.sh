#!/usr/bin/env bash

# Checking that backups actually exist.
#
# This exists for the same reason as check-certs.sh: a script that did its work
# and a script that decided there were zero sources and honestly exited 0 look
# identical. So the expected list of sources is rebuilt HERE — from the DBMS
# itself — and the result is asked of S3 rather than of backup.sh.
#
# Exit codes (as in check-certs.sh):
#   0 — every source is fresh and non-empty
#   1 — some are not: stale, empty or missing
#   2 — the check could not be performed (no config, S3 or the DBMS unreachable)
#
# A non-zero code puts the unit into the failed state, so it is visible in
# `systemctl --failed` rather than sinking into the journal.

set -uo pipefail

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

ENV_BACKUP="$ROOT_DIR/.env-backup"
[ -f "$ENV_BACKUP" ] || { echo "Error: no $ENV_BACKUP" >&2; exit 2; }

env_load_files "$ROOT_DIR/.env" "$ENV_BACKUP"

S3_BUCKET=$(env_get Backup_S3_Bucket)
[ -n "$S3_BUCKET" ] || { echo "Error: Backup_S3_Bucket is not set" >&2; exit 2; }
S3_PREFIX=$(backup_s3_prefix)
AWS_REGION=$(env_get Backup_AWS_Region us-east-1)
AWS_KEY=$(env_get Backup_AWS_Access_Key_Id)
AWS_SECRET=$(env_get Backup_AWS_Secret_Access_Key)
DB_PREFIX=$(backup_db_prefix)
MAX_AGE_HOURS=$(env_get Backup_Max_Age_Hours 26)
MIN_OBJ_BYTES=$(env_get Backup_Min_Object_Bytes 1024)
MIN_GLOBALS_BYTES=$(backup_min_globals_bytes)

aws_cli() {
  if [ -n "$AWS_KEY" ]; then
    AWS_ACCESS_KEY_ID="$AWS_KEY" AWS_SECRET_ACCESS_KEY="$AWS_SECRET" \
      aws --region "$AWS_REGION" "$@"
  else
    aws --region "$AWS_REGION" "$@"
  fi
}

command -v aws >/dev/null 2>&1 || { echo "Error: no 'aws' command" >&2; exit 2; }
aws_cli s3api head-bucket --bucket "$S3_BUCKET" >/dev/null 2>&1 \
  || { echo "Error: bucket '$S3_BUCKET' is not reachable" >&2; exit 2; }

# ---------------------------------------------- the expected source list

EXPECTED=()
DEGRADED=0
problems=0

# The database list is rebuilt from the DBMS itself rather than taken from
# backup.sh: a check that asks the thing being checked only confirms its own
# opinion. It is asked through the provider's hook — the platform knows nothing
# about any particular dump command.
DB_PROVIDER="$(stacks_db_provider)"
databases=""
if [ -n "$DB_PROVIDER" ]; then
  hook="$(stack_dir "$DB_PROVIDER")/scripts/backup-dump.sh"
  if [ -x "$hook" ]; then
    databases=$(ROOT_DIR="$ROOT_DIR" STACK_DIR="$(stack_dir "$DB_PROVIDER")" "$hook" list 2>/dev/null \
                | tr -d '\r' | sed '/^[[:space:]]*$/d')
    # A failed hook is not "no cluster objects": backup.sh fails that source
    # too, and here it would otherwise quietly drop out of the expected list.
    if globals=$(ROOT_DIR="$ROOT_DIR" STACK_DIR="$(stack_dir "$DB_PROVIDER")" "$hook" globals 2>/dev/null); then
      [ -n "$globals" ] && EXPECTED+=("$DB_PREFIX/_globals")
    else
      printf '%-34s ERROR: the provider could not list roles and grants\n' "$DB_PREFIX/_globals"
      problems=$((problems + 1))
    fi
  fi

  if [ -z "$databases" ]; then
    # If the list cannot be built, nobody can claim every database is covered.
    # The freshness of what does exist is still checked — that is more useful
    # than silence. But the final exit code will be 2, because "could not
    # verify" is not the same as "all is well".
    echo "NOTE: could not obtain the database list from provider '$DB_PROVIDER' — completeness was not verified." >&2
    DEGRADED=1
    while IFS= read -r p; do
      [ -n "$p" ] && EXPECTED+=("$DB_PREFIX/$p")
    done < <(aws_cli s3 ls "s3://$S3_BUCKET/$S3_PREFIX/$DB_PREFIX/" 2>/dev/null \
             | awk '$1 == "PRE" { sub(/\/$/, "", $2); print $2 }' | grep -v '^_globals$')
  else
    while IFS= read -r db; do
      [ -n "$db" ] && EXPECTED+=("$DB_PREFIX/$db")
    done <<< "$databases"
  fi
fi

# The expected set is built from THE SAME declarations backup.sh builds the
# actual one from, using the same prefix formula out of the shared lib-env.sh.
# Two copies of one formula drift easily, and the symptom is "no backups at
# all" while backups are healthy.
#
# From backup_sources_enabled, the list backup.sh works from too. A stack whose
# sources cannot be read is a problem, not a stack with fewer sources: that is
# how a failure here used to look.
#
# db: is what backup.sh stores under the provider's prefix, the same path as a
# database the provider lists — expected once, whichever way it is declared.
src_err="$(mktemp)"
if ! all_sources="$(backup_sources_enabled 2>"$src_err")"; then
  # One problem per stack that could not be read; the lines before its verdict
  # say why, and are shown as they are.
  while IFS= read -r line; do
    case "$line" in
      "Error: could not read the backup sources of stack "*)
        printf '%-34s ERROR: %s\n' "sources" "${line#Error: }"
        problems=$((problems + 1)) ;;
      *) printf '%-34s   %s\n' "" "$line" ;;
    esac
  done < "$src_err"
fi
rm -f "$src_err"
while IFS= read -r entry; do
  [ -n "$entry" ] || continue
  stack="${entry%%|*}"; src="${entry#*|}"
  case "${src%%:*}" in
    db)     case " ${EXPECTED[*]+${EXPECTED[*]}} " in
              *" $DB_PREFIX/${src#*:} "*) ;;
              *) EXPECTED+=("$DB_PREFIX/${src#*:}") ;;
            esac ;;
    sqlite) EXPECTED+=("$(sqlite_s3_subpath "${src#*:}")") ;;
    files)  EXPECTED+=("files/$stack") ;;
    volume) EXPECTED+=("volume/${src#*:}") ;;
  esac
done <<< "$all_sources"

# Nothing expected is not "everything is fresh". A machine with backups
# configured and not one source to check is either misconfigured or checked by
# the wrong code; either way it is not a green result.
if [ ${#EXPECTED[@]} -eq 0 ] && [ "$problems" -eq 0 ]; then
  echo "Error: not one backup source is expected on this machine — nothing was verified." >&2
  echo "  Either the machine needs no backups (remove .env-backup), or the sources are not declared." >&2
  exit 2
fi

# --------------------------------------------------------------- the check

now=$(date -u +%s)

# ${…+…}: under set -u, bash before 4.4 calls an empty array unbound.
for src in ${EXPECTED[@]+"${EXPECTED[@]}"}; do
  newest=$(aws_cli s3api list-objects-v2 \
             --bucket "$S3_BUCKET" --prefix "$S3_PREFIX/$src/" \
             --query 'sort_by(Contents, &LastModified)[-1].[Size,LastModified]' \
             --output text 2>/dev/null)

  if [ -z "$newest" ] || [ "$newest" = "None" ] || [ "$newest" = "None	None" ]; then
    printf '%-34s NO BACKUP AT ALL\n' "$src"
    problems=$((problems + 1))
    continue
  fi

  size=$(printf '%s' "$newest" | awk '{print $1}')
  modified=$(printf '%s' "$newest" | awk '{print $2}')

  if ! ts=$(iso_to_epoch "$modified"); then
    printf '%-34s ERROR: could not parse the date "%s"\n' "$src" "$modified"
    problems=$((problems + 1))
    continue
  fi

  age_h=$(( (now - ts) / 3600 ))

  # The same two floors as in backup.sh, for the same reason: one threshold
  # for a database dump and for a list of grants makes the second one red
  # forever.
  floor="$MIN_OBJ_BYTES"
  case "$src" in *_globals) floor="$MIN_GLOBALS_BYTES" ;; esac
  if [ "$size" -lt "$floor" ]; then
    # A truncated dump is almost always tiny. Without this check "a file
    # exists" is indistinguishable from "a backup exists".
    printf '%-34s EMPTY: %s B against a %s B threshold\n' "$src" "$size" "$floor"
    problems=$((problems + 1))
  elif [ "$age_h" -ge "$MAX_AGE_HOURS" ]; then
    printf '%-34s STALE: %sh old (threshold %sh)\n' "$src" "$age_h" "$MAX_AGE_HOURS"
    problems=$((problems + 1))
  else
    printf '%-34s ok, %sh old, %s KiB\n' "$src" "$age_h" "$((size / 1024))"
  fi
done

echo
if [ "$problems" -gt 0 ]; then
  echo "Problem sources: $problems of ${#EXPECTED[@]}." >&2
  echo "Investigate with: journalctl -u devbox-backup --since '-3 days'" >&2
  exit 1
fi

if [ "$DEGRADED" -eq 1 ]; then
  echo "Every source found is fresh, but the database list was not verified — see the note above." >&2
  exit 2
fi

echo "Sources checked: ${#EXPECTED[@]}. All fresher than ${MAX_AGE_HOURS}h and non-empty."
