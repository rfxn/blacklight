# Admin-Layer Backdoors and Persistence

**Source authority:** Sansec `accesson.php` coverage within the PolyShell research
<https://sansec.io/research/magento-polyshell>,
Infiniroot field observations from PolyShell and SessionReaper incidents
<https://www.infiniroot.com/blog/1527/magento-adobe-commerce-attacked-polyshell-sessionreaper-exploit-vulnerability>,
and the community patch inventory at
<https://github.com/aregowe/magento2-module-polyshell-protection>
as a defense-in-depth layer reference.

This skill covers the persistence layer. The initial-compromise paths are in [`../apsb25-94/exploit-chain.md`](../apsb25-94/exploit-chain.md). Payload-level fingerprints are in [`../webshell-families/polyshell.md`](../webshell-families/polyshell.md). The curator loads this skill when `observe.htaccess`, `observe.cron`, or `observe.file` evidence lands on a host that already has a confirmed initial-compromise event — persistence is the second wave, and misordering the cleanup is how incidents reopen.

---

## Pattern taxonomy

Five recurring persistence patterns appear across PolyShell-era and SessionReaper-era intrusions. Multiple patterns are typically present on a single compromised host; treat them as a set, not alternatives.

### 1. `.htaccess` + PHP drop in unusual directories

The adversary writes a `.htaccess` to a directory where PHP execution is normally disabled (commonly `pub/media/catalog/product/cache/`, `pub/media/import/`, or a newly-created subdirectory) and uses `AddHandler` or `AddType` to force PHP execution on a specific file extension. The payload file is dropped alongside.

Typical `.htaccess` content:

```apache
AddType application/x-httpd-php .jpg
```

or

```apache
<FilesMatch "^(shell|access|config)\.php$">
    SetHandler application/x-httpd-php
</FilesMatch>
```

### 2. `accesson.php` spray (Sansec-documented)

Following a PolyShell compromise, the adversary commonly drops a file named `accesson.php` (sometimes `access.php`, `conn.php`, `wp-config-bak.php`) across five to ten directories for persistence redundancy. The file implements a simple cookie-auth or password-gated `eval` / `system` dispatcher.

Typical spray targets:

- `pub/media/accesson.php`
- `pub/media/catalog/accesson.php`
- `pub/media/wysiwyg/accesson.php`
- `app/code/accesson.php`
- `app/etc/accesson.php` (rarer — `app/etc/` should never contain executable PHP)
- `vendor/accesson.php`

The file is small (50–200 bytes decoded) and is designed to survive incomplete cleanup — removing the initial PolyShell without finding the spray leaves the adversary with access.

### 3. FORCE-INJECT-ADMIN SQL

The adversary inserts an admin user record directly into the database, bypassing the usual `bin/magento admin:user:create` checks. Two variants:

- **Direct INSERT**: `INSERT INTO admin_user (username, email, password, is_active, ...) VALUES (...)` with a known-value password hash. The username is often innocuous-looking (`support`, `backup`, `m_admin`).
- **Via shell**: `bin/magento admin:user:create` run from a webshell to leverage Magento's own user-creation machinery. Logs the creation in `system.log` but is harder to distinguish from legitimate admin-management activity.

Both variants typically set `is_active=1` and bypass the 2FA `admin_user_expiration` and `tfa_user_config` tables by either leaving the 2FA row absent or pre-populating it.

### 4. Magento cron-schedule hijack

The `cron_schedule` table is a queue of scheduled jobs. The adversary registers a job with a `job_code` that Magento's built-in scheduler will pick up and execute. The payload lives in a custom module (often under `app/code/Attacker/Backdoor/`) or in an inline `setup/patch_data.php`.

Persistence via cron survives file-system cleanup: deleting the payload file without removing the `cron_schedule` row means the scheduler keeps trying, and if the file is restored from an un-scrubbed backup the persistence reactivates.

### 5. `local.xml` / `env.php` configuration tamper

Adversary weakens configuration rather than (or in addition to) dropping files.

- `app/etc/env.php` → `session.cookie_lifetime` extended to weeks or months (admin sessions stay valid after the adversary logs out).
- `app/etc/env.php` → `backend.frontName` changed so the admin URL is adversary-known and un-rotated.
- `app/etc/local.xml` (legacy Magento 1 installs still using this file) → database credentials changed, or session-save-path redirected.
- `core_config_data` rows → `admin/security/lockout_threshold` bumped high, `admin/security/password_lifetime` disabled.

---

## Detection heuristics

**Filesystem surveys:**

