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
check "a stack without stack.conf does not break reading" "$(stack_conf_get nosuch Domains)" ""
check "stack_requires reads from the file" "$(stack_requires bravo)" "pg qdrant"

echo "== generating the static spec"

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

echo "== whose certificate it is"

# Separate stack names rather than reusing the ones above: a test that has to
# put a fixture back the way it found it is a test that will one day forget.
fixture own stack.conf 'Domains="own.test"'
fixture alb stack.conf 'Domains="alb.test+www.alb.test"
Certs="external"'
printf 'Enabled_Stacks="own alb"\n' > "$WORK/.env-stacks"

# The split that matters: what nginx must SERVE does not change with who
# signed the certificate, while what getssl is pointed at does.
check "an external stack still contributes every name nginx serves" \
  "$(stacks_domain_names | tr '\n' ' ')" "alb.test own.test www.alb.test "
check "an external stack feeds no getssl config" \
  "$(stacks_domain_specs | tr '\n' ' ')" "own.test "
check "the getssl-managed domains leave it out" \
  "$(stacks_domains_getssl | tr '\n' ' ')" "own.test "
check "the external list carries the aliases too" \
  "$(stacks_domains_external | tr '\n' ' ')" "alb.test www.alb.test "

printf 'Enabled_Stacks="alb"\n' > "$WORK/.env-stacks"
check "a machine with nothing but external domains needs no getssl" \
  "$(stacks_getssl_any && echo yes || echo no)" "no"
check "...and asks for no getssl configs at all" "$(stacks_domain_specs)" ""

# The direction that matters: a manifest that did not arrive must not read as
# a decision to stop renewing anything.
printf 'Enabled_Stacks=""\n' > "$WORK/.env-stacks"
check "an empty manifest is not a declaration that nothing needs getssl" \
  "$(stacks_getssl_any && echo yes || echo no)" "yes"
rm -f "$WORK/.env-stacks"
check "a missing manifest is not one either" \
  "$(stacks_getssl_any && echo yes || echo no)" "yes"

# An unknown value must not quietly mean "external", and must not quietly mean
# the default either: it has to be said out loud while the machine keeps
# issuing the certificate, which is the safe half of the two.
fixture oops stack.conf 'Domains="oops.test"
Certs="exernal"'
printf 'Enabled_Stacks="alb oops"\n' > "$WORK/.env-stacks"
check "a typo in Certs is reported" \
  "$(check_certs_mode | grep -c 'stack oops: Certs="exernal" is not a known value')" "1"
check "a misdeclared stack is still treated as one this machine issues for" \
  "$(stacks_getssl_any && echo yes || echo no)" "yes"

printf 'Enabled_Stacks="bravo"\n' > "$WORK/.env-stacks"

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

# 1. A stack path built as a string is blind to the profile root: such a stack
#    simply is not found, and its preflight/health/stack.conf are silently
#    never read. The only legitimate way is stack_dir and what derives from it.
#
#    What is searched for is the SYMPTOM — the literal '/stacks/' immediately
#    before a substitution — rather than particular variable names: a guard
#    listing specific names misses $root, ${DEPLOY_DIR:?} and every file under
#    profiles/, matching nothing while six real cases exist, and thereby serves
#    as permission not to think about the class.
#
#    Legitimate exceptions are marked in the code with # stack-path-ok. There
#    are two kinds: the definition of the roots themselves, and a stack's .env,
#    which by design is ALWAYS the machine's. The marker is greppable, so an
#    exception is visible and countable; there must be no silent one.
built=$(grep -rInE '/stacks/\$' \
          "$REPO_DIR"/platform/bin "$REPO_DIR"/platform/lib "$REPO_DIR"/bin \
          "$REPO_DIR"/profiles 2>/dev/null \
        | grep -v 'stack-path-ok' \
        | grep -vE '(selftest|mutate)\.sh:' || true)
check "no stack path is built as a string" "$built" ""

# 2. Writing into platform/ or profile/: these are shared layers, and bootstrap
#    overwrites them wholesale. Anything written there disappears at the next
#    update, and until then sits in a layer distributed to every machine.
#
#    Any kind of write is searched for, not just `>`: cp, tee and >> count
#    too. And every directory that might hold writing code is examined, not
#    two of them.
writes=$(grep -rInE '(>>?|tee|cp|mkdir -p|install) +[^|#]*\$\{?(ROOT_DIR|REPO_DIR|Platform_Deploy_Dir)[^ "]*/(platform|profile)/' \
           "$REPO_DIR"/platform/bin "$REPO_DIR"/platform/lib "$REPO_DIR"/bin \
           "$REPO_DIR"/profiles 2>/dev/null \
        | grep -v 'stack-path-ok' | grep -vE '(selftest|mutate)\.sh:' || true)
check "nothing writes into the shared layers" "$writes" ""

# 3. `sudo -u` must pass ROOT_DIR through env: sudo resets the environment, and
#    a platform script would then derive the root from its own path — which is
#    inside .stackyard/platform/bin, making .stackyard the root. The failure
#    reads as "no .env" on a machine that has one.
badsudo=$(grep -rIn 'sudo -u' "$REPO_DIR"/platform/bin "$REPO_DIR"/bin 2>/dev/null \
          | grep -vE ':[0-9]+:[[:space:]]*#' \
          | grep -vE '(selftest|mutate)\.sh:' \
          | grep -v 'env ROOT_DIR=' || true)
check "sudo -u passes ROOT_DIR through" "$badsudo" ""

# 4. Package-manager commands are not hardcoded: the platform is distributed,
#    and naming one means that on another distribution the first install runs
#    into "command not found" — with advice that cannot be followed.
#
#    The abstraction itself, which has to enumerate the managers, is marked
#    # pkg-mgr-ok in the code, like the other legitimate exceptions: the marker
#    is greppable, so an exception is visible and countable.
hardpm=$(grep -rInE '(^|[^_[:alnum:]])(dnf|yum|apt-get|apk add|zypper) ' \
           "$REPO_DIR"/platform/bin "$REPO_DIR"/platform/lib "$REPO_DIR"/bin 2>/dev/null \
         | grep -vE ':[0-9]+:[[:space:]]*#' \
         | grep -v 'pkg-mgr-ok' || true)
check "package-manager commands are not hardcoded" "$hardpm" ""

# 5. A `# shellcheck source=` directive must resolve FROM THE REPOSITORY ROOT:
#    that is how shellcheck looks for it — relative to the working directory,
#    not to the file being checked. A ../lib/... form looks correct and
#    silently fails to resolve, and SC1091 is an info-level finding, so at
#    -S error it is invisible. The result: -x is enabled while every script is
#    linted in isolation, and a typo in a library path survives to runtime.
badsrc=""
while IFS= read -r line; do
  [ -n "$line" ] || continue
  t="${line##*source=}"; t="${t%% *}"
  [ -f "$REPO_DIR/$t" ] || badsrc="$badsrc ${line%%:*}:$t"
#    What is searched for is the REAL form of the directive (a whole line that
#    is a shellcheck comment) rather than a substring: otherwise the check
#    matches its own search pattern and the prose describing what it checks.
done < <(grep -rInE '^[[:space:]]*# shellcheck source=' "$REPO_DIR"/platform/bin "$REPO_DIR"/platform/lib \
           "$REPO_DIR"/bin "$REPO_DIR"/tests "$REPO_DIR"/profiles 2>/dev/null)
