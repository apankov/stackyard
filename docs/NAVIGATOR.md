# Documentation navigator

Reading order for someone new: [README.md](../README.md) — what this is, the
quick start, the commands. Then the guide for whatever you are about to do.

## Root

- [README.md](../README.md) — what stackyard is, how the pieces fit, installing
  the CLI, deploying and updating a machine, requirements.

- [CHANGELOG.md](../CHANGELOG.md) — what changed in each release, and what to
  do when a release breaks something.

## Guides

- [guides/stacks.md](guides/stacks.md) — writing stacks: what a directory
  declares, every `stack.conf` key, copy or link, the database provider role,
  external certificates, foreign containers.
- [guides/agents.md](guides/agents.md) — how an AI agent should work with a
  fleet: plan, apply, check by exit code; the rules; what is still missing.
- [guides/isolation.md](guides/isolation.md) — what keeps clients apart,
  `stackyard audit`, machine state, pinned getssl.

## Architecture

- [platform-delivery.md](architecture/platform-delivery.md) — how a machine gets
  the platform: the lock, `bootstrap`, versions side by side, updating and
  rolling back, `bootstrap.local`, offline installs, emergency vendoring.

- [decisions/0001-delivery-mechanism.md](architecture/decisions/0001-delivery-mechanism.md)
  — why the platform is downloaded by version and `lock` rather than vendored,
  submoduled or subtreed. The rejected options and the price of the chosen one.
- [k8s-assessment.md](architecture/k8s-assessment.md) — whether the machines
  should move to Kubernetes (no, and why), and six ideas from its design worth
  taking. Assessed 2026-09-15.

## Plans

- [devel/plans/extraction-backlog.md](devel/plans/extraction-backlog.md) — what
  is left after extracting the platform: the unported backup and notifications,
  assumptions that get in the way of distributing it, secret-handling debts.
- [devel/plans/after-first-migration.md](devel/plans/after-first-migration.md)
  — what one day of running a live machine on stackyard exposed, as classes of
  defect rather than instances, and the queued architecture work.
- [devel/plans/distribution-and-cli.md](devel/plans/distribution-and-cli.md) —
  whether to install stackyard the way nvm is installed: which part that fits
  (the operator's tools), which part it must not touch (the platform onto a
  machine), and the `./stack init` command that removes the remembered steps.

- [devel/plans/promotion.md](devel/plans/promotion.md) — how to put stackyard
  in front of the people it is for: the readiness checklist before any launch,
  positioning, channels in order, the questions to have answers ready for.

## Assets

- [assets/logo/](assets/logo/) — the mark (`stackyard-mark.svg`, and
  `stackyard-mark-dark.svg` for dark backgrounds) and the repository's social
  preview (`social-preview.svg`, rendered to `social-preview.png` at 1280×640
  for GitHub's Settings → Social preview).
