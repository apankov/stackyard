#!/usr/bin/env bash

# Enabling and disabling stacks with one command instead of three manual steps.
#
# There is one source of truth — Enabled_Stacks in .env-stacks. This script
# brings both compose and nginx in line with it, in the right order: when
# enabling, the application first and the vhost second; when disabling, the
# vhost first and the containers second. At no point does nginx hold a vhost
# whose upstream is not running.
#
# Doing the same by hand — editing compose files, vhosts and containers
# separately — means three places with no shared source of truth. Any drift
# between them produces `host not found in upstream`, an nginx crash loop, and
# every site on the machine at once.
#
#   ./stack list                # what is enabled and what is actually alive
#   ./stack enable  <stack>...  # enable and bring up
#   ./stack disable <stack>...  # stop; data and images are left intact
#   ./stack purge   <stack>     # also volumes and images; asks for confirmation
#   ./stack sync                # bring nginx in line with the manifest
#   ./stack --check             # check only, non-zero exit on problems
#
# Flags: --dry-run (print the commands, change nothing),
#        --no-start (config only, do not start containers) — for enable.
#
# What this script NEVER does, in any mode: it does not touch data in bind
# mounts, and it does not drop databases from the shared DBMS. Reclaiming space
# there is a manual step, using the commands `purge` prints.

set -euo pipefail

DIR0="$( cd -P "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# The MACHINE's directory, not the platform's. Normally set by the ./stack
# wrapper in the machine root; the fallback is two levels up from platform/bin,
# so the script also works when invoked directly.
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

MANIFEST="$ROOT_DIR/.env-stacks"

# State directories, before any command that writes into them. On a fresh
# machine they do not exist at all, and the first write would die with a raw
# shell error.
ensure_state_dirs
DRY_RUN=0
NO_START=0
NO_UNITS=0
PROBLEMS=0
WARNINGS=0

# The limit for a stack's scripts/health.sh. A liveness check has to be fast:
# --check is run both by hand and from monitoring, and a hung stack script
# would hang the whole report with it.
HEALTH_TIMEOUT=10

ok()   { printf '  [ok]   %s\n' "$1"; }
warn() { printf '  [!]    %s\n' "$1"; WARNINGS=$((WARNINGS + 1)); }
bad()  { printf '  [FAIL] %s\n' "$1"; PROBLEMS=$((PROBLEMS + 1)); }
step() { printf '\n== %s\n' "$1"; }
die()  { echo "Error: $*" >&2; exit 1; }

# Everything that changes the machine goes through run(): that way --dry-run
# covers docker and file writes alike, and no branch has to remember it.
run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '  [dry] %s\n' "$*"
    return 0
  fi
  "$@"
}

# Bring the systemd units in line with the manifest.
#
# Installing and removing them is systemd.sh's job and nobody else's: it alone
# knows about placeholders, OnFailure and a stack's preflight. All that is
# decided here is whether to call it — as root, because /etc/systemd/system
# cannot be touched otherwise.
#
# If root is unavailable the operation is NOT cancelled: the stack is already
# enabled or disabled, and the units remain a discrepancy that --check will
# name. Leaving it silent is not an option — a forgotten timer of a disabled
# stack wakes the machine every night, and from the outside that looks like
# normal operation.
units_apply() {
  local reason="$1" cmd=("$DIR0/systemd.sh")
  [ "$(id -u)" -eq 0 ] || cmd=(sudo "${cmd[@]}")

  if [ "$NO_UNITS" -eq 1 ]; then
    warn "--no-units: units left untouched — ${cmd[*]}"
    return 0
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '  [dry] %s\n' "${cmd[*]}"
    return 0
  fi
  if [ "$(id -u)" -ne 0 ] && ! command -v sudo >/dev/null 2>&1; then
    warn "no sudo — units left as they were: ${cmd[*]}"
    return 0
  fi

  echo "  $reason"
  if "${cmd[@]}" 2>&1 | sed 's/^/      /'; then
    ok "units match the manifest"
  else
    warn "systemd.sh did not complete — rerun by hand: ${cmd[*]}"
  fi
}

# A row of the stack table. The widths are declared once, here, so the header
# and the data cannot drift apart when either is edited.
_row() {
  printf '%s%s%s%s%s\n' \
    "$(_cell "$1" 13)" "$(_cell "$2" 10)" "$(_cell "$3" 24)" "$(_cell "$4" 14)" "$5"
}

usage() {
  cat <<'USAGE'
Enable and disable stacks. The source of truth is Enabled_Stacks in
.env-stacks; this script brings both docker compose and nginx in line with it.

  stack list                  what is enabled, what is running, what has vhosts
  stack enable  <stack>...    enable: manifest -> containers -> vhost -> units
  stack disable <stack>...    disable: manifest -> units -> vhost -> containers
                              (volumes, images and data stay; enable restores it)
  stack purge   <stack>       also remove volumes and images; irreversible,
                              asks for the stack name (data in bind mounts and
                              databases in the shared DBMS are left alone)
  stack sync                  bring the nginx vhosts in line with the manifest
  stack --check               check only, exit code 1 on problems

  --dry-run     print what would be done and change nothing
  --no-start    for enable: configuration only, do not start containers
  --no-units    leave the systemd units alone (otherwise enable/disable call
                sudo ./platform/bin/systemd.sh themselves; --check reports drift)
USAGE
  exit "${1:-2}"
}

# ---------------------------------------------------------------- manifest

# Rewrite Enabled_Stacks while preserving the rest of the file: the comments in
# .env-stacks explain how to use it, and erasing them on every enable would be
# a poor trade.
manifest_write() {
  local stacks="$*" tmp
  # From this point every derived value (nginx includes, dependency checks) is
  # computed from the NEW set — in normal mode and under --dry-run alike.
  STACKS_ENABLED_OVERRIDE="$stacks"
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '  [dry] Enabled_Stacks="%s" (file left untouched)\n' "$stacks"
    return 0
  fi
  tmp=$(mktemp)
  if [ -f "$MANIFEST" ] && grep -qE '^[[:space:]]*Enabled_Stacks=' "$MANIFEST"; then
    awk -v val="Enabled_Stacks=\"$stacks\"" '
      /^[[:space:]]*Enabled_Stacks=/ { if (!done) { print val; done = 1 } next }
      { print }
    ' "$MANIFEST" > "$tmp"
  else
    [ -f "$MANIFEST" ] && cat "$MANIFEST" > "$tmp"
    {
      [ -f "$MANIFEST" ] || cat "$ROOT_DIR/.env-stacks.example" 2>/dev/null | sed '/^Enabled_Stacks=/d'
      printf 'Enabled_Stacks="%s"\n' "$stacks"
    } >> "$tmp"
  fi
  cat "$tmp" > "$MANIFEST"
  rm -f "$tmp"
  ok "Enabled_Stacks: $stacks"
}

# ------------------------------------------------------------------ nginx

nginx_running() {
  [ "$(docker inspect -f '{{.State.Status}}' nginx 2>/dev/null || true)" = "running" ]
}

