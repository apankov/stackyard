#!/usr/bin/env bash

# TLS preparation: per-host getssl configs from a template, and placeholder
# certificates.
#
# The placeholders are needed BEFORE nginx sees a new vhost: `listen 443 ssl`
# without an existing certificate file is a refusal to start, and with
# `restart: always` a crash loop taking down EVERY vhost.
#
# The list of domains comes from Domains= in the enabled stacks, not from the
# set of directories under getssl-config/: two separate lists drift invisibly
# in both directions — a domain with no stack is renewed forever, and a stack
# with no domain keeps its placeholder until the first visitor.
#
# Run as the owner of the repository, NOT as root: the getssl timer runs as
# that same user and must be able to overwrite a placeholder.
#
#   ./platform/bin/certs.sh            prepare
#   ./platform/bin/certs.sh --check    only report what is missing (exit 1)
#   ./platform/bin/certs.sh --prune    prepare, and also remove the getssl
#                                      configs of domains no enabled stack
#                                      declares (certificates are never removed)

set -euo pipefail

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

CHECK_ONLY=0
PRUNE=0
case "${1:-}" in
  --check) CHECK_ONLY=1 ;;
  --prune) PRUNE=1 ;;
  "")      ;;
  *)       echo "Unknown argument: $1 (expected --check or --prune)" >&2; exit 2 ;;
esac

[ -f "$ENV_FILE" ] || { echo "Error: no $ENV_FILE" >&2; exit 2; }

Platform_Deploy_Dir=$(grep -E '^Platform_Deploy_Dir=' "$ENV_FILE" | head -n 1 | cut -d '=' -f2- | tr -d '"'"'" || true)
[ -n "$Platform_Deploy_Dir" ] || { echo "Error: Platform_Deploy_Dir is not set in $ENV_FILE" >&2; exit 2; }

CERTS_DIR="$ROOT_DIR/state/certs"
GETSSL_DIR="$ROOT_DIR/state/getssl-config"
# The template and the shared config belong to the platform and are identical
# on every machine. getssl's results and the ACME account key belong to the
# machine, under state/.
TEMPLATE="$ROOT_DIR/platform/getssl-config/getssl.cfg.template"
SHARED_CFG="$ROOT_DIR/platform/getssl-config/getssl.cfg"

problems=0
note() { printf '  %s\n' "$1"; }
lack() { printf '  [missing] %s\n' "$1"; problems=$((problems + 1)); }

[ -f "$TEMPLATE" ] || { echo "Error: no template at $TEMPLATE" >&2; exit 2; }

# ---------------------------------------------- 0. ACME account isolation
#
# Each machine must have its OWN ACME account key, and this is not hygiene. One
# account shared across clients means shared Let's Encrypt rate limits (a
# renewal loop on one machine burns another's quota) and shared authority to
# revoke someone else's certificates. Nothing but a check here can notice it:
# such a configuration works perfectly right up to the first incident.
#
# A refusal rather than a warning: a key sitting in the platform would be
# copied to every machine by the next update.
if [ -e "$ROOT_DIR/platform/getssl-config/account.key" ]; then
  echo "REFUSING: platform/getssl-config/account.key exists." >&2
  echo "  The platform is distributed to every machine — an ACME account key in" >&2
  echo "  it means one Let's Encrypt account for all: shared limits, shared" >&2
  echo "  revocation authority." >&2
  echo "  A machine's account lives in state/getssl-config/account.key." >&2
  exit 2
fi

echo "== shared getssl config"
mkdir -p "$GETSSL_DIR"
# Materialised as a copy rather than a symlink: getssl reads its config
# relative to the current directory, and a symlink into the platform would not
# survive every way the platform can be delivered.
if [ -f "$GETSSL_DIR/getssl.cfg" ] && cmp -s "$SHARED_CFG" "$GETSSL_DIR/getssl.cfg"; then
  note "getssl.cfg matches the platform's"
elif [ "$CHECK_ONLY" -eq 1 ]; then
  lack "getssl.cfg is absent or has drifted from the platform's"
else
  cp "$SHARED_CFG" "$GETSSL_DIR/getssl.cfg"
  note "getssl.cfg written from the platform"
fi

# --------------------------------------------------- 1. per-host configs

echo "== getssl configs"

# Named, not silently absent. A domain that simply never appears in this
# section is indistinguishable from one the platform forgot, and the whole
# point of Certs="external" is that someone decided it on purpose.
while IFS= read -r d; do
  [ -n "$d" ] || continue
  note "$d — external: the certificate is issued in front of this machine"
done < <(stacks_domains_external)

while IFS= read -r spec; do
  [ -n "$spec" ] || continue
  domain="$(domain_primary "$spec")"
  # Aliases go into the same certificate as a SANS line. An empty string when
  # there are none: getssl reads SANS="" as "no additional names", whereas a
  # missing line would leave a www name holding a certificate for the bare
  # domain.
  sans="$(domain_sans "$spec" | tr ' ' ',')"
  cfg="$GETSSL_DIR/$domain/getssl.cfg"
  want=$(sed -e "s|@DOMAIN@|$domain|g" -e "s|@DEPLOY_DIR@|$Platform_Deploy_Dir|g" \
             -e "s|@SANS@|$sans|g" "$TEMPLATE")
  if [ -f "$cfg" ] && [ "$(cat "$cfg")" = "$want" ]; then
    note "$domain — ok"
  elif [ "$CHECK_ONLY" -eq 1 ]; then
    lack "$domain — the config is absent or has drifted from the template"
  else
    mkdir -p "$GETSSL_DIR/$domain"
    printf '%s\n' "$want" > "$cfg"
    note "$domain — wrote $cfg"
  fi
done < <(stacks_domain_specs)

