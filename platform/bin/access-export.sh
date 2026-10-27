#!/usr/bin/env bash
# The nightly access-log export: every finished day of the access logs of the
# stacks that declare Access_Export="yes", turned into one anonymised file per
# vhost and day under state/access-export/<stack>/<domain>/<YYYY-MM-DD>.tsv.gz.
# What devbox-access-export.service runs, and the same thing by hand.
#
# Why: the logs are kept Platform_Nginx_Log_Days and no longer, because they
# hold the IP of every visitor, and a privacy note promises that. Who came,
# from where and how often is still worth knowing a year later. The export
# keeps that and drops the address:
#
#   - the IP becomes a client hash, SHA-256 of a salt and the address. The salt
#     is made once per machine and stays in ACCESS_EXPORT_STATE_DIR, root's
#     alone and in no backup, so a client is the same client across days and
#     months, and the files alone do not lead back to an address;
#   - its country and network (AS) are looked up first, here, in DB-IP's free
#     databases (db-ip.com, CC BY 4.0), downloaded once a month;
#   - query strings go, and so does any long token in a path: a Telegram
#     webhook carries its bot token in the URL.
#
#   sudo ./platform/bin/access-export.sh              # as the timer does
#   ./platform/bin/access-export.sh --dry-run         # which days it would export; no root
#   sudo ./platform/bin/access-export.sh --hash <IP>  # an address's client hash, to find your own
#
# Which days. A day is exported once, the night after it ends, and never
# rewritten. The day still running is left alone, and so is the oldest day the
# logs hold: the rotation that removed the generation before it may have cut
# its first minutes, and a day that looks whole but is not is worse than none.
# A night missed (the machine was off, the database could not be fetched) is
# caught up by the next run, as long as the logs still have the day.
set -euo pipefail

DIR0="$( cd -P "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# The MACHINE's directory, not the platform's: see nginx-logrotate.sh.
if [ -z "${ROOT_DIR:-}" ]; then
  ROOT_DIR="$( cd "$DIR0/../.." && pwd )"
  ROOT_DIR="${ROOT_DIR%%/.stackyard/*}"; ROOT_DIR="${ROOT_DIR%/.stackyard}"
fi
LIB_DIR="$( cd "$DIR0/../lib" && pwd )"
ENV_FILE="$ROOT_DIR/.env"

# shellcheck source=platform/lib/lib-env.sh
. "$LIB_DIR/lib-env.sh"
# shellcheck source=platform/lib/lib-stacks.sh
. "$LIB_DIR/lib-stacks.sh"

if [ ! -f "$ENV_FILE" ]; then
  echo "Error: environment file '$ENV_FILE' not found" >&2
  exit 2
fi
env_load_files "$ENV_FILE"

MODE="export"
HASH_IP=""
case "${1-}" in
  "") ;;
  --dry-run) MODE="dry" ;;
  --hash) MODE="hash"; HASH_IP="${2-}"
          [ -n "$HASH_IP" ] || { echo "Usage: $0 --hash <IP>" >&2; exit 2; } ;;
  *) echo "Usage: $0 [--dry-run | --hash <IP>]" >&2; exit 2 ;;
esac

SALT_FILE="$ACCESS_EXPORT_STATE_DIR/salt"
GEO_DIR="$ACCESS_EXPORT_STATE_DIR/geo"
# Overridable only for the selftest, which serves fixture databases from a
# directory (curl reads file:// URLs too).
GEO_URL="${STACKYARD_ACCESS_EXPORT_GEO_URL:-https://download.db-ip.com/free}"
EXPORT_ROOT="$(access_export_root)"
OWNER=$(stat -c '%U' "$ROOT_DIR" 2>/dev/null || stat -f '%Su' "$ROOT_DIR")
TODAY=$(date -u +%Y-%m-%d)

die() { echo "Error: $*" >&2; exit 1; }

# The salt, made on first use. 077 and an atomic rename: a half-written or
# world-readable salt is worse than none.
salt() {
  if [ ! -s "$SALT_FILE" ]; then
    ( umask 077
      mkdir -p "$ACCESS_EXPORT_STATE_DIR"
      head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$SALT_FILE.new"
      mv -f "$SALT_FILE.new" "$SALT_FILE" ) 2>/dev/null \
      || die "cannot create $SALT_FILE — run as root (sudo $0)"
  fi
  [ -r "$SALT_FILE" ] && cat "$SALT_FILE" || die "cannot read $SALT_FILE — run as root (sudo $0)"
}

