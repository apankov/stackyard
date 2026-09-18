# shellcheck shell=bash
# Which stacks a machine has and which of them are enabled. Sourced, never run
# on its own.
#
# There is exactly one source of truth — Enabled_Stacks in .env-stacks — and
# everything else is derived from it: the set of compose files, the vhost
# includes, the systemd units, the certificate domains. A second list of
# "which stacks are enabled" anywhere means compose and nginx can disagree,
# which surfaces as `host not found in upstream`: nginx refuses to start, and
# with restart: always that becomes a crash loop taking down EVERY vhost.
#
# This file depends on nothing: the manifest is read with a line-by-line grep,
# so it can also be sourced from docker-compose.sh, which does not load
# lib-env.sh.

# Inter-stack dependencies: the stacks this one cannot work without.
#
# Not cosmetic. A stack may have no containers of its own at all — a PHP site
# runs on the platform's php-fpm and reaches the shared database by service
# name. Without Requires="php-fpm mysql" such a stack enables "successfully"
# and then serves 502 or "Access denied": the failure moves from the moment of
# enabling into runtime, where a visitor finds it first.
#
# The stack declares this in its own stack.conf. A list inside this library
# would mean a stack with a dependency cannot be added without editing the
# library.
stack_requires() { stack_conf_get "$1" Requires; }

# ------------------------------------------------------------------ paths

stacks_root() {
  # ROOT_DIR is set by the calling script; this is only a safety net.
  printf '%s' "${ROOT_DIR:?ROOT_DIR was not set by the calling script}"
}

# The roots searched for stacks, in priority order.
#
# There are two, and together they are the whole "copy or link" mechanism:
#
#   stacks/          — stacks belonging to THIS machine. Edited freely.
#   profile/stacks/  — a library of reusable stacks that arrives with the
#                      profile. Updated as a whole, together with it.
#
# The machine root comes first, so a stack copied from the profile into
# stacks/ shadows the profile's copy. That is how a machine detaches from the
# profile: the copy becomes the machine's, profile updates no longer touch it,
# and a single `ls stacks/` shows this — no config entry to look up.
#
# The reverse order would mean the profile silently overrides a local edit,
# which is the worse failure: someone edits a file that nothing reads.
stack_roots() {
  printf '%s/stacks\n' "$(stacks_root)"   # stack-path-ok: this is where the roots are defined
  [ -d "$(stacks_root)/profile/stacks" ] && printf '%s/profile/stacks\n' "$(stacks_root)"
  return 0
}

# A stack's directory: the first root that holds its stack.conf.
#
# stack.conf specifically, not merely a directory of that name. The difference
# is not theoretical: for ANY enabled stack, profile ones included, the machine
# creates stacks/<stack>/.env, because secrets belong to the machine. If a bare
# directory counted as a declaration, a profile stack would be shadowed by a
# directory containing nothing but .env: the compose file would not be found,
# while `stack.sh list` cheerfully reported everything fine.
#
# Hence the rule: a stack is declared by the directory that holds its
# stack.conf. Copying a stack out of the profile means copying it whole,
# declaration included; half a copy is not a stack.
stack_dir() {
  local r
  while IFS= read -r r; do
    [ -f "$r/$1/stack.conf" ] && { printf '%s/%s' "$r" "$1"; return 0; }
  done < <(stack_roots)
  printf '%s/stacks/%s' "$(stacks_root)" "$1"   # stack-path-ok: path used only in the error message
}

stack_compose_file() { printf '%s/compose.yaml' "$(stack_dir "$1")"; }
stack_vhost_dir()    { printf '%s/nginx' "$(stack_dir "$1")"; }
stack_conf_file()    { printf '%s/stack.conf' "$(stack_dir "$1")"; }

# A stack's .env is ALWAYS in the machine root, even for a profile stack.
#
# Secrets belong to the machine, not to the profile: the profile is delivered
# as a whole and updated as a whole, so putting a password inside it would mean
# the next update wipes it, and the profile's git history sees it.
# stack-path-ok: a stack's .env is ALWAYS in the machine root, even for a
# profile stack — that is the intent, see the comment above.
stack_env_file()     { printf '%s/stacks/%s/.env' "$(stacks_root)" "$1"; }

# The stacks directory INSIDE the nginx container. The value must match the
# mount target for $Platform_Deploy_Dir/stacks in platform/compose/nginx.yaml:
# the generated include file is read by nginx, not by the host.
STACKS_DIR_IN_CONTAINER="/etc/nginx/stacks"
STACKS_PROFILE_DIR_IN_CONTAINER="/etc/nginx/profile-stacks"

# A stack's directory INSIDE the nginx container. There are two roots, and the
# include must point at the one the stack actually lives in: otherwise, after a
# stack is copied from the profile into the machine's stacks/, nginx would keep
# reading the profile's copy.
stack_dir_in_container() {
  case "$(stack_dir "$1")" in
    "$(stacks_root)/profile/stacks/"*) printf '%s/%s' "$STACKS_PROFILE_DIR_IN_CONTAINER" "$1" ;;
    *)                                 printf '%s/%s' "$STACKS_DIR_IN_CONTAINER" "$1" ;;
  esac
}

# The generated file of includes for the enabled stacks. It lives in the
# machine's state/, and nginx reads it through a single include line in
# platform/nginx-vhosts/05-enabled.conf.
#
# The numeric prefix keeps the reading order predictable but does not decide
# the default server: default_server is set explicitly in default.conf.
stacks_include_file() { printf '%s/state/nginx-vhosts/10-enabled.conf' "$(stacks_root)"; }

# The generated file of static-content volumes. Also kept out of git: it
# describes one particular machine and is derived from Static= in
# stacks/*/stack.conf.
stacks_static_file()  { printf '%s/state/nginx-static.generated.yaml' "$(stacks_root)"; }

# Create the machine's state directories. Idempotent.
#
# One function rather than an mkdir at each call site: the same knowledge in
# two places drifts, and a fix applied to one entry point silently misses the
# other. Both entry points call this first.
#
# What it prevents. On a fresh machine, right after ./bootstrap, neither state/
# nor its subdirectories exist: bootstrap delivers the platform, while state is
# the machine's own. The first command would write into state/nginx-vhosts/ and
# die with a raw shell error, and databases.yaml would never be created — while
# --check demanded a `sync` that does not create it either. A closed loop in
# the first minute of using the platform.
ensure_state_dirs() {
  local root p
  root="$(stacks_root)"
  mkdir -p "$root/state/nginx-vhosts" "$root/state/certs" \
           "$root/state/htpasswd" "$root/state/getssl-config" 2>/dev/null || true
  # The provider's directory only when a provider is enabled: an empty state/pg
  # on a MySQL machine would be as misleading as a missing one where it is
  # needed.
  p="$(stacks_db_provider)"
  [ -n "$p" ] && mkdir -p "$root/state/$p" 2>/dev/null
  return 0
}