# The shared DBMS's database list, from the declarations of enabled stacks.
#
# A separate function rather than a line inside nginx_apply: it has nothing to
# do with nginx and is called from there only because that is where all the
# generated files are produced. Mode 600 is mandatory — the file holds
# passwords.
databases_apply() {
  local f content
  f="$(stacks_databases_file)"
  # Empty means no provider is enabled. That is a legitimate state: a machine
  # with a single proxy stack needs no shared DBMS. Testing the DIRECTORY
  # instead would not work: dirname of an empty string is ".", which always
  # exists, and the write would then be `> ""` — a raw shell error on the very
  # first command such a machine runs.
  [ -n "$f" ] || { ok "no shared-DB provider — there is no database list to build"; return 0; }
  mkdir -p "$(dirname "$f")"
  content="$(stacks_databases_content)"
  if [ -f "$f" ] && [ "$(cat "$f")" = "$content" ]; then
    ok "databases already match the declarations"
  elif [ "$DRY_RUN" -eq 1 ]; then
    printf '  [dry] rewrite %s\n' "$f"
  else
    printf '%s' "$content" > "$f"
    chmod 600 "$f"
    ok "rewrote $(basename "$f") (chmod 600)"
  fi
}

# Rebuild the include file and reload nginx. Reload, not recreate: the vhost
# directory is mounted from the host, and recreating the container is a
# separate way to take every site down.
#
# `nginx -t` before the reload, and a rollback of the include file if it fails,
# because a reload with a broken config is simply not applied — nginx keeps
# running with the old one, while the next container restart, for any reason,
# would no longer come up.
nginx_apply() {
  local file backup content static_file static_content junk
  file="$(stacks_include_file)"
  content="$(stacks_include_content)"

  # Before anything else: a stray directory next to the include file is read by
  # nginx through the *.conf glob and sends it into a crash loop. Writing
  # configs on top of that is pointless — nginx -t would fail, and the cause
  # would be buried under the rollback.
  junk="$(check_vhost_dir "$(dirname "$file")")"
  if [ -n "$junk" ]; then
    printf '%s' "$junk" | while IFS= read -r l; do [ -n "$l" ] && bad "$l"; done
    die "the vhost directory contains something that is not a file — remove it and retry"
  fi

  # Static content first. It is part of the nginx SPEC, so changing it makes
  # the next `up -d` recreate the container, whereas the includes are read by
  # the already running nginx on reload. The output order reflects that
  # difference: first what can cause nginx to be recreated, then what merely
  # causes a reload.
  #
  # The content is computed across ALL stacks, so it changes here only when a
  # stack.conf is edited, not on enable/disable — see stacks_static_content().
  static_file="$(stacks_static_file)"
  static_content="$(stacks_static_content)"
  if [ -f "$static_file" ] && [ "$(cat "$static_file")" = "$static_content" ]; then
    ok "nginx static content already matches the declarations"
  elif [ "$DRY_RUN" -eq 1 ]; then
    printf '  [dry] rewrite %s\n' "$static_file"
  else
    mkdir -p "$(dirname "$static_file")"
    printf '%s' "$static_content" > "$static_file"
    ok "rewrote $(basename "$static_file")"
  fi

  databases_apply

  if [ -f "$file" ] && [ "$(cat "$file")" = "$content" ]; then
    ok "nginx vhosts already match the manifest"
  else
    if [ "$DRY_RUN" -eq 1 ]; then
      printf '  [dry] rewrite %s:\n' "$file"
      printf '%s\n' "$content" | grep '^include' | sed 's/^/          /'
    else
      backup=$(mktemp)
      [ -f "$file" ] && cat "$file" > "$backup"
      printf '%s\n' "$content" > "$file"
      ok "rewrote $(basename "$file")"
    fi
  fi

  certs_stubs_if_needed

  if ! nginx_running; then
    warn "the nginx container is not running — nothing to reload; start it: ./dc up -d nginx"
    [ -n "${backup:-}" ] && rm -f "$backup"
    return 0
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    printf '  [dry] docker exec nginx nginx -t && docker exec nginx nginx -s reload\n'
    return 0
  fi

  if ! docker exec nginx nginx -t >/dev/null 2>&1; then
    echo "  [FAIL] nginx -t failed, rolling back $(basename "$file")" >&2
    docker exec nginx nginx -t || true
    if [ -n "${backup:-}" ] && [ -s "$backup" ]; then
      cat "$backup" > "$file"
    else
      rm -f "$file"
    fi
    [ -n "${backup:-}" ] && rm -f "$backup"
    die "the nginx config did not build; vhost changes were rolled back, containers untouched"
  fi
  # Not `rm -f "${backup:-}"`: with an empty argument rm returns 1, and under
  # set -e that would abort the script right before the reload — the worst
  # possible place.
  [ -n "${backup:-}" ] && rm -f "$backup"

  docker exec nginx nginx -s reload
  ok "nginx reloaded"
}

# Placeholder certificates BEFORE nginx sees a new vhost, otherwise it does not
# start. certs.sh is invoked only when something is actually missing:
# generating dhparam from scratch takes minutes.
certs_stubs_if_needed() {
  local certs_dir="$ROOT_DIR/state/certs" missing=0 path
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    [ -f "$certs_dir/$(basename "$path")" ] || missing=1
  done < <(stacks_cert_paths | awk '{print $2}' | tr -d ';' | sort -u)

  [ "$missing" -eq 0 ] && return 0
  warn "certificate files are missing — running platform/bin/certs.sh (placeholders)"
  run "$DIR0/certs.sh"
}

# ------------------------------------------------------------- containers

# All of a stack's containers (stopped ones included), by compose labels.
stack_containers() {
  local s="$1" svc
  while IFS= read -r svc; do
    [ -n "$svc" ] || continue
    service_containers "$svc"
  done < <(stack_services "$s" 2>/dev/null)
}

stack_running() {
  local s="$1" id n=0
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    [ "$(docker inspect -f '{{.State.Status}}' "$id" 2>/dev/null)" = "running" ] && n=$((n + 1))
  done < <(stack_containers "$s")
  printf '%s' "$n"
}

# Removing a stack's containers.
#
# Removal rather than `stop`: watch-host.sh walks `docker ps -a` and raises a
# critical alert for a stopped container declared restart: always. A disabled
# stack would therefore look like an incident around the clock.
#
# And `docker rm -f` by label rather than `docker compose rm`: by this point
# the stack has already been struck from the manifest, its file is no longer
# included, and there is nothing to ask compose to remove. The compose labels
# are still there — they live on the containers themselves.
containers_remove() {
  local s="$1" ids
  ids=$(stack_containers "$s" | tr '\n' ' ')
  ids=$(echo $ids)
  if [ -z "$ids" ]; then
    ok "stack '$s' has no containers"
    return 0
  fi
  # shellcheck disable=SC2086
  run docker rm -f $ids
  ok "removed containers: $(echo $ids | wc -w | tr -d ' ')"
}

# ---------------------------------------------------------------- verbs