# The client hash: 12 hex digits of SHA-256 over salt and address, through
# standard input (see sha256_stdin). 48 bits: no two of a site's visitors
# collide in practice, and the column stays short.
client_hash() { printf '%s%s' "$1" "$2" | sha256_stdin | cut -c1-12; }

if [ "$MODE" = hash ]; then
  client_hash "$(salt)" "$HASH_IP"
  echo
  exit 0
fi

# Validated before anything else, as systemd.sh does: Access_Export="Yes" is a
# stack whose owner asked for the numbers.
invalid="$(stacks_access_export_invalid)"
[ -z "$invalid" ] || die "Access_Export must be yes or no: $(echo "$invalid" | tr '\n' ' ')"

STACKS="$(stacks_access_export)"
if [ -z "$STACKS" ]; then
  echo "No enabled stack declares Access_Export=\"yes\" — nothing to export."
  exit 0
fi

# A domain's log files, the rotated generations oldest first and the live file
# last: a day's records then come out in the order nginx wrote them.
domain_logs() {
  local d="$1" f
  for f in $(find "$NGINX_LOG_DIR" -maxdepth 1 -type f -name "$d-access-*" 2>/dev/null | sort); do
    case "${f##*/}" in
      "$d-access-"[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]|"$d-access-"[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9].gz)
        printf '%s\n' "$f" ;;
    esac
  done
  [ -f "$NGINX_LOG_DIR/$d-access" ] && printf '%s\n' "$NGINX_LOG_DIR/$d-access"
  return 0
}

# Every record of the given files, uncompressed.
read_logs() { local f; for f in "$@"; do gzip -dcf "$f"; done; }

