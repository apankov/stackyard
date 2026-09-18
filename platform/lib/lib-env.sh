# shellcheck shell=bash
# Reading the machine's .env files. Sourced, never run on its own.
#
# Why a shared file: a dozen scripts read .env, and a `grep | cut | tr -d`
# one-liner in each of them parses it slightly differently. All env reading
# goes through here.
#
# What this loader does NOT do: execute the file. `source .env` looks simpler,
# but a value such as `Pass=a b c`, or a backtick inside a password, becomes
# executable code. Parsing here is line by line.
#
# What it adds over a one-liner is expanding `${OTHER_VARIABLE}`, the way
# docker compose does. Without that, `Db_Dir=${Home_Dir}/db` is read
# literally, braces and all, and the resulting path does not exist.

# `declare -gA` requires bash >= 4.2. The stock /bin/bash on macOS is 3.2, and
# there the line below fails with `declare: -g: invalid option`; the sourcing
# script then continues with an empty ENV_VARS, every env_get returns its
# default, and the script quietly does something other than what was asked.
# The easiest way to land on 3.2 is sudo: it sanitises PATH, so `/usr/bin/env
# bash` finds the system one rather than the bash used to launch the script.
if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ] ||
   { [ "${BASH_VERSINFO[0]:-0}" -eq 4 ] && [ "${BASH_VERSINFO[1]:-0}" -lt 2 ]; }; then
  echo "Error: bash >= 4.2 required, running ${BASH_VERSION:-not bash}." >&2
  echo "       On macOS /bin/bash is 3.2; install a current bash and invoke" >&2
  echo "       the script with it explicitly (sudo sanitises PATH, so use" >&2
  echo "       sudo \"\$(command -v bash)\" <script>)." >&2
  exit 1
fi

declare -gA ENV_VARS=()