check "shellcheck source= directives resolve" "$badsrc" ""

# 6. A reference to a platform compose file that does not exist. A stale `-f`
#    makes compose fail on a non-existent file, a nearby 2>/dev/null swallows
#    it, and a whole block of checks is dead on every machine.
#
#    Comment lines are skipped: this guard is about CODE, not prose. An
#    explanation of a past defect inevitably contains the name of a file that
#    no longer exists, and catching that would mean forcing explanations to be
#    erased.
badref=""
for ref in $(grep -rIhE 'platform/compose/[A-Za-z0-9_.-]+\.yaml' \
               "$REPO_DIR"/platform/bin "$REPO_DIR"/bin 2>/dev/null \
             | grep -vE '^[[:space:]]*#' \
             | grep -oE 'platform/compose/[A-Za-z0-9_.-]+\.yaml' | sort -u); do
  case "$ref" in *.generated.yaml) continue ;; esac
  [ -f "$REPO_DIR/$ref" ] || badref="$badref $ref"
done
check "there are no references to non-existent platform files" "$badref" ""

# 7. Stack scripts source the libraries from platform/lib/. A path from an
#    older layout survives a move unnoticed, because its consequence looks like
#    "the stack does not answer" rather than like a broken script.
badlib=$(grep -rIn 'ROOT_DIR[^"]*}\?/scripts/lib-' "$REPO_DIR"/profiles "$REPO_DIR"/platform 2>/dev/null \
         | grep -vE ':[0-9]+:[[:space:]]*#' || true)
check "stacks source their libraries from platform/lib" "$badlib" ""

# 8. A specific machine's or client's name inside a shared layer. The
#    repository is public; besides the leak, such a name also makes any check
#    built around it pass silently on every other machine.
names=$(grep -rniE 'devbox6|devbox-asstnt|12devs|my-new-site|pankov\.me|filinn|pckup|sanya|quotrum|tokensale' \
          "$REPO_DIR"/platform "$REPO_DIR"/profiles "$REPO_DIR"/bin 2>/dev/null \
        | grep -v '^Binary' | grep -v 'selftest\.sh:[0-9]*:names=' \
        | grep -vE ':[0-9]+:[[:space:]]*#' || true)
check "no machine or client names appear in the platform" "$names" ""

# 9. A command that may be absent on another machine, or behave differently
#    there. Such failures are not caught by tests written on a machine where
#    everything happens to be installed. So what is caught is the CLASS — a
#    direct call bypassing the wrapper in lib-env.sh — rather than a particular
#    call. The wrappers have one legitimate home, marked # portable-ok.

#    9a. shasum/sha256sum. A missing tool yields an EMPTY checksum, which
#        matches nothing, and check-vendor then reports that every platform
#        file was edited in place: an absent tool looks like sabotage.
badsha=$(grep -rInE '(^|[^_[:alnum:]])(shasum|sha256sum)[[:space:]]' \
           "$REPO_DIR"/platform/bin "$REPO_DIR"/platform/lib "$REPO_DIR"/bin "$REPO_DIR"/tests 2>/dev/null \
         | grep -vE ':[0-9]+:[[:space:]]*#' \
         | grep -vE '(selftest|mutate)\.sh:' | grep -v 'portable-ok' || true)
check "checksums go through sha256_file" "$badsha" ""

#    9b. timeout comes from GNU coreutils and does not exist on macOS or BSD at
#        all. Without it the watchdog simply never starts, and --check hangs
#        exactly where the watchdog was needed: on an unresponsive health.sh.
badto=$(grep -rInE '(^|[^_[:alnum:]-])timeout[[:space:]]+"?\$' \
          "$REPO_DIR"/platform/bin "$REPO_DIR"/platform/lib "$REPO_DIR"/bin 2>/dev/null \
        | grep -vE ':[0-9]+:[[:space:]]*#' \
        | grep -vE '(selftest|mutate)\.sh:' | grep -v 'portable-ok' || true)
check "the timeout watchdog goes through run_with_timeout" "$badto" ""

#    9c. `find -printf` is a GNU extension; BSD find fails on it entirely. Such
#        a call wrapped in 2>/dev/null || true fails silently: a counter above
#        says "N unuploaded dumps" while the list below it comes out empty.
badfp=$(grep -rIn -- '-printf' "$REPO_DIR"/platform "$REPO_DIR"/bin "$REPO_DIR"/tests 2>/dev/null \
        | grep -v 'platform/getssl' | grep -vE '(selftest|mutate)\.sh:' \
        | grep -vE ':[0-9]+:[[:space:]]*#' || true)
check "find -printf (GNU only) is not used" "$badfp" ""

#    9d. `date -j -f` without -u and without %z in the format reads the string
#        as LOCAL time. S3 timestamps arrive in UTC, so east of Greenwich a
#        fresh backup looks stale, and west of it a stale backup passes the
#        check. The second is worse: a freshness check that silently approves
#        an old backup.
badtz=""
while IFS= read -r line; do
  [ -n "$line" ] || continue
  case "$line" in *'%z'*|*'date -j -u'*|*'%Z'*) continue ;; esac
  badtz="$badtz${line%%:*} "
done < <(grep -rIn 'date -j' "$REPO_DIR"/platform/bin "$REPO_DIR"/platform/lib "$REPO_DIR"/bin 2>/dev/null \
         | grep -v 'platform/getssl' | grep -vE '(selftest|mutate)\.sh:' \
         | grep -vE ':[0-9]+:[[:space:]]*#')
check "BSD date parsing does not treat UTC as local" "$badtz" ""

# 10. `declare -gA` requires bash >= 4.2, while the stock /bin/bash on macOS is
#     still 3.2. Without an explicit version check the library loads silently
#     with an empty ENV_VARS: every env_get returns its default, and the script
#     does something other than what was asked. The easiest way to land on 3.2
#     is sudo, which sanitises PATH.
badbv=""
for f in $(grep -rIl 'declare -gA' "$REPO_DIR"/platform/lib 2>/dev/null); do
  grep -q 'BASH_VERSINFO' "$f" || badbv="$badbv $f"
done
check "declare -gA is guarded by a bash version check" "$badbv" ""

# 11. Argument parsing: `WANT="$2"; shift 2` under set -u with a forgotten
#     value gives "$2: unbound variable" — a message about the script's
#     internals instead of one about what is missing on the command line.
badsh=$(grep -rIn 'shift 2' "$REPO_DIR"/bin "$REPO_DIR"/platform/bin 2>/dev/null \
        | grep -vE ':[0-9]+:[[:space:]]*#' \
        | grep -vE '(selftest|mutate)\.sh:' | grep -v '${2-}' || true)
check "an optional argument is read as \${2-}" "$badsh" ""

# 12. Duplicate detection through `prev` in awk must require the second line to
#     come from a DIFFERENT source. The same key of one machine lives in two
#     files at once, and without that condition the isolation audit reports
#     "the key is identical on machines X and X". A false alarm in a security
#     check is worse than no check: people learn not to read it, and stop
#     reading the genuine findings alongside.
#
#     What is examined is neither a line nor a file but a WINDOW around each
#     comparison. Line by line will not do: the source comparison sits on the
#     next line, inside the same awk program. Whole-file will not do either:
#     one file holds two such awk programs, and the corrected one would cover
#     for the broken one.
baddup=""
while IFS=: read -r f n _; do
  [ -n "${n:-}" ] || continue
  sed -n "$((n > 2 ? n - 2 : 1)),$((n + 5))p" "$f" | grep -qE '\$2 (==|!=) prev' \
    || baddup="$baddup $f:$n"
