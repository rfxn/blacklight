# cpanel-easyapache — Substrate Router

**Scenario.** A cPanel EA4 host. The curator has proposed `defend.modsec` to lock
in a SecRule blocking the APSB25-94 initial-access endpoint pattern. The wrapper
detects `_bl_cpanel_present()` returns true (both `/usr/local/cpanel/` exists and
`/usr/local/cpanel/scripts/restartsrv_httpd` is executable). The cPanel apply path
fires instead of the vanilla `apachectl configtest` path.

The substrate router's non-obvious rule: the global path and the per-user vhost
path are mutually exclusive decisions — the wrapper chooses based on whether a
specific cPanel user is named in the case scope. Do not propose both in the same
step. The global path applies the rule to `modsec2.user.conf` (all vhosts); the
per-user path applies it to `/home/<user>/public_html/.htaccess`-adjacent userdata
conf (one vhost only).

Reference: `src/bl.d/45-cpanel.sh`, `DESIGN.md §5.3`.

---

## 1. Substrate detection

`_bl_cpanel_present()` returns true when both conditions hold:
- Directory `/usr/local/cpanel/` exists.
- File `/usr/local/cpanel/scripts/restartsrv_httpd` is executable.

The check is overridable via `BL_CPANEL_DIR` and `BL_CPANEL_SCRIPT_DIR` for
test isolation. Production hosts use the defaults above.

If `_bl_cpanel_present()` is false: the standard `apachectl configtest` path is
used for `defend.modsec`. cPanel-specific steps must not be proposed.

---

## 2. Apply path routing

| Case scope | Apply path | cPanel mechanics |
|---|---|---|
| All vhosts on host | **Global** | Write rule to `modsec2.user.conf`; invoke `restartsrv_httpd --restart` |
| Single cPanel user | **Per-user vhost** | Run `ensure_vhost_includes --user=<user>`; invoke `restartsrv_httpd --restart` |

The curator determines scope from the case evidence:
- If flagged paths span multiple users' docroots → global path.
- If flagged paths are under one user's docroot only → per-user vhost path.
- If uncertain: default to global (more conservative; covers all vhosts).

---

## 3. Global path sequence

1. Write SecRule body to `modsec2.user.conf` (path: `/etc/apache2/conf.d/modsec2.user.conf`
   or the WHM-configured equivalent).
2. Emit `cpanel_lockin_invoked` ledger event (scope=global).
3. Run `restartsrv_httpd --restart` (timeout 60s by default; overridable via
   `BL_CPANEL_LOCKIN_TIMEOUT_SECONDS`).
4. If exit 0: rule is live. Return `BL_EX_OK`.
5. If non-zero: emit `cpanel_lockin_failed`; restore backup; retry restart once.
   If retry succeeds: emit `cpanel_lockin_rolled_back` (rollback_succeeded=true).
   If retry fails: emit `cpanel_lockin_rolled_back` (rollback_succeeded=false);
   dispatch `bl notify critical` — operator must intervene manually.

---

## 4. Per-user vhost path sequence

1. Write SecRule body to the user's EA4 userdata conf.
2. Emit `cpanel_lockin_invoked` (scope=uservhost).
3. Run `ensure_vhost_includes --user=<user>` (idempotent; adds vhost includes if
   missing without modifying existing vhost conf).
4. Run `restartsrv_httpd --restart` (same timeout and rollback semantics as global).
5. Rollback restores the user's vhost conf from backup.

---

## 5. What NOT to touch

- **`/var/cpanel/modsec_cpanel_conf/`** — WHM ModSecurity ruleset management
  directory. `bl` does not read or write this directory. Modifying files here
  bypasses the `ensure_vhost_includes` layer and can corrupt WHM's rule inventory.

- **`whmapi1` or WHM API calls** — `bl` does not call the WHM API. All cPanel
  interaction is through `scripts/restartsrv_httpd` and `scripts/ensure_vhost_includes`
  (filesystem-level, not API-level). WHM API calls require cPanel root credentials
  that bl does not hold.

- **EasyApache 4 profile files** (`/etc/cpanel/ea4/ea4.conf`, EA4 profile `.yaml`)
  — `bl` does not modify the EA4 module profile. Module presence is a host-level
  constraint that determines which SecRule directives are available; the curator
  must not propose directives that depend on unlisted EA4 modules.

- **Per-user `.htaccess` in docroots** — `bl clean htaccess` handles `.htaccess`
  cleanup for malicious directives (Auto_Prepend_File, php_value, ErrorDocument
  rewrite tricks). This is separate from the ModSec userdata apply path. The two
  paths do not interact — `bl clean htaccess` does not invoke `restartsrv_httpd`.

---

## §5 Pointers

- `skills/cpanel-easyapache/modsec-apply-paths.md` — detailed path discipline
- `skills/lmd-triggers/SKILL.md` — hook router (cPanel substrate check at step 4)
- `/skills/prescribing-defensive-payloads-corpus.md` — SecRule grammar for the rule body
- `/skills/foundations.md` — ir-playbook lifecycle rules
