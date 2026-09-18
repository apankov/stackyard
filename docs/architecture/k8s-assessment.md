# Should the machines move to Kubernetes

Assessed 2026-09-15. The question was put like this: could `devbox6`,
`devbox-asstnt` and `ledger-devbox` be run through k8s on small machines, what
would we gain and lose, and what can be taken from the way k8s is designed.

Short answer: **do not move**, but several ideas from its design are worth
taking, and they are listed at the end — that is the main value of this note.

## The facts everything rests on

All three machines are of one class: Amazon Linux, **~1 GB RAM, 25 GB disk**.
`devbox-asstnt` is documented at ~916 MB, of which **~200 MB is free** with
every stack up.

`ledger-devbox` at the time of the assessment was a copy of the `devbox-asstnt`
engine that had drifted by 430 lines in `lib-stacks.sh`, 138 in `lib-env.sh`
and 185 in `stack.sh`. Its `CLAUDE.md` meanwhile described the stacks
`sanya-next` and `bod-assistant-2`, which do not exist on that machine: the
copy dragged someone else's documentation along with it. That is not an
argument for or against k8s, but it is proof that copies drifting is not a
hypothesis.

## Would it fit

No. k3s — the lightest option — in practice holds 350-600 MB under the control
plane (apiserver, controller-manager, scheduler, kubelet, containerd, coredns).
Stripped down (`--disable traefik,servicelb,metrics-server,local-storage`,
sqlite instead of etcd) it is 300-400 MB. Free memory is ~200 MB. The result
would be "we have a cluster and no applications".

The entry threshold is 2 GB minimum, realistically 4 GB per machine, and that
multiplies by the number of clients.

## What we would gain

- **The main failure class would disappear.** Recreating nginx while an
  upstream is down gives a crash loop and takes down every site on the machine.
  In k8s that is closed by readiness probes and by a Service not sending
  traffic to a pod that is not ready. We treat it with the order of operations
  in `stack.sh`, and a residual race remains.
- **Memory limits would be enforced.** Today, checking free memory before
  starting a container is a ritual you have to remember.
- **cert-manager instead of getssl + timer + reload.** Renewal, storage and
  reloading become someone else's concern, tested on an incomparably larger
  number of installations.
- **The distribution problem is solved by Helm**: a chart (versioned,
  published) + a per-install `values.yaml` + `helm list` answering "which
  version is where". We arrived at the same three things on our own.

## What we would lose

- **Memory.** Decisive.
- **We would pay for a scheduler we do not use.** The value of k8s is spreading
  load across nodes and moving work when a node dies. On a single node, the
  node dying means the site is dead either way.
- **The legacy would not get better.** PHP 5.6, MySQL 5.5 and docroots outside
  the repository would turn into `hostPath` volumes — the very thing the k8s
  documentation warns against — plus YAML on top.
- **The host-side part does not move at all**: the `/usr/local/bin/php` shim,
  the `_db` toolkit, manual dumps.
- **We would take on a standing duty** to upgrade the cluster and track API
  deprecations. Today there is none.
- **Client isolation would not improve.** A namespace is not a security
  boundary between clients; we would need a cluster per client, i.e. a control
  plane each — worse than now.
- **The ergonomics assume a platform team**, not one person.

## What we have already taken from k8s without calling it that

Three decisions in `stackyard` are direct analogues, which confirms the
direction is right:

| Ours | In k8s |
|---|---|
| `Provides_DB` on a provider stack | a capability declaration; the CRD idea: a new resource type is declared as data, with a controller attached |
| "the presence of a directory is a declaration" | kubelet's static pods: resources read from a directory, with no registry |
| a provider's `scripts/check-decl.sh` | a validating admission webhook: validate at declaration time, by whoever owns the semantics |

## What is worth taking, most valuable first

### 1. Requests as a declaration, plus refusal when short

`Resources_Memory=256M` in `stack.conf`, and `stack.sh enable` refuses to
enable a stack if the sum over the enabled ones exceeds the machine's RAM minus
a reserve.

On 1 GB machines that turns "do not forget to check free memory" from a ritual
into a rule. The cheapest and most useful idea on the list.

### 2. `spec` versus `status`, explicitly and everywhere

Every k8s object has a desired state and an observed one, and they are never
mixed. Our best checks already work that way — the "live nginx versus the spec"
block, and `health.sh` asking the running server rather than a file on disk.

This is worth making a rule: **every declaration must have a paired check by
observation**, and `--check` is their difference. Several of our own bugs would
have been caught by that rule.

### 3. A version for the contract, not only for the code

k8s versions the API of its objects and guarantees that old manifests keep
being readable. That is exactly what we lack: `stack.conf` should carry an
`apiVersion`, and the platform should refuse or convert rather than silently
read it wrong.

The platform's `VERSION` answers "what is installed"; a declaration's
`apiVersion` answers "is it compatible". The second does not exist yet, and it
is the missing piece in fleet updates.

### 4. A reconciliation loop instead of a one-shot `sync`

`stack.sh sync` is `kubectl apply` run by hand. In k8s a controller applies
continuously, so drift heals itself. The cheap version: a timer that runs the
comparison and reports a divergence. It hits "somebody patched it in place"
directly.

### 5. Readiness separate from liveness

Our `health.sh` is closer to liveness. k8s adds: do not send traffic until it
is ready. Our analogue is that `stack.sh enable` should **wait** for the
upstream to be ready before writing the vhost, not merely keep the order of
operations.

### 6. Helm's three entities

The chart (versioned, published), the values (per install) and the **release** —
the record of what is actually deployed and where. We have the first two; the
third appeared as `bin/fleet.sh`, and it is worth looking at exactly as a
release registry.

## What to do about it

Ideas 1-3 come first in the queue: the first fixes real pain on these machines,
the third closes the hole in fleet updates. Ideas 4-6 are cheaper to discuss
once we have decided how many machines we serve.

`ledger-devbox` is more useful seen not as a third machine but as the first
piece of evidence: it drifted before it even started working. Whatever
mechanism we choose is meaningfully tested on it — can we bring it back to the
shared engine without losing what was deliberately done there.