# ------------------------------------------------------- the DB provider
#
# The engine does NOT know which DBMS a machine runs. It knows only the role:
# some enabled stack declares itself the provider of the shared database, and
# then other stacks can order a database and a user from it.
#
# Naming a specific DBMS here would fork the engine per machine: a Postgres
# machine would need the same code with seven words replaced. A name written
# where the meaning is a role is exactly how a shared platform starts to
# diverge between machines.
#
# The provider stack declares itself in its own stack.conf:
#
#   Provides_DB="Mysql"                 the prefix of the keys it understands
#   DB_Init_Service="mysql-initializer" the one-shot container that creates them
#
# A consumer writes keys with that prefix: Mysql_DB, Mysql_User, Mysql_Password
# (plus whatever else the provider understands — Mysql_Grants, Mysql_Dump).
# These keys are opaque to the engine: it only collects them and hands them to
# the provider.

# The name of the enabled provider stack, or empty.
#
# A machine cannot have two providers: consumer keys are distinguished by
# prefix, not by addressee, so a second provider with the same prefix would
# quietly intercept declarations meant for the first. Enforced by
# check_db_providers_unique.
stacks_db_provider() {
  local s
  while IFS= read -r s; do
    [ -n "$(stack_conf_get "$s" Provides_DB)" ] && { printf '%s' "$s"; return 0; }
  done < <(stacks_enabled 2>/dev/null)
  return 0
}

# The provider's key prefix (Mysql, Postgres, ...).
stacks_db_prefix() {
  local p; p="$(stacks_db_provider)"
  [ -n "$p" ] && stack_conf_get "$p" Provides_DB
  return 0
}

# The name of the one-shot container that creates the databases. Needed by
# --check: it has no restart: always, so from the outside its failure looks
# merely like `exited`.
stacks_db_init_service() {
  local p; p="$(stacks_db_provider)"
  [ -n "$p" ] && stack_conf_get "$p" DB_Init_Service
  return 0
}

# The generated list of databases. It lives inside the provider's state
# directory because that is where the initializer reads it from — but it is
# written by the platform, from the declarations of all enabled stacks. The
# consumer decides the location, not the author.
#
# The file is always under the machine root, named after the provider stack:
# writing inside profile/ is not allowed, because the next profile update would
# overwrite it.
#
# CONTAINS PASSWORDS: chmod 600, kept out of git.
stacks_databases_file() {
  local p; p="$(stacks_db_provider)"
  [ -n "$p" ] || return 0
  printf '%s/state/%s/databases.yaml' "$(stacks_root)" "$p"
}

# Two providers at once is a fight over the prefix and almost certainly an
# oversight when enabling a stack.
check_db_providers_unique() {
  local s found=""
  while IFS= read -r s; do
    [ -n "$(stack_conf_get "$s" Provides_DB)" ] || continue
    [ -n "$found" ] && printf 'more than one shared-DB provider is enabled: %s and %s\n' "$found" "$s"
    found="$s"
  done < <(stacks_enabled 2>/dev/null)
  return 0
}

# ------------------------------------------------------------- stack.conf

# stack_conf_get <stack> <key> [<default>]
#
# Parsed with a line-by-line grep, WITHOUT lib-env.sh and without expanding
# ${...}. Two reasons, both load-bearing:
#
#   1. docker-compose.sh sources lib-stacks.sh but not lib-env.sh (see the file
#      header). That dependency must not appear here.
#   2. stack.conf must be readable for a stack that is DISABLED and whose .env
#      does not exist on this machine at all. There is nothing to expand from,
#      and substituting an empty string is the worse outcome: an empty host
#      path in a volume gives a root-owned empty directory and silent 404s.
#
# Values containing ${...} — only Static does — go into the generated compose
# file verbatim, and compose expands them itself from the root .env. The
# Backup_* keys are read by backup.sh, which works only on enabled stacks,
# loads lib-env.sh and expands substitutions normally.
stack_conf_get() {
  local s="$1" key="$2" default="${3-}" file val=""
  file="$(stack_conf_file "$s")"
  if [ -f "$file" ]; then
    val=$(grep -E "^[[:space:]]*${key}=" "$file" | tail -n 1 | cut -d '=' -f2- | tr -d '"'"'" || true)
  fi
  if [ -z "$val" ]; then printf '%s' "$default"; else printf '%s' "$val"; fi
}

# ------------------------------------------------------- the list of stacks

# Every stack is a directory under a stack root. The directory name is the
# stack name; there is nothing to subtract from the list, because only stacks
# live there.
stacks_available() {
  local r d
  while IFS= read -r r; do
    for d in "$r"/*/; do
      d="${d%/}"
      # stack.conf, not merely a directory — see stack_dir. A directory holding
      # only .env is not a stack and must not appear in the list.
      [ -f "$d/stack.conf" ] || continue
      printf '%s\n' "${d##*/}"
    done
  done < <(stack_roots) | sort -u
}

stack_exists() {
  local s
  while IFS= read -r s; do [ "$s" = "$1" ] && return 0; done < <(stacks_available)
  return 1
}

# The enabled stacks come from Enabled_Stacks in .env-stacks, in file order.
#
# A missing .env-stacks is NOT a failure: a fresh `git pull` on a server must
# not break every compose command on the machine. Hence a warning on stderr and
# a fallback to "every stack that has all of its files".
stacks_enabled() {
  local manifest="$(stacks_root)/.env-stacks" raw s

  # An override from stack.sh: it already knows what the manifest is about to
  # become, and under --dry-run it does not write the file. Without this,
  # dry-run would compare the includes against the OLD set and report "already
  # up to date" — lying in the very mode that exists in order not to lie.
  if [ -n "${STACKS_ENABLED_OVERRIDE+x}" ]; then
    for s in $STACKS_ENABLED_OVERRIDE; do printf '%s\n' "$s"; done
    return 0
  fi

  if [ -f "$manifest" ]; then
    raw=$(grep -E '^[[:space:]]*Enabled_Stacks=' "$manifest" | tail -n 1 | cut -d '=' -f2- | tr -d '"'"'" || true)
    for s in $raw; do
      if stack_exists "$s"; then
        printf '%s\n' "$s"
      else
        echo "Warning: .env-stacks lists stack '$s', but there is no stacks/$s directory — skipping" >&2
      fi
    done
    return 0
  fi

  echo "Warning: no .env-stacks — treating every stack with a complete file set as enabled." >&2
  echo "  Create the manifest: cp .env-stacks.example .env-stacks && ./stack sync" >&2
  while IFS= read -r s; do
    [ -z "$(stack_missing_files "$s")" ] && printf '%s\n' "$s"
  done < <(stacks_available)
}

