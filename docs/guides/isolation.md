# Machine isolation and machine state

stackyard is built for running many clients' hosts from one laptop without any
of them seeing another. This page is what keeps them apart, and where each
machine keeps what is its own.

## Nothing secret is shared

The platform and the profile ship to **every** machine, so a secret cannot live
in them at all: it would be copied to every client, and nothing could detect it
afterwards. This repository is public for the same reason, and holds no real
machine: the fixtures in `tests/machines/` use `example.com` names only. Each
real machine is a private repository of its own, and its secrets — `.env`,
`.env-backup`, `.env-notify`, `stacks/*/.env` — exist only on its server.
`certs.sh` refuses to run if `platform/getssl-config/account.key` exists.

## `stackyard audit`

Isolation is checked from the laptop, never on a machine: a machine by
definition cannot see its neighbours, and a bucket shared by everyone looks to
it exactly like a properly configured one of its own. `stackyard audit` (with no
arguments, the whole fleet) looks for:

- secrets in `platform/` and `profiles/`;
- the same `Platform_Network`, `Platform_Deploy_Dir`, backup bucket and prefix,
  GPG recipient, notification token or chat on two machines;
- the same password under **different** keys on different machines: leak it on
  one and it opens both;
- one ACME account key on two machines, which means shared Let's Encrypt limits
  and the ability to revoke each other's certificates.

An honest caveat: domains become public anyway through Certificate Transparency
when a certificate is issued. What is achieved is "client A's machine holds no
inventory of client B", not "domains are secret".

## Machine state

`<machine>/state/` is everything generated that describes this particular
machine: certificates, `getssl-config/`, `databases.yaml` (with passwords),
`nginx-vhosts/10-enabled.conf`, `nginx-static.generated.yaml`, `bin/getssl`.
None of it is in git, and nothing is ever written into `platform/` or
`profile/` at runtime: they are replaced on the next update, and on the
workspace they are shared by every fixture.

## getssl, pinned

getssl is not vendored into this repository. `platform/bin/getssl-fetch.sh`
downloads it into `state/bin/` per `platform/getssl.lock`, a version plus a
sha256. A copy of someone else's GPL-3 script inside an MIT repository is
awkward legally and in practice: it gets edited in place and drifts from
upstream silently. The checksum is there because getssl can update itself
(`getssl -u` overwrites itself with a fresh download); the units pass `-U`,
which disables even the version check, and the checksum catches the case where
someone ran `-u` by hand anyway.

```sh
./platform/bin/getssl-fetch.sh           # download the pinned version
./platform/bin/getssl-fetch.sh --check   # verify the checksum, change nothing
./platform/bin/getssl-fetch.sh --force   # put the pinned version back
```

Upstream offers a floating `latest` URL; a machine does not use it, for the
same reason a machine does not follow stackyard's `latest`: code that runs on a
client's host is the version someone chose.
