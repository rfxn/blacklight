# false-positives — backup and archive artifact patterns

Loaded alongside `vendor-tree-allowlist.md` when a flagged file is suspected to be a backup or archive rather than an attacker artifact. This file is the lookup of *which filename + path + owner signatures mark a file as benign backup content* and *what properties distinguish a legitimate backup from an attacker using backup-looking filenames for cover*.

Authoritative references: cPanel Backup documentation (`docs.cpanel.net/cpanel/files/backup/`); UpdraftPlus user documentation (`updraftplus.com/documentation/`); BackupBuddy plugin documentation (`ithemes.com/docs/backupbuddy`); `logrotate(8)` and `mysqldump(1)` man pages from the util-linux and mysql-client source trees. Every pattern below traces back to one of these sources; operator-specific addenda belong below the footer.

---

## Common suffixes

Editor and system conventions produce a small, closed vocabulary of backup-suffixed files:

- `*.bak` — generic "previous version kept". Emitted by most package managers on config edits (e.g., `rpmsave`, `dpkg-old` variants), by WordPress auto-updates, by manual operator copies.
- `*.old`, `*.orig` — same class. `*.orig` is the `patch(1)` convention when patching with `-b`.
- `*.sav` — less common; legacy editor save.
- `*~` — Emacs auto-save. Drops a tilde-suffixed copy alongside the edited file.
- `*.swp`, `*.swo` — vim swap files. Present while vim is open or after a crash. Prefix is `.` (hidden): `.index.php.swp`.
- `*.tmp` — half-written copy; produced by atomic-write patterns that rename `<file>.tmp` to `<file>` on completion.
- `*-old`, `*-backup`, `*-YYYYMMDD` — operator-added stems. No format standard; grep the parent directory for siblings.

Suffix alone is not conclusive. A file named `wp-config.php.bak` in a docroot still reads as a credential leak if its contents match the live `wp-config.php`; the allowlist applies to the hunter, not to the access-control posture.

---

## cPanel backup wheels

cPanel generates per-account tarballs on scheduled or on-demand backups. The default output locations (`docs.cpanel.net`):

- `/home/<user>/backup-<date>-<user>.tar.gz` — full account backup. `<date>` in the tarball name is `YYYY-MM-DD_HH-MM-SS` format.
- `/home/<user>/backups/` — alternate output directory configurable via the Backup Configuration screen in WHM.
- `/backup/` or `/backup/<date>/accounts/<user>.tar.gz` — system-level scheduled backups; owned by `root:root`.
- `/home/<user>/.cpanel/caches/backup-*.cache` — metadata caches; small, benign, regenerated on each run.

File ownership signatures:

- `/home/<user>/backup-*.tar.gz` — owned by `<user>:<user>` because cPanel drops the file as the account user.
- `/backup/**/*.tar.gz` — owned by `root:root` because the scheduled backup runs as root.

An attacker using backup-like naming typically drops into a writable subdir (`pub/media/`, `wp-content/uploads/`) with the web-user ownership, not into `/home/<user>/` at the tenant root. Ownership + parent directory are the two load-bearing tells.

---

## WordPress backup-plugin artifacts

Three dominant plugins produce the bulk of WordPress backup files in the wild:

- **UpdraftPlus** — writes to `wp-content/updraft/` by default. File naming: `backup_YYYY-MM-DD-HHMM_<sitename>_<hash>-<class>.zip|gz|tar.gz` where `<class>` is one of `db`, `plugins`, `themes`, `uploads`, `others`. The hash is stable per site.
- **BackupBuddy** — writes to `wp-content/uploads/backupbuddy_backups/` by default, sometimes relocated to `wp-content/uploads/backupbuddy/`. File naming: `backup-<sitename>-YYYY_MM_DD-HHMMSS-<type>.zip`.
- **VaultPress / Jetpack Backup** — uploads offsite; on-disk footprint is minimal. A `.vaultpress-options.php` in the plugin directory is the only steady-state marker.

Out-of-default backup-plugin output directories are common. The resolution path is: check `wp-options` for the plugin's configured output directory (backups table, UpdraftPlus `updraft_<option>` keys), then confirm the flagged file lives there.

---

## Database dumps

`mysqldump(1)` produces SQL-text output with a stable header:

```
-- MySQL dump 10.13  Distrib 8.0.<minor>, for Linux (x86_64)
--
-- Host: localhost    Database: <db>
-- ------------------------------------------------------
-- Server version       8.0.<minor>
```

File naming is operator-driven — `mysqldump` writes to stdout by default. Common operator patterns:

- `dump-<date>.sql`, `<dbname>-<date>.sql`, `mysqldump-<date>.sql.gz`.
- `db-backup-YYYYMMDD.sql` from cron-driven maintenance scripts.
- `.sql.gz` compressed variants from `mysqldump | gzip > <file>.sql.gz` idiom.

Content-based FP resolution: the header above is load-bearing. A file ending in `.sql` that lacks the `-- MySQL dump` header is not a `mysqldump` output and deserves review — attackers sometimes use `.sql` extension on webshell-containing text to bypass extension-based blocks.

Size signal: a real dump of a medium Magento store runs hundreds of MB to low GB; a 4 KB file named `dump-<date>.sql` is either a stub or not what it claims to be.

---

## Log-rotation artifacts

`logrotate(8)` produces predictable naming:

- `<logname>.1`, `<logname>.2`, ..., `<logname>.N` — the numeric-suffix rotation scheme (default on most distros).
- `<logname>-YYYYMMDD` or `<logname>.YYYYMMDD` — the date-suffix rotation scheme (configurable via `dateext` in `/etc/logrotate.conf`).
- `<logname>.1.gz`, `<logname>-YYYYMMDD.gz` — compressed variants. Compression is driven by the `compress` directive in logrotate config.

Typical rotated log locations on cPanel hosts: `/var/log/apache2/domlogs/<domain>-<YYYYMMDD>`, `/home/<user>/logs/<domain>-bytes_log.gz`. See `hosting-stack/cpanel-anatomy.md:91-96` for the cPanel-specific log tree.

Rotation does not create files inside docroots. A `access.log.1` inside `/home/<user>/public_html/` is misplaced — either a misconfigured rotation, a manual operator copy, or a drop using rotation naming for cover.

---

## Resolution checklist

For a flagged file suspected to be a backup artifact:

1. **Filename suffix match.** Does the name match one of the patterns above? If not, skip to step 5.
2. **Ownership match.** `stat -c '%U:%G' <file>`. Compare against the expected producer (cPanel = `<user>:<user>` or `root:root`; UpdraftPlus = web-user; `mysqldump` = whoever ran it — operator ticket should name it).
3. **Sibling check.** `ls -la` the parent directory. Are there other backup-named files with similar shape and timestamps? A single lone `.bak` in a docroot without siblings is weaker evidence than a directory full of rotated copies.
4. **Content header match.** For `.sql`, check the mysqldump header. For `.tar.gz`, `tar tzf <file> | head` confirms the archive structure. For `.zip`, `unzip -l <file> | head` the same. A backup archive has thousands of entries; a 2-entry archive with one entry named `shell.php` is not a backup.
5. **Mtime and size sanity.** Mtime during a known backup window; size in the expected range for the content class. Missing either signal does not prove malice, but presence of both without other anomalies closes the FP.

A file that passes steps 1-5 is benign with high confidence. Any step failure escalates to full evidence collection per `ir-playbook/case-lifecycle.md`.

<!-- public-source authored — extend with operator-specific addenda below -->
