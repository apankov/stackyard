# Databases, users and privileges of the shared MySQL

`databases.yaml` in this directory is **generated** — edits survive exactly
until the next `./stack sync`. It is not in git: it contains the
passwords of every database on the machine, so the file is server-side and
carries `chmod 600`.

## Where it comes from

From the stacks' own declarations. A stack that needs a database gets a few
lines added to its `stack.conf`:

```sh
Requires="mysql"
Mysql_DB="${Newapp_DB_Name}"
Mysql_User="${Newapp_DB_User}"
Mysql_Password="${Newapp_DB_Password}"
Mysql_Grants="SELECT,INSERT,UPDATE,DELETE"   # optional, this is also the default
Mysql_Dump="seed.sql"                        # optional, see below
```

What goes into `stack.conf` are **references** to variables, not values: the
secret stays in `stacks/<stack>/.env`, which is server-side and `chmod 600`.
The platform expands them at generation time.

A second place holding the same name, user and password drifts away from the
stack's `.env` silently: the application gets `Access denied for user` against
a healthy database, and it shows only in the application's log, hours after
`up -d`.

## Privileges

The default is `SELECT,INSERT,UPDATE,DELETE`, and it is deliberately **not**
`ALL PRIVILEGES`. `ALL` includes `DROP`, `ALTER`, `CREATE USER` and `GRANT
OPTION`: an application with a stolen password wipes its own database and hands
access further on. A stack that applies its own schema needs
`CREATE,ALTER,INDEX` — that is the stack's decision, and it is declared
explicitly.

The user is created exactly as `'name'@'%'`. In MySQL an account is a (user,
host) pair, and `'app'@'%'` and `'app'@'localhost'` are two different records
with different privileges and passwords. Containers reach mysqld over the
bridge network from random addresses, so only `'%'` works; a second pair would
give an account that some connections land on, with "Access denied" under a
correct password.

## What `initializer.sh` does

The container is one-shot but comes up on **every** `up -d`, so everything
below is idempotent.

- **No user** — created with the declared password.
- **User exists** — the password is not changed, but it is verified with a
  trial connection. On a mismatch the container prints what to fix and exits
  non-zero. `SET PASSWORD` is deliberately not done: a password changed by hand
  and not written into `.env` would be silently overwritten on the next
  `up -d`.
- **No database** — created with `CHARACTER SET utf8`. Not `utf8mb4`: in MySQL
  5.5 the InnoDB index key limit is 767 bytes, and a `VARCHAR(255)` under
  `utf8mb4` (1020 bytes) does not fit into an index. The refusal arrives on the
  migration rather than on a query, and it looks like an application bug.
- **Database exists** — not touched at all.
- **Privileges missing** — granted.
- **Privileges beyond the declaration** — **not revoked**; an error is printed
  with a ready-made command. A removed privilege breaks the application at a
  moment unrelated to it; and staying silent is not an option, because the
  whole point of limited privileges is that the set is known.

`Mysql_Dump` is loaded **only when the database is created**, from the `dumps/`
directory at the repository root. Otherwise every `up -d` would pour the seed
over live data.

## Give a new application a database

```sh
cp stacks/newapp/.env.example stacks/newapp/.env && chmod 600 stacks/newapp/.env
$EDITOR stacks/newapp/.env          # database name, user, password
./stack enable newapp    # sync + up -d + mysql-initializer + vhost
docker logs mysql-initializer
```

There is deliberately no separate "one-time setup step" here. A one-off script
you have to remember to run is a step that will be forgotten: on a new machine,
during a restore from backup, when a stack is moved. A declaration in
`stack.conf` runs by itself, as many times as needed.

## Verify

```bash
./stack --check          # the "Shared databases" block
docker logs mysql-initializer
```

`mysql-initializer` has no `restart: always`, so from the outside its failure
looks simply like `exited`. That is precisely why `--check` looks at its exit
code separately — otherwise the loud message would go to a log nobody reads.
