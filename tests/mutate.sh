#!/usr/bin/env bash
#
# Mutation run of the selftest: break the engine one function at a time and see
# whether the test fails.
#
# It exists because a green selftest proves nothing on its own. A run done once
# by hand found 11 uncaught breakages out of 18 -- including the whole two-root
# mechanism. A check that does not fail on broken code is worse than no check:
# it serves as permission not to think.
#
#   ./tests/mutate.sh          all mutations
#   ./tests/mutate.sh mount    only those whose name contains the substring
#
# Works on a CLONE in /tmp: the working tree is not touched at all.

set -uo pipefail

ROOT="$( cd -P "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
FILTER="${1:-}"

# A mutation is: name @@ file @@ what to replace @@ what with.
#
# The separator is @@, not |: a vertical bar occurs inside the patterns
# themselves (regexps like (proxy_pass|fastcgi_pass)), and the mutation silently
# failed to apply -- that is, the run reported a check that never happened.
#
# Each one must be PLAUSIBLE -- the kind of thing you could write by being
# careless. A mutation nobody would ever write checks nothing.
MUTATIONS=(
  'two roots: the profile root switched off@@platform/lib/lib-stacks.sh@@  [ -d "$(stacks_root)/profile/stacks" ] \&\& printf@@  false \&\& printf'
  'two roots: enumeration lists only the machine root@@platform/lib/lib-stacks.sh@@done < <(stack_roots) | sort -u@@done < <(printf "%s/stacks\\n" "$(stacks_root)") | sort -u'
  'stack_dir: root priority reversed@@platform/lib/lib-stacks.sh@@  while IFS= read -r r; do\n    [ -f "$r/$1/stack.conf" ]@@  while IFS= read -r r; do\n    [ -f "$r/$1/stack.conf" ] \&\& [ "$r" != "$(stacks_root)/stacks" ]'
  'include: the profile points at the machine path@@platform/lib/lib-stacks.sh@@    "$(stacks_root)/profile/stacks/"*) printf@@    "$(stacks_root)/NEVER/"*) printf'
  'stack_env_file: .env looked up in the profile@@platform/lib/lib-stacks.sh@@printf '"'"'%s/stacks/%s/.env'"'"'@@printf '"'"'%s/profile/stacks/%s/.env'"'"''
  'domains: aliases are lost@@platform/lib/lib-stacks.sh@@[ "$1" = "${1#*+}" ] ||@@true ||'
  'database order: the prefix is hardcoded@@platform/lib/lib-stacks.sh@@  [ -n "$p" ] \&\& stack_conf_get "$p" Provides_DB@@  [ -n "$p" ] \&\& printf Postgres'
  'backup: the sqlite path formula changed@@platform/lib/lib-env.sh@@printf '"'"'sqlite/%s'"'"'@@printf '"'"'sqlitebackup/%s'"'"''
  'upstream: fastcgi_pass is not counted@@platform/lib/lib-stacks.sh@@(proxy_pass|fastcgi_pass)@@(proxy_pass)'
  'stack_services: platform services not excluded@@platform/lib/lib-stacks.sh@@  base_services=$(platform_services)@@  base_services=""'
  'missing_files: compose is not required@@platform/lib/lib-stacks.sh@@  if [ "$(stack_conf_get "$s" Containers yes)" != "no" ] \&\&@@  if false \&\&'
  'missing_files: example looked up by the machine path@@platform/lib/lib-stacks.sh@@  if [ -f "$(stack_dir "$s")/.env.example" ]@@  if [ -f "$(stacks_root)/stacks/$s/.env.example" ]'
  'units: @STACK_DIR@ loses the root@@platform/lib/lib-stacks.sh@@${DEPLOY_DIR:?}$(_stack_dir_suffix "$stack")@@${DEPLOY_DIR:?}/stacks/$stack'
  'backup: gzip detected as SQLite (A2)@@platform/lib/lib-env.sh@@    1f8b*) ;;                                                          # gzip — look inside@@    1f8b*) printf sqlite_gz; return 0 ;;'
  'backup: tar inside gzip not distinguished@@platform/lib/lib-env.sh@@    7573746172*) printf '"'"'tar_gz'"'"'; return 0 ;;@@    7573746172*) printf unknown; return 0 ;;'
  'seed: the initializer reads a different key (A3)@@profiles/stacks/mysql/db-init/initializer.sh@@yq e '"'"'.dump // ""'"'"' -@@yq e '"'"'.dump_file // ""'"'"' -'
  'fresh machine: state/ is not created (B1)@@platform/lib/lib-stacks.sh@@  mkdir -p "$root/state/nginx-vhosts"@@  mkdir -p "$root/state/NOPE"  #'
  'fresh machine: the provider directory is not created (A5)@@platform/lib/lib-stacks.sh@@  [ -n "$p" ] \&\& mkdir -p "$root/state/$p"@@  [ -n "$p" ] \&\& true'
  'placeholders: the profile stack is not scanned (A4)@@platform/lib/lib-stacks.sh@@  done < <(stacks_available)\n  grep -rhE@@  done < <(stacks_enabled 2>/dev/null | grep -v .)\n  grep -rhE'
  'include: the reader looks for the wrong line (A6)@@platform/lib/lib-stacks.sh@@  want="include $(stack_dir_in_container "$1")/nginx/*.conf;"@@  want="conf.d/$1/*.conf"'
  'health: library taken from the old layout path (A9)@@profiles/stacks/mysql/scripts/health.sh@@. "$ROOT_DIR/platform/lib/lib-env.sh"@@. "$ROOT_DIR/scripts/lib-env.sh"'
  'include: the file sorts before the zones again (A15)@@platform/lib/lib-stacks.sh@@state/nginx-vhosts/10-enabled.conf@@state/nginx-vhosts/00-enabled.conf'
  'http2: the image check is always silent (A16)@@platform/lib/lib-stacks.sh@@        printf '"'"'image %s is older than 1.25.1@@        true \&\& printf '"'"'' # '"'"'image %s is older than 1.25.1'
  'fixtures: environment not built, block skipped (C6)@@platform/bin/selftest.sh@@  fixture_machine "$src" "$m"@@  true'
  'shellcheck: the source= directive does not resolve (C5)@@platform/bin/certs.sh@@# shellcheck source=platform/lib/lib-stacks.sh@@# shellcheck source=../lib/lib-stacks.sh'
  # The selftest does not exercise bootstrap over the network: a run must not
  # depend on the internet. That one is checked by hand, see
  # docs/architecture/platform-delivery.md.
  'sudo -u loses ROOT_DIR@@platform/bin/host-setup.sh@@sudo -u "$DEPLOY_OWNER" env ROOT_DIR="$ROOT_DIR" "$DIR0/certs.sh"@@sudo -u "$DEPLOY_OWNER" "$DIR0/certs.sh"'
  'the package manager is hardcoded again@@platform/bin/host-setup.sh@@    apt-get) apt-get update -qq \&\& apt-get install -y "$@" ;;  # pkg-mgr-ok@@    apt-get) dnf install -y "$@" ;;'
  'static: built from the enabled stacks only@@platform/lib/lib-stacks.sh@@  done < <(stacks_available)\n\n  cat <<@@  done < <(stacks_enabled)\n\n  cat <<'

  # --- block B: a command that is missing on someone else's machine, or that
  # behaves differently there.
  'time: BSD date parses UTC as local (B3)@@platform/lib/lib-env.sh@@  date -j -f '"'"'%Y-%m-%dT%H:%M:%S%z'"'"' "$s" +%s 2>/dev/null \&\& return 0@@  date -j -f '"'"'%Y-%m-%dT%H:%M:%S'"'"' "${s%%%%[+-][0-9][0-9][0-9][0-9]}" +%s 2>/dev/null \&\& return 0'
  'checksums: bare shasum instead of the wrapper (B4)@@platform/bin/check-vendor.sh@@  if [ "$(sha256_file "$f")" != "$sum" ]; then@@  if [ "$(shasum -a 256 "$f" | cut -d'"'"' '"'"' -f1)" != "$sum" ]; then'
  'bash: the version guard is removed (B5)@@platform/lib/lib-env.sh@@if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ] ||@@if false \&\& [ "${BASH_VERSINFO[0]:-0}" -lt 4 ] ||'
  'arguments: $2 without ${2-} under set -u (B8)@@bin/pin.sh@@    --version) WANT="${2-}"; [ -n "$WANT" ] || { echo "Error: --version requires a value" >\&2; exit 2; }; shift 2 ;;@@    --version) WANT="$2"; shift 2 ;;'
  'watchdog: timeout is called directly@@platform/bin/stack.sh@@            run_with_timeout "$HEALTH_TIMEOUT" "$hscript" 2>\&1)" || hrc=$?@@            timeout "$HEALTH_TIMEOUT" "$hscript" 2>\&1)" || hrc=$?'
  'watchdog: the fallback does not return 124@@platform/lib/lib-env.sh@@  [ "$rc" -eq 143 ] \&\& rc=124@@  true'
  'find: -printf again (GNU only)@@platform/bin/backup.sh@@  done < <(find "$TMP_DIR" -maxdepth 1 -type f ! -name '"'"'*.part'"'"' 2>/dev/null)@@  done < <(find "$TMP_DIR" -maxdepth 1 -type f -printf '"'"'%p '"'"' 2>/dev/null)'
  'audit: a machine reported as duplicating itself (B7)@@bin/audit-isolation.sh@@if ($1 == prev \&\& $2 != prevm) print prevm@@if ($1 == prev) print prevm'

  # --- getssl is no longer vendored: references to the copy must not come back.
  'getssl: the unit calls the vendored copy again@@platform/systemd/getssl-renew.service@@ExecStart=@DEPLOY_DIR@/state/bin/getssl@@ExecStart=@DEPLOY_DIR@/platform/getssl'
  'getssl: the checksum in the lock is truncated@@platform/getssl.lock@@sha256=c26d1a714fb96feeed2ac808cf16aae8e453d0005475e47e5732213ab1a7485e@@sha256=c26d1a714fb96feeed2ac808'

  # --- the machine root seen through the platform/ symlink, and htpasswd flags.
  'root: ROOT_DIR stays inside .stackyard@@platform/bin/htpasswd.sh@@  ROOT_DIR="${ROOT_DIR%%/.stackyard/*}"; ROOT_DIR="${ROOT_DIR%/.stackyard}"@@  true'
  'root: only the flat layout is cut back to the machine@@platform/bin/htpasswd.sh@@  ROOT_DIR="${ROOT_DIR%%/.stackyard/*}"; ROOT_DIR="${ROOT_DIR%/.stackyard}"@@  ROOT_DIR="${ROOT_DIR%/.stackyard}"'
  'htpasswd: -b together with -i (usage instead of a password)@@platform/bin/htpasswd.sh@@FLAGS="-iB"@@FLAGS="-ibB"'
  'htpasswd: the host sets ownership, not the container@@platform/bin/htpasswd.sh@@  sh -c "$IN_CONTAINER"@@  sh -c "$IN_CONTAINER"\n\nchmod 640 "$FILE"'
  'nginx: the image is hardcoded past nginx_image@@platform/bin/htpasswd.sh@@"$(nginx_image)"@@nginx:1.30-alpine'

  # --- foreign containers watch-host.sh is responsible for. A mistake here is
  # silence: the alert that never comes looks exactly like a healthy machine.
  'watch: a declared project is not watched@@platform/lib/lib-stacks.sh@@  [ -n "$project" ] \&\& [ "$project" != "-" ] \&\& list_has "$declared" "$project" \&\& return 0@@  true'
  'watch: every foreign container counts as ours@@platform/lib/lib-stacks.sh@@  for n in "$@"; do\n    [ -n "$n" ] \&\& list_has "$upstreams" "$n" \&\& return 0\n  done\n  return 1@@  return 0'
  'watch: projects of disabled stacks are watched too@@platform/lib/lib-stacks.sh@@  for s in $(stacks_enabled 2>/dev/null); do\n    for p in $(stack_conf_get "$s" Watch_Project)@@  for s in $(stacks_available 2>/dev/null); do\n    for p in $(stack_conf_get "$s" Watch_Project)'
  'watch-host: the declared projects are never read@@platform/bin/watch-host.sh@@WATCHED_PROJECTS=$(stacks_watch_projects)@@WATCHED_PROJECTS=""'

  # --- a profile port published past the host firewall.
  'ports: pg is published on every interface again@@profiles/stacks/pg/compose.yaml@@      - "127.0.0.1:5432:5432"@@      - "5432:5432"'

  # --- the platform version nginx mounts, and how bootstrap switches it.
  # Each of these brings back an nginx that is blind after ./bootstrap, and
  # nothing says so until a visitor finds every domain gone.
  'layer: nginx mounts the version, not .stackyard@@platform/lib/lib-stacks.sh@@  if [ -n "$(layer_link_target "$1")" ]; then\n    printf@@  if false; then\n    printf'
  'layer: nginx reads the platform past current@@platform/lib/lib-stacks.sh@@  printf '"'"'/stackyard/%s%s'"'"' "$1" "${t:+/$t}"@@  printf '"'"'/stackyard/%s'"'"' "$1"'
  'layer: the decision ignores the link in the machine root@@platform/lib/lib-stacks.sh@@  case "$l" in .stackyard/current/*) printf@@  [ -L "$(stacks_root)/.stackyard/current" ] \&\& l=.stackyard/current/platform\n  case "$l" in .stackyard/current/*) printf'
  'entrypoint: conf.d is not linked@@platform/compose/nginx-entrypoint.sh@@link "$STACKYARD_PLATFORM_DIR/nginx-vhosts"   /etc/nginx/conf.d@@: conf.d'
  'bootstrap: an update replaces .stackyard again@@templates/machine/bootstrap@@  rm -rf "$DEST.tmp" "$NEW"@@  rm -rf "$DEST.tmp" "$NEW" "$DEST"'
  'bootstrap: the flat layout is deleted, not moved@@templates/machine/bootstrap@@  mv "$DEST" "$DEST.flat"@@  rm -rf "$DEST"; mkdir -p "$DEST.flat"'
  'bootstrap: previous is cleaned up with the rest@@templates/machine/bootstrap@@  case "versions/${d##*/}" in "$keep_cur"|"$keep_prev") continue ;; esac@@  case "versions/${d##*/}" in "$keep_cur") continue ;; esac'
  'bootstrap: previous is not recorded@@templates/machine/bootstrap@@  [ -n "$prev" ] \&\& swap_link "$prev" "$DEST/previous"@@  true'
  'bootstrap: the kept version is fetched again@@templates/machine/bootstrap@@elif [ "$(cat "$NEW/.commit" 2>/dev/null)" = "$want" ]; then@@elif false; then'
  'bootstrap: the machine links bypass current@@templates/machine/bootstrap@@ln -sfn .stackyard/current/platform "$ROOT/platform"@@ln -sfn .stackyard/versions/$want/platform "$ROOT/platform"'

  # --- a stale bind-mount left over after ./bootstrap.
  'mount: an empty host side also counts as evidence@@platform/lib/lib-stacks.sh@@  [ "${1:-0}" -gt 0 ] \&\& [ "${2:-0}" -eq 0 ]@@  [ "${2:-0}" -eq 0 ]'
  'mount: the evidence is not recognized at all@@platform/lib/lib-stacks.sh@@  [ "${1:-0}" -gt 0 ] \&\& [ "${2:-0}" -eq 0 ]@@  false'

  # --- a rename of the generated file that never reached its consumers (A15).
  'compose: a file mounted inside a :ro directory@@platform/compose/nginx.yaml@@      - ${Platform_Deploy_Dir:?}/state/nginx-vhosts:/etc/nginx/enabled:ro@@      - ${Platform_Deploy_Dir:?}/state/nginx-vhosts/10-enabled.conf:/etc/nginx/conf.d/10-enabled.conf:ro'
  'vhost: a stray directory goes unnoticed@@platform/lib/lib-stacks.sh@@    [ -f "$e" ] \&\& continue@@    continue'
  'vhost: the directory check is not called before writing@@platform/bin/stack.sh@@  junk="$(check_vhost_dir "$(dirname "$file")")"@@  junk=""'
  'compose: the state directory is not mounted at all@@platform/compose/nginx.yaml@@      - ${Platform_Deploy_Dir:?}/state/nginx-vhosts:/etc/nginx/enabled:ro@@      - ${Platform_Deploy_Dir:?}/nginx:/etc/nginx/enabled:ro'
  'nginx: the platform does not read the state directory@@platform/nginx-vhosts/05-enabled.conf@@include /etc/nginx/enabled/*.conf;@@# include removed'
  'generator: the name is matched by a pattern@@platform/bin/docker-compose.sh@@  if [ "$gen" = "$(stacks_static_file)" ]; then@@  case "$gen" in *00-enabled.conf) :;; esac\n  if [ "$gen" = "$(stacks_static_file)" ]; then'
  'compose: the generated file name is written a second time@@platform/bin/docker-compose.sh@@  -f "$STATIC_REL"@@  -f state/nginx-static.generated.yaml'

  # --- Certs="external": the whole mechanism fails SILENTLY when it breaks.
  # A stack that should be left alone quietly gets a getssl config again, or a
  # machine that needs no renewal quietly keeps its timers -- in both cases
  # everything still runs and nothing says anything, which is why each of
  # these is worth a mutation of its own.
  'certs: an external stack is fed to getssl again@@platform/lib/lib-stacks.sh@@stacks_domain_specs() {\n  local s d\n  while IFS= read -r s; do\n    stack_certs_external "$s" \&\& continue@@stacks_domain_specs() {\n  local s d\n  while IFS= read -r s; do\n    true'
  'certs: any declared value counts as external@@platform/lib/lib-stacks.sh@@stack_certs_external() { [ "$(stack_conf_get "$1" Certs getssl)" = external ]; }@@stack_certs_external() { [ -n "$(stack_conf_get "$1" Certs getssl)" ]; }'
  'certs: an unknown value is read as the default@@platform/lib/lib-stacks.sh@@    case "$m" in getssl|external) continue ;; esac@@    case "$m" in *) continue ;; esac'
  'certs: the machine always wants getssl timers@@platform/lib/lib-stacks.sh@@  [ -z "$(stacks_enabled 2>/dev/null)" ] || [ -n "$(stacks_domains_getssl)" ]@@  true'
  'certs: an empty manifest reads as nothing needing getssl@@platform/lib/lib-stacks.sh@@  [ -z "$(stacks_enabled 2>/dev/null)" ] || [ -n "$(stacks_domains_getssl)" ]@@  [ -n "$(stacks_domains_getssl)" ]'

  # --- stack init: a profile stack's .env silently not created, or a secrets
  # file created readable by everyone on the host.
  'init: the example looked up by the machine path@@platform/bin/stack.sh@@    ex="$(stack_dir "$s")/.env.example"@@    ex="$ROOT_DIR/stacks/$s/.env.example"'
  'init: the copy keeps the example'"'"'s mode@@platform/bin/stack.sh@@  ( umask 077 \&\& cp "$1" "$2" )@@  cp "$1" "$2"'

  # --- what only a live nginx can refuse. The text checks passed this one; the
  # image rejects it as a duplicate directive and does not start.
  'nginx: a vhost sets http2 next to ssl-params.conf@@tests/machines/alpha/stacks/site/nginx/01-app.example.com.conf@@	listen		443 ssl;@@	listen		443 ssl;\n	http2		on;'
  'nginx: a vhost points at a certificate nobody makes@@tests/machines/beta/stacks/service/nginx/01-svc.example.net.conf@@/etc/nginx/certs/svc.example.net-fullchain.crt@@/etc/nginx/certs/svc.example.org-fullchain.crt'

  # --- the operator CLI. The first one is the contract the whole installer
  # rests on: a lock must get the installed commit, and the mirror's HEAD is a
  # plausible-looking wrong answer.
  'cli: the lock is written from the mirror'"'"'s HEAD@@bin/lib-workspace.sh@@  if ws_installed; then\n    cat "$ROOT/.commit"@@  if false; then\n    cat "$ROOT/.commit"'
  'cli: the link in ~/.local/bin is not followed@@bin/stackyard@@while [ -L "$self" ]; do@@while false; do'
  'install: a release without the CLI becomes current@@install.sh@@mgit cat-file -e "$COMMIT:bin/stackyard" 2>/dev/null@@true'
  'store: the fleet list read from the home again@@bin/lib-workspace.sh@@ws_fleet_file() { printf '"'"'%s/fleet'"'"' "$(ws_store)"; }@@ws_fleet_file() { printf '"'"'%s/.stackyard-fleet'"'"' "$HOME"; }'
  'store: installed back into the home directory@@install.sh@@DIR="${STACKYARD_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/stackyard}"@@DIR="${STACKYARD_DIR:-$HOME/.stackyard}"'
  'fleet: a machines_dir line is taken for a path@@bin/lib-workspace.sh@@      machines_dir=*)@@      NEVER=*)'
  'fleet: the first add starts an empty list next to the old one@@bin/fleet.sh@@    if [ -f "$HOME/.stackyard-fleet" ]; then@@    if false; then'
  # --- --json: a program reads it, so a broken one is broken silently.
  'json: the human report lands on stdout@@platform/bin/stack.sh@@  exec 3>&1 1>&2@@  exec 3>&1'
  'json: a double quote is not escaped@@platform/lib/lib-env.sh@@  s="${s//\"/\\\"}"@@  :'
  'new: the machine is left without a repository@@bin/new-machine.sh@@  git -C "$DEST" init -q \&\& echo@@  true \&\& echo'
  # --- sync applies the manifest and never edits it; --manifest-only edits it
  # and touches nothing else.
  'sync: a manifest missing a dependency is applied anyway@@platform/bin/stack.sh@@      if ! stack_is_enabled "$req"; then\n        bad "$s requires@@      if false; then\n        bad "$s requires'
  'sync: a database consumer without containers is left out@@platform/bin/stack.sh@@      [ -n "$s" ] \&\& [ -n "$(stack_conf_get "$s" "$(stacks_db_prefix)_DB")" ] || continue@@      continue'
  'sync: nginx is left down on a fresh machine@@platform/bin/stack.sh@@  if ! nginx_running; then\n    step "nginx container"@@  if false; then\n    step "nginx container"'
  'manifest-only: the machine is changed too@@platform/bin/stack.sh@@  [ "$MANIFEST_ONLY" -eq 1 ] \&\& { manifest_only_done; return 0; }\n  stacks_bring_up@@  stacks_bring_up'
  'check: a manifest that differs from git goes unreported@@platform/bin/stack.sh@@      elif ! git -C "$ROOT_DIR" diff --quiet HEAD -- "$MANIFEST" 2>/dev/null; then@@      elif false; then'
  # --- the backup units after a layout change: three silent nights on a real
  # machine, and every one of these brings that back.
  'backup: the key default differs between the scripts again@@platform/lib/lib-env.sh@@  p="$(env_get Backup_GPG_Pubkey "gpg/backup-pubkey.asc")"@@  p="$(env_get Backup_GPG_Pubkey "platform/gpg/backup-pubkey.asc")"'
  'backup: no .env-backup leaves the old units firing@@platform/bin/systemd.sh@@if [ "$INSTALL_BACKUP" -eq 0 ] \&\& [ "$BACKUP_BROKEN" -eq 0 ]; then\n  for name in "${BACKUP_UNITS[@]}"; do@@if false; then\n  for name in "${BACKUP_UNITS[@]}"; do'
  'backup: a broken .env-backup takes the units away@@platform/bin/systemd.sh@@if [ "$INSTALL_BACKUP" -eq 0 ] \&\& [ "$BACKUP_BROKEN" -eq 0 ]; then\n  for name in "${BACKUP_UNITS[@]}"; do@@if [ "$INSTALL_BACKUP" -eq 0 ]; then\n  for name in "${BACKUP_UNITS[@]}"; do'
  'backup: a broken .env-backup passes for success@@platform/bin/systemd.sh@@if [ "$BACKUP_BROKEN" -eq 1 ]; then\n  echo >\&2@@if false; then\n  echo >\&2'
  'units: --check does not look at ExecStart@@platform/bin/systemd.sh@@        /*) [ -e "$cmd" ] || problem@@        /*) true || problem'
  'units: --check compares by existence only@@platform/bin/systemd.sh@@  elif [ "$(cat "$f")" != "$want" ]; then@@  elif false; then'
  # --- the backup list: each of these is a backup that goes quiet, or a check
  # that calls it fine.
  'sources: a stack that cannot be read is forgotten@@platform/lib/lib-env.sh@@      rc=1\n      continue@@      continue'
  'check-backups: a Backup_DB source is not expected@@platform/bin/check-backups.sh@@    db)     case " ${EXPECTED@@    NEVER)  case " ${EXPECTED'
  'check-backups: a failed globals hook reads as empty@@platform/bin/check-backups.sh@@"$hook" globals 2>/dev/null); then@@"$hook" globals 2>/dev/null || true); then'
  'check-backups: nothing expected passes as fresh@@platform/bin/check-backups.sh@@if [ ${#EXPECTED[@]} -eq 0 ] \&\& [ "$problems" -eq 0 ]; then@@if false; then'
  # --- the Postgres initializer (run with the live-database block).
  'pg init: a failed statement does not stop it@@profiles/stacks/pg/db-init/initializer.sh@@-v ON_ERROR_STOP=1 "$@"@@-v ON_ERROR_STOP=0 "$@"'
  'pg init: a failed seed leaves its database behind@@profiles/stacks/pg/db-init/initializer.sh@@                sql -d postgres -v d="$DB_NAME" <<< "DROP DATABASE :\"d\";" || true@@                true'
  'audit: a prefix of the shared secret is printed again@@bin/audit-isolation.sh@@    bad "$key is identical on machines $m1 and $m2"@@    bad "$key is identical on machines $m1 and $m2 (value: ${val:0:24}...)"'
  'install: PATH is appended on every run@@install.sh@@    elif grep -qF "$line" "$rc" 2>/dev/null; then@@    elif false; then'
)

