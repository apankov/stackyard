#!/usr/bin/env bash
#
# Liveness of php-fpm for `stack.sh --check`, plus the one setting this image
# cannot do without.
#
# We ask the container rather than reading 50-settings.ini: the image is BUILT
# from that file, and an edit that was never followed by `up -d --build` leaves
# the old settings running behind a correct file. The CLI reads the same conf.d
# as the FPM master, so its answer is the image's.
#
# Contract: no root, changes nothing, finishes within 10 seconds, and the first
# line of output becomes the reason in the report.

set -uo pipefail

v="$(docker exec php-fpm php5 -r 'echo ini_get("session.upload_progress.enabled") ? "on" : "off";' 2>/dev/null)" \
  || { echo "php-fpm does not run php5"; exit 1; }

# On, the upload-progress tracker is the known exploit path for
# CVE-2026-109618/109619: remote code execution with no fix for PHP 5.x.
[ "$v" = off ] || {
  echo "session.upload_progress.enabled is on -- RCE CVE-2026-109618/9; ./dc up -d --build php-fpm"; exit 1; }

echo "php-fpm answers, session.upload_progress off"
