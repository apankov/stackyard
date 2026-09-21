# Distribution: an installer, an operator CLI, and fewer remembered steps

Written 2026-09-21, from a discussion that ended without code. Nothing here is
implemented. The question was: could stackyard be installed the way nvm is —
`curl -o- https://raw.githubusercontent.com/apankov/stackyard/v0.18.0/install.sh | bash` —
and if so, for which part.

The answer is yes for exactly one of the three things that question conflates.
They are listed separately below because the wrong one is the tempting one.

## 1. The platform onto a machine — leave it alone

Today: `stackyard.lock` committed in the machine's git plus `./bootstrap`.

A `curl | bash` here would be a step backwards. The version would stop being
recorded in the machine's repository and would start depending on what the
operator downloaded last; "which version is this client on" would go back to
being answered by comparing contents rather than reading one line. That is the
property ADR 0001 exists to protect, and the reason vendoring was rejected.

No change. `bootstrap` stays as it is.

## 2. The operator's tools on a laptop — this is the nvm-shaped part

`bin/new-machine.sh`, `pin.sh`, `fleet.sh`, `audit-isolation.sh` and
`vendor.sh` currently require "first clone stackyard somewhere and remember
where". That is precisely the class of problem an installer solves.

Proposed:

```sh
curl -o- https://raw.githubusercontent.com/apankov/stackyard/v0.18.0/install.sh | bash
```

installs `~/.stackyard/versions/v0.18.0/` and a shim `~/.local/bin/stackyard`:

```sh
stackyard new ~/dev/machines/acme     # today: ./bin/new-machine.sh
stackyard pin ~/dev/machines/acme
stackyard fleet
stackyard audit ~/dev/machines/*
stackyard version
stackyard install v0.19.0             # self-update, side by side
```

Requirements, without which the installer breaks what already works:

- **The tag in the URL is resolved to a commit**, and `stackyard new` writes
  that commit into the new machine's `stackyard.lock`. The existing contract —
  a tag only makes cloning cheap, the commit is the truth — must not leak.
- **Several versions side by side** (`versions/vX`), switched by a symlink. A
  single overwritten install would mean `stackyard new` generating a skeleton
  from a newer platform than the machine it is for.
- `STACKYARD_VERSION`, `STACKYARD_DIR`, `--no-modify-path`; idempotent; no
  dependencies beyond `git`, `curl`, `tar`.
- A vanity URL (`stackyard.example.com/install.sh`) is acceptable only as a
  redirect to a concrete tag, and the script must print what it resolved to. A
  floating URL that stays silent about its version is the same silent drift the
  fleet commands exist to catch.
- The README must carry the honest caveat that `curl | bash` cannot be
  inspected before it runs, together with the two-step form:
  `curl -o install.sh …; less install.sh; bash install.sh`.

Note that no installer is needed on a server: there it is `git clone` of the
machine's repository plus `./bootstrap`.

## 3. "Fewer steps to remember" — not a delivery problem

The steps that actually irritate during a deployment are on the server:

```sh
cp .env.example .env && chmod 600 .env
cp profile/stacks/<s>/.env.example stacks/<s>/.env      # once per stack
```

An installer does not remove those. A platform command does:

```sh
./stack init    # create the missing .env files from their examples (machine
                # and profile stacks alike), chmod 600, print what still needs
                # filling in, exit non-zero while anything does
```

Half of it exists already: `host-setup` catches `CHANGE_ME` and unfilled
secrets, and `stack list` reports `missing: stacks/x/.env`. What is missing is
the step that creates them and says what to fill.

## Order of work

1. **`./stack init`** — cheapest, removes the most manual work (roughly 40
   lines in `stack.sh` plus a selftest guard). It pays for itself on the
   devbox6 migration, where the profile stacks' `.env` files are currently
   created by hand from a list in the runbook.
2. **`install.sh` + the `stackyard` CLI** — gives "distributed like everything
   else" without touching how machines receive the platform.
3. **`bootstrap`** — do not touch.

## Where things stood when this was written

- stackyard `master` at v0.18.0 (`48b94df`), **not pushed**. Contains the full
  Russian-to-English translation of the repository and the `bootstrap.local`
  hook.
- The machine repository being migrated is on branch `stackyard-migration`
  (a worktree under `.worktrees/`), pinned to v0.18.0, **not pushed**. Its
  server-side steps are in that repository's
  `docs/devel/plans/stackyard-migration.md`.
- Because the machine's lock already points at `48b94df`, stackyard has to be
  pushed (and tagged) before that machine can `./bootstrap`.
