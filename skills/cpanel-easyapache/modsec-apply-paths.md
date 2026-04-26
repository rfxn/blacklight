# modsec-apply-paths — Global vs. Userdata Path Discipline

**Purpose.** When `defend.modsec` is prescribed on a cPanel EA4 host, the rule
must land in the right conf file or it will be silently overwritten on the next
WHM ModSecurity rebuild. This file documents the two valid apply paths, the file
locations for each, and the WHM rebuild risk for each.

Reference: `src/bl.d/45-cpanel.sh`. cPanel EA4 EasyApache 4 documentation for
per-user ModSecurity configuration and `ensure_vhost_includes`.

---

## 1. Two valid apply paths

### 1a. Global — `modsec2.user.conf`

**File path:** `/etc/apache2/conf.d/modsec2.user.conf`

This file is the standard location for site-wide ModSec rules on cPanel EA4 hosts.
It is included by the EA4 Apache configuration template. WHM ModSecurity rebuilds
do NOT overwrite this file — it is explicitly preserved as the operator-customization
path.

**When to use:** rule should apply to all vhosts on the server (e.g., blocking a
source IP cluster that targeted multiple accounts, or applying a generic PHP
deserialization rule that applies to any Magento install on the host).

**Apply mechanics:**
1. Append (or insert) the SecRule body to `modsec2.user.conf`.
2. Run `restartsrv_httpd --restart`.
3. On failure: restore from backup (see `SKILL.md §3`).

**Rollback:** `bl` writes a backup of `modsec2.user.conf` before modification.
The backup path is `/var/lib/bl/backups/modsec2.user.conf.<timestamp>`. The
rollback sequence restores from this backup and retries `restartsrv_httpd`.

---

### 1b. Per-user vhost — userdata conf

**File path:** `/usr/local/apache/conf/userdata/std/2_4/<user>/<domain>/modsec2.conf`
(EA4 standard form; actual path may vary by WHM version — `ensure_vhost_includes`
normalizes it)

This is the per-user, per-domain ModSec configuration file managed by cPanel's
userdata layer. It is included in the generated vhost conf by
`/scripts/ensure_vhost_includes --user=<user>` and is preserved across WHM
rebuilds (stored in userdata, not in generated httpd.conf).

**When to use:** rule targets a specific user's vhost (e.g., the APSB25-94 exploit
targeted `/home/shopowner/public_html/rest/V1/` specifically; the SecRule should
be scoped to that vhost, not applied globally to all vhosts).

**Apply mechanics:**
1. Write SecRule body to the userdata conf file.
2. Run `ensure_vhost_includes --user=<user>` (idempotent; regenerates the vhost
   include linkage without modifying existing conf content).
3. Run `restartsrv_httpd --restart`.
4. On failure: symmetric rollback via backup restore (see `SKILL.md §4`).

**Rollback:** backup path is `/var/lib/bl/backups/userdata-<user>-<domain>.<timestamp>`.
The rollback sequence restores the userdata conf and retries `restartsrv_httpd`.

---

## 2. `restartsrv_httpd` vs. `ensure_vhost_includes` — invocation order

**Global path:** `restartsrv_httpd` only. `ensure_vhost_includes` is not needed
because `modsec2.user.conf` is already included by the EA4 template; the include
linkage does not need to be regenerated.

**Per-user vhost path:** `ensure_vhost_includes --user=<user>` FIRST, then
`restartsrv_httpd`. The ordering matters:
- `ensure_vhost_includes` generates or refreshes the include stanza in the user's
  vhost conf that pulls in the userdata conf file.
- If `restartsrv_httpd` runs without `ensure_vhost_includes` having been called,
  a freshly written userdata conf file may not be included in the active vhost
  conf — the rule silently does not load.

The `45-cpanel.sh` implementation enforces this order. The curator should not
propose a step that calls `restartsrv_httpd` on the per-user path without
`ensure_vhost_includes` having been called first in the same apply sequence.

---

## 3. WHM ModSecurity rebuild risk

**Global path risk: LOW.** `modsec2.user.conf` is preserved by WHM's ModSecurity
configuration rebuild (this is its design purpose — it is the safe hand-edit
destination). Rules in this file survive:
- EasyApache 4 profile updates
- Apache version upgrades
- WHM ModSecurity ruleset vendor updates (e.g., OWASP CRS updates via WHM)

