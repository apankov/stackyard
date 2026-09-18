# Fixture machines

Two synthetic layouts the engine is exercised on: `alpha` (shared MySQL, a PHP
site, a redirect with an alias, a proxy into somebody else's container) and
`beta` (shared Postgres). Different DBMSes on purpose -- the platform counts as
shared exactly when both run on it without a single edit.

There are no real machines here and there cannot be: the repository is public,
and a client's domains and stack list in a public repository are exactly the
leak the split was made for. Every name is under `example.com`.

## How they differ from a real machine

`platform` and `profile` here are symlinks straight into the working tree, not
copies brought by `./bootstrap`. That is for the development loop: an edit to
the engine is visible to the fixtures immediately, with no commit and no second
`bootstrap`. A real machine is arranged differently -- see the README at the
root.

`bootstrap` itself does not go untested because of that: it is exercised on a
separate machine created with `bin/new-machine.sh`.

## Run

```sh
./platform/bin/selftest.sh              # the whole engine, these fixtures included
./tests/machines/alpha/stack --check
./tests/machines/alpha/dc --all-stacks --examples config -q
```