```bash
# Any .htaccess under media is high-suspicion
find pub/media -name '.htaccess' -printf '%T@ %p\n' | sort -n

# accesson.php and common spray names across the install root
find . -type f \( \
    -name 'accesson.php' -o \
    -name 'access.php' -o \
    -name 'conn.php' -o \
    -name 'wp-config-bak.php' \
\) -printf '%T@ %p\n' | sort -n

# .php in app/etc — should never exist outside the expected config set
find app/etc -type f -name '*.php' -not \( \
    -name 'env.php' -o \
    -name 'config.php' -o \
    -name 'di.xml' \
\)

# Recently-created modules under app/code — match against known legitimate vendor list
find app/code -mindepth 2 -maxdepth 2 -type d -newermt '2025-09-01'
```

**Database surveys (run from the DB host with read-only creds):**

```sql
-- New admin user records
SELECT username, email, created, is_active
FROM admin_user
WHERE created > '2025-09-08'
ORDER BY created DESC;

-- Unexpected cron jobs
SELECT DISTINCT job_code
FROM cron_schedule
WHERE job_code NOT IN (
    -- list of known Magento core + known-module jobs here
    'indexer_reindex_all_invalid',
    'sales_grid_order_async_insert'
    -- ...
);

-- Config changes to security-sensitive paths
SELECT path, value, updated_at
FROM core_config_data
WHERE path LIKE 'admin/security/%'
   OR path LIKE 'web/cookie/%'
   OR path LIKE 'web/session/%'
ORDER BY updated_at DESC;
```

**Config-dir PHP content check:**

```bash
grep -rEn 'eval|system|passthru|base64_decode|shell_exec' app/etc/
```

---

## Remediation choreography — delete-order rule

**Non-obvious rule:** when cleaning up `.htaccess` + PHP drop combinations, **delete the PHP payload first, not the `.htaccess`**. Here is why.

The `.htaccess` carries the `AddHandler` / `SetHandler` directive that enables PHP execution on the affected file extension in that directory. Removing the `.htaccess` first breaks PHP execution for future requests, but the PHP file on disk is still accessible and, depending on the adversary's infrastructure, may still be polled. Removing the PHP file first means the directory is empty of payload during the rotation window between "PHP file deleted" and "`.htaccess` deleted" — adversary polling returns 404, and when `.htaccess` goes next the configuration is clean.

The practical order (the curator encodes this as sequenced `clean.file` / `clean.htaccess` steps in `pending/`):

1. **Identify** all payload `.php` (or `.jpg`-as-PHP) files in every directory that has an anomalous `.htaccess`.
2. **Delete the payload files** first (`clean.file`).
3. **Delete the `.htaccess` files** second (`clean.htaccess`).
4. **Remove DB records** — admin users, cron jobs, config rows.
5. **Restart PHP-FPM / Apache** to clear any in-memory opcode cache of the removed payload.
6. **Rotate** every admin password, every API key, every integration token issued during the exposure window.
7. **Apply the Adobe hotfix or upgrade** for the underlying vulnerability (APSB25-94, APSB25-88, or both).

Order matters less on hosts where the webserver is taken offline during remediation; order matters a lot on hosts where the site stays live during cleanup.

---

## Triage checklist

- [ ] `.htaccess` survey under `pub/media/` and every directory more than two levels deep
- [ ] `accesson.php` and alias-file search across the install root
- [ ] `app/etc/` PHP content check — nothing besides the known config files
- [ ] `app/code/` newly-created module check against legitimate vendor inventory
- [ ] `admin_user` table diff — new rows since last-known-good snapshot
- [ ] `cron_schedule` table — unexpected `job_code` values
- [ ] `core_config_data` audit on `admin/security/*`, `web/cookie/*`, `web/session/*` paths
- [ ] `env.php` config review — session lifetime, backend frontName, session save-path
- [ ] Cross-reference initial-compromise vector — load [`../apsb25-94/exploit-chain.md`](../apsb25-94/exploit-chain.md)
- [ ] Plan remediation in delete-order sequence above
- [ ] Collect: all deleted paths with hashes, all DB rows removed, rotation log for credentials

---

## See also

- [../apsb25-94/exploit-chain.md](../apsb25-94/exploit-chain.md) — PolyShell upload path (primary initial-compromise vector)
- [../apsb25-94/indicators.md](../apsb25-94/indicators.md) — IOCs for cross-host correlation
- [../webshell-families/polyshell.md](../webshell-families/polyshell.md) — PolyShell variant fingerprints
- [../linux-forensics/](../linux-forensics/) — correlation of persistence artifacts with access logs
- [../remediation/cleanup-choreography.md](../remediation/cleanup-choreography.md) — backup-quarantine-remove-audit sequencing

<!-- adapted from beacon/skills/magento-attacks/admin-backdoor.md (2026-04-23) — v2-reconciled -->
