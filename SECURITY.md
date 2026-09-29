# Security

## Reporting a vulnerability

Please do not open a public issue for it. Use GitHub's private vulnerability
reporting on this repository (Security → Report a vulnerability). If that is
not available, open an issue asking for a private contact, without details.

Fixes go into the newest release. A machine is pinned to a commit, so it gets
a fix when its operator runs `stackyard pin` for it; `stackyard fleet` shows
which machines are behind.

## Threat model

What stackyard is built to protect, what it is not, and what it trusts. Read
this before putting anything on a machine you would not want its neighbours
to reach.

### Between machines: isolated

Each machine is a separate host and a separate private repository. The
platform and the profile are public and hold no secrets; a machine's secrets
(`.env`, `.env-backup`, `.env-notify`, `stacks/*/.env`) exist only on its
server, mode 600, never in git. `stackyard audit` checks from the laptop that
no two machines share a secret, a backup bucket or prefix, a GPG recipient, an
alert channel, an ACME account key, a docker network or a deploy directory.
One client's machine holds no inventory of another's. Domains themselves are
public anyway, through Certificate Transparency.

### Between stacks on one machine: not isolated

All stacks of a machine share one docker network (`Platform_Network`), so any
container can reach every other by name: the shared MySQL or Postgres, a redis
without a password, php-fpm's FastCGI port, every application's own ports. A
compromised application on a machine is a compromised machine. **Treat every
stack on a machine as one trust domain**, and do not put mutually untrusted
tenants on one host: give each its own machine, which is what stackyard makes
cheap. Separate networks per stack are not provided; the shared network is
what lets a stack reach the database provider by name.

### Code that runs as root

`sudo ./host-setup` runs each enabled stack's `scripts/host-setup.sh` and
`scripts/preflight.sh`, and most of the platform's systemd units (backup,
host watching, notifications) run as root. Stacks come from the machine's own
repository and from the profile, and both are therefore trusted code: review a
stack you did not write the way you would review a script you are about to run
with sudo, because that is what it is.

### Exposure to the network

Profile stacks publish their ports on `127.0.0.1` only, and the selftest fails
on any that does not: Docker's port rules sit ahead of the host firewall, so a
port published on every interface is open wherever a security group allows it.
A machine's own stacks are its operator's to keep the same way. nginx is the
only service meant to face the internet.

### What a machine runs

- The platform is pinned by commit in `stackyard.lock`; `bootstrap` refuses a
  commit it cannot find rather than installing something else.
- getssl is downloaded per `platform/getssl.lock`, version and SHA-256.
- Stack images can be pinned to digests with `./registry pin <stack>`.
- **Not pinned yet:** the profile images are referenced by tag (`redis` by no
  tag at all), and the database initializers add packages (`apk add`) when
  they start. Both are supply-chain exposure a machine inherits from the
  profile.
- The operator CLI can be installed with `curl … | bash`, which cannot be read
  before it runs; the README gives the two-step form that can.

### Backups

Dumps are encrypted to a GPG public key; the private key is never on the
machine. `check-backups.sh` checks that every expected object exists, is
recent and is not implausibly small. That proves a backup was taken, **not
that it restores**: until a restore drill has been run on a machine, treat
its backups as unproven.

### After a failed change

`enable` and `disable` are not transactional: a step that fails part way can
leave the manifest, the containers and nginx disagreeing. `./stack sync` is
the way back: it brings the machine in line with `machine.conf`, and
`./stack --check` says what still differs.