# The baseline first: the selftest must pass on an UNMUTATED copy made the way
# every mutation's copy is. If it does not, each mutation below fails the
# selftest for a reason of its own making and is reported as caught. That is
# not hypothetical: from v0.28.0 the CLI block failed in any copy without .git,
# and two full runs reported everything caught while proving nothing.
#
# The live-database block of the selftest is slow and off by default; it runs
# for the mutations of an initializer, the only ones it can catch, and then for
# the baseline too.
live_for() { case "$1" in */db-init/*) printf 1 ;; esac; }
BASE_LIVE=""
for m in "${MUTATIONS[@]}"; do
  IFS=$'\034' read -r name file old new <<< "${m//@@/$'\034'}"
  case "$name" in *"$FILTER"*) [ -n "$(live_for "$file")" ] && BASE_LIVE=1 ;; esac
done
W=$(mktemp -d); cp -R "$ROOT"/. "$W"/ 2>/dev/null; rm -rf "$W/.git"
if ! ( cd "$W" && STACKYARD_LIVE_DB="$BASE_LIVE" ./platform/bin/selftest.sh ) > "$W.baseline.log" 2>&1; then
  echo "REFUSING: the selftest fails on an unmutated copy, so every mutation would look caught." >&2
  grep -E '✗|expected|got:' "$W.baseline.log" | head -n 20 >&2
  rm -rf "$W" "$W.baseline.log"; exit 1
fi
rm -rf "$W" "$W.baseline.log"

pass=0; miss=0
printf '%-58s %s\n' MUTATION RESULT
for m in "${MUTATIONS[@]}"; do
  IFS=$'\034' read -r name file old new <<< "${m//@@/$'\034'}"
  case "$name" in *"$FILTER"*) ;; *) continue ;; esac

  W=$(mktemp -d); cp -R "$ROOT"/. "$W"/ 2>/dev/null
  rm -rf "$W/.git"

  # python does the replacement: sed over multi-line patterns with quotes in
  # them is unreliable, and a mutation that did not apply is a test that
  # "caught" a breakage that was never there. So application is verified, and a
  # mutation that did not apply counts as a failure of the run, not a success.
  applied=$(W="$W" F="$file" O="$old" N="$new" python3 - <<'PY'
import io, os
p = os.path.join(os.environ['W'], os.environ['F'])
s = io.open(p, encoding='utf-8').read()
old = os.environ['O'].replace('\\n', '\n').replace('\\&', '&')
new = os.environ['N'].replace('\\n', '\n').replace('\\&', '&')
if old in s:
    io.open(p, 'w', encoding='utf-8').write(s.replace(old, new, 1)); print('yes')
else:
    print('no')
PY
)
  if [ "$applied" != yes ]; then
    printf '%-58s \033[33mDID NOT APPLY\033[0m (pattern is stale)\n' "$name"
    rm -rf "$W"; miss=$((miss + 1)); continue
  fi

  if ( cd "$W" && STACKYARD_LIVE_DB="$(live_for "$file")" ./platform/bin/selftest.sh ) >/dev/null 2>&1; then
    printf '%-58s \033[31mNOT CAUGHT\033[0m\n' "$name"; miss=$((miss + 1))
  else
    printf '%-58s caught\n' "$name"; pass=$((pass + 1))
  fi
  rm -rf "$W"
done

echo
echo "caught: $pass, missed: $miss"
[ "$miss" -eq 0 ]
