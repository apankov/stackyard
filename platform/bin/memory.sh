#!/usr/bin/env bash

# Where a machine's memory went: by container, by stack and by role.
#
# `docker stats` answers "how much does this container eat", while the question
# people actually ask is "what does this stack cost" and "what is left if I
# start one more". These machines are small — under a gigabyte of RAM — and
# both answers used to be added up in one's head, from memory of which
# container belongs to whom.
#
#   ./platform/bin/memory.sh            the full report
#   ./platform/bin/memory.sh --brief    without the per-container table
#   ./platform/bin/memory.sh --check    only that the data can be collected
#
# No root, changes nothing.
#
# Roles are derived from the declarations rather than from a list of names: a
# service from platform/compose/* is the platform; a stack required by an
# enabled one (Requires=) is a dependency; the remaining enabled ones are
# applications. A list of names here would be a third place holding the same
# knowledge, and it would drift on the first stack anyone added.

# Deliberately no `-e`: the report is a dozen greps and awks, each of which
# legitimately finds nothing (a stack without containers, a container without a
# label). Under errexit the first of those ends the report silently — the block
# then looks empty rather than broken.
set -uo pipefail

DIR0="$( cd -P "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# The MACHINE's directory, not the platform's. Normally set by a wrapper in the
# machine root; the fallback is two levels up from platform/bin.
if [ -z "${ROOT_DIR:-}" ]; then
  ROOT_DIR="$( cd "$DIR0/../.." && pwd )"
  # On a machine platform/ is a symlink into .stackyard/, and the `cd -P` above
  # has already resolved it: two levels up would land inside the downloaded
  # layer instead of the machine.
  [ "${ROOT_DIR##*/}" = .stackyard ] && ROOT_DIR="${ROOT_DIR%/*}"
fi
LIB_DIR="$( cd "$DIR0/../lib" && pwd )"

# shellcheck source=platform/lib/lib-stacks.sh
. "$LIB_DIR/lib-stacks.sh"
# shellcheck source=platform/lib/lib-env.sh
. "$LIB_DIR/lib-env.sh"

# Overridable only for tests: on a machine this is always /proc/meminfo.
#
# /proc/meminfo rather than `free`: the output of `free` is localised and
# parsing it breaks on a machine with a non-English locale, while /proc/meminfo
# is stable "key: kilobytes" pairs.
MEMINFO="${STACKYARD_MEMINFO:-/proc/meminfo}"
PROC_DIR="${STACKYARD_PROC:-/proc}"
CGROUP_DIR="${STACKYARD_CGROUP:-/sys/fs/cgroup}"

# The level below which starting one more container is a lottery. Taken from
# observation on machines this size. It is a hint at the end of the report, not
# a check: the decision is a person's either way.
WARN_AVAIL_MB=150

MODE=full
case "${1:-}" in
  --brief) MODE=brief ;;
  --check) MODE=check ;;
  --help)  sed -n '3,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  "")      ;;
  *)       echo "Unknown argument: $1 (expected --brief or --check)" >&2; exit 2 ;;
esac

die() { echo "Error: $*" >&2; exit 2; }

# ------------------------------------------------------------------ the host

# A value from /proc/meminfo in megabytes. The key is passed without the colon.
meminfo_mb() {
  awk -v k="$1:" '$1 == k { printf "%.0f", $2 / 1024; exit }' "$MEMINFO" 2>/dev/null
}

[ -r "$MEMINFO" ] || die "cannot read $MEMINFO — is this a Linux machine?"

MEM_TOTAL=$(meminfo_mb MemTotal)
MEM_AVAIL=$(meminfo_mb MemAvailable)
SWAP_TOTAL=$(meminfo_mb SwapTotal)
SWAP_FREE=$(meminfo_mb SwapFree)
[ -n "$MEM_TOTAL" ] && [ "$MEM_TOTAL" -gt 0 ] 2>/dev/null || die "no MemTotal in $MEMINFO"

# --------------------------------------------------------------- containers

# "name<TAB>megabytes" for EVERY running container on the machine, not only the
# project's: someone else's container eats the same memory, and a report that
# hides it lies about the one number that matters — what is left.
container_usage() {
  docker stats --no-stream --format '{{.Name}}|{{.MemUsage}}' 2>/dev/null \
    | awk -F'|' '
        # docker prints "123.4MiB / 916MiB": usage on the left, limit on the right.
        function tomib(v,   n, u) {
          n = v + 0
          u = v; sub(/^[0-9.]+/, "", u)
          if (u ~ /^B/)    return n / 1048576
          if (u ~ /^[kK]/) return n / 1024
          if (u ~ /^G/)    return n * 1024
          if (u ~ /^T/)    return n * 1048576
          return n
        }
        NF >= 2 {
          split($2, a, "/"); gsub(/[[:space:]]/, "", a[1])
          printf "%s\t%.1f\n", $1, tomib(a[1])
        }'
}

