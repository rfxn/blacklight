# legacy-os-pitfalls — keeping authored shell within the substrate floor

Loaded by the router when `substrate-report` names an `os.id` matching `centos6 | rhel6 | ubuntu1204 | ubuntu1404`, or when the curator authors shell for any `clean.*` or `defend.*` step. The pitch reads "compatible from CentOS 6 (2011) through modern distros." This bundle keeps the emit honoring that floor.

## The lived failure this prevents

The curator authors `bl clean cron --user $u` whose body uses `mapfile -d '' lines < <(crontab -u "$u" -l)`. Substrate named the host as CentOS 6, `bash.version=4.1.2`. `mapfile -d` is a bash 4.4 feature; the script parse-fails before any cron content reads. The case stalls in `pending` while the operator chases a syntax error.

## Three classes of pitfall, three files

- `pre-usr-merge-coreutils.md` — pre-`/usr`-merge hosts keep `cp`, `mv`, `rm`, `cat`, `chmod`, `mkdir`, `touch`, `ln` at `/bin/`. `command <util>` resolves portably.
- `no-systemd-no-journal.md` — no `systemctl`, no `journalctl`. Service control is `service` + `chkconfig`; logs sit at `/var/log/secure`, `/var/log/messages`, `/var/log/auth.log`.
- `bash-4.1-floor-features.md` — CentOS 6 ships bash 4.1.2. Idioms from 4.2 / 4.3 / 4.4 / 5.0 parse-fail. NEWS-cited intro versions and per-idiom workarounds live in that file.

## Routing

```
IF substrate.os.id IN {centos6, rhel6, ubuntu1204, ubuntu1404}
   OR authoring shell for any clean.* / defend.* step
  → load SKILL.md + three sister files

IF substrate.os.usrmerge = false → pre-usr-merge-coreutils.md binding
IF substrate.init.system IN {sysvinit, upstart} → no-systemd-no-journal.md binding
IF substrate.bash.version < 4.2 → bash-4.1-floor-features.md binding
```

The bash-4.1-floor file loads with the whole bundle — a patch that parses on Rocky 9 but uses a 5.0 idiom breaks the next time it lands on 4.1.

Cross: `defense-synthesis/firewall-rules.md` (no-systemd `defend firewall` emits `service iptables save`, not `systemctl reload firewalld`); project `CLAUDE.md` "Bash 4.1+ Floor (CentOS 6)" section as canonical project-internal authority.

<!-- public-source authored — extend with operator-specific addenda below -->
