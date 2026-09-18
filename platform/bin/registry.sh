#!/usr/bin/env bash

# External image registries: logging in, pinning a moving tag to a digest, and
# checking both.
#
# Why this exists. A registry token is short-lived, so `docker login` by hand is
# a mechanism with an expiry date that somebody has to watch, and a forgotten
# login shows up as a failed pull in the middle of a deploy. So there is no
# "log in beforehand" here at all: it is built into the one path that pulls
# images — docker-compose.sh calls `registry.sh login --soft` before any
# command that might reach a registry.
#
# The same reasoning gives the second rule: a stack runs from a DIGEST, not
# from a moving tag. With a moving tag, `up -d` uses whatever is cached
# locally, drifts from the registry silently, and leaves nowhere to roll back
# to — the previous tag no longer exists. The digest in stacks/<stack>/.env
# answers "what is running right now" and provides the rollback: restore the
# previous line and `up -d`.
#
#   ./platform/bin/registry.sh login          log in to every registry the enabled stacks use
#   ./platform/bin/registry.sh pin <stack>    Image_Tag -> digest in stacks/<stack>/.env
#   ./platform/bin/registry.sh --check        what is wrong, changing nothing (exit 1)
#
# Registries other than ECR are not logged in to by this script, and it says so
# out loud: each has its own command for issuing a password, and there is
# nothing here to guess it with.

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

# shellcheck source=platform/lib/lib-stacks.sh
. "$LIB_DIR/lib-stacks.sh"
# shellcheck source=platform/lib/lib-env.sh
. "$LIB_DIR/lib-env.sh"

problems=0
ok()   { printf '  [ok]   %s\n' "$1"; }
warn() { printf '  [!]    %s\n' "$1"; }
bad()  { printf '  [FAIL] %s\n' "$1"; problems=$((problems + 1)); }
step() { echo; echo "== $1"; }

# A stamp of the last login. In /tmp deliberately: this is exactly ephemeral
# state — after a reboot one extra login costs nothing, and the stamp has no
# reason to survive one. The TTL is shorter than the token's lifetime, with
# room to spare for a long deploy.
STAMP_TTL=$((8 * 3600))
stamp_file() { printf '%s/devbox-registry-login-%s-%s' "${TMPDIR:-/tmp}" "$(id -u)" "${1//[^A-Za-z0-9._-]/_}"; }

# The ECR region is derived from the host name
# (<id>.dkr.ecr.<region>.amazonaws.com) rather than declared separately: a
# second place holding the same knowledge would drift from the image.
ecr_region() {
  case "$1" in
    *.dkr.ecr.*.amazonaws.com) local r="${1#*.dkr.ecr.}"; printf '%s' "${r%.amazonaws.com}" ;;
    *) return 1 ;;
  esac
}

# ------------------------------------------------------------------- login

# registry_login <host> <soft?>
registry_login() {
  local host="$1" soft="$2" region stamp
  stamp="$(stamp_file "$host")"

  if [ -f "$stamp" ] && [ $(( $(date +%s) - $(stat -c %Y "$stamp" 2>/dev/null || stat -f %m "$stamp") )) -lt "$STAMP_TTL" ]; then
    [ "$soft" -eq 1 ] || ok "$host — login is recent (less than $((STAMP_TTL / 3600))h old)"
    return 0
  fi

  if ! region="$(ecr_region "$host")"; then
    if [ "$soft" -eq 1 ]; then
      echo "Warning: $host is not ECR, this script does not log in to it; log in yourself" >&2
    else
      bad "$host is not ECR: every registry has its own way of issuing a password, log in by hand"
    fi
    return 0
  fi

  if ! command -v aws >/dev/null 2>&1; then
    if [ "$soft" -eq 1 ]; then
      echo "Warning: no aws command — did not log in to $host, a pull will fail" >&2
      return 0
    fi
    bad "no aws command — nothing to log in to $host with"
    return 1
  fi

  if aws ecr get-login-password --region "$region" 2>/dev/null \
     | docker login --username AWS --password-stdin "$host" >/dev/null 2>&1; then
    : > "$stamp"
    [ "$soft" -eq 1 ] || ok "$host — logged in"
    return 0
  fi

  # The machine takes its permissions from the instance's IAM role; a role that
  # has fallen off looks exactly like a working one until the first call — so
  # the cause is named here rather than surfacing later as an obscure pull
  # error.
  if [ "$soft" -eq 1 ]; then
    echo "Warning: could not log in to $host (instance IAM role? ecr:GetAuthorizationToken?) — a pull will fail" >&2
    return 0
  fi
  bad "$host — login failed; check the instance IAM role and the ecr:GetAuthorizationToken permission"
  return 1
}