stack_is_enabled() {
  local s
  while IFS= read -r s; do [ "$s" = "$1" ] && return 0; done < <(stacks_enabled 2>/dev/null)
  return 1
}

# The enabled stacks that require the given stack.
stack_dependents() {
  local target="$1" s req
  while IFS= read -r s; do
    for req in $(stack_requires "$s"); do
      [ "$req" = "$target" ] && printf '%s\n' "$s"
    done
  done < <(stacks_enabled 2>/dev/null)
}

# What a stack is missing before it can be enabled. Empty output means it is
# complete.
stack_missing_files() {
  local s="$1"
  # compose.yaml is required for a stack that has containers OF ITS OWN.
  #
  # A stack without containers is common: a static site runs on the platform's
  # nginx and php-fpm, and a proxy stack only describes a vhost pointing at
  # someone else's application. But a missing compose.yaml is NOT itself a
  # declaration: a forgotten file in an ordinary stack would look exactly the
  # same and would produce a valid config in which nothing starts.
  #
  # So the declaration is explicit — Containers="no" in stack.conf.
  if [ "$(stack_conf_get "$s" Containers yes)" != "no" ] && [ ! -f "$(stack_compose_file "$s")" ]; then
    printf 'stacks/%s/compose.yaml (or Containers="no" in stack.conf if it has no containers of its own)\n' "$s"
  fi
  # A stack's .env is required only where an example exists: a static site
  # needs no env file of its own, and demanding one would invent a failure.
  #
  # The example is looked for NEXT TO THE STACK, while the .env itself is in
  # the machine root. For a machine stack that is the same directory; for a
  # profile stack they differ, and the two places cannot be probed the same
  # way. A profile stack's example lives under profile/, so looking for it
  # along the machine path would never find it — and a database stack would
  # then count as complete without its root password, failing later with an
  # interpolation error from the middle of compose instead of one clear line
  # here.
  if [ -f "$(stack_dir "$s")/.env.example" ] && [ ! -f "$(stack_env_file "$s")" ]; then
    printf 'stacks/%s/.env\n' "$s"
  fi
}

# --------------------------------------------------------------- checks
#
# Each prints one line per problem found and stays silent when there is none.
# That makes them equally usable from selftest.sh and from stack.sh --check,
# and none of them decides on its own what to do about a finding.

# One domain claimed by two stacks is a guaranteed nginx failure at startup
# ("conflicting server name") and two getssl configs fighting over one
# certificate.
check_domains_unique() {
  local s d a
  while IFS= read -r s; do
    for d in $(stack_conf_get "$s" Domains); do
      printf '%s\t%s\n' "$(domain_primary "$d")" "$s"
      for a in $(domain_sans "$d"); do printf '%s\t%s\n' "$a" "$s"; done
    done
  done < <(stacks_available) | sort | awk -F'\t' '
    # Adjacent lines can come from ONE stack: Domains="a.test a.test" or
    # a.test+a.test is the same mistake, but calling it "declared by both papa
    # and papa" would read as a broken check, and a broken-looking check stops
    # being read.
    { if ($1 == prev) {
        if ($2 == prevs) print "domain " $1 " is declared twice by stack " $2
        else             print "domain " $1 " is declared by both " prevs " and " $2
      }
      prev = $1; prevs = $2 }'
}

# A domain in stack.conf with no matching server_name in the stack's vhosts
# means a certificate that is issued and serves nobody; the reverse means a
# vhost that works until someone notices it has no certificate.
check_domains_match() {
  local s="$1" declared served d
  declared=$(for d in $(stack_conf_get "$s" Domains); do
               printf '%s\n' "$(domain_primary "$d")"
               for a in $(domain_sans "$d"); do printf '%s\n' "$a"; done
             done | sed '/^$/d' | sort -u)
  # `|| true` for the same reason as in stacks_upstreams: for a stack that
  # declares Domains but has no nginx/ directory, grep exits non-zero, and
  # under `set -e` the function would die right here — without printing the one
  # finding it is called for ("domain declared, no vhost").
  served=$(grep -rhE '^[[:space:]]*server_name[[:space:]]' "$(stack_vhost_dir "$s")" 2>/dev/null \
           | awk '{for (i = 2; i <= NF; i++) print $i}' | tr -d ';' | sed '/^$/d' | sort -u || true)
  for d in $(comm -23 <(printf '%s\n' "$declared") <(printf '%s\n' "$served")); do
    printf 'stack %s: domain %s is declared in stack.conf, but no vhost serves it\n' "$s" "$d"
  done
  for d in $(comm -13 <(printf '%s\n' "$declared") <(printf '%s\n' "$served")); do
    printf 'stack %s: a vhost serves %s, but the domain is absent from stack.conf — no certificate is issued for it\n' "$s" "$d"
  done
}

# A relative host path resolves against the project directory, not against the
# stack's own file. The project directory is set explicitly
# (--project-directory in docker-compose.sh), but stack files must not rely on
# it: the path would then be correct by coincidence rather than by declaration.
#
# Named volumes (`- somevolume:/data`) also contain a colon, but their host
# part does not look like a path and never reaches here: only candidates
# starting with a dot are examined.
check_paths_absolute() {
  local s="$1"
  awk -v s="$s" '
    # Leaving the block: the first non-empty line indented no deeper than
    # volumes: itself. Comments and blank lines inside do not close it.
    in_vol && !/^[[:space:]]*-[[:space:]]/ {
      match($0, /^[[:space:]]*/)
      if ($0 ~ /[^[:space:]]/ && RLENGTH <= vol_indent) in_vol = 0
    }
    /^[[:space:]]+volumes:[[:space:]]*(#.*)?$/ {
      match($0, /^[[:space:]]*/); vol_indent = RLENGTH; in_vol = 1; next
    }
    in_vol && match($0, /^[[:space:]]*-[[:space:]]+/) {
      v = substr($0, RLENGTH + 1)
      sub(/[[:space:]]*(#.*)?$/, "", v)
      gsub(/^["'"'"']|["'"'"']$/, "", v)
      if (v ~ /^\.{1,2}\//) {
        print "stack " s ": relative host path in a volume: " v
      } else if (v ~ /^\// && v !~ /\$/) {
        print "stack " s ": hardcoded host path in a volume (use a variable): " v
      }
    }
  ' "$(stack_compose_file "$s")" 2>/dev/null
}

# /etc/systemd/system is flat. Without a prefix, two stacks fight over a name,
# and whichever was installed last wins.
check_unit_names() {
  local s="$1" u n
  while IFS= read -r u; do
    [ -n "$u" ] || continue
    n=$(basename "$u")
    case "$n" in
      devbox-"$s"-*) ;;
      *) printf 'stack %s: unit %s lacks the devbox-%s- prefix\n' "$s" "$n" "$s" ;;
    esac
  done < <(stack_units "$s")
}

