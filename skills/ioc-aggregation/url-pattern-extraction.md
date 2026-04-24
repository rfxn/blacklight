# ioc-aggregation — URL pattern extraction

Loaded by the router when a case has many distinct URL strings in access-log evidence and the curator is about to author a ModSec rule (or a preflight condition for `defend.modsec`). Complements `skills/defense-synthesis/modsec-patterns.md` — that file describes rule shapes; this file describes how to collapse N observed URL strings into M generalizable patterns where M ≪ N without under-fitting into customer traffic or over-fitting into per-IP rule explosion.

The output of this work lands in `bl-case/CASE-<id>/url-patterns.md` (the case memory-store pointer file — see `docs/case-layout.md` §3) and becomes the `args` payload for a `synthesize_defense` call with `kind: modsec`.

---

## Scenario

A case has ingested forty-seven distinct URL strings from the Apache transfer log across three compromised hosts. All forty-seven routed to a PHP drop via URL-evasion (image-extension trailing path, query-param dispatch). The operator wants ModSec coverage that blocks the *class* — not forty-seven individual `@streq` rules, not one wide `.*\.php.*` rule that cascades into admin-traffic blocks. The curator's task is to extract two or three generalizable patterns that cover the observed adversary traffic while preserving legitimate Magento admin paths.

Wrong move A: emit forty-seven `SecRule REQUEST_URI "@streq <literal>"` rules. ModSec's rule evaluation cost compounds — every request pays the cost of every rule, and the synthesizer's per-case rule budget (DESIGN.md §12.2, roughly 20 rules per case) is blown on literals that the next adversary IP will sidestep.

Wrong move B: emit one `SecRule REQUEST_URI "@rx .*\.php.*\?c=" ...` rule. Catches every PolyShell variant — and every legitimate admin tool that uses `?c=` as a query parameter. Customer-outage within hours.

Right move: identify the axes of variation across the forty-seven, find the two or three axes that generalize without crossing into admin surface, emit one rule per cluster with admin-path exemptions ordered before the deny-rule. The sections below are the discipline.

---

## Common URL-evasion shapes

PolyShell-era URL evasion uses a compact set of shapes. Recognizing the shape class determines which axis of variation matters for the extraction.

**Image-extension-to-PHP routing.** Request arrives as `a.php/banner.jpg?c=id`. The `AcceptPathInfo` directive (or a rewrite rule) routes the request to `a.php` for execution; the trailing `banner.jpg` is path-info the PHP interpreter ignores. Naive log filtering on `.jpg` misses the request (no `.php` substring at first glance); naive log filtering on `.php` catches legitimate admin pages. The shape: `<phpfile>.php/<decoyfile>.<imgext>?<dispatch-params>`.

**Query-param dispatch.** Request arrives as `/custom_options/?a=read&f=/etc/passwd`. The `/custom_options/` path is a public-facing Magento endpoint; the adversary has placed a dispatch shim at that path that routes on `a=` to file read. APSB25-94's public shape (https://helpx.adobe.com/security/products/magento/apsb25-94.html) documents `custom_options` as the vector for the initial compromise; post-compromise shells reuse the same path for persistence. The shape: `<publicly-routable-path>/?<short-key>=<op>&<params>`.

**Path-trailing-slash / dot-segment.** Request arrives as `/pub/media/cache/./evil.php`. The `./` path segment is normalized by some WAFs (treated as the parent directory) but the filesystem resolves it literally, landing on `evil.php` under `cache/.`. Shapes vary: `/./`, `//./`, `/..//`, `%2e%2f`. The evasion defeats path-normalization-unaware filters.

**Double extension under permissive AddHandler.** Request arrives as `/upload/file.jpg.phtml`. An `AddHandler` directive in `.htaccess` maps `.phtml` to PHP; the `.jpg.phtml` extension slips through "block .php uploads" filters that only look at `.php` literally. Shape: `<dir>/<file>.<decoy-ext>.<phpclass-ext>` where phpclass-ext ∈ {php, php5, phtml, phar, inc}.

