#!/usr/bin/env bash

# Tests of the platform's engines against synthetic stacks.
#
#   ./platform/bin/selftest.sh
#
# This exists because the generators cannot be exercised on a live machine
# without breaking it: a wrong include file means no vhosts at all, and a wrong
# statics file means nginx gets recreated. Here ROOT_DIR is replaced by a
# temporary directory holding a few invented stacks, and what is checked is
# exactly the text the generators produce.
#
# In shell, rather than anything else, for the same reason the subject itself
# is in shell: a machine may carry no other runtime, and a harness in another
# language would be testing something else.

set -uo pipefail

DIR0="$( cd -P "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# The stackyard root rather than a machine's: the subject here is the engine.
REPO_DIR="$( cd "$DIR0/../.." && pwd )"
LIB_DIR="$( cd "$DIR0/../lib" && pwd )"

# Fixture machines. There are two of them, with DIFFERENT database engines, on
# purpose: the platform counts as shared exactly when both run on it without a
# single edit, and the only way to check that is to run the engine on both.
FIXTURES="$REPO_DIR/tests/machines"

failures=0
check() {
  if [ "$2" = "$3" ]; then
    printf '  ✓ %s\n' "$1"
  else
    printf '  ✗ %s\n    expected: [%s]\n    got:      [%s]\n' "$1" "$3" "$2"
    failures=$((failures + 1))
  fi
}

# fixture <stack name> <path relative to the stack> <contents>
# Creates a file inside $WORK/stacks/<name>/, making directories along the way.
fixture() {
  local stack="$1" rel="$2" content="$3"
  mkdir -p "$WORK/stacks/$stack/$(dirname "$rel")"
  printf '%s\n' "$content" > "$WORK/stacks/$stack/$rel"
  # What makes a directory a stack is stack.conf, not its mere existence —
  # otherwise stacks/<stack>/.env, which a machine creates for ANY stack, would
  # declare one. Without this, a fixture defining only a vhost or only a
  # compose file would be invisible to the engine, and half the tests would be
  # asserting things about emptiness.
  [ -f "$WORK/stacks/$stack/stack.conf" ] || : > "$WORK/stacks/$stack/stack.conf"
}

# fixture_root <root> <stack> <file> <contents>
# The same, but into the given root: this checks that the engine sees stacks in
# both the machine's stacks/ and the profile's profile/stacks/, and that the
# machine's copy shadows the profile's.
fixture_root() {
  local root="$1" stack="$2" rel="$3" content="$4"
  mkdir -p "$WORK/$root/$stack/$(dirname "$rel")"
  printf '%s\n' "$content" > "$WORK/$root/$stack/$rel"
  [ -f "$WORK/$root/$stack/stack.conf" ] || : > "$WORK/$root/$stack/stack.conf"
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/platform/lib" "$WORK/platform/nginx-vhosts" "$WORK/platform/compose" "$WORK/state" "$WORK/stacks"
# Both libraries: lib-stacks.sh reads stack.conf without substitutions, while
# lib-env.sh is needed for stack_backup_sources, where substitutions are
# expanded.
cp "$LIB_DIR/lib-stacks.sh" "$LIB_DIR/lib-env.sh" "$WORK/platform/lib/"
printf 'services:\n  nginx:\n    image: nginx\n' > "$WORK/platform/compose/nginx.yaml"

# Read by the libraries sourced below, not by this file.
# shellcheck disable=SC2034
ROOT_DIR="$WORK"
# shellcheck source=platform/lib/lib-stacks.sh
. "$WORK/platform/lib/lib-stacks.sh"
# shellcheck source=platform/lib/lib-env.sh
. "$WORK/platform/lib/lib-env.sh"

echo "== vhost includes"

# Two stacks whose file prefixes run COUNTER to the alphabetical order of their
# names: alpha gets 20-, zulu gets 10-. The order of the includes must follow
# the prefixes rather than the stack names — which vhost nginx reads first
# depends on it.
fixture alpha stack.conf 'Requires=""'
fixture alpha compose.yaml 'services:
  alpha-app:
    image: alpine'
fixture alpha nginx/20-alpha.test.conf 'server {
    server_name alpha.test;
}'
fixture zulu stack.conf 'Requires=""'
fixture zulu compose.yaml 'services:
  zulu-app:
    image: alpine'
fixture zulu nginx/10-zulu.test.conf 'server {
    server_name zulu.test;
}'
printf 'Enabled_Stacks="alpha zulu"\n' > "$WORK/.env-stacks"

