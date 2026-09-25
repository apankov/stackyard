# stackyard

A yard where stacks stand: a platform for a single host on which several
independent projects live side by side, each in its own docker stack.

Extracted from two working devboxes. There are no real machines here and there
cannot be: the repository is public, and a client's domains and stack list in a
public repository are exactly the leak the split was made for. Every machine
lives in its own private repository.

`tests/machines/` holds two **synthetic** fixtures — `alpha` (shared MySQL +
PHP) and `beta` (shared Postgres). The platform counts as shared exactly when
both run on it without a single edit: different DBMSes, different stack shapes,
one engine.

## Three layers

| Layer | What it knows | Who gets it |
|---|---|---|
| `platform/` | the engine: stacks, dependencies, nginx, TLS, systemd. No machine, no DBMS, no secret | distributed |
| `profiles/` | reusable stacks: `mysql`, `pg`, `redis`, `php-fpm` | yours |
| machine | sites, `.env`, state — **its own repository**, not here | private, per client |

The split is not cosmetic. The platform contains no secrets **at all** —
otherwise it cannot be distributed, and an ACME key or a backup bucket shared
across clients means the rate limits, the access and the dumps are shared too.

## A stack is a directory

Everything runs through the machine's `./dc`; the composition is one
`Enabled_Stacks` line in its `.env-stacks`. From that line follow the compose
files, the vhost includes, the certificate domains, the systemd units and the
database orders.

**A stack is declared by a directory containing `stack.conf`.** The presence of
a subdirectory is a declaration too: `nginx/` means an include will be made,
`systemd/` means units will be installed, `scripts/health.sh` means `--check`
will ask the stack whether it is alive, `scripts/host-setup.sh` means the stack
has a host-side part.

## Whose certificate it is

By default this machine issues and renews the certificate for every domain a
stack declares. A stack whose TLS is terminated **in front of** the
machine — behind a load balancer or a CDN — says so:

```
# stacks/ledger/stack.conf
Domains="ledger.staging.example.com"
Certs="external"
```

Then no getssl config is written for those names, `check-certs.sh` reports
them as external instead of counting a placeholder as a problem, and if no
enabled stack is left wanting getssl, `host-setup` removes the renewal timers
rather than installing them.

The placeholder certificate stays either way: `listen 443 ssl` with no
certificate file is a refusal to start, not a warning.

Explicit, rather than inferred from a failing challenge, for the same reason
`Containers="no"` is explicit. A domain nobody issues a certificate for looks
exactly like a domain whose renewal has broken, and the first machine to need
this had spent two weeks failing a renewal every night for a domain an ALB had
been terminating all along — with a green timer, because getssl exits zero
when there is nothing it can do.

## Copy or link

Stacks are looked up in two roots, the machine one first:

```
machines/<name>/stacks/         its own. Edited freely
machines/<name>/profile/stacks/ the library that came with the profile
```

**Linked** — the stack exists only in the profile; updating the profile brings
the changes with it. **Copied** — `stack.conf` sits in the machine's `stacks/`,
and the machine copy shadows the profile one; profile updates no longer touch
it. Detaching means copying the whole directory; half a copy is not a stack,
and you can see which it is from a single `ls stacks/`, not from an entry in a
config file.

A stack's `.env` is **always** the machine's, even for a profile stack: the
secret belongs to the machine, and the profile is updated wholesale and would
overwrite it.

## The DB provider is a role, not a name

The engine does not know the words "MySQL" and "Postgres". It knows that some
enabled stack declared itself a provider:

```sh
# profiles/stacks/mysql/stack.conf
Provides_DB="Mysql"
DB_Init_Service="mysql-initializer"
```

A consumer orders a database with keys carrying that prefix:

```sh
# machines/client-acme/stacks/timesheets/stack.conf
Requires="mysql php-fpm"
Mysql_DB="${Timesheets_DB_Name}"
Mysql_User="${Timesheets_DB_User}"
Mysql_Password="${Timesheets_DB_Password}"
Mysql_Grants="SELECT,INSERT,UPDATE,DELETE"
```

The values are **references** into the stack's `.env`, not copies. A machine on
Postgres enables `pg` with `Provides_DB="Postgres"`, and not one line of the
platform changes. What the keys beyond the mandatory `DB`/`User`/`Password`
mean is the provider's business: `Grants` is validated by
`profiles/stacks/mysql/scripts/check-decl.sh`, because the list of MySQL
privileges is knowledge about MySQL, not about the platform.

