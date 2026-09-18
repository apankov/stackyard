#!/usr/bin/env bash
#
# Auditing isolation between machines. It runs in the WORKSPACE, not on a
# machine, and that is not a detail: a machine by definition cannot see its
# neighbours, and a bucket shared by everyone looks to it exactly like a
# correctly configured one of its own.
#
# What it looks for is values shared by two or more machines. Each of them
# means client isolation exists only on paper:
#
#   * one ACME account key    -> shared Let's Encrypt rate limits and shared
#                                authority to revoke someone else's certificates
#   * one backup bucket/prefix -> client A's dumps where client B collects theirs
#   * one GPG recipient        -> and decrypts them there too
#   * one notification chat    -> every client's incidents in one reader's feed
#   * one docker network or one
#     deployment directory     -> almost certainly a copy-pasted .env, dragging
#                                everything else along with it
#
#   ./bin/audit-isolation.sh          # a report, non-zero exit on findings
#
# Changes nothing.

set -uo pipefail

ROOT="$( cd -P "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"

# Needed for sha256_file: a bare `shasum` may not be available.
# shellcheck source=platform/lib/lib-env.sh
. "$ROOT/platform/lib/lib-env.sh"
PROBLEMS=0
WARNINGS=0

ok()   { printf '  [ok]   %s\n' "$1"; }
warn() { printf '  [!]    %s\n' "$1"; WARNINGS=$((WARNINGS + 1)); }
bad()  { printf '  [FAIL] %s\n' "$1"; PROBLEMS=$((PROBLEMS + 1)); }
step() { printf '\n== %s\n' "$1"; }