verb_login() {
  local soft=0 host any=0 hosts
  if [ "${1:-}" = "--soft" ]; then soft=1; fi
  # Разбиение на слова здесь намеренное: stacks_enabled отдаёт список стеков.
  # shellcheck disable=SC2046
  hosts="$(stacks_registries $(stacks_enabled 2>/dev/null) 2>/dev/null)"
  while IFS= read -r host; do
    [ -n "$host" ] || continue
    any=1
    registry_login "$host" "$soft" || true
  done <<< "$hosts"
  if [ "$any" -eq 0 ] && [ "$soft" -eq 0 ]; then
    ok "ни один включённый стек не тянет образы из внешнего реестра"
  fi
  if [ "$soft" -eq 1 ]; then return 0; fi
  return $(( problems > 0 ))
}

# ---------------------------------------------------------------- parsing

# A stack has exactly one image reference in an external registry. More than
# one would mean the stack pulls two different applications and pin would not
# know which of them it is pinning; fewer means there is nothing to pin.
stack_registry_image() {
  local imgs
  imgs="$(stack_registry_images "$1")"
  [ -n "$imgs" ] || return 1
  printf '%s' "$imgs" | head -n 1
}

# The name of the digest variable comes from the reference itself
# (`<repository>@${VARIABLE}`). There is deliberately no separate declaration:
# the variable's name is already written in compose.yaml, and a second place
# holding it would drift silently.
image_digest_var() {
  case "$1" in
    *@\$\{*) local v="${1#*@\$\{}"; v="${v%%\}*}"; printf '%s' "${v%%:*}" ;;
    *) return 1 ;;
  esac
}

image_repo_path() { local v="${1%%@*}"; v="${v%%:*}"; printf '%s' "${v#*/}"; }

# ---------------------------------------------------------------------- pin

verb_pin() {
  local s="${1:-}" img host region repo var tag digest envf cur tmp
  [ -n "$s" ] || { echo "Usage: $0 pin <stack>" >&2; exit 2; }
  stack_exists "$s" || { echo "Error: no such stack '$s'" >&2; exit 2; }

  img="$(stack_registry_image "$s")" \
    || { echo "Error: stack '$s' pulls no image from an external registry — nothing to pin" >&2; exit 2; }
  var="$(image_digest_var "$img")" \
    || { echo "Error: the image of stack '$s' is not given as a digest ($img) — pinning does not apply" >&2; exit 2; }
  tag="$(stack_image_tag "$s")"
  [ -n "$tag" ] || { echo "Error: stack '$s' declares no Image_Tag= in stack.conf — there is no tag to follow" >&2; exit 2; }

  host="$(image_registry "$img")"
  region="$(ecr_region "$host")" \
    || { echo "Error: $host is not ECR, this script cannot resolve a tag into a digest there" >&2; exit 2; }
  repo="$(image_repo_path "$img")"

  registry_login "$host" 0 >/dev/null || true

  digest="$(aws ecr describe-images --region "$region" --repository-name "$repo" \
              --image-ids "imageTag=$tag" --query 'imageDetails[0].imageDigest' \
              --output text 2>/dev/null || true)"
  case "$digest" in
    sha256:*) ;;
    *) echo "Error: $host/$repo has no image tagged '$tag' (or ecr:DescribeImages is not permitted)" >&2; exit 1 ;;
  esac

  envf="$(stack_env_file "$s")"
  [ -f "$envf" ] || { echo "Error: no $envf — create it from the example" >&2; exit 2; }

  ENV_VARS=(); env_load_files "$envf" >/dev/null 2>&1 || true
  cur="$(env_get "$var")"
  if [ "$cur" = "$digest" ]; then
    echo "$s: already at $digest (tag $tag) — nothing to change"
    return 0
  fi

  # Rewritten through a temporary file and `cat > original`: the inode and mode
  # 600 are preserved, and .env holds passwords — losing them to an mv would be
  # expensive.
  tmp="$(mktemp)"
  trap 'rm -f "$tmp"' RETURN
  if grep -qE "^[[:space:]]*${var}=" "$envf"; then
    awk -v var="$var" -v val="$digest" '
      $0 ~ "^[[:space:]]*" var "=" { print var "=" val; next } { print }
    ' "$envf" > "$tmp"
  else
    { cat "$envf"; printf '%s=%s\n' "$var" "$digest"; } > "$tmp"
  fi
  cat "$tmp" > "$envf"

  echo "$s: $var"
  echo "  was: ${cur:-<unset>}"
  echo "  now: $digest   (tag $tag)"
  echo
  echo "Apply:    ./dc up -d $(stack_services "$s" | tr '\n' ' ')"
  echo "Roll back: restore the previous line in $envf and run up -d again"
}

# -------------------------------------------------------------------- check