**Per-user vhost path risk: LOW (with `ensure_vhost_includes`).** Rules in
userdata confs are preserved by WHM's vhost rebuild machinery because they are
stored in the userdata layer, not in generated httpd.conf. WHM's rebuild
regenerates httpd.conf from templates but includes userdata confs verbatim.

**What IS overwritten on rebuild:**
- `/etc/apache2/conf.d/modsec2.conf` — WHM manages this file; rules written
  here directly are lost on the next WHM ModSecurity ruleset update.
- `/etc/apache2/conf.d/` files that match WHM-managed naming patterns.
- Vhost conf files under `/var/cpanel/userdata/` (generated; userdata source
  in `/usr/local/apache/conf/userdata/` is preserved).

The curator must not propose rules targeting WHM-managed files.

---

## 4. SecRule body format constraints for EA4

ModSecurity on EA4 runs in embedded mode inside Apache. The rule syntax must be
valid for the ModSecurity version shipped with the active EasyApache 4 profile.

Key constraints (derived from public EA4 + ModSec documentation):

- **Phase placement:** rules blocking pre-auth REST endpoints should use
  `phase:2` (request body phase) to allow body inspection. `phase:1` (request
  headers) is appropriate for source-IP blocks and UA blocks. Do not use
  `phase:4` or `phase:5` for blocking rules — response phases cannot deny
  the current request (the request has already been processed).

- **`SecRule` vs. `SecAction`:** use `SecRule` for pattern-based conditions;
  use `SecAction` only for unconditional logging or flag-setting (e.g., setting
  a transaction variable for chain use). Never use `SecAction` as a blocking
  rule.

- **`t:` transformation order:** transformations apply before matching.
  For URL-evasion patterns (`image-proc.php` masquerading as `.jpg`),
  include `t:base64DecodeExt` and `t:urlDecodeUni` in the rule chain where
  applicable. See `skills/modsec-grammar/transformation-cookbook.md` for
  the standard transformation stack.

- **No `@exec` in operator-authored rules.** `@exec` invokes an external script
  from within ModSec — prohibited in any bl-authored SecRule. The wrapper's
  `bl_run_preflight_tier` will reject rules containing `@exec` during schema
  validation.

- **Rule ID namespace:** operator-authored rules should use IDs in the range
  `9990000–9999999` (reserved for local customization in OWASP CRS
  conventions). Do not use IDs in the `9[0-9]{5}` range without checking
  for OWASP CRS rule conflicts on the host.

---

## 5. cPanel-specific paths — what NOT to touch

| Path | Reason |
|---|---|
| `/var/cpanel/modsec_cpanel_conf/` | WHM ModSecurity manager storage; direct edits conflict with WHM's rule inventory |
| `/etc/apache2/conf.d/modsec2.conf` | WHM-managed; overwritten on ruleset update |
| `/etc/apache2/conf.d/modsec2_cpanel.conf` | WHM-generated cPanel rules; do not modify |
| `whmapi1` / WHM API | bl does not hold WHM credentials; API-level rule management is out of scope |
| EA4 profile `.yaml` files | Module-level config; modifying module presence requires `ea_install`/`ea_remove`, not conf edits |
| Apache worker MPM config | `mpm.conf` changes require full `easyapache4` profile rebuild; out of scope |

---

## 6. Diagnostic commands (observe-only, non-mutating)

These can be proposed as `observe.file` steps to verify apply-path state:

| Check | Path |
|---|---|
| Verify rule landed | `observe.file /etc/apache2/conf.d/modsec2.user.conf` |
| Verify userdata conf exists | `observe.file /usr/local/apache/conf/userdata/std/2_4/<user>/<domain>/modsec2.conf` |
| Verify include linkage | `observe.file /usr/local/apache/conf/userdata/std/2_4/<user>/<domain>/` (list dir) |
| Check restart log | `observe.log_journal` filtered to `apache2` unit within the apply window |

Do not propose `apachectl configtest` directly — on cPanel EA4 the correct
pre-flight is handled by `restartsrv_httpd`'s own config validation step.
`apachectl configtest` against cPanel's generated httpd.conf may report false
errors related to non-standard cPanel directives.

---

## Pointers

- `skills/cpanel-easyapache/SKILL.md` — substrate detection + router overview
- `/skills/prescribing-defensive-payloads-corpus.md` — SecRule grammar (ModSec rules-101, transformation cookbook)
- `skills/modsec-grammar/rules-101.md` — SecRule operator + action syntax
- `skills/modsec-grammar/transformation-cookbook.md` — transformation stacks for obfuscated URIs
- `/skills/foundations.md` — ir-playbook lifecycle rules
