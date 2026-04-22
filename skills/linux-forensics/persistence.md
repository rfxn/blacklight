# linux-forensics — persistence patterns after web-shell access

Loaded by the router when cron, systemd, or shell-init artifacts have moved inside the investigation window. The web-shell itself is the entry; persistence is what survives a reboot, a `php-fpm` restart, or a customer-side cleanup pass that only deletes the visible dropper. This file is the lookup of where to check, what shape attacker insertion takes versus legitimate sysadmin work, and the time-stamp signals that separate the two.

## Cron — the low-effort default

Attacker cron entries land in five places. Check all five; do not stop after the first hit.

- `/etc/crontab` — system-wide, runs as the user named in column six. A new line with `root` in column six and a non-package path in column seven is load-bearing.
- `/etc/cron.d/*` — drop-in directory, same five-field-plus-user-plus-command grammar as `/etc/crontab`. Filenames matter: `0logrotate`, `awstats`, `php` are common mimicry. A drop-in owned by a non-root user, or one with no matching package owner (`rpm -qf` / `dpkg -S` returns "not owned"), is the tell.
- `/etc/cron.{hourly,daily,weekly,monthly}/*` — script-style, no schedule field. Run as root by `run-parts`. Same package-ownership check applies.
- `/var/spool/cron/{crontabs/}*` — per-user crontabs. Path varies: `/var/spool/cron/<user>` on RHEL-family, `/var/spool/cron/crontabs/<user>` on Debian-family. The `<user>` filename must match an existing UID; orphan files (user removed, crontab survived) are common attacker drops because they execute under the original UID until the file is found.
- `/var/spool/anacron/` and `/etc/anacrontab` — anacron entries fire on machines that aren't on 24/7. Less common as an attacker vector but worth checking on workstations and dev hosts.

Distinguishing attacker insertion from sysadmin work:

- **Comment density.** Sysadmin cron entries usually carry a one-line comment naming the purpose; attacker entries are bare.
- **Command shape.** Sysadmin work calls a script in `/usr/local/bin`, `/opt/<vendor>`, or a package-owned path. Attacker entries call `curl|sh`, `wget -O- | bash`, base64-decoded one-liners, or a script under `/tmp`, `/var/tmp`, `/dev/shm`, `/home/<user>/.cache`.
- **Schedule shape.** Hourly-or-faster schedules (`*/5 * * * *`, `@reboot`) on an unowned script are an attacker tell. Sysadmin cron is usually daily-or-slower.
- **mtime/ctime divergence.** Legitimate cron files have mtime and ctime within seconds of each other (created once, edited once). An attacker who used `touch -r` to copy a reference timestamp leaves mtime matching the reference but ctime at the actual write moment. `stat -c '%Y %Z %n'` makes the divergence visible — any cron file where ctime is significantly later than mtime warrants explanation.

## systemd units

Persistence via systemd is more durable than cron and harder for a customer-side cleanup to spot.

- `/etc/systemd/system/*.service` and `/etc/systemd/system/*.timer` — operator-installed units. Inspect `[Service] ExecStart=` and `[Install] WantedBy=`. A unit with `WantedBy=multi-user.target` is enabled at boot; `WantedBy=default.target` enables for the user-level manager.
- `/etc/systemd/system/multi-user.target.wants/` and `/etc/systemd/system/timers.target.wants/` — symlink directories that mark which units are enabled. A symlink here whose target is a unit file outside `/usr/lib/systemd/system` should be justified.
- `/usr/lib/systemd/system/*` — package-owned units. New files here without a package owner are a tampering signal.
- `~/.config/systemd/user/*` — per-user units. Run by the user's `systemd --user` instance. Easy to miss because most fleet inventories only check system-level units. Combined with `loginctl enable-linger <user>`, a per-user unit runs even when the user is not logged in.

Distinguishing markers for attacker units:

- `Description=` field is generic, missing, or copied from a real package (mimicry).
- `ExecStart=` invokes a shell or interpreter against a script in a writable directory (`/tmp`, `/var/tmp`, `/home/<user>/.cache`, `/dev/shm`) or against a base64-decoded inline payload.
- The unit was placed by writing a file plus running `systemctl enable`, but the operator's configuration management has no record of it. `systemctl list-unit-files --state=enabled | xargs -I{} rpm -qf /usr/lib/systemd/system/{}` (or the dpkg equivalent) surfaces enabled units with no package owner.
- Timer units paired with a service unit of the same basename are the most common scheduled-execution shape; check both files together.

## Init survivors and rc.local

`/etc/rc.local` is deprecated on systemd distros but still executed by `rc-local.service` when present, which is shipped on most stock images. A non-empty `/etc/rc.local` with anything other than the distro's stock comment-only template is worth a read.

`/etc/init.d/*` survives on legacy hosts (CentOS 6, Slackware, older Gentoo) and is occasionally still used as an attacker drop on systemd hosts because `systemd-sysv-generator` will execute SysV scripts at boot.

`/etc/profile.d/*.sh` runs at login for every user. A new script here that touches the network or writes to a non-standard path is rare in sysadmin work and common in attacker persistence.

## Shell-init hijacks

Per-user shell init files are the lowest-blast-radius persistence — only fires when that specific user logs in, but invisible to a `systemctl`-centric audit.