verb_list() {
  local s enabled_list missing running vhosts mark files
  enabled_list=" $(stacks_enabled 2>/dev/null | tr '\n' ' ') "

  _row "STACK" "MANIFEST" "FILES" "CONTAINERS" "VHOSTS"
  while IFS= read -r s; do
    case "$enabled_list" in *" $s "*) mark="on" ;; *) mark="off" ;; esac

    missing="$(stack_missing_files "$s" | tr '\n' ',' | sed 's/,$//')"
    files="ok"; [ -n "$missing" ] && files="missing: $missing"

    running="$(stack_running "$s")"
    total="$(stack_services "$s" 2>/dev/null | grep -c . || true)"

    vhosts="-"
    if [ -d "$(stack_vhost_dir "$s")" ]; then
      n=$(ls -1 "$(stack_vhost_dir "$s")"/*.conf 2>/dev/null | grep -c . || true)
      if [ "$n" -gt 0 ]; then
        if stack_vhost_enabled "$s"; then
          vhosts="$n (on)"
        else
          vhosts="$n (off)"
        fi
      fi
    fi

    _row "$s" "$mark" "$files" "$running/$total" "$vhosts"
  done < <(stacks_available)

  printf '\nManifest: %s\n' "$([ -f "$MANIFEST" ] && echo "$MANIFEST" || echo 'NONE (every stack with a complete file set counts as enabled)')"
}

verb_enable() {
  local want=() s req add enabled_now new_list svc_args=()
  want=("$@")

  for s in "${want[@]}"; do
    stack_exists "$s" || die "no such stack: '$s' (see ./stack list)"
  done

  # Dependencies are added automatically: enabling an application without the
  # database it requires is not a choice but a forgotten step, and it surfaces
  # as a container that will not start.
  for s in "${want[@]}"; do
    for req in $(stack_requires "$s"); do
      case " ${want[*]} " in *" $req "*) continue ;; esac
      if ! stack_is_enabled "$req"; then
        echo "Stack '$s' requires '$req' — enabling that too."
        want+=("$req")
      fi
    done
  done

  for s in "${want[@]}"; do
    missing="$(stack_missing_files "$s" | tr '\n' ' ')"
    [ -n "$(echo $missing)" ] && die "stack '$s' is missing files: $missing"
  done

  enabled_now="$(stacks_enabled 2>/dev/null | tr '\n' ' ')"
  new_list="$enabled_now"
  for s in "${want[@]}"; do
    case " $new_list " in *" $s "*) echo "Stack '$s' is already enabled — reconciling state." ;; *) new_list="$new_list $s" ;; esac
  done

  step "Manifest"
  manifest_write $(echo $new_list)

  # Database declarations BEFORE the containers: the initializer reads
  # databases.yaml at startup, so generating the file later (in nginx_apply, as
  # usual) would leave the initializer working from the previous list.
  step "Shared databases"
  databases_apply

  # The application first, the vhost second. The reverse order gives nginx a
  # proxy_pass to a container that does not exist — a crash loop taking every
  # site with it.
  if [ "$NO_START" -eq 1 ]; then
    step "Containers"
    warn "--no-start: not starting containers"
  else
    step "Containers"
    for s in "${want[@]}"; do
      while IFS= read -r svc; do
        [ -n "$svc" ] && svc_args+=("$svc")
      done < <(stack_services "$s")
    done

    # A stack that declares a database cannot work until the user and database
    # exist, and they are created by the initializer — the provider's one-shot
    # container. The provider itself is usually already enabled, so it does not
    # appear in the list being started, and the application comes up pointing
    # at a database that does not exist: restarts and authentication failures
    # in its log.
    for s in "${want[@]}"; do
      [ -n "$(stack_conf_get "$s" "$(stacks_db_prefix)_DB")" ] || continue
      case " ${svc_args[*]} " in
        *" $(stacks_db_init_service) "*) ;;
        *) svc_args+=("$(stacks_db_init_service)") ;;
      esac
      break
    done

    if [ ${#svc_args[@]} -eq 0 ]; then
      warn "the stacks declare no services — nothing to start"
    else
      run env STACK_SH_APPLYING=1 "$DIR0/docker-compose.sh" up -d "${svc_args[@]}"
    fi
  fi

  step "nginx"
  nginx_apply

  # Units are installed AFTER the containers and the vhost: a stack's timer
  # calls scripts that need the stack running, and one that fires too early
  # raises an incident alert out of thin air.
  step "systemd units"
  local need_units=0 u
  for s in "${want[@]}"; do
    while IFS= read -r u; do
      [ -n "$u" ] || continue
      stack_units_installed "$s" | grep -qxF "$(basename "$u")" || need_units=1
    done < <(stack_units "$s")
  done
  if [ "$need_units" -eq 1 ]; then
    units_apply "installing units of the enabled stacks..."
  else
    ok "units for these stacks are already in place"
  fi
}

verb_disable() {
  local want=("$@") s dep deps new_list

  for s in "${want[@]}"; do
    stack_exists "$s" || die "no such stack: '$s' (see ./stack list)"
  done

  # Disabling a stack that other enabled stacks depend on is refused.
  # Otherwise the action reads as "I turned off the database" and is discovered
  # a week later as "the application stopped remembering anything".
  for s in "${want[@]}"; do
    deps=""
    while IFS= read -r dep; do
      [ -z "$dep" ] && continue
      case " ${want[*]} " in *" $dep "*) continue ;; esac
      deps="$deps $dep"
    done < <(stack_dependents "$s")
    [ -n "$(echo $deps)" ] && die "stack '$s' is required by enabled stacks:$deps — disable them together, or those first"
  done

  new_list=""
  for s in $(stacks_enabled 2>/dev/null); do
    case " ${want[*]} " in *" $s "*) continue ;; esac
    new_list="$new_list $s"
  done

  step "Manifest"
  manifest_write $(echo $new_list)

  # Units are removed BEFORE the containers: a timer firing between the
  # container's death and the unit's removal would run a script against a dead
  # stack and alert about an incident that does not exist. The manifest is
  # already updated by this point, so systemd.sh treats these stacks as
  # disabled on its own.
  step "systemd units"
  local installed=""
  for s in "${want[@]}"; do
    installed="$installed$(stack_units_installed "$s")"
  done
  if [ -n "$installed" ]; then
    units_apply "removing units of the stacks being disabled..."
  else
    ok "these stacks have no installed units"
  fi

  # The vhost first, the containers second: in the reverse order nginx is left
  # holding a vhost whose upstream is dead, and any restart in that window
  # takes every site down.
  step "nginx"
  nginx_apply

  step "Containers"
  for s in "${want[@]}"; do
    containers_remove "$s"
  done

  step "What was left in place"
  for s in "${want[@]}"; do
    # `|| true`: purge_plan returns 1 when there is nothing to remove, and
    # under set -e that would abort disable on its last, informational step.
    purge_plan "$s" report || true
  done
  echo
  echo "Data, volumes and images are untouched — to re-enable: ./stack enable ${want[*]}"
  echo "To reclaim space (irreversible): ./stack purge <stack>"
}

# An image repository without its tag. Values such as
# `app:${Image_Tag:-latest}` break the naive "cut after the last colon", so the
# substitution is stripped first.
image_repo() {
  local v="$1"
  if [[ "$v" == *'${'* ]]; then v="${v%%\$\{*}"; v="${v%:}"; fi
  case "${v##*:}" in
    "$v") printf '%s' "$v" ;;
    */*)  printf '%s' "$v" ;;
    *)    printf '%s' "${v%:*}" ;;
  esac
}