# env_load_files <file> [<file>...]
# Loads files in order; a later file overrides an earlier one.
# A missing file is skipped silently — the caller decides whether it is required.
env_load_files() {
  local file line key val
  for file in "$@"; do
    [ -f "$file" ] || continue
    while IFS= read -r line || [ -n "$line" ]; do
      line="${line%$'\r'}"                       # CRLF, if the file was edited on Windows
      [[ "$line" =~ ^[[:space:]]*# ]] && continue
      [[ "$line" =~ ^[[:space:]]*$ ]] && continue
      [[ "$line" == *=* ]] || continue
      key="${line%%=*}"
      key="${key#"${key%%[![:space:]]*}"}"       # trim leading whitespace
      key="${key%"${key##*[![:space:]]}"}"       # and trailing
      [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
      val="${line#*=}"
      # Quotes around a value are stripped: docker compose does not keep them either.
      if [[ "$val" == \"*\" && ${#val} -ge 2 ]]; then val="${val:1:${#val}-2}"
      elif [[ "$val" == \'*\' && ${#val} -ge 2 ]]; then val="${val:1:${#val}-2}"
      fi
      ENV_VARS["$key"]="$val"
    done < "$file"
  done
  env_expand
}

# Expands ${VAR} inside values. Iteratively, because a reference may point at a
# value that itself contains a reference. The ceiling of 10 passes guards
# against `A=${A}`: such a file must not hang the backup script forever.
env_expand() {
  local pass key val ref sub changed
  for (( pass = 0; pass < 10; pass++ )); do
    changed=0
    for key in "${!ENV_VARS[@]}"; do
      val="${ENV_VARS[$key]}"
      while [[ "$val" =~ \$\{([A-Za-z_][A-Za-z0-9_]*)\} ]]; do
        ref="${BASH_REMATCH[1]}"
        sub="${ENV_VARS[$ref]-}"
        # A self-reference never resolves — stop and leave it as written.
        [ "$ref" = "$key" ] && break
        [[ "$sub" == *"\${$ref}"* ]] && break
        val="${val//\$\{$ref\}/$sub}"
        changed=1
      done
      ENV_VARS["$key"]="$val"
    done
    [ "$changed" -eq 0 ] && break
  done
}

# env_get <key> [<default>]
env_get() {
  local key="$1" default="${2-}"
  local val="${ENV_VARS[$key]-}"
  if [ -z "$val" ]; then printf '%s' "$default"; else printf '%s' "$val"; fi
}

# env_require <key> <human-readable hint>
# An empty value counts as absent: a key present but blank is a half-filled
# config, not a deliberate default.
env_require() {
  local key="$1" hint="${2-}"
  local val="${ENV_VARS[$key]-}"
  if [ -z "$val" ]; then
    echo "Error: $key is not set in .env-backup${hint:+ — $hint}" >&2
    return 1
  fi
  printf '%s' "$val"
}

# ---------------------------------------------------------------------------
# Derived values computed by SEVERAL scripts.
#
# They live here rather than as a copy in each one because two copies of one
# formula drift apart quietly: backup.sh would store an object under one path
# while check-backups.sh looks under another, and the check would report "no
# backups at all" while backups are being taken correctly. Both sides look
# healthy in isolation.

# Whether every ${...} in a key's raw value is defined. Prints the missing ones
# to stderr.
#
# A separate function because the raw value has to be read from stack.conf
# bypassing env_get: env_get returns the already-expanded value, where an unset
# variable is indistinguishable from one set to the empty string.
_env_check_refs() {
  local key="$1" s="$2" raw ref missing=""
  raw=$(grep -E "^[[:space:]]*${key}=" "$(stack_conf_file "$s")" 2>/dev/null \
        | tail -n 1 | cut -d '=' -f2- | tr -d '"'"'" || true)
  [ -n "$raw" ] || return 0
  while [[ "$raw" =~ \$\{([A-Za-z_][A-Za-z0-9_]*)\} ]]; do
    ref="${BASH_REMATCH[1]}"
    [ -n "${ENV_VARS[$ref]-}" ] || missing="$missing $ref"
    raw="${raw//\$\{$ref\}/}"
  done
  [ -z "$missing" ] && return 0
  echo "Error: $key of stack '$s' references undefined variables:$missing" >&2
  echo "  Define them in stacks/$s/.env (see .env.example next to it)." >&2
  return 1
}

# --------------------------------------------- databases at the provider stack

# A YAML single-quoted string. Inside single quotes there are no escapes at
# all, except the single quote itself, which is doubled.
#
# This matters because PASSWORDS go through here: a password truncated at a
# quote would produce a user the application cannot authenticate as — exactly
# the failure this generator exists to prevent.
_yaml_sq() { printf "'%s'" "${1//\'/\'\'}"; }

# The keys the engine collects from consumers and hands to the provider.
#
# DB, User and Password are required — without them ordering a database is
# meaningless. The rest are optional, and their meaning is the provider's
# business: Grants is understood by the mysql stack, Dump by both mysql and pg.
# The engine does not interpret them and does not validate them: a list of
# valid MySQL privileges inside the platform would mean the platform knows
# about MySQL, which is precisely what this design avoids. The provider
# validates its own keys, in scripts/check-decl.sh.
DB_KEYS_REQUIRED="DB User Password"
DB_KEYS_OPTIONAL="Grants Dump"

# stacks_databases_content
#
# The contents of databases.yaml: databases and users ordered by the ENABLED
# stacks from the enabled provider.
#
# Why enabled stacks rather than all of them, unlike the static generator. The
# difference is in the nature of the file: nginx-static.generated.yaml is part
# of the container SPEC, and changing it recreates nginx, so it must not depend
# on which stacks are enabled. This file is a bind mount; its contents change
# no specification. And a disabled stack has no use for a database. There is no
# failure in the other direction because the initializer never deletes
# anything.
#
# THE FILE CONTAINS PASSWORDS: written with chmod 600 and kept out of git.
stacks_databases_content() {
  local root="${ROOT_DIR:?}" prefix s key val body=""
  prefix="$(stacks_db_prefix)"
  [ -n "$prefix" ] || return 0

  cat <<HDR
# GENERATED FILE — edits will be overwritten.
# Produced by stack.sh from the ${prefix}_* keys in stacks/*/stack.conf.
#
# The source of truth is the stack's .env. A second copy of the database name,
# user and password drifts from it silently: the application gets an
# authentication failure against a healthy database, and it shows up only in
# the application's own log, hours after \`up -d\`.
HDR

  while IFS= read -r s; do
    [ -n "$s" ] || continue
    ENV_VARS=()
    env_load_files "$root/.env" "$(stack_env_file "$s")" "$(stack_conf_file "$s")"
    [ -n "$(env_get "${prefix}_DB")" ] || continue
    body="$body
# stack $s"
    for key in $DB_KEYS_REQUIRED $DB_KEYS_OPTIONAL; do
      val="$(env_get "${prefix}_${key}")"
      [ -n "$val" ] || continue
      # The key in the file is lowercase and without the prefix: the provider's
      # initializer reads ITS OWN file and need not know our prefix.
      body="$body
  $(printf '%s' "$key" | tr 'A-Z' 'a-z'): $(_yaml_sq "$val")"
    done
    # The first key of an entry must carry the YAML list dash. Appending it
    # here is simpler than branching inside the loop above.
    body="$(printf '%s' "$body" | sed 's/^  db:/- db:/')"
  done < <(stacks_enabled 2>/dev/null)
  printf '%s\n' "$body"
}

# Declaration checks. They print one line per problem and stay silent when
# there is none, like the other check_* functions in lib-stacks.sh.

# An incomplete database order. A user without a password would be created with
# an EMPTY password and would let in anyone who can reach the database port; a
# database without a user would not be created at all.
check_db_decl() {
  local s="$1" root="${ROOT_DIR:?}" prefix key missing="" any=""
  prefix="$(stacks_db_prefix)"
  [ -n "$prefix" ] || return 0
  ENV_VARS=()
  env_load_files "$root/.env" "$(stack_env_file "$s")" "$(stack_conf_file "$s")"
  for key in $DB_KEYS_REQUIRED; do
    if [ -n "$(env_get "${prefix}_${key}")" ]; then any=1; else missing="$missing ${prefix}_${key}"; fi
  done
  [ -n "$any" ] || return 0
  [ -z "$missing" ] || printf 'stack %s: incomplete database order, missing:%s\n' "$s" "$missing"

  # The provider validates its own keys: what Grants means is known to it, not
  # to the engine. The presence of the file is the declaration; no separate key
  # is needed for it.
  local provider check
  provider="$(stacks_db_provider)"
  [ -n "$provider" ] || return 0
  check="$(stack_dir "$provider")/scripts/check-decl.sh"
  [ -x "$check" ] || return 0
  STACK_NAME="$s" DB_PREFIX="$prefix" "$check" 2>&1 || true
}

# One database name ordered by two stacks is a fight over ownership and almost
# certainly a typo: the initializer creates the database for the first stack
# and silently skips the second, which then gets someone else's database with
# someone else's data.
check_databases_unique() {
  local root="${ROOT_DIR:?}" prefix s db
  prefix="$(stacks_db_prefix)"
  [ -n "$prefix" ] || return 0
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    ENV_VARS=()
    env_load_files "$root/.env" "$(stack_env_file "$s")" "$(stack_conf_file "$s")"
    db="$(env_get "${prefix}_DB")"
    [ -n "$db" ] && printf '%s\t%s\n' "$db" "$s"
  done < <(stacks_enabled 2>/dev/null) | sort | awk -F'\t' '
    # $2 != prevs for the same reason as in check_domains_unique: adjacent
    # lines can come from one stack, and "ordered by papa and by papa" reads
    # as a broken check rather than as a finding.
    { if ($1 == prev) {
        if ($2 == prevs) print "database " $1 " is ordered twice by stack " $2
        else             print "database " $1 " is ordered by both " prevs " and " $2
      }
      prev = $1; prevs = $2 }'
}

# stack_backup_sources <stack>
#
# Prints one line per source: "<kind>:<path-or-name>". Kinds are db, sqlite,
# files, volume. Which DBMS a db source belongs to is unknown to the engine:
# dumps are taken by the provider.
#
# Called ONLY for enabled stacks: they have a .env by construction, otherwise
# no compose command would run on the machine at all. That is why substitutions
# are EXPANDED here — unlike Static, which the platform passes to compose
# verbatim (see stack_conf_get in lib-stacks.sh).
#
# The list of databases in the shared provider is deliberately not assembled
# here; it is asked of the DBMS itself. A hardcoded list would mean the next
# database someone creates silently goes unbacked. Backup_DB is only an
# addition, for a database that does not live in the shared container.
#
# Non-DBMS sources are declared by the stack itself (Backup_Sqlite= in
# stack.conf). A path hardcoded in the engine would mean editing backup.sh for
# every new stack of that kind.
stack_backup_sources() {
  local s="$1" root="${ROOT_DIR:?}" kind key v
  # A fresh variable set per stack: values from a neighbouring stack must not
  # leak into this one's substitutions.
  ENV_VARS=()
  env_load_files "$root/.env" "$(stack_env_file "$s")" "$(stack_conf_file "$s")"
  for kind in db sqlite files volume; do
    case "$kind" in
      db)       key=Backup_DB ;;
      sqlite)   key=Backup_Sqlite ;;
      files)    key=Backup_Files ;;
      volume)   key=Backup_Volume ;;
    esac
    # An undefined variable is a failure, not a source.
    #
    # That is what a forgotten line in a stack's .env looks like: a value of
    # "${Host_Db_Dir}/${Db_File}" with the second variable missing would
    # collapse into a path ending in a slash, and that source would silently
    # stop being backed up. Silence is the worst outcome here: a missing backup
    # looks exactly like a source that does not exist.
    #
    # The name of the missing variable is taken from the RAW value: by this
    # point env_expand has already substituted an empty string for it, and the
    # expanded value no longer says what needs fixing.
    if ! _env_check_refs "$key" "$s"; then return 1; fi

    for v in $(env_get "$key"); do
      case "$v" in
        */) echo "Error: $key of stack '$s' ends in a slash: $v" >&2
            echo "  A file name was probably substituted as empty." >&2
            return 1 ;;
      esac
      printf '%s:%s\n' "$kind" "$v"
    done
  done
}

# ------------------------------------------------- recognising a dump
#
# backup_file_kind <file> -> sqlite_plain | sqlite_gz | tar_gz | unknown
#
# Looks at the CONTENT, not at the wrapper. Treating every gzip as SQLite would
# be wrong: a MySQL dump (.sql.gz) and a tar of files:/volume: sources are both
# gzipped. On the day a restore is needed, a database dump would be recognised
# as a SQLite database, the restore would take the wrong branch, and nothing
# would land in the database.
#
# unknown means "not something the platform recognises on its own" — then the
# DB provider is asked: only it knows the formats of its own dumps.
backup_file_kind() {
  local f="$1" magic head
  magic=$(od -An -v -tx1 -N16 "$f" 2>/dev/null | tr -d ' \n')
  case "$magic" in
    53514c69746520666f726d6174*) printf 'sqlite_plain'; return 0 ;;   # "SQLite format"
    1f8b*) ;;                                                          # gzip — look inside
    *)     printf 'unknown'; return 0 ;;
  esac

  # Inside the gzip: 512 bytes is enough for both the SQLite header and the
  # ustar field in a tar header (offset 257). Read through head so a
  # multi-gigabyte dump is not decompressed for the sake of sixteen bytes.
  head=$(gunzip -c "$f" 2>/dev/null | head -c 512 | od -An -v -tx1 | tr -d ' \n')
  case "$head" in
    53514c69746520666f726d6174*) printf 'sqlite_gz'; return 0 ;;
  esac
  # "ustar" at offset 257 is character 514 of the hex string.
  case "${head:514:10}" in
    7573746172*) printf 'tar_gz'; return 0 ;;
  esac
  printf 'unknown'
}