done < <(grep -rIn '$1 == prev' "$REPO_DIR"/bin "$REPO_DIR"/platform 2>/dev/null \
         | grep -vE '(selftest|mutate)\.sh:')
check "duplicate detection tells a source from itself" "$baddup" ""

# 13. Third-party code kept as a copy in the repository. Such a copy is both a
#     licensing problem in a permissively licensed public repository and a
#     drift problem: it accumulates local edits nobody remembers the origin of.
#     Third-party tools are pinned by a lock file and downloaded onto the
#     machine instead; this checks that no copy has come back and that no
#     references to one remain.
#
#     The symptom of a copy: an executable file outside bin/ and lib/ longer
#     than 500 lines. Small templates and configs do not look like that.
vendored=""
while IFS= read -r f; do
  case "$f" in */bin/*|*/lib/*) continue ;; esac
  [ -x "$f" ] || continue
  [ "$(wc -l < "$f")" -gt 500 ] && vendored="$vendored $f"
done < <(find "$REPO_DIR/platform" "$REPO_DIR/profiles" -type f 2>/dev/null)
check "no third-party code is kept as a copy in the platform" "$vendored" ""

#     The trailing ([^-.a-zA-Z0-9]|$) is required: without the "|$" the pattern
#     misses a reference at the END of a line — which is exactly how one looks
#     in an ExecStart.
stale=$(grep -rInE 'platform/getssl([^-.a-zA-Z0-9]|$)' "$REPO_DIR"/platform "$REPO_DIR"/bin "$REPO_DIR"/templates 2>/dev/null \
        | grep -vE '(selftest|mutate)\.sh:' | grep -vE ':[0-9]+:[[:space:]]*#' || true)
check "no references to the removed getssl copy remain" "$stale" ""

# 14. The machine root derived from a script's own path. On a machine,
#     platform/ is a symlink into .stackyard/, and `cd -P` resolves it: two
#     levels up gives .stackyard rather than the machine. A script then creates
#     state/ inside the layer that is overwritten by every ./bootstrap — and,
#     for instance, writes a password file where nothing will look for it while
#     honestly reporting that the file is empty.
badroot=""
for f in $(grep -rIl 'cd "$DIR0/../\.\." && pwd' "$REPO_DIR"/platform/bin 2>/dev/null); do
  grep -q '\.stackyard' "$f" || badroot="$badroot $f"
done
check "ROOT_DIR does not stay inside .stackyard" "$badroot" ""

# 15. Mutually exclusive htpasswd flags. -i reads the password from stdin, -b
#     takes it as the THIRD argument; together they mean "waiting for a third
#     argument" that never comes, and htpasswd prints its usage and exits. On a
#     server that looks like a broken script rather than like wrong flags. It
#     cannot be exercised by running it: htpasswd lives in a container, and
#     selftest runs without docker.
badflags=$(grep -n 'FLAGS=' "$REPO_DIR/platform/bin/htpasswd.sh" 2>/dev/null \
           | grep -E '\-[a-zA-Z]*i[a-zA-Z]*b|\-[a-zA-Z]*b[a-zA-Z]*i' || true)
check "htpasswd: -i and -b are never used together" "$badflags" ""

# 16. The machine's wrappers are listed once (templates/machine/wrappers), and
#     every target must exist: a typo here gives a machine an entry point that
#     fails with "the platform is missing" — a message about bootstrap, while
#     bootstrap has nothing to do with it.
badwrap=""
while IFS=: read -r name target; do
  case "$name" in ''|\#*) continue ;; esac
  [ -f "$REPO_DIR/platform/bin/$target" ] || badwrap="$badwrap $name->$target"
done < "$REPO_DIR/templates/machine/wrappers"
check "every wrapper target exists" "$badwrap" ""

# 17. One function defined twice. In bash the LAST definition wins, and the
#     first remains dead code that still looks live: an edit is made to it,
#     tested, and nothing changes. Worse if the copies have diverged: swapping
#     the blocks then silently restores the older behaviour.
dupfn=""
while IFS= read -r f; do
  while IFS= read -r fn; do
    [ "$(grep -cE "^${fn}\(\) \{" "$f")" -gt 1 ] && dupfn="$dupfn $(basename "$f"):$fn"
  done < <(grep -oE '^[a-z_][a-z_0-9]*\(\) \{' "$f" | sed 's/() {//' | sort -u)
done < <(find "$REPO_DIR/platform/lib" "$REPO_DIR/platform/bin" "$REPO_DIR/bin" -name '*.sh' 2>/dev/null)
check "no function is defined twice" "$dupfn" ""

# 18. A mutation pattern that no longer matches the code. A mutation that fails
#     to apply verifies NOTHING, and that is otherwise discovered only after a
#     full run — ten minutes later, and only if the whole output is read.
#
#     The FIRST line of each pattern is checked rather than the whole pattern:
#     multi-line patterns are assembled by mutate.sh from \n, and repeating its
#     parsing in full here would mean a second implementation that drifts from
#     the first. One line is enough to catch a rename or a translation — what
#     the guard exists for — and it produces no false alarms.
stale_mut=""
while IFS= read -r line; do
  case "$line" in *"@@"*) ;; *) continue ;; esac
  body="${line#*\'}"; body="${body%\'*}"
  body="${body//\'\"\'\"\'/\'}"
  name="${body%%@@*}"; rest="${body#*@@}"
  file="${rest%%@@*}"; rest="${rest#*@@}"
  pat="${rest%%@@*}"
  pat="${pat%%\\n*}"          # the first line only
  # sed rather than ${pat//...}: in a substitution pattern a backslash escapes
  # the next character, so \\& means merely "&" and the replacement silently
  # does nothing.
  pat="$(printf '%s' "$pat" | sed 's/\\&/\&/g')"
  [ -n "$pat" ] || continue
  if [ ! -f "$REPO_DIR/$file" ]; then
    stale_mut="$stale_mut [no such file: $file]"
  elif ! grep -qF -- "$pat" "$REPO_DIR/$file"; then
    stale_mut="$stale_mut [$name]"
  fi
done < <(sed -n "/^MUTATIONS=(/,/^)/p" "$REPO_DIR/tests/mutate.sh" | grep "@@")
check "mutation patterns still match the code" "$stale_mut" ""

# 19. The nginx image is one value shared by everyone who names it. On a
#     machine that overrides the image, a second copy means the password file
#     is prepared by a DIFFERENT nginx from the one that reads it — and the gid,
#     hence the file's permissions, comes from the image.
#     In compose a literal is unavoidable, so compose is not examined here;
#     this is about the scripts.
badimg=$(grep -rInE 'nginx:[0-9]+\.[0-9]+' "$REPO_DIR"/platform/bin "$REPO_DIR"/bin 2>/dev/null \
         | grep -vE '(selftest|mutate)\.sh:' | grep -vE ':[0-9]+:[[:space:]]*#' || true)
check "scripts take the nginx image from nginx_image" "$badimg" ""

# 20. A file created by a container is owned by root: it cannot be reassigned
#     on the host, and `chmod` from an ordinary user fails with EPERM. The
#     permissions must be set by the container itself, while it is root. This
#     checks that no host-side chmod on that file remains after the docker
#     run.
badchmod=$(grep -n '^chmod .*"\$FILE"' "$REPO_DIR/platform/bin/htpasswd.sh" 2>/dev/null || true)
check "the password file's permissions are set by the container, not the host" "$badchmod" ""

# 21. A provider validates the declaration addressed to it, and the two ways
#     that validation can go silently blind are both cheap to make: splitting
#     the list on whitespace (half of MySQL's privileges are two words) and a
#     `read` loop over input that does not end in a newline (a list of ONE
#     privilege is exactly that, and the loop body then never runs). Either
#     mistake turns the check into one that accepts everything, which is worse
#     than no check: it is read as a pass.
DM="$WORK/decl-machine"; rm -rf "$DM"; mkdir -p "$DM/stacks/t"
ln -sfn "$REPO_DIR/platform" "$DM/platform"
ln -sfn "$REPO_DIR/profiles" "$DM/profile"
: > "$DM/.env"
decl_check() {
  printf 'Mysql_User="u"\nMysql_Grants="%s"\n' "$1" > "$DM/stacks/t/stack.conf"
  ROOT_DIR="$DM" STACK_NAME=t DB_PREFIX=Mysql \
    bash "$REPO_DIR/profiles/stacks/mysql/scripts/check-decl.sh" 2>&1
}
check "a single bogus privilege is caught" "$(decl_check NOSUCH | grep -c NOSUCH)" "1"
check "a two-word privilege is accepted" "$(decl_check 'SELECT,LOCK TABLES')" ""
check "ALL PRIVILEGES is reported once" "$(decl_check 'ALL PRIVILEGES' | grep -c .)" "1"
check "a correct list stays silent" "$(decl_check 'SELECT,INSERT,UPDATE,DELETE')" ""

# 22. The S3 prefix is joined with "/" by every caller, so a value written with
#     a slash on either end produces keys with an empty path segment. The
#     writer and the checker would agree with each other and disagree with
#     every human reading the bucket — until someone tidies the config, after
#     which the checker looks in a place the writer never wrote to.
for pair in 'm/:m' '/m/:m' 'm:m' '//a/b//:a/b'; do
  ENV_VARS=(); ENV_VARS["Backup_S3_Prefix"]="${pair%%:*}"
  check "S3 prefix '${pair%%:*}' normalises to '${pair#*:}'" "$(backup_s3_prefix)" "${pair#*:}"
done

# 23. `| grep -q` under `set -o pipefail`. grep exits on the first match while
#     the writer is still writing; the writer dies of SIGPIPE and the pipeline
#     returns 141, so a line that IS in the list counts as absent. Measured on
#     a live machine at ~1.3% of calls — invisible in a test, and in a check
#     that runs twenty of them it made a quarter of the runs report something
#     that was not there. Membership goes through list_has; a grep reading
#     FILES is not a pipeline and is not affected.
# `[^|]` before the pipe so that `|| grep -q file` — an OR, not a pipeline —
# does not count: a grep reading files never sees a writer die.
pipeq=$(grep -rnE '[^|]\|[[:space:]]*grep[[:space:]]+-q' \
          "$REPO_DIR/platform/bin" "$REPO_DIR/platform/lib" "$REPO_DIR/profiles" "$REPO_DIR/bin" 2>/dev/null \
        | grep -vE '(selftest|mutate)\.sh:' | grep -vE ':[0-9]+:[[:space:]]*#' || true)
check "no membership test forks a grep into a pipe" "$pipeq" ""

# 24. list_has decides whether a check reports a finding, so its two failure
#     modes are both silent: a substring counted as a whole line hides a real
#     difference, and a glob character taken as a wildcard invents one.
LH="$(printf '%s\n' '/a -> /x' '/c*d -> /z')"
say() { "$@" && echo yes || echo no; }
check "list_has: an exact line is found"        "$(say list_has "$LH" '/a -> /x')" "yes"
check "list_has: a substring is not a line"     "$(say list_has "$LH" '/a')" "no"
check "list_has: a glob character is literal"   "$(say list_has "$LH" '/c*d -> /z')" "yes"
check "list_has: a glob does not match wildly"  "$(say list_has "$LH" '/cXd -> /z')" "no"
check "list_has: a trailing space is a difference" "$(say list_has "$LH" '/a -> /x ')" "no"

# 25. memory.sh answers "where did the memory go", so it must fail loudly when
#     it cannot measure. A report that silently prints zeros is read as "the
#     machine is idle" — the opposite of the truth it exists to tell.
printf 'SwapTotal: 0 kB\n' > "$WORK/meminfo-no-total"
mem_rc=0
STACKYARD_MEMINFO="$WORK/meminfo-no-total" "$REPO_DIR/platform/bin/memory.sh" --check >/dev/null 2>&1 || mem_rc=$?
check "memory.sh refuses a meminfo without MemTotal" "$mem_rc" "2"

# A lock file must name everything without which the download is not
# reproducible. An empty field here would mean "download whatever is served" —
# precisely what a lock file exists to prevent.
for field in repo version sha256; do
  v=$(sed -n "s/^$field=//p" "$REPO_DIR/platform/getssl.lock" | head -n 1)
  check "getssl.lock: field $field is filled in" "$([ -n "$v" ] && echo yes || echo no)" "yes"
done
# The checksum is exactly 64 hexadecimal characters. A truncated one, or one
# with a stray space, matches nothing, and getssl-fetch would report tampering
# forever.
check "getssl.lock: the checksum looks like a sha256" \
  "$(sed -n 's/^sha256=//p' "$REPO_DIR/platform/getssl.lock" | head -n 1 | grep -cE '^[0-9a-f]{64}$')" "1"

echo "== ordering and rate-limit zones"

# conf.d files are read alphabetically, and nginx resolves a zone name while
# parsing the server block. A generated file landing BEFORE the zone
# definitions means "unknown limit_req_zone" and a refusal to start — a crash
# loop under restart: always. nginx does not run on a developer's machine at
# all, so this is the only way to notice.
inc_name="$(basename "$(stacks_include_file)")"
first=$( { printf '%s\n' "$inc_name"
           ls -1 "$REPO_DIR"/platform/nginx-vhosts/*.conf 2>/dev/null | sed 's:.*/::'; } | sort | head -n 1)
