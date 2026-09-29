# Promotion: getting stackyard in front of the people it is for

Written 2026-09-29. Nothing here is launched yet. The rule this plan rests on:
**do not promote before the first visitor can succeed.** People who arrive,
find it raw and leave rarely come back, and a young project gets one first
impression per channel.

## Where it stands

v0.34, one user, three live machines, a breaking change most weeks. The
engine is well tested (selftest, a mutation run, CI with a real `nginx -t`),
the README is a front page, there is a CHANGELOG, a logo and a social
preview. What is missing is everything a stranger needs to try it without
the author in the room.

## Positioning

Not "a Coolify/Dokku alternative": those have a web UI and `git push` deploys,
and a comparison on their terms is lost. The niche, in one line each:

- **A fleet of small hosts kept in a known state, from git, with nothing to
  run on the server but docker.** Every host pinned to a commit, changed by a
  reviewable diff, audited for what two clients share.
- **Safe for an AI agent to operate.** The state is text in git, commands
  reconcile and answer by exit code (and `--json`), mistakes stay small. This is
  the newest angle and the one that sets it apart most.

The honest "not for you if…" (HA, clusters, a UI, a single compose project)
stays in every post: it earns more trust than it costs.

## Readiness checklist — before any loud launch

- [ ] **The quick start works end to end on a clean VPS in ten minutes.** Walk
      it on a fresh Hetzner or DigitalOcean box, write down every step that
      stumbled, fix the step or the docs.
- [ ] **A public example machine**, `stackyard-example`: a static site, an app
      on Postgres, a proxy to an external service. Cloning an example beats
      reading about `stack.conf` keys.
- [ ] **A 30–60 second demo** (asciinema or GIF) at the top of the README:
      `stackyard new` → `sync` → `--check`, then `stackyard fleet` over three
      machines.
- [ ] **The format's stability stated.** Until 1.0 `stack.conf` and
      `machine.conf` may change, and every such change carries its steps in
      CHANGELOG. *(CHANGELOG exists since 0.34.1.)*
- [ ] **GitHub releases**, not only tags: each release's CHANGELOG entry as its
      notes.
- [ ] **The name checked**: GitHub, Homebrew, npm, PyPI, a domain. Better known
      now than after the first stars.
- [ ] **CONTRIBUTING.md, issue templates**, and two or three issues marked
      "good first issue".
- [ ] **The Social preview set** in the repository's settings
      (`docs/assets/logo/social-preview.png`).

## Channels, in order of value

1. **Habr.** The natural first audience, and one that values engineering
   write-ups over announcements. Not "here is my project" but stories that
   already happened, each ending with how stackyard settles it:
   - a green renewal timer and a certificate that expired anyway (getssl exits
     zero when there is nothing it can do);
   - one forgotten vhost taking down every site on the host;
   - SIGPIPE under systemd: a bug visible only on CI;
   - a mutation suite that proved nothing for two weeks, and how it was
     caught.
2. **r/selfhosted, r/devops, r/sysadmin.** A post with the demo and the "not
   for you if…" up front.
3. **Show HN**, only once the demo and the example machine exist. The title is
   about the substance, not the language: "Show HN: Stackyard – run a fleet of
   small Docker hosts from Git, safe for AI agents to operate".
4. **Lobsters, dev.to**: the English versions of the Habr articles.
5. **awesome-selfhosted and topical awesome lists.** awesome-selfhosted has
   rules on a project's age and activity; read them before submitting.
6. **Agent communities.** A write-up or a video of Claude Code running a fleet
   through stackyard. An MCP server or a Claude Code skill over `--json` would
   put it into those catalogues too.

## Ongoing

- A CHANGELOG entry and a GitHub release for every tag.
- A fast answer to every first issue: for a young project that matters more
  than stars.
- Nothing announced that does not exist yet.

## The questions to have answers ready for

- **"Why bash, not Go?"** On purpose: nothing to install on a server but docker,
  the code is small and readable, and selftest, the mutation run and CI keep it
  honest. The format is declarative, so machines outlive any tool that reads
  it.
- **"What happens when the one maintainer stops?"** A machine keeps running the
  commit it is pinned to, with no service to call home to; the manifest and the
  stacks are plain files anyone can read.

## Order of work

1. The readiness checklist, top to bottom.
2. The first Habr article (the certificate story is the strongest).
3. r/selfhosted, then Show HN once the demo exists.
4. The agent angle: the MCP server or skill, then the write-up.