# ---------------------------------------------------------- paths in S3
#
# The formulas live HERE rather than in the scripts because two copies drift:
# backup.sh would store an object under one path while check-backups.sh looks
# under another, and the check would report "no backups at all" while backups
# are healthy. Both sides look correct in isolation, which makes it hard to
# notice.

# The machine's prefix inside the bucket. REQUIRED, with no default.
#
# A default here is more dangerous than an absence: the bucket may be shared by
# several machines, and a forgotten value would mean dumps land in another
# machine's directory, on top of its dumps.
backup_s3_prefix() { env_require Backup_S3_Prefix "this machine's prefix in the bucket, unique per machine"; }

# The prefix for shared-DBMS dumps inside the machine's prefix.
#
# Defaults to the provider stack's name. It is overridable because changing the
# prefix on a RUNNING machine means new dumps go somewhere else while the check
# keeps looking in the same place and reports "no backups" for healthy backups.
backup_db_prefix() { env_get Backup_DB_Prefix "$(stacks_db_provider)"; }

# The S3 prefix for this file: sqlite/<name without extension>.
sqlite_s3_subpath() {
  local base
  base=$(basename "${1-}")
  base="${base%.db}"
  printf 'sqlite/%s' "$(printf '%s' "$base" | tr -c 'A-Za-z0-9._-' '_')"
}