got=$(stacks_include_lines)
want='include /etc/nginx/stacks/zulu/nginx/*.conf;
include /etc/nginx/stacks/alpha/nginx/*.conf;'
check "include order follows file prefixes, not stack names" "$got" "$want"

echo "== the two stack roots"

# The platform's central mechanism, and a mutation run showed it was covered by
# nothing: disable the profile root in stack_dir or in stacks_available and not
# one test failed.
#
# "Link" and "copy" are expressed by THESE TWO ROOTS and nothing else; there is
# no separate switch. So a mistake here does not break anything visible — it
# makes a profile stack invisible: its preflight never runs, its stack.conf is
# never read, its vhost is never included, all silently.
fixture_root profile/stacks papa stack.conf 'Requires=""
Domains="papa.test"'
fixture_root profile/stacks papa compose.yaml 'services:
  papa-app:
    image: alpine'
fixture_root profile/stacks papa nginx/50-papa.conf 'server { server_name papa.test; }'
fixture_root profile/stacks quebec stack.conf 'Requires=""'
printf 'Enabled_Stacks="papa quebec alpha"\n' > "$WORK/.env-stacks"

check "a profile stack appears in the list" \
  "$(stacks_available | grep -cx papa)" "1"
check "a profile stack's directory is the profile's" \
  "$(stack_dir papa)" "$WORK/profile/stacks/papa"
check "a profile stack's compose file is found" \
  "$(stack_compose_file papa)" "$WORK/profile/stacks/papa/compose.yaml"
check "a profile stack's domain is visible" \
  "$(stacks_domains | grep -cx papa.test)" "1"

# A stack's .env is ALWAYS the machine's, even for a profile stack: the profile
# is updated as a whole, and a secret inside it would be wiped by the next
# update.
check "a profile stack's .env is in the machine root" \
  "$(stack_env_file papa)" "$WORK/stacks/papa/.env"

# The include must point at the root the stack actually lives in: otherwise,
# after the stack is copied into the machine's, nginx would keep reading the
# profile's copy.
check "a profile stack's include points into the profile directory" \
  "$(stacks_include_lines | grep -c '/etc/nginx/profile-stacks/papa/nginx')" "1"

# The .env example is looked for NEXT TO THE STACK, while the .env itself is in
# the machine root. Looking for the example along the machine path would mean a
# profile stack's .env requirement is never checked at all, and the stack
# counts as complete without its secrets.
fixture_root profile/stacks papa .env.example 'Papa_Secret=CHANGE_ME'
# A stack with containers of its own must have a compose.yaml. Tolerating its
# absence silently would turn a forgotten file into "a stack without
# containers" — a valid config in which nothing starts.
fixture victor stack.conf 'Requires=""'
check "a stack with no compose.yaml and no Containers=no is incomplete" \
  "$(stack_missing_files victor | grep -c 'compose.yaml')" "1"
fixture whiskey stack.conf 'Requires=""
Containers="no"'
check "with Containers=no there is nothing to report" "$(stack_missing_files whiskey)" ""

check "a profile stack needs an .env because it has an example" \
  "$(stack_missing_files papa)" "stacks/papa/.env"
printf 'x\n' > "$WORK/stacks/papa/.env" 2>/dev/null || { mkdir -p "$WORK/stacks/papa"; printf 'x\n' > "$WORK/stacks/papa/.env"; }
check "with the machine's .env there is nothing to report" "$(stack_missing_files papa)" ""

# The machine root shadows the profile's — that is what detaching means. A
# stack is declared by the directory holding stack.conf: half a copy is not a
# stack.
mkdir -p "$WORK/stacks/papa"
: > "$WORK/stacks/papa/.env"
check "a directory holding only .env does NOT shadow a profile stack" \
  "$(stack_dir papa)" "$WORK/profile/stacks/papa"
fixture papa stack.conf 'Requires=""
Domains="papa.test"'
check "the machine's copy shadows the profile's" \
  "$(stack_dir papa)" "$WORK/stacks/papa"
check "after copying, the include points into the machine directory" \
  "$(stacks_include_lines | grep -c '/etc/nginx/stacks/papa/nginx')" "0"
rm -rf "$WORK/stacks/papa"

# A profile stack's unit must point at the profile directory ON THE SERVER.
fixture_root profile/stacks papa systemd/devbox-papa-x.service '[Service]
ExecStart=@STACK_DIR@/scripts/x.sh'
check "a profile stack's unit points into the profile" \
  "$( DEPLOY_DIR=/srv/m SERVICE_USER=u ONFAILURE= \
      unit_render "$WORK/profile/stacks/papa/systemd/devbox-papa-x.service" papa \
      | grep -c 'ExecStart=/srv/m/profile/stacks/papa/scripts/x.sh' )" "1"

echo "== stack.conf"

fixture bravo stack.conf 'Requires="pg qdrant"
Domains="bravo.test"
Static="bravo.test:${Bravo_Static_Dir:-./vhosts}/public"'
fixture bravo compose.yaml 'services:
  bravo-app:
    image: alpine'

check "Requires is read" "$(stack_conf_get bravo Requires)" "pg qdrant"
check "Domains is read" "$(stack_conf_get bravo Domains)" "bravo.test"
# The key property: the platform does NOT expand ${...} in Static. Expanding it
# here would mean the text of the nginx spec depends on whether a stack has an
# .env — that is, on whether it is enabled.
check "Static is returned verbatim, without substitution" \
  "$(stack_conf_get bravo Static)" 'bravo.test:${Bravo_Static_Dir:-./vhosts}/public'
check "a missing key yields the default" "$(stack_conf_get bravo Nope def)" "def"
check "стек без stack.conf не роняет чтение" "$(stack_conf_get nosuch Domains)" ""
check "stack_requires читает из файла" "$(stack_requires bravo)" "pg qdrant"

echo "== генерация статики"

fixture charlie stack.conf 'Static="charlie.test:${Charlie_Dir:-./vhosts}/pub"'
fixture charlie compose.yaml 'services:
  charlie-app:
    image: alpine'

printf 'Enabled_Stacks="alpha zulu bravo charlie"\n' > "$WORK/.env-stacks"
with_all=$(stacks_static_content)
printf 'Enabled_Stacks="alpha"\n' > "$WORK/.env-stacks"
with_one=$(stacks_static_content)

# The central invariant: the text of the nginx spec is the same for any set of
# enabled stacks. Otherwise disabling a stack changes the spec, the next up -d
# recreates nginx, and every site goes down at once.
check "the statics text does not depend on Enabled_Stacks" "$with_all" "$with_one"
check "a declared volume made it into the file" \
  "$(printf '%s' "$with_all" | grep -c 'charlie.test')" "1"
check "the substitution was not expanded" \
  "$(printf '%s' "$with_all" | grep -c '${Charlie_Dir:-./vhosts}')" "1"

# Stacks without Static must not produce an empty volumes block: that is
# invalid YAML, and compose would fail on EVERY command.
rm -f "$WORK/stacks/charlie/stack.conf" "$WORK/stacks/bravo/stack.conf"
check "with no Static at all the file is valid and has no volumes" \
  "$(stacks_static_content | grep -c 'volumes:')" "0"

echo "== domains"

fixture delta stack.conf 'Domains="d1.test d2.test"'
fixture delta compose.yaml 'services:
  delta-app:
    image: alpine'
fixture bravo stack.conf 'Domains="bravo.test"'
printf 'Enabled_Stacks="delta bravo"\n' > "$WORK/.env-stacks"

check "domains are collected from enabled stacks, deduplicated and sorted" \
  "$(stacks_domains | tr '\n' ' ')" "bravo.test d1.test d2.test "

printf 'Enabled_Stacks="bravo"\n' > "$WORK/.env-stacks"
check "a disabled stack contributes no domains" "$(stacks_domains | tr '\n' ' ')" "bravo.test "

echo "== stack units"

fixture echo1 stack.conf 'Requires=""'
fixture echo1 compose.yaml 'services:
  echo1-app:
    image: alpine'
fixture echo1 systemd/devbox-echo1-job.service '[Service]
ExecStart=@STACK_DIR@/scripts/job.sh
WorkingDirectory=@DEPLOY_DIR@
User=@SERVICE_USER@
@ONFAILURE@'

check "a stack's units are found by directory, with no declaration in stack.conf" \
  "$(stack_units echo1 | while IFS= read -r f; do basename "$f"; done | tr '\n' ' ')" \
  "devbox-echo1-job.service "
check "a stack without a systemd/ directory contributes no units" "$(stack_units alpha)" ""

rendered=$(DEPLOY_DIR=/opt/devbox SERVICE_USER=ec2-user ONFAILURE='OnFailure=x.service' \
           unit_render "$WORK/stacks/echo1/systemd/devbox-echo1-job.service" echo1)
check "@STACK_DIR@ was substituted" \
  "$(printf '%s' "$rendered" | grep -c '/opt/devbox/stacks/echo1/scripts/job.sh')" "1"
check "@DEPLOY_DIR@ was substituted" \
  "$(printf '%s' "$rendered" | grep -c '^WorkingDirectory=/opt/devbox$')" "1"
# A placeholder left inside a unit is swallowed silently by systemd as part of
# a path, and the timer then runs a non-existent command every night.
check "no placeholders remain" \
  "$(printf '%s' "$rendered" | grep -c '@[A-Z_]*@')" "0"

# Declared units and installed ones are different sets. Their divergence is
# what enable/disable now reconcile themselves and what --check catches when
# they could not: for an enabled stack the job never runs at all, and for a
# disabled one the machine wakes on a dead stack's timer.
mkdir -p "$WORK/systemd-units"
# Read by lib-stacks.sh, not by this file.
# shellcheck disable=SC2034
SYSTEMD_UNIT_DIR="$WORK/systemd-units"
check "a declared but uninstalled unit is not listed as installed" \
  "$(stack_units_installed echo1)" ""
: > "$WORK/systemd-units/devbox-echo1-job.service"
check "an installed stack unit is visible" \
  "$(stack_units_installed echo1)" "devbox-echo1-job.service"
check "another stack's unit in the directory is not attributed to this one" \
  "$(: > "$WORK/systemd-units/devbox-other-job.service"; stack_units_installed echo1)" \
  "devbox-echo1-job.service"

echo "== backup sources"

fixture foxtrot stack.conf 'Backup_Sqlite="${Foxtrot_DB_Dir}/${Foxtrot_DB_File}"
Backup_Files="/mnt/data/foxtrot"
Backup_Volume="foxtrot-data"'
fixture foxtrot compose.yaml 'services:
  foxtrot-app:
    image: alpine'
printf 'Foxtrot_DB_Dir=/mnt/data/fox\nFoxtrot_DB_File=f.db\n' > "$WORK/stacks/foxtrot/.env"
printf 'Enabled_Stacks="foxtrot bravo"\n' > "$WORK/.env-stacks"

# Here substitutions ARE expanded, unlike Static: backup.sh works only on
# enabled stacks, and an enabled stack has an .env by construction.
check "Backup_Sqlite is expanded from the stack's .env" \
  "$(stack_backup_sources foxtrot | grep '^sqlite:')" "sqlite:/mnt/data/fox/f.db"
check "Backup_Files made it into the list" \
  "$(stack_backup_sources foxtrot | grep '^files:')" "files:/mnt/data/foxtrot"
check "Backup_Volume made it into the list" \
  "$(stack_backup_sources foxtrot | grep '^volume:')" "volume:foxtrot-data"
check "a stack declaring nothing yields nothing" "$(stack_backup_sources bravo)" ""

# The main protection: a forgotten variable in a stack's .env would collapse
# the path into one ending in a slash, and that source would silently stop
# being backed up. A missing backup looks exactly like a source that does not
# exist, so silence is not an option here.
printf 'Foxtrot_DB_Dir=/mnt/data/fox\n' > "$WORK/stacks/foxtrot/.env"
stack_backup_sources foxtrot >/dev/null 2>&1
check "an unexpanded substitution is a failure, not an empty path" "$?" "1"
check "and the failure names what is missing" \
  "$(stack_backup_sources foxtrot 2>&1 >/dev/null | grep -c 'Foxtrot_DB_File')" "1"

# One stack's values must not leak into another's substitutions.
printf 'Foxtrot_DB_Dir=/mnt/data/fox\nFoxtrot_DB_File=f.db\n' > "$WORK/stacks/foxtrot/.env"
stack_backup_sources foxtrot >/dev/null
check "a stack's environment does not leak into the next one" "$(stack_backup_sources bravo)" ""

echo "== declaration checks"

# A stack that violates everything at once: a domain duplicated with delta, a
# relative host path, a vhost serving someone else's server_name, a unit
# without the required prefix and a timer with no result check.
fixture golf stack.conf 'Domains="d1.test"'
fixture golf compose.yaml 'services:
  golf-app:
    image: alpine
    volumes:
      - ./relative/path:/data
      - /abs/hardcoded:/other
      - ${Golf_Home_Dir}/ok:/fine
      - somevolume:/named'
# Real vhosts keep server_name on its own line — the fixture has to look the
# same, otherwise the test exercises a parse that never occurs in practice.
fixture golf nginx/50-golf.conf 'server {
    listen      80;
    server_name other.test;
}'
fixture golf systemd/wrong-name.timer '[Timer]
OnCalendar=daily'
fixture golf systemd/devbox-golf-job.timer '[Timer]
OnCalendar=daily'
printf 'Enabled_Stacks="golf delta"\n' > "$WORK/.env-stacks"

check "a duplicate domain is found" "$(check_domains_unique | wc -l | tr -d ' ')" "1"
check "a duplicate domain is attributed to two different stacks" \
  "$(check_domains_unique | grep -cE 'is declared by both .* and ' | tr -d ' ')" "1"

# The same domain TWICE IN ONE stack is the same mistake, but a message saying
# "declared by both hotel and hotel" reads as a broken check rather than a
# finding, and people stop reading it along with the rest of the report.
fixture hotel stack.conf 'Domains="hotel.test hotel.test"
Containers="no"'
printf 'Enabled_Stacks="golf delta hotel"\n' > "$WORK/.env-stacks"
check "a duplicate within one stack is described in its own words" \
  "$(check_domains_unique | grep -c 'declared twice by stack hotel' | tr -d ' ')" "1"
check "nothing says \"both hotel and hotel\"" \
  "$(check_domains_unique | grep -c 'both hotel and hotel' | tr -d ' ')" "0"
rm -rf "$WORK/stacks/hotel"
printf 'Enabled_Stacks="golf delta"\n' > "$WORK/.env-stacks"
check "a domain without a vhost and a vhost without a domain — both directions" \
  "$(check_domains_match golf | wc -l | tr -d ' ')" "2"
# A host path must have both properties at once: absolute AND through a
# variable. Both halves are checked, so there are two findings here: the
# relative path and the hardcoded one. A path through a variable and a named
# volume are not findings.
check "the relative and hardcoded host paths are found, the two valid ones are not" \
  "$(check_paths_absolute golf | wc -l | tr -d ' ')" "2"
check "the hardcoded path is named as hardcoded" \
  "$(check_paths_absolute golf | grep -c 'hardcoded host path')" "1"
check "a unit name without the prefix is found" "$(check_unit_names golf | wc -l | tr -d ' ')" "1"
check "a timer with no result check is found" \
  "$(check_timer_has_check golf | grep -c 'devbox-golf-job')" "1"
check "a well-formed stack raises no path findings" \
  "$(check_paths_absolute delta | wc -l | tr -d ' ')" "0"

# A timer that does have a check must raise nothing.
fixture golf scripts/check-job.sh '#!/bin/sh
exit 0'
check "a timer with scripts/check-<job>.sh raises nothing" \
  "$(check_timer_has_check golf | grep -c 'devbox-golf-job')" "0"

# A cycle in Requires: hotel -> india -> hotel.
fixture hotel stack.conf 'Requires="india"'
fixture hotel compose.yaml 'services:
  hotel-app:
    image: alpine'
fixture india stack.conf 'Requires="hotel"'
fixture india compose.yaml 'services:
  india-app:
    image: alpine'
check "a cycle in Requires is found" "$(check_requires_cycle hotel | wc -l | tr -d ' ')" "1"
check "a stack without dependencies yields no cycle" "$(check_requires_cycle delta)" ""

# Merging into the shared nginx service is the very breakage Static= exists to
# prevent.
fixture juliet stack.conf 'Requires=""'
fixture juliet compose.yaml 'services:
  nginx:
    volumes:
      - /x:/y'
check "merging into the shared nginx service is found" \
  "$(check_no_base_service_merge juliet | wc -l | tr -d ' ')" "1"
check "an ordinary stack does not touch the shared service" "$(check_no_base_service_merge delta)" ""

echo "== checks under set -e"

# This file runs under `set -uo pipefail`, while stack.sh runs under `set -euo
# pipefail`, and the difference is not cosmetic. A failing `grep` (a stack with
# no nginx/ directory, or no matches inside one) under `set -e` kills the
# loop's subshell entirely, and the function returns NOTHING instead of its
# findings — the check quietly stops checking. That is exactly how the
# upstreams block of `stack --check` came to print nothing: the first stack in
# the manifest had no nginx/ directory.
#
# So the functions whose output stack.sh reads are also exercised the way it
# calls them: under errexit and NOT as part of an `&&` — otherwise bash
# disables errexit inside the function and the test would be checking something
# other than what happens on a machine.
errexit_run() {
  bash -c '
    set -euo pipefail
    ROOT_DIR="$1"; shift
    . "$ROOT_DIR/platform/lib/lib-stacks.sh"
    . "$ROOT_DIR/platform/lib/lib-env.sh"
    "$@"
  ' _ "$WORK" "$@" 2>/dev/null
}

# mike is a stack with no vhosts but a declared domain, and it comes FIRST in
# the manifest: that is where the walk used to die. november is an ordinary
# stack with a proxy_pass.
fixture mike stack.conf 'Domains="mike.test"'
fixture mike compose.yaml 'services:
  mike-app:
    image: alpine'
fixture november stack.conf 'Requires=""'
fixture november compose.yaml 'services:
  november-app:
    image: alpine'
fixture november nginx/70-november.test.conf 'server {
    server_name november.test;
    location / {
        proxy_pass http://november-app:3000;
    }
}'
printf 'Enabled_Stacks="mike november"\n' > "$WORK/.env-stacks"

check "upstreams are found even though the manifest's first stack has no nginx/" \
  "$(errexit_run stacks_upstreams)" "november-app"

# fastcgi_pass alongside proxy_pass. Not symmetry for its own sake: nginx
# resolves both while READING the config, and a stopped php-fpm takes every
# site down — static ones included — when nginx is recreated. Covering this by
# accident, through a realistic PHP fixture, would disappear the first time the
# tests are rearranged.
fixture oscar2 stack.conf 'Requires=""'
fixture oscar2 compose.yaml 'services:
  oscar2-app:
    image: alpine'
fixture oscar2 nginx/80-oscar2.conf 'server {
	location ~ .php$ {
		fastcgi_pass	php-fpm:9000;
	}
}'
printf 'Enabled_Stacks="mike november oscar2"\n' > "$WORK/.env-stacks"
check "fastcgi_pass counts as an upstream too" \
  "$(errexit_run stacks_upstreams | grep -cx 'php-fpm')" "1"
printf 'Enabled_Stacks="mike november"\n' > "$WORK/.env-stacks"
check "a domain without a vhost is found under set -e" \
  "$(errexit_run check_domains_match mike | wc -l | tr -d ' ')" "1"
check "a vhost without a domain is found under set -e" \
  "$(errexit_run check_domains_match november | wc -l | tr -d ' ')" "1"

# A check's exit status must mean "the check could not be performed", not
# "nothing to report": otherwise the first call through `||` behaves
# backwards.
errexit_run check_no_base_service_merge november >/dev/null
check "a clean stack does not look like an error by exit status" "$?" "0"

# The list of known services covers ALL stacks, not only the enabled ones.
# Otherwise a disabled stack's container would be declared an orphan, and
# "disabled but containers remain" (fixed with `stack disable`) would merge
# with "no stack declares this service" (fixed with docker rm -f). Those are
# different diagnoses.
known=$(errexit_run stacks_known_services | sed '/^$/d' | sort -u)
check "the platform's nginx is a known service" \
  "$(printf '%s\n' "$known" | grep -cx 'nginx')" "1"
check "an enabled stack's service is known" \
  "$(printf '%s\n' "$known" | grep -cx 'november-app')" "1"
check "a DISABLED stack's service is known too" \
  "$(printf '%s\n' "$known" | grep -cx 'golf-app')" "1"

# Platform services are excluded from a stack's services: otherwise `disable`
# would destroy the nginx container together with every site on the machine.
fixture papa2 stack.conf 'Requires=""'
fixture papa2 compose.yaml 'services:
  nginx:
    image: alpine
  papa2-app:
    image: alpine'
check "a platform service does not count as a stack's service" \
  "$(errexit_run stack_services papa2 | grep -cx nginx)" "0"
check "a stack's own service does count" \
  "$(errexit_run stack_services papa2 | grep -cx papa2-app)" "1"
check "a service nobody declares is not in the list" \
  "$(printf '%s\n' "$known" | grep -cx 'stray-app')" "0"

echo "== the running nginx vs its spec"

# A `docker compose config` render: volumes in long form, with ports nearby
# that also carry a target key. A port must not end up in the mount list —
# otherwise comparing against the live container yields a permanent
# mismatch.
got=$(compose_mount_pairs <<'YAML'
  nginx:
    ports:
      - mode: ingress
        target: 80
        published: "80"
    volumes:
      - type: bind
        source: /srv/repo/platform/nginx-vhosts
        target: /etc/nginx/conf.d
        bind: {}
      - type: bind
        source: /srv/repo/stacks
        target: /etc/nginx/stacks
        read_only: true
        bind: {}
      - type: volume
        source: somevolume
        target: /data
YAML
)
want="/srv/repo/platform/nginx-vhosts	/etc/nginx/conf.d
/srv/repo/stacks	/etc/nginx/stacks"
check "mounts are parsed; the port and the named volume are not" "$got" "$want"

# `nginx -T` output: a directive may carry several names, and `_` is not a
# domain.
got=$(nginx_served_names <<'CONF'
server {
    listen 80 default_server;
    server_name _;
}
server {
    listen 443 ssl;
    server_name api.test  www.api.test;
}
server {
    server_name api.test;
}
CONF
)
check "the running nginx's domains are parsed, deduplicated and without _" \
  "$got" "api.test
www.api.test"

# A configuration with no server block is syntactically valid: nginx passes
# `nginx -t` with it and listens for nothing. An empty list here is a failure
# --check must notice.
check "a configuration without server blocks yields an empty list" \
  "$(printf 'events {}\nhttp {\n  include /etc/nginx/conf.d/*.conf;\n}\n' | nginx_served_names)" ""

echo "== stack health"

# The presence of the file IS the declaration: there is no separate list of
# checks.
fixture oscar stack.conf 'Requires=""'
fixture oscar compose.yaml 'services:
  oscar-app:
    image: alpine'
fixture oscar scripts/health.sh '#!/bin/sh
exit 0'
check "a stack's liveness check is found by path" \
  "$(errexit_run stack_health_script oscar)" "$WORK/stacks/oscar/scripts/health.sh"
check "a stack without one has no such file on disk" \
  "$([ -f "$(errexit_run stack_health_script november)" ] && echo yes || echo no)" "no"

echo "== databases at the provider"

# The DB provider is a ROLE, not a name. A stack declares Provides_DB=<prefix>,
# and the engine collects orders under that prefix without knowing the word
# "Postgres" or "MySQL". This is exercised with an INVENTED prefix: if the test
# passes with it, no real DBMS name is left hardcoded in the engine.
fixture papa stack.conf 'Provides_DB="Zulu"
DB_Init_Service="zulu-init"'
fixture papa compose.yaml 'services:
  zulu:
    image: alpine'

fixture kilo stack.conf 'Requires="papa"
Zulu_DB="${Kilo_DB_Name}"
Zulu_User="${Kilo_DB_User}"
Zulu_Password="${Kilo_DB_Password}"'
fixture kilo compose.yaml 'services:
  kilo-app:
    image: alpine'
printf 'Kilo_DB_Name=kilo_stg\nKilo_DB_User=kilo\nKilo_DB_Password=p@ss'"'"'w0rd\n' \
  > "$WORK/stacks/kilo/.env"
fixture lima stack.conf 'Zulu_DB="lima"
Zulu_User="lima"
Zulu_Password="secret"
Zulu_Dump="lima-seed.sql"'
fixture lima compose.yaml 'services:
  lima-app:
    image: alpine'
printf 'Enabled_Stacks="papa kilo lima alpha"\n' > "$WORK/.env-stacks"

check "the provider is found by role" "$(stacks_db_provider)" "papa"
check "the order prefix comes from the provider" "$(stacks_db_prefix)" "Zulu"
check "the initializer's name comes from the provider" "$(stacks_db_init_service)" "zulu-init"
check "the database list lives in the machine's state" \
  "$(stacks_databases_file)" "$WORK/state/papa/databases.yaml"

yaml=$(stacks_databases_content)
check "a declared database made it into the YAML" "$(printf '%s' "$yaml" | grep -c '^- db:')" "2"
check "the database name is expanded from the stack's .env" \
  "$(printf '%s' "$yaml" | grep -c "db: 'kilo_stg'")" "1"
# A password containing an apostrophe must survive YAML: inside single quotes
# it is doubled. Otherwise the initializer reads a truncated password and
# creates a user the application cannot authenticate as — exactly the failure
# this generation exists to prevent.
check "an apostrophe in a password is escaped" \
  "$(printf '%s' "$yaml" | grep -c "password: 'p@ss''w0rd'")" "1"
check "an optional key appears where it is declared" \
  "$(printf '%s' "$yaml" | grep -c "dump: 'lima-seed.sql'")" "1"
# The S3 path for SQLite is a formula shared by backup.sh and
# check-backups.sh. The VALUE is checked, not merely "there is one formula":
# once they drift, one stores and the other looks in different places.
check "the S3 path for SQLite" "$(sqlite_s3_subpath /var/lib/app/twd-tm.db)" "sqlite/twd-tm"
check "the S3 path for SQLite drops the .db extension" "$(sqlite_s3_subpath /x/base.db)" "sqlite/base"

check "a stack that declares nothing stays out of the YAML" \
  "$(printf '%s' "$yaml" | grep -c 'alpha')" "0"

# A disabled stack has no use for a database. There is no failure in the other
# direction: the initializer deletes nothing, so disable leaves the database
# alone and enable brings it back.
printf 'Enabled_Stacks="papa lima"\n' > "$WORK/.env-stacks"
check "a disabled stack declares no database" \
  "$(stacks_databases_content | grep -c 'kilo')" "0"

# With no provider enabled there is nobody to order from — and that is a
# legitimate state rather than a breakage: a machine with a single proxy stack
# needs no shared DBMS.
printf 'Enabled_Stacks="lima"\n' > "$WORK/.env-stacks"
check "without a provider the YAML is empty" "$(stacks_databases_content)" ""
check "without a provider the file path is empty" "$(stacks_databases_file)" ""
printf 'Enabled_Stacks="papa lima"\n' > "$WORK/.env-stacks"

# A partial declaration is a failure rather than half an entry: a user without
# a password would be created with an empty one and would let in anyone who can
# reach the database port.
fixture mike stack.conf 'Zulu_DB="mike"'
fixture mike compose.yaml 'services:
  mike-app:
    image: alpine'
printf 'Enabled_Stacks="papa lima mike"\n' > "$WORK/.env-stacks"
check "a partial declaration is found" "$(check_db_decl mike | wc -l | tr -d ' ')" "1"
check "a complete declaration raises nothing" "$(check_db_decl lima)" ""
check "a stack that orders nothing raises nothing" "$(check_db_decl alpha)" ""

# Two stacks on one database is a fight over ownership and almost certainly a
# typo.
fixture november stack.conf 'Zulu_DB="lima"
Zulu_User="november"
Zulu_Password="x"'
fixture november compose.yaml 'services:
  november-app:
    image: alpine'
printf 'Enabled_Stacks="papa lima november"\n' > "$WORK/.env-stacks"
check "a duplicate database name is found" "$(check_databases_unique | wc -l | tr -d ' ')" "1"

# There cannot be two providers: orders are distinguished by prefix rather than
# by addressee, and a second provider with the same prefix would quietly
# intercept declarations meant for the first.
fixture quebec stack.conf 'Provides_DB="Zulu"
DB_Init_Service="other-init"'
fixture quebec compose.yaml 'services:
  quebec:
    image: alpine'
printf 'Enabled_Stacks="papa quebec"\n' > "$WORK/.env-stacks"
check "two providers at once are found" "$(check_db_providers_unique | wc -l | tr -d ' ')" "1"
printf 'Enabled_Stacks="papa lima november"\n' > "$WORK/.env-stacks"

echo "== image registries"

# A stack that pulls a prebuilt image from a registry and is pinned by digest
# is exactly the arrangement registry.sh exists for.
fixture oscar stack.conf 'Image_Tag="master"'
fixture oscar compose.yaml 'services:
  oscar-app:
    image: 111.dkr.ecr.eu-north-1.amazonaws.com/oscar@${Oscar_Image_Digest:?not set in stacks/oscar/.env — run ./scripts/registry.sh pin oscar}'
# papa: an image from a registry, but no Image_Tag declared — nothing to
# refresh the digest from.
fixture papa compose.yaml 'services:
  papa-app:
    image: 111.dkr.ecr.eu-north-1.amazonaws.com/papa@${Papa_Image_Digest}'
# quebec: Image_Tag declared, but the image comes from Docker Hub — nothing to
# pin.
fixture quebec stack.conf 'Image_Tag="master"'
fixture quebec compose.yaml 'services:
  quebec-app:
    image: alpine:3.20'
printf 'Enabled_Stacks="oscar papa quebec"\n' > "$WORK/.env-stacks"

# The `image:` value is taken whole: a `:?` substitution contains spaces, and
# splitting on them would leave half an image name — and purge uses that name
# to decide what to delete from disk.
check 'an image name with spaces inside a substitution is not truncated' \
  "$(stack_images oscar)" \
  '111.dkr.ecr.eu-north-1.amazonaws.com/oscar@${Oscar_Image_Digest:?not set in stacks/oscar/.env — run ./scripts/registry.sh pin oscar}'

check "a Docker Hub image has no registry host" "$(image_registry 'alpine:3.20')" ""
check "an image with a path but no dot has no registry host" "$(image_registry 'library/alpine:3.20')" ""
check "an ECR registry is recognised" \
  "$(image_registry '111.dkr.ecr.eu-north-1.amazonaws.com/oscar@sha256:ab')" \
  "111.dkr.ecr.eu-north-1.amazonaws.com"
check "a registry with a port is recognised" "$(image_registry 'localhost:5000/x')" "localhost:5000"

check "a stack with a Hub image yields no external registries" "$(stack_registry_images quebec)" ""
check "the registries of the listed stacks" "$(stacks_registries oscar quebec)" \
  "111.dkr.ecr.eu-north-1.amazonaws.com"

# A tag without a digest and a digest without a tag are halves of one pair, and
# each is useless alone: there is nowhere to write the resolution, or nothing
# to refresh it from.
check "a digest without Image_Tag is found" "$(check_image_decl papa | wc -l | tr -d ' ')" "1"
check "an Image_Tag without an external registry is found" "$(check_image_decl quebec | wc -l | tr -d ' ')" "1"
check "a consistent pair raises nothing" "$(check_image_decl oscar)" ""

# A stack with no registry images at all must not kill the walk under errexit:
# it is sometimes first in the manifest, and the registry list would then come
# out empty.
check "registries are found under set -e even though the manifest's first stack has none" \
  "$(errexit_run stacks_registries quebec oscar)" "111.dkr.ecr.eu-north-1.amazonaws.com"

echo "== platform hygiene"

# Classes of defect that have occurred before. What is checked is the CLASS,
# not a particular place: a particular instance is fixed once, a class comes
# back.
#
# -I everywhere: without it any binary file that happens to be in the tree (a
# .swp from an open editor, say) produces a "Binary file ... matches" line and
# breaks several guards at once — the tests would fail because of an unrelated
# file rather than because of the code.

# 1. Путь к стеку, собранный строкой, слеп к профильному корню: такой стек
#    просто не находится, и его preflight/health/stack.conf молча не читаются.
#    Единственный законный способ — stack_dir и производные от него.
#
#    Ищем сам ПРИЗНАК — литерал '/stacks/' сразу перед подстановкой, — а не
#    конкретные имена переменных: прошлая версия проверки перечисляла ROOT_DIR
#    и stacks_root, из-за чего не видела ни $root, ни ${DEPLOY_DIR:?}, ни один
#    файл в profiles/. Она давала ноль совпадений при шести настоящих случаях,
#    то есть служила разрешением не думать про класс.
#
#    Законные исключения помечаются в коде комментарием # stack-path-ok:
#    их два вида — определение самих корней и .env стека, который по замыслу
#    ВСЕГДА машинный. Пометка грепается, то есть исключение видно и его можно
#    пересчитать; молчаливого исключения быть не должно.
built=$(grep -rInE '/stacks/\$' \
          "$REPO_DIR"/platform/bin "$REPO_DIR"/platform/lib "$REPO_DIR"/bin \
          "$REPO_DIR"/profiles 2>/dev/null \
        | grep -v 'stack-path-ok' \
        | grep -vE '(selftest|mutate)\.sh:' || true)
check "путь к стеку нигде не собирается строкой" "$built" ""

# 2. Запись в platform/ или profile/: это общие слои, bootstrap перезаписывает
#    их целиком. Записанное туда исчезает при следующем обновлении, а до того
#    лежит в слое, который раздаётся всем машинам.
#    Ищем любую запись, а не только `>`: cp, tee и >> туда же. И смотрим все
#    каталоги, где может оказаться пишущий код, а не только два.
writes=$(grep -rInE '(>>?|tee|cp|mkdir -p|install) +[^|#]*\$\{?(ROOT_DIR|REPO_DIR|Platform_Deploy_Dir)[^ "]*/(platform|profile)/' \
           "$REPO_DIR"/platform/bin "$REPO_DIR"/platform/lib "$REPO_DIR"/bin \
           "$REPO_DIR"/profiles 2>/dev/null \
        | grep -v 'stack-path-ok' | grep -vE '(selftest|mutate)\.sh:' || true)
