# Changelog

What changed for the people who run stackyard, newest first. Versions are the
platform's (`platform/VERSION`); each is a git tag, and a machine pins one by
its commit in `stackyard.lock`. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); until 1.0 a minor
version may break things, and when it does the entry says what to do.

Releases before 0.27.0 are recorded only in the tags and the git history.

## [0.43.0] — 2026-10-26

### Security
- The nginx image is pinned to `nginx:1.30.6-alpine` instead of the floating
  `nginx:1.30-alpine`. 1.30.6 carries the fixes for the October 2026 nginx.org
  advisories (CVE-2026-15176, -93479, -95101, -97629, -97205) and the earlier
  ones, among them the major CVE-2026-42533 in `map` with a regex, which a
  machine's login rate limit typically uses. The floating tag ran whatever a
  machine had last pulled.

  **After pinning:** the spec of nginx changes, so the next `./dc up -d`
  recreates it. Run `./stack --check` first and make sure "Upstreams of the
  enabled vhosts" is clean: nginx resolves every upstream when it starts. A
  machine that sets its own `Platform_Nginx_Image` keeps it; raise it there.

### Added
- `./stack --check` asks the running nginx for its version and fails below
  1.30.6 (stable) or 1.31.7 (mainline), whatever the image tag says.

## [0.42.0] — 2026-10-26

### Security
- The `php-fpm` profile (profiles 0.1.3) sets
  `session.upload_progress.enabled = Off`. CVE-2026-109618 and CVE-2026-109619
  are unauthenticated remote code execution in every PHP since 5.4, exploited
  in the wild since 2026-10-17, and the known full exploit chain runs through
  the upload-progress tracker. The 5.x branch gets no fix, so for this image the
  setting is the remedy.

  **After pinning:** the setting is baked into the image, so the container
  must be rebuilt, not just restarted: `./dc up -d --build php-fpm`. A site
  that shows an upload progress bar fed from `$_SESSION` loses it.

### Added
- `php-fpm` has a `scripts/health.sh`: `./stack --check` asks the running
  container whether upload progress is off and fails while it is on, so a
  correct file behind a container that was never rebuilt does not pass.

### Fixed
- The plugin is fetched from the `latest` branch, so the skill is always a
  released one.

## [0.41.0] — 2026-10-20

### Added
- The repository is a Claude Code plugin marketplace. The skill installs and
  stays updated with
  `claude plugin install stackyard --marketplace apankov/stackyard#latest`.
  `#latest` follows releases, and the plugin's version is the platform's.
- The skill covers someone who has not installed anything yet. Sent to this
  repository with "what is this?", an agent judges whether stackyard fits that
  user's setup, and before installing the CLI it asks, because the install
  pipes a script into bash.

### Changed
- The skill moved to `plugins/stackyard/skills/stackyard/`.
  **If you ran `stackyard skill install`:** run it again after
  `stackyard install`, or the old link points at nothing. In Claude Code,
  prefer the plugin: run `stackyard skill uninstall`, then install the plugin.

## [0.40.0] — 2026-10-20

### Added
- An agent skill, `skills/stackyard/SKILL.md`, and `stackyard skill install`,
  which links it into Claude Code's skills (`--dir` for another agent's;
  `uninstall` and `path` too). An agent then knows when to propose stackyard,
  what to answer about it, where the fleet is, how to deploy and what not to
  touch, without being told or reading the source. The link goes through the
  store's `current`, so the skill follows `stackyard install`. Opt-in: nothing
  is written into an agent's configuration unasked.

### Fixed
- The nginx log rotation no longer forces its first run on a day the logs were
  already rotated by whatever rotated them before. logrotate refused every file
  whose dated name was taken, and the unit failed.

## [0.39.0] — 2026-10-06

### Added
- The platform rotates the nginx logs in `/var/log/nginx` itself. Until now
  `host-setup` installed `logrotate` and no config, so on every machine the
  logs grew without bound. `devbox-nginx-logrotate.timer` runs
  `platform/bin/nginx-logrotate.sh` nightly with a state of its own (not
  through `/etc/logrotate.d`), and `devbox-nginx-logrotate-check.timer` checks
  the result: files left unrotated, generations past the retention, logs named
  outside `<name>-access`, `<name>-error`, `*.log`. The first run forces a
  rotation, so the history a machine already holds comes under the retention
  at once.
- `Platform_Nginx_Log_Days` in the root `.env` sets the retention, 14 days by
  default, 2 at least.
- `systemd.sh` warns when a file in `/etc/logrotate.d` also rotates
  `/var/log/nginx`.

  **A machine that rotates these logs some other way** (a stack of its own, a
  host nginx package): remove that before `sudo ./host-setup` installs the
  platform's, or the logs are rotated twice a night — `./stack disable <stack>`
  first. Set `Platform_Nginx_Log_Days` if it kept something other than 14 days.

## [0.38.0] — 2026-10-06

### Added
- `./stack enable` and `./stack sync` issue real certificates for the enabled
  domains still served with the placeholder, right after the vhost goes live,
  instead of leaving them to the nightly `getssl-renew`. `--no-issue` skips it;
  a failure is a warning, not a failed sync.
- `./certs --issue` does the same by hand. Let's Encrypt is asked only after a
  probe file is fetched through `http://<name>/.well-known/acme-challenge/` for
  every name of the certificate, so a domain whose DNS or port 80 is not ready
  yet costs no rate-limited failed validation. getssl runs from `state/` and as
  the repository's owner, as the timer runs it.