# The date of each record as YYYY-MM-DD, from nginx's $time_local
# ([27/Oct/2026:08:49:01 +0000]). The month table is shared by both passes.
AWK_DATE='
  BEGIN { split("Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec", mn, " ")
          for (i = 1; i <= 12; i++) mo[mn[i]] = sprintf("%02d", i) }
  # Sets rtime, HH:MM, as a side effect.
  function rdate(   t, p) {
    if (!match($0, /\[[0-9][0-9]\/[A-Z][a-z][a-z]\/[0-9][0-9][0-9][0-9]:/)) return ""
    t = substr($0, RSTART + 1, 11)
    rtime = substr($0, RSTART + 13, 5)
    split(t, p, "/")
    return p[3] "-" mo[p[2]] "-" p[1]
  }'

# ------------------------------------------------------- 1. the plan

# "stack|domain|date" for every day to export.
PLAN=()
NO_LOGS=()
for stack in $STACKS; do
  for d in $(stack_conf_get "$stack" Domains); do
    d="$(domain_primary "$d")"
    mapfile -t logs < <(domain_logs "$d")
    if [ ${#logs[@]} -eq 0 ]; then
      NO_LOGS+=("$stack/$d")
      continue
    fi
    # Every date the logs hold, minus the oldest (see the header), today and
    # what is already exported.
    dates=$(read_logs "${logs[@]}" | awk "$AWK_DATE"'{ d = rdate(); if (d != "") print d }' | LC_ALL=C sort -u)
    oldest=$(printf '%s\n' "$dates" | head -n 1)
    for day in $dates; do
      [ "$day" = "$oldest" ] && continue
      [[ "$day" < "$TODAY" ]] || continue
      [ -f "$EXPORT_ROOT/$stack/$d/$day.tsv.gz" ] && continue
      PLAN+=("$stack|$d|$day")
    done
  done
done

for x in ${NO_LOGS[@]+"${NO_LOGS[@]}"}; do
  echo "WARNING: no access log for ${x#*/} (stack ${x%%/*}) in $NGINX_LOG_DIR — its vhost must log to ${x#*/}-access" >&2
done

if [ "$MODE" = dry ]; then
  if [ ${#PLAN[@]} -eq 0 ]; then
    echo "Nothing to export: every finished day is exported."
  else
    for p in "${PLAN[@]}"; do echo "would export ${p//|/ }"; done
  fi
  exit 0
fi

# Root, asked here and said plainly: on a machine the state directory is
# root's, and a run without sudo used to end in two raw shell errors first.
( umask 077; mkdir -p "$ACCESS_EXPORT_STATE_DIR" ) 2>/dev/null && [ -w "$ACCESS_EXPORT_STATE_DIR" ] \
  || die "cannot write $ACCESS_EXPORT_STATE_DIR — run as root (sudo $0)"

# One run at a time, before anything is written. host-setup starts the first
# export in the background, and a run by hand beside it once deleted the
# other's work directory mid-day. flock is util-linux: every machine has it, a
# laptop running the selftest may not, and there nothing runs beside the test.
if command -v flock >/dev/null 2>&1; then
  exec 9>"$ACCESS_EXPORT_STATE_DIR/lock"
  flock -n 9 || die "another export is already running (lock $ACCESS_EXPORT_STATE_DIR/lock)"
fi

# The stack directories and their FORMAT, every run: backup.sh keeps them as
# an archive of their own, and FORMAT is what makes an emptied directory an
# empty source rather than a quiet one (see backup_sources_enabled).
for stack in $STACKS; do
  mkdir -p "$EXPORT_ROOT/$stack"
  cat > "$EXPORT_ROOT/$stack/FORMAT.new" <<'TXT'
Access-log exports made by stackyard's platform/bin/access-export.sh.

<domain>/<YYYY-MM-DD>.tsv.gz: one file per vhost and finished day, written
once, the night after. Tab-separated, with a header row:

  date      YYYY-MM-DD, as nginx logged it
  time      HH:MM
  client    12 hex digits of SHA-256 over this machine's salt and the IP;
            the same address is the same client on every day
  country   ISO 3166 code, or - when unknown
  as        the network: AS number and name, or -
  method    the HTTP method, or - for a request that was not HTTP
  path      without the query string; long tokens read <tok>
  status    the HTTP status (101 is an upgraded WebSocket)
  bytes     the response size
  referrer  the referring host only, or -
  ua        the user agent

Country and network: DB-IP Lite (https://db-ip.com), CC BY 4.0.
TXT
  mv -f "$EXPORT_ROOT/$stack/FORMAT.new" "$EXPORT_ROOT/$stack/FORMAT"
  chown "$OWNER" "$EXPORT_ROOT" "$EXPORT_ROOT/$stack" "$EXPORT_ROOT/$stack/FORMAT" 2>/dev/null || true
done

if [ ${#PLAN[@]} -eq 0 ]; then
  echo "Nothing to export: every finished day is exported."
  exit 0
fi


SALT="$(salt)"
command -v curl >/dev/null 2>&1 || die "no curl command (sudo ./host-setup installs it)"

# ------------------------------------------------------- 2. the databases

# This month's file, or last month's while this month's is not published yet,
# or the newest one cached. No database at all fails the run: a day exported
# without countries cannot be redone once its logs are rotated away, and a
# failed run is retried the next night with the logs still there.
fetch_geo() {
  local db="$1" y m month prev f
  y=${TODAY%%-*}; m=${TODAY#*-}; m=${m%%-*}
  month="$y-$m"
  if [ "$((10#$m))" -eq 1 ]; then prev="$((y - 1))-12"; else prev="$y-$(printf '%02d' $((10#$m - 1)))"; fi
  for f in "$month" "$prev"; do
    if [ -s "$GEO_DIR/dbip-$db-lite-$f.csv.gz" ]; then
      printf '%s' "$GEO_DIR/dbip-$db-lite-$f.csv.gz"; return 0
    fi
    if curl -fsS --max-time 300 -o "$GEO_DIR/part" "$GEO_URL/dbip-$db-lite-$f.csv.gz" 2>/dev/null \
       && gzip -t "$GEO_DIR/part" 2>/dev/null; then
      mv -f "$GEO_DIR/part" "$GEO_DIR/dbip-$db-lite-$f.csv.gz"
      # Only the newest is kept.
      find "$GEO_DIR" -maxdepth 1 -name "dbip-$db-lite-*.csv.gz" ! -name "dbip-$db-lite-$f.csv.gz" -exec rm -f {} +
      printf '%s' "$GEO_DIR/dbip-$db-lite-$f.csv.gz"; return 0
    fi
    rm -f "$GEO_DIR/part"
  done
  f=$(find "$GEO_DIR" -maxdepth 1 -name "dbip-$db-lite-*.csv.gz" 2>/dev/null | LC_ALL=C sort | tail -n 1)
  if [ -n "$f" ]; then
    echo "WARNING: cannot download the $db database for $month or $prev; using ${f##*/}" >&2
    printf '%s' "$f"; return 0
  fi
  return 1
}
( umask 077; mkdir -p "$GEO_DIR" )
GEO_COUNTRY=$(fetch_geo country) || die "no country database: $GEO_URL/dbip-country-lite-*.csv.gz cannot be downloaded and none is cached"
GEO_ASN=$(fetch_geo asn) || die "no network database: $GEO_URL/dbip-asn-lite-*.csv.gz cannot be downloaded and none is cached"

# An address as a key that sorts the way the databases do: v4 and 8 hex
# digits, v6 and 32. The databases list IPv4 ranges first, then IPv6, each in
# numeric order; fixed-width hex makes that a plain string order (LC_ALL=C).
# The prefix is letters so awk never compares two keys as numbers.
AWK_KEY='
  function pad4(g) { while (length(g) < 4) g = "0" g; return g }
  function ipkey(ip,   a, b, n, i, head, tail, h, t, hp, tp, out, at) {
    if (index(ip, ":") == 0) {
      if (split(ip, a, ".") != 4) return ""
      return sprintf("v4%02x%02x%02x%02x", a[1], a[2], a[3], a[4])
    }
    ip = tolower(ip)
    # An IPv4 address nginx logged as IPv6 (a dual-stack listener) is looked
    # up as the IPv4 address it is: the databases list it there.
    if (ip ~ /^::ffff:[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) return ipkey(substr(ip, 8))
    # Any other IPv4 tail is two groups.
    if (index(ip, ".")) {
      n = split(ip, a, ":"); split(a[n], b, ".")
      sub(/[^:]*$/, "", ip)
      ip = ip sprintf("%x:%x", b[1] * 256 + b[2], b[3] * 256 + b[4])
    }
    at = index(ip, "::")
    if (at) { head = substr(ip, 1, at - 1); tail = substr(ip, at + 2) } else { head = ip; tail = "" }
    h = (head == "" ? 0 : split(head, hp, ":"))
    t = (tail == "" ? 0 : split(tail, tp, ":"))
    out = "v6"
    for (i = 1; i <= h; i++) out = out pad4(hp[i])
    for (i = 0; i < 8 - h - t; i++) out = out "0000"
    for (i = 1; i <= t; i++) out = out pad4(tp[i])
    return out
  }'

# "ip<TAB>value" for every address in $1 (key<TAB>ip, sorted), one pass over a
# database in step with the sorted addresses: the databases are hundreds of
# thousands of ranges, and the machine may have a gigabyte of memory.
#
# gzip's status is ignored: awk stops reading once every address is placed,
# and under pipefail the SIGPIPE that gzip then gets would fail the run.
geo_lookup() {
  local keys="$1" db="$2" kind="$3"
  { gzip -dc "$db" || true; } | awk -v keys="$keys" -v kind="$kind" "$AWK_KEY"'
    BEGIN {
      i = 1
      while ((getline l < keys) > 0) { split(l, a, "\t"); k[++n] = a[1]; ip[n] = a[2] }
      if (n == 0) exit
    }
    {
      line = $0
      c = index(line, ","); s = substr(line, 1, c - 1); line = substr(line, c + 1)
      c = index(line, ","); e = substr(line, 1, c - 1); rest = substr(line, c + 1)
      ks = ipkey(s); ke = ipkey(e)
      while (i <= n && k[i] < ks) i++
      while (i <= n && k[i] <= ke) {
        if (kind == "asn") {
          c = index(rest, ","); org = substr(rest, c + 1)
          sub(/^"/, "", org); sub(/"$/, "", org); gsub(/""/, "\"", org); gsub(/\t/, " ", org)
          val[i] = "AS" substr(rest, 1, c - 1) " " org
        } else {
          val[i] = rest
        }
        i++
      }
      if (i > n) exit
    }
    END { for (j = 1; j <= n; j++) print ip[j] "\t" ((j in val) ? val[j] : "-") }
  '
}

# ------------------------------------------------------- 3. the days

# A directory of this run's own, on disk rather than in /tmp (a tmpfs the size
# of half the memory on a small machine): a day of a busy site is large.
WORK="$(mktemp -d "$ACCESS_EXPORT_STATE_DIR/work.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# Tokens in paths, as regular expressions without interval expressions: mawk,
# Debian and Ubuntu's awk, has none. A bot token (123456:AAH…) and any run of
# 24 or more characters an id or a key is made of.
TOKEN_CHARS='[A-Za-z0-9_=-]'
RE_LONG="$(printf "$TOKEN_CHARS%.0s" $(seq 1 24))$TOKEN_CHARS*"
RE_BOT="[0-9][0-9]*:$(printf '[A-Za-z0-9_-]%.0s' $(seq 1 20))[A-Za-z0-9_-]*"

FAILED=0
for p in "${PLAN[@]}"; do
  IFS='|' read -r stack d day <<< "$p"
  mapfile -t logs < <(domain_logs "$d")
  raw="$WORK/raw"
  read_logs "${logs[@]}" | awk -v want="$day" "$AWK_DATE"'{ if (rdate() == want) print }' > "$raw"

  # Each address once: its hash, country and network.
  awk '{ print $1 }' "$raw" | LC_ALL=C sort -u > "$WORK/ips"
  awk "$AWK_KEY"'{ k = ipkey($1); if (k != "") print k "\t" $1 }' "$WORK/ips" | LC_ALL=C sort > "$WORK/keys"
  geo_lookup "$WORK/keys" "$GEO_COUNTRY" country > "$WORK/cc"
  geo_lookup "$WORK/keys" "$GEO_ASN" asn > "$WORK/as"
  : > "$WORK/hash"
  while IFS= read -r ip; do
    printf '%s\t%s\n' "$ip" "$(client_hash "$SALT" "$ip")" >> "$WORK/hash"
  done < "$WORK/ips"

  out="$EXPORT_ROOT/$stack/$d/$day.tsv.gz"
  mkdir -p "$EXPORT_ROOT/$stack/$d"
  # The record is nginx's combined format: split on the double quotes, the
  # request is field 2, status and size field 3, referrer 4, user agent 6.
  if ! awk -F '"' -v hashes="$WORK/hash" -v ccs="$WORK/cc" -v ases="$WORK/as" \
          -v re_bot="$RE_BOT" -v re_long="$RE_LONG" "$AWK_DATE"'
    BEGIN {
      OFS = "\t"
      while ((getline l < hashes) > 0) { split(l, a, "\t"); h[a[1]] = a[2] }
      while ((getline l < ccs) > 0)    { split(l, a, "\t"); cc[a[1]] = a[2] }
      while ((getline l < ases) > 0)   { split(l, a, "\t"); as[a[1]] = a[2] }
      print "date", "time", "client", "country", "as", "method", "path", "status", "bytes", "referrer", "ua"
    }
    {
      split($1, f, " "); ip = f[1]
      date = rdate()
      n = split($2, r, " "); method = r[1]; path = (n >= 2 ? r[2] : $2)
      if (method !~ /^[A-Z]+$/) { method = "-"; path = "<not http>" }
      sub(/[?#].*/, "", path)
      gsub(re_bot, "<tok>", path)
      gsub(re_long, "<tok>", path)
      gsub(/\t/, " ", path)
      split($3, s, " ")
      ref = $4; sub(/^[A-Za-z]+:\/\//, "", ref); sub(/[\/?#:].*/, "", ref); if (ref == "") ref = "-"
      ua = $6; gsub(/\t/, " ", ua); if (ua == "") ua = "-"
      print date, rtime, ((ip in h) ? h[ip] : "-"), ((ip in cc) ? cc[ip] : "-"), ((ip in as) ? as[ip] : "-"), \
            method, path, s[1], s[2], ref, ua
    }
  ' "$raw" | gzip -9 > "$out.part"; then
    rm -f "$out.part"
    echo "Error: could not export $d $day (stack $stack)" >&2
    FAILED=1
    continue
  fi
  chmod 644 "$out.part"
  mv -f "$out.part" "$out"
  chown "$OWNER" "$EXPORT_ROOT/$stack/$d" "$out" 2>/dev/null || true
  echo "  exported $d $day: $(($(wc -l < "$raw"))) requests, $(($(wc -l < "$WORK/ips"))) clients"
done

exit "$FAILED"