check "в общие слои никто не пишет" "$writes" ""

# 3. `sudo -u` обязан пробрасывать ROOT_DIR через env: sudo сбрасывает
#    окружение, и скрипт платформы вычислит корень от своего пути — а лежит он
#    в .stackyard/platform/bin, то есть корнем станет .stackyard. Отказ
#    выглядит как «нет .env» на машине, где .env есть.
badsudo=$(grep -rIn 'sudo -u' "$REPO_DIR"/platform/bin "$REPO_DIR"/bin 2>/dev/null \
          | grep -vE ':[0-9]+:[[:space:]]*#' \
          | grep -vE '(selftest|mutate)\.sh:' \
          | grep -v 'env ROOT_DIR=' || true)
check "sudo -u пробрасывает ROOT_DIR" "$badsudo" ""

# 3. Менеджер пакетов и команды дистрибутива не зашиваются: платформа
#    раздаётся, и `dnf` в ней означает, что на Debian/Ubuntu установка упирается
#    в «dnf: command not found» — с подсказкой, которую невозможно выполнить.
#    Ровно это и случилось на первом же реальном сервере.
#
#    Сама абстракция (она обязана перечислить менеджеры) помечена в коде
#    # pkg-mgr-ok — как и другие законные исключения: пометка грепается, то
#    есть исключение видно и его можно пересчитать.
hardpm=$(grep -rInE '(^|[^_[:alnum:]])(dnf|yum|apt-get|apk add|zypper) ' \
           "$REPO_DIR"/platform/bin "$REPO_DIR"/platform/lib "$REPO_DIR"/bin 2>/dev/null \
         | grep -vE ':[0-9]+:[[:space:]]*#' \
         | grep -v 'pkg-mgr-ok' || true)
