# Changelog

What changed for the people who run stackyard, newest first. Versions are the
platform's (`platform/VERSION`); each is a git tag, and a machine pins one by
its commit in `stackyard.lock`. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); until 1.0 a minor
version may break things, and when it does the entry says what to do.

Releases before 0.27.0 are recorded only in the tags and the git history.

## [0.34.2] — 2026-09-29

### Fixed
- `systemd.sh` looks for the backup GPG key where `backup.sh` does
  (`gpg/backup-pubkey.asc` unless `Backup_GPG_Pubkey` says otherwise). It used
  to default to `platform/gpg/`, skip backups "for want of a key" on a machine
  that had one, and leave the old units in place.
- No `.env-backup` removes installed backup units, since a timer for a backup
  nobody configured can only fail. An `.env-backup` that exists but cannot work
  (no bucket, no key, no aws) is an error: the run exits non-zero after
  installing everything else, and the installed backup units are left as they
  are rather than taken away quietly.

### Added
- `./platform/bin/systemd.sh --check` compares every installed unit with what it
  would install, flags an `ExecStart` that runs a missing file, and warns about
  a `devbox-*` or `getssl-*` unit this version does not install. It needs
  neither root nor systemd, and `host-setup --check` runs it: an enabled timer
  pointing at a script an update removed no longer passes as healthy.

## [0.34.1] — 2026-09-29

### Fixed
- `stackyard pin` ends by saying which steps run on the laptop (`./bootstrap`
  there, commit, push) and which on the server (`git pull && ./bootstrap &&
  ./stack sync`); it used to put the commit on the server.
- A new machine's `machine.conf` explains how the manifest is changed on the
  laptop and applied with `sync`, and no longer claims the stacks run in the
  order listed.

### Changed
- The `latest` branch also moves on pushes to `master` and by hand: GitHub
  creates no tag events when more than three tags arrive in one push.

## [0.34.0] — 2026-09-29

### Added
- `./stack sync` applies `machine.conf`: it starts what the manifest lists and
  is not running, runs the database provider's initializer when the orders
  changed, rebuilds the vhost includes, starts nginx last on a fresh machine
  and installs missing units. It never edits the manifest, and refuses — before
  changing anything — when a stack's dependency or `.env` is missing. A stack
  that left the manifest but still runs is reported with the command that
  stops it, not stopped.
- `./stack enable|disable <stack> --manifest-only` edits `machine.conf` with the
  dependency logic and touches nothing else: run it on the laptop, after
  `./bootstrap` there.
- `./stack --check` warns when the host's `machine.conf` differs from the last
  commit.

### Changed
- `enable` follows `Requires` transitively, not one level deep.

## [0.33.0] — 2026-09-29

### Changed — breaking
- The manifest is `machine.conf`, committed with the machine, instead of the
  untracked `.env-stacks`. Without it nothing counts as enabled (it used to be
  every stack with a complete file set), and `enable`, `disable`, `purge` and
  `sync` refuse to run. `./stack init` no longer creates the manifest.

  **Before pinning a machine to 0.33.0 or later:** in its repository,
  `git mv .env-stacks.example machine.conf`, set its `Enabled_Stacks` to what
  the server's `.env-stacks` says, drop `.env-stacks` and `!.env-stacks.example`
  from `.gitignore`, and commit.

## [0.32.0] — 2026-09-29

### Added
- `stackyard new` initialises the machine's git repository (not when created
  inside another repository; a warning when git is missing).

## [0.31.0] — 2026-09-29

### Added
- `./stack list --json` and `./stack --check --json`: one JSON object on
  stdout, the report on stderr, the exit code unchanged. Built without jq.

## [0.30.2] — 2026-09-29

### Fixed
- Lookups (`stack_dir`, `stack_exists`, `stack_is_enabled`, the DB provider)
  no longer close a pipe while its producer is still writing. Where SIGPIPE is
  ignored — every systemd unit — that printed "write error: Broken pipe" into
  the output of timers and checks.

## [0.30.1] — 2026-09-28

### Fixed
- A timestamp without an offset is read as UTC on GNU date too, as on BSD:
  `check-backups.sh` computed backup ages off by the machine's time zone on
  Linux hosts not running in UTC.

### Added
- The `latest` branch, moved onto each release:
  `curl -o- https://raw.githubusercontent.com/apankov/stackyard/latest/install.sh | bash`.

## [0.30.0] — 2026-09-28

### Added
- The fleet list takes `machines_dir=<dir>` lines: every machine under that
  directory, found on each run. `stackyard fleet add`, `add-dir` and `list`
  keep the list.

## [0.29.0] — 2026-09-28

### Changed
- The operator CLI keeps everything in `~/.local/share/stackyard/` (or under
  `$XDG_DATA_HOME`): installed versions, the repository mirror and the fleet
  list. A `~/.stackyard-fleet` is still read, with a note, and the first
  `stackyard fleet add` carries it over.

## [0.28.0] — 2026-09-28

### Added
- `install.sh` and the `stackyard` command for the operator's laptop: `new`,
  `pin`, `fleet`, `audit`, `vendor`, `version`, `versions`, `install`.
  Versions install side by side; the tag is resolved to a commit and printed,
  and that commit is what `new` and `pin` write into a lock.

## [0.27.0] — 2026-09-28

### Added
- `./stack init [<stack>...]` creates the missing `.env` files from their
  examples with mode 600, never overwrites one, follows `Requires`, and exits
  non-zero while any value is still `CHANGE_ME`.

[0.34.2]: https://github.com/apankov/stackyard/compare/v0.34.1...v0.34.2
[0.34.1]: https://github.com/apankov/stackyard/compare/v0.34.0...v0.34.1
[0.34.0]: https://github.com/apankov/stackyard/compare/v0.33.0...v0.34.0
[0.33.0]: https://github.com/apankov/stackyard/compare/v0.32.0...v0.33.0
[0.32.0]: https://github.com/apankov/stackyard/compare/v0.31.0...v0.32.0
[0.31.0]: https://github.com/apankov/stackyard/compare/v0.30.2...v0.31.0
[0.30.2]: https://github.com/apankov/stackyard/compare/v0.30.1...v0.30.2
[0.30.1]: https://github.com/apankov/stackyard/compare/v0.30.0...v0.30.1
[0.30.0]: https://github.com/apankov/stackyard/compare/v0.29.0...v0.30.0
[0.29.0]: https://github.com/apankov/stackyard/compare/v0.28.0...v0.29.0
[0.28.0]: https://github.com/apankov/stackyard/compare/v0.27.0...v0.28.0
[0.27.0]: https://github.com/apankov/stackyard/compare/v0.26.0...v0.27.0