**Query-string-injected payload.** Request arrives as `/legit/page.php?q=<?php eval($_GET[c])?>`. The legitimate page echoes `$_GET['q']` back into HTML; the adversary's PHP fragment runs when the response is re-fetched from a cache or crawled by a content scraper that executes embedded PHP. Rarer on Magento (rendering is template-driven, not echo-dominated) but present on WordPress plugin surfaces the Magento operator also fronts.

Public reference grounding: https://sansec.io/research/magento-polyshell (Sansec's PolyShell research describes the image-extension and query-param shapes), https://helpx.adobe.com/security/products/magento/apsb25-94.html (Adobe advisory documents `custom_options` as the initial vector).

---

## The three-axis reduction

Every URL string varies on three axes. A generalizable pattern fixes on one axis and varies on the other two; a noise-class group varies on all three.

**Path-leaf axis.** The final segment of the request path before the query string. `a.php`, `banner.jpg`, `evil.phtml`, `index.php/custom_options/`. Variations on path-leaf within a cluster suggest multiple adversary-owned files but a shared dispatch pattern.

**Query-param axis.** The key-value shape of the query string. `c=id`, `a=read&f=/etc/passwd`, `op=harvest&m=cred`. Variations on query-param within a cluster suggest a common shell dispatching on different capabilities.

**Request-body axis.** POST bodies (when observed via ModSec audit log, not Apache transfer log). JSON payloads, form-encoded fields, multipart uploads. Variations on body within a cluster suggest a common endpoint receiving different payload shapes per intrusion stage.

The axis-reduction rule: **patterns that vary on two axes and fix on one are generalizable into a single ModSec rule; patterns varying on three axes are probably noise or span multiple actors**.

Worked example: forty-seven URLs from the scenario.

- Twelve vary on path-leaf and query-param, fix on path-prefix (all are under `/pub/media/cache/*/`). Generalizable — rule targets `REQUEST_URI` prefix `^/pub/media/cache/[^/]+/` with trailing `.php` in any segment.
- Eighteen vary on path-leaf and query-param, fix on `/custom_options/` endpoint with `?a=` dispatch. Generalizable — rule targets `REQUEST_URI` exactly matching `^/custom_options/` AND `ARGS_NAMES` containing `a`.
- Eight vary on all three axes with no fixed path-prefix. Noise — likely scanner probes from the adversary cluster that never found a working shell. No rule; the firewall layer handles these via IP block.
- Nine cluster on double-extension shape `\.jpg\.phtml$` under `/upload/`. Generalizable — rule targets file-upload validator with extension-class match.

Forty-seven collapsed to three rules + eight ignored-as-noise. That's the extraction output.

---

## Over-fit vs under-fit tradeoff

The generalization has failure modes on both sides.

**Over-fit:** one regex per adversary IP, one rule per URL literal, one `@streq` per observed request. Cost: ModSec's per-request rule-evaluation budget (typically ~40 rules in phase 2 before latency becomes customer-visible) is exhausted by one case's evidence. Second cost: the next adversary IP arrives with a URL that differs by one character, and none of the forty-seven literals match. The over-fit rule set buys one-case coverage at the expense of next-case coverage.

**Under-fit:** one wide regex catching the whole class. `.*\.php.*\?c=`. Cost: catches legitimate admin traffic — Magento's `?c=` is a valid query parameter for some admin panels, and third-party Magento modules that use short query keys get swept up. Customer support-ticket storm within hours. Under-fit rules are the class that make responders pull rules mid-incident, which is worse than not deploying them at all.