check "команды менеджера пакетов не зашиты" "$hardpm" ""

# 3. Директива `# shellcheck source=` обязана резолвиться ОТ КОРНЯ репозитория:
#    именно так шеллчек её и ищет — от рабочего каталога, а не от проверяемого
#    файла. Форма ../lib/... выглядела верной и молча не резолвилась, а SC1091
#    идёт уровнем info, то есть при -S error его не видно вовсе. Итог: -x был
#    включён, а каждый скрипт линтился в изоляции, и опечатка в пути к
#    библиотеке доживала до рантайма (ровно так уцелел дефект A9).
badsrc=""
while IFS= read -r line; do
  [ -n "$line" ] || continue
  t="${line##*source=}"; t="${t%% *}"
  [ -f "$REPO_DIR/$t" ] || badsrc="$badsrc ${line%%:*}:$t"
#    Ищем НАСТОЯЩУЮ форму директивы (строка целиком — комментарий шеллчека), а
#    не подстроку: иначе проверка ловит собственный образец поиска и рассказ о
#    том, что она проверяет. На этом я попался трижды подряд.
done < <(grep -rInE '^[[:space:]]*# shellcheck source=' "$REPO_DIR"/platform/bin "$REPO_DIR"/platform/lib \
           "$REPO_DIR"/bin "$REPO_DIR"/tests "$REPO_DIR"/profiles 2>/dev/null)
check "директивы shellcheck source= резолвятся" "$badsrc" ""

# 3. Ссылка на платформенный compose-файл, которого нет. Так в stack.sh жил
#    `-f platform/compose/php-fpm.yaml`, оставшийся с тех пор, когда php-fpm был
#    платформенным: compose падал на несуществующем -f, 2>/dev/null это съедал,
#    и целый блок проверки был мёртв на всех машинах.
#    Строки-комментарии пропускаем: guard про КОД, а не про прозу. Объяснение
#    прошлого дефекта неизбежно содержит имя файла, которого больше нет, и
#    ловить его — значит заставлять стирать объяснения.
badref=""
for ref in $(grep -rIhE 'platform/compose/[A-Za-z0-9_.-]+\.yaml' \
               "$REPO_DIR"/platform/bin "$REPO_DIR"/bin 2>/dev/null \
             | grep -vE '^[[:space:]]*#' \
             | grep -oE 'platform/compose/[A-Za-z0-9_.-]+\.yaml' | sort -u); do
  case "$ref" in *.generated.yaml) continue ;; esac
  [ -f "$REPO_DIR/$ref" ] || badref="$badref $ref"
done
check "ссылок на несуществующие файлы платформы нет" "$badref" ""

# 4. Скрипты стеков подключают библиотеки по пути platform/lib/. Путь из
#    devbox6 (scripts/lib-env.sh) переживал перенос незамеченным, потому что
#    его следствие выглядело как «стек не отвечает», а не как сломанный скрипт.
badlib=$(grep -rIn 'ROOT_DIR[^"]*}\?/scripts/lib-' "$REPO_DIR"/profiles "$REPO_DIR"/platform 2>/dev/null \
         | grep -vE ':[0-9]+:[[:space:]]*#' || true)
check "стеки подключают библиотеки из platform/lib" "$badlib" ""

# 3. Имя конкретной машины или клиента в публичном слое. Репозиторий публичный;
#    кроме утечки это ещё и проверка, которая на другой машине молча проходит.
names=$(grep -rniE 'devbox6|devbox-asstnt|12devs|my-new-site|pankov\.me|filinn|pckup|sanya|quotrum|tokensale' \
          "$REPO_DIR"/platform "$REPO_DIR"/profiles "$REPO_DIR"/bin 2>/dev/null \
        | grep -v '^Binary' | grep -v 'selftest\.sh:[0-9]*:names=' \
        | grep -vE ':[0-9]+:[[:space:]]*#' || true)
check "имён машин и клиентов в платформе нет" "$names" ""

# 5. Команда, которой на чужой машине может не быть, либо ведущая себя там
#    иначе. Пять отказов подряд на первом реальном сервере были именно такими,
#    и ни один не поймали тесты: у меня всё стояло. Поэтому ловим класс —
#    прямой вызов в обход обёртки из lib-env.sh, — а не конкретный вызов.
#    Законное место обёрток одно, оно помечено # portable-ok.

#    5a. shasum/sha256sum. Отсутствие первого давало ПУСТУЮ сумму, она не
#        совпадала ни с чем, и check-vendor докладывал, что на месте правили
#        каждый файл платформы: отсутствие инструмента выглядело как диверсия.
badsha=$(grep -rInE '(^|[^_[:alnum:]])(shasum|sha256sum)[[:space:]]' \
           "$REPO_DIR"/platform/bin "$REPO_DIR"/platform/lib "$REPO_DIR"/bin "$REPO_DIR"/tests 2>/dev/null \
         | grep -vE ':[0-9]+:[[:space:]]*#' \
         | grep -vE '(selftest|mutate)\.sh:' | grep -v 'portable-ok' || true)
check "суммы считаются через sha256_file" "$badsha" ""

#    5b. timeout — из GNU coreutils, в macOS и BSD его нет вовсе. Без него
#        сторож просто не запускается, и --check зависает ровно там, где
#        сторож и был нужен: на неотвечающем health.sh.
badto=$(grep -rInE '(^|[^_[:alnum:]-])timeout[[:space:]]+"?\$' \
          "$REPO_DIR"/platform/bin "$REPO_DIR"/platform/lib "$REPO_DIR"/bin 2>/dev/null \
        | grep -vE ':[0-9]+:[[:space:]]*#' \
        | grep -vE '(selftest|mutate)\.sh:' | grep -v 'portable-ok' || true)
check "сторож времени идёт через run_with_timeout" "$badto" ""

#    5c. `find -printf` — расширение GNU; BSD find на нём падает целиком.
#        Вызов был обёрнут в 2>/dev/null || true, поэтому падал молча: счётчик
#        выше говорил «невыгруженных дампов N», а список под ним был пуст.
badfp=$(grep -rIn -- '-printf' "$REPO_DIR"/platform "$REPO_DIR"/bin "$REPO_DIR"/tests 2>/dev/null \
        | grep -v 'platform/getssl' | grep -vE '(selftest|mutate)\.sh:' \
        | grep -vE ':[0-9]+:[[:space:]]*#' || true)
check "find -printf (только GNU) не используется" "$badfp" ""

