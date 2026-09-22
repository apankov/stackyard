#!/usr/bin/env bash

# Checking TLS certificate expiry.
#
# This exists because a timer that has stopped firing looks exactly like a
# timer with nothing to do. getssl is quiet when there is nothing to renew, and
# equally quiet when it never ran. Only an independent check of the RESULT can
# tell the two apart.
#
# A non-zero exit code makes systemd mark the unit as failed, so it surfaces in
# `systemctl --failed` rather than sinking into the journal.

set -uo pipefail

DIR0="$( cd -P "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# The MACHINE's directory, not the platform's. Normally set by a wrapper in the
# machine root; the fallback is two levels up from platform/bin, so the script
# also works when invoked directly.
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
ENV_FILE="$ROOT_DIR/.env"

# shellcheck source=platform/lib/lib-stacks.sh
. "$LIB_DIR/lib-stacks.sh"

if [ ! -f "$ENV_FILE" ]; then
  echo "Error: environment file '$ENV_FILE' not found" >&2
  exit 2
fi

Platform_Deploy_Dir=$(grep -E '^Platform_Deploy_Dir=' "$ENV_FILE" | head -n 1 | cut -d '=' -f2- | tr -d '"'\')

if [ -z "$Platform_Deploy_Dir" ]; then
  echo "Error: Platform_Deploy_Dir is not set in $ENV_FILE" >&2
  exit 2
fi

CERTS_DIR="$Platform_Deploy_Dir/state/certs"

# RENEW_ALLOW in the shared getssl.cfg is 30: a renewal is due once fewer than
# 30 days remain. The alarm threshold is lower so that getssl has ten days and
# several attempts before anyone is woken.
THRESHOLD_DAYS="${THRESHOLD_DAYS:-20}"

# The placeholder certificate from certs.sh is self-signed and valid for a
# year, so by expiry alone it is indistinguishable from a healthy one. It is
# recognised by its issuer.
PLACEHOLDER_CN='CN=devbox'

if [ ! -d "$CERTS_DIR" ]; then
  echo "Error: no certificate directory $CERTS_DIR" >&2
  exit 2
fi

shopt -s nullglob
certs=( "$CERTS_DIR"/*-fullchain.crt )
shopt -u nullglob

if [ ${#certs[@]} -eq 0 ]; then
  echo "Error: $CERTS_DIR contains no *-fullchain.crt at all" >&2
  exit 2
fi

now=$(date +%s)
problems=0

# Domains whose TLS is terminated in front of the machine. Their file on disk
# is the placeholder and always will be: nothing here issues it, and nothing
# outside is going to write it back. Reporting that as a problem every night
# is how a check stops being read — and this check has one job, which is to be
# read on the night a real renewal breaks.
external=" $(stacks_domains_external | tr '\n' ' ') "
skipped=0

for cert in "${certs[@]}"; do
  host=$(basename "$cert" -fullchain.crt)

  case "$external" in
    *" $host "*)
      printf '%-40s external: TLS is terminated in front of this machine\n' "$host"
      skipped=$((skipped + 1))
      continue ;;
  esac

  if ! end_date=$(openssl x509 -noout -enddate -in "$cert" 2>/dev/null | cut -d= -f2); then
    printf '%-40s ERROR: the file is not readable as a certificate\n' "$host"
    problems=$((problems + 1))
    continue
  fi

  issuer=$(openssl x509 -noout -issuer -in "$cert" 2>/dev/null)

  # BSD date (macOS) and GNU date (Linux) parse this string differently.
  if ! end_ts=$(date -d "$end_date" +%s 2>/dev/null); then
    end_ts=$(date -j -f '%b %e %T %Y %Z' "$end_date" +%s 2>/dev/null) || {
      printf '%-40s ERROR: could not parse the date "%s"\n' "$host" "$end_date"
      problems=$((problems + 1))
      continue
    }
  fi

  days=$(( (end_ts - now) / 86400 ))

  if [[ "$issuer" == *"$PLACEHOLDER_CN"* ]]; then
    printf '%-40s PLACEHOLDER: a real certificate was never issued\n' "$host"
    problems=$((problems + 1))
  elif [ "$days" -lt "$THRESHOLD_DAYS" ]; then
    printf '%-40s EXPIRES in %s days — the renewal did not work\n' "$host" "$days"
    problems=$((problems + 1))
  else
    printf '%-40s ok, %s days\n' "$host" "$days"
  fi
done

# A domain of an enabled stack with no certificate at all is a failure, not
# silence. The loop above walks FILES and therefore cannot notice a missing
# one: no file, no iteration. Without this check a new stack keeps its
# placeholder until someone opens it in a browser.
declared=0
while IFS= read -r domain; do
  [ -n "$domain" ] || continue
  declared=$((declared + 1))
  if [ ! -f "$CERTS_DIR/$domain-fullchain.crt" ]; then
    printf '%-40s NO FILE: the domain is declared in stack.conf, the certificate is absent\n' "$domain"
    problems=$((problems + 1))
  fi
done < <(stacks_domains)

if [ "$declared" -eq 0 ]; then
  # No domain from any enabled stack is almost certainly a broken manifest or
  # empty stack.conf files, rather than a machine without sites. A silent
  # success here would be the worst outcome.
  echo "Warning: no enabled stack declares any domain" >&2
fi

if [ "$problems" -gt 0 ]; then
  echo
  echo "Problem certificates: $problems of ${#certs[@]}." >&2
  echo "Investigate with: journalctl -u getssl-renew --since '-14 days'" >&2
  exit 1
fi

# The two numbers are reported apart. "3 checked, all valid" while two of them
# were never looked at is a sentence that is true about nothing, and this is
# the line someone reads instead of the ones above it.
echo
checked=$(( ${#certs[@]} - skipped ))
if [ "$checked" -gt 0 ]; then
  echo "Certificates checked: $checked. All valid for more than $THRESHOLD_DAYS days."
else
  echo "No certificate here is this machine's to renew."
fi
# An `if`, not `[ ... ] && echo`: this is the last statement in the file, so a
# false test becomes the script's exit status — and that status is the whole
# point of this script, the thing monitoring reads. Every machine without an
# external domain would have started reporting a failure.
if [ "$skipped" -gt 0 ]; then
  echo "External, not checked: $skipped."
fi
