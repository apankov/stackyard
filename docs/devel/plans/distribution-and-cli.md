# Distribution: an installer, an operator CLI, and fewer remembered steps

Written 2026-09-21, from a discussion that ended without code; status updated
2026-09-28. Section 3 is implemented (v0.27.0), section 4 was solved another
way (v0.24.0), section 2 is still open. The question was: could stackyard be
installed the way nvm is —
`curl -o- https://raw.githubusercontent.com/apankov/stackyard/v0.18.0/install.sh | bash` —
and if so, for which part.

The answer is yes for exactly one of the three things that question conflates.
They are listed separately below because the wrong one is the tempting one.

## 0. Terminology (proposed, 2026-09-28)

"stackyard" has been used for at least three different things: the
repository, the code running on a machine, and the operator's tools. They are
one tree at one commit put to different uses, and the plan below cannot be
discussed without telling them apart. The closest model is rustup/cargo: one
manager on the laptop, toolchains installed side by side, a file in each
project pinning which one it gets.

| Term | What it is | Where it lives | rustup analogue |
|---|---|---|---|
| **stackyard** | the product and its repository | `apankov/stackyard` | rust-lang/rust |
| **release** | a tag, resolved to the commit it points at; the commit is the truth | git tags | a release channel's version |
| **installed version** | one release unpacked into a directory named by its commit | `versions/<commit>/` in a version store | a toolchain |
| **version store** | the directory holding installed versions and the `current`/`previous` links | `<machine>/.stackyard/` on a server, `~/.stackyard/` on a laptop | `~/.rustup/toolchains/` |
| **platform** | the engine: `platform/` inside an installed version. Knows no machine, no DBMS, no secret | `platform -> .stackyard/current/platform` | rustc + std |
| **profile** | the library of reusable stacks, versioned apart from the platform (`profiles/VERSION`) but shipped in the same release | `profile -> .stackyard/current/profiles` | — |
| **machine** | a private repository describing one host: its stacks, manifest, secrets, pin | its own git repository | a cargo project |
| **pin** | `stackyard.lock`: the commit a machine runs | the machine's repository | `rust-toolchain.toml` |
| **bootstrap** | installs the pinned release into the machine's version store and switches `current` | the machine root | `rustup toolchain install` |
| **machine commands** | `./stack`, `./dc`, `./certs`…: generated wrappers that run the current platform | the machine root | the `cargo` proxy picking the pinned toolchain |
| **operator CLI** | `stackyard`: the tools that act across machines (`new`, `pin`, `fleet`, `audit`, `vendor`) plus managing its own installed versions | `~/.local/bin/stackyard` | `rustup` |

What this settles:

- **"platform" means the engine only**, never the product. "Update the
  platform on a machine" is correct; "install stackyard on the laptop" means
  the operator CLI.
- **The two version stores have one layout on purpose.** A laptop's
  `~/.stackyard/versions/<commit>/` and a machine's `.stackyard/versions/<commit>/`
  hold the same release tree; only the entry points used differ.
- **The operator CLI should dispatch like rustup.** Run inside a machine's
  directory, `stackyard` reads that machine's pin and runs the tools of that
  installed version, fetching it if needed. That gives section 2's "several
  versions side by side" for free, and `stackyard new --version vX` becomes the
  same mechanism rather than a special case.
- **Nothing is renamed on disk.** `platform/`, `profiles/`, `.stackyard/`,
  `stackyard.lock` and the machine commands stay: machines depend on those
  paths, and the vocabulary is what was ambiguous, not the layout.

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

**Done in v0.27.0** as `./stack init [<stack>...]`. It follows `Requires`, so
`./stack init site` before `./stack enable site` also sets up the database it
needs, and it never overwrites an existing file.

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

## 4. A third remembered step, found while migrating a machine

**Solved in v0.24.0 (`265ea4c`), and not the way sketched below.** Rather than
teaching `sync` to repair a stale mount, the mount no longer goes stale: every
version lives in `.stackyard/versions/<commit>/`, `bootstrap` switches
`.stackyard/current` with a rename and keeps `previous`, and nginx mounts
`.stackyard` itself and links its directories through `current` at start
(`layer_host_root` in `lib-stacks.sh`, `platform/compose/nginx-entrypoint.sh`).
An update now needs a reload, not a recreate. The one recreate left is a
machine's first move from the flat layout to `versions/`. The sketch is kept
for the record of why:

`./bootstrap` replaces `.stackyard/` wholesale, and nginx bind-mounts
directories through the `platform/` symlink. The container is then left holding
deleted inodes: it keeps serving from the configuration in its memory, and the
next reload leaves it with no server blocks at all. The remedy is
`./dc up -d --force-recreate nginx` — a plain `up -d` does nothing, because the
paths in the spec have not changed and compose compares the spec.

So every platform update ends with a command a person has to remember, and
during one migration it was forgotten twice in an evening.

That work belongs to `./stack sync`, whose stated job is to bring nginx in line
with the manifest — a mount pointing at a deleted directory is a divergence
from the manifest as much as a missing include is. The shape:

- `sync` probes liveness the way `--check` already does, by asking the
  container rather than `docker inspect`;
- if the directories are dead AND the upstreams are up, it recreates nginx
  itself and says why;
- if they are dead while an upstream is down, it refuses and names the
  upstream: recreating at that moment is exactly how every vhost on the machine
  goes down;
- `bootstrap` stays as it is. It must not restart anything on a running machine
  without being asked; printing the warning is its job.

## Order of work

1. ~~**`./stack init`**~~ — done, v0.27.0.
2. ~~**Recreation inside `sync`**~~ — made unnecessary by the versioned layout,
   v0.24.0 (section 4).
3. **`install.sh` + the `stackyard` CLI** — gives "distributed like everything
   else" without touching how machines receive the platform. Next.
4. **`bootstrap`** — do not touch its contract. (Its layout did change in
   v0.24.0; what it records and how a machine pins it did not.)

## Where things stand (2026-09-28)

- stackyard `master` at v0.27.0. The first machine was migrated on 2026-09-27
  and receives updates through `bin/pin.sh`; the blockers listed here on
  2026-09-21 (stackyard not pushed, the machine's lock pointing at an
  unpublished commit) are gone.