#    5d. `date -j -f` без -u и без %z в формате разбирает строку как ЛОКАЛЬНОЕ
#        время. Метки S3 приходят в UTC, поэтому к востоку от Гринвича свежий
#        бэкап выглядел устаревшим, а к западу — устаревший проходил проверку.
#        Второе хуже: проверка свежести бэкапов, которая молча одобряет старый.
badtz=""
while IFS= read -r line; do
  [ -n "$line" ] || continue
  case "$line" in *'%z'*|*'date -j -u'*|*'%Z'*) continue ;; esac
  badtz="$badtz${line%%:*} "
done < <(grep -rIn 'date -j' "$REPO_DIR"/platform/bin "$REPO_DIR"/platform/lib "$REPO_DIR"/bin 2>/dev/null \
         | grep -v 'platform/getssl' | grep -vE '(selftest|mutate)\.sh:' \
         | grep -vE ':[0-9]+:[[:space:]]*#')
check "разбор времени BSD-датой не считает UTC локальным" "$badtz" ""

# 6. `declare -gA` — это bash >= 4.2, а штатный /bin/bash в macOS остался 3.2.
#    Без явной проверки версии библиотека молча загружалась с пустым ENV_VARS:
#    каждый env_get возвращал умолчание, и скрипт делал не то, о чём просили.
#    Попасть на 3.2 легче всего через sudo — он чистит PATH.
badbv=""
for f in $(grep -rIl 'declare -gA' "$REPO_DIR"/platform/lib 2>/dev/null); do
  grep -q 'BASH_VERSINFO' "$f" || badbv="$badbv $f"
done
check "declare -gA прикрыт проверкой версии bash" "$badbv" ""

# 7. Разбор аргументов: `WANT="$2"; shift 2` под set -u на забытом значении
#    даёт «$2: unbound variable» — сообщение про внутренности скрипта вместо
#    сообщения про то, чего не хватает в командной строке.
badsh=$(grep -rIn 'shift 2' "$REPO_DIR"/bin "$REPO_DIR"/platform/bin 2>/dev/null \
        | grep -vE ':[0-9]+:[[:space:]]*#' \
        | grep -vE '(selftest|mutate)\.sh:' | grep -v '${2-}' || true)
check "необязательный аргумент читается как \${2-}" "$badsh" ""

# 8. Поиск дубликатов через `prev` в awk обязан требовать, чтобы вторая строка
#    была от ДРУГОЙ машины. Один и тот же ключ у одной машины лежит сразу в
#    двух файлах (Mysql_Root_Password в .env и в stacks/mysql/.env), и без
#    этого условия аудит изоляции докладывал «ключ одинаков у машин X и X».
#    Ложная тревога в проверке безопасности хуже её отсутствия: её учатся не
#    читать, а вместе с ней перестают читать и настоящую находку.
#    Смотрим не на строку и не на файл, а на ОКНО вокруг каждого сравнения.
#    Построчно нельзя: сравнение источников стоит строкой ниже, внутри того же
#    awk-выражения. По файлу целиком — тоже: в audit-isolation.sh таких awk два,
#    и исправленный прикрывал собой сломанный (ровно так эта проверка и
#    пропустила первую мутацию).
baddup=""
while IFS=: read -r f n _; do
  [ -n "${n:-}" ] || continue
  sed -n "$((n > 2 ? n - 2 : 1)),$((n + 5))p" "$f" | grep -qE '\$2 (==|!=) prev' \
    || baddup="$baddup $f:$n"
done < <(grep -rIn '$1 == prev' "$REPO_DIR"/bin "$REPO_DIR"/platform 2>/dev/null \
         | grep -vE '(selftest|mutate)\.sh:')
check "поиск дубликатов отличает источник от самого себя" "$baddup" ""

# 9. Чужой код копией в репозитории. Копия getssl весила 155 КБ, лежала под
#    GPL-3 в публичном репозитории под MIT и успела обрасти локальными
#    правками, про которые никто уже не помнил, откуда они. Теперь такие вещи
#    закрепляются lock-файлом и скачиваются на машину; проверяем, что копия не
#    вернулась и что ссылки на неё не остались.
#
#    Признак копии — исполняемый файл вне bin/ и lib/ длиннее 500 строк:
#    маленькие шаблоны и конфиги так не выглядят.
vendored=""
while IFS= read -r f; do
  case "$f" in */bin/*|*/lib/*) continue ;; esac
  [ -x "$f" ] || continue
  [ "$(wc -l < "$f")" -gt 500 ] && vendored="$vendored $f"
done < <(find "$REPO_DIR/platform" "$REPO_DIR/profiles" -type f 2>/dev/null)
check "чужой код не лежит копией в платформе" "$vendored" ""

#    Хвост ([^-.a-zA-Z0-9]|$) обязателен с обеих сторон: без «|$» шаблон не
#    видел ссылку в КОНЦЕ строки — а именно так она и выглядит в ExecStart.
stale=$(grep -rInE 'platform/getssl([^-.a-zA-Z0-9]|$)' "$REPO_DIR"/platform "$REPO_DIR"/bin "$REPO_DIR"/templates 2>/dev/null \
        | grep -vE '(selftest|mutate)\.sh:' | grep -vE ':[0-9]+:[[:space:]]*#' || true)
check "ссылок на убранную копию getssl не осталось" "$stale" ""

# 10. Корень машины, вычисленный от пути скрипта. На машине platform/ — это
#     симлинк в .stackyard/, и `cd -P` его разворачивает: два уровня вверх дают
#     .stackyard, а не машину. Скрипт после этого заводит state/ внутри слоя,
#     который перезаписывается при каждом ./bootstrap. Замечено на живом
#     сервере: htpasswd.sh положил файл в .stackyard/state/ и там же его искал,
#     так что «пусто» он печатал совершенно честно.
badroot=""
for f in $(grep -rIl 'cd "$DIR0/../\.\." && pwd' "$REPO_DIR"/platform/bin 2>/dev/null); do
  grep -q '\.stackyard' "$f" || badroot="$badroot $f"
done
check "ROOT_DIR не остаётся внутри .stackyard" "$badroot" ""

# 11. Взаимоисключающие флаги htpasswd. -i читает пароль со стдина, -b берёт его
#     ТРЕТЬИМ аргументом; вместе они означают «жду третий аргумент», которого
#     нет, и htpasswd печатает usage и выходит. На сервере это выглядит как
#     сломанный скрипт, а не как неверные флаги. Прогоном не проверить: htpasswd
#     живёт в контейнере, а selftest работает без docker.
badflags=$(grep -n 'FLAGS=' "$REPO_DIR/platform/bin/htpasswd.sh" 2>/dev/null \
           | grep -E '\-[a-zA-Z]*i[a-zA-Z]*b|\-[a-zA-Z]*b[a-zA-Z]*i' || true)
check "htpasswd: -i и -b не стоят вместе" "$badflags" ""

# 12. Обёртки машины перечислены одним списком (templates/machine/wrappers), и
#     каждая цель обязана существовать: опечатка здесь даёт машине точку входа,
#     которая падает на "Платформы нет" — то есть сообщением про bootstrap,
#     хотя bootstrap ни при чём.
badwrap=""
while IFS=: read -r name target; do
  case "$name" in ''|\#*) continue ;; esac
  [ -f "$REPO_DIR/platform/bin/$target" ] || badwrap="$badwrap $name->$target"
done < "$REPO_DIR/templates/machine/wrappers"
check "цели обёрток машины существуют" "$badwrap" ""

# 13. Одна функция, определённая дважды. В bash побеждает ПОСЛЕДНЕЕ
#     определение, а первое остаётся мёртвым кодом, который выглядит живым:
#     правку в нём вносят, тестируют — и ничего не меняется. Хуже, если копии
#     разошлись: тогда перестановка блоков местами молча возвращает старое
#     поведение.
dupfn=""
while IFS= read -r f; do
  while IFS= read -r fn; do
    [ "$(grep -cE "^${fn}\(\) \{" "$f")" -gt 1 ] && dupfn="$dupfn $(basename "$f"):$fn"
  done < <(grep -oE '^[a-z_][a-z_0-9]*\(\) \{' "$f" | sed 's/() {//' | sort -u)
done < <(find "$REPO_DIR/platform/lib" "$REPO_DIR/platform/bin" "$REPO_DIR/bin" -name '*.sh' 2>/dev/null)
check "ни одна функция не определена дважды" "$dupfn" ""

# 14. Образец мутации, переставший совпадать с кодом. Мутация, которая не
#     наложилась, НИЧЕГО не проверяет, а узнаётся это только после полного
#     прогона — десять минут спустя, и то если читать вывод целиком.
#
#     Проверяется ПЕРВАЯ строка образца, а не весь он: многострочные образцы
#     mutate.sh собирает из \n, и повторять здесь его разбор целиком означало
#     бы завести вторую реализацию, которая разойдётся с первой. Первой строки
#     хватает, чтобы поймать переименование или перевод — то, ради чего гард и
#     нужен, — и она не даёт ложных срабатываний.
stale_mut=""
while IFS= read -r line; do
  case "$line" in *"@@"*) ;; *) continue ;; esac
  body="${line#*\'}"; body="${body%\'*}"
  body="${body//\'\"\'\"\'/\'}"
  name="${body%%@@*}"; rest="${body#*@@}"
  file="${rest%%@@*}"; rest="${rest#*@@}"
  pat="${rest%%@@*}"
  pat="${pat%%\\n*}"          # только первая строка
  # sed, а не ${pat//...}: в шаблоне подстановки обратный слэш экранирует
  # следующий символ, поэтому \\& означает просто «&» и замена молчит вхолостую.
  pat="$(printf '%s' "$pat" | sed 's/\\&/\&/g')"
  [ -n "$pat" ] || continue
  if [ ! -f "$REPO_DIR/$file" ]; then
    stale_mut="$stale_mut [нет файла: $file]"
  elif ! grep -qF -- "$pat" "$REPO_DIR/$file"; then
    stale_mut="$stale_mut [$name]"
  fi
done < <(sed -n "/^MUTATIONS=(/,/^)/p" "$REPO_DIR/tests/mutate.sh" | grep "@@")
check "образцы мутаций совпадают с кодом" "$stale_mut" ""

# 13. Имя образа nginx — одно на всех, кто его называет. Копий было три, и
#     htpasswd.sh про Platform_Nginx_Image вовсе не знал: на машине с
#     переопределённым образом файл паролей готовил НЕ тот nginx, который его
#     читает, — а от образа зависит gid, то есть права на файл.
#     В compose литерал неизбежен (там подстановки без запасного значения нет),
#     поэтому его и не считаем; речь про скрипты.
badimg=$(grep -rInE 'nginx:[0-9]+\.[0-9]+' "$REPO_DIR"/platform/bin "$REPO_DIR"/bin 2>/dev/null \
         | grep -vE '(selftest|mutate)\.sh:' | grep -vE ':[0-9]+:[[:space:]]*#' || true)
check "скрипты берут образ nginx из nginx_image" "$badimg" ""

# 14. Файл, созданный контейнером, принадлежит root: на хосте его уже не
#     переназначить, и `chmod` от обычного пользователя падает с EPERM. Права
#     должен ставить сам контейнер, пока он root. Проверяем, что после docker
#     run в скрипте не осталось хостового chmod по этому файлу.
badchmod=$(grep -n '^chmod .*"\$FILE"' "$REPO_DIR/platform/bin/htpasswd.sh" 2>/dev/null || true)
check "права файла паролей ставит контейнер, а не хост" "$badchmod" ""

# Lock обязан называть всё, без чего скачивание не воспроизводится. Пустое поле
# здесь означало бы «скачаем что дадут»: ровно то, от чего lock и заводят.
for field in repo version sha256; do
  v=$(sed -n "s/^$field=//p" "$REPO_DIR/platform/getssl.lock" | head -n 1)
  check "getssl.lock: поле $field заполнено" "$([ -n "$v" ] && echo да || echo нет)" "да"
done
# Сумма — ровно 64 шестнадцатеричных знака. Обрезанная или с пробелом не
# совпадёт ни с чем, и getssl-fetch будет вечно докладывать о подмене.
check "getssl.lock: сумма похожа на sha256" \
  "$(sed -n 's/^sha256=//p' "$REPO_DIR/platform/getssl.lock" | head -n 1 | grep -cE '^[0-9a-f]{64}$')" "1"

echo "== порядок и зоны лимитов"

# Файлы conf.d читаются по алфавиту, а nginx разрешает имя зоны в момент
# разбора server-блока. Генерируемый файл, попавший ПЕРЕД определениями зон,
# означает "unknown limit_req_zone" и отказ старта — то есть краш-луп по
# restart: always. На машине разработчика nginx не запускается вовсе, поэтому
# заметить это можно только так.
inc_name="$(basename "$(stacks_include_file)")"
first=$( { printf '%s\n' "$inc_name"
           ls -1 "$REPO_DIR"/platform/nginx-vhosts/*.conf 2>/dev/null | sed 's:.*/::'; } | sort | head -n 1)
