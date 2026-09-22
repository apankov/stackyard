# What the first real migration taught, and what to do next

Written 2026-09-22, the day a live machine was moved onto stackyard and the
work on that machine was closed. This is the handoff into the next piece of
work: changing stackyard's architecture.

The machine itself is finished and is not stackyard's business any more. What
belongs here is what the migration exposed about the platform.

## Where things stand

- stackyard is at **v0.21.2**; nineteen commits and fourteen releases happened
  during one day of running it against a live machine.
- The machine runs on it: shared MySQL 5.5 with production data, php-fpm,
  redis, Vault, nginx serving ten domains, systemd timers for certificates,
  backups, host watch and a weekly digest, notifications to Telegram.
- Backups upload and are checked; **a restore has still never been run**, so by
  this repository's own definition that machine has files in S3 rather than a
  backup. That is recorded on the machine, not here.

## The defects the day produced, as classes

Every one of these was found by running the thing, not by testing it. They are
listed as classes because each had several instances, and because the next
architecture change should make whole classes impossible rather than fix
instances.

1. **A check that reports its own failure as a finding.** `docker compose
   config` killed halfway still prints valid YAML; `nginx -T` likewise. With
   `2>/dev/null` and `|| true` around them, the comparison blamed the container
   for what the measurement was missing — a different accusation on every run.
   Fixed by keeping exit codes. The class: any check whose input comes from a
   command must decide what a failed command means before comparing anything.

2. **`| grep -q` under `set -o pipefail`.** grep exits on the first match, the
   writer dies of SIGPIPE, the pipeline returns 141, and a line that IS in the
   list counts as absent. Measured on the machine at ~1.3% of calls; in a check
   making twenty-two such calls it corrupted a quarter of the runs. Replaced by
   `list_has`, with a hygiene guard forbidding the pattern.

3. **Readiness that checks the wrong noun.** `command -v aws` answers "is the
   binary here", never "can it reach the bucket". A package check compared
   package NAMES while the machine had the commands under different names, and
   the resulting install could not succeed at all. Both now check the thing
   that matters.

4. **Advice that changes nothing.** `./dc up -d nginx` after `./bootstrap` does
   nothing, because the spec has not changed — only the inode behind it. The
   check printed that advice three times while the operator did as told and
   watched nothing happen.

5. **A directory docker invents.** A missing bind-mount source becomes a
   root-owned directory. The ACME webroot lived in the platform layer, which
   git cannot ship empty, so it was created by docker as root and getssl could
   never have written a challenge there. Invisible until a certificate actually
   needed renewing — every run until then exits cleanly with nothing to do.

6. **Two settings that must agree.** A backup schedule and a staleness
   threshold; an S3 prefix with or without a trailing slash; a declared
   privilege set and the one the account really has. Each pair drifts silently.
   Where possible the second value is now measured from the first rather than
   configured beside it.

7. **One threshold over dissimilar things.** A size floor meant for a database
   dump made a perfectly good list of grants red on every run, and a check that
   is always red stops being read at all.

8. **A step a person must remember.** After every `./bootstrap`, nginx has to
   be recreated. It was forgotten twice in one evening — by the person who had
   just written the rule down.

## Queued work, in the order I would take it

1. **`./stack init`** — create the missing `.env` files from their examples,
   chmod them, print what still needs filling. Removes the largest remaining
   pile of manual steps, and it is the cheapest of these.
2. **`sync` recreates nginx when a mount has gone stale** — class 8 above, with
   the upstream gate: recreate only when the upstreams are up, otherwise refuse
   and name the one that is down. Design sketch in `distribution-and-cli.md`.
3. **`install.sh` + a `stackyard` CLI** for the operator's tools. Same file.
4. **`apiVersion` in `stack.conf`** — idea 3 of `../architecture/k8s-assessment.md`.
   The platform's code is versioned; the declaration format is not, so an
   incompatible change will be read silently and wrongly.
5. **`Resources_Memory=`** — idea 1 of the same document. The machine that was
   migrated has 950 MB, of which one stack holds 224 MB permanently, and
   "check free memory before starting a container" is still a ritual.

## Smaller debts worth writing down

- The three-line AWS credential dance exists in `backup.sh`,
  `check-backups.sh` and now `host-setup.sh`. A third copy was a fair price for
  not importing config parsing into a preflight check; a fourth would not be.
- `check-backups.sh` has one freshness threshold for all sources. Per-source
  cadence was considered and rejected on measurement (the source in question
  compressed to 949 KB), but the moment a machine has a genuinely large source,
  both the cadence and the threshold need to become per-source together.
- `certs.sh --prune` removes configs; nothing removes stale certificates, on
  purpose. Worth revisiting only if a machine accumulates enough of them to
  matter.
- The mutation suite and the hygiene guards caught four of my own regressions
  during the day, including two vacuous checks I had just written. They earn
  their keep; keep adding a guard with every fix.