# A stack's images, minus those referenced by anyone else. A shared base image
# must not disappear because one stack was purged.
stack_own_images() {
  local s="$1" other="" o img repo proj svc
  while IFS= read -r o; do
    [ "$o" = "$s" ] && continue
    while IFS= read -r img; do
      [ -n "$img" ] && other="$other $(image_repo "$img")"
    done < <(stack_images "$o")
  done < <(stacks_available)
  while IFS= read -r img; do
    [ -n "$img" ] && other="$other $(image_repo "$img")"
  done < <(awk '/^[[:space:]]+image:[[:space:]]*[^[:space:]]/ { print $2 }' \
              "$ROOT_DIR/platform/compose/nginx.yaml" "$ROOT_DIR/platform/compose/nginx-static.generated.yaml" 2>/dev/null)

  # Candidates: the declared `image:` values plus the names compose gives to
  # images built from `build:` without an `image:`. Without the latter, purge
  # would leave behind the largest thing the stack occupies.
  {
    stack_images "$s"
    proj="$(compose_project)"
    while IFS= read -r svc; do
      [ -n "$svc" ] || continue
      printf '%s-%s\n' "$proj" "$svc"   # compose v2
      printf '%s_%s\n' "$proj" "$svc"   # compose v1 naming, for images left from that era
    done < <(stack_services "$s" 2>/dev/null)
  } | while IFS= read -r img; do
    [ -n "$img" ] || continue
    repo="$(image_repo "$img")"
    case " $other " in *" $repo "*) continue ;; esac
    printf '%s\n' "$repo"
  done | sort -u
}

# A stack's volumes, under the names docker actually gives them.
stack_docker_volumes() {
  local s="$1" v proj found
  proj="$(compose_project)"
  while IFS= read -r v; do
    [ -n "$v" ] || continue
    found=$(docker volume ls -q \
              --filter "label=com.docker.compose.project=$proj" \
              --filter "label=com.docker.compose.volume=$v" 2>/dev/null || true)
    if [ -z "$found" ] && docker volume inspect "${proj}_${v}" >/dev/null 2>&1; then
      found="${proj}_${v}"
    fi
    [ -n "$found" ] && printf '%s\n' "$found"
  done < <(stack_volumes "$s")
}

# Prints what purge will remove. mode=report only lists it.
purge_plan() {
  local s="$1" mode="${2:-plan}" v repo line n
  n=0

  while IFS= read -r v; do
    [ -n "$v" ] || continue
    printf '  volume %-42s %s\n' "$v" "$(docker volume inspect -f '{{.Mountpoint}}' "$v" 2>/dev/null || true)"
    n=$((n + 1))
  done < <(stack_docker_volumes "$s")

  while IFS= read -r repo; do
    [ -n "$repo" ] || continue
    while IFS= read -r line; do
      [ -n "$line" ] && printf '  image  %s\n' "$line" && n=$((n + 1))
    done < <(docker images --filter "reference=$repo" --format '{{.Repository}}:{{.Tag}}  {{.Size}}' 2>/dev/null | sort -u)
  done < <(stack_own_images "$s")

  if [ "$n" -eq 0 ]; then
    [ "$mode" = "report" ] && printf '  stack %s: no volumes or images found\n' "$s"
    return 1
  fi
  return 0
}

verb_purge() {
  local s="$1" answer v repo

  stack_exists "$s" || die "no such stack: '$s' (see ./stack list)"

  step "Will be removed IRREVERSIBLY (stack '$s')"
  local containers
  containers=$(stack_containers "$s" | grep -c . || true)
  printf '  containers: %s\n' "$containers"
  purge_plan "$s" || true

  step "Will be left in place"
  echo "  * data in bind mounts — this script never touches it"
  echo "  * databases in the shared DBMS. To reclaim those as well, do it BY HAND"
  echo "    with the provider's own client; this script never drops a database."
  echo "  * docker's build cache (cleaned separately: docker builder prune)"

  if [ "$DRY_RUN" -eq 1 ]; then
    step "--dry-run: no confirmation asked, nothing done"
    return 0
  fi

  # Confirmation by typing the stack's name rather than [y/N]: purge is
  # irreversible, and "y" is pressed on autopilot. Typing the name of the stack
  # about to disappear is exactly the pause this needs.
  if [ ! -t 0 ]; then
    die "purge requires an interactive terminal (it confirms by asking for the stack name)"
  fi
  step "Confirmation"
  printf 'Type the stack name to confirm (%s), or press Enter to cancel: ' "$s"
  IFS= read -r answer
  [ "$answer" = "$s" ] || die "cancelled (you typed '$answer')"

  # An ordinary disable first: manifest, nginx, containers. A volume cannot be
  # removed while a container holds it, and a vhost must not be left without
  # its upstream.
  if stack_is_enabled "$s"; then
    verb_disable "$s"
  else
    step "Containers"
    containers_remove "$s"
  fi

  step "Volumes"
  while IFS= read -r v; do
    [ -n "$v" ] && run docker volume rm "$v"
  done < <(stack_docker_volumes "$s")

  step "Images"
  while IFS= read -r repo; do
    [ -n "$repo" ] || continue
    while IFS= read -r img; do
      [ -n "$img" ] && run docker rmi "$img"
    done < <(docker images --filter "reference=$repo" --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | sort -u)
  done < <(stack_own_images "$s")

  step "Done"
  df -h /var/lib/docker 2>/dev/null | tail -n 1 || true
  echo "Stack '$s' has been purged. To restore: ./stack enable $s (the image must be rebuilt)"
}

verb_sync() {
  step "nginx"
  nginx_apply

  step "Drift from the manifest"
  local s running total
  while IFS= read -r s; do
    running="$(stack_running "$s")"
    total="$(stack_services "$s" 2>/dev/null | grep -c . || true)"
    if [ "$running" -eq 0 ] && [ "$total" -gt 0 ]; then
      warn "enabled but not running: $s — ./stack enable $s"
    fi
  done < <(stacks_enabled 2>/dev/null)

  while IFS= read -r s; do
    stack_is_enabled "$s" && continue
    running="$(stack_containers "$s" | grep -c . || true)"
    [ "$running" -gt 0 ] && warn "disabled but containers remain ($running): $s — ./stack disable $s"
  done < <(stacks_available)

  [ "$WARNINGS" -eq 0 ] && ok "no drift"
}