check "определения зон читаются раньше vhost'ов стеков" \
  "$([ "$first" = "$inc_name" ] && echo "СНАЧАЛА vhost'ы" || echo ok)" "ok"

# Платформа несёт только общие зоны. Политика конкретной машины — какой URI
# считать логином — уехав в общий слой, попала бы на все машины сразу.
# Комментарии пропускаем — как и в остальных гигиенических проверках:
# объяснение прошлого дефекта неизбежно содержит то, что он ловит.
check "в платформенных зонах нет машинной политики" \
  "$(grep -vE '^[[:space:]]*#' "$REPO_DIR"/platform/nginx-vhosts/00-limits.conf \
     | grep -cE 'map |user/login' || true)" "0"

# Совместимость образа с директивами платформы.
ENV_VARS=(); ENV_VARS[Platform_Nginx_Image]='nginx:1.19-alpine'
check "старый образ nginx назван" "$(check_nginx_image | grep -c 'older than 1.25.1')" "1"
ENV_VARS[Platform_Nginx_Image]='nginx:1.25.1-alpine'
check "1.25.1 претензий не вызывает" "$(check_nginx_image)" ""
ENV_VARS=()

echo "== include: генератор против читателя"

# Формула строки include пишется в одном месте и читается в другом. Разъезд
# молчит в обе стороны: прошлая версия читателя искала "conf.d/<стек>/*.conf",
# которой генератор не производил никогда, и колонка VHOSTS показывала «выкл»
# у каждого стека с vhost'ами. Колонка, которая всегда врёт, хуже отсутствующей.
fixture tango stack.conf 'Domains="tango.test"
Containers="no"'
fixture tango nginx/70-tango.conf 'server { server_name tango.test; }'
fixture_root profile/stacks uniform stack.conf 'Domains="uniform.test"
Containers="no"'
fixture_root profile/stacks uniform nginx/71-uniform.conf 'server { server_name uniform.test; }'
printf 'Enabled_Stacks="papa lima november tango uniform"\n' > "$WORK/.env-stacks"

mkdir -p "$(dirname "$(stacks_include_file)")"
stacks_include_content > "$(stacks_include_file)"

check "читатель видит включённый машинный стек" \
  "$(stack_vhost_enabled tango && echo да || echo нет)" "да"
check "читатель видит включённый ПРОФИЛЬНЫЙ стек" \
  "$(stack_vhost_enabled uniform && echo да || echo нет)" "да"

printf 'Enabled_Stacks="papa lima november"\n' > "$WORK/.env-stacks"
stacks_include_content > "$(stacks_include_file)"
check "выключенный стек читателем не виден" \
  "$(stack_vhost_enabled tango && echo да || echo нет)" "нет"

echo "== состояние свежей машины"

# На свежей машине после ./bootstrap каталога state/ нет вовсе: bootstrap несёт
# платформу, а состояние — дело машины. Первая же команда писала в
# state/nginx-vhosts/ и умирала сырой ошибкой оболочки, а databases.yaml не
# создавался никогда — при том что --check требовал `sync`, который его и не
# создаёт. Замкнутый круг на первой минуте знакомства с платформой.
rm -rf "$WORK/state"
printf 'Enabled_Stacks="papa lima"\n' > "$WORK/.env-stacks"
ensure_state_dirs
for d in nginx-vhosts certs htpasswd getssl-config; do
  check "state/$d заведён" "$([ -d "$WORK/state/$d" ] && echo да || echo нет)" "да"
done
check "каталог поставщика заведён" "$([ -d "$WORK/state/papa" ] && echo да || echo нет)" "да"

# А на машине без поставщика его каталога быть не должно: пустой state/papa
# там вводит в заблуждение не меньше, чем его отсутствие там, где он нужен.
rm -rf "$WORK/state"
printf 'Enabled_Stacks="lima"\n' > "$WORK/.env-stacks"
ensure_state_dirs
check "без поставщика его каталог не заводится" \
  "$([ -d "$WORK/state/papa" ] && echo да || echo нет)" "нет"
check "без поставщика путь к файлу баз пуст" "$(stacks_databases_file)" ""
printf 'Enabled_Stacks="papa lima november"\n' > "$WORK/.env-stacks"

# Заглушки сертификатов обязаны заводиться и профильным стекам. Иначе домен
# объявлен, конфиг getssl есть, а файла нет — nginx не стартует и с
# restart: always уносит ВСЕ сайты машины.
fixture_root profile/stacks sierra stack.conf 'Domains="sierra.test"
Containers="no"'
fixture_root profile/stacks sierra nginx/60-sierra.conf 'server {
	ssl_certificate /etc/nginx/certs/sierra.test-fullchain.crt;
	ssl_certificate_key /etc/nginx/certs/sierra.test.key;
}'
printf 'Enabled_Stacks="papa lima november sierra"\n' > "$WORK/.env-stacks"
check "путь сертификата профильного стека виден" \
  "$(stacks_cert_paths | grep -c 'sierra.test-fullchain.crt')" "1"
printf 'Enabled_Stacks="papa lima november"\n' > "$WORK/.env-stacks"

echo "== посторонний каталог среди vhost'ов"

# Docker, не найдя файла для bind-mount, заводит на его месте КАТАЛОГ от root.
# Он попадает под маску *.conf, по которой nginx читает включённые vhost'ы, и
# роняет его: «pread() ... failed (21: Is a directory)». С restart: always это
# краш-луп, уносящий все сайты, а сообщение говорит про pread — то есть отказ
# выглядит как поломка nginx, а не как мусор в каталоге.
#
# Пережить обновление платформы он может: state/ машинный, bootstrap его не
# трогает. Так и случилось — каталог от прежней спеки дождался версии, где
# маска стала его читать.
vh="$WORK/state/nginx-vhosts"
mkdir -p "$vh"
: > "$vh/10-enabled.conf"
check "нормальный каталог vhost'ов претензий не вызывает" "$(check_vhost_dir "$vh")" ""

mkdir -p "$vh/00-enabled.conf"
check "посторонний каталог найден" \
  "$(check_vhost_dir "$vh" | wc -l | tr -d ' ')" "1"
check "в сообщении есть выполнимая команда с sudo" \
  "$(check_vhost_dir "$vh" | grep -c 'sudo rm -rf')" "1"
rmdir "$vh/00-enabled.conf"

check "несуществующий каталог — не находка" "$(check_vhost_dir "$WORK/нет-такого")" ""