# --------------------------------------------------------------------------
# The three wrappers below are all about the same thing: a command that exists
# on one machine and not on another, or behaves differently there. Each failure
# of that kind is silent — an empty checksum, a timestamp read as local time, a
# watchdog that never starts. Calling these things directly is therefore not
# allowed, and selftest enforces that.
# --------------------------------------------------------------------------

# sha256_file <file> -> hex digest without the file name
#
# Neither command is universal: sha256sum comes from GNU coreutils and does not
# exist on macOS; shasum comes from perl and may be absent from a minimal Linux
# image. A bare `shasum` would substitute an empty string when missing, that
# string would match no checksum in the manifest, and the check would report
# that EVERY platform file had been edited in place. A missing tool must be
# reported as a missing tool, not as a discrepancy.
sha256_file() {
  local f="${1-}"
  if command -v sha256sum >/dev/null 2>&1; then  # portable-ok
    sha256sum "$f" | cut -d' ' -f1  # portable-ok
  elif command -v shasum >/dev/null 2>&1; then  # portable-ok
    shasum -a 256 "$f" | cut -d' ' -f1  # portable-ok
  else
    echo "Error: neither sha256sum nor shasum is available — cannot compute checksums." >&2  # portable-ok
    return 2
  fi
}

# iso_to_epoch <ISO-8601 timestamp> -> epoch seconds
#
# GNU date parses such a string directly; BSD date (macOS) understands neither
# the colon in the offset (`+00:00`), nor a `Z` suffix, nor fractional seconds.
# The tempting shortcut is to drop the offset and parse the rest with `-f`. But
# `-f` without `-u` and without `%z` reads the string as LOCAL time, while S3
# timestamps arrive in UTC: east of Greenwich a fresh backup looks stale by the
# size of the timezone offset, west of it a stale backup passes the check. So
# the offset is not dropped but normalised into a form BSD date accepts.
iso_to_epoch() {
  local s="${1-}"
  date -d "$s" +%s 2>/dev/null && return 0
  s=$(printf '%s' "$s" | sed -E 's/\.[0-9]+//; s/[Zz]$/+0000/; s/([+-][0-9]{2}):([0-9]{2})$/\1\2/')
  date -j -f '%Y-%m-%dT%H:%M:%S%z' "$s" +%s 2>/dev/null && return 0
  # The string carried no offset. Then it is UTC by the source's convention —
  # which is exactly why -u is here rather than a bare -f.
  date -j -u -f '%Y-%m-%dT%H:%M:%S' "$s" +%s 2>/dev/null && return 0
  return 1
}

# run_with_timeout <seconds> <command> [arguments...]
#
# `timeout` comes from GNU coreutils; macOS and FreeBSD do not have it (under
# Homebrew it is called gtimeout). Without this wrapper the call simply fails
# to find the command, health.sh is never started, and --check hangs exactly
# where the watchdog was needed — on an unresponsive stack. Exit code 124
# matches GNU timeout so the caller can tell "did not answer" from "returned an
# error".
run_with_timeout() {
  local secs="${1-}"; shift
  local t
  for t in timeout gtimeout; do
    if command -v "$t" >/dev/null 2>&1; then "$t" "$secs" "$@"; return $?; fi  # portable-ok
  done
  # Neither is present — run our own watchdog.
  "$@" &
  local pid=$! guard rc=0
  ( sleep "$secs"; kill -TERM "$pid" 2>/dev/null ) >/dev/null 2>&1 &
  guard=$!
  wait "$pid" || rc=$?
  kill -TERM "$guard" >/dev/null 2>&1
  wait "$guard" >/dev/null 2>&1
  # 128+SIGTERM: that is what a process killed by the watchdog looks like.
  [ "$rc" -eq 143 ] && rc=124
  return "$rc"
}
