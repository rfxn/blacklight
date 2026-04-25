# shared-hosting — cPanel compromise-shape (where backdoors stage and what evades find)

Loaded by the router when `shared_hosting_layer = cpanel`. Sibling to the layout reference at [`../hosting-stack/cpanel-anatomy.md`](../hosting-stack/cpanel-anatomy.md) — that file maps the tree; this one names the staging spots and timing tells that a layout-only read misses. Pairs with [`../linux-forensics/persistence.md`](../linux-forensics/persistence.md) for cron/systemd persistence reading once the staging spot is found.

A `find /home -type f -name '*.php' -newer /tmp/window.flag` lands one PolyShell-class hit and cleanup gets declared done. A week later the dropper is back. The other files were at perms `0440 owner-only` in `~/.cache/`, invisible to a `find` that stopped at the docroot. The PHP-FPM pool runs as the user, so it reads `~/.cache/loader.php` via `auto_prepend_file`. The visible dropper was the decoy; the loader rebuilt it on the next request.

This file is the lookup of where else to walk and which timing tells separate adversary cadence from sysadmin churn.

Authoritative references: cPanel filesystem layout (`docs.cpanel.net`), PHP-FPM configuration (`https://www.php.net/manual/en/install.fpm.configuration.php`), Apache `auto_prepend_file` (`https://httpd.apache.org/docs/current/mod/core.html`), and [`../hosting-stack/cpanel-anatomy.md`](../hosting-stack/cpanel-anatomy.md) for layout.

## Backdoor staging spots that evade a docroot-only find

The tenant's `$HOME` has subtrees the user's PHP can read but most scans skip. Walk all of them:

- `~/.cache/` — user-writable, almost never customer-content, reachable by PHP. Staging file at `0440 owner:owner` named `loader.php` / `wp-cache.php` / `index.php` is the canonical pattern. Triggered via `auto_prepend_file` injected through `.htaccess` or `php.ini`.
- `~/tmp/` — per-user tmp; survives a `/tmp` wipe and is visible to PHP. Common spot for second-stage payloads downloaded by the loader.
- `~/.cpanel/` — per-user cPanel state. A new `.cpanel/api_tokens_v2/` entry means the account API was used to establish access; the file's mtime brackets the issuance event.
- `~/.htpasswds/` — `.htaccess` auth files. An attacker who locks the operator out of an admin path adds an entry here plus a `.htaccess` `AuthUserFile` directive in the protected directory.
- `~/ssl/` — account-managed SSL artifacts. PEM files the panel did not generate are worth a `openssl x509 -text` read; panel certs trace to the panel-managed Let's Encrypt issuer.
- `~/.trash/` — files the customer "deleted" via the cPanel File Manager land here. Triage that opens with "the customer cleaned up" should always check this directory first; it commonly contains the original PolyShell file the customer thought they removed.
- `~/etc/<domain>/` and `~/logs/` — mail config and rotated bytes_log; rarely staging targets but read for evidence (matching POSTs to suspect paths).

Triage walk:

```
find ~/.cache ~/tmp ~/etc ~/.cpanel ~/.htpasswds ~/ssl ~/.trash \
  -type f \( -name '*.php' -o -name '*.phtml' -o -name '*.phar' \) \
  -newer /tmp/window.flag -printf '%TY-%Tm-%Td %TH:%TM %m %u:%g %p\n'
```

A hit at perms `0440` or `0400` outside `~/.trash/` is load-bearing — the user's normal umask produces `0644`, and the loader pattern is to drop staging files at `0440` so customer `find -perm 0644` sweeps miss them.

## Setgid directories as a deployment-cadence tell

Files written into a `g+s` (setgid) directory inherit the directory's group, not the writer's primary group. Adversary-staged directories under `~/public_html/` often have `g+s` set so files dropped by a PHP request retain a consistent group string the curator can pivot on across the docroot.

```
find ~/public_html -type d -perm -2000 -printf '%TY-%Tm-%Td %m %u:%g %p\n'
```

Expected count on a clean home is zero or one (`Maildir/` is sometimes `g+s` by panel default; nothing under `public_html/` should be). Three or more under the docroot is a staging tell on its own. The directory's mtime brackets staging setup — usually within 30 seconds of the first dropped file's mtime.

## What survives a PHP-FPM pool restart

`whmapi1 restart_service service=httpd` or a per-user pool restart kills in-memory adversary state (open shell sockets) but leaves:

- Any `auto_prepend_file` directive in `.htaccess` or `~/etc/<domain>/<user>/php.ini`. Re-loaded on the next request.
- `~/.cpanel/api_tokens_v2/` entries. Pool restart does not invalidate API tokens.
- Cron entries under `/var/spool/cron/<user>` (RHEL) or `/var/spool/cron/crontabs/<user>` (Debian).
- Files under the staging spots above.

"Restart the pool to clear it" is necessary but not sufficient — the staging-spot walk must run, plus a cron-and-`auto_prepend_file` scrub. See [`../linux-forensics/persistence.md`](../linux-forensics/persistence.md) for cron / shell-init reading; [`homedir-perms-traps.md`](homedir-perms-traps.md) for the perm-pattern triad that promotes the find above into a high-confidence finding.

<!-- public-source authored — extend with operator-specific addenda below -->
