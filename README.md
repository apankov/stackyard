<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/assets/logo/stackyard-mark-dark.svg">
  <img src="docs/assets/logo/stackyard-mark.svg" alt="" width="72" height="72">
</picture>

# stackyard

[![selftest](https://github.com/apankov/stackyard/actions/workflows/selftest.yml/badge.svg)](https://github.com/apankov/stackyard/actions/workflows/selftest.yml)

Run several independent docker-compose projects on one host — one nginx in
front, TLS for every domain, a shared database, backups, alerts and systemd
timers — and keep a fleet of such hosts on known, pinned versions. Plain bash;
the server needs nothing but docker.

- **One list decides.** `Enabled_Stacks` in a machine's `machine.conf` is the only
  place that says what runs. Compose files, vhost includes, certificate domains,
  systemd units and database grants are derived from it.
- **Nothing half-enabled.** `./stack enable` starts the containers before the
  vhost and `disable` removes the vhost first, so nginx never points at a dead
  upstream and takes every site down with it.
- **Pinned, one machine at a time.** A machine records the commit it runs in
  `stackyard.lock`. Updating a client is a two-line diff in its repository, and
  there is deliberately no "update everyone".
- **Clients share nothing.** The platform is public and holds no secrets; each
  machine is a private repository, and `stackyard audit` catches a key, bucket
  or network that two of them share.
- **Checked, not assumed.** `./stack --check` asks the running host: upstreams,
  certificates, mounts, units, databases. The engine's own tests include a
  mutation run and a real `nginx -t` on every commit.

## Who it's for

Anyone keeping several small hosts, each running a handful of unrelated
projects: client sites and APIs on a VPS per client, a pile of side projects,
a team's internal tools (n8n, Metabase, Grafana, an admin panel), staging and
demo environments that come and go, an isolated installation per customer —
and, increasingly, the many small apps that AI agents build and that need
somewhere safe and cheap to live.

The pains it removes are the silent ones, because a fleet's state lives in
someone's head and in hand edits on the servers:

- a certificate expires while its renewal timer stays green → `Certs="external"`
  for names terminated elsewhere, and `check-certs.sh` for the rest;
- switching one project off takes every site on the host down with it, because
  its vhost still points at the removed container → `./stack disable` removes
  the vhost first, `--check` verifies every upstream;
- a fix reaches some hosts and not others, and a month later nobody knows which
  → one pinned commit per machine, `stackyard fleet` shows who is behind;
- a new host is built from a neighbour's `.env`, and two clients now share a
  backup bucket, an alert chat and an ACME key → `stackyard audit`;
- backups stop without a word, a 1 GB host is killed by OOM → `check-backups.sh`
  and `watch-host` alert, `./memory` shows what each project costs.

Not for you if you need high availability or a cluster (Kubernetes, Nomad), a
`git push` deploy (Dokku, Kamal) or a web UI (Coolify, CapRover), or if one
host with one compose project is all there is.

## Built for agents

An AI agent can run a stackyard fleet with the same guarantees a careful human
gets, because the design already assumes nobody should have to guess:

- **The whole state is text in git.** A machine is `stack.conf`, `machine.conf`
  and `stackyard.lock`: no control plane, no UI, no API token to a panel. Every
  change an agent makes is a diff a human can read before it is pushed.
- **Commands reconcile, and are safe to repeat.** `enable`, `disable`, `sync`
  and `init` bring the host in line with the manifest; the ones that change it
  take `--dry-run`.
- **Outcomes are checked by exit code**, one `[ok]` / `[!]` / `[FAIL]` line per
  finding, and failures name the command that fixes them.
- **Mistakes stay small.** Data and databases are never dropped, `purge` asks for
  the stack's name, `nginx -t` runs before every reload, there is no "update
  everyone", and a rollback is one command.
- **Isolation is least privilege.** One machine is one repository with no
  secrets in it, so an agent working on one client cannot see another.

What is still missing (machine-readable output, remote runs, per-machine agent
instructions) and how an agent should work with a machine:
[docs/guides/agents.md](docs/guides/agents.md).

## How it fits together

```
laptop                               GitHub                      server
stackyard CLI                        apankov/stackyard  ──────▶  /mnt/data/acme/
  new · pin · fleet · audit          (public: the platform)        stackyard.lock   the pinned commit
~/.local/share/stackyard/            you/machine-acme   ──────▶    .stackyard/versions/<commit>/
  versions/  repo.git  fleet         (private, one per host)       platform/ profile/ -> current
~/dev/machines/acme/ ────── push ──▶                                stacks/  .env*  state/
```

| Layer | What it is | Where it lives |
|---|---|---|
| `platform/` | the engine: stacks, dependencies, nginx, TLS, backups, systemd. Knows no machine, no DBMS, no secret | this repository |
| `profiles/` | reusable stacks: `mysql`, `pg`, `redis`, `php-fpm` | this repository |
| machine | its own stacks, `.env` files, generated state | a private repository per host |

## Quick start

On the laptop, once:

```sh
curl -o- https://raw.githubusercontent.com/apankov/stackyard/latest/install.sh | bash
stackyard fleet add-dir ~/dev/machines     # every machine created there is in the fleet
```

`latest` is the newest release; `…/stackyard/v0.37.0/install.sh` pins one. The
script prints the tag and commit it installed and keeps everything in
`~/.local/share/stackyard/`. A pipe into bash cannot be read first; to read it:
`curl -o install.sh <url> && less install.sh && bash install.sh`.

A new machine:

```sh
stackyard new ~/dev/machines/acme          # skeleton, pinned to the CLI's commit; a git repository
cd ~/dev/machines/acme
./bootstrap                                # the pinned platform here too, for ./stack on the laptop
$EDITOR .env.example                       # paths, network (no secrets: this is committed)
# describe your own stacks in stacks/, then list what runs:
./stack enable site --manifest-only        # writes machine.conf: site, and mysql and php-fpm it requires
git add -A && git commit -m acme && git push   # to a private repository
```

The secrets are never on the laptop: `.env.example` and `machine.conf` are
committed, and the real `.env` files are made on the server.

On the server:

```sh
git clone <the machine's repository> /mnt/data/acme && cd /mnt/data/acme
./bootstrap                        # the platform, at the commit in stackyard.lock
./stack init                       # .env files for what machine.conf lists; rerun until it passes
$EDITOR .env stacks/*/.env         # the secrets, here and only here
sudo ./host-setup                  # packages, placeholder certificates, timers
./stack sync                       # start what machine.conf lists, nginx last
./stack --check
```

Changing what runs is a commit: `./stack enable|disable <stack> --manifest-only`
on the laptop (or an edit of `machine.conf`), push, and on the server
`git pull && ./stack sync --dry-run && ./stack sync`. `sync` starts what the
manifest lists and reports, without stopping it, what it no longer lists.

Updating a machine:

```sh
stackyard install latest                   # the CLI itself; older versions stay installed
stackyard pin ~/dev/machines/acme          # shows the platform diff, rewrites the lock
git -C ~/dev/machines/acme commit -am "platform <tag>" && git -C ~/dev/machines/acme push
# on the server: git pull && ./bootstrap && ./stack sync && ./stack --check
stackyard fleet                            # who runs what, and how far behind
```

Rolling back is `stackyard pin <machine> --version <tag>`; to the version the
machine ran just before, `./bootstrap` switches back without a download.

## A stack is a directory

```
stacks/site/
  stack.conf                  what the stack is and needs
  .env.example                its variables; ./stack init makes .env from it
  compose.yaml                its containers (none here: Containers="no")
  nginx/01-app.example.com.conf
```

```sh
# stacks/site/stack.conf
Requires="mysql php-fpm"
Domains="app.example.com"
Containers="no"
Mysql_DB="${Site_DB_Name}"
Mysql_User="${Site_DB_User}"
Mysql_Password="${Site_DB_Password}"
Mysql_Grants="SELECT,INSERT,UPDATE,DELETE"
```

This site runs on the shared nginx and php-fpm, and its database is created in
the shared MySQL by the provider. The engine knows the provider only as a
role: a Postgres machine enables `pg` instead, and nothing in the platform
changes. Subdirectories are declarations too — `systemd/` installs units,
`scripts/health.sh` answers `--check`. Every key and why each one is explicit:
[docs/guides/stacks.md](docs/guides/stacks.md).

## On a machine

```sh
./stack list           # what is enabled and what is actually alive
./stack --check        # declarations, domains, databases, upstreams, vhosts, units
./stack sync           # apply machine.conf: start what it lists, rebuild vhosts (nginx -t, then reload)
./stack enable <stack> # add to machine.conf and bring up: containers first, then the vhost
./stack disable <stack> # remove from machine.conf: the vhost first, then the containers; data stays
./stack init           # missing .env files from their examples; names what is still CHANGE_ME
./dc <compose args>    # the only path to docker compose
sudo ./host-setup      # packages, certificate placeholders, timers, stack host parts
./memory               # where the memory went: by container, by stack, by role
```

Also on board: `backup.sh` (databases and declared files → GPG → S3, with
`check-backups.sh` watching freshness), `watch-host.sh` and `notify.sh` (disk,
containers and failed units → Telegram), `registry.sh` (logins, and moving
tags pinned to digests), getssl renewals on a timer.

## Requirements

- **Server:** Linux with systemd, docker with the compose plugin, bash ≥ 4.2.
  `host-setup` installs the rest (openssl, gnupg, sqlite, logrotate, …) with
  apt, dnf, yum, apk or zypper.
- **Laptop:** macOS or Linux, git, tar, python3, and bash ≥ 4.2 — on macOS that
  means a Homebrew bash; `/bin/bash` 3.2 is refused.

## Documentation

- [docs/guides/stacks.md](docs/guides/stacks.md) — writing stacks: every
  `stack.conf` key, copy or link, database providers, external certificates.
- [docs/architecture/platform-delivery.md](docs/architecture/platform-delivery.md)
  — the lock, `bootstrap`, versions side by side, rollback, offline and
  vendored installs.
- [docs/guides/agents.md](docs/guides/agents.md) — working with a fleet as an
  AI agent: the check loop, the rules, the gaps.
- [docs/guides/isolation.md](docs/guides/isolation.md) — what keeps clients
  apart, `audit`, machine state, pinned getssl.
- [SECURITY.md](SECURITY.md) — the threat model (what is isolated and what is
  not), and how to report a vulnerability.
- [docs/NAVIGATOR.md](docs/NAVIGATOR.md) — everything else: decisions, plans.

## Development

```sh
./platform/bin/selftest.sh   # the whole suite; the nginx -t block needs docker
./tests/mutate.sh            # breaks the engine one mutation at a time; each must be caught
```

Releases follow semver: every change to the platform is a tagged release, and
the `latest` branch follows the newest tag. The fixtures in `tests/machines/`
are synthetic, `alpha` on MySQL and `beta` on Postgres: the platform counts as
shared only while both run on it unchanged. How to contribute, and what a
change is expected to carry: [CONTRIBUTING.md](CONTRIBUTING.md).

MIT licensed.
