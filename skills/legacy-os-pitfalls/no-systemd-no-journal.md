# no-systemd-no-journal — service control and log paths on sysvinit / upstart hosts

Loaded by the router when `substrate-report.init.system` is `sysvinit` or `upstart`, and whenever the curator authors `bl observe log journal` content. CentOS 6 / RHEL 6 ship sysvinit; Ubuntu 12.04 and 14.04 ship upstart. Neither has `systemctl`, `journalctl`, or `loginctl`. Service control is `service` + `chkconfig`; logs are file-based at predictable paths.

## The lived failure

The curator emits `bl observe log journal --since '2 hours ago' --grep sshd`. Substrate has named the host as CentOS 6 with rsyslog and sysvinit. `journalctl` is not installed; the verb fails at exec. The actual log path the case needs is `/var/log/secure` — `awk '/sshd/' /var/log/secure` returns the auth events directly. The substrate-read should have caught this; this skill is what the substrate report routes the curator to read when it does.

## Service control without systemd

`systemctl status ssh.service` is the post-systemd idiom. On RHEL 6 and Ubuntu 14.04, the equivalent is SysV-RC:

```bash
service sshd status              # RHEL family — query / restart with 'restart'
chkconfig sshd on                # RHEL family — enable at boot
chkconfig --list sshd            # RHEL family — runlevel matrix

service ssh status               # Debian / Ubuntu
update-rc.d ssh defaults         # Debian / Ubuntu — enable at boot
```

Service names differ by family: RHEL ships `sshd`, Debian ships `ssh`. The curator's `bl run` should normalize via substrate-report's `services.*` map rather than hardcoding either.

Upstart (Ubuntu 12.04 / 14.04) has `initctl` as the native surface, but the SysV-RC compat layer (`service`, `/etc/init.d/`) covers everything that ships SysV scripts. Reference: Red Hat Enterprise Linux 6 Deployment Guide (https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/6/) chapter on services and runlevels.

## File-based log paths

The authoritative log paths on no-systemd hosts are file-based, predictable, and mostly the same across distros:

- `/var/log/messages` (RHEL family) or `/var/log/syslog` (Debian family) — general system log.
- `/var/log/secure` (RHEL family) or `/var/log/auth.log` (Debian family) — sshd, sudo, su, PAM auth events.
- `/var/log/cron` (RHEL family) or entries in `/var/log/syslog` (Debian family) — cron daemon activity.
- `/var/log/maillog` (RHEL family) or `/var/log/mail.log` (Debian family) — local MTA delivery.
- `/var/log/httpd/{access,error}_log` (RHEL family) or `/var/log/apache2/{access,error}.log` (Debian family) — Apache.
- `/var/log/yum.log` (RHEL 6) or `/var/log/dpkg.log` + `/var/log/apt/history.log` (Debian family) — package transactions.

The substrate-read enumerates these per-subsystem and writes `logs.<subsystem>.path` into the substrate-report. The curator's emit reads them with `awk` or `grep`, never `journalctl`:

```bash
awk -v start="$start" -v end="$end" \
    '/sshd/ && $0 >= start && $0 <= end' /var/log/secure
```

Custom rsyslog rules (`/etc/rsyslog.d/*.conf`) shift paths in ~5% of cases — the substrate-read records `rsyslog.custom_paths` for those.

## auditd may not be running

Hosts with systemd often have `auditd` running by default, sometimes via SELinux's policy. CentOS 6 ships `auditd` but it is commonly disabled on hosting fleets to reduce I/O — a tenant making thousands of file opens per second floods `/var/log/audit/audit.log` and crowds out useful events. The curator must not assume `auditctl -s` returns auditing-enabled state on a 4.1-floor host. Reference: `auditctl(8)` and `auditd(8)` man pages.

When `auditd` is off, substitute `last`/`lastlog` for login records (reads `/var/log/wtmp` and `/var/log/btmp`), `/var/log/secure` or `/var/log/auth.log` for sudo/su transitions, and the application's own log for the rest.

## Failure mode named, with mitigation

**Failure:** curator emits `journalctl -u ssh.service --since '2 hours ago'` on CentOS 6. Step fails at exec; case sits in `pending`.

**Mitigation:** `SKILL.md` loads on substrate-report `init.system=sysvinit|upstart`. The curator's authored step uses `awk '/sshd/' /var/log/secure` instead. `bl observe log`'s substrate-aware mode dispatches to file-based paths automatically when init is not `systemd`.

## Cross-references

- `pre-usr-merge-coreutils.md`, `bash-4.1-floor-features.md` — sister floor rules.
- `linux-forensics/apache-transfer-log.md` — Apache log path patterns survive the systemd / no-systemd split (the file paths shift but the parsing rules carry over).
- Debian Wiki on init system history (https://wiki.debian.org/Debate/initsystem) for cross-family service-name conventions.

<!-- public-source authored — extend with operator-specific addenda below -->
