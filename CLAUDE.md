# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

stackyard is a platform for running several independent docker-compose stacks
on a single host. It is written entirely in bash (bash >= 4.2; macOS `/bin/bash`
3.2 is rejected by `platform/lib/lib-env.sh`). The repository is **public** and
holds no real machines: every real machine lives in its own private repository
and pulls the platform by a pinned commit (`stackyard.lock` + `bootstrap`). Never
add real domains, client names or secrets. Fixture names stay under
`example.com`.

`README.md` is the design document. Read it before changing behavior.
`docs/NAVIGATOR.md` indexes the rest (ADRs, plans, the post-migration handoff).

## Commands

```sh
./platform/bin/selftest.sh                 # the whole test suite (engine + both fixtures + repo hygiene)
./tests/mutate.sh                          # mutation run: breaks the engine one mutation at a time, expects selftest to fail
./tests/mutate.sh certs                    # only mutations whose name contains "certs"
./tests/machines/alpha/stack --check       # run the engine against a fixture machine
./tests/machines/alpha/dc --all-stacks --examples config -q   # validate every compose file without secrets
shellcheck platform/bin/*.sh platform/lib/*.sh bin/*.sh
```

selftest has no per-test filter. It is one script of `check "<name>" "$got"
"$expected"` calls, so run the whole thing. `mutate.sh` works on a clone in a
temporary directory and never touches the working tree.

When you fix a bug in the engine, add a selftest check that fails without the
fix. If the bug is the kind that fails silently, also add a plausible mutation
to `MUTATIONS` in `tests/mutate.sh` (the format is `name@@file@@old@@new`, and
the separator is `@@` because patterns contain `|`). A mutation that nobody
would plausibly write adds nothing.

## Architecture

**Three layers.** `platform/` is the engine and knows no machine, no DBMS and no
secret. `profiles/stacks/` is a library of reusable stacks (`mysql`, `pg`,
`redis`, `php-fpm`). The machine is a separate private repo. On a machine,
`platform/` and `profile/` are symlinks into `.stackyard/`, which `bootstrap`
downloads. In `tests/machines/{alpha,beta}` they are symlinks straight into this
working tree, so engine edits show up in the fixtures immediately.

**A stack is a directory with `stack.conf`.** Its subdirectories are
declarations too: `compose.yaml`, `nginx/` (vhost includes), `systemd/` (units),
`scripts/health.sh` (asked by `--check`), `scripts/host-setup.sh`,
`scripts/check-decl.sh`, and `scripts/backup-dump.sh`. The `stack.conf` keys are
`Requires`, `Domains`, `Containers`, `Certs` (`getssl` or `external`),
`Provides_DB`, `DB_Init_Service`, and `<Provider>_DB/_User/_Password/...`.
Values are references into the stack's `.env`, not copies.

**Single source of truth.** `Enabled_Stacks` in the machine's `.env-stacks` is
the only list of enabled stacks. Compose files, nginx includes, cert domains,
systemd units and DB orders are all derived from it in `platform/lib/lib-stacks.sh`.
Do not add a second list anywhere: if compose and nginx disagree, nginx
crash-loops and takes down every vhost.

**Two stack roots.** A stack is looked up first in `stacks/` (a copy owned by the
machine), then in `profile/stacks/` (linked from the profile). The machine copy
shadows the profile one. A stack's `.env` is always read from the machine's
`stacks/<name>/.env`, even for a profile stack.

**The DB provider is a role.** The engine never names MySQL or Postgres. An
enabled stack declares `Provides_DB="Mysql"`, and consumers order databases with
`Mysql_*` keys. Knowledge that belongs to a specific DBMS (such as validating
grants) lives in that profile's `scripts/check-decl.sh`, not in the platform.

**Entry points.** A machine's root holds wrappers (`stack`, `dc`, `host-setup`,
`certs`, `registry`, `htpasswd`, `memory`). They are generated from
`templates/machine/wrapper` using the list in `templates/machine/wrappers`, and
each one sets `ROOT_DIR` before it `exec`s `platform/bin/<script>.sh`. Scripts
run directly also have to handle `ROOT_DIR` resolving inside `.stackyard/` (the
`${ROOT_DIR##*/} = .stackyard` fallback). `docker-compose.sh` is the only path
to `docker compose`.

**Machine state.** Generated files (certs, `getssl-config`, `databases.yaml`,
`state/nginx-vhosts/10-enabled.conf`, `nginx-static.generated.yaml`,
`state/bin/getssl`) go in `machines/<name>/state/` and are never committed.
Never write into `platform/` or `profile/` at runtime: they are shared or
replaced on the next update.

**Env parsing.** All `.env` reading goes through `lib-env.sh`, which parses line
by line and expands `${VAR}` like compose does. Never `source` a `.env` file.

**Workspace tools (`bin/`).** These run on the operator's laptop, not on a
machine: `new-machine.sh`, `pin.sh` (rewrites one machine's `stackyard.lock`;
there is deliberately no "update everyone"), `fleet.sh`, `audit-isolation.sh`
(looks for cross-machine leaks of secrets, buckets, networks and ACME keys) and
`vendor.sh` (emergency self-contained copy, checked by
`platform/bin/check-vendor.sh`).

**getssl** is not vendored. `platform/bin/getssl-fetch.sh` downloads it per
`platform/getssl.lock` (version + sha256).

## Conventions

- Portability matters: machines are Linux, while development happens on macOS.
  Avoid GNU-only flags such as `find -printf` or `date -d`, and don't call
  `timeout` or `shasum` directly. Use `run_with_timeout` and `sha256_file` from
  `lib-env.sh`. Several
  mutations in `tests/mutate.sh` exist to catch exactly these.
- Under `set -u`, read optional arguments as `${2-}` and test them explicitly.
- Comments explain *why*, often by naming the incident that motivated the code.
  Keep that density and voice when you edit.
- Releases: each `feat`/`fix` commit that changes the platform bumps
  `platform/VERSION` (semver) in the same commit, and that commit is tagged
  `vX.Y.Z`. Docs-only commits don't bump it. `profiles/VERSION` is versioned
  separately.
- Open work is tracked in `docs/devel/plans/extraction-backlog.md` and
  `docs/devel/plans/after-first-migration.md`.