### Fixed
- `./certs` no longer says "no stack declares that domain" for a getssl config
  whose stack is present but not enabled: it names that stack.

## [0.37.0] — 2026-09-30

### Added
- `./stack --check` looks at how every port the enabled vhosts reach through
  `host.docker.internal` is published: on every interface is a warning (open to
  the internet wherever the firewall allows), on `127.0.0.1` only is a failure
  (nginx cannot reach it there), on the docker bridge address is ok.
- `docs/guides/stacks.md` describes proxying to an application in its own
  compose project: through the host on the bridge address (recommended), by
  joining the machine's network, and why nginx does not join the
  application's.

## [0.36.1] — 2026-09-30

### Fixed
- `backup-restore.sh --check` says a file's format was recognised by neither
  the platform nor the provider, instead of calling it "a dump, format:
  unknown": the branch for it came after `db:*` and never matched.

## [0.36.0] — 2026-09-30

### Changed
- `.env`, `.env-backup`, `.env-notify` and `stack.conf` are read the way docker
  compose reads them, so the platform's scripts see the values its containers
  get. Before, quotes were stripped and nothing else: a comment after an
  unquoted value became part of it, blanks around it stayed, `\"` and `\n` in
  double quotes stayed backslashes, `${…}` was expanded inside single quotes,
  and `$VAR`, `${VAR:-default}` and `${VAR-default}` were not expanded at all.
  An `&` in a substituted value is no longer mangled under bash 5.2. The
  selftest compares the two parsers on 29 cases on every run.

  **If a machine's scripts relied on the old reading** (a backup using a
  password written as `Pass=ab$cd`, say), they now get what the container
  always got: quote such values in single quotes.

## [0.35.1] — 2026-09-29

### Fixed
- `check-certs.sh` checks that a certificate is the right one, not only that it
  is fresh: it covers its domain and every alias declared with it, the key
  beside it is its key, and its chain verifies up to a trusted root. Someone
  else's valid certificate, one issued before an alias was added, or a renewal
  that left the old key in place used to read as ok.

## [0.35.0] — 2026-09-29

### Changed
- A name in `machine.conf` that is not a stack on the machine (a typo, or a
  stack whose directory is gone) makes `sync`, `enable`, `disable` and `purge`
  refuse, and `--check` fail. It used to be skipped with a warning most callers
  silenced, so a misspelled site simply dropped out of nginx on the next sync.

## [0.34.6] — 2026-09-29

### Security
- The `mysql`, `php-fpm` and `redis` profiles (profiles 0.1.2) publish their
  ports on `127.0.0.1` only. They were bound to every interface, and Docker's
  rules sit ahead of the host firewall: a database superuser, an
  unauthenticated FastCGI socket and a password-less redis were open to the
  internet wherever a security group allowed it. The selftest no longer lets
  any profile port through with a `public-port-debt` marker.

  **Check before pinning:** anything that reached these ports through the
  host's public address, or from another compose project through
  `host.docker.internal`, stops reaching them. Containers on the machine's
  docker network are unaffected; move such clients onto it.

## [0.34.5] — 2026-09-29

### Fixed
- `notify.sh --resolve` clears an alert's state only after the recovery message
  went out. It cleared it first, so a failed send (Telegram or the network
  down) left no trace that a recovery was owed, and the incident never closed.

### Security
- `stackyard audit` names the key and the machines of a shared secret and no
  longer prints the first 24 characters of its value.

## [0.34.4] — 2026-09-29

### Fixed
- The `pg` profile's initializer (profiles 0.1.1) passes names and passwords to
  `psql` as variables instead of pasting them into SQL, stops on the first
  failed statement, and counts every failure. A password with an apostrophe
  broke `CREATE USER`, and a failed statement still ended in "All databases
  are in sync". A seed that fails half way drops the database it was loaded
  into, so the next run loads it again instead of skipping an empty database.
  Names that are not plain Postgres identifiers are refused.

## [0.34.3] — 2026-09-29

### Fixed
- `backup.sh` refuses to run when a stack's backup sources cannot all be read.
  The sources were read through a process substitution, whose failure bash
  does not pass on: a stack whose second source had an undefined variable was
  backed up with its first source only, and the run reported nothing.
  `check-backups.sh` had the same blind spot and now reports such a stack.
- `check-backups.sh` expects the objects of `Backup_DB` sources, which
  `backup.sh` stores and the check never looked for.
- A failing `globals` hook of the database provider is a failure in both
  scripts; it used to read as "no roles to save", and roles and grants went
  unsaved without a word.
- `check-backups.sh` exits 2 when not one source is expected, instead of
  reporting every (none) source fresh.

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

[0.37.0]: https://github.com/apankov/stackyard/compare/v0.36.1...v0.37.0
[0.36.1]: https://github.com/apankov/stackyard/compare/v0.36.0...v0.36.1
[0.36.0]: https://github.com/apankov/stackyard/compare/v0.35.1...v0.36.0
[0.35.1]: https://github.com/apankov/stackyard/compare/v0.35.0...v0.35.1
[0.35.0]: https://github.com/apankov/stackyard/compare/v0.34.6...v0.35.0
[0.34.6]: https://github.com/apankov/stackyard/compare/v0.34.5...v0.34.6
[0.34.5]: https://github.com/apankov/stackyard/compare/v0.34.4...v0.34.5
[0.34.4]: https://github.com/apankov/stackyard/compare/v0.34.3...v0.34.4
[0.34.3]: https://github.com/apankov/stackyard/compare/v0.34.2...v0.34.3
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
