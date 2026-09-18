# Databases and users of the shared postgres

`databases.yaml` in this directory is **generated** — edits survive exactly
until the next `./scripts/stack.sh sync`. It is not in git: it contains the
passwords of every database on the machine, so the file is server-side and
carries `chmod 600`.

## Where it comes from

From the stacks' own declarations. A stack that needs a database gets three
lines added to its `stack.conf`:

```sh
Requires="pg"
Postgres_DB="${Sage_DB_Name}"
Postgres_User="${Sage_DB_User}"
Postgres_Password="${Sage_DB_Password}"
Postgres_Dump="seed.sql"     # optional, see below
```

What goes into `stack.conf` are **references** to variables, not values: the
secret stays in `stacks/<stack>/.env`, which is server-side and `chmod 600`.
The platform expands them at generation time.

A second place holding the same name, user and password drifts away from the
stack's `.env` silently: the application gets `P1000 / password authentication
failed` against a healthy database, and it shows only in the application's log,
hours after `up -d`.

## What `initializer.sh` does

Idempotent: existing users and databases are not recreated.

- **No user** — created with the declared password.
- **User exists** — the password is not changed, but it is verified with a
  trial connection. On a mismatch the container prints what to fix and exits
  non-zero. `ALTER USER` is deliberately not done: a password changed by hand
  in psql and not written into `.env` would be silently overwritten on the next
  `up -d`.
- **No database** — created with `OWNER` = the declared user. That matters for
  Prisma: since PG15 the `public` schema belongs to `pg_database_owner`, and
  without the right owner `prisma migrate deploy` will not create the tables.
- **Database exists** — not touched at all.

`Postgres_Dump` is loaded **only when the database is created**, from the
`dumps/` directory at the repository root. Otherwise every `up -d` would pour
the seed over live data.

## Verify

```bash
./scripts/stack.sh --check          # the "Shared databases" block
docker logs db-initializer
```

`db-initializer` has no `restart: always`, so from the outside its failure looks
simply like `exited`. That is precisely why `--check` looks at its exit code
separately — otherwise the loud message would go to a log nobody reads.