check "zone definitions are read before the stacks' vhosts" \
  "$([ "$first" = "$inc_name" ] && echo "VHOSTS FIRST" || echo ok)" "ok"

# The platform carries only generic zones. A particular machine's policy —
# which URI counts as a login — would, once in a shared layer, travel to every
# machine at once. Comments are skipped, as in the other hygiene checks: an
# explanation of a past defect inevitably contains what it catches.
check "the platform's zones contain no machine-specific policy" \
  "$(grep -vE '^[[:space:]]*#' "$REPO_DIR"/platform/nginx-vhosts/00-limits.conf \
     | grep -cE 'map |user/login' || true)" "0"

# The image's compatibility with the platform's directives.
ENV_VARS=(); ENV_VARS[Platform_Nginx_Image]='nginx:1.19-alpine'
check "an old nginx image is reported" "$(check_nginx_image | grep -c 'older than 1.25.1')" "1"
ENV_VARS[Platform_Nginx_Image]='nginx:1.25.1-alpine'
check "1.25.1 raises nothing" "$(check_nginx_image)" ""
ENV_VARS=()

echo "== the include file: generator vs reader"

# The formula for an include line is written in one place and read in another.
# A mismatch is silent in both directions: a reader looking for a path the
# generator never produced matches nothing, and the VHOSTS column reports every
# stack with vhosts as disabled. A column that always lies is worse than a
# missing one.
fixture tango stack.conf 'Domains="tango.test"
Containers="no"'
fixture tango nginx/70-tango.conf 'server { server_name tango.test; }'
fixture_root profile/stacks uniform stack.conf 'Domains="uniform.test"
Containers="no"'
fixture_root profile/stacks uniform nginx/71-uniform.conf 'server { server_name uniform.test; }'
printf 'Enabled_Stacks="papa lima november tango uniform"\n' > "$WORK/.env-stacks"