# Machines live OUTSIDE this repository: stackyard is public, and a client's
# domains and stack list in a public repository would be exactly the leak this
# whole design exists to prevent. So the paths come from outside.
#
#   ./bin/audit-isolation.sh ~/dev/machines/*
#   ./bin/audit-isolation.sh            # from ~/.stackyard-fleet, one path per line
paths=("$@")
if [ ${#paths[@]} -eq 0 ]; then
  list="${HOME}/.stackyard-fleet"
  [ -f "$list" ] || { echo "Give the paths to the machines, or create $list" >&2; exit 2; }
  while IFS= read -r l; do
    case "$l" in ''|\#*) continue ;; esac
    paths+=("${l/#\~/$HOME}")
  done < "$list"
fi

machines=(); declare -A MDIR=()
for p in "${paths[@]}"; do
  [ -d "$p" ] || { echo "Warning: no directory $p — skipping" >&2; continue; }
  n="$(basename "$p")"; machines+=("$n"); MDIR[$n]="$p"
done
[ ${#machines[@]} -gt 0 ] || { echo "No machines found"; exit 0; }

# --------------------------------------------- 1. no secrets in the platform

step "Secrets in the shared layers"

# The platform and the profile travel to EVERY machine. A secret in them is a
# secret copied to every client, and nothing can detect that after the fact.
found=0
while IFS= read -r f; do
  case "$f" in *.example) continue ;; esac
  bad "secret in a shared layer: ${f#"$ROOT"/}"
  found=1
done < <(find "$ROOT/platform" "$ROOT/profiles" \
              \( -name '.env' -o -name '*.key' -o -name '*.pem' -o -name 'account.key' \
                 -o -name 'databases.yaml' -o -name '*.asc' \) 2>/dev/null)
[ "$found" -eq 0 ] && ok "no secrets in platform/ or profiles/"

# ------------------------------------- 2. values shared between machines

step "Values shared by several machines"

# Keys whose coincidence across any two machines is a failure rather than a
# coincidence.
#
# Backup_S3_Bucket is deliberately NOT here: one bucket for several machines is
# a legitimate and common configuration. What separates them is
# Backup_S3_Prefix, and that one must not match: the same prefix in one bucket
# means the machines write over each other while check-backups stays green on
# both.
#
# The list is by name rather than "anything that looks like a secret": some
# values are REQUIRED to match (a path inside a container, say), and flagging
# those would teach people to skim the report.
MUST_DIFFER="Platform_Network Platform_Deploy_Dir
Backup_S3_Prefix Backup_GPG_Recipient
Backup_AWS_Access_Key_Id Backup_AWS_Secret_Access_Key
Notify_Telegram_Token Notify_Telegram_Chat_Id"

# Collect "key<TAB>value<TAB>machine" across every env file of every machine.
pairs=$(
  for m in "${machines[@]}"; do
    for f in "${MDIR[$m]}"/.env "${MDIR[$m]}"/.env-backup \
             "${MDIR[$m]}"/.env-notify "${MDIR[$m]}"/stacks/*/.env; do
      [ -f "$f" ] || continue
      # Line by line, without source: a value containing spaces or backticks
      # would otherwise become executable code.
      while IFS= read -r line; do
        case "$line" in \#*|'') continue ;; esac
        case "$line" in *=*) ;; *) continue ;; esac
        key="${line%%=*}"; val="${line#*=}"
        val="${val%\"}"; val="${val#\"}"; val="${val%\'}"; val="${val#\'}"
        [ -n "$val" ] || continue
        printf '%s\t%s\t%s\n' "$key" "$val" "$m"
      done < "$f"
    done
  done
)

shared=0
for key in $MUST_DIFFER; do
  # `$2 != prevm` is not a quibble: the same key of one machine lives in two
  # files at once (a root password in .env and in that stack's .env), and
  # without this condition the audit reports "the key is identical on machines
  # X and X". A false alarm in an isolation check is worse than no check: people
  # learn not to read it.
  dupes=$(printf '%s\n' "$pairs" | awk -F'\t' -v k="$key" '$1 == k { print $2 "\t" $3 }' \
          | sort | awk -F'\t' '{ if ($1 == prev && $2 != prevm) print prev "\t" prevm "\t" $2; prev = $1; prevm = $2 }')
  [ -n "$dupes" ] || continue
  while IFS=$'\t' read -r val m1 m2; do
    bad "$key is identical on machines $m1 and $m2 (value: ${val:0:24}...)"
    shared=1
  done <<< "$dupes"
done

# Any password or token shared by two machines BY VALUE.
#
# Values are compared, not key-value pairs. A root password under one key on
# one machine and under a different key on another are different keys, but if
# the string is the same then the secret is the same: leak it from either and
# it opens both. Comparing pairs misses this case, and misses it silently.
dupes=$(printf '%s\n' "$pairs" \
  | awk -F'\t' 'tolower($1) ~ /password|secret|token|_key$/ { print $2 "\t" $1 "\t" $3 }' \
  | sort -u | sort -t$'\t' -k1,1 \
  | awk -F'\t' '{ if ($1 == pv && $3 != pm) print $2 "\t" pm "\t" $3; pv = $1; pm = $3 }')
if [ -n "$dupes" ]; then
  while IFS=$'\t' read -r key m1 m2; do
    bad "a secret is reused by machines $m1 and $m2 (under a key such as $key)"
    shared=1
  done <<< "$dupes"
fi
[ "$shared" -eq 0 ] && ok "no shared values found"

# ------------------------------------------- 3. ACME account keys

step "ACME account keys"

# Compared by CONTENT: the path is unique per machine by construction, whereas
# a copied file looks perfectly well configured.
sums=""
for m in "${machines[@]}"; do
  k="${MDIR[$m]}/state/getssl-config/account.key"
  if [ ! -f "$k" ]; then
    warn "$m: no ACME account key yet (getssl will create one on first issue)"
    continue
  fi
  sums="$sums$(sha256_file "$k")	$m"$'\n'
done
dupes=$(printf '%s' "$sums" | sort | awk -F'\t' '{ if ($1 == prev && $2 != prevm) print prevm "\t" $2; prev = $1; prevm = $2 }')
if [ -n "$dupes" ]; then
  while IFS=$'\t' read -r m1 m2; do
    bad "machines $m1 and $m2 share ONE ACME account key — shared limits and shared revocation"
  done <<< "$dupes"
elif [ -n "$sums" ]; then
  ok "every machine has its own key"
fi

# ------------------------------------------------------------------ summary

echo
if [ "$PROBLEMS" -gt 0 ]; then
  echo "Isolation is broken: problems — $PROBLEMS, warnings — $WARNINGS."
  exit 1
fi
echo "Isolation is intact. Warnings: $WARNINGS."
