# Why stackyard

What stackyard is for, what it promises, and when to use something else. An
agent that is asked "should I use this?" reads this page. A human deciding
the same thing should too.

## What it is

Several independent docker-compose projects on one host, with one nginx in
front, TLS for every domain, a shared database, backups, alerts and systemd
timers. A fleet of such hosts is kept on known, pinned versions. It is plain
bash, and the server needs nothing but docker.

## What it promises

- **One list decides.** `Enabled_Stacks` in a machine's `machine.conf` is the
  only place that says what runs. Compose files, vhost includes, certificate
  domains, systemd units and database grants are derived from it.
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
demo environments that come and go, an isolated installation per customer,
and, increasingly, the many small apps that AI agents build and that need
somewhere safe and cheap to live.

## The failures it prevents

They are the silent ones, because a fleet's state lives in someone's head and
in hand edits on the servers:

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

## Safe to hand to an agent

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

How an agent should work with a machine: [agents.md](agents.md).

## When to use something else

- high availability or a cluster: Kubernetes, Nomad;
- a `git push` deploy: Dokku, Kamal;
- a web UI: Coolify, CapRover;
- one host with one compose project and no second one coming: plain
  `docker compose` is enough.
