# 0001. How the platform reaches a machine

Status: accepted, implemented (see "How a machine gets the platform" in the
README).
Date: 2026-09-15.

This record fixes **why** this particular mechanism was chosen. The mechanism
itself is described in the README; here are the rejected alternatives and the
reasons, so that in six months nobody has to derive them again.

## Context

One shared engine serves several machines, each belonging to a different
client. The requirements everything follows from:

1. **Isolation.** Client A's machine must not hold client B's inventory. That
   rules out a monorepo with all the machines in it.
2. **A self-contained machine.** The machine's repository goes to the client;
   the fewer external dependencies its deployment has, the better.
3. **Divergence must not be silent.** The original problem was stated exactly
   that way: "everything is about to start drifting apart". By the time of the
   assessment it already had — `ledger-devbox` had drifted hundreds of lines
   from the reference before it even started working.
4. **Fleet visibility.** "Did the fix reach every machine" must have a quick
   answer.

## Decision

The platform is a **versioned artifact the machine downloads**, and the
machine's repository holds only a version declaration and a `lock` with a hash.
The download is performed by a small committed `bootstrap`; the unpacked
platform is not in the machine's git.

That is how `terraform init`, `helm dependency update`,
`ansible-galaxy install -r`, `npm ci` and `dbt deps` work. What they have in
common: **git holds the lock, not the dependency's code**.

## Rejected alternatives

### Vendoring (a copy of the platform committed into the machine's repository)

Implemented first and rejected once it became clear it **does not solve the
original problem**. Checksums make an in-place edit visible and `VERSION` makes
the version visible, but there are still N copies, the temptation to patch in
place is still there, and an update is N operations with a diff across dozens
of files. Fleet visibility requires comparing contents rather than reading one
line.

Kept as an **offline mode** for a machine without network or a client who
requires a fully self-contained repository. `check-vendor.sh` only makes sense
there.

### git submodule

Requires access to the platform repository at clone time and a separate
`--recursive` step. Machines go to clients; giving a client access to the
platform just so their config assembles is a bad trade. Plus the classic trap
of a forgotten pointer commit.

### git subtree

The copy remains, but git knows where it came from, and an update becomes a
merge: divergence surfaces as a conflict where it actually is, not after the
fact via a checksum. An honest alternative, and if publishing releases turns
out to be inconvenient, this is the thing to come back to.

It loses on fleet visibility: "which version is the client on" still does not
read as one line.

### copier / cruft (a template that tracks its upstream)

Tools for exactly "I generated a project from a template and want to pull the
template's updates"; `update` performs a three-way merge. Not a fit for the
**platform**: a machine is not supposed to edit the platform, and a three-way
merge encourages precisely that.

For **generating a new machine's repository** it is a fit, and if
`new-machine.sh` starts growing logic, `copier` is worth considering in its
place.

## Consequences

**The price, and there is exactly one:** "one clone and it works" is gone —
there is now a `bootstrap` step. Exactly the price `npm install`,
`terraform init` and `ansible-galaxy install` charge; the step is obvious to
anyone, and a committed lock with a hash settles the question of trusting what
was downloaded.

**What was gained:**

- updating a machine is editing one version line, not a diff across dozens of
  files;
- rolling back is restoring that same line;
- "who is on which version" reads as one line per machine (`bin/fleet.sh`);
- an in-place platform edit does not survive `bootstrap`, so fixes have to
  happen at the source — which was the point.

**What is left open:** the platform's code is versioned, but the **declaration
contract** is not. `stack.conf` carries no `apiVersion`, so an incompatible
format change will be read silently and wrongly. More in idea 3 of
`../k8s-assessment.md`.

## Industry analogues

Our build is "a framework plus per-deployment configuration". The closest
relatives, worth watching:

- **Ansible** — the same domain (provisioning with shell and configs): the
  engine as a package, roles in `requirements.yml` with versions, your own
  playbooks.
- **Helm** — the same structure: a chart plus `values.yaml`. Our `profiles/`
  are the charts, our `.env` is values.
- **NixOS with several hosts in a flake** — literally our problem: a shared set
  of modules, a per-machine config, `flake.lock` pinning the source by hash.
- **Terraform** — modules from the registry with a version constraint, the lock
  in git, the providers' code not.
- **Create React App / Next.js** — the "eject" pattern: you consume a
  dependency, and you may diverge once, explicitly, by taking a copy. We
  already have that as the two stack roots: copy from `profile/stacks/` into
  `stacks/` and you shadow it and own it.
