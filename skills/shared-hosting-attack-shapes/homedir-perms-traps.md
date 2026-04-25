# shared-hosting — homedir perm traps (the perm grammar that diverges from dedicated)

Loaded when the curator is reasoning about file-permission evidence on any host with `shared_hosting_layer != none`. Always-load alongside [`SKILL.md`](SKILL.md). Pairs with [`cpanel-vhost-anatomy.md`](cpanel-vhost-anatomy.md), [`plesk-vhost-anatomy.md`](plesk-vhost-anatomy.md), [`directadmin-vhost-anatomy.md`](directadmin-vhost-anatomy.md) — those teach where; this teaches what to flag and what to ignore.

A `find /home -perm -o+w -type f` on a dedicated server returns ~10 hits and they all matter. The same `find` on shared hosting returns 4,000 hits and 99% are FP — customer uploads with bad umask, old WP plugin cache files, legacy CMS installers. A curator that emits "host has 4,000 world-writable files" as high-confidence burns its confidence budget for the case. Shared hosting has its own perm grammar; rules that work on dedicated boxes are noise here.

Authoritative references: `find(1)` perm syntax, PHP-FPM per-user pool ownership (`https://www.php.net/manual/en/install.fpm.configuration.php`), Apache `mod_ruid2` (`https://github.com/mind04/mod-ruid2`), and [`../hosting-stack/cpanel-anatomy.md §Execution context`](../hosting-stack/cpanel-anatomy.md) for suEXEC/PHP-FPM/DSO baseline.

## What `0644 owner:owner` means on shared hosting

The PHP-FPM pool runs as the user; the user's PHP needs read access to its own files. `0644 <user>:<user>` under `~/public_html/` is *expected* — flagging any `0644` PHP file as suspicious would fire on every legitimate file.

The inversion: perms that draw attention are the ones the user *cannot create* through normal upload paths.

- `0666 nobody:nogroup` under `/home/<user>/` — DSO-leftover pattern (mod_php as the Apache user, mostly retired). On a modern PHP-FPM cPanel host, anomalous; suggests an old vhost handler.
- `0440 nobody:<user>` — user cannot create this group/perm pair via FTP, SSH, or panel upload. Loader staging tell.
- `0400 root:root` under `/home/<user>/` — root wrote this. Either a sysadmin reset or a privilege-escalation tell.
- `04755` (setuid) under `/home/<user>/` — tenant cannot set setuid through normal paths. Privilege-escalation drop.

## Setgid directories under homedirs

`g+s` on a directory makes files written into it inherit the directory's group. Adversary deployment scripts set `g+s` on staging directories so PHP-dropped files retain a consistent group the curator can pivot on.

```
find /home/<user> -type d -perm -2000 -printf '%TY-%Tm-%Td %m %u:%g %p\n'
```

Expected count on a clean home: zero or one. `Maildir/` is sometimes `g+s` by panel default; nothing under the docroot or `~/.cache/` should be. Three or more is a staging tell.

## World-writable files on shared hosting

A `0666` file in `~/public_html/` on shared hosting is *usually* an old WP plugin cache, a legacy CMS installer leftover, or a hosting-migration tool that left files at `0666` to ease cross-user copy. Treating world-writable as a high-confidence adversary tell on shared hosting is a noise-floor mistake.

The signal is the **triad**:

1. **Perm pattern** — world-writable, `0440 nobody:<user>`, setuid, or anything in §"What `0644` means" above.
2. **Mtime cluster** — file mtime inside the suspect window (within minutes of the access-log POST or the LMD hit).
3. **Magic-byte tell** — `file <path>` returns `PHP script` for a non-`.php` extension, or `GIF image data` with PHP open-tag in the first 1024 bytes (PolyShell-class polyglot), or magic bytes contradicting the extension.

Any one leg is noise; the triad firing on the same file is a high-confidence finding. Never emit a single leg alone on a shared-hosting host.

## Triage script

```
window_start=$(date -d 'YYYY-MM-DD HH:MM' +%s)
find /home/<user> -type f -newermt "@$window_start" \
  \( -perm -o+w -o -perm -2000 -o -perm -4000 \) \
  -printf '%TY-%Tm-%Td %TH:%TM %m %u:%g %p\n' \
  | while read -r line; do
      path=$(awk '{print $NF}' <<<"$line")
      magic=$(file -b "$path" | head -c 80)
      printf '%s | %s\n' "$line" "$magic"
    done
```

Rows where the magic-byte column reads `PHP script`, `GIF image data ... PHP`, or `data` for a file at `*.php` extension are the high-confidence finds. Everything else is the noise floor — file as `ambiguous` per `../ir-playbook/case-lifecycle.md §support types` rather than emitting a finding.

Layer-specific paths to feed into this triad live in the three sibling vhost-anatomy files.

<!-- public-source authored — extend with operator-specific addenda below -->