# A job that has stopped running looks exactly like a job with nothing to do.
# Only an independent check of the RESULT can tell them apart, so a timer
# without one is an incomplete job.
check_timer_has_check() {
  local s="$1" u n base
  while IFS= read -r u; do
    case "$u" in *.timer) ;; *) continue ;; esac
    n=$(basename "$u" .timer)
    base="${n#devbox-"$s"-}"
    [ -f "$(stack_dir "$s")/scripts/check-$base.sh" ] && continue
    [ -f "$(stack_dir "$s")/systemd/$n-check.timer" ] && continue
    printf 'stack %s: timer %s has no result check (scripts/check-%s.sh or %s-check.timer)\n' \
      "$s" "$n" "$base" "$n"
  done < <(stack_units "$s")
}

# The platform's services: everything declared in platform/compose/*.yaml,
# except the generated statics file (it merges a volume into the already
# declared nginx and introduces no new services).
#
# php-fpm is here for the same reason as nginx, not for symmetry. PHP sites
# reach it through `fastcgi_pass php-fpm:9000`, and nginx resolves that address
# while READING the config, exactly as it does proxy_pass: no container means
# nginx does not start, and `restart: always` turns that into a crash loop
# taking down every site on the machine. So php-fpm follows the same rule as
# nginx: its spec is constant, and stacks merge nothing into it.
platform_services() {
  local f
  for f in "$(stacks_root)"/platform/compose/*.yaml; do
    [ -f "$f" ] || continue
    case "$f" in *.generated.yaml) continue ;; esac
    _stacks_yaml_keys "$f" services
  done
}

# A stack that merges anything into a platform service makes that service's
# spec depend on which stacks are enabled — reintroducing exactly the failure
# the statics generator exists to prevent.
check_no_base_service_merge() {
  local s="$1" base svc
  base=$(platform_services)
  while IFS= read -r svc; do
    [ -n "$svc" ] || continue
    # `if` rather than `&&`: with `&&` at the end of the loop body the
    # function's exit status becomes that of the last grep, so it "fails"
    # precisely when there is NOTHING to report. Harmless while it is called
    # through process substitution, but the first `check_... || die` call site
    # would behave backwards.
    if printf '%s\n' "$base" | grep -qx -- "$svc"; then
      printf 'stack %s: merges into shared service %s — declare static content via Static= in stack.conf\n' "$s" "$svc"
    fi
  done < <(_stacks_yaml_keys "$(stack_compose_file "$s")" services)
}

# A cycle in Requires means enable and disable loop forever while resolving
# dependencies.
check_requires_cycle() {
  local s="$1" seen=" $1 " queue next r depth=0
  queue=$(stack_requires "$s")
  while [ -n "$queue" ] && [ "$depth" -lt 20 ]; do
    next=""
    for r in $queue; do
      case "$seen" in
        *" $r "*) printf 'cycle in Requires: %s -> ... -> %s\n' "$s" "$r"; return 0 ;;
      esac
      seen="$seen$r "
      next="$next $(stack_requires "$r")"
    done
    queue="$next"
    depth=$((depth + 1))
  done
}

# The upstreams referenced by the vhosts of enabled stacks.
#
# A stack may legitimately have no nginx/ directory (a database, a cache), and
# a directory may legitimately contain no matches — but grep exits non-zero in
# both cases, and stack.sh runs under `set -e`. Without guarding both, the loop
# subshell dies on the FIRST such stack and the function returns nothing: the
# upstream check would then verify nothing at all, silently, showing an empty
# block instead of lines. Hence both `[ -d ]` and `|| true`: each covers a
# different half (no directory / no matches).
stacks_upstreams() {
  local s dir
  while IFS= read -r s; do
    dir="$(stack_vhost_dir "$s")"
    [ -d "$dir" ] || continue
    # fastcgi_pass alongside proxy_pass, and that is not a detail: nginx
    # resolves `fastcgi_pass php-fpm:9000` while reading the config in exactly
    # the same way. A stopped php-fpm therefore takes down EVERY site when
    # nginx is recreated, including static ones that need no PHP at all.
    grep -rhE '^[[:space:]]*(proxy_pass|fastcgi_pass)[[:space:]]' "$dir" 2>/dev/null || true
  done < <(stacks_enabled 2>/dev/null) \
    | sed -E 's|^[[:space:]]*fastcgi_pass[[:space:]]+|//|' \
    | sed -E 's|.*//([^/:;]+).*|\1|' | sed '/^$/d' \
    | grep -vxF 'host.docker.internal' \
    | sort -u
  return 0
}

# host.docker.internal is excluded on purpose: it is not a container but an
# alias for the host itself, provided by `extra_hosts: host-gateway`. The check
# looks for upstreams among running containers, so it would always report this
# one as "not running" — a machine with an upstream outside the docker network
# would have a permanently red block. A permanently red check stops being read
# at all, together with its genuine findings.
#
# Whether the thing listening on the host is alive is not visible from here.
# That is the stack's business: see scripts/health.sh.

# ------------------------------------------------------- image registries
#
# The point: a stack runs from a DIGEST, not from a moving tag. With `:master`,
# `up -d` uses whatever is already cached locally, drifts from the registry
# silently, and leaves nowhere to roll back to — the previous tag no longer
# exists.


# Whether how a stack pulls its image agrees with what it declares.
#
# There is exactly one question: how the stack chooses an image version. A
# digest (`repo@${VARIABLE}`) answers "what is running right now" and lives in
# the stack's .env; `Image_Tag=` in stack.conf answers "which moving tag we
# follow", and resolving one into the other is registry.sh's job. Half of that
# pair is useless: a tag with no digest has nowhere to be written, a digest
# with no tag has nothing to be refreshed from. Such a mismatch is silent —
# pinning simply stops doing what it is called for.
check_image_decl() {
  local s="$1" img tag has_reg=0 digest=0
  tag="$(stack_image_tag "$s")"
  while IFS= read -r img; do
    [ -n "$img" ] || continue
    has_reg=1
    case "$img" in *@\$\{*) digest=1 ;; esac
  done < <(stack_registry_images "$s")

  if [ -n "$tag" ] && [ "$has_reg" -eq 0 ]; then
    printf 'stack %s: Image_Tag=%s is declared, but no image is pulled from an external registry\n' "$s" "$tag"
  fi
  if [ -n "$tag" ] && [ "$has_reg" -eq 1 ] && [ "$digest" -eq 0 ]; then
    printf 'stack %s: Image_Tag=%s is declared, but the image is not pinned by digest — nothing to pin\n' "$s" "$tag"
  fi
  if [ -z "$tag" ] && [ "$digest" -eq 1 ]; then
    printf 'stack %s: the image is pinned by digest, but no Image_Tag= is declared — nothing to refresh it from\n' "$s"
  fi
}


