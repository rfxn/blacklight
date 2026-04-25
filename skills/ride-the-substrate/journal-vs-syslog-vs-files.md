# journal-vs-syslog-vs-files — log surface divergence

Loaded by the router when any `bl observe log` verb is pending, or when the curator's hypothesis turns on a time-windowed log read. This file is the lookup of where the answer lives, gated by substrate. Pairs with `enumeration-before-action.md` (the why, applied to logs) and feeds `linux-forensics/apache-transfer-log.md`, `linux-forensics/maldet-session-log.md`, and the cPanel WHM-side log paths in `hosting-stack/cpanel-anatomy.md` §`/usr/local/cpanel/`.

## The 03:14 question

The case needs "what did sshd log between 03:14 and 03:42 last Tuesday." On Debian 12: `journalctl -u ssh.service --since '2026-04-22 03:14' --until '2026-04-22 03:42'`. On CentOS 7 + rsyslog: `/var/log/secure`. On CentOS 6: `/var/log/secure` *plus* knowing `journalctl` does not exist. On cPanel: *both* `/var/log/secure` (system sshd) *and* `/usr/local/cpanel/logs/login_log` (cPanel/WHM/Webmail UI logins). The same observable question produces a different command on each substrate, and the wrong substrate produces an empty result that looks like "no activity" when it is actually "wrong file."

## Three rules that bind every log read

**1. `journalctl` may exist but not contain what you need.** systemd's journal can be configured `Storage=volatile` (RAM-only), `Storage=auto` (volatile until `/var/log/journal/` exists, persistent after), or `Storage=persistent`. On `volatile`, reboots erase history; on `auto` without the journal directory present, the same. The substrate read must verify both: `journalctl --disk-usage` (returns `0B` on volatile) and the `Storage=` directive in `/etc/systemd/journald.conf` plus drop-ins under `/etc/systemd/journald.conf.d/`. Upstream docs: `https://www.freedesktop.org/software/systemd/man/journald.conf.html`.

A second pitfall: even with persistent storage, `SystemMaxUse=` and `MaxRetentionSec=` may have rotated the case's window out of existence. The substrate report emits the journal's effective coverage window, not just `journal=present`.

**2. Shared-hosting layers shadow the system log path.** On cPanel, sshd login attempts land in `/var/log/secure` (RHEL) or `/var/log/auth.log` (Debian) *and* WHM/cPanel UI / Webmail login attempts land in `/usr/local/cpanel/logs/login_log` — both authoritative for different attack vectors. The curator that reads only the system path misses the WHM-side compromise window. cPanel publishes the layout at `https://api.docs.cpanel.net/`; the file is named in `hosting-stack/cpanel-anatomy.md` §`/usr/local/cpanel/` — cross-read whenever substrate flags `hosting_layer=cpanel`.

The same shadowing pattern applies to other shared-hosting layers per platform. The substrate read does not assume "system log + done"; it enumerates per-subsystem log surface (sshd, sudo, cron, web access, web error, MTA, FTP) where each names its own path.

**3. The "log path" answer is the substrate report's most volatile field.** Vendor packaging differences move things: `/var/log/messages` on RHEL, `/var/log/syslog` on Debian, neither on a journald-only Debian 12 install. `/var/log/secure` vs `/var/log/auth.log` for sshd. `/var/log/cron` on RHEL, cron events on Debian in `/var/log/syslog` or the journal. The report emits *which path* per *which subsystem*, not a top-level "messages.log."

Public references:

- Debian Policy Manual `/var/log/` layout: `https://www.debian.org/doc/debian-policy/ch-opersys.html#log-files`.
- rsyslog upstream docs (covers `/var/log/secure` on RHEL): `https://www.rsyslog.com/doc/`.
- systemd-journald (`Storage=`, `SystemMaxUse=`, `MaxRetentionSec=`): `https://www.freedesktop.org/software/systemd/man/journald.conf.html`.
- cPanel UI log paths: `https://api.docs.cpanel.net/`.

## Failure mode named

A curator runs `bl observe log journal --since 2026-04-22T03:14 --until 2026-04-22T03:42 --unit ssh.service` on a CentOS 6 host. The verb fails with `journalctl: command not found`. The case stalls until the operator hand-redirects to `/var/log/secure`. Worse: same verb on a CentOS 7 host with journald + `Storage=volatile` returns empty (the host rebooted Tuesday morning), and the curator concludes "no sshd activity" when the actual activity is in `/var/log/secure` (rsyslog still writes to disk regardless of journald storage mode).

The substrate read prevents the path. `bl observe log` binds to a precondition: log surface = `journal | syslog | files | mixed`, with file paths enumerated per subsystem. When `log_surface=journal`, the report carries `journal.storage`, `journal.disk_usage`, `journal.effective_window`. When `log_surface=mixed` (cPanel + journald), every authoritative path is enumerated. The curator chooses `bl observe log journal`, `bl observe log syslog`, or `bl observe log file <path>` with a path that actually contains the data.

## Cross-references

- `enumeration-before-action.md` — bundle spine, log-specialized here.
- `linux-forensics/apache-transfer-log.md` — Apache log surface.
- `linux-forensics/maldet-session-log.md` — LMD session log surface.
- `hosting-stack/cpanel-anatomy.md` §`/usr/local/cpanel/` — cPanel/WHM log paths.

<!-- public-source authored — extend with operator-specific addenda below -->
