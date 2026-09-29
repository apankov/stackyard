# stackyard

[![selftest](https://github.com/apankov/stackyard/actions/workflows/selftest.yml/badge.svg)](https://github.com/apankov/stackyard/actions/workflows/selftest.yml)

Run several independent docker-compose projects on one host — one nginx in
front, TLS for every domain, a shared database, backups, alerts and systemd
timers — and keep a fleet of such hosts on known, pinned versions. Plain bash;
the server needs nothing but docker.

- **One list decides.** `Enabled_Stacks` in a machine's `.env-stacks` is the only
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

It is not a cluster scheduler and not a PaaS with a web UI or git-push deploys:
one host, several projects, and an operator who wants to know exactly what is
on it.

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

`latest` is the newest release; `…/stackyard/v0.30.2/install.sh` pins one. The
script prints the tag and commit it installed and keeps everything in
`~/.local/share/stackyard/`. A pipe into bash cannot be read first; to read it:
`curl -o install.sh <url> && less install.sh && bash install.sh`.

A new machine:

```sh
stackyard new ~/dev/machines/acme          # skeleton, pinned to the CLI's commit
cd ~/dev/machines/acme && git init
$EDITOR .env.example .env-stacks.example   # paths, network; Enabled_Stacks
# describe your own stacks in stacks/, commit, push to a private repository
```

On the server:

```sh
git clone <the machine's repository> /mnt/data/acme && cd /mnt/data/acme
./bootstrap                        # the platform, at the commit in stackyard.lock
./stack init mysql php-fpm site    # .env files from their examples; rerun until it passes
$EDITOR .env stacks/*/.env
sudo ./host-setup                  # packages, placeholder certificates, timers
./stack enable mysql php-fpm site
./stack --check
```

Updating a machine:

```sh
stackyard install latest                   # the CLI itself; older versions stay installed
stackyard pin ~/dev/machines/acme          # shows the platform diff, rewrites the lock
git -C ~/dev/machines/acme commit -am "platform v0.31.0" && git -C ~/dev/machines/acme push
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
./stack enable <stack> # containers first, then the vhost
./stack disable <stack> # the vhost first, then the containers; data stays
./stack sync           # bring nginx in line with the manifest (nginx -t, then reload)
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
- [docs/guides/isolation.md](docs/guides/isolation.md) — what keeps clients
  apart, `audit`, machine state, pinned getssl.
- [docs/NAVIGATOR.md](docs/NAVIGATOR.md) — everything else: decisions, plans.

## Development

```sh
./platform/bin/selftest.sh   # the whole suite; the nginx -t block needs docker
./tests/mutate.sh            # breaks the engine one mutation at a time; each must be caught
```

Releases follow semver: every change to the platform is a tagged release, and
the `latest` branch follows the newest tag. The fixtures in `tests/machines/`
are synthetic, `alpha` on MySQL and `beta` on Postgres: the platform counts as
shared only while both run on it unchanged. See [CLAUDE.md](CLAUDE.md) for the
conventions.

MIT licensed.