mkdir -p "$(dirname "$(stacks_include_file)")"
stacks_include_content > "$(stacks_include_file)"

check "the reader sees an enabled machine stack" \
  "$(stack_vhost_enabled tango && echo yes || echo no)" "yes"
check "the reader sees an enabled PROFILE stack" \
  "$(stack_vhost_enabled uniform && echo yes || echo no)" "yes"

printf 'Enabled_Stacks="papa lima november"\n' > "$WORK/.env-stacks"
stacks_include_content > "$(stacks_include_file)"
check "a disabled stack is invisible to the reader" \
  "$(stack_vhost_enabled tango && echo yes || echo no)" "no"

echo "== the state of a fresh machine"

# On a fresh machine, right after ./bootstrap, there is no state/ directory at
# all: bootstrap delivers the platform, while state is the machine's own. The
# very first command would write into state/nginx-vhosts/ and die with a raw
# shell error, and databases.yaml would never be created — while --check
# demanded a `sync` that does not create it either. A closed loop in the first
# minute of using the platform.
rm -rf "$WORK/state"
printf 'Enabled_Stacks="papa lima"\n' > "$WORK/.env-stacks"
ensure_state_dirs
for d in nginx-vhosts certs htpasswd getssl-config; do
  check "state/$d was created" "$([ -d "$WORK/state/$d" ] && echo yes || echo no)" "yes"
done
check "the provider's directory was created" "$([ -d "$WORK/state/papa" ] && echo yes || echo no)" "yes"

# On a machine without a provider that directory must not exist: an empty one
# is as misleading there as a missing one is where it is needed.
rm -rf "$WORK/state"
printf 'Enabled_Stacks="lima"\n' > "$WORK/.env-stacks"
ensure_state_dirs
check "without a provider its directory is not created" \
  "$([ -d "$WORK/state/papa" ] && echo yes || echo no)" "no"
check "without a provider the database file path is empty" "$(stacks_databases_file)" ""
printf 'Enabled_Stacks="papa lima november"\n' > "$WORK/.env-stacks"

# Placeholder certificates must be created for profile stacks too. Otherwise
# the domain is declared, the getssl config exists, and the file does not —
# nginx will not start, and under restart: always it takes EVERY site on the
# machine down with it.
fixture_root profile/stacks sierra stack.conf 'Domains="sierra.test"
Containers="no"'
fixture_root profile/stacks sierra nginx/60-sierra.conf 'server {
	ssl_certificate /etc/nginx/certs/sierra.test-fullchain.crt;
	ssl_certificate_key /etc/nginx/certs/sierra.test.key;
}'
printf 'Enabled_Stacks="papa lima november sierra"\n' > "$WORK/.env-stacks"
check "a profile stack's certificate path is visible" \
  "$(stacks_cert_paths | grep -c 'sierra.test-fullchain.crt')" "1"
printf 'Enabled_Stacks="papa lima november"\n' > "$WORK/.env-stacks"

echo "== a stray directory among the vhosts"

# When Docker cannot find a file to bind-mount, it creates a root-owned
# DIRECTORY in its place. That directory matches the *.conf glob through which
# nginx reads the enabled vhosts, and brings it down: "pread() ... failed (21:
# Is a directory)". Under restart: always that is a crash loop taking every
# site with it, and the message talks about pread — so the failure looks like a
# broken nginx rather than like rubbish in a directory.
#
# Such a directory can survive a platform update: state/ belongs to the machine
# and bootstrap does not touch it.
vh="$WORK/state/nginx-vhosts"
mkdir -p "$vh"
: > "$vh/10-enabled.conf"
check "a normal vhost directory raises nothing" "$(check_vhost_dir "$vh")" ""

mkdir -p "$vh/00-enabled.conf"
check "a stray directory is found" \
  "$(check_vhost_dir "$vh" | wc -l | tr -d ' ')" "1"
check "the message carries a command that can actually be run, with sudo" \
  "$(check_vhost_dir "$vh" | grep -c 'sudo rm -rf')" "1"
rmdir "$vh/00-enabled.conf"

check "a non-existent directory is not a finding" "$(check_vhost_dir "$WORK/no-such-dir")" ""

