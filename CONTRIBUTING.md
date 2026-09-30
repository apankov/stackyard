# Contributing

Issues, ideas and pull requests are welcome. The quickest way to help is to
use stackyard on a host of your own and open an issue about the first thing
that confused you: that is a bug in the docs, if nothing else.

- **A bug:** open an issue with the version, the command and what it printed.
- **An idea, a question, "is this for me?":** Discussions, or an issue if it
  is concrete.
- **A security problem:** privately, see [SECURITY.md](SECURITY.md).
- **Something to work on:** issues labelled
  [good first issue](https://github.com/apankov/stackyard/labels/good%20first%20issue)
  are small, self-contained and say where to look.

## Before a pull request

```sh
./platform/bin/selftest.sh   # the whole suite; one block needs docker
./tests/mutate.sh <name>     # the mutations near what you changed
shellcheck -S warning platform/bin/*.sh platform/lib/*.sh bin/*.sh bin/stackyard \
  install.sh templates/machine/bootstrap tests/mutate.sh
```

CI runs the same on Ubuntu with docker, plus a live Postgres for the database
initializers (`STACKYARD_LIVE_DB=1`).

What a change is expected to carry:

- **A fix comes with a selftest check that fails without it.** If the bug is
  the kind that fails silently, also a mutation in `tests/mutate.sh` that
  reintroduces it (`name@@file@@old@@new`): a check that nothing proves can
  fail is not a check.
- **Portable shell.** Machines are Linux, development is often macOS: no GNU-only
  flags (`find -printf`, `date -d` alone, bare `timeout`), bash ≥ 4.2, and
  `${2-}` for optional arguments under `set -u`. `lib-env.sh` has the portable
  helpers.
- **Comments say why**, usually by naming what went wrong without them. Keep
  that density and voice.
- **No real machines.** The repository is public: fixtures use `example.com`
  and `example.net` names only, and nothing secret goes into `platform/` or
  `profiles/`.
- **Conventional commits, one purpose each** (`fix(backup): …`,
  `feat(stack): …`). Version bumps and tags are the maintainer's.

The design is in [docs/guides/stacks.md](docs/guides/stacks.md),
[docs/architecture/platform-delivery.md](docs/architecture/platform-delivery.md)
and [docs/guides/isolation.md](docs/guides/isolation.md); read the one next to
your change first. [CLAUDE.md](CLAUDE.md) is the same conventions written for
coding agents, and holds for people too.
