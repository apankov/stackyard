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
  # depend on the internet. That one is checked by hand, see README.
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
  'root: ROOT_DIR stays inside .stackyard@@platform/bin/htpasswd.sh@@  [ "${ROOT_DIR##*/}" = .stackyard ] \&\& ROOT_DIR="${ROOT_DIR%/*}"@@  true'
  'htpasswd: -b together with -i (usage instead of a password)@@platform/bin/htpasswd.sh@@FLAGS="-iB"@@FLAGS="-ibB"'
  'htpasswd: the host sets ownership, not the container@@platform/bin/htpasswd.sh@@  sh -c "$IN_CONTAINER"@@  sh -c "$IN_CONTAINER"\n\nchmod 640 "$FILE"'
  'nginx: the image is hardcoded past nginx_image@@platform/bin/htpasswd.sh@@"$(nginx_image)"@@nginx:1.30-alpine'

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
)

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

  if ( cd "$W" && ./platform/bin/selftest.sh ) >/dev/null 2>&1; then
    printf '%-58s \033[31mNOT CAUGHT\033[0m\n' "$name"; miss=$((miss + 1))
  else
    printf '%-58s caught\n' "$name"; pass=$((pass + 1))
  fi
  rm -rf "$W"
done

echo
echo "caught: $pass, missed: $miss"
[ "$miss" -eq 0 ]
