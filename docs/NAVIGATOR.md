# Documentation navigator

Reading order for someone new: [README.md](../README.md) — what this is, how to
deploy a machine and how to update the platform. The rest as needed.

## Root

- [README.md](../README.md) — the three layers, a stack as a directory, copy or
  link, machine isolation, platform delivery, working with a machine.

## Architecture

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
