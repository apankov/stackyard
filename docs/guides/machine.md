# Running a machine

The whole life of one machine, by hand: creating it, the first deploy,
changing what runs, updating, and the commands for every day. An agent with
the skill does the same steps; this page is what it follows.

## How it fits together

| Layer | What it is | Where it lives |
|---|---|---|
| `platform/` | the engine: stacks, dependencies, nginx, TLS, backups, systemd. Knows no machine, no DBMS, no secret | the stackyard repository |
| `profiles/` | reusable stacks: `mysql`, `pg`, `redis`, `php-fpm` | the stackyard repository |
| machine | its own stacks, `.env` files, generated state | a private repository per host |

## Once, on the laptop

```sh
curl -o- https://raw.githubusercontent.com/apankov/stackyard/latest/install.sh | bash
stackyard fleet add-dir ~/dev/machines     # every machine created there is in the fleet
```

`latest` is the newest release; `…/stackyard/<tag>/install.sh` pins one. The
script prints the tag and commit it installed and keeps everything in
`~/.local/share/stackyard/`. A pipe into bash cannot be read first; to read it:
`curl -o install.sh <url> && less install.sh && bash install.sh`.

## A new machine

```sh
stackyard new ~/dev/machines/acme          # skeleton, pinned to the CLI's commit; a git repository
cd ~/dev/machines/acme
./bootstrap                                # the pinned platform here too, for ./stack on the laptop
$EDITOR .env.example                       # paths, network (no secrets: this is committed)
# describe your own stacks in stacks/, then list what runs:
./stack enable site --manifest-only        # writes machine.conf: site, and mysql and php-fpm it requires
git add -A && git commit -m acme && git push   # to a private repository
```

How to describe a stack: [stacks.md](stacks.md).

The secrets are never on the laptop: `.env.example` and `machine.conf` are
committed, and the real `.env` files are made on the server.

## The first deploy, on the server

```sh
git clone <the machine's repository> /mnt/data/acme && cd /mnt/data/acme
./bootstrap                        # the platform, at the commit in stackyard.lock
./stack init                       # .env files for what machine.conf lists; rerun until it passes
$EDITOR .env stacks/*/.env         # the secrets, here and only here
sudo ./host-setup                  # packages, placeholder certificates, timers
./stack sync                       # start what machine.conf lists, nginx last
./stack --check
```

## Changing what runs

Changing what runs is a commit: `./stack enable|disable <stack> --manifest-only`
on the laptop (or an edit of `machine.conf`), push, and on the server
`git pull && ./stack sync --dry-run && ./stack sync`. `sync` starts what the
manifest lists and reports, without stopping it, what it no longer lists.

## Updating

```sh
stackyard install latest                   # the CLI itself; older versions stay installed
stackyard pin ~/dev/machines/acme          # shows the platform diff, rewrites the lock
git -C ~/dev/machines/acme commit -am "platform <tag>" && git -C ~/dev/machines/acme push
# on the server: git pull && ./bootstrap && ./stack sync && ./stack --check
stackyard fleet                            # who runs what, and how far behind
```

Rolling back is `stackyard pin <machine> --version <tag>`; to the version the
machine ran just before, `./bootstrap` switches back without a download. The
details: [platform-delivery.md](../architecture/platform-delivery.md).

## Every day, on the server

```sh
./stack list           # what is enabled and what is actually alive
./stack --check        # declarations, domains, databases, upstreams, vhosts, units
./stack sync           # apply machine.conf: start what it lists, rebuild vhosts (nginx -t, then reload),
                       # issue certificates for domains still on a placeholder (--no-issue skips that)
./stack enable <stack> # add to machine.conf and bring up: containers first, then the vhost
./stack disable <stack> # remove from machine.conf: the vhost first, then the containers; data stays
./stack init           # missing .env files from their examples; names what is still CHANGE_ME
./dc <compose args>    # the only path to docker compose
sudo ./host-setup      # packages, certificate placeholders, timers, stack host parts
./certs --issue        # the same issuance by hand; Let's Encrypt is asked only once
                       # http://<name>/.well-known/acme-challenge/ reaches this machine
./memory               # where the memory went: by container, by stack, by role
```

Also on board: `backup.sh` (databases and declared files → GPG → S3, with
`check-backups.sh` watching freshness), `watch-host.sh` and `notify.sh` (disk,
containers and failed units → Telegram), `registry.sh` (logins, and moving
tags pinned to digests), getssl renewals on a timer, and a nightly rotation of
the nginx logs (`Platform_Nginx_Log_Days`, 14 by default) with its own check.

## Requirements

- **Server:** Linux with systemd, docker with the compose plugin, bash ≥ 4.2.
  `host-setup` installs the rest (openssl, gnupg, sqlite, logrotate, …) with
  apt, dnf, yum, apk or zypper.
- **Laptop:** macOS or Linux, git, tar, python3, and bash ≥ 4.2 — on macOS that
  means a Homebrew bash; `/bin/bash` 3.2 is refused.
