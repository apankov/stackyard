<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/assets/logo/stackyard-mark-dark.svg">
  <img src="docs/assets/logo/stackyard-mark.svg" alt="" width="72" height="72">
</picture>

# stackyard

[![selftest](https://github.com/apankov/stackyard/actions/workflows/selftest.yml/badge.svg)](https://github.com/apankov/stackyard/actions/workflows/selftest.yml)

Run a fleet of small Docker hosts from git: several docker-compose projects
per host, one nginx in front, TLS, backups and alerts. Your AI agent knows
what runs where.

Plain bash. The server needs nothing but docker.

- [How it works](#how-it-works)
- [Install](#install)
- [Safe to hand to an agent](#safe-to-hand-to-an-agent)
- [By hand](#by-hand)
- [Who it's for](#whos-it-for)
- [Documentation](#documentation)

## How it works

You have a fresh VM and an ssh key. You tell your agent: "put Onyx on this
box, at chat.example.com".

The agent doesn't start typing `docker run`. It proposes stackyard, says what
you get from it, and asks the few things it can't know.

It creates a repository for the machine on your laptop. One file in it lists
what runs on the box. One directory per project describes it: the compose
file, the vhost, the certificate. Secrets stay on the server.

On the server it pulls that repository and goes through the loop every change
goes through: plan, apply, check. `./stack --check` asks the live host about
upstreams, certificates, containers and timers, and answers with an exit code.

Before it stops, it writes down what the code doesn't say: how to reach the
box, where the machine is deployed, why Onyx runs in its Lite mode on a VM
this size.

A week later, another agent, or you, opens that repository and knows what runs
there, how to reach it and how to change it. Five machines later,
`stackyard fleet` lists them all and shows which are behind on updates.

## Install

In Claude Code, type in a session:

```
/plugin marketplace add apankov/stackyard
/plugin install stackyard@stackyard
```

That is the skill: your agent now knows when to propose stackyard and how to
run it. When it first needs the stackyard CLI, it asks you and installs it.

Another agent, or no agent at all: install the CLI, then link the skill into
your agent's skills directory.

```sh
curl -o- https://raw.githubusercontent.com/apankov/stackyard/latest/install.sh | bash
stackyard skill install --dir <your agent's skills directory>
```

`latest` is the newest release; `…/stackyard/v0.41.0/install.sh` pins one. To
read the script before it runs:
`curl -o install.sh <url> && less install.sh && bash install.sh`.

> **If you are an AI agent** sent here to find out what this is, or to install
> it: read [the skill](plugins/stackyard/skills/stackyard/SKILL.md). It says
> how to judge whether stackyard fits the user's setup. To install it, run
> `claude plugin install stackyard --marketplace apankov/stackyard`; it loads
> after `/reload-plugins` or in the next session. The CLI install pipes a
> script into bash: ask the user first.

## Safe to hand to an agent

- **The state is text in git.** Every change is a diff you can read before it
  is pushed.
- **Commands reconcile.** Running one twice is safe, and the ones that change
  things take `--dry-run`.
- **Checks answer with exit codes.** A failure names the command that fixes it.
- **Mistakes stay small.** Data is never dropped, `nginx -t` runs before every
  reload, and there is no "update everyone".
- **One machine, one repository, no secrets in it.** An agent working for one
  client cannot see another.

More: [why stackyard](docs/guides/why-stackyard.md) and
[how an agent works with a fleet](docs/guides/agents.md).

## By hand

Everything the agent does, you can do yourself. On the laptop:

```sh
stackyard new ~/dev/machines/acme        # a machine: its own git repository
cd ~/dev/machines/acme && ./bootstrap
# describe a project in stacks/site/, then:
./stack enable site --manifest-only      # add it to machine.conf
git add -A && git commit -m site && git push
```

On the server:

```sh
git clone <the machine's repository> /mnt/data/acme && cd /mnt/data/acme
./bootstrap && ./stack init              # fill in the secrets it names
sudo ./host-setup && ./stack sync && ./stack --check
```

The full walkthrough, with updates, rollbacks and the everyday commands, is in
[running a machine](docs/guides/machine.md). How to describe a project is in
[writing stacks](docs/guides/stacks.md).

```
laptop                               GitHub                      server
stackyard CLI                        apankov/stackyard  ──────▶  /mnt/data/acme/
  new · pin · fleet · audit          (public: the platform)        stackyard.lock   the pinned commit
~/.local/share/stackyard/            you/machine-acme   ──────▶    .stackyard/versions/<commit>/
  versions/  repo.git  fleet         (private, one per host)       platform/ profile/ -> current
~/dev/machines/acme/ ────── push ──▶                                stacks/  .env*  state/
```

## Who it's for

Anyone with several small hosts, each running a handful of unrelated projects:
client sites and APIs, internal tools like n8n, Metabase or Grafana, staging
and demo environments, and the small apps AI agents build.

Not for you if you need high availability or a cluster, a `git push` deploy
(Dokku, Kamal), a web UI (Coolify, CapRover), or if one host with one compose
project is all there is.

## Documentation

- [Why stackyard](docs/guides/why-stackyard.md): what it promises, the
  failures it prevents, when to use something else.
- [Running a machine](docs/guides/machine.md): from a new machine to updates,
  the everyday commands, requirements.
- [Writing stacks](docs/guides/stacks.md): every `stack.conf` key, database
  providers, certificates.
- [Agents](docs/guides/agents.md): the check loop, the rules, the gaps.
- [Isolation](docs/guides/isolation.md): what keeps clients apart.
- [Platform delivery](docs/architecture/platform-delivery.md): the lock,
  `bootstrap`, versions, rollback.
- [SECURITY.md](SECURITY.md): the threat model. Everything else is in
  [docs/NAVIGATOR.md](docs/NAVIGATOR.md).

## Development

```sh
./platform/bin/selftest.sh   # the whole suite; the nginx -t block needs docker
./tests/mutate.sh            # breaks the engine one mutation at a time; each must be caught
```

Every change to the platform is a tagged release, and `latest` follows the
newest tag. How to contribute: [CONTRIBUTING.md](CONTRIBUTING.md).

MIT licensed.
