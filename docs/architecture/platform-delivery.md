# How a machine gets the platform

The platform is **not** in the machine's git. The machine's repository holds
`bootstrap` (one file, plain bash) and `stackyard.lock` with the pinned
version:

```
repo=https://github.com/apankov/stackyard.git
version=v0.30.2
commit=c4bf1ae2d099c1653673c4b2c1d865410ae736a9
```

`./bootstrap` fetches that commit into `.stackyard/`, which is not in git, and
links it in as `platform/` and `profile/`. It is the same mechanic as
`terraform init` or `npm ci`: the repository declares a version rather than
carrying a copy of the code. Why that and not a submodule, a subtree or a
vendored copy is [ADR 0001](decisions/0001-delivery-mechanism.md).

## Pinned by commit

The pin is a **commit**, not a tag and not an archive hash. A tag only names a
commit, and GitHub's automatic archives are not guaranteed byte-stable, while a
commit is immutable. `bootstrap` clones the repository and checks the commit
out; if it is not there (never pushed, or a typo) it refuses rather than
installing something else. "Which version is this client on" is answered by
reading one line.

## Versions side by side

```
.stackyard/versions/<commit>/
.stackyard/current  -> versions/<commit>    what the machine runs
.stackyard/previous -> versions/<commit>    the one before, kept for a rollback
platform -> .stackyard/current/platform
profile  -> .stackyard/current/profiles
```

An update downloads the new version next to the old one and swaps `current`
with a rename; `.stackyard` itself is never replaced, and only `current` and
`previous` are kept. That matters for nginx. A bind mount pins the directory it
was started on, not its path, so an nginx that mounted `platform/nginx-snippets`
was left looking at a deleted directory after every `./bootstrap` and served no
domains until it was recreated. nginx now mounts `.stackyard` and reaches
`/etc/nginx/snippets`, `/etc/nginx/conf.d` and `/etc/nginx/profile-stacks`
through links that follow `current` (`platform/compose/nginx-entrypoint.sh`).
After an update it needs a reload — `./stack sync`, which runs `nginx -t`
first — not a restart.

A machine still on the older flat `.stackyard/` is moved into `versions/` on its
first `./bootstrap` of v0.24.0 or later, by rename, so the running nginx keeps
its files. It needs one `./dc up -d --force-recreate nginx` to get the new
mounts; `./bootstrap` says so, and no update after that needs one.

## Updating and rolling back

On the laptop, `stackyard pin <machine>` shows the platform diff, rewrites the
two lines of the lock, and refreshes `bootstrap` and the machine commands
(`./stack`, `./dc`, …) from the templates if they fell behind. Run `./bootstrap`
in the machine's directory there as well: the laptop's copy of the platform is
what `./stack enable|disable --manifest-only` resolves dependencies with, and
it should be the version the machine is about to run. Commit, push, and on
the server:

```sh
git pull && ./bootstrap && ./stack sync && ./stack --check
```

`stackyard pin <machine> --version <tag>` pins an older release. To the version
the machine ran just before, `./bootstrap` switches back to the kept copy
without a download. There is deliberately no "update everyone": a client
nobody touched keeps its version for as long as it likes, and
`stackyard fleet` shows who is behind, counting only commits that touch the
platform.

## `bootstrap.local`

When the platform is in place, `bootstrap` runs `./bootstrap.local` if the
machine has one: a toolkit from the machine's own repository, a checkout of an
application. It is a separate file because `bootstrap` is a platform file that
`pin` overwrites from the template, and machine-specific code in it would
disappear at the next update. A failure there is reported and does not fail
the install.

## Offline and local installs

`STACKYARD_SOURCE=/path/to/stackyard ./bootstrap` takes a local checkout instead
of the network, for developing the platform and for installing without
internet. It installs that checkout's HEAD through `git archive`, so neither
`.git` nor uncommitted edits land on the machine. A mismatch with the lock is
not a refusal in that mode, but it is said out loud.

## Emergency: vendoring

For a client who needs a repository that works with no access to stackyard at
all, `stackyard vendor <machine>` replaces the `platform/` and `profile/` links
with copies and writes `.vendor.lock`: the layer versions and a checksum of
every file. Commit both, and drop `/platform` and `/profile` from the machine's
`.gitignore`. `--unlink` removes the copies, and `./bootstrap` brings the
linked platform back.

The price of a copy is that nobody can tell at a glance whether it was edited in
place. `platform/bin/check-vendor.sh` compares the copy with `.vendor.lock` and
catches a changed file, a missing one and an extra one. It runs first in
`host-setup --check`: if the platform is not the right one, everything else is
being checked by the wrong code.

## The operator CLI's store

The laptop keeps the same layout. `install.sh` puts every installed version in
`~/.local/share/stackyard/versions/<commit>/`, with `current`, a mirror of the
repository (`repo.git`) for the history `pin` and `fleet` read, and the fleet
list. Only the CLI may follow the `latest` branch; a machine always runs the
commit in its lock. The reasoning is in
[distribution-and-cli.md](../devel/plans/distribution-and-cli.md).

The fleet list is what `stackyard fleet` and `stackyard audit` read when given
no paths:

```sh
stackyard fleet add-dir ~/dev/machines   # every machine under it, found afresh on each run
stackyard fleet add ~/work/odd-one       # one machine that lives elsewhere
stackyard fleet list                     # what the list resolves to
```

A `machines_dir=` line means a machine created under that directory is in the
fleet without anyone adding it. A `~/.stackyard-fleet` from before the store is
still read, with a note, and the first `add` carries it over.