if ! docker info >/dev/null 2>&1; then
  [ "$MODE" = check ] && die "the docker daemon is not responding — nothing to say about containers"
  echo "Error: the docker daemon is not responding" >&2
  exit 2
fi

USAGE="$(container_usage)"
if [ -z "$USAGE" ]; then
  [ "$MODE" = check ] && die "docker stats returned no containers"
  echo "Error: docker stats returned no containers" >&2
  exit 2
fi

[ "$MODE" = check ] && { echo "Data collected: $(printf '%s\n' "$USAGE" | grep -c .) containers, ${MEM_TOTAL} MB RAM."; exit 0; }

# ------------------------------------------------------------------ swap

# A container's swap, in megabytes. `docker stats` says nothing about swap in
# any column — and on a small machine swap is exactly what explains why "used"
# does not add up to the sum of the containers: pages that were swapped out are
# no longer in memory.current.
#
# The cgroup path is taken from the container's own /proc/<pid>/cgroup rather
# than assembled from its id: the layout depends on the cgroup driver (systemd
# versus cgroupfs), and a hardcoded path would fall apart on the first machine
# with the other one.
container_swap_mb() {
  local pid="$1" cg base memsw mem
  # cgroup v2: a single line like "0::/system.slice/docker-<id>.scope"
  cg=$(awk -F: '$1 == "0" { print $3; exit }' "$PROC_DIR/$pid/cgroup" 2>/dev/null)
  if [ -n "$cg" ] && [ -r "$CGROUP_DIR$cg/memory.swap.current" ]; then
    awk 'NR == 1 { printf "%.1f", $1 / 1048576 }' "$CGROUP_DIR$cg/memory.swap.current" 2>/dev/null
    return 0
  fi
  # cgroup v1: swap is the difference between memsw and memory proper.
  cg=$(awk -F: '$2 ~ /(^|,)memory(,|$)/ { print $3; exit }' "$PROC_DIR/$pid/cgroup" 2>/dev/null)
  base="$CGROUP_DIR/memory$cg"
  if [ -r "$base/memory.memsw.usage_in_bytes" ] && [ -r "$base/memory.usage_in_bytes" ]; then
    memsw=$(cat "$base/memory.memsw.usage_in_bytes" 2>/dev/null)
    mem=$(cat "$base/memory.usage_in_bytes" 2>/dev/null)
    awk -v a="${memsw:-0}" -v b="${mem:-0}" 'BEGIN { d = a - b; if (d < 0) d = 0; printf "%.1f", d / 1048576 }'
  fi
}

# "rss_kb<TAB>swap_kb<TAB>name<TAB>pid" for the HOST's processes. One pass over
# /proc for both lists — walking several hundred directories twice for the same
# files would buy nothing.
#
# Container processes are filtered out, and filtered out by the SHAPE of the
# cgroup path (docker-<id>.scope under the systemd driver, /docker/<id> under
# cgroupfs) rather than by the substring "docker": dockerd's own cgroup is
# /system.slice/docker.service, and a broad pattern made it disappear from the
# report — the single largest consumer on the machine.
#
# That is what separates this from `ps aux --sort=-rss`: there a container's
# process and a host process look identical, and `node dist/server.js` under a
# service user may equally be a forgotten dev server or the contents of a
# container.
#
# Unreadable /proc entries are counted into a FILE, not a variable: the loop
# sits on the left of a pipe, i.e. runs in a subshell, and an assignment there
# does not come back out. The counter is not cosmetic: another user's /proc
# cannot be read under hidepid, and without it the report would quietly
# understate swap while looking complete.
host_processes() {
  local p pid rss sw cg
  : > "$UNREADABLE_FILE"
  for p in "$PROC_DIR"/[0-9]*; do
    pid="${p##*/}"
    if [ ! -r "$p/status" ]; then printf '%s\n' "$pid" >> "$UNREADABLE_FILE"; continue; fi
    cg=$(cat "$p/cgroup" 2>/dev/null)
    case "$cg" in */docker-*.scope*|*/docker/*|*/kubepods*) continue ;; esac
    rss=$(awk '/^VmRSS:/ { print $2; exit }' "$p/status" 2>/dev/null)
    sw=$(awk '/^VmSwap:/ { print $2; exit }' "$p/status" 2>/dev/null)
    # Kernel threads have no VmRSS line at all; they do not belong in a report
    # about who took the memory.
    [ -n "$rss" ] || continue
    printf '%s\t%s\t%s\t%s\n' "$rss" "${sw:-0}" "$(cat "$p/comm" 2>/dev/null)" "$pid"
  done
}

