# Working with a fleet as an AI agent

stackyard was not written for agents, but it was written so that nobody has to
guess: the state is text, the commands reconcile, and every check answers with
an exit code. That makes it a good ground for an agent that deploys, monitors
and maintains a fleet of small hosts. This page is how an agent should work
with it, and what is still missing.

## The model

Two places, never mixed up:

| Where | Repository | What an agent does there |
|---|---|---|
| the laptop | a machine's private repository, and the `stackyard` CLI | edits stacks and the manifest, pins versions, reads the fleet, audits isolation; commits and pushes |
| the server | a clone of the same repository | `git pull`, `./bootstrap`, the `./stack` verbs, checks |

The machine's repository is the whole truth about the machine: which stacks run
(`.env-stacks`), what each one is (`stacks/*/stack.conf`) and which platform it
runs on (`stackyard.lock`). Secrets are not in it: `.env` files exist only on
the server. An agent session scoped to one machine's repository therefore
cannot see another client's composition or secrets, which is the least
privilege it should have.

## The loop: plan, apply, check

Every change is the same three steps, and each step has an exit code.

```sh
./stack enable site --dry-run   # the plan: prints every command, changes nothing
./stack enable site             # apply
./stack --check                 # exit 1 on any problem, one line per finding
```

The checks, and what their exit code means:

| Command | Non-zero means |
|---|---|
| `./stack --check` | a declaration, domain, database, upstream, vhost, mount or unit is wrong |
| `./stack init` | a `.env` is missing or a value is still `CHANGE_ME` |
| `sudo ./host-setup --check` | the host is not ready: packages, placeholders, timers, secrets |
| `./platform/bin/check-certs.sh` | a certificate this machine issues needs attention: missing, a placeholder, or near expiry |
| `stackyard audit` | two machines share a secret, bucket, network or key |

Findings are lines starting with `[ok]`, `[!]` (warning) or `[FAIL]`, and a
failure usually names the command that fixes it (`./stack init site creates
it`, `stackyard fleet add-dir …`). Follow those rather than improvising.

## Typical tasks

**Deploy a new project on an existing machine.** Add `stacks/<name>/` in the
machine's repository (see [stacks.md](stacks.md)), push, then on the server:
`git pull`, `./stack init <name>`, have a human fill in what it names, rerun
`init` until it exits 0, `./stack enable <name>`, `./stack --check`.

**Take a project off.** `./stack disable <name>`: the units and the vhost go before
the containers; volumes, images and data stay. Only `purge` removes volumes and
images, and it asks for the stack's name on a terminal on purpose.

**Update the platform on one machine.** On the laptop, `stackyard pin
<machine>` and read the diff it prints before committing. On the server,
`git pull && ./bootstrap && ./stack sync && ./stack --check`. A rollback is
`stackyard pin <machine> --version <tag>`.

**Sweep the fleet.** `stackyard fleet` (who is behind), `stackyard audit`
(isolation), and `./stack --check` on each machine.

## Rules

- **Change machines one at a time.** There is no "update everyone" on purpose;
  do not build one out of a loop.
- **Never edit `platform/` or `profile/` on a machine.** They are replaced on the
  next `./bootstrap`. A local change to a profile stack means copying the whole
  stack into `stacks/`.
- **Never write into `state/` by hand.** It is generated; `./stack sync`
  regenerates it.
- **Never `source` a `.env`,** and never put a secret into git, a commit message
  or a log. Secrets are for a human to enter where `init` says.
- **Only `./dc` runs `docker compose`.** A bare `docker compose` misses the env
  files, the generated files and the project name.
- **Do not bypass a refusal.** `disable` refusing a dependency, `bootstrap`
  refusing an unknown commit, `sync` rolling back an include that fails `nginx -t`: each one
  is the platform stopping an outage.
- **Do not move the `latest` branch or tags by hand.** Machines pin commits; the
  CLI may follow `latest`, which a workflow moves.

## What is missing

Honest gaps, in the order they would help most:

1. **Machine-readable output.** `list`, `--check`, `fleet` and `audit` print
   text lines. They parse, but a `--json` would make them a contract.
2. **Per-machine agent instructions.** `stackyard new` could write an
   `AGENTS.md` into each machine: what this machine is, what may be changed
   there, how to verify a change.
3. **Remote runs.** An agent has to know how to reach each server itself; a
   `stackyard run <machine> -- ./stack --check` over ssh, with the address kept
   in the machine's repository, would close that.
4. **Non-interactive purge.** The confirmation should stay, in a form an agent
   passes deliberately, such as `--confirm <stack>`.
5. **Secrets.** `init` names what is unfilled, and a human fills it. Generating
   the values nothing outside depends on (a database password the provider
   creates anyway) would remove most of that.
6. **An MCP server** over the same commands, once the output is structured.