verb_check() {
  local host s img var tag region repo cur envf latest

  step "Registries"
  if [ -z "$(stacks_registries)" ]; then
    ok "no stack pulls images from an external registry — nothing to check"
    return 0
  fi
  while IFS= read -r host; do
    [ -n "$host" ] || continue
    if ! region="$(ecr_region "$host")"; then
      warn "$host is not ECR: logging in and pinning are manual, nothing here can verify them"
      continue
    fi
    if ! command -v aws >/dev/null 2>&1; then
      bad "no aws command — neither logging in nor resolving a tag into a digest is possible"
      continue
    fi
    # The only honest question about permissions: is a token issued RIGHT NOW?
    # The presence of an IAM role, a profile and a network guarantees nothing
    # separately.
    if aws ecr get-authorization-token --region "$region" >/dev/null 2>&1; then
      ok "$host — a token is issued (region $region)"
    else
      bad "$host — no token is issued: check the instance IAM role and ecr:GetAuthorizationToken"
    fi
  done < <(stacks_registries)

  step "Images of the enabled stacks"
  local seen=0
  while IFS= read -r s; do
    img="$(stack_registry_image "$s")" || continue
    seen=$((seen + 1))
    host="$(image_registry "$img")"
    region="$(ecr_region "$host")" || { warn "$s: $host is not ECR, stopping here"; continue; }
    repo="$(image_repo_path "$img")"

    tag="$(stack_image_tag "$s")"
    [ -n "$tag" ] || bad "$s: no Image_Tag= in stack.conf — registry.sh pin has no tag to follow"

    if ! var="$(image_digest_var "$img")"; then
      warn "$s: the image is given by tag ($img) rather than by digest — up -d will use the local copy and drift from the registry silently"
      continue
    fi

    envf="$(stack_env_file "$s")"
    # ENV_VARS is declared in lib-env.sh and filled by the loader; it is cleared
    # before each stack, otherwise the previous stack's values leak into the
    # next one.
    # shellcheck disable=SC2034
    ENV_VARS=(); env_load_files "$envf" >/dev/null 2>&1 || true
    cur="$(env_get "$var")"
    case "$cur" in
      sha256:*) ;;
      '') bad "$s: $var is not set in $(basename "$(dirname "$envf")")/.env — compose will not build; ./platform/bin/registry.sh pin $s"; continue ;;
      *)  bad "$s: $var=$cur does not look like a digest (sha256:... expected)"; continue ;;
    esac

    command -v aws >/dev/null 2>&1 || continue

    # A pinned digest can disappear from the registry under a retention policy.
    # While the image is still cached locally this is invisible — and it
    # surfaces exactly when the container has to be recreated, that is, at the
    # worst moment.
    if aws ecr describe-images --region "$region" --repository-name "$repo" \
         --image-ids "imageDigest=$cur" >/dev/null 2>&1; then
      ok "$s: the pinned image is present in the registry"
    else
      bad "$s: image $cur is gone from $host/$repo — there would be nothing to recreate the container from; ./platform/bin/registry.sh pin $s"
    fi

    if docker image inspect "${img%%@*}@$cur" >/dev/null 2>&1; then
      ok "$s: the image is present locally"
    else
      warn "$s: the image is not present locally — the next up -d will reach for the registry"
    fi

    [ -n "$tag" ] || continue
    latest="$(aws ecr describe-images --region "$region" --repository-name "$repo" \
                --image-ids "imageTag=$tag" --query 'imageDetails[0].imageDigest' \
                --output text 2>/dev/null || true)"
    case "$latest" in
      sha256:*)
        if [ "$latest" = "$cur" ]; then
          ok "$s: the pin matches tag '$tag'"
        else
          warn "$s: the registry holds a different image under tag '$tag' — ./platform/bin/registry.sh pin $s"
        fi ;;
      *) warn "$s: $host/$repo has no tag '$tag' — there is nothing to follow" ;;
    esac
  done < <(stacks_enabled 2>/dev/null)
  # Zero stacks is not "all is well" but "there was nothing to look at": on a
  # machine without .env-stacks nobody counts as enabled, and silence here
  # would read as health.
  if [ "$seen" -eq 0 ]; then
    warn "no ENABLED stack pulls images from an external registry — there was nothing to check"
  fi

  echo
  if [ "$problems" -eq 0 ]; then echo "Registries: no problems"; else echo "Registries: problems — $problems"; fi
  return $(( problems > 0 ))
}

case "${1:-}" in
  login)   shift; verb_login "$@" ;;
  pin)     shift; verb_pin "$@" ;;
  --check) verb_check ;;
  ""|-h|--help)
    sed -n '3,25p' "$0" | sed 's/^# \{0,1\}//'
    exit 2 ;;
  *) echo "Unknown command: $1" >&2; exit 2 ;;
esac