# --------------------------------------------------------- maps and roles

# "service<TAB>stack" for every stack at once: parsing compose files costs
# noticeably more than the rest, and doing it inside the per-container loop
# would repeat that cost for nothing.
SERVICE_TO_STACK="$(
  while IFS= read -r s; do
    while IFS= read -r svc; do
      [ -n "$svc" ] && printf '%s\t%s\n' "$svc" "$s"
    done < <(stack_services "$s" 2>/dev/null)
  done < <(stacks_available)
)"

PLATFORM_SERVICES="$(platform_services | sed '/^$/d' | sort -u)"

# A stack's role. A dependency is one that at least one ENABLED stack names in
# Requires= — that is what "dependency" means on this machine.
role_of_stack() {
  local s="$1"
  if [ -n "$(stack_dependents "$s" 2>/dev/null)" ]; then
    printf 'dependency'
  elif stack_is_enabled "$s" 2>/dev/null; then
    printf 'application'
  else
    printf 'disabled'
  fi
}

CONTAINER_TO_SERVICE="$(project_containers)"

# "name<TAB>pid" in one call: a docker inspect per container would cost seconds
# on a machine with a dozen of them.
CONTAINER_PIDS="$(docker ps -q 2>/dev/null | xargs -r docker inspect \
  --format '{{.Name}}	{{.State.Pid}}' 2>/dev/null | sed 's|^/||')"

ROWS="$(mktemp)"
SWAP_ROWS="$(mktemp)"
UNREADABLE_FILE="$(mktemp)"
HOST_ROWS="$(mktemp)"
trap 'rm -f "$ROWS" "$SWAP_ROWS" "$UNREADABLE_FILE" "$HOST_ROWS"' EXIT

while IFS=$'\t' read -r name mib; do
  [ -n "$name" ] || continue
  svc="$(printf '%s\n' "$CONTAINER_TO_SERVICE" | awk -F'\t' -v n="$name" '$1 == n { print $2; exit }')"
  if [ -z "$svc" ]; then
    # No compose project label at all: the container was started outside this
    # repository. It eats the same memory.
    stack="—"; role="outside the project"
  elif list_has "$PLATFORM_SERVICES" "$svc"; then
    stack="platform"; role="platform"
  else
    stack="$(printf '%s\n' "$SERVICE_TO_STACK" | awk -F'\t' -v s="$svc" '$1 == s { print $2; exit }')"
    if [ -z "$stack" ]; then
      # No stack declares this service — the same thing stack.sh --check
      # catches with its orphaned-containers block.
      stack="—"; role="outside the stacks"
    else
      role="$(role_of_stack "$stack")"
    fi
  fi
  # A container's swap goes in a fifth column rather than a separate pass: it
  # is the stack's memory just as much as the resident part is. Without it the
  # table stands on its head — a stack with 35 MB resident and 417 in swap
  # looks like the cheapest one there is.
  pid="$(printf '%s\n' "$CONTAINER_PIDS" | awk -F'\t' -v n="$name" '$1 == n { print $2; exit }')"
  swap_mib=0
  if [ -n "$pid" ] && [ "$pid" != "0" ]; then
    swap_mib="$(container_swap_mb "$pid")"
    [ -n "$swap_mib" ] || swap_mib=0
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$stack" "$role" "$mib" "$swap_mib" >> "$ROWS"
done <<< "$USAGE"

# ------------------------------------------------------------------ output

step() { printf '\n== %s\n' "$1"; }

DOCKER_MB="$(awk -F'\t' '{ s += $4 } END { printf "%.0f", s }' "$ROWS")"
DOCKER_SWAP_MB="$(awk -F'\t' '{ s += $5 } END { printf "%.0f", s }' "$ROWS")"
pct_of_total() { awk -v v="$1" -v t="$MEM_TOTAL" 'BEGIN { printf "%.0f", (t > 0 ? v * 100 / t : 0) }'; }