# The function is exercised above, but it is useless if nobody calls it. There
# are exactly two places: before writing into the directory (otherwise nginx -t
# fails and the cause is buried under the rollback) and in --check (otherwise
# the rubbish is discovered through a crash loop).
check "the directory check is called both on write and in --check" \
  "$(grep -c 'check_vhost_dir "\$(dirname' "$REPO_DIR/platform/bin/stack.sh")" "2"

echo "== nested mounts"

# Docker creates the mount point for a nested path INSIDE the already-mounted
# directory. If that one is mounted :ro there is nothing to create it with, and
# the container does not start at all. The message talks about a mountpoint and
# a read-only file system — so the failure looks like a broken docker rather
# than like a wrong spec, and it gets investigated in the wrong place.
#
# What is checked is the CLASS: no mount target may lie inside another target
# mounted read-only. Every compose file of the platform is parsed, not just one
# of them: the next such mount will appear in a different file.
nested=""
while IFS= read -r f; do
  # From a volumes list item, take the TARGET and the mode: "<target> <ro|rw>".
  #
  # The source is cut at the LAST ":/" rather than at the first colon: the
  # source contains ${Platform_Deploy_Dir:?}, and the colon inside that
  # substitution would eat half the line — which is how this guard first
  # stayed silent.
  mounts=$(grep -oE '^[[:space:]]*-[[:space:]]+[^[:space:]]+:/[^[:space:]]+' "$f" \
           | sed -E 's|.*:(/[^:]+)(:([a-z]+))?$|\1 \2|; s/:ro$/ ro/; s/ $/ rw/' \
           | sed -E 's/ :ro$/ ro/; s/  +/ /')
  while IFS=' ' read -r ro_dst mode; do
    [ "${mode:-}" = ro ] || continue
    while IFS=' ' read -r o_dst _; do
      [ -n "${o_dst:-}" ] || continue
      case "$o_dst" in
        "$ro_dst"/*) nested="$nested $(basename "$f"):$o_dst-inside-$ro_dst" ;;
      esac
    done <<< "$mounts"
  done <<< "$mounts"
done < <(find "$REPO_DIR/platform/compose" "$REPO_DIR/profiles" -name '*.yaml' 2>/dev/null)
check "nothing is mounted inside a :ro directory" "$nested" ""

echo "== generated files: one name for everyone"

# Renaming a generated file must reach EVERYONE who names it. A rename that
# reaches the generator but not compose, which mounts the file by name, and not
# the branch that compares against a name pattern, is expensive: docker turns a
# missing bind-mount file into a DIRECTORY, after which nginx does not start at
# all — "create mountpoint ... read-only file system". The failure looks like a
# broken docker rather than like an unfinished rename.
#
# In compose a literal is unavoidable: there are no function calls in its
# substitutions. So the literal is compared against what the library produces.
#
# The directory the generated include is written into must be mounted whole.
inc_dir="$(basename "$(dirname "$(stacks_include_file)")")"
check "compose mounts the directory of generated vhosts" \
  "$(grep -cE "state/$inc_dir:/etc/nginx/[a-z-]+:ro" "$REPO_DIR/platform/compose/nginx.yaml")" "1"

# And it is read by exactly one include line from a platform conf.d file. That
# file's name fixes the order: rate-limit zones must be declared before any
# server block.
inc_mount="$(grep -oE "state/$inc_dir:/etc/nginx/[a-z-]+:ro" "$REPO_DIR/platform/compose/nginx.yaml" | head -n 1)"
inc_mount="${inc_mount#*:}"; inc_mount="${inc_mount%:ro}"
check "the platform reads that directory with a single include line" \
  "$(grep -rlF "include $inc_mount/" "$REPO_DIR"/platform/nginx-vhosts/*.conf 2>/dev/null | wc -l | tr -d ' ')" "1"
# Both sides must be found. An empty name compares as smaller than any other,
# so a vanished zones file would look like the correct order — the check would
# approve precisely what it was written to prevent.
reader=$(grep -rlF "include $inc_mount/" "$REPO_DIR"/platform/nginx-vhosts/*.conf 2>/dev/null | head -n 1)
limits=$(grep -rlE '^[[:space:]]*limit_req_zone' "$REPO_DIR"/platform/nginx-vhosts/*.conf 2>/dev/null | head -n 1)
check "the zones file and the reader are both present" \
  "$([ -n "$reader" ] && [ -n "$limits" ] && echo yes || echo no)" "yes"
check "the reader sorts AFTER the rate-limit zones" \
  "$([ -n "$reader" ] && [ -n "$limits" ] && [ "$(basename "$limits")" \< "$(basename "$reader")" ] && echo yes || echo no)" "yes"

# The generated compose file's name is never written in code — it is asked of
# stacks_static_file. Comments do not count: the guard is about code, and an
# explanation of a past defect inevitably names the file.
stat_name="$(basename "$(stacks_static_file)")"
# grep over ONE file does not print its name, so the line starts with the
# number — the comment-exclusion pattern here differs from the guards above.
badstat=$(grep -In "$stat_name" "$REPO_DIR/platform/bin/docker-compose.sh" 2>/dev/null \
          | grep -vE '^[0-9]+:[[:space:]]*#' || true)
check "the generated compose file's name is not repeated in code" "$badstat" ""

# No consumer may learn the name through a pattern: a pattern survives a rename
# silently, and the branch stops matching without a word.
badpat=$(grep -rInE '\*[0-9]+-enabled\.conf\)' "$REPO_DIR"/platform/bin "$REPO_DIR"/bin 2>/dev/null \
         | grep -vE '(selftest|mutate)\.sh:' | grep -vE ':[0-9]+:[[:space:]]*#' || true)
check "the generated file's name is never matched by pattern" "$badpat" ""

echo "== a stale bind mount"

# ./bootstrap replaces .stackyard wholesale (rm -rf), and platform/ is a
# symlink into it. A container started before that is left mounted onto a
# DELETED directory: the path in docker inspect is unchanged, and there are
# zero files behind it. Comparing paths misses this — it compares strings,
# while what changed is the inode.
#
# The comparison itself cannot be run by selftest (it needs docker), so what is
# checked is the RULE. An empty directory on the host is not evidence: mounting
# something empty is legitimate, and a [FAIL] on that would be a permanent
# false alarm on a fresh machine.
check "non-empty on the host against empty in the container is evidence" \
  "$(mount_looks_stale 5 0 && echo yes || echo no)" "yes"
check "matching counts are not evidence" \
  "$(mount_looks_stale 5 5 && echo yes || echo no)" "no"
check "empty on both sides is not evidence" \
  "$(mount_looks_stale 0 0 && echo yes || echo no)" "no"
check "empty on the host, non-empty in the container is not evidence" \
  "$(mount_looks_stale 0 5 && echo yes || echo no)" "no"
check "empty arguments are not evidence" \
  "$(mount_looks_stale "" "" && echo yes || echo no)" "no"

echo "== the machine root seen through a symlink"

# The layout exactly as on a machine: platform is a symlink into .stackyard/.
# The guard above looks at a script's text; this block looks at WHERE the
# script actually goes. A textual check alone will not do: it passes for a
# script that contains the right line in the wrong branch.
MROOT="$WORK/machine"
rm -rf "$MROOT"
mkdir -p "$MROOT/.stackyard"
cp -R "$REPO_DIR/platform" "$MROOT/.stackyard/platform"
ln -s .stackyard/platform "$MROOT/platform"
# The expectation goes through pwd -P because the script resolves symlinks
# itself (cd -P), and on macOS $TMPDIR is /var -> /private/var. Otherwise the
# test would be measuring the layout of the temp directory instead of the thing
# it was written for.
MREAL="$(cd "$MROOT" && pwd -P)"
check "through the symlink a script sees the machine as its root, not .stackyard" \
  "$(cd "$MROOT" && env -u ROOT_DIR ./platform/bin/htpasswd.sh proba --list 2>&1)" \
  "empty: $MREAL/state/htpasswd/proba"
rm -rf "$MROOT"

echo "== portability: time, checksums, the watchdog"

# An S3 timestamp must parse to THE SAME value regardless of the timezone of
# the machine running the check. Otherwise check-backups.sh computes a backup's
# age with an offset the size of the timezone: east of Greenwich a fresh dump
# looks stale (a false alarm), west of it a stale dump passes. The second is
# quieter and therefore worse.
#
# Three timezones on purpose: in UTC an incorrect parse gives the correct
# answer, so a test written only for UTC would be evergreen.
for tz in UTC Asia/Tokyo America/New_York; do
  for form in '2026-01-02T03:04:05+00:00' '2026-01-02T03:04:05Z' \
              '2026-01-02T03:04:05.123456+00:00' '2026-01-02T06:04:05+03:00'; do
    check "iso_to_epoch $form under TZ=$tz" "$(TZ="$tz" iso_to_epoch "$form")" "1767323045"
  done
done
check "iso_to_epoch treats a timestamp without an offset as UTC" "$(TZ=Asia/Tokyo iso_to_epoch '2026-01-02T03:04:05')" "1767323045"
check "iso_to_epoch rejects rubbish" "$(iso_to_epoch 'not a date' >/dev/null 2>&1 && echo accepted || echo rejected)" "rejected"

# The bash version guard is checked BY RUNNING IT, not by the presence of the
# word BASH_VERSINFO in the file: a "the word is there" check passes for a
# disarmed guard, which is exactly how it missed its first mutation. A genuinely
# old bash is needed — on macOS that is the stock /bin/bash 3.2. Where there is
# none (Linux), there is nothing to check with and the block is skipped: an
# honest skip beats a test that means nothing.
old_bash=""
for b in /bin/bash /usr/bin/bash; do
  [ -x "$b" ] || continue
  v=$("$b" -c 'echo ${BASH_VERSINFO[0]}${BASH_VERSINFO[1]}' 2>/dev/null)
  [ -n "$v" ] && [ "$v" -lt 42 ] 2>/dev/null && { old_bash="$b"; break; }
done
if [ -n "$old_bash" ]; then
  check "the library refuses to run on bash < 4.2" \
    "$("$old_bash" -c ". '$REPO_DIR/platform/lib/lib-env.sh'; echo loaded" 2>/dev/null)" ""
  check "and it states the reason" \
    "$("$old_bash" -c ". '$REPO_DIR/platform/lib/lib-env.sh'" 2>&1 | grep -c 'bash >= 4.2')" "1"
else
  printf '  [--]   no bash < 4.2 on this machine — the version guard cannot be exercised\n'
fi

# The checksum is of KNOWN content, not "something non-empty": an empty string
# is exactly what a missing tool would produce, and comparing against a
# non-empty expectation catches it.
printf 'stackyard' > "$WORK/checksum.txt"
check "sha256_file computes the checksum" "$(sha256_file "$WORK/checksum.txt")" \
  "660b926bc79186f63660911f660e1a187daf9fafd1700148d43fb7e02f909bb0"

# The watchdog must return 124 (as GNU timeout does), preserve what was already
# printed, and pass through someone else's exit code. What is exercised is the
# FALLBACK — the path taken where timeout does not exist: the normal path works
# for everyone without a test.
guard_out=$(PATH=/usr/bin:/bin run_with_timeout 1 bash -c 'echo before; sleep 5; echo after' 2>/dev/null); guard_rc=$?
check "the watchdog aborts something hung" "$guard_rc" "124"
check "the watchdog preserves what was printed before the abort" "$guard_out" "before"
PATH=/usr/bin:/bin run_with_timeout 5 bash -c 'exit 7' >/dev/null 2>&1; check "the watchdog passes through someone else's exit code" "$?" "7"

echo "== recognising a dump"

# Treating EVERY gzip as SQLite would be wrong: a SQL dump (.sql.gz) and a tar
# of files:/volume: sources are gzipped too. On the day a restore is needed, a
# database dump would take the wrong branch and nothing would land in the
# database — silently, because `gunzip -c > target` succeeds.
#
# Exercised against REAL files: magic-number recognition cannot be checked with
# a fixture made of strings.
bkd="$WORK/bk"; mkdir -p "$bkd/dir"
printf 'SQLite format 3\000' > "$bkd/plain.db"
gzip -c "$bkd/plain.db" > "$bkd/base.db.gz"
printf -- '-- dump\nCREATE TABLE t;\n' | gzip -c > "$bkd/mysql.sql.gz"
echo x > "$bkd/dir/f"; tar -czf "$bkd/files.tar.gz" -C "$bkd" dir
printf 'PGDMP\000\000\000\000\000\000\000\000\000\000\000' > "$bkd/pg.dump"

check "SQLite, uncompressed"             "$(backup_file_kind "$bkd/plain.db")"     "sqlite_plain"
check "SQLite under gzip"                "$(backup_file_kind "$bkd/base.db.gz")"   "sqlite_gz"
check "a SQL dump under gzip is NOT SQLite" "$(backup_file_kind "$bkd/mysql.sql.gz")" "unknown"
check "a tar under gzip is NOT SQLite"      "$(backup_file_kind "$bkd/files.tar.gz")" "tar_gz"
check "a provider's own format is unknown to the platform" "$(backup_file_kind "$bkd/pg.dump")" "unknown"

# The seed key: the generator writes the name in lowercase without a prefix,
# and a second spelling in the initializer would mean the seed silently never
# runs — the database is created, the schema is empty, and the application
# fails at runtime.
gen_key=$(printf '%s' "$DB_KEYS_OPTIONAL" | tr 'A-Z ' 'a-z\n' | grep -x dump)
check "the generator writes the seed key as 'dump'" "$gen_key" "dump"
for init in "$REPO_DIR"/profiles/stacks/*/db-init/initializer.sh; do
  [ -f "$init" ] || continue
  check "$(basename "$(dirname "$(dirname "$init")")"): the initializer reads the same key" \
    "$(grep -c "yq e '\.dump //" "$init")" "1"
done

echo "== paths in S3"

# A path formula must be ONE for all its consumers. A divergence means
# backup.sh stores an object under one path while check-backups.sh looks under
# another — and reports "no backups at all" forever while backups are healthy.
# Both sides look like they work, so the check here is not about the value but
# about there being exactly one formula.
dup=$(grep -hoE 'env_(get|require) Backup_(S3|DB)_Prefix' "$REPO_DIR"/platform/bin/*.sh | sort -u)
check "the prefix formulas are not duplicated in bin/" "$dup" ""

# The machine's prefix is mandatory: a bucket is sometimes shared by several
# machines, and a default would mean dumps landing in another machine's
# directory, on top of its dumps.
printf 'Backup_S3_Bucket=b\n' > "$WORK/.env-backup"
ENV_VARS=(); env_load_files "$WORK/.env-backup" >/dev/null 2>&1
check "without Backup_S3_Prefix the formula refuses" \
  "$(backup_s3_prefix 2>/dev/null; echo "code:$?")" "code:1"

echo "== the layout of the profile and the fixtures"

# These checks run against REAL files rather than a fixture in a temporary
# directory: the subject here is the profile's own stacks and the fixture
# machines, and those can only drift there.

check "profile stacks declare a stack.conf" \
  "$(ls "$REPO_DIR"/profiles/stacks/*/stack.conf 2>/dev/null | wc -l | tr -d ' ')" \
  "$(ls -d "$REPO_DIR"/profiles/stacks/*/ 2>/dev/null | wc -l | tr -d ' ')"

# Exactly one DB provider per prefix. Two stacks with the same Provides_DB in
# the profile would mean a machine enabling both quietly receives declarations
# meant for the other.
dupe_prefix=$(grep -h '^Provides_DB=' "$REPO_DIR"/profiles/stacks/*/stack.conf 2>/dev/null \
              | cut -d= -f2- | tr -d '"' | sort | uniq -d)
check "provider prefixes in the profile are unique" "$dupe_prefix" ""

# A provider must have a dump hook: without it backup.sh silently takes no
# database dumps at all, and check-backups.sh cannot build the expected list.
for d in "$REPO_DIR"/profiles/stacks/*/; do
  name=$(basename "${d%/}")
  grep -q '^Provides_DB=' "$d/stack.conf" 2>/dev/null || continue
  check "provider $name: scripts/backup-dump.sh exists" \
    "$([ -x "$d/scripts/backup-dump.sh" ] && echo yes || echo no)" "yes"
  check "provider $name: the hook answers ext" \
    "$(ROOT_DIR="$REPO_DIR" STACK_DIR="$d" "$d/scripts/backup-dump.sh" ext 2>/dev/null | head -c 1)" "."
done

# The engine must serve BOTH fixture machines with no edits. They run different
# DBMSes on purpose: the platform counts as shared exactly when both work.
# The fixture is set up HERE, not by hand beforehand.
#
# Its .env, .env-stacks and stacks/*/.env are not in git (they are .env files,
# and the rule is the same for everyone). So a fresh clone does not have them,
# and this block used to skip itself -- and a skip is indistinguishable from a
# pass. The selftest was green only on the author's machine, where those files
# survived from earlier runs.
#
# So we copy the fixture into a temp directory and build its environment from
# the examples. That also tests the examples themselves: a fixture whose
# .env.example is incomplete no longer sets up.
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
  # Stack secrets come from the examples, with a value substituted for
  # CHANGE_ME. Each fixture gets its own: the same secret on two machines is
  # exactly what bin/audit-isolation.sh catches, and planting one here would be
  # teaching the wrong habit.
  for f in "$dst"/stacks/*/; do
    [ -d "$f" ] || continue
    [ -f "$f/.env" ] && continue
    local ex; ex="$(cd "$REPO_DIR" && ROOT_DIR="$dst" bash -c ". platform/lib/lib-stacks.sh; stack_dir $(basename "${f%/}")")/.env.example"
    [ -f "$ex" ] || ex="$f/.env.example"
    [ -f "$ex" ] && sed "s/CHANGE_ME/$(basename "$dst")-fixture-pw/" "$ex" > "$f/.env"
  done
  # Profile stacks need a .env too, and the machine may have no directory for
  # them at all.
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

  # The fixture must be NON-EMPTY. Without that, every check below compares
  # empty with empty and passes: that is exactly how this block looked "green"
  # while in fact being skipped. Empty equals empty is not a check.
  enabled_n=$( ROOT_DIR="$m" bash -c ". \"$LIB_DIR/lib-stacks.sh\"; stacks_enabled 2>/dev/null" | grep -c . || true)
  check "$name: the fixture is set up and non-empty" \
    "$([ "${enabled_n:-0}" -ge 1 ] && echo yes || echo "no (stacks: ${enabled_n:-0})")" "yes"

  # Domains and server_name are two lists of the same thing. A divergence means
  # either a certificate that gets issued and serves nobody, or a vhost that
  # works only until the first visitor.
  declared=$( ROOT_DIR="$m" bash -c ". \"$LIB_DIR/lib-stacks.sh\"; stacks_domain_names" 2>/dev/null )
  served=$(grep -rhE '^[[:space:]]*server_name[[:space:]]' "$m"/stacks/*/nginx/*.conf 2>/dev/null \
           | awk '{for (i = 2; i <= NF; i++) print $i}' | tr -d ';' | sed '/^$/d' | sort -u)
  check "$name: Domains match server_name" "$declared" "$served"

  # A stack without compose.yaml must say so explicitly. Tolerating it silently
  # would turn a forgotten file into "a stack with no containers".
  bad=""
  for d in "$m"/stacks/*/; do
    [ -f "$d/stack.conf" ] || continue
    [ -f "$d/compose.yaml" ] && continue
    grep -q '^Containers="\?no' "$d/stack.conf" || bad="$bad $(basename "${d%/}")"
  done
  check "$name: stacks without compose.yaml declare Containers=no" "$bad" ""

  # No database order without an enabled provider: otherwise a stack "enables"
  # successfully and fails at runtime on the connection.
  prefix=$( ROOT_DIR="$m" bash -c ". \"$LIB_DIR/lib-stacks.sh\"; stacks_db_prefix" 2>/dev/null )
  orphan=""
  if [ -z "$prefix" ]; then
    orphan=$(grep -lE '^[A-Za-z]+_(DB|User|Password)=' "$m"/stacks/*/stack.conf 2>/dev/null | wc -l | tr -d ' ')
    [ "$orphan" = "0" ] && orphan=""
  fi
  check "$name: no database orders without a provider" "$orphan" ""

  # No missing files: if an example is incomplete the fixture will not set up,
  # and that used to go unnoticed.
  missing_all=""
  while IFS= read -r st; do
    [ -n "$st" ] || continue
    mf=$( ROOT_DIR="$m" bash -c ". \"$LIB_DIR/lib-stacks.sh\"; stack_missing_files $st" 2>/dev/null )
    [ -n "$mf" ] && missing_all="$missing_all $st:$mf"
  done < <(ROOT_DIR="$m" bash -c ". \"$LIB_DIR/lib-stacks.sh\"; stacks_enabled 2>/dev/null")
  check "$name: enabled stacks have everything in place" "$missing_all" ""
done

# Skipping a fixture is indistinguishable from checking it, so their count is
# asserted explicitly. Two, with different DBMSes, is the minimum the fixtures
# exist for.
check "the fixtures really ran" "$([ "$fixtures_seen" -ge 2 ] && echo yes || echo "no ($fixtures_seen)")" "yes"

echo "== .gitignore"

# An `.env*` rule without an exception silently eats every new example: files
# already added keep being tracked, new ones never reach git, and it surfaces
# only on a fresh machine. So the rules are asserted explicitly.
# Outside a git repository check-ignore cannot answer, and its silence looked
# like "the file is tracked" -- six false failures on an unpacked archive.
# No answer and an answer of "no" are different things, and confusing them is
# wrong anywhere.
if ! ( cd "$REPO_DIR" && git rev-parse --git-dir ) >/dev/null 2>&1; then
  echo "  . not a git repository -- nothing to check .gitignore rules with, block skipped"
else

ignored() {
  ( cd "$REPO_DIR" && git check-ignore -q "$1" 2>/dev/null && echo ignored || echo tracked )
}

# Fixture secrets and state stay out of git. There are no real machines here by
# construction: the repository is public.
for f in tests/machines/alpha/.env \
         tests/machines/alpha/.env-stacks \
         tests/machines/alpha/stacks/site/.env \
         tests/machines/alpha/state/certs/x.crt \
         tests/machines/alpha/.stackyard/platform/bin/stack.sh \
         profiles/stacks/mysql/.env; do
  check "$f is ignored" "$(ignored "$f")" "ignored"
done

# The examples are the opposite: without them there is nothing on the server to
# build the real file from.
for f in tests/machines/alpha/.env.example \
         tests/machines/alpha/.env-stacks.example \
         tests/machines/alpha/stacks/site/.env.example \
         profiles/stacks/mysql/.env.example \
         platform/getssl-config/getssl.cfg \
         platform/getssl-config/getssl.cfg.template; do
  check "$f is NOT ignored" "$(ignored "$f")" "tracked"
done

# No secrets in the shared layers: they ship to EVERY machine, so a secret
# there is a secret copied to every client.
leaked=$(find "$REPO_DIR/platform" "$REPO_DIR/profiles" \
              \( -name '.env' -o -name '*.key' -o -name 'account.key' -o -name '*.pem' \) 2>/dev/null | wc -l | tr -d ' ')
check "no secrets in platform/ and profiles/" "$leaked" "0"

# git keeps tracking a file that is already tracked when a new rule starts
# matching it -- so the rule looks like it works without working.
fell_out=$( cd "$REPO_DIR" && git ls-files | while IFS= read -r f; do
              git check-ignore -q "$f" 2>/dev/null && echo "$f"
            done )
check "tracked files did not fall out of git" "$fell_out" ""

fi

echo
if [ "$failures" -eq 0 ]; then
  echo "selftest: everything checks out"
  exit 0
fi
echo "selftest: failures: $failures"
exit 1