# --------------------------------------------------------------- registries

# The registry host of an image reference, or empty for Docker Hub.
#
# This is Docker's own rule, not a heuristic: the first path segment is a
# registry if it contains a dot or a colon, or is localhost. Without it,
# `team/app` (a Hub image) and `registry.example/app` are indistinguishable.
image_registry() {
  local v="${1%%/*}"
  [ "$v" = "$1" ] && return 0
  case "$v" in
    localhost|localhost:*|*.*|*:*) printf '%s' "$v" ;;
  esac
}


# A stack's image references that live in an EXTERNAL registry (not Docker Hub).
#
# Values containing ${...} are returned verbatim: compose expands them, and the
# host and repository are written as literals in the compose file precisely so
# they can be read from here — a disabled stack has no .env on the machine at
# all (see stack_conf_get).
stack_registry_images() {
  local img
  while IFS= read -r img; do
    [ -n "$img" ] || continue
    if [ -n "$(image_registry "$img")" ]; then printf '%s\n' "$img"; fi
  done < <(stack_images "$1")
}


# stacks_registries [<stack>...]
#
# The external registry hosts mentioned by the listed stacks; with no arguments,
# by every available stack. Only registries that can be pulled from right now
# need a login, so registry.sh passes the enabled stacks; the question "does
# this machine use registries at all" is asked with no arguments.
stacks_registries() {
  local s img
  { if [ $# -gt 0 ]; then printf '%s\n' "$@"; else stacks_available; fi; } | {
    while IFS= read -r s; do
      [ -n "$s" ] || continue
      while IFS= read -r img; do
        if [ -n "$img" ]; then image_registry "$img"; printf '\n'; fi
      done < <(stack_registry_images "$s")
    done
  } | sed '/^$/d' | sort -u
}


# The moving tag a stack follows in the registry (`Image_Tag=` in stack.conf).
#
# Needed only by registry.sh: it resolves that tag into a digest, and a stack
# always runs from the digest. Tag and digest answer different questions and
# live apart: the tag says "what we follow", is the same on every machine and
# therefore belongs in the declaration; the digest says "what is running now",
# changes with every deploy and therefore belongs in the stack's .env, next to
# the rest of the server-side state.
stack_image_tag() { stack_conf_get "$1" Image_Tag; }

# The certificate paths referenced by the vhosts of ALL stacks — from both
# roots — plus the platform's own.
#
# Via stack_vhost_dir rather than a glob over the machine root: a glob is blind
# to the profile root, so no placeholder certificate would be created for a
# profile stack. Its domain is still visible (domain enumeration looks at both
# roots), so getssl would be configured for it correctly. The result: domain
# declared, getssl config present, placeholder file absent — nginx cannot open
# ssl_certificate, does not start, and with restart: always goes into a crash
# loop taking down EVERY site on the machine.
stacks_cert_paths() {
  local s dir
  while IFS= read -r s; do
    dir="$(stack_vhost_dir "$s")"
    [ -d "$dir" ] || continue
    grep -rhE '^[[:space:]]*ssl_certificate(_key)?[[:space:]]' "$dir" 2>/dev/null || true
  done < <(stacks_available)
  grep -rhE '^[[:space:]]*ssl_certificate(_key)?[[:space:]]' \
    "$(stacks_root)/platform/nginx-vhosts" 2>/dev/null || true
}

# ------------------------------------------------------------------ nginx

# --------------------------------------------------------------- systemd

# Файлы юнитов стека. Пусто, если каталога systemd/ нет — наличие каталога и
# есть объявление, отдельного ключа в stack.conf для этого не нужно.
stack_units() {
  local f
  for f in "$(stack_dir "$1")"/systemd/*.service "$(stack_dir "$1")"/systemd/*.timer; do
    [ -f "$f" ] || continue
    printf '%s\n' "$f"
  done
}

# Каталог стека ОТНОСИТЕЛЬНО корня — то есть без префикса ROOT_DIR.
#
# Нужен там, где путь пишется не для нас, а для кого-то ещё: systemd видит
# машину по DEPLOY_DIR, и подставлять туда локальный ROOT_DIR нельзя. При этом
# КОРЕНЬ (машинный или профильный) обязан быть настоящим — иначе юнит
# профильного стека получит ExecStart в машинный каталог, где лежит только
# .env, и упадёт с 203/EXEC по таймеру, ночью.
_stack_dir_suffix() {
  local d; d="$(stack_dir "$1")"
  printf '%s' "${d#"$(stacks_root)"}"
}

# Текст юнита с подставленными плейсхолдерами.
#
# Юниты systemd не умеют переменных вовсе — ни своих, ни окружения на этапе
# разбора. Поэтому подстановка делается здесь, при установке, и все пути в
# результате абсолютные.
#
# Значения берутся из окружения (DEPLOY_DIR, SERVICE_USER, ONFAILURE), чтобы
# функция одинаково годилась и для systemd.sh, и для тестов.
unit_render() {
  local file="$1" stack="$2"
  sed \
    -e "s#@DEPLOY_DIR@#${DEPLOY_DIR:?}#g" \
    -e "s#@STACK_DIR@#${DEPLOY_DIR:?}$(_stack_dir_suffix "$stack")#g" \
    -e "s#@SERVICE_USER@#${SERVICE_USER:?}#g" \
    -e "s#@ONFAILURE@#${ONFAILURE:-}#g" \
    "$file"
}

# ---------------------------------------------------------------- домены

# Домены включённых стеков, по одному на строку, без повторов.
#
# Отдельный список доменов (например, набор каталогов в getssl-config/)
# разъезжается с набором стеков незаметно в обе стороны: домен без стека
# продлевается вечно и тратит лимиты Let's Encrypt, а стек без домена молча
# остаётся с самоподписанной заглушкой до тех пор, пока кто-нибудь не откроет
# его в браузере.
# Одна запись Domains= — это ОДИН сертификат. Форма `домен+алиас+алиас`
# означает, что алиасы уходят в тот же сертификат как SANS.
#
# Без этого www-имя, которое обслуживает тот же server-блок, остаётся с
# сертификатом на голый домен: браузер ругается только на www, то есть отказ
# видно не всем и не сразу, а из логов nginx он не виден вовсе.
domain_primary() { printf '%s' "${1%%+*}"; }
domain_sans()    { [ "$1" = "${1#*+}" ] || printf '%s' "${1#*+}" | tr '+' ' '; }

# Основные домены включённых стеков — по одному на сертификат.
stacks_domains() {
  local s d
  while IFS= read -r s; do
    for d in $(stack_conf_get "$s" Domains); do printf '%s\n' "$(domain_primary "$d")"; done
  done < <(stacks_enabled 2>/dev/null) | sort -u
}

# Сырые записи Domains= включённых стеков — по одной на сертификат, вместе с
# алиасами. Это то, из чего certs.sh собирает per-host конфиги getssl.
stacks_domain_specs() {
  local s d
  while IFS= read -r s; do
    for d in $(stack_conf_get "$s" Domains); do printf '%s\n' "$d"; done
  done < <(stacks_enabled 2>/dev/null) | sort -u
}

# ВСЕ имена включённых стеков, включая алиасы. Это то, что обязан обслуживать
# работающий nginx, — в отличие от stacks_domains, которым меряют сертификаты.
stacks_domain_names() {
  local s d a
  while IFS= read -r s; do
    for d in $(stack_conf_get "$s" Domains); do
      printf '%s\n' "$(domain_primary "$d")"
      for a in $(domain_sans "$d"); do printf '%s\n' "$a"; done
    done
  done < <(stacks_enabled 2>/dev/null) | sort -u
}

# ------------------------------------------------- разбор compose-файла
#
# Имена сервисов, томов и образов читаем разбором yaml, а НЕ через
# `docker compose config`: последний требует все env-файлы стека и падает на
# стеке, который как раз выключен или сломан — то есть именно тогда, когда
# `stack.sh list` и `stack.sh purge` обязаны работать. Разбор рассчитан на
# формат этих файлов (два пробела отступа под `services:` / `volumes:`), а
# `stack.sh --check` сверяет результат с `docker compose config --services`
# для включённых стеков, чтобы расхождение не жило незамеченным.

_stacks_yaml_keys() {
  local file="$1" want="$2"
  [ -f "$file" ] || return 0
  awk -v want="$want" '
    /^services:/ { sect = "services"; next }
    /^volumes:/  { sect = "volumes";  next }
    /^[^[:space:]#]/ { sect = ""; next }
    sect == want && /^  [A-Za-z0-9_.-]+:[[:space:]]*(&[A-Za-z0-9_-]+)?[[:space:]]*(#.*)?$/ {
      key = $0
      sub(/^  /, "", key)
      sub(/:.*$/, "", key)
      print key
    }
  ' "$file"
}

# Сервисы, принадлежащие стеку.
#
# Сервисы платформы (nginx, php-fpm) исключаются намеренно: файл стека может
# домешивать в них том, и без этого фильтра `stack.sh disable` снёс бы контейнер
# nginx вместе со всеми сайтами машины.
stack_services() {
  local s="$1" base_services svc
  base_services=$(platform_services)
  while IFS= read -r svc; do
    [ -n "$svc" ] || continue
    if printf '%s\n' "$base_services" | grep -qx -- "$svc"; then
      echo "Предупреждение: стек '$s' домешивает в общий сервис '$svc' — он не будет ни остановлен, ни удалён" >&2
      continue
    fi
    printf '%s\n' "$svc"
  done < <(_stacks_yaml_keys "$(stack_compose_file "$s")" services)
}

# Named volumes, объявленные стеком (bind-mount'ы сюда не попадают и не должны:
# данные на /mnt/data не удаляет никакая команда этого репозитория).
stack_volumes() { _stacks_yaml_keys "$(stack_compose_file "$1")" volumes; }

# Образы, на которые ссылается стек (в формате repository:tag или repository).
stack_images() {
  local f="$(stack_compose_file "$1")"
  [ -f "$f" ] || return 0
  awk '
    /^[[:space:]]+image:[[:space:]]*[^[:space:]]/ {
      v = $0
      sub(/^[[:space:]]*image:[[:space:]]*/, "", v)
      sub(/[[:space:]]+#.*$/, "", v)
      sub(/[[:space:]]*$/, "", v)
      print v
    }
  ' "$f" | tr -d '"'"'" | sort -u
}

