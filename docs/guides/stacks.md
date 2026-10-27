# Writing stacks

A stack is one project on a machine: its containers, its vhosts, its
certificates, its database, its timers. This page is what a stack can declare
and why each declaration is explicit.

## A stack is a directory

**A stack is declared by a directory containing `stack.conf`.** Not by a bare
directory: a machine creates `stacks/<name>/.env` for every enabled stack,
profile ones included, and a directory holding only that file must not shadow
the real declaration.

Its subdirectories are declarations too:

| Path | Means |
|---|---|
| `compose.yaml` | the stack's own containers. Required unless `Containers="no"` |
| `nginx/*.conf` | vhosts; an include line is generated while the stack is enabled |
| `systemd/` | units, installed by `sudo ./host-setup` with the stack's prefix |
| `scripts/health.sh` | asked by `./stack --check` whether the stack is alive |
| `scripts/host-setup.sh` | the stack's host-side part, run by `host-setup` |
| `scripts/check-decl.sh` | a provider's own validation of what consumers declare |
| `scripts/backup-dump.sh` | a provider's dump hook, used by `backup.sh` |
| `.env.example` | the stack's variables; `./stack init` makes `stacks/<name>/.env` from it |

A site on the shared nginx and php-fpm, with its database in the shared MySQL:

```
stacks/site/
  stack.conf                  what the stack is and needs
  .env.example                its variables; ./stack init makes .env from it
  compose.yaml                its containers (none here: Containers="no")
  nginx/01-app.example.com.conf
```

```sh
# stacks/site/stack.conf
Requires="mysql php-fpm"
Domains="app.example.com"
Containers="no"
Mysql_DB="${Site_DB_Name}"
Mysql_User="${Site_DB_User}"
Mysql_Password="${Site_DB_Password}"
Mysql_Grants="SELECT,INSERT,UPDATE,DELETE"
```

The database is created by the provider. The engine knows the provider only
as a role: a Postgres machine enables `pg` instead, and nothing in the
platform changes.

Everything runs through the machine's `./dc`, and the composition is one
`Enabled_Stacks` line in its `machine.conf`. Compose files, vhost includes,
certificate domains, systemd units and database orders all follow from that
line; there is no second list anywhere. If compose and nginx disagreed, nginx
would crash-loop and take every vhost down with it.

## `stack.conf`

Values are **references** into the stack's `.env` (`${Site_DB_Name}`), not
copies. The file is parsed line by line and never sourced.

| Key | Example | Meaning |
|---|---|---|
| `Requires` | `"mysql php-fpm"` | stacks that must be enabled first; `enable` adds them, `disable` refuses to pull them out from under a dependent |
| `Domains` | `"app.example.com+www.app.example.com"` | the names the vhosts serve, one certificate per word; in `a+b+c`, `b` and `c` are alternative names on `a`'s certificate |
| `Containers` | `"no"` | the stack has no compose file of its own (a site on the shared php-fpm, a proxy to someone else) |
| `Certs` | `"external"` | TLS is terminated in front of the machine; see below |
| `Watch_Project` | `"shop-main"` | a foreign compose project whose containers are this stack's; see below |
| `Static` | `"app.example.com:${App_Dir}/public"` | static content nginx serves from a host directory |
| `Provides_DB` | `"Mysql"` | this stack is the machine's database provider, under that prefix |
| `DB_Init_Service` | `"mysql-initializer"` | the provider's one-shot container that creates users and databases |
| `<Prefix>_DB`, `_User`, `_Password` | `Mysql_DB="${Site_DB_Name}"` | a database order from a consumer |
| `<Prefix>_Grants` and others | `Mysql_Grants="SELECT,INSERT"` | provider-specific; validated by the provider's `check-decl.sh` |
| `Backup_Sqlite`, `Backup_Files`, `Backup_Volume` | `"${App_Dir}/db.sqlite"` | what `backup.sh` takes from this stack besides its databases; all `Backup_Files` paths of a stack go into one archive, each under its base name, so two paths with the same base name are refused |
| `Access_Export` | `"yes"` | export this stack's access logs every night, anonymised, and keep them; see below |
| `Image_Tag` | `"registry.example.com/app:main"` | the moving tag `./registry pin <stack>` resolves to a digest |

