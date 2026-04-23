# hosting-stack — CloudLinux CageFS and LVE quirks

Loaded by the router when the host indicates a CloudLinux platform (`/var/cagefs/` or `/var/lve/` present). Pairs with `cpanel-anatomy.md` for the broader cPanel-managed-hosting layout; this file adds the CloudLinux-specific quirks that change how a responder reads filesystem and process evidence on LVE hosts.

Authoritative references: CloudLinux documentation at `docs.cloudlinux.com` — the CageFS section (`docs.cloudlinux.com/shared/cagefs/`), the LVE Manager section (`docs.cloudlinux.com/lve_manager/`), the PHP Selector section (`docs.cloudlinux.com/shared/cloudlinux_php_selector/`), and the MySQL Governor section (`docs.cloudlinux.com/shared/mysql_governor/`). The quirks described below are sourced from these references; operator-specific tuning belongs below the footer marker.

---

## CageFS virtual namespace

CageFS is a per-user virtualized filesystem. Each tenant sees a private namespace assembled from a shared read-only base plus bind-mounts of their own `/home/<user>/`, `/tmp/`, `/var/tmp/`, and selected system directories. From inside the cage, the tenant's filesystem view is small — most of `/etc/`, `/var/`, `/usr/local/cpanel/` is not visible at all, and system users other than the tenant do not appear in `/etc/passwd`.

Layout on the host (outside the cage):

- `/var/cagefs/<0-9>/<user>/` — per-user cage root. The `<0-9>` is a hash-bucket prefix; `<user>` is the cPanel account name. Inside this tree the tenant's private view of `/etc/`, `/var/`, and friends is assembled.
- `/etc/cagefs/` — CageFS configuration. `cagefs.mp` (mount-point list), `conf/` (per-exception configs), `exclude/` (files hidden from the cage).
- `/usr/sbin/cagefs{ctl,enter,exit_all,update}` — CageFS management binaries. `cagefsctl --force-update` rebuilds all user cages; `cagefsctl --remount-all` reapplies mount points.