# ------------------------------------------------------------------ nginx

# The include lines for enabled stacks that have a non-empty vhost directory.
#
# Ordered by the smallest file name inside each directory, not alphabetically
# by stack name. The vhost files carry numeric prefixes precisely so that their
# reading order is stated rather than inherited from whatever the stacks happen
# to be called; ordering by stack name would change it silently.
stacks_include_lines() {
  local s dir first
  while IFS= read -r s; do
    dir="$(stack_vhost_dir "$s")"
    [ -d "$dir" ] || continue
    first=$(ls -1 "$dir"/*.conf 2>/dev/null | sed 's:.*/::' | sort | head -n 1)
    [ -n "$first" ] || continue
    printf '%s\t%s\n' "$first" "$s"
  done < <(stacks_enabled) | sort | while IFS=$'\t' read -r _ s; do
    printf 'include %s/nginx/*.conf;\n' "$(stack_dir_in_container "$s")"
  done
}

# Включён ли vhost стека в работающем include-файле.
#
# Сверяем ровно ту строку, которую производит stacks_include_lines, а не
# похожую на неё: прошлая версия искала подстроку "conf.d/<стек>/*.conf",
# которой в генерируемом файле нет и никогда не было (там путь вида
# /etc/nginx/stacks/<стек>/nginx/*.conf). Совпадений не было ни разу, поэтому
# `stack.sh list` показывал «выкл» у КАЖДОГО стека с vhost'ами — при включённом
# include. Колонка, которая всегда врёт, хуже отсутствующей: по ней принимают
# решения.
stack_vhost_enabled() {
  local want
  want="include $(stack_dir_in_container "$1")/nginx/*.conf;"
  grep -qxF "$want" "$(stacks_include_file)" 2>/dev/null
}

# Содержимое 10-enabled.conf для текущего манифеста.
# Каталог машины с её собственным http-конфигом (зоны лимитов, карты).
# Монтирование постоянное; пустой каталог законен — include по маске, которая
# ничего не нашла, для nginx не ошибка.
MACHINE_CONF_DIR_IN_CONTAINER="/etc/nginx/machine"

stacks_include_content() {
  cat <<'HDR'
# СГЕНЕРИРОВАННЫЙ ФАЙЛ — правки будут перезаписаны.
# Создаётся scripts/stack.sh из Enabled_Stacks в .env-stacks.
#
# Смысл: nginx включает только conf.d/*.conf верхнего уровня, а vhost'ы стеков
# лежат вне conf.d — в смонтированном /etc/nginx/stacks/<стек>/nginx/. Читаются
# они ТОЛЬКО через include ниже, поэтому стек без строки здесь для nginx не
# существует.
HDR
  # Своё у машины — ПЕРВЫМ: там определения зон и карт, а nginx разрешает их
  # имена в момент разбора server-блока. Политика, зависящая от конкретной
  # машины (какой URI считать логином, какие частоты терпимы её сайтам), в
  # платформе жить не может: она уехала бы на все остальные машины.
  printf 'include %s/*.conf;\n' "$MACHINE_CONF_DIR_IN_CONTAINER"
  stacks_include_lines
}

# Содержимое platform/compose/nginx-static.generated.yaml.
#
# Собирается из Static= ВСЕХ стеков в stacks/, а не только включённых, и
# значения переносятся дословно, без разворачивания ${...}. Ровно это и делает
# текст файла независимым от Enabled_Stacks и от наличия .env у стеков: спека
# nginx, зависящая от набора стеков, означает, что выключение стека
# пересоздаёт nginx — а это уносит ВСЕ vhost'ы, а не только сайты выключаемого
# стека (CLAUDE.md §3.1).
#
# Файл генерируется, а не пишется руками: захардкоженное имя домена в общем
# файле означало бы правку платформы при каждом новом стеке со статикой.
stacks_static_content() {
  local s pair domain path lines=""
  while IFS= read -r s; do
    for pair in $(stack_conf_get "$s" Static); do
      domain="${pair%%:*}"
      path="${pair#*:}"
      lines="$lines      - $path:\${Platform_Vhosts_Mount:?задайте Platform_Vhosts_Mount в корневом .env}/$domain:ro"$'\n'
    done
  done < <(stacks_available)

  cat <<'HDR'
# СГЕНЕРИРОВАННЫЙ ФАЙЛ — правки будут перезаписаны.
# Создаётся scripts/stack.sh из Static= в stacks/*/stack.conf.
#
# Подключается ВСЕГДА, независимо от Enabled_Stacks, и собирается из всех
# стеков, а не из включённых. Это и есть его смысл: том со статикой домешивается
# в сервис nginx из platform/compose/nginx.yaml, и если бы он жил в файле стека,
# выключение стека МЕНЯЛО БЫ спеку nginx — то есть следующий `up -d` пересоздавал
# бы nginx со всеми последствиями из CLAUDE.md §3.1.
#
# Переменные не развёрнуты намеренно: их подставляет compose из корневого .env,
# который загружается всегда. Дефолт `:-./vhosts` в каждой из них обязателен —
# пустой host-путь означает каталог-пустышку от root и молчаливые 404.
HDR

  # Пустой блок volumes — невалидный yaml, и compose падал бы на КАЖДОЙ команде
  # на машине, где ни один стек статики не раздаёт.
  if [ -n "$lines" ]; then
    printf 'services:\n  nginx:\n    volumes:\n%s' "$lines"
  fi
}

# Имя compose-проекта. Берём с метки живого контейнера, а не из basename
# каталога: по метке работают все docker-команды disable/purge, и ошибиться
# здесь означало бы трогать чужие контейнеры.
compose_project() {
  local p
  p=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' nginx 2>/dev/null || true)
  if [ -n "$p" ] && [ "$p" != "<no value>" ]; then printf '%s' "$p"; return 0; fi
  basename "$(stacks_root)" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9_-' '-' | sed 's/-*$//'
}

# Контейнеры сервиса (включая остановленные) по меткам compose.
service_containers() {
  local svc="$1" proj
  proj=$(compose_project)
  docker ps -aq \
    --filter "label=com.docker.compose.project=$proj" \
    --filter "label=com.docker.compose.service=$svc" 2>/dev/null || true
}

# Сервисы, объявленные платформой и ВСЕМИ стеками — включёнными и нет.
#
# Выключенный стек здесь намеренно считается «знакомым»: его оставшиеся
# контейнеры — это отдельная строка проверки («выключен, но остались
# контейнеры») с понятным лечением через stack.sh disable. Бесхозный — это
# другое: сервиса с таким именем не объявляет НИКТО.
stacks_known_services() {
  local s f
  for f in "$(stacks_root)"/platform/compose/*.yaml; do
    [ -f "$f" ] || continue
    _stacks_yaml_keys "$f" services
  done
  while IFS= read -r s; do
    stack_services "$s" 2>/dev/null || true
  done < <(stacks_available)
}

# Контейнеры проекта: «имя<TAB>сервис» по строке на контейнер, включая
# остановленные.
#
# Существует потому, что service_containers() ищет по ИМЕНАМ сервисов из
# compose-файлов и поэтому слеп к тому, чего в них нет. Контейнер
# переименованного или удалённого сервиса иначе не виден ни одной проверке, а
# для watch-host.sh он при этом вечная авария: остановлен, но с
# restart: unless-stopped.
project_containers() {
  local proj
  proj=$(compose_project)
  docker ps -a --filter "label=com.docker.compose.project=$proj" \
    --format '{{.Names}}	{{.Label "com.docker.compose.service"}}' 2>/dev/null || true
}

# ------------------------------------------------------- вывод таблиц

# Ширина строки в СИМВОЛАХ. `printf %-12s` считает байты, поэтому таблица с
# русскими значениями («вкл», «выкл», «ок») разъезжается тем сильнее, чем
# больше в ней кириллицы. Считаем байты, кроме продолжающих байтов UTF-8
# (0x80-0xBF) — это не зависит от локали, а `${#s}` зависит: под LANG=C bash
# посчитает те же байты.
#
# Живёт здесь, а не в stack.sh: таблицу со стеками печатает не он один.
_vislen() { LC_ALL=C printf '%s' "$1" | LC_ALL=C tr -d '\200-\277' | LC_ALL=C wc -c | tr -d ' \n'; }

# Ячейка таблицы: текст, добитый пробелами до нужной ширины.
_cell() {
  local text="$1" width="$2" len
  len=$(_vislen "$text")
  printf '%s' "$text"
  while [ "$len" -lt "$width" ]; do printf ' '; len=$((len + 1)); done
}

# Зоны лимитов, на которые ссылаются vhost'ы включённых стеков, но которых
# никто не определяет.
#
# nginx разрешает имя зоны в момент разбора server-блока: неизвестное имя —
# "unknown limit_req_zone", отказ старта и краш-луп по restart: always. Ровно
# это ждало любую машину, чьи vhost'ы писались под другой набор зон: платформа
# несла зоны одного девбокса, а vhost'ы других просили свои.
#
# Ищем и в платформе, и в nginx/ машины: политика, зависящая от машины, живёт
# там, и зона, объявленная ею, законна не меньше платформенной.
check_limit_zones() {
  local defined used z
  defined=$( { cat "$(stacks_root)/platform/nginx-vhosts"/*.conf 2>/dev/null
               cat "$(stacks_root)/nginx"/*.conf 2>/dev/null; } \
             | grep -oE 'zone=[A-Za-z0-9_]+' | sed 's/zone=//' | sort -u )
  used=$( while IFS= read -r st; do
            d="$(stack_vhost_dir "$st")"; [ -d "$d" ] || continue
            grep -rhoE '(limit_req[[:space:]]+zone=[A-Za-z0-9_]+|limit_conn[[:space:]]+[A-Za-z0-9_]+)' "$d" 2>/dev/null
          done < <(stacks_enabled 2>/dev/null) \
          | sed -E 's/.*zone=//; s/limit_conn[[:space:]]+//' | sort -u )
  for z in $used; do
    printf '%s\n' "$defined" | grep -qx "$z" \
      || printf 'vhost ссылается на зону лимита %s, которой никто не определяет — nginx не стартует\n' "$z"
  done
  return 0
}

# Поддерживает ли закреплённый образ nginx директиву `http2 on`.
#
# Она появилась в 1.25.1 и стоит в platform/nginx-snippets/ssl-params.conf.
# Машина, закрепившая образ старее, получает неизвестную директиву — nginx не
# стартует, и с restart: always это краш-луп, уносящий все сайты. Отказ виден
# только в логах контейнера: снаружи машина просто не отвечает.
#
# Печатает строку на проблему, молчит когда её нет.
# Образ nginx — один на всех, кто его называет. Копий было три: compose (там
# без литерала нельзя), эта проверка и htpasswd.sh, который про
# Platform_Nginx_Image вовсе не знал и запускал свой. На машине с
# переопределённым образом это значило, что файл паролей готовит НЕ тот nginx,
# который его потом читает, — а прав на файл это касается напрямую.
nginx_image() { env_get Platform_Nginx_Image "nginx:1.30-alpine"; }

# check_vhost_dir <каталог>
#
# Всё, что лежит рядом с генерируемым include'ом, читается nginx по маске
# *.conf. Docker, не найдя файла для bind-mount, заводит на его месте КАТАЛОГ
# от root — и тот попадает под маску: nginx падает с «pread() ... failed (21:
# Is a directory)», а с restart: always это краш-луп, уносящий все сайты.
#
# Такой каталог остаётся от прежних спек и переживает обновление платформы:
# state/ машинный, bootstrap его не трогает. Убрать его может только root,
# поэтому в сообщении стоит sudo — без него rm молча не сработает.
#
# Печатает строку на находку, молчит когда их нет.
check_vhost_dir() {
  local dir="${1-}" e
  [ -d "$dir" ] || return 0
  for e in "$dir"/*; do
    [ -e "$e" ] || continue
    [ -f "$e" ] && continue
    printf '%s — не файл, а каталог; nginx читает его по маске *.conf и падает: sudo rm -rf %s\n' "$e" "$e"
  done
}

# mount_looks_stale <файлов на хосте> <файлов в контейнере>
#
# Правило вынесено из stack.sh отдельно, потому что сама сверка требует docker
# и потому в selftest не проверяется — а решение «это устаревший mount» нужно
# проверять. Пустой каталог на хосте не улика: смонтировать пустое законно.
# Улика — непустой на хосте против пустого в контейнере.
mount_looks_stale() {
  [ "${1:-0}" -gt 0 ] && [ "${2:-0}" -eq 0 ]
}

check_nginx_image() {
  local img tag major minor patch
  img="$(nginx_image)"
  tag="${img##*:}"; tag="${tag%%-*}"
  case "$tag" in
    [0-9]*.[0-9]*)
      major="${tag%%.*}"
      minor="${tag#*.}"
      case "$minor" in *.*) patch="${minor#*.}"; minor="${minor%%.*}" ;; *) patch=0 ;; esac
      if [ "$major" -lt 1 ] \
         || { [ "$major" -eq 1 ] && [ "$minor" -lt 25 ]; } \
         || { [ "$major" -eq 1 ] && [ "$minor" -eq 25 ] && [ "$patch" -lt 1 ]; }; then
        printf 'образ %s старее 1.25.1, а ssl-params.conf содержит `http2 on` — nginx не стартует\n' "$img"
      fi
      ;;
    *) printf 'не разобрать версию образа nginx (%s) — проверьте вручную, что он не старее 1.25.1\n' "$img" ;;
  esac
}

# -------------------------------------------- живой nginx против спеки

# «источник<TAB>цель» по каждому bind-mount'у из рендера `docker compose
# config`. Читает stdin.
#
# Спека контейнера и его живое состояние — разные вещи: правка `volumes`
# применяется только пересозданием. До него `docker ps` показывает контейнер
# работающим, `nginx -t` внутри него проходит, и ничто не намекает, что nginx
# смотрит в каталоги, которых на диске уже нет.
compose_mount_pairs() {
  awk '
    $1 == "-" && $2 == "type:"      { ty = $3; src = "" }
    $1 == "source:" && ty == "bind" { src = $2; gsub(/^"|"$/, "", src) }
    $1 == "target:" && src != ""    { tgt = $2; gsub(/^"|"$/, "", tgt)
                                      printf "%s\t%s\n", src, tgt; src = "" }
  '
}

# Домены, которые РЕАЛЬНО обслуживает работающий nginx. Читает вывод
# `nginx -T`, то есть эффективную конфигурацию процесса, а не файлы на диске.
#
# `nginx -t` на этот вопрос не отвечает: конфигурация без единого server-блока
# синтаксически верна и проверку синтаксиса проходит — при том что nginx в
# таком состоянии не слушает вообще ничего.
nginx_served_names() {
  awk '$1 == "server_name" {
         for (i = 2; i <= NF; i++) { gsub(/;/, "", $i); if ($i != "" && $i != "_") print $i }
       }' | sed '/^$/d' | sort -u
}

# ------------------------------------------------------ юниты на машине

# Каталог юнитов systemd. Переопределяется только ради тестов: на машине это
# всегда /etc/systemd/system, и юниты там лежат плоско — отсюда требование
# префикса devbox-<стек>- в имени.
SYSTEMD_UNIT_DIR="${SYSTEMD_UNIT_DIR:-/etc/systemd/system}"

# Юниты стека, РЕАЛЬНО установленные на машине, по одному имени на строку.
#
# Объявленные (stack_units) и установленные — разные множества, и расходятся
# они молча в обе стороны: у включённого стека юнит может быть не поставлен, у
# выключенного — остаться и будить машину по таймеру мёртвого стека.
stack_units_installed() {
  local s="$1" u n
  while IFS= read -r u; do
    [ -n "$u" ] || continue
    n="$(basename "$u")"
    [ -e "$SYSTEMD_UNIT_DIR/$n" ] && printf '%s\n' "$n"
  done < <(stack_units "$s")
  return 0
}

# --------------------------------------------------- здоровье стеков

# Проверка живости стека, если стек её объявил. Наличие файла — и есть
# объявление: отдельного списка нет, как и у vhost'ов, юнитов и logrotate.
stack_health_script() { printf '%s/scripts/health.sh' "$(stack_dir "$1")"; }