USED_MB=$(( MEM_TOTAL - MEM_AVAIL ))

step "Host"
printf '  total       %5s MB\n' "$MEM_TOTAL"
printf '  used        %5s MB (%s%%)\n' "$USED_MB" "$(pct_of_total "$USED_MB")"
printf '  available   %5s MB (%s%%)\n' "$MEM_AVAIL" "$(pct_of_total "$MEM_AVAIL")"
printf '  containers  %5s MB (%s%%), %s running; %s MB more in swap\n' \
  "$DOCKER_MB" "$(pct_of_total "$DOCKER_MB")" "$(grep -c . "$ROWS")" "$DOCKER_SWAP_MB"
if [ "${SWAP_TOTAL:-0}" -gt 0 ] 2>/dev/null; then
  printf '  swap        %5s MB total, %s MB used\n' "$SWAP_TOTAL" "$((SWAP_TOTAL - SWAP_FREE))"
else
  # Not a nitpick: a build that sizes its heap from physical memory fails
  # outright on a machine this small without swap.
  printf '  swap        none\n'
fi

if [ "$MODE" = full ]; then
  step "Containers"
  printf '%s%s%s%s\n' "$(_cell CONTAINER 24)" "$(_cell STACK 14)" "$(_cell ROLE 20)" "   RAM     SWAP"
  while IFS=$'\t' read -r name stack role mib swap; do
    printf '%s%s%s%5.0f MB %5.0f MB\n' \
      "$(_cell "$name" 24)" "$(_cell "$stack" 14)" "$(_cell "$role" 20)" "$mib" "$swap"
  done < <(sort -t$'\t' -k4 -gr "$ROWS")
fi

# Sorted by the SUM, not by the resident part: a stack whose memory has been
# swapped out costs the machine just as much — it will take it back the moment
# it is woken, and that is exactly what makes the free figure deceptive.
step "By stack"
printf '%s%s%s%s\n' "$(_cell STACK 14)" "$(_cell ROLE 20)" "$(_cell CONT. 7)" "   RAM     SWAP    TOTAL"
while IFS=$'\t' read -r stack role n mib swap total; do
  printf '%s%s%s%5.0f MB %5.0f MB %5.0f MB\n' \
    "$(_cell "$stack" 14)" "$(_cell "$role" 20)" "$(_cell "$n" 7)" "$mib" "$swap" "$total"
