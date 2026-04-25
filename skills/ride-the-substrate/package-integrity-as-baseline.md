# package-integrity-as-baseline — `rpm -V` / `dpkg --verify` is the cheapest tamper detector

Loaded by the router when the curator is constructing a system-wide tampering hypothesis (multi-path mtime cluster, `linux-forensics/persistence.md` already loaded), or when substrate flags `package_manager = {rpm | dpkg}` and the curator is asked "is this host clean." Pairs with `enumeration-before-action.md` and closes the loop on `linux-forensics/persistence.md`.

## The cheapest sweep on the host

The cheapest persistence sweep on any RPM host is `rpm -V <pkg>` or `rpm -Va`. On any DEB host: `dpkg --verify`, or `debsums -c` when `debsums` is installed. Both compare on-disk state to the package baseline (md5sum, mode, owner, group, mtime, capabilities) and have shipped since the early 2000s — though they are disabled in most distros' update cron, so most operators forget they exist. The skill is the rule for when the baseline is load-bearing (drift on system paths) versus noise (admin edits to `/etc/`).

## Three rules that bind the integrity sweep

**1. `rpm -V` flag `5` (md5 mismatch) on `/etc/` files is expected and ignorable; flag `5` on `/usr/sbin/`, `/usr/bin/`, `/usr/lib*/`, `/lib*/` is the load-bearing tell.** Admin work edits config; admin work does not legitimately edit shipped binaries. Flag glossary from `rpm(8)`:

```
S Size differs       D Device major/minor mismatch
M Mode differs       L readLink path mismatch
5 digest (md5)       U/G/T User/Group/mtime differs
P caPabilities       c marks a configuration file
```

Path-scoped filter that converts a noisy `rpm -Va` into a high-signal one: drop lines under `/etc/`, `/var/`, `/srv/`, `/home/`; keep lines under `/usr/bin/`, `/usr/sbin/`, `/usr/lib*/`, `/lib*/`, `/bin/`, `/sbin/`. The kept lines are the candidate tampering signal.

**2. `debsums` is not installed by default on most Debian images.** When present, `debsums -c` checks every file against its shipped md5sum (`debsums(1)`). When absent, the equivalent is `dpkg --verify` (`dpkg(1)`), with narrower coverage — md5sums only, no separate symlink/owner/perm checks. The substrate read prefers `debsums` when present; otherwise falls back to `dpkg --verify` and notes reduced coverage in the case ledger. References: `dpkg(1)` §`--verify`; `debsums(1)`; `https://packages.debian.org/debsums`.

**3. The integrity baseline is also the cheapest detection of `/etc/ld.so.preload` and `/etc/cron.d/` tampering.** `linux-forensics/persistence.md` names these as adversary persistence sites; the integrity skill closes the loop — *one command checks them all*. `/etc/ld.so.preload` is package-owned on most distros (`rpm -qf` returns `glibc-common`; `dpkg -S` returns `libc6`). A non-package version, or a package version with flag `5`, is the tampering signal. Same cross-check applies to package-owned cron drop-ins, systemd units under `/usr/lib/systemd/system/`, and shell init under `/etc/profile.d/`. References: `rpm(8)` §`-V`; Red Hat docs `https://access.redhat.com/documentation/`.

## Failure mode named

A curator skips the integrity sweep because "the last `yum update` was 4 months ago; the baseline is stale." The skill rebuts: a stale baseline is *more* useful for tamper detection — every legitimate change has had four months to settle, so new mismatches are high-signal. The risk is false-negatives on packages updated post-baseline. Workaround: filter `rpm -V` output to packages whose `rpm -qi | grep "Install Date"` predates the suspect mtime cluster. Any flag `5` on a binary in such a package is unambiguously load-bearing.

## Cross-references

- `enumeration-before-action.md` — bundle spine, integrity-tooling specialized here.
- `linux-forensics/persistence.md` — persistence sites this skill verifies.
- `linux-forensics/maldet-session-log.md` — LMD is the slow scanner; package-integrity is the fast pre-filter.

<!-- public-source authored — extend with operator-specific addenda below -->
