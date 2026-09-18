# What is left after extracting the platform

Done: the engine is decoupled from machine names and DBMS names, stacks are
looked up in two roots (the "copy" and "link" modes), and both machines pass
`--check` on the shared platform without a single edit in `platform/`.

## A. Secrets that used to be shared — DONE

The ACME account became per-machine (`state/getssl-config/`), `certs.sh`
refuses to run when a key sits in the platform, and `bin/audit-isolation.sh`
catches reuse of a bucket, a GPG recipient, a chat, a token, and of any
password by value.

What is left in this area:

- **Backup and notifications are not ported at all**, so the checks for their
  keys run idle today — there is nothing to catch. When `backup.sh` and
  `notify.sh` arrive, the checks will already be in place, and that is the
  right order: a check written after an incident is written from the traces of
  one case.
- **In devbox6 `account.key` is still in git.** The fix belongs there, not
  here: untrack plus, properly, rotating the account itself — the key is in the
  history.

An honest caveat worth writing into the product promise: domains are public
anyway through Certificate Transparency at certificate issue time. What
isolation achieves is "client A's machine holds no inventory of client B", not
"domains are secret".

## B. Platform assumptions that get in the way of distributing it

- **`dnf`/`rpm`** in `host-setup.sh`. Either declare support for the RHEL
  family honestly, or move the package step outside the platform's boundary.
  Pretending to be cross-platform costs more than declaring.
- **The container name `nginx`** is hardcoded in nine places in
  `stack.sh`/`systemd.sh`. Harmless inside one machine; when distributed, an
  assumption nobody warned about.
- **Language — DONE.** The engine and the documentation were entirely in
  Russian. They are now entirely in English, and every text is self-contained:
  reading this repository alone is enough, with no references to any earlier
  project.

## C. Porting from devbox-asstnt

**Done:** `backup.sh`, `check-backups.sh`, `backup-restore.sh`, `notify.sh`,
`watch-host.sh` and the `devbox-*` units. Knowledge of a specific DBMS was
moved into the provider hook `scripts/backup-dump.sh` (contract: check / list /
dump / globals / ext / detect / inspect / restore), with implementations for
MySQL and Postgres.

Verified without docker: the hook contract answers, `detect` distinguishes
formats by file magic, and the platform contains not one mention of `pg_dump`
or `mysqldump`. **Not verified on a live machine** — neither a dump nor a
restore has ever been run. Until the first successful `backup-restore.sh` on
real data, this cannot be counted as a working backup: a backup that has never
been restored is an assumption, not a backup.

**`selftest.sh` was moved and rewritten.** 14 sections, three of them new or
completely reworked:

- "databases at the provider" exercises the role with a FICTIONAL prefix
  `Zulu`. If the test passes with it, no hardcoded name of any real DBMS is
  left in the engine — which is exactly the property the decoupling was done
  for;
- "profile and fixture layout" runs the engine against
  `tests/machines/{alpha,beta}`: it compares `Domains` with `server_name`,
  requires an explicit `Containers="no"` on stacks without compose, and catches
  a database order with no enabled provider;
- ".gitignore" checks that fixture secrets and `.stackyard/` are closed, that
  the examples are open, and that there is not one secret in `platform/` or
  `profiles/`.

It was verified that the test CATCHES a regression: replacing
`stacks_db_prefix` with a constant gives 8 failures instead of "everything
checks out".

**`htpasswd.sh` and `registry.sh` were moved.** The first one's file name
became an argument: a machine has more than one vhost with authentication, and
a shared file would mean that access to one site opens the others too. The
second was taken whole — there is nothing in it to split: it exits immediately
when the enabled stacks have no external registries, and `--soft` keeps it from
failing a compose command. The `[ -x registry.sh ]` guard was removed from the
hook: the file is always present in the platform, and the guard would have
silently swallowed its disappearance.

## Audit by an independent agent

Performed after the port; it found ~30 defects, a quarter of them silent data
loss. Fixed as of today:

- **A1** — a profile stack's `Backup_*` did not exist for anyone, and the
  backup and its check were blind CONSISTENTLY;
- **A2** — any gzip was detected as SQLite, i.e. a MySQL dump could not be
  restored by its own tool;
- **A3** — `Mysql_Dump`/`Postgres_Dump` did not work: the generator wrote
  `dump`, the initializers read `dump_file`;
- **A8**, **A14**, **C2**, **C4** — see the commits.

Also fixed: **A5/B1/B2** (a fresh machine did not come up) and **A4**
(certificate placeholders were not created for profile stacks). Verified by an
end-to-end run of a fresh machine with real dhparam generation.

One claim in the report was **not confirmed**: `./stack sync` does not "hang
with no indication" — `note` is printed before `openssl`, and openssl itself
emits progress dots. The terminal is not silent.

Also fixed: **A9/A6/A7** — three lying or dead checks.

Left from the report, in order: ~~A9~~ **A15** (`00-limits.conf` carried over
from devbox6 into the platform — the zones are not the ones asstnt and ledger
use, so porting such a machine gives `unknown limit_conn_zone` and a crash
loop), **A16** (lost `http2 on`), **A10-A13** and block **B**.

**C5 and C6 are fixed.** The `# shellcheck source=` directives were brought to
the repository-root form — shellcheck resolves them from the working directory,
not from the file being checked, so the `../lib/...` form looked correct and
silently failed to resolve. SC1091 is an info-level message, so with `-S error`
it is not visible at all: `-x` was enabled while every script was linted in
isolation. `shellcheck -x` now works without `-P`.

The selftest sets its fixtures up itself, in a temporary copy, from the
examples — previously their `.env` files were not in git, so on a fresh clone
the block skipped itself, which is indistinguishable from "checked". An
assertion that the fixture is non-empty was added: without it the checks
compared empty with empty and passed.

**Deliberately not done:** once `-x` started working, shellcheck showed about a
dozen more warning-level messages (SC2155, SC2046, SC2010, SC1007, SC2209,
SC2221/2222). They were not addressed — that is separate work, and it is worth
doing in one pass rather than in passing.

**Left from the port:** `memory.sh`.

**For migrating machines:** the dump prefix in S3 is now derived from the
provider stack's name (`pg`, `mysql`), whereas it used to be the constant
`postgres`. A machine that already writes to a bucket needs
`Backup_DB_Prefix=postgres` in `.env-backup` — otherwise new dumps go
elsewhere, and `check-backups.sh` will report "no backups" while the backup is
healthy.

## D. The mechanism that delivers the platform to a machine

Today `machines/*/platform` and `machines/*/profile` are symlinks: this is the
workspace, and a symlink guarantees that both machines run byte-for-byte the
same thing. On a real machine that must be a **vendored copy with a pinned
version**, not a symlink and not a submodule: a client repository must be
self-contained (one `clone`, with no access to a second repository).

What is missing for that: a version file, an update command with a visible
diff, and a check in `--check` that the local platform does not diverge from
the declared version. A platform that has silently diverged looks healthy.

## E. Small things found by the extraction

- `stacks/tokensale/compose.yaml` (the asstnt machine) — `MARIADB_ROOT_PASSWORD`
  in plain text, against the rule "secrets only in `.env`".
- `.env-backup.example` there refers to `env/gpg/...` — the path lagged behind
  the move to `platform/`.
- Both machines still carry commented-out blocks of earlier service variants.