## The profile's stacks

| Stack | Image | Status |
|---|---|---|
| `pg` | `postgres:16-alpine` | current |
| `mysql` | `devilbox/mysql:mysql-5.5` | **legacy**: MySQL 5.5 is long out of support |
| `php-fpm` | built from `alpine:3.8`, PHP 5.6 | **legacy**: both long out of support |
| `redis` | `redis`, no tag | current, but floating: whatever `latest` is on pull |

The legacy ones exist because a machine migrated onto stackyard runs on them,
not as a recommendation. For a new machine, prefer `pg`, or copy a stack into
the machine's `stacks/` and give it a current image. Profile images are
referenced by tag rather than digest, and the initializers add packages when
they start; see [SECURITY.md](../../SECURITY.md) for what that means.

## Copy or link

Stacks are looked up in two roots, the machine one first:

```
<machine>/stacks/          its own. Edited freely
<machine>/profile/stacks/  the library that came with the profile
```

**Linked**: the stack exists only in the profile, and updating the platform
brings its changes. **Copied**: `stack.conf` sits in the machine's `stacks/`,
the machine copy shadows the profile one, and profile updates no longer touch
it. Detaching means copying the whole directory; half a copy is not a stack,
and a single `ls stacks/` shows which is which.

A stack's `.env` is **always** the machine's, even for a profile stack: the
secret belongs to the machine, and the profile is replaced wholesale on every
update.

## The database provider is a role, not a name

The engine does not know the words "MySQL" and "Postgres". It knows that some
enabled stack declared itself a provider:

```sh
# profile/stacks/mysql/stack.conf
Provides_DB="Mysql"
DB_Init_Service="mysql-initializer"
```

A consumer orders a database with keys carrying that prefix:

```sh
# stacks/timesheets/stack.conf
Requires="mysql php-fpm"
Mysql_DB="${Timesheets_DB_Name}"
Mysql_User="${Timesheets_DB_User}"
Mysql_Password="${Timesheets_DB_Password}"
Mysql_Grants="SELECT,INSERT,UPDATE,DELETE"
```

A machine on Postgres enables `pg` with `Provides_DB="Postgres"`, and not one
line of the platform changes; the two fixtures, `alpha` on MySQL and `beta` on
Postgres, are there to prove it. What the keys beyond `DB`/`User`/`Password`
mean is the provider's business: `Grants` is validated by
`profiles/stacks/mysql/scripts/check-decl.sh`, because the list of MySQL
privileges is knowledge about MySQL, not about the platform.

## Whose certificate it is

By default the machine issues and renews a certificate for every domain a stack
declares. A stack whose TLS is terminated **in front of** the machine, behind a
load balancer or a CDN, says so:

```sh
# stacks/shop/stack.conf
Domains="ledger.staging.example.com"
Certs="external"
```

Then no getssl config is written for those names, `check-certs.sh` reports them
as external instead of counting a placeholder as a problem, and if no enabled
stack is left wanting getssl, `host-setup` removes the renewal timers rather
than installing them. The placeholder certificate stays either way:
`listen 443 ssl` with no certificate file is a refusal to start.

It is explicit rather than inferred from a failing challenge. A domain nobody
issues a certificate for looks exactly like one whose renewal broke: the first
machine to need this had failed a renewal every night for two weeks, for a
domain a load balancer had been terminating all along, with a green timer,
because getssl exits zero when there is nothing it can do.

## Proxying to another compose project

A common shape: an application with a `docker-compose.yaml` of its own, in its
own repository, brought up by its own `make up`; the machine only has to put
it behind nginx, with a domain and a certificate. The stack is then a vhost
and nothing else (`Containers="no"`), and its `Watch_Project` names the
application's project (below). How nginx reaches the application is one of
three ways.