## Working with a machine

```sh
cd machines/client-acme
./stack list           # what is enabled and what is actually alive
./stack --check        # declarations, domains, databases, upstreams, vhosts, units
./stack enable <stack> # containers first, then the vhost — the order matters
./stack sync           # bring nginx in line with the manifest
./dc up -d
sudo ./host-setup      # packages, certificate placeholders, timers, stack host parts
./memory               # where the memory went: by container, by stack, by role
```

## Machine state

`machines/<name>/state/` is everything that describes this particular machine
and is generated: certificates, `getssl-config`, `databases.yaml` (with
passwords), `10-enabled.conf`, `nginx-static.generated.yaml`, `bin/getssl`.
Not a line of it is in git.

`getssl` lives there for the same reason: it is not vendored into the
repository but downloaded per `platform/getssl.lock` — a pinned version plus a
sha256. A copy of someone else's GPL-3 script inside a public MIT repository is
awkward both legally and in substance: it gets edited in place, and it drifts
from upstream silently. The checksum is also there because getssl can update
itself (`getssl -u` downloads a fresh version and overwrites itself); the units
pass `-U`, which disables even the version check, and the checksum catches the
case where someone ran `-u` by hand anyway.

    ./platform/bin/getssl-fetch.sh           # download the pinned version
    ./platform/bin/getssl-fetch.sh --check   # verify the checksum, change nothing
    ./platform/bin/getssl-fetch.sh --force   # put the pinned version back

The separate directory exists because `platform/` and `profile/` are shared: in
the workspace they are symlinks, on a machine they are vendored copies. Writing
there either breaks a neighbouring machine or disappears at the next update.

## Machine isolation

The platform and the profile ship to **every** machine, so a secret cannot live
in them at all: it would be copied to every client, and there would be nothing
to detect it with after the fact. `certs.sh` refuses to run if
`platform/getssl-config/account.key` exists.

Isolation is checked by `./bin/audit-isolation.sh`, and it lives **in the
workspace, not on a machine**: a machine by definition cannot see its
neighbours, and a bucket shared by everyone looks to it exactly like a properly
configured one of its own. It looks for:

- secrets in `platform/` and `profiles/`;
- the same `Platform_Network`, `Platform_Deploy_Dir`, backup bucket and prefix,
  GPG recipient, notification token or chat on two machines;
- the same password under **different** keys on different machines — leak it on
  one and it opens both;
- one ACME account key on two machines: that means shared Let's Encrypt limits
  and the ability to revoke the other's certificates.

An honest caveat: domains are public anyway through Certificate Transparency at
issue time. What is achieved is "client A's machine holds no inventory of
client B", not "domains are secret".

## How a machine gets the platform

The platform is **not** in the machine's git. The machine's repository holds
only `bootstrap` (one file, plain bash) and `stackyard.lock` with the pinned
version:

```
repo=https://github.com/apankov/stackyard.git
version=v0.3.0
commit=019829962cd0be920ebfd59fa675da820652c51a
```

`./bootstrap` fetches it into `.stackyard/` (not in git) and links it in as
`platform/` and `profile/`.

Every version gets a directory of its own, and the machine runs whichever one
`current` points at:

```
.stackyard/versions/<commit>/
.stackyard/current  -> versions/<commit>    what the machine runs
.stackyard/previous -> versions/<commit>    the one before, kept for a rollback
platform -> .stackyard/current/platform
profile  -> .stackyard/current/profiles
```

An update downloads the new version next to the old one and swaps `current`
with a rename; `.stackyard` itself is never replaced. That matters for nginx: a
bind mount pins the directory it was started on, not its path, so an nginx
that mounted `platform/nginx-snippets` was left looking at a deleted directory
after every `./bootstrap` and served no domains until it was recreated. nginx
now mounts `.stackyard` and reaches `/etc/nginx/snippets`, `/etc/nginx/conf.d`
and `/etc/nginx/profile-stacks` through links that follow `current`
(`platform/compose/nginx-entrypoint.sh`), so after an update it needs a
reload — `./stack sync`, which runs `nginx -t` first — and not a restart.

A machine on the older flat `.stackyard/` is moved into `versions/` on its
first `./bootstrap` of this version, by rename, so the running nginx keeps its
files. It still needs one `./dc up -d --force-recreate nginx` to get the new
mounts; `./bootstrap` says so, and no update after that needs one. This is the same mechanic as `terraform init`,
`helm dependency update`, `ansible-galaxy install -r` and `npm ci`: the
repository declares a version rather than carrying a copy of the code.