verb_check() {
  local s line fn up pair missing include_file junk_line awk_svc cfg_svc decl_problems_before
  local db_file perm init_state init_svc img_problem zone_problem

  step "Manifest"
  if [ -f "$MANIFEST" ]; then
    ok ".env-stacks is present"
    ok "enabled: $(stacks_enabled 2>/dev/null | tr '\n' ' ')"
  else
    warn "no .env-stacks — every stack with a complete file set counts as enabled (cp .env-stacks.example .env-stacks)"
  fi

  step "Files of the enabled stacks"
  while IFS= read -r s; do
    missing="$(stack_missing_files "$s" | tr '\n' ' ')"
    if [ -n "$(echo $missing)" ]; then
      bad "$s: missing $missing — every compose command fails"
    else
      ok "$s"
    fi
  done < <(stacks_enabled 2>/dev/null)

  step "Stack declarations"
  while IFS= read -r s; do
    if [ -f "$(stack_conf_file "$s")" ]; then
      ok "$s: stack.conf present"
    else
      bad "$s: no stack.conf — the stack declares nothing about itself"
    fi
  done < <(stacks_available)

  decl_problems_before="$PROBLEMS"
  while IFS= read -r line; do [ -n "$line" ] && bad "$line"; done < <(check_domains_unique)
  while IFS= read -r line; do [ -n "$line" ] && bad "$line"; done < <(check_databases_unique)

  while IFS= read -r s; do
    for fn in check_domains_match check_paths_absolute check_unit_names \
              check_timer_has_check check_no_base_service_merge check_requires_cycle \
              check_db_decl; do
      while IFS= read -r line; do [ -n "$line" ] && bad "$line"; done < <("$fn" "$s")
    done
    # This block keeps its own problem count: the global PROBLEMS may already
    # have grown on missing .env files, and then "all clear" would not be
    # printed even for perfectly clean declarations.
    :
  done < <(stacks_enabled 2>/dev/null)
  if [ "$PROBLEMS" -eq "$decl_problems_before" ]; then
    ok "domains, paths, unit names and dependencies are all consistent"
  fi

  step "The nginx image"
  # Before anything else about nginx: with an incompatible image it does not
  # start at all, and every other finding about it is moot.
  img_problem="$(check_nginx_image)"
  if [ -n "$img_problem" ]; then bad "$img_problem"; else ok "the image supports the platform's directives"; fi

  zone_problem="$(check_limit_zones)"
  if [ -n "$zone_problem" ]; then
    printf '%s\n' "$zone_problem" | while IFS= read -r l; do [ -n "$l" ] && bad "$l"; done
    PROBLEMS=$((PROBLEMS + 1))
  else
    ok "every rate-limit zone referenced by a vhost is defined"
  fi

  step "nginx static content"
  if [ ! -f "$(stacks_static_file)" ]; then
    bad "missing $(basename "$(stacks_static_file)") — ./stack sync"
  elif [ "$(cat "$(stacks_static_file)")" != "$(stacks_static_content)" ]; then
    bad "$(basename "$(stacks_static_file)") does not match stack.conf — ./stack sync"
  else
    ok "static content matches the declarations"
  fi

  step "Shared databases"
  # After check_db_decl, ENV_VARS holds the last stack's variables. Restore the
  # machine-level environment, or everything below that reads .env would see
  # another stack's values.
  ENV_VARS=(); env_load_files "$ROOT_DIR/.env" >/dev/null 2>&1 || true
  if [ -z "$(stacks_db_provider)" ]; then
    ok "no shared-DB provider enabled — there is nobody to create databases and no need to"
  else
    db_file="$(stacks_databases_file)"
    if [ ! -f "$db_file" ]; then
      bad "missing $(basename "$db_file") — $(stacks_db_init_service) will not start; ./stack sync"
    elif [ "$(cat "$db_file")" != "$(stacks_databases_content)" ]; then
      bad "$(basename "$db_file") does not match the declarations — ./stack sync"
    else
      ok "databases.yaml matches the declarations"
      # The mode matters as much as the contents: it holds every database
      # password on the machine.
      perm=$(stat -c '%a' "$db_file" 2>/dev/null || stat -f '%OLp' "$db_file")
      [ "$perm" = "600" ] || bad "$(basename "$db_file") has mode $perm instead of 600 — it contains passwords"
    fi

    # The initializer has no `restart: always`, so its failure is invisible from
    # the outside: the container simply shows as "exited". And it fails exactly
    # when the password in the database has drifted from the declared one — it
    # reports a breakage that would otherwise be found hours later, as an
    # authentication error in an application's log.
    init_svc="$(stacks_db_init_service)"
    init_state=$(docker inspect -f '{{.State.Status}}:{{.State.ExitCode}}' "$init_svc" 2>/dev/null || true)
    case "$init_state" in
      '')            warn "container $init_svc does not exist — has the provider ever been started?" ;;
      exited:0)      ok "$init_svc completed successfully" ;;
      running:*|created:*) warn "$init_svc is still running" ;;
      *)             bad "$init_svc exited with code ${init_state#*:} — docker logs $init_svc" ;;
    esac
  fi

  step "Upstreams of the enabled vhosts"
  # Recreating nginx while an upstream is down gives "host not found in
  # upstream", a refusal to start and, under restart: always, a crash loop
  # taking down EVERY vhost. This script starts containers before the vhost,
  # but only this check notices a container that was already down beforehand.
  while IFS= read -r up; do
    [ -n "$up" ] || continue
    if [ "$(docker inspect -f '{{.State.Status}}' "$up" 2>/dev/null || true)" = "running" ]; then
      ok "upstream $up is up"
    else
      bad "upstream $up is not running — recreating nginx would take down EVERY vhost"
    fi
  done < <(stacks_upstreams)

  step "nginx vhosts"
  include_file="$(stacks_include_file)"
  while IFS= read -r junk_line; do
    [ -n "$junk_line" ] && bad "$junk_line"
  done < <(check_vhost_dir "$(dirname "$include_file")")
  if [ ! -f "$include_file" ]; then
    bad "missing $(basename "$include_file") — after the next reload nginx would have NO vhosts at all; ./stack sync"
  elif [ "$(cat "$include_file")" != "$(stacks_include_content)" ]; then
    bad "$(basename "$include_file") does not match the manifest — ./stack sync"
  else
    ok "the includes match the manifest"
  fi

  if nginx_running; then
    if docker exec nginx nginx -t >/dev/null 2>&1; then
      ok "nginx -t passes"
    else
      bad "nginx -t FAILS — the container will not come up on its next restart"
    fi
  else
    bad "the nginx container is not running"
  fi

  # Two questions about the RUNNING process that `nginx -t` does not answer.
  #
  # First: is what the spec describes actually mounted into the container? An
  # edit to `volumes` takes effect only on recreation, and until then the
  # container looks healthy while reading directories that may no longer exist
  # on disk.
  #
  # Second: does it serve a single domain? A configuration with no server block
  # is syntactically valid, `nginx -t` accepts it, and nginx in that state
  # listens for nothing — indistinguishable from a powered-off machine from
  # outside, while every other check inside stays green.
  step "The running nginx vs its spec"
  if ! nginx_running; then
    warn "the nginx container is not running — nothing to compare"
  else
    local live_mounts spec_mounts pair served declared dom
    local detail="" detail2=""

    # Both sides are read through functions because they are read TWICE. A
    # mismatch here is a statement about a live system measured with several
    # `docker` calls, and a single reading that disagrees with the next one is
    # not evidence of drift — it is evidence that the measurement moved. The
    # second reading costs two docker calls and buys the difference between "I
    # saw it twice" and "I saw something once".
    read_live_mounts() {
      docker inspect nginx \
        --format '{{range .Mounts}}{{.Source}}	{{.Destination}}{{"\n"}}{{end}}' 2>/dev/null \
        | awk -F'\t' 'NF >= 2 { printf "%s -> %s\n", $1, $2 }' | sort
    }
    # The spec is captured in TWO steps, and the exit code of the first one is
    # kept. Piping compose straight into the parser and ending with `|| true`
    # hides the one failure that matters: a compose killed halfway still prints
    # valid YAML up to the point it died. The parser then returns a SHORTER
    # list, and the comparison blames the container for whatever the spec is
    # missing. A check whose own failure looks like a finding is worse than no
    # check.
    SPEC_RC=0
    read_spec_mounts() {
      local yaml
      SPEC_RC=0
      yaml="$(cd "$ROOT_DIR" && docker compose \
        --project-directory "$ROOT_DIR" --env-file "$ROOT_DIR/.env" \
        -f "$ROOT_DIR/platform/compose/nginx.yaml" -f "$(stacks_static_file)" \
        config 2>/dev/null)" || { SPEC_RC=$?; return 0; }
      printf '%s\n' "$yaml" | compose_mount_pairs \
        | awk -F'\t' 'NF >= 2 { printf "%s -> %s\n", $1, $2 }' | sort
    }
    # One difference per line, in both directions, as text: comparing the
    # printed form is what makes the message show exactly what was compared.
    mount_diff() {
      local live="$1" spec="$2" p out=""
      while IFS= read -r p; do
        [ -n "$p" ] || continue
        printf '%s\n' "$live" | grep -qxF "$p" && continue
        out="$out         missing in the container: $p"$'\n'
      done <<< "$spec"
      while IFS= read -r p; do
        [ -n "$p" ] || continue
        printf '%s\n' "$spec" | grep -qxF "$p" && continue
        out="$out         extra in the container: $p"$'\n'
      done <<< "$live"
      printf '%s' "$out"
    }

    live_mounts="$(read_live_mounts)"
    spec_mounts="$(read_spec_mounts)"

    if [ "$SPEC_RC" -ne 0 ]; then
      warn "the nginx spec did not build (compose exited $SPEC_RC) — mounts cannot be compared"
    elif [ -z "$spec_mounts" ]; then
      warn "the nginx spec built but declares no mounts — mounts cannot be compared"
    else
      detail="$(mount_diff "$live_mounts" "$spec_mounts")"
      if [ -n "$detail" ]; then
        # Second reading. Only what both agree on is reported: a real drift
        # does not heal between two calls, while a measurement that moved does.
        local live2 spec2
        live2="$(read_live_mounts)"
        spec2="$(read_spec_mounts)"
        detail2="$(mount_diff "$live2" "$spec2")"
      fi

      if [ -z "$detail" ]; then
        ok "mounts match the spec"
      elif [ "$detail" = "$detail2" ]; then
        bad "mounts have drifted from the spec — ./dc up -d --force-recreate nginx"
        printf '%s' "$detail"
      else
        # The two readings disagree. That is a fact about the measurement, not
        # about the machine, and it is said out loud rather than swallowed: a
        # check that quietly retries until it likes the answer is how a real
        # drift gets hidden.
        warn "the two readings of the mounts disagree — not reported as drift (STACKYARD_DEBUG=1 for both)"
        if [ -n "${STACKYARD_DEBUG:-}" ]; then
          printf '         --- reading 1, live (%s lines)\n%s\n' "$(printf '%s\n' "$live_mounts" | grep -c .)" "$live_mounts" >&2
          printf '         --- reading 1, spec (%s lines)\n%s\n' "$(printf '%s\n' "$spec_mounts" | grep -c .)" "$spec_mounts" >&2
          printf '         --- reading 2, live (%s lines)\n%s\n' "$(printf '%s\n' "$live2" | grep -c .)" "$live2" >&2
          printf '         --- reading 2, spec (%s lines)\n%s\n' "$(printf '%s\n' "$spec2" | grep -c .)" "$spec2" >&2
        fi
      fi

      # A mount's path and what is visible through it are different things, so
      # comparing paths above is not enough. ./bootstrap replaces .stackyard
      # wholesale (rm -rf), and platform/ is a symlink into it: a running
      # container is left bind-mounted onto a DELETED directory. In docker
      # inspect the path is unchanged, while there are zero files behind it.
      #
      # From the outside this looks like an error in a vhost — "open() ...
      # failed (2: No such file or directory)" — and the vhost, which is not at
      # fault, is what gets investigated. Hence asking the container rather
      # than docker inspect.
      local src dst host_n cont_n empty=0
      while IFS= read -r pair; do
        [ -n "$pair" ] || continue
        src="${pair%% -> *}"; dst="${pair##* -> }"
        [ -d "$src" ] || continue
        host_n=$(ls -A "$src" 2>/dev/null | wc -l | tr -d ' ')
        cont_n=$(docker exec nginx sh -c "ls -A '$dst' 2>/dev/null | wc -l" 2>/dev/null | tr -d ' \r')
        if mount_looks_stale "$host_n" "$cont_n"; then
          # --force-recreate, not a plain `up -d`. The path in the spec has not
          # changed — only the inode behind it — and compose compares the spec,
          # so it reports the container as up to date and does nothing. Advice
          # that changes nothing is worse than none: it reads as "already
          # tried, still broken".
          bad "the container cannot see $dst — the host directory was replaced after it started: ./dc up -d --force-recreate nginx"
          empty=$((empty + 1))
        fi
      done <<< "$spec_mounts"
      [ "$empty" -eq 0 ] && ok "the container can see the contents of its mounted directories"
    fi

    # Same two-step treatment as the spec above, for the same reason: a
    # `nginx -T` that died halfway still prints valid configuration up to that
    # point, and the comparison would then report the vhosts it never reached
    # as "not served". On a machine this size that is not hypothetical — the
    # dump is the whole configuration, and it competes for memory with
    # everything else this check runs.
    local dump dump_rc=0
    dump="$(docker exec nginx nginx -T 2>/dev/null)" || dump_rc=$?
    if [ "$dump_rc" -ne 0 ]; then
      served=""
    else
      served="$(printf '%s\n' "$dump" | nginx_served_names)"
    fi
    # ALL names are needed here, aliases included: those are what the server
    # blocks serve. stacks_domains returns only the primary ones, which measure
    # certificates rather than vhosts.
    declared="$(stacks_domain_names)"
    if [ "$dump_rc" -ne 0 ]; then
      warn "could not read the running configuration (nginx -T exited $dump_rc) — domains not compared"
    elif [ -z "$served" ]; then
      bad "the running nginx serves NO domains at all — ./dc up -d --force-recreate nginx"
    else
      for dom in $declared; do
        printf '%s\n' "$served" | grep -qxF "$dom" \
          || bad "nginx does not serve $dom — the process's config differs from the one on disk: ./dc up -d --force-recreate nginx"
      done
      for dom in $served; do
        printf '%s\n' "$declared" | grep -qxF "$dom" \
          || warn "nginx serves $dom, which no enabled stack declares — ./stack sync"
      done
      ok "domains served: $(printf '%s\n' "$served" | grep -c .)"
    fi
  fi

  step "Containers"
  while IFS= read -r s; do
    local running total
    running="$(stack_running "$s")"
    total="$(stack_services "$s" 2>/dev/null | grep -c . || true)"
    if [ "$total" -eq 0 ]; then
      # A stack with no containers of its own is normal, not a finding: the site
      # runs on the platform's nginx and php-fpm, with its docroot in the shared
      # vhosts directory. That is distinguished from a stack that HAS a compose
      # file in which no services were found — which is a parsing failure.
      if [ ! -f "$(stack_compose_file "$s")" ]; then
        ok "$s: no containers of its own — runs on the platform's nginx/php-fpm"
      else
        warn "$s: no services found in its compose file"
      fi
    elif [ "$running" -eq 0 ]; then
      bad "$s: enabled, but not a single container is running"
    else
      ok "$s: $running/$total running"
    fi
  done < <(stacks_enabled 2>/dev/null)

  while IFS= read -r s; do
    stack_is_enabled "$s" && continue
    local left
    left="$(stack_containers "$s" | grep -c . || true)"
    [ "$left" -gt 0 ] && bad "$s: disabled, but $left container(s) remain — watch-host.sh will treat this as an incident"
  done < <(stacks_available)

  # A container carrying the project label whose service NO stack declares is
  # invisible to everything else: stack_containers searches by service names
  # taken from compose files, and a renamed or deleted service has no such name
  # there. Stopped yet declared restart: unless-stopped, it is meanwhile a
  # permanent incident for watch-host.sh. Docker shows it only as a compose
  # orphan, that is, in a warning attached to some other command.
  local known cname csvc orphans=0 seen=0
  known="$(stacks_known_services | sed '/^$/d' | sort -u)"
  while IFS=$'\t' read -r cname csvc; do
    [ -n "$cname" ] || continue
    seen=$((seen + 1))
    if [ -n "$csvc" ] && printf '%s\n' "$known" | grep -qxF "$csvc"; then continue; fi
    orphans=$((orphans + 1))
    bad "container $cname belongs to no stack (service '${csvc:-unlabelled}') — docker rm -f $cname"
  done < <(project_containers)
  # Zero containers for the project is not "all clear" but "the question could
  # not be asked": on a live machine there are always more than zero. A silent
  # [ok] here would be exactly the kind of failure this whole block exists to
  # catch.
  if [ "$seen" -eq 0 ]; then
    warn "no project containers visible — is docker responding? orphans were not checked"
  elif [ "$orphans" -eq 0 ]; then
    ok "no orphaned project containers"
  fi

  # Declared units and installed ones drift silently in both directions, and
  # both directions cost the same: for an enabled stack the job never runs at
  # all, and for a disabled one the machine wakes on a dead stack's timer and
  # runs scripts against containers that do not exist.
  #
  # systemd.sh is what puts the layout right; the only question here is whether
  # it needs to be run.
  step "systemd units"
  local unit uinst units_wrong=0
  while IFS= read -r s; do
    while IFS= read -r unit; do
      [ -n "$unit" ] || continue
      stack_units_installed "$s" | grep -qxF "$(basename "$unit")" && continue
      units_wrong=$((units_wrong + 1))
      bad "$s: unit $(basename "$unit") is declared but not installed — sudo ./platform/bin/systemd.sh"
    done < <(stack_units "$s")
  done < <(stacks_enabled 2>/dev/null)

  while IFS= read -r s; do
    stack_is_enabled "$s" && continue
    while IFS= read -r uinst; do
      [ -n "$uinst" ] || continue
      units_wrong=$((units_wrong + 1))
      bad "$s: disabled, but unit $uinst is installed — the machine will keep waking on it; sudo ./platform/bin/systemd.sh"
    done < <(stack_units_installed "$s")
  done < <(stacks_available)

  [ "$units_wrong" -eq 0 ] && ok "stack units match the manifest"

  # "Started" and "working" are different things: a container with a dead
  # application inside looks exactly like a healthy one in docker ps.
  #
  # There are two sources of signal, and both are declarations by the stack
  # rather than a list in this file. The first is free: docker's own
  # healthcheck, if the compose file has one. The second is the stack's
  # scripts/health.sh, for what docker cannot express: the application
  # answering through nginx, the freshness of data, the length of a queue.
  step "Stack health"
  local cid cname cstate healthy=0 nohc=0 hscript hrc hout without=""
  while IFS= read -r s; do
    while IFS= read -r cid; do
      [ -n "$cid" ] || continue
      cname="$(docker inspect -f '{{.Name}}' "$cid" 2>/dev/null | sed 's|^/||')"
      cstate="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}-{{end}}' "$cid" 2>/dev/null || true)"
      case "$cstate" in
        healthy)   healthy=$((healthy + 1)) ;;
        unhealthy) bad "$s: container $cname is unhealthy; docker logs $cname --tail 30" ;;
        starting)  warn "$s: container $cname is still starting (healthcheck starting)" ;;
        *)         nohc=$((nohc + 1)) ;;
      esac
    done < <(stack_containers "$s")
  done < <(stacks_enabled 2>/dev/null)
  # Zero containers is not "everything is healthy" but "there was nothing to
  # look at": that a stack is not running is stated on its own line by the
  # containers block above.
  if [ $((healthy + nohc)) -gt 0 ]; then
    ok "docker healthcheck: $healthy healthy, $nohc without a healthcheck"
  fi

  while IFS= read -r s; do
    hscript="$(stack_health_script "$s")"
    if [ ! -f "$hscript" ]; then without="$without $s"; continue; fi
    if [ ! -x "$hscript" ]; then
      warn "$s: scripts/health.sh is not executable — chmod +x $hscript"
      continue
    fi
    # The exit code is captured with `|| hrc=$?`: under errexit a plain
    # assignment from a failing command would abort --check on the first
    # unhealthy stack, printing neither its name nor the reason.
    hrc=0
    hout="$(cd "$ROOT_DIR" && STACK_DIR="$(stack_dir "$s")" ROOT_DIR="$ROOT_DIR" \
            run_with_timeout "$HEALTH_TIMEOUT" "$hscript" 2>&1)" || hrc=$?
    case "$hrc" in
      0)   ok "$s: health.sh — the stack answers" ;;
      124) bad "$s: health.sh did not answer within ${HEALTH_TIMEOUT}s" ;;
      *)   bad "$s: health.sh returned $hrc — $(printf '%s' "$hout" | sed -n '1p')" ;;
    esac
  done < <(stacks_enabled 2>/dev/null)
  [ -n "$without" ] && printf '  [--]   no health check of their own:%s (stacks/<stack>/scripts/health.sh)\n' "$without"

  # Cross-checking the YAML parser against compose itself. The library obtains
  # the service list with a regular expression, and a silent mismatch here
  # would mean disable fails to remove some of a stack's containers.
  step "Compose-file parsing"
  # platform/compose/nginx.yaml is included here as well: stack files reference
  # the shared network declared in it, and on their own `config` fails with
  # "refers to undefined network". The base file's own services are subtracted
  # from the comparison — the library excludes them deliberately.
  local base_svc cfg_args cfg_files dep dsvc ef pf
  base_svc="$(platform_services)"
  while IFS= read -r s; do
    # A stack with no containers of its own has nothing to compare: it has no
    # compose file.
    [ -f "$(stack_compose_file "$s")" ] || continue
    awk_svc="$(stack_services "$s" 2>/dev/null | sort | tr '\n' ' ')"
    # The dependency stacks' files are needed too: `depends_on` references a
    # service belonging to another stack, and on its own `config` fails with
    # "depends on undefined service".
    #
    # The paths come from the same helpers docker-compose.sh uses rather than
    # being assembled from the stack name: a string-built path drifts from the
    # layout silently — `config` then fails for every stack, and the check
    # stops comparing anything while still looking like it works.
    cfg_args=(--project-directory "$ROOT_DIR" --env-file .env)
    # Platform files are taken FROM THE DIRECTORY rather than listed by name.
    # A named file that no longer exists makes `docker compose` fail on a
    # non-existent -f, the 2>/dev/null below swallows it, cfg_svc comes back
    # empty, and "config did not run" is printed for EVERY stack — a check
    # written to catch a YAML-parsing mismatch would be dead on every
    # machine.
    cfg_files=()
    for pf in "$ROOT_DIR"/platform/compose/*.yaml; do
      [ -f "$pf" ] || continue
      case "$pf" in *.generated.yaml) continue ;; esac
      cfg_files+=(-f "${pf#"$ROOT_DIR"/}")
    done
    for dep in "$s" $(stack_requires "$s"); do
      ef="$(stack_env_file "$dep")"
      [ -f "$ef" ] && cfg_args+=(--env-file "$ef")
      [ -f "$(stack_compose_file "$dep")" ] && cfg_files+=(-f "$(stack_compose_file "$dep")")
    done
    cfg_svc="$(cd "$ROOT_DIR" && docker compose "${cfg_args[@]}" "${cfg_files[@]}" config --services 2>/dev/null \
               | grep -vxF "$base_svc" | sort | tr '\n' ' ' || true)"
    # The dependencies' services are subtracted from the output: what is being
    # compared is THIS stack's list.
    #
    # `|| true` on both greps: when `config` did not run, cfg_svc is empty,
    # grep over empty input returns 1, and under `set -e` the check would die
    # right here — printing nothing and never reaching the static-content
    # section or the summary. The very failure the warn below describes would
    # suppress that warn.
    for dep in $(stack_requires "$s"); do
      while IFS= read -r dsvc; do
        [ -n "$dsvc" ] && cfg_svc="$(printf '%s' "$cfg_svc" | tr ' ' '\n' | grep -vx "$dsvc" | tr '\n' ' ' || true)"
      done < <(stack_services "$dep" 2>/dev/null)
    done
    cfg_svc="$(printf '%s' "$cfg_svc" | tr ' ' '\n' | grep -v '^$' | sort | tr '\n' ' ' || true)"
    if [ -z "$cfg_svc" ]; then
      warn "$s: docker compose config did not run — nothing to compare the service list against"
    elif [ "$awk_svc" = "$cfg_svc" ]; then
      ok "$s: the service list matches docker compose"
    else
      bad "$s: the YAML parser yields '$awk_svc', docker compose yields '$cfg_svc'"
    fi
  done < <(stacks_enabled 2>/dev/null)

  step "Static content: what nginx actually mounted"
  # The RESULT is checked, not the formula: comparing variables by name would
  # mean knowing about a particular stack, while the failure looks the same for
  # any of them — the variable is unset or points elsewhere, compose
  # substitutes its default, and the domain serves 404s from a directory nobody
  # intended.
  if ! nginx_running; then
    warn "the nginx container is not running — the mounted static content cannot be checked"
  else
    local mounts; mounts=$(docker inspect nginx \
      --format '{{range .Mounts}}{{.Destination}}|{{.Source}}{{"\n"}}{{end}}' 2>/dev/null || true)
    local declared=0
    while IFS= read -r s; do
      for pair in $(stack_conf_get "$s" Static); do
        declared=$((declared + 1))
        local domain src
        domain="${pair%%:*}"
        src=$(printf '%s\n' "$mounts" | awk -F'|' -v d="/$domain" '$1 ~ d"$" { print $2; exit }')
        if [ -z "$src" ]; then
          bad "$s: static content for $domain is not mounted — ./stack sync and up -d"
        elif [ ! -d "$src" ]; then
          bad "$s: static content for $domain is mounted from '$src', which does not exist — $domain will serve 404"
        else
          case "$src" in
            */vhosts)
              warn "$s: static content for $domain is mounted from '$src' — that is the fallback default, not the stack's directory; check the variable used in Static= in the root .env" ;;
            *) ok "$s: static content for $domain — $src" ;;
          esac
        fi
      done
    done < <(stacks_available)
    [ "$declared" -eq 0 ] && ok "no stack declares Static — nothing to check"
  fi

  step "Summary"
  echo "  problems: $PROBLEMS, warnings: $WARNINGS"
  [ "$PROBLEMS" -gt 0 ] && exit 1
  exit 0
}

# ------------------------------------------------------------------ main

VERB=""
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)  DRY_RUN=1 ;;
    --no-start) NO_START=1 ;;
    --no-units) NO_UNITS=1 ;;
    --check)    VERB="check" ;;
    -h|--help)  usage 0 ;;
    -*)         die "unknown flag: $1" ;;
    *)          if [ -z "$VERB" ]; then VERB="$1"; else ARGS+=("$1"); fi ;;
  esac
  shift
done

case "${VERB:-list}" in
  list)    verb_list ;;
  check)   verb_check ;;
  sync)    verb_sync ;;
  enable)  [ ${#ARGS[@]} -gt 0 ] || die "name a stack: $0 enable <stack>..."; verb_enable "${ARGS[@]}" ;;
  disable) [ ${#ARGS[@]} -gt 0 ] || die "name a stack: $0 disable <stack>..."; verb_disable "${ARGS[@]}" ;;
  purge)   [ ${#ARGS[@]} -eq 1 ] || die "purge takes EXACTLY one stack: $0 purge <stack>"; verb_purge "${ARGS[0]}" ;;
  *)       die "unknown command: '$VERB' (list|enable|disable|purge|sync|--check)" ;;
esac