- `~/.bashrc`, `~/.bash_profile`, `~/.bash_login`, `~/.profile` — bash startup chain. New `alias` definitions that wrap `ls`, `cat`, `ps`, or `netstat` to filter attacker artifacts are a known pattern. Function definitions named after common commands (`function ls() { ... }`) override the binary in PATH for that user.
- `~/.zshrc`, `~/.zprofile`, `~/.zshenv` — zsh equivalents. `~/.zshenv` is loaded for every zsh invocation including non-interactive, which makes it the highest-leverage zsh init file.
- `~/.bash_logout` — runs at logout. Used for "leave-no-trace" cleanup that wipes session history.
- `/etc/profile`, `/etc/profile.d/`, `/etc/bash.bashrc` — system-wide shell init. Modifications here affect every user.

Compare the user's init files against a known-clean reference (a fresh user account on the same image, or a backup snapshot from before the suspected entry date). Diff drives the read; raw content rarely tells the story without a baseline.

## LD_PRELOAD via /etc/ld.so.preload

`/etc/ld.so.preload` lists shared objects that are loaded into every dynamically-linked binary the loader runs. A non-empty `/etc/ld.so.preload` on a host that has not deliberately deployed a preload library (LD-based observability tools, license shims) is a high-confidence rootkit indicator. The library named in the file is usually placed in `/usr/lib64/`, `/usr/local/lib/`, or `/lib/` with a name that mimics a system library.

Checks:

- File should be empty or absent on stock systems. `stat /etc/ld.so.preload` returning `No such file or directory` is the expected state.
- If the file is present, every line names a `.so` path. Each path must resolve, and each `.so` must have a package owner. Orphan `.so` files are the failure mode.
- A recently-modified `/etc/ld.so.preload` on an otherwise stable host is an alert by itself, regardless of contents.

## MOTD and update-motd.d

`/etc/update-motd.d/*` (Debian/Ubuntu) executes scripts at login to generate the dynamic message-of-the-day. A new script here runs as root for every interactive SSH login. `/etc/motd` itself is static text and not directly executable, but `pam_motd.so` invokes the update-motd.d scripts.

Same shape rule as cron drops: new script, no package owner, references a network path or a writable directory in its body.

## Package-manager hooks

Both `dpkg` and `rpm` support per-transaction hooks that run with elevated privilege. These are uncommon attacker territory but high-impact when they appear.

- Debian: `/etc/apt/apt.conf.d/*` lines beginning with `DPkg::Pre-Invoke`, `DPkg::Post-Invoke`, `APT::Update::Pre-Invoke`. Also `/etc/dpkg/dpkg.cfg.d/*`.
- RHEL-family: `/etc/yum/pluginconf.d/*` and the corresponding plugin python files in `/usr/lib/yum-plugins/`. On dnf-based systems, `/etc/dnf/plugins/*` and `/usr/lib/python*/site-packages/dnf-plugins/`.

A drop here means the attacker fires their payload every time the operator runs a package operation — including the cleanup operation. Worth checking before running any post-incident `apt update` or `dnf update`.

## Web-server includes — auto_prepend_file and pool overrides

The web-server execution context is its own persistence surface, separate from system init.

- `.htaccess` directives `php_value auto_prepend_file` and `php_value auto_append_file` cause an arbitrary PHP file to load before/after every request handled by the directory. A `.htaccess` in a customer document root that names an `auto_prepend_file` outside the document root (or to a hidden file inside) is a webshell loader pattern.
- PHP-FPM pool overrides under `/etc/php/<ver>/fpm/pool.d/` or `/etc/php-fpm.d/`. A new pool, or a `php_admin_value[auto_prepend_file]` line in an existing pool, achieves the same loading without touching the customer's `.htaccess`.
- Apache `Include` directives under `/etc/httpd/conf.d/` or `/etc/apache2/conf-enabled/` that pull in attacker-controlled snippets. Look for include targets that resolve to writable directories.
- nginx `include` directives in server blocks pulling from `/etc/nginx/conf.d/` — same shape, different web server.

The auto_prepend_file pattern is especially load-bearing because it survives the deletion of the visible dropper: cleanup removes `shell.php` from the document root, but the `.htaccess` directive points at a backup loader the operator never saw, and the loader re-creates the dropper on the next request.

## mtime / ctime as triage signals

Persistence triage hinges on three timestamps and the relationships between them:

- **mtime** — last content write. Adjustable with `touch -t` and `touch -r`.
- **ctime** — last inode change (content, ownership, permissions, link count). Not adjustable from userland. A `chown` or `chmod` updates ctime without touching mtime.
- **atime** — last read access. Often disabled (`noatime` mount option) on production hosts; not reliable.

Decision shapes:

- ctime later than mtime by minutes or more on a file claimed to be old is the `touch -r` signal — the attacker reset mtime to mimic neighbors but could not touch ctime.
- A cluster of unrelated files across `/etc/`, `/var/spool/cron/`, `/etc/systemd/system/`, and a document root all sharing an mtime within a few-minute window is a deployment cadence — the attacker scripted the persistence in one batch.
- Compare suspect file mtimes against the `rpm -V` / `debsums` baseline. Stock package files that have been modified out-of-band are the highest-confidence persistence signal short of catching the payload firing.

## What to capture, not just check

When triage finds a persistence artifact, the evidence row should record: full path, owner+group, mode, mtime, ctime, package owner (or `unowned`), the exact command line or `ExecStart` value, and the SHA-256 of the artifact. The artifact itself goes into evidence storage by hash so the case file can cite it across hosts and the synthesizer can pattern-match across cases.

<!-- public-source authored — extend with operator-specific addenda below -->