The pin is by **commit**, not by an archive hash: GitHub's automatic archives
are not guaranteed byte-stable, while a commit is immutable by definition. If a
tag was moved, `bootstrap` refuses to run rather than handing over unapproved
code.

When the platform is in place, `bootstrap` runs `./bootstrap.local` if the
machine has one. That is where a machine puts what only it needs fetched — a
toolkit pulled from its own repository, a checkout of an application. It is a
separate file because `bootstrap` itself is a platform file that `./bin/pin.sh`
overwrites from the template: machine-specific code inside it would disappear
at the next update without a word. A failure there is reported and does not
fail the install — the platform is already installed by that point.

### Deploy a machine

```sh
# on the laptop
cd ~/dev/stackyard
./bin/new-machine.sh ~/dev/machines/client-acme
cd ~/dev/machines/client-acme && git init
$EDITOR .env.example .env-stacks.example   # then cp without .example
# describe the sites in stacks/, commit, push

# on the server
git clone <the machine's repository> /mnt/data/client-acme
cd /mnt/data/client-acme
./bootstrap
sudo ./host-setup
./stack enable mysql php-fpm site
```

### Update the platform on a machine

```sh
cd ~/dev/stackyard && git pull
./bin/pin.sh ~/dev/machines/client-acme   # shows the platform diff, rewrites the lock
cd ~/dev/machines/client-acme && git commit -am "platform 0.3.0" && git push
# on the server: git pull && ./bootstrap && ./stack sync && ./stack --check
```

**Two lines** change in the machine's repository, not sixty files. Rolling back
is `./bin/pin.sh <machine> --version v0.2.0`; to the version the machine ran
just before, `./bootstrap` switches back to the kept copy without a download.

There is deliberately no "update everyone" command: a client nobody touched
keeps running its own version for as long as it likes.

### Who is on which version

```sh
./bin/fleet.sh ~/dev/machines/*
./bin/audit-isolation.sh ~/dev/machines/*
```

```
MACHINE       VERSION  BEHIND  COMMIT
client-acme   v0.3.0   no      019829962cd0
client-beta   v0.2.0   1       a6dbe464c8bd
```

Both commands take paths; with no arguments they read `~/.stackyard-fleet`, one
path per line.

They exist for one question that otherwise has no quick answer: did the fix
reach everyone. Lag is counted in commits that **touch the platform** — a
machine twenty README commits behind is behind on nothing.

### Offline mode

`STACKYARD_SOURCE=/path/to/stackyard ./bootstrap` takes a local directory
instead of the network — for developing the platform and for installing without
internet. A divergence from the `lock` is not a refusal in that mode, but it is
said out loud: otherwise the machine would be running something other than what
is written down, and the `lock` would not show it.

`bin/vendor.sh` (a copy of the platform straight into the machine's repository)
remains as an emergency mode for a client who needs a fully self-contained
repository. `check-vendor.sh` only makes sense there.

## Vendoring: two modes

```sh
./bin/vendor.sh <machine>            # replace the symlinks with copies, write .vendor.lock
./bin/vendor.sh <machine> --unlink   # restore the symlinks (development mode)
```

**Symlink** is the workspace: both machines run byte-for-byte the same files,
so divergence is impossible by construction. That is how the platform is proven
to be shared.

**Copy** is what ships to a machine. A machine's repository must be
self-contained: one `clone`, with no access to a second repository, no
`--recursive`, no forgotten pointer commit. The machine runs the version it was
vendored with — a platform edit in the workspace does not reach it until
`vendor.sh` is run again.

The price of a copy is that you cannot tell at a glance whether someone edited
the platform in place. So `.vendor.lock` sits next to it with the versions and
file checksums, and `platform/bin/check-vendor.sh` verifies them and catches
all three kinds of divergence: a file changed, a file gone, a file present
beyond the manifest. That check comes first in `host-setup --check`: if the
platform is not the right one, everything else is being checked by the wrong
code.

In THIS repository the vendored copies are not in git — here they are a
duplicate. In a client machine's repository it is the other way round: the copy
is the whole point of vendoring, and it is committed together with
`.vendor.lock`.

## What is not done yet

`docs/devel/plans/extraction-backlog.md`.