# Configs with no stack. Not a refusal, but not normal either: renewing a
# certificate for a domain that no stack.conf declares any more wastes Let's
# Encrypt rate limits and produces expiry mail about ghost domains.
#
# Why it matters beyond tidiness: `getssl -a` walks EVERY directory here, not
# the declared domains. A config left behind by a disabled stack becomes a
# nightly attempt to answer a challenge for a domain this machine no longer
# serves — silent until the certificate enters its renewal window, then an
# error every night and Let's Encrypt requests spent on nothing.
#
# --prune removes the config and NEVER the certificate. A certificate that is
# merely unused costs nothing; one deleted by mistake means nginx does not
# start, because a vhost with `listen 443 ssl` and no certificate file is a
# refusal to start, not a warning.
# The getssl-managed domains, not every declared one: with Certs="external"
# the config left over from before the switch is exactly what has to go, and
# it is the reason --prune is reached for here at all.
domains_now=" $(stacks_domains_getssl | tr '\n' ' ') "
external_now=" $(stacks_domains_external | tr '\n' ' ') "
for d in "$GETSSL_DIR"/*/; do
  [ -d "$d" ] || continue
  name=$(basename "$d")
  case "$domains_now" in
    *" $name "*) continue ;;
  esac
  # Two different findings, and saying the wrong one sends the reader looking
  # for a stack that is right there. A domain moved to Certs="external" is
  # still declared; what it no longer has is a certificate this machine issues.
  case "$external_now" in
    *" $name "*) why="the stack declares it Certs=external" ;;
    *)           why="no stack declares that domain" ;;
  esac
  if [ "$PRUNE" -eq 1 ]; then
    rm -rf "$d" && printf '  [ok] %s — config removed, %s (the certificate in state/certs is untouched)\n' "$name" "$why"
  else
    printf '  [!] %s — a config exists, but %s' "$name" "$why"
    [ "$CHECK_ONLY" -eq 1 ] && printf ' (certs.sh --prune)'
    printf '\n'
  fi
done

# ------------------------------------------------------- 2. placeholders

echo
echo "== placeholder certificates"
[ "$CHECK_ONLY" -eq 1 ] || mkdir -p "$CERTS_DIR"

# Generating dhparam from scratch takes minutes, so only when the file really
# is absent.
if [ ! -f "$CERTS_DIR/dhparam.pem" ]; then
  if [ "$CHECK_ONLY" -eq 1 ]; then
    lack "dhparam.pem"
  else
    note "generating dhparam.pem (4096 bit), this takes a couple of minutes"
    openssl dhparam -out "$CERTS_DIR/dhparam.pem" 4096 2>/dev/null
  fi
fi

if [ ! -f "$CERTS_DIR/nginx-selfsigned.key" ]; then
  if [ "$CHECK_ONLY" -eq 1 ]; then
    lack "nginx-selfsigned.key"
  else
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
      -subj "/C=US/ST=New York/L=New York City/O=devbox/OU=devbox/CN=devbox" \
      -keyout "$CERTS_DIR/nginx-selfsigned.key" \
      -out "$CERTS_DIR/nginx-selfsigned.crt"
    note "created the base self-signed certificate"
  fi
fi

# The files the vhosts expect. The source of truth is the nginx configs
# themselves: ssl_certificate/ssl_certificate_key may name anything, and
# deriving the names from domains would be guesswork.
#
# A key is told from a certificate by its extension rather than by the order of
# two passes: `grep 'ssl_certificate\s'` also matches ssl_certificate_key
# lines, and then the result depends on which loop ran first.
while IFS= read -r path; do
  [ -n "$path" ] || continue
  filename=$(basename "$path")
  [ -f "$CERTS_DIR/$filename" ] && continue
  if [ "$CHECK_ONLY" -eq 1 ]; then
    lack "$filename (expected by a vhost)"
  else
    case "$filename" in
      *.key) cp "$CERTS_DIR/nginx-selfsigned.key" "$CERTS_DIR/$filename" ;;
      *)     cp "$CERTS_DIR/nginx-selfsigned.crt" "$CERTS_DIR/$filename" ;;
    esac
    note "placeholder: $filename"
  fi
done < <(stacks_cert_paths | awk '{print $2}' | tr -d ';' | sort -u)

# ------------------------------------------------- 3. the ACME account

# A check, not a creation. getssl creates the account key itself on first use,
# but it creates it RELATIVE to the current directory (ACCOUNT_KEY is a
# relative path in the shared getssl.cfg). Running from the wrong directory
# creates a new ACME account and loses the existing one — a silent failure,
# which is why it is named out loud.
echo
echo "== ACME account"
if ! stacks_getssl_any; then
  # No account is needed where no challenge is ever answered, and advice about
  # an account key nobody will use is the same noise this script exists to
  # remove from the other sections.
  note "not needed — every domain is Certs=external"
elif [ -f "$GETSSL_DIR/account.key" ]; then
  # The mode matters as much as the presence: this key can revoke the machine's
  # certificates.
  perm=$(stat -c '%a' "$GETSSL_DIR/account.key" 2>/dev/null || stat -f '%OLp' "$GETSSL_DIR/account.key")
  case "$perm" in
    600|400) note "account.key present ($perm)" ;;
    *) lack "account.key has mode $perm instead of 600 — chmod 600 $GETSSL_DIR/account.key" ;;
  esac
else
  printf '  [!] %s\n' "no $GETSSL_DIR/account.key — getssl will create a new account on its next run"
  printf '  %s\n' "If an account already existed, find its key and put it here rather than issuing a new one."
fi

if [ "$problems" -gt 0 ]; then
  echo
  echo "Missing: $problems. Run without --check." >&2
  exit 1
fi
echo
echo "Done."