# Функция проверена выше, но она бесполезна, если её не зовут. Мест ровно два:
# перед записью в каталог (иначе nginx -t падает, и причина тонет в откате) и
# в --check (иначе про мусор узнают от краш-лупа).
check "проверка каталога вызывается и при записи, и при --check" \
  "$(grep -c 'check_vhost_dir "\$(dirname' "$REPO_DIR/platform/bin/stack.sh")" "2"

echo "== вложенные монтирования"

# Точку монтирования для вложенного пути docker создаёт ВНУТРИ уже
# смонтированного каталога. Если тот смонтирован с :ro, создать её нечем, и
# контейнер не стартует вовсе. Сообщение при этом говорит про mountpoint и
# read-only file system — то есть отказ выглядит как поломка docker, а не как
# неверная спека, и ищут его не там. Так стоял генерируемый список include'ов:
# файлом внутрь conf.d, смонтированного с :ro.
#
# Проверяем КЛАСС: ни одна цель монтирования не должна лежать внутри другой
# цели, смонтированной только на чтение. Разбираем все compose-файлы платформы,
# а не один nginx.yaml: следующий такой же появится в другом.
nested=""
while IFS= read -r f; do
  # Из строки-элемента volumes берём ЦЕЛЬ и режим: "<цель> <ro|rw>".
  #
  # Источник отрезаем по ПОСЛЕДНЕМУ ":/", а не по первому двоеточию: в
  # источнике стоит ${Platform_Deploy_Dir:?}, и двоеточие внутри подстановки
  # съедало половину строки. На этом гард сначала и промолчал.
  mounts=$(grep -oE '^[[:space:]]*-[[:space:]]+[^[:space:]]+:/[^[:space:]]+' "$f" \
           | sed -E 's|.*:(/[^:]+)(:([a-z]+))?$|\1 \2|; s/:ro$/ ro/; s/ $/ rw/' \
           | sed -E 's/ :ro$/ ro/; s/  +/ /')
  while IFS=' ' read -r ro_dst mode; do
    [ "${mode:-}" = ro ] || continue
    while IFS=' ' read -r o_dst _; do
      [ -n "${o_dst:-}" ] || continue
      case "$o_dst" in
        "$ro_dst"/*) nested="$nested $(basename "$f"):$o_dst-внутри-$ro_dst" ;;
      esac
    done <<< "$mounts"
  done <<< "$mounts"
done < <(find "$REPO_DIR/platform/compose" "$REPO_DIR/profiles" -name '*.yaml' 2>/dev/null)
check "внутрь :ro-каталога ничего не монтируется" "$nested" ""

echo "== генерируемые файлы: имя одно на всех"

# Переименование генерируемого файла обязано доходить до ВСЕХ, кто его
# называет. Фикс A15 переименовал 00-enabled.conf в 10-enabled.conf в
# генераторе — и не дошёл до compose, который монтирует его по имени, и до
# docker-compose.sh, где ветка case сверялась с образцом имени.
#
# Обошлось это дорого: docker на отсутствующий файл в bind-mount заводит
# КАТАЛОГ, после чего nginx не стартует вовсе — «create mountpoint ...
# read-only file system». То есть отказ выглядит как поломка docker, а не как
# незавершённое переименование.
#
# В compose литерал неизбежен: подстановок с вызовом функции там нет. Поэтому
# сверяем литерал с тем, что производит библиотека.
# Каталог, куда пишется генерируемый include, обязан быть смонтирован целиком.
inc_dir="$(basename "$(dirname "$(stacks_include_file)")")"
check "compose монтирует каталог генерируемых vhost'ов" \
  "$(grep -cE "state/$inc_dir:/etc/nginx/[a-z-]+:ro" "$REPO_DIR/platform/compose/nginx.yaml")" "1"

# И читается он ровно одной строкой из платформенного файла conf.d. Имя этого
# файла задаёт порядок: зоны лимитов обязаны быть объявлены до server-блоков.
inc_mount="$(grep -oE "state/$inc_dir:/etc/nginx/[a-z-]+:ro" "$REPO_DIR/platform/compose/nginx.yaml" | head -n 1)"
inc_mount="${inc_mount#*:}"; inc_mount="${inc_mount%:ro}"
check "платформа читает этот каталог одной строкой include" \
  "$(grep -rlF "include $inc_mount/" "$REPO_DIR"/platform/nginx-vhosts/*.conf 2>/dev/null | wc -l | tr -d ' ')" "1"
# Обе стороны обязаны найтись. Пустое имя сравнивается как меньшее любого, то
# есть исчезнувший файл зон выглядел бы как правильный порядок — проверка
# одобрила бы ровно то, ради чего написана.
reader=$(grep -rlF "include $inc_mount/" "$REPO_DIR"/platform/nginx-vhosts/*.conf 2>/dev/null | head -n 1)
limits=$(grep -rlE '^[[:space:]]*limit_req_zone' "$REPO_DIR"/platform/nginx-vhosts/*.conf 2>/dev/null | head -n 1)
check "зоны лимитов и читатель — оба на месте" \
  "$([ -n "$reader" ] && [ -n "$limits" ] && echo да || echo нет)" "да"
check "читатель сортируется ПОСЛЕ зон лимитов" \
  "$([ -n "$reader" ] && [ -n "$limits" ] && [ "$(basename "$limits")" \< "$(basename "$reader")" ] && echo да || echo нет)" "да"

# Имя генерируемого compose-файла в коде не пишется вовсе — спрашивается у
# stacks_static_file. Комментарии не в счёт: гард про код, а объяснение
# прошлого дефекта неизбежно называет файл.
stat_name="$(basename "$(stacks_static_file)")"
# grep по ОДНОМУ файлу не печатает его имя, поэтому строка начинается сразу с
# номера — шаблон исключения комментариев здесь другой, чем у гардов выше.
badstat=$(grep -In "$stat_name" "$REPO_DIR/platform/bin/docker-compose.sh" 2>/dev/null \
          | grep -vE '^[0-9]+:[[:space:]]*#' || true)
check "имя генерируемого compose-файла в коде не повторяется" "$badstat" ""

# Ни один потребитель не должен узнавать имя по образцу: образец переживает
# переименование молча, а ветка case перестаёт совпадать без единого слова.
badpat=$(grep -rInE '\*[0-9]+-enabled\.conf\)' "$REPO_DIR"/platform/bin "$REPO_DIR"/bin 2>/dev/null \
         | grep -vE '(selftest|mutate)\.sh:' | grep -vE ':[0-9]+:[[:space:]]*#' || true)
check "имя генерируемого файла не сверяется образцом" "$badpat" ""

echo "== устаревший bind-mount"

# ./bootstrap заменяет .stackyard целиком (rm -rf), а platform/ — симлинк туда.
# Контейнер, запущенный до этого, остаётся с монтированием на УДАЛЁННЫЙ
# каталог: путь в docker inspect прежний, файлов по нему ноль. Сверка путей
# такое пропускает — она сравнивает строки, а изменился inode.
#
# Саму сверку selftest прогнать не может (нужен docker), поэтому проверяется
# ПРАВИЛО. Пустой каталог на хосте не улика: смонтировать пустое законно, и
# [FAIL] на этом был бы вечной ложной тревогой на свежей машине.
check "непустой на хосте против пустого в контейнере — улика" \
  "$(mount_looks_stale 5 0 && echo да || echo нет)" "да"
check "совпадающие количества — не улика" \
  "$(mount_looks_stale 5 5 && echo да || echo нет)" "нет"
check "пусто с обеих сторон — не улика" \
  "$(mount_looks_stale 0 0 && echo да || echo нет)" "нет"
check "пусто на хосте, непусто в контейнере — не улика" \
  "$(mount_looks_stale 0 5 && echo да || echo нет)" "нет"
check "пустые аргументы не считаются уликой" \
  "$(mount_looks_stale "" "" && echo да || echo нет)" "нет"

echo "== корень машины из-под симлинка"

# Раскладка ровно как на машине: platform — симлинк в .stackyard/. Гард выше
# смотрит на текст скрипта, а этот блок — на то, КУДА скрипт на самом деле
# сходит. Текстовая проверка одна не годится: она пройдёт и на скрипте, где
# нужная строка есть, но стоит не в той ветке.
MROOT="$WORK/machine"
rm -rf "$MROOT"
mkdir -p "$MROOT/.stackyard"
cp -R "$REPO_DIR/platform" "$MROOT/.stackyard/platform"
ln -s .stackyard/platform "$MROOT/platform"
# pwd -P у ожидания — потому что скрипт разворачивает симлинки сам (cd -P), а
# в macOS $TMPDIR это /var -> /private/var. Иначе тест ловил бы раскладку
# временного каталога, а не то, ради чего написан.
MREAL="$(cd "$MROOT" && pwd -P)"
check "скрипт через симлинк видит корнем машину, а не .stackyard" \
  "$(cd "$MROOT" && env -u ROOT_DIR ./platform/bin/htpasswd.sh proba --list 2>&1)" \
  "empty: $MREAL/state/htpasswd/proba"
rm -rf "$MROOT"

echo "== переносимость: время, суммы, сторож"

# Метка S3 разбирается в ОДНО И ТО ЖЕ независимо от часового пояса машины, на
# которой запущена проверка. Иначе check-backups.sh считает возраст бэкапа со
# сдвигом на величину пояса: к востоку от Гринвича свежий дамп выглядит
# устаревшим (ложная тревога), к западу — устаревший проходит проверку.
# Второе тише и потому хуже.
#
# Гоняем в трёх поясах намеренно: в UTC неверный разбор даёт верный ответ, то
# есть тест, написанный только под UTC, был бы вечнозелёным.
for tz in UTC Asia/Tokyo America/New_York; do
  for form in '2026-01-02T03:04:05+00:00' '2026-01-02T03:04:05Z' \
              '2026-01-02T03:04:05.123456+00:00' '2026-01-02T06:04:05+03:00'; do
    check "iso_to_epoch $form в TZ=$tz" "$(TZ="$tz" iso_to_epoch "$form")" "1767323045"
  done
done
check "iso_to_epoch без смещения считает UTC" "$(TZ=Asia/Tokyo iso_to_epoch '2026-01-02T03:04:05')" "1767323045"
check "iso_to_epoch отвергает мусор" "$(iso_to_epoch 'не дата' >/dev/null 2>&1 && echo принял || echo отверг)" "отверг"

# Гарда версии bash проверяется НА ДЕЛЕ, а не наличием слова BASH_VERSINFO в
# файле: проверка «слово на месте» проходит и на обезвреженной гарде, и именно
# так она первую же мутацию и пропустила. Нужен настоящий старый bash — в macOS
# это штатный /bin/bash 3.2. Там, где его нет (Linux), проверять нечем и блок
# пропускается: лучше честный пропуск, чем тест, который ничего не значит.
old_bash=""
for b in /bin/bash /usr/bin/bash; do
  [ -x "$b" ] || continue
  v=$("$b" -c 'echo ${BASH_VERSINFO[0]}${BASH_VERSINFO[1]}' 2>/dev/null)
  [ -n "$v" ] && [ "$v" -lt 42 ] 2>/dev/null && { old_bash="$b"; break; }
done
if [ -n "$old_bash" ]; then
  check "библиотека отказывается работать на bash < 4.2" \
    "$("$old_bash" -c ". '$REPO_DIR/platform/lib/lib-env.sh'; echo загрузилась" 2>/dev/null)" ""
  check "и называет причину" \
    "$("$old_bash" -c ". '$REPO_DIR/platform/lib/lib-env.sh'" 2>&1 | grep -c 'bash >= 4.2')" "1"
else
  printf '  [--]   bash < 4.2 на этой машине нет — гарду версии проверить нечем\n'
fi

# Сумма — известного содержимого, а не «что-нибудь непустое»: пустая строка
# ровно так и появилась бы при отсутствии обеих команд, а сравнение с непустым
# ожиданием её ловит.
printf 'stackyard' > "$WORK/сумма.txt"
check "sha256_file считает сумму" "$(sha256_file "$WORK/сумма.txt")" \
  "660b926bc79186f63660911f660e1a187daf9fafd1700148d43fb7e02f909bb0"

# Сторож обязан отдавать 124 (как GNU timeout), сохранять уже напечатанное и
# пропускать чужой код возврата. Проверяем ФОЛБЭК — путь, который включается
# там, где timeout'а нет: штатный путь и без теста работает у всех.
guard_out=$(PATH=/usr/bin:/bin run_with_timeout 1 bash -c 'echo раньше; sleep 5; echo позже' 2>/dev/null); guard_rc=$?
check "сторож обрывает зависшее" "$guard_rc" "124"
check "сторож сохраняет напечатанное до обрыва" "$guard_out" "раньше"
PATH=/usr/bin:/bin run_with_timeout 5 bash -c 'exit 7' >/dev/null 2>&1; check "сторож пропускает чужой код возврата" "$?" "7"

echo "== распознавание дампа"

# Прошлая версия объявляла SQLite'ом ЛЮБОЙ gzip. А gzip'ом сжаты и дамп MySQL
# (.sql.gz), и tar источников files:/volume:. В аварийный день дамп базы шёл не
# той веткой восстановления, и в базу не попадало ничего — молча, потому что
# `gunzip -c > цель` отрабатывал успешно.
#
# Проверяем на НАСТОЯЩИХ файлах: распознавание по магии нельзя проверить
# фикстурой из строк.
bkd="$WORK/bk"; mkdir -p "$bkd/dir"
printf 'SQLite format 3\000' > "$bkd/plain.db"
gzip -c "$bkd/plain.db" > "$bkd/base.db.gz"
printf -- '-- dump\nCREATE TABLE t;\n' | gzip -c > "$bkd/mysql.sql.gz"
echo x > "$bkd/dir/f"; tar -czf "$bkd/files.tar.gz" -C "$bkd" dir
printf 'PGDMP\000\000\000\000\000\000\000\000\000\000\000' > "$bkd/pg.dump"

check "SQLite без сжатия"            "$(backup_file_kind "$bkd/plain.db")"     "sqlite_plain"
check "SQLite под gzip"              "$(backup_file_kind "$bkd/base.db.gz")"   "sqlite_gz"
check "дамп SQL под gzip — НЕ SQLite" "$(backup_file_kind "$bkd/mysql.sql.gz")" "unknown"
check "tar под gzip — НЕ SQLite"      "$(backup_file_kind "$bkd/files.tar.gz")" "tar_gz"
check "формат поставщика платформе неизвестен" "$(backup_file_kind "$bkd/pg.dump")" "unknown"

# Ключ seed'а: генератор пишет имя в нижнем регистре без префикса, и второе
# написание в инициализаторе означало бы, что seed молча не накатывается —
# база заведена, схема пуста, приложение падает уже в рантайме.
gen_key=$(printf '%s' "$DB_KEYS_OPTIONAL" | tr 'A-Z ' 'a-z\n' | grep -x dump)
check "генератор пишет ключ seed'а как 'dump'" "$gen_key" "dump"
for init in "$REPO_DIR"/profiles/stacks/*/db-init/initializer.sh; do
  [ -f "$init" ] || continue
  check "$(basename "$(dirname "$(dirname "$init")")"): инициализатор читает тот же ключ" \
    "$(grep -c "yq e '\.dump //" "$init")" "1"
done

echo "== пути в S3"

# Формула пути обязана быть ОДНА на всех потребителей. Разъезд означает, что
# backup.sh кладёт объект по одному пути, а check-backups.sh ищет по другому —
# и вечно докладывает «нет ни одного бэкапа» при исправных бэкапах. Обе стороны
# при этом выглядят работающими, поэтому проверка тут не про значение, а про то,
# что формула ровно одна.
dup=$(grep -hoE 'env_(get|require) Backup_(S3|DB)_Prefix' "$REPO_DIR"/platform/bin/*.sh | sort -u)
check "формулы префиксов не продублированы в bin/" "$dup" ""

# Префикс машины обязателен: бакет бывает общим на несколько машин, и умолчание
# означало бы дампы, уезжающие в чужой каталог поверх чужих. Раньше умолчанием
# было имя конкретной машины.
printf 'Backup_S3_Bucket=b\n' > "$WORK/.env-backup"
ENV_VARS=(); env_load_files "$WORK/.env-backup" >/dev/null 2>&1
check "без Backup_S3_Prefix формула отказывает" \
  "$(backup_s3_prefix 2>/dev/null; echo "код:$?")" "код:1"

echo "== раскладка профиля и фикстур"

# Эти проверки идут по РЕАЛЬНЫМ файлам, а не по фикстуре из mktemp: предмет
# здесь — сами стеки профиля и машин-фикстур, и разъехаться они могут только
# там.

check "профильные стеки объявляют stack.conf" \
  "$(ls "$REPO_DIR"/profiles/stacks/*/stack.conf 2>/dev/null | wc -l | tr -d ' ')" \
  "$(ls -d "$REPO_DIR"/profiles/stacks/*/ 2>/dev/null | wc -l | tr -d ' ')"

# Ровно один поставщик БД на префикс. Два стека с одним Provides_DB в профиле
# означали бы, что машина, включившая оба, тихо получает чужие заказы.
dupe_prefix=$(grep -h '^Provides_DB=' "$REPO_DIR"/profiles/stacks/*/stack.conf 2>/dev/null \
              | cut -d= -f2- | tr -d '"' | sort | uniq -d)
check "префиксы поставщиков в профиле уникальны" "$dupe_prefix" ""

# У поставщика обязан быть хук дампов: без него backup.sh молча не снимет ни
# одной базы, а check-backups.sh не сможет построить ожидаемый список.
for d in "$REPO_DIR"/profiles/stacks/*/; do
  name=$(basename "${d%/}")
  grep -q '^Provides_DB=' "$d/stack.conf" 2>/dev/null || continue
  check "поставщик $name: есть scripts/backup-dump.sh" \
    "$([ -x "$d/scripts/backup-dump.sh" ] && echo да || echo нет)" "да"
  check "поставщик $name: хук отвечает на ext" \
    "$(ROOT_DIR="$REPO_DIR" STACK_DIR="$d" "$d/scripts/backup-dump.sh" ext 2>/dev/null | head -c 1)" "."
done

# Движок обязан обслуживать ОБЕ машины-фикстуры без правок. Они с разными
# СУБД намеренно: платформа считается общей ровно тогда, когда обе работают.
# Фикстура настраивается ЗДЕСЬ, а не заранее руками.
#
# Её .env, .env-stacks и stacks/*/.env в git не лежат (это .env-файлы, правило
# одно на всех). Значит на свежем клоне их нет, и блок уходил в «пропускаю» —
# а пропуск неотличим от «проверено». Selftest был зелёным только на машине
# автора, где эти файлы остались с прошлых запусков.
#
# Поэтому копируем фикстуру во временный каталог и заводим ей окружение из
# образцов. Заодно это проверяет сами образцы: фикстура, у которой .env.example
# неполон, теперь не настроится.
fixture_machine() {
  local src="$1" dst="$2" f
  mkdir -p "$dst"
  cp -R "$src"/. "$dst"/ 2>/dev/null
  rm -rf "$dst/platform" "$dst/profile" "$dst/.stackyard" "$dst/state"
  ln -sfn "$REPO_DIR/platform" "$dst/platform"
  ln -sfn "$REPO_DIR/profiles" "$dst/profile"
  [ -f "$dst/.env-stacks" ] || cp "$dst/.env-stacks.example" "$dst/.env-stacks" 2>/dev/null
  if [ ! -f "$dst/.env" ] && [ -f "$dst/.env.example" ]; then
    sed "s|^Platform_Deploy_Dir=.*|Platform_Deploy_Dir=$dst|" "$dst/.env.example" > "$dst/.env"
  fi
  # Секреты стеков — из образцов, с подстановкой вместо CHANGE_ME. Значение
  # своё у каждой фикстуры: одинаковый секрет у двух машин — то, что ловит
  # bin/audit-isolation.sh, и заводить его здесь значило бы учить плохому.
  for f in "$dst"/stacks/*/; do
    [ -d "$f" ] || continue
    [ -f "$f/.env" ] && continue
    local ex; ex="$(cd "$REPO_DIR" && ROOT_DIR="$dst" bash -c ". platform/lib/lib-stacks.sh; stack_dir $(basename "${f%/}")")/.env.example"
    [ -f "$ex" ] || ex="$f/.env.example"
    [ -f "$ex" ] && sed "s/CHANGE_ME/$(basename "$dst")-fixture-pw/" "$ex" > "$f/.env"
  done
  # Профильным стекам .env тоже нужен, а их каталога в машине может не быть.
  while IFS= read -r st; do
    [ -n "$st" ] || continue
    local sd; sd="$dst/stacks/$st"
    [ -f "$sd/.env" ] && continue
    local pex="$REPO_DIR/profiles/stacks/$st/.env.example"
    [ -f "$pex" ] || continue
    mkdir -p "$sd"
    sed "s/CHANGE_ME/$(basename "$dst")-fixture-pw/" "$pex" > "$sd/.env"
  done < <(ROOT_DIR="$dst" bash -c ". $REPO_DIR/platform/lib/lib-stacks.sh; stacks_enabled 2>/dev/null")
}

fixtures_seen=0
for src in "$FIXTURES"/*/; do
  [ -d "$src" ] || continue
  name=$(basename "${src%/}")
  m="$WORK/fx-$name"
  fixture_machine "$src" "$m"
  fixtures_seen=$((fixtures_seen + 1))

  # Фикстура обязана быть НЕПУСТОЙ. Без этого все проверки ниже сравнивают
  # пустое с пустым и проходят: ровно так блок и выглядел «зелёным», когда на
  # деле пропускался. Пустое равно пустому — это не проверка.
  enabled_n=$( ROOT_DIR="$m" bash -c ". \"$LIB_DIR/lib-stacks.sh\"; stacks_enabled 2>/dev/null" | grep -c . || true)
  check "$name: фикстура настроена и непуста" \
    "$([ "${enabled_n:-0}" -ge 1 ] && echo да || echo "нет (стеков: ${enabled_n:-0})")" "да"

  # Domains и server_name — два списка одного и того же. Разъезд означает либо
  # сертификат, который выпускается и никому не служит, либо vhost, работающий
  # до первого посетителя.
  declared=$( ROOT_DIR="$m" bash -c ". \"$LIB_DIR/lib-stacks.sh\"; stacks_domain_names" 2>/dev/null )
  served=$(grep -rhE '^[[:space:]]*server_name[[:space:]]' "$m"/stacks/*/nginx/*.conf 2>/dev/null \
           | awk '{for (i = 2; i <= NF; i++) print $i}' | tr -d ';' | sed '/^$/d' | sort -u)
  check "$name: Domains совпадают с server_name" "$declared" "$served"

  # Стек без compose.yaml обязан объявить это явно. Молчаливая терпимость
  # превращала бы забытый файл в «стек без контейнеров».
  bad=""
  for d in "$m"/stacks/*/; do
    [ -f "$d/stack.conf" ] || continue
    [ -f "$d/compose.yaml" ] && continue
    grep -q '^Containers="\?no' "$d/stack.conf" || bad="$bad $(basename "${d%/}")"
  done
  check "$name: стеки без compose.yaml объявили Containers=no" "$bad" ""

  # Ни одного заказа базы без включённого поставщика: иначе стек «включается»
  # успешно и падает в рантайме на подключении.
  prefix=$( ROOT_DIR="$m" bash -c ". \"$LIB_DIR/lib-stacks.sh\"; stacks_db_prefix" 2>/dev/null )
  orphan=""
  if [ -z "$prefix" ]; then
    orphan=$(grep -lE '^[A-Za-z]+_(DB|User|Password)=' "$m"/stacks/*/stack.conf 2>/dev/null | wc -l | tr -d ' ')
    [ "$orphan" = "0" ] && orphan=""
  fi
  check "$name: заказов базы без поставщика нет" "$orphan" ""

  # Ни одного недостающего файла: если образец неполон, фикстура не настроится,
  # и раньше это было незаметно.
  missing_all=""
  while IFS= read -r st; do
    [ -n "$st" ] || continue
    mf=$( ROOT_DIR="$m" bash -c ". \"$LIB_DIR/lib-stacks.sh\"; stack_missing_files $st" 2>/dev/null )
    [ -n "$mf" ] && missing_all="$missing_all $st:$mf"
  done < <(ROOT_DIR="$m" bash -c ". \"$LIB_DIR/lib-stacks.sh\"; stacks_enabled 2>/dev/null")
  check "$name: у включённых стеков всё на месте" "$missing_all" ""
done

# Пропуск фикстуры неотличим от её проверки, поэтому их число проверяется явно.
# Две с разными СУБД — тот минимум, ради которого фикстуры и существуют.
check "фикстуры действительно прогнаны" "$([ "$fixtures_seen" -ge 2 ] && echo да || echo "нет ($fixtures_seen)")" "да"

echo "== .gitignore"

# Правило `.env*` без исключения молча съедает каждый новый образец: уже
# добавленные файлы продолжают отслеживаться, а новые не попадают в git, и
# обнаруживается это на свежей машине. Поэтому правила проверяются явно.
# Вне git-репозитория check-ignore ответить не может, и его молчание выглядело
# как «файл отслеживается» — шесть ложных провалов на распакованном архиве.
# Отсутствие ответа и ответ «нет» — разные вещи, и путать их нельзя нигде.
if ! ( cd "$REPO_DIR" && git rev-parse --git-dir ) >/dev/null 2>&1; then
  echo "  · это не git-репозиторий — правила .gitignore проверить нечем, блок пропущен"
else

ignored() {
  ( cd "$REPO_DIR" && git check-ignore -q "$1" 2>/dev/null && echo ignored || echo tracked )
}

# Секреты и состояние фикстур — мимо git. Настоящих машин здесь нет по
# построению: репозиторий публичный.
for f in tests/machines/alpha/.env \
         tests/machines/alpha/.env-stacks \
         tests/machines/alpha/stacks/site/.env \
         tests/machines/alpha/state/certs/x.crt \
         tests/machines/alpha/.stackyard/platform/bin/stack.sh \
         profiles/stacks/mysql/.env; do
  check "$f игнорируется" "$(ignored "$f")" "ignored"
done

# А образцы — наоборот: без них на сервере не из чего завести файл.
for f in tests/machines/alpha/.env.example \
         tests/machines/alpha/.env-stacks.example \
         tests/machines/alpha/stacks/site/.env.example \
         profiles/stacks/mysql/.env.example \
         platform/getssl-config/getssl.cfg \
         platform/getssl-config/getssl.cfg.template; do
  check "$f НЕ игнорируется" "$(ignored "$f")" "tracked"
done

# Ни одного секрета в общих слоях: они уезжают на КАЖДУЮ машину, и секрет в них
# означает секрет, размноженный по всем клиентам.
leaked=$(find "$REPO_DIR/platform" "$REPO_DIR/profiles" \
              \( -name '.env' -o -name '*.key' -o -name 'account.key' -o -name '*.pem' \) 2>/dev/null | wc -l | tr -d ' ')
check "в platform/ и profiles/ секретов нет" "$leaked" "0"

# Уже отслеживаемый файл, попавший под новое правило, git продолжает
# отслеживать — и правило выглядит работающим, не будучи им.
fell_out=$( cd "$REPO_DIR" && git ls-files | while IFS= read -r f; do
              git check-ignore -q "$f" 2>/dev/null && echo "$f"
            done )
check "отслеживаемые файлы не выпали из git" "$fell_out" ""

fi

echo
if [ "$failures" -eq 0 ]; then
  echo "selftest: всё сошлось"
  exit 0
fi
echo "selftest: провалов: $failures"
exit 1