Balance target: **one rule per actor cluster, scoped narrow enough to sit above legitimate traffic but wide enough to survive variant drift**. The scoping happens on two dimensions — path-prefix (narrowest acceptable) and axis-fixing (the one axis the adversary can't cheaply vary without moving the whole operation).

---

## Non-obvious rule — whitelist admin paths FIRST, deny-rule SECOND

ModSec rule ordering matters. A `SecRule REQUEST_URI "@rx \.php/[^/]+\.(jpg|png|gif)$"` block applied at phase 1 catches the PolyShell image-evasion shape — AND catches any legitimate Magento admin tool that happens to fit the same path shape (rare but non-zero on third-party extensions).

Fix: author the admin allowlist at a lower rule-id than the deny. ModSec processes rules in rule-id order; the allowlist's `skipAfter` directs ModSec to jump past the deny-rule when the allowlist matches.

Shape:

```apache
# Rule 900001 (phase 1): allowlist admin paths
SecRule REQUEST_URI "@beginsWith /admin/" \
    "id:900001,phase:1,pass,nolog,t:none,t:normalizePath,\
     skipAfter:END_POLYSHELL_CHECKS"

SecRule REQUEST_URI "@beginsWith /rest/V1/" \
    "id:900002,phase:1,pass,nolog,t:none,t:normalizePath,\
     skipAfter:END_POLYSHELL_CHECKS"

SecRule REQUEST_URI "@beginsWith /graphql" \
    "id:900003,phase:1,pass,nolog,t:none,t:normalizePath,\
     skipAfter:END_POLYSHELL_CHECKS"

# Rule 900100 (phase 1): deny-rule for PolyShell URL-evasion
SecRule REQUEST_URI "@rx \.php/[^/]+\.(jpg|jpeg|png|gif|svg|css|js|webp|bmp|ico)(\?|$)" \
    "id:900100,phase:1,deny,status:403,log,auditlog,\
     msg:'PolyShell URL-evasion: image-extension trailing path on PHP',\
     tag:'attack-polyshell',tag:'attack-url-evasion',severity:'CRITICAL'"

SecMarker END_POLYSHELL_CHECKS
```

The `skipAfter:END_POLYSHELL_CHECKS` on rules 900001-900003 directs ModSec to jump past rule 900100 when any admin path matches; legitimate admin traffic pays zero deny-rule cost and avoids false positives. Attacker traffic doesn't match the admin prefix, flows to rule 900100, gets denied.

Reverse the order — deny-rule at 900001 with allowlist at 900100 — and the allowlist never fires. Admin traffic blocked, customer escalation within minutes.

The operator-protection rule: **enumerate admin URL patterns from Magento's public route reference** (https://developer.adobe.com/commerce/webapi/rest/, https://developer.adobe.com/commerce/frontend-core/guide/routing/ ) **and subtract them from the deny-rule target-path set via explicit `skipAfter` allowlists at lower rule-ids**. Magento routes that MUST appear in the allowlist: `/admin/`, `/rest/V1/`, `/graphql`, `/checkout/`, `/customer/account/`, `/pub/static/`, `/pub/media/` (only the legitimate subtrees — the rule still catches adversary drops inside `.cache` / `.system` / `.tmp`), `/media/` (legacy), `/media-/*/`, `/_cache/`, and operator-customized admin aliases (often in `app/etc/env.php` under `backend.frontName`).

Public references: https://owasp-modsecurity-crs.org/ (OWASP ModSecurity CRS — rule ordering and `skipAfter` patterns), https://coreruleset.org/ (CRS rule library; reference for well-structured admin allowlist patterns).

---

## Worked example — five PolyShell URLs generalized

Input: five URLs from the case evidence (all from the Sansec-documented PolyShell shape).

1. `/custom_options/?a=read&f=/etc/passwd`
2. `/pub/media/wysiwyg/.system/a.php?c=id`
3. `/pub/media/cache/default/.tmp/b.php/banner.jpg?c=whoami`
4. `/pub/media/catalog/product/.cache/shell.php/decoy.png?op=harvest`
5. `/upload/cv.jpg.phtml`

Axis analysis:

- URLs 2, 3, 4: share `pub/media/*/<dotted-leaf-dir>/*.php` path-prefix. Vary on path-leaf and query-param; fix on path-prefix AND `.php` presence AND image-extension trailing path (for 3, 4) or `.php?` direct (for 2).
- URL 1: `/custom_options/` endpoint with `a=` dispatch. Separate cluster — shares no path-prefix with 2/3/4.
- URL 5: double-extension under `/upload/`. Separate cluster.

Output: three generalized ModSec rules.

```apache
# Rule 900100: PolyShell drop in Magento media-tree dotted-leaf directories
SecRule REQUEST_URI "@rx ^/pub/media/[^/]+/(cache|wysiwyg|catalog)/[^/]+/\.(cache|system|tmp)/[^/]+\.php(/|\?|$)" \
    "id:900100,phase:1,deny,status:403,log,auditlog,\
     msg:'PolyShell drop in Magento media-tree dotted-leaf',\
     tag:'attack-polyshell',severity:'CRITICAL'"

# Rule 900101: custom_options dispatch with short-key action param
SecRule REQUEST_URI "@beginsWith /custom_options/" \
    "id:900101,phase:2,chain,deny,status:403,log,auditlog,\
     msg:'custom_options endpoint with short-key action dispatch',\
     tag:'attack-polyshell',severity:'CRITICAL'"
    SecRule ARGS_NAMES "@rx ^(a|c|f|m|op)$" "t:none"

# Rule 900102: double-extension upload with PHP-class suffix
SecRule REQUEST_FILENAME "@rx \.(jpg|jpeg|png|gif|svg|webp|bmp|ico)\.(php|php\d|phtml|phar|inc)$" \
    "id:900102,phase:2,deny,status:403,log,auditlog,\
     msg:'Double-extension upload with PHP-class suffix',\
     tag:'attack-file-upload',severity:'CRITICAL'"
```

Forty-seven URLs → three rules. Admin allowlist (rules 900001-900003 from the non-obvious-rule section) sits in front. The ruleset survives variant drift because the generalization is on axes the adversary can't cheaply change without relocating the whole operation.

---

## Failure mode — over-broad regex catches legitimate admin tooling

Concrete failure: curator emits `SecRule REQUEST_URI "@rx /.*\.(jpg|png)\/.*\.php.*"` to catch image-route evasion. The regex matches adversary traffic — AND matches legitimate `/pub/media/catalog/banner.jpg/modified-headers.php` used by a third-party Magento extension for dynamic header management on product images.

The extension owner gets paged at 3am when its traffic starts 403-ing. Customer escalation follows. Responder rolls back the rule; case's deny-coverage drops to zero; adversary activity resumes within the rollback window.

The preemption: the non-obvious rule above — **enumerate admin/extension paths first, subtract from the deny set via `skipAfter` allowlist**. Operators running curated Magento extension inventories keep a list at `/var/lib/bl/state/magento-extension-paths.json` that the curator reads during URL-pattern synthesis; the allowlist rules 900001+ are auto-generated from that inventory.

Without the extension inventory, the curator falls back to the Magento public route list (https://developer.adobe.com/commerce/webapi/rest/) — covers core but misses third-party extensions. The fallback is noted in `open-questions.md`: "Operator should export installed Magento extension paths to /var/lib/bl/state/magento-extension-paths.json so future URL-pattern rules safelist them explicitly."

The observed-from-field precedent: pre-blacklight URL generalization relied on responder intuition. Two-thirds of emergency ModSec rollbacks in IR history traced to admin-path collision with a deny regex that caught the adversary AND a third-party extension. The allowlist-first discipline turns that class of failure into a preflight-blocked configtest failure, not a production rollback.

---

## What this file is *not*

- Not a guide to writing ModSec rules from scratch. See `skills/defense-synthesis/modsec-patterns.md` and https://coreruleset.org/ for rule-shape references.
- Not an exhaustive list of URL-evasion techniques. New shapes surface; the three-axis reduction generalizes.
- Not a substitute for the operator's own extension inventory. The admin allowlist is the operator-protection floor; extension-inventory drift is the responder's ongoing work.
