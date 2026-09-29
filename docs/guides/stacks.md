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

Everything runs through the machine's `./dc`, and the composition is one
`Enabled_Stacks` line in its `.env-stacks`. Compose files, vhost includes,
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
| `Backup_Sqlite`, `Backup_Files`, `Backup_Volume` | `"${App_Dir}/db.sqlite"` | what `backup.sh` takes from this stack besides its databases |
| `Image_Tag` | `"registry.example.com/app:main"` | the moving tag `./registry pin <stack>` resolves to a digest |

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