Evidence reading implication: when triaging a suspected webshell, a `find /` as root walks the host view (every user's real filesystem). A `find /` from inside the tenant shell via `cagefs_enter_user <user>` walks the cage view only. The difference is load-bearing: files that exist in the cage but not the host view are artifacts of the cage layering (usually benign); files in the host view but not the cage view are either cage-excluded or point to a cage-escape condition worth investigating.

---

## suEXEC, PHP Selector, and mod_lsapi

CloudLinux replaces the stock Apache PHP handler with mod_lsapi on most deployments and ships PHP Selector for per-user version choice.

- **PHP Selector** — each account picks a PHP version from the installed alt-php set: `/opt/alt/php<NN>/` (where `<NN>` is `74`, `81`, `82`, etc.). The account's selected version is stored in `/var/cagefs/etc/cl.selector/defaults.cfg` per user. Changing the version reloads the PHP-FPM pool for that account only.
- **mod_lsapi** — LiteSpeed API connector running inside the cage. Process view in `ps` shows `lsphp` processes with the tenant user as owner. The binary path inside `ps` output is the cage-local view (e.g., `/usr/bin/lsphp`) even though the binary on the host is under `/opt/alt/php<NN>/usr/bin/lsphp`.
- **suEXEC fallback** — present when mod_lsapi is not the configured handler. PHP runs via CGI wrapper with the account UID. Same process-ownership semantics.

File-write attribution: every file a PHP process writes lands with the tenant's UID/GID. A file owned by `apache:apache` or `nobody:nogroup` under `/home/<user>/` on a CloudLinux host is an anomaly — the standard handler paths don't produce that ownership.

---

## LVE faults and limit hits

Lightweight Virtual Environment (LVE) is the kernel-level cgroup layer that enforces per-user CPU, memory, IO, and concurrent-process limits. When a tenant exceeds a limit, the kernel logs a fault and either throttles or kills the offending process.

Evidence surfaces:

- `/var/log/messages` — kernel LVE events. Signatures:
  - `lve_enter[<UID>]: enter user=<UID> lve=<UID>` — normal entry, not a fault.
  - `lve[<UID>]: fault=<type>` — a limit breach. `<type>` is one of `CPU`, `IO`, `MEM`, `NPROC`, `EP` (entry-process count), `IOPS`.
  - `kernel: LVE <UID> Killed process <PID>` — OOM-like kill for memory overrun.
- `/var/log/lve-stats/` — lve-stats daemon aggregates. Per-hour and per-day rollups of faults, CPU, memory, IO.
- `lveinfo --period=<N>d --user=<user>` — CLI query for the account's historical resource profile.
- `lvetop` — live, top-like view of per-user resource use.

Corroborating signal: a burst of LVE faults clustered in the same window as suspect access-log activity points at the tenant running something heavy. The typical webshell shape — a mining loader invoked per request — shows as sustained 100% CPU-fault hits for the tenant's UID across a window matching the suspect window. A credential-harvester shows low CPU but elevated IO (file writes to the harvest output).

---

## Per-user MySQL via Governor

MySQL Governor monitors per-user MySQL query cost and throttles heavy users without affecting the whole server.

- `/var/lve/dbgovernor-store/` — per-user query-runtime state. Files named `<user>.log` or `<user>.stats`.
- `/var/log/dbgovernor-mysql.log` — governor's own log. Throttle events, restarts, config reloads.
- `dbtop` — live view of per-user MySQL load.
- `/etc/container/mysql-governor.xml` — config. Per-user limits defined here as `<limit name="cpu" current="30" short="50" mid="70" long="90"/>` style blocks.

For a suspected SQL-injection or credential-exfil incident, governor logs answer two questions: was there an unusual burst of query activity from the tenant during the suspect window, and what queries were in flight when throttling kicked in? The governor logs carry the query text (truncated) — a `SELECT password_hash FROM admin_user` query appearing in the throttled set is load-bearing evidence.

---

## The attacker view from inside the cage

An attacker who lands RCE inside a cage sees a restricted namespace:

- `/proc/` shows only the tenant's own processes. Other tenants are invisible; system processes are invisible.
- `/etc/passwd` shows only the tenant and a small allowlist of system accounts (root, nobody, and a few cPanel helpers). The other tenants' `/etc/passwd` entries are not present.
- System binaries under `/usr/bin/` and `/usr/sbin/` are a reduced set. `/etc/cagefs/conf/` whitelists the exposed binaries per group. Binaries not whitelisted are absent from the cage namespace.
- Most of `/var/` is private to the tenant (their own mail, their own logs) or absent.
- Outbound network is whatever the host's firewall permits; CageFS does not filter network. See `apf-grammar/basics.md:17-19` for egress-filtering posture.

Escape attempts — attempts to reach outside the cage — show up as EPERM denials in strace against `chroot`, `unshare`, `mount`, and a few other syscalls. The kernel module blocks these at syscall time; audit records them. A cage-escape attempt observed in `audit.log` is a system-level finding, not a tenant finding.

---

## Triage checklist for CloudLinux hosts

When the host is confirmed CloudLinux:

1. **Correlate LVE faults to the suspect window.** `lveinfo --period=<window> --user=<tenant>` against the access-log suspect window. Sustained faults confirm active execution during the window.
2. **Read UID mapping in file ownership.** `find <docroot> -newer <reference> -printf '%u %p\n'`. Tenant UID confirms tenant-scoped activity; other UIDs are anomalies worth explaining.
3. **Cross-check process owner in the suspect window.** Apache access log plus governor/lve logs give concurrent tenant process activity. A webshell invocation shows as `lsphp` with the tenant UID running during the matching `POST`.
4. **Baseline the cage.** `cagefsctl --list-users` enumerates which accounts have active cages. `cagefsctl --display-user-mode <user>` reports whether the tenant is in CageFS (`Enabled`) or not (`Disabled`). A tenant running outside the cage on a CloudLinux host is a misconfiguration that widens blast radius — flag this before proceeding.
5. **Pull governor records for the suspect MySQL user.** `/var/lve/dbgovernor-store/<user>.log` gives the per-tenant query profile. Anomalies here corroborate or refute credential-harvest and injection claims.

The case-engine evidence row should cite `/var/log/messages` LVE-fault lines by byte offset, `lveinfo` output as a captured JSON blob, and the `cagefsctl --display-user-mode` result as a one-line attribution. See `ir-playbook/case-lifecycle.md` on evidence-row discipline.

---

## When CloudLinux is present but not configured

Two partial-deployment states change the reading:

- **CloudLinux kernel installed but CageFS disabled for some accounts.** `cagefsctl --display-user-mode <user>` reports `Disabled`. These accounts run in the stock cPanel posture — no cage isolation — and `/home/<other-user>/` trees are visible to their PHP processes if POSIX perms allow. Lateral-movement risk is higher for these accounts.
- **CloudLinux installed but LVE limits set to zero or unlimited.** `lvectl list` shows `CPU=0 IO=0 MEM=0` for some tenants (meaning unlimited on this platform). LVE faults do not surface even under sustained abuse. The case engine must not rely on LVE-fault absence as evidence of benign activity for these accounts.

Both conditions are operator-owned misconfigurations rather than forensic anomalies per se, but they change what evidence is available. The triage checklist above should record the deployment posture as a preliminary observation before reading per-tenant evidence.

<!-- public-source authored — extend with operator-specific addenda below -->