**1. Through the host, on the bridge address — recommended.** The application
publishes its port on the docker bridge's address on the host, and the vhost
proxies to `host.docker.internal`, which the platform's nginx maps to that
address:

```yaml
# the application's own docker-compose.yaml
    ports:
      - "172.17.0.1:3000:3000"   # the bridge address: `docker network inspect bridge`
```

```nginx
# stacks/shop/nginx/10-shop.example.com.conf
    location / { proxy_pass http://host.docker.internal:3000; }
```

The two projects stay independent: the application's `down` never touches
nginx, and nothing joins anyone else's network. Two ways to publish that look
the same and are not:

- `"3000:3000"` or `"0.0.0.0:3000:3000"` works, and is open to the internet
  wherever the firewall lets it through: Docker's rules sit ahead of the host
  firewall. A live machine served a storefront this way for weeks.
- `"127.0.0.1:3000:3000"` is closed to the outside and to nginx too:
  `host.docker.internal` is the bridge address, not the host's loopback, and
  the proxy gets "connection refused".

`./stack --check` looks at every `host.docker.internal` port the enabled vhosts
use and says which of the three it is: a warning for every interface, a
failure for loopback only, ok for the bridge address or a port no container
publishes (a process on the host itself).

**2. The application joins the machine's network.** Its compose file declares
the machine's `Platform_Network` as an external network, and the vhost proxies
to its container by name. No port is published at all. The price: the
application depends on that network's name, and it is now inside the
machine's trust domain, one hop from the shared database and redis (see
[SECURITY.md](../../SECURITY.md)). Right for an application you own and
trust, not for someone else's.

**3. nginx joins the application's network.** Not supported, on purpose:
nginx would depend on another repository's lifecycle. The network has to exist
before nginx starts, its re-creation leaves nginx on a network that is gone,
and attaching to a new one means recreating nginx, which takes every site on
the machine down with it.

## Whose containers they are

`watch-host` alerts about the machine's own containers, those in its compose
project, and about a foreign one only while an enabled vhost points at it. A
stack whose application runs in a compose project of its own, started from
another repository and reached through `host.docker.internal`, is pointed at
by no vhost. It says whose containers those are:

```sh
# stacks/shop/stack.conf
Containers="no"
Watch_Project="shop-main"
```

Then those containers are watched while the stack is enabled, and
`./stack --check` fails when none of them is running. Without the line, a
machine whose whole point is that application would raise no alert when it
crash-loops.

## Keeping the access logs as numbers

The platform keeps nginx's access logs `Platform_Nginx_Log_Days` (14 by
default) and no longer: they hold the IP of every visitor. A stack whose
owner wants to know, a year later, how many came, from where and how often,
asks for an export:

```sh
# stacks/site/stack.conf
Access_Export="yes"
```

Every night `devbox-access-export.timer` runs `platform/bin/access-export.sh`,
which writes each finished day of each of the stack's domains to
`state/access-export/<stack>/<domain>/<YYYY-MM-DD>.tsv.gz`, once:

- the IP becomes a client hash, SHA-256 of a per-machine salt and the address.
  The salt lives in `/var/lib/devbox-access-export`, root's alone and in no
  backup, so a client is the same client on every day while the files alone
  do not lead back to an address. `sudo ./platform/bin/access-export.sh --hash
  <IP>` gives an address's hash, to tell your own visits apart;
- the country and the network (AS) are looked up on the machine first, in
  [DB-IP](https://db-ip.com)'s free databases (CC BY 4.0), fetched monthly;
- query strings go, and so does any long token in a path.

The directory's `FORMAT` names the columns. The exports are kept for good and
backed up as an archive of their own, `files/<stack>-access-export`. Only
`yes` and `no` are values: `Access_Export="Yes"` fails `host-setup` instead of
quietly exporting nothing. The vhost must log to
`/var/log/nginx/<domain>-access`, as the rotation expects.

A new salt (a rebuilt machine) starts new clients: the hashes before and after
cannot be matched. Whether keeping these files needs a word in a site's
privacy note is the site owner's call: they are pseudonymous while the salt
exists, not anonymous.