done < <(awk -F'\t' '
    { k = $2 "\t" $3; n[k]++; m[k] += $4; w[k] += $5 }
    END { for (k in m) printf "%s\t%d\t%.1f\t%.1f\t%.1f\n", k, n[k], m[k], w[k], m[k] + w[k] }
  ' "$ROWS" | sort -t$'\t' -k6 -gr)

step "By role"
printf '  %s%s\n' "$(_cell ROLE 20)" "   RAM     SWAP    TOTAL"
while IFS=$'\t' read -r role mib swap total; do
  printf '  %s%5.0f MB %5.0f MB %5.0f MB\n' "$(_cell "$role" 20)" "$mib" "$swap" "$total"
done < <(awk -F'\t' '
    { m[$3] += $4; w[$3] += $5 }
    END { for (k in m) printf "%s\t%.1f\t%.1f\t%.1f\n", k, m[k], w[k], m[k] + w[k] }
  ' "$ROWS" | sort -t$'\t' -k4 -gr)

SWAP_USED=$(( ${SWAP_TOTAL:-0} - ${SWAP_FREE:-0} ))

# One walk over /proc for both blocks below.
host_processes > "$HOST_ROWS"
HOST_RSS_MB="$(awk -F'\t' '{ s += $1 } END { printf "%.0f", s / 1024 }' "$HOST_ROWS")"

if [ "$MODE" = full ]; then
  step "Host processes"
  printf '%s%s%s\n' "$(_cell PROCESS 24)" "$(_cell PID 10)" "   RSS     SWAP"
  while IFS=$'\t' read -r rss sw comm pid; do
    printf '%s%s%5.0f MB %5.0f MB\n' "$(_cell "$comm" 24)" "$(_cell "$pid" 10)" \
      "$(awk -v k="$rss" 'BEGIN { print k / 1024 }')" "$(awk -v k="$sw" 'BEGIN { print k / 1024 }')"
  done < <(sort -t$'\t' -k1 -rn "$HOST_ROWS" | head -n 10)
  printf '  outside containers in total: %s MB resident\n' "$HOST_RSS_MB"
fi

if [ "$SWAP_USED" -gt 0 ] && [ "$MODE" = full ]; then
  # Containers were already measured in the main pass — docker is not asked twice.
  while IFS=$'\t' read -r name stack _ _ sw; do
    awk -v v="${sw:-0}" 'BEGIN { exit !(v >= 0.5) }' || continue
    printf '%s\t%s\t%s\n' "$name" "$stack" "$sw" >> "$SWAP_ROWS"
  done < "$ROWS"

  # Host processes: the ones that explain the "outside containers" difference.
  while IFS=$'\t' read -r _ kb comm pid; do
    [ -n "$kb" ] && [ "$kb" -gt 0 ] 2>/dev/null || continue
    printf '%s (pid %s)\t—\t%s\n' "$comm" "$pid" "$(awk -v k="$kb" 'BEGIN { printf "%.1f", k / 1024 }')" \
      >> "$SWAP_ROWS"
  done < <(sort -t$'\t' -k2 -rn "$HOST_ROWS" | head -n 10)

  step "Swap"
  printf '  %s MB used of %s\n' "$SWAP_USED" "$SWAP_TOTAL"
  if [ -s "$SWAP_ROWS" ]; then
    printf '%s%s%s\n' "$(_cell "CONTAINER OR PROCESS" 30)" "$(_cell STACK 14)" "SWAP"
    while IFS=$'\t' read -r label stack mb; do
      printf '%s%s%5.0f MB\n' "$(_cell "$label" 30)" "$(_cell "$stack" 14)" "$mb"
    done < <(sort -t$'\t' -k3 -gr "$SWAP_ROWS")

    # Swap that could not be attributed to anyone. Usually these are processes
    # that have long since exited and whose pages the kernel has not reclaimed
    # — but if the difference is large, part of /proc did not read, and the
    # number below says so plainly.
    accounted=$(awk -F'\t' '{ s += $3 } END { printf "%.0f", s }' "$SWAP_ROWS")
    if [ "$accounted" -gt "$SWAP_USED" ]; then
      # More than is in use means something was counted twice: as itself and as
      # its cgroup. That happens when a process's /proc did not read and it was
      # not recognised as a container's. Printed as is: a figure massaged to
      # add up would look precise without being so.
      printf '  %s MB accounted for — more than is in use, some pages counted twice\n' "$accounted"
    else
      printf '  %s MB accounted for out of %s\n' "$accounted" "$SWAP_USED"
    fi
  else
    printf '  by whom exactly is not visible: cgroup and /proc did not read, try under sudo\n'
  fi
  # `grep -c` on empty input prints 0 AND returns 1 — with `|| echo 0` that
  # produced the value "0\n0", on which `[` fails with "integer expression
  # expected". wc -l does not do that.
  unreadable=$(wc -l < "$UNREADABLE_FILE" 2>/dev/null | tr -d ' ')
  unreadable=${unreadable:-0}
  [ "$unreadable" -gt 0 ] && printf '  processes skipped (no access to /proc): %s — fuller under sudo\n' "$unreadable"
fi

step "Bottom line"
printf '  %s MB available of %s\n' "$MEM_AVAIL" "$MEM_TOTAL"

# The difference between what is used and the sum of the containers is the
# host: the kernel, sshd, systemd, docker itself. It cannot be printed as a row
# in the roles table: everything there is counted from docker stats, and this
# comes from a different source.
#
# The difference can be negative, and that is not a counting error: docker
# stats reports its cgroup's memory.current, which includes page cache that the
# kernel will hand back under pressure, while MemAvailable no longer counts it
# as used. Silently clamping that to zero would mean printing a pretty figure
# that is wrong.
OUTSIDE_MB=$(( USED_MB - DOCKER_MB ))
if [ "$OUTSIDE_MB" -ge 0 ]; then
  printf '  outside containers %s MB: host processes %s MB, the rest is the kernel and its structures\n' \
    "$OUTSIDE_MB" "$HOST_RSS_MB"
else
  printf '  the containers sum to %s MB more than is in use: docker stats also counts\n' "$(( -OUTSIDE_MB ))"
  printf '  page cache, which the kernel hands back under pressure\n'
fi
if [ "$MEM_AVAIL" -lt "$WARN_AVAIL_MB" ]; then
  printf '  [!] under %s MB — starting one more container is a gamble;\n' "$WARN_AVAIL_MB"
  printf '      look at the top of the container table first\n'
fi
