# defense-synthesis — ModSec rule patterns

Loaded by the router on every `synthesizer.generate()` call. The synthesizer's job is to take a `CapabilityMap` from the intent reconstructor and emit one or more `SecRule` directives plus an exception list and a validation test, all of which must pass `apachectl configtest` before they're written to the manifest.

This file is the *grammatical* and *operational* constraint the model writes against. The grammar is enforceable by `configtest`; the operational discipline is enforceable only by convention. Both matter — a syntactically valid rule that 503s legitimate traffic costs more than the attack it prevents.

---

## What "validated" means

Every emitted rule is gated through three checks before it's accepted into the manifest:

1. **Syntactic validity.** `apachectl configtest` parses the rule against the host's actual ModSec build. Different ModSec major versions (v2 vs v3 / libmodsecurity) reject different syntax. The synthesizer targets v2.9+ as the floor; v3-only operators (`@detectXSS`, transformation chains in v3-specific positions) are out of scope unless the manifest is v3-tagged.
2. **No-FP smoke against a baseline.** Every rule ships with a `validation_test` block of N HTTP requests that should NOT match (legitimate traffic shapes pulled from the host's own access.log when available) and M requests that SHOULD match (the attack shapes the rule is targeting). The smoke runs against the host's actual Apache + ModSec stack in audit-only mode before promotion to block mode.
3. **Idempotent reapply.** Re-applying the manifest must not duplicate rules. Rule IDs are stable across regenerations of the same case, drawn from the case's reserved range (`9NNN` for case-derived rules; see § Rule ID allocation).

Rules that fail any of these go to `suggested_rules` in the manifest — they do not auto-apply. The operator reviews them.

---

## SecRule anatomy

```
SecRule VARIABLES "OPERATOR" "ACTIONS"
```

**Variables** name what to inspect: `REQUEST_URI`, `ARGS`, `ARGS:foo`, `REQUEST_HEADERS:User-Agent`, `REQUEST_BODY`, `FILES_NAMES`, `FILES_TMP_CONTENT`, `RESPONSE_BODY`, `REMOTE_ADDR`, `REQUEST_METHOD`. Multiple variables join with `|`. Negation: `!ARGS:safe_param`. Selector: `ARGS_NAMES`, `ARGS_GET`, `ARGS_POST`.

**Operators** start with `@` and define the match: `@rx <regex>`, `@beginsWith <str>`, `@contains <str>`, `@endsWith <str>`, `@streq <str>`, `@eq <int>`, `@ge <int>`, `@ipMatch <cidr>`, `@pmFromFile <path>` (parallel match, fast for many tokens), `@detectXSS`, `@detectSQLi`, `@validateByteRange`, `@geoLookup`. Negate with `!@`: `!@rx ...`.

**Actions** govern what happens on match. The mandatory minimum: `id:<int>`, `phase:<int>`, and a disposition (`pass`, `deny`, `block`, `drop`). Common adjuncts: `log`, `nolog`, `auditlog`, `noauditlog`, `msg:'...'`, `tag:'attack-class'`, `severity:'CRITICAL|ERROR|WARNING|NOTICE'`, `status:<code>`, `t:<transformation>`, `chain` (continues on next rule), `skipAfter:<id>`, `ctl:ruleRemoveById=<id>`, `setvar:<varname>=<value>`.

**Transformations** (`t:`) preprocess the variable before the operator runs. Chain them: `t:none,t:lowercase,t:urlDecodeUni,t:removeWhitespace`. `t:none` clears any inherited transformations from the SecDefaultAction. The synthesizer should be explicit about transformations — implicit chains break across hosts with different SecDefaultAction.

---

## Phase discipline

ModSec rules run in one of five phases per request. Picking the wrong phase is the most common mistake the synthesizer can make. Costs and capabilities by phase:

**Phase 1 — request headers received.** Cheapest. Variables available: `REQUEST_URI`, `REQUEST_HEADERS`, `REMOTE_ADDR`, `REQUEST_METHOD`. Use for: URL-evasion rules, IP/geo blocks, header-based UA filtering, large `Content-Length` rejections. Cannot inspect body.

**Phase 2 — request body received.** Variables available: everything from phase 1 plus `ARGS`, `REQUEST_BODY`, `FILES_*`. Use for: payload inspection, SQLi/XSS filtering, file-upload screening. Most attack-blocking rules belong in phase 2. Cost: the body must be buffered, which respects `SecRequestBodyLimit`.

**Phase 3 — response headers received.** Use for: response-header sanitation, status-code-based intrusion detection (e.g., chained rule that escalates if many 404s from one IP). Variables available: response headers and status, plus everything from phases 1-2.

**Phase 4 — response body received.** Variables available: `RESPONSE_BODY`. Use for: data-exfil detection (cardholder data leaving in a response), response-content sanitation. Cost: response body buffering, also bound by limits.

**Phase 5 — logging only.** Variables available: everything. No disposition allowed (cannot block). Use for: audit-log enrichment, post-hoc tagging, conditional `auditlog` decisions.

Synthesizer rule of thumb: pick the **earliest** phase that has the variables you need. Cheaper phase = lower cost on every request.

---

## Anchor patterns by attack class

For each common attack class blacklight defends against, the canonical rule shape. The synthesizer adapts these — the shape is the constraint, the regex is filled from the case's evidence.

### URL-evasion (APSB25-94 PolyShell class)

The attack: a request to `something.php/banner.jpg?op=...` routes to PHP execution because of `AcceptPathInfo` or rewrite rules; the trailing `.jpg` defeats extension-based filters.

```apache
SecRule REQUEST_URI "@rx \.php(/[^?]*)?\.(jpg|jpeg|png|gif|svg|css|js|webp|bmp|ico)(\?|$)" \
    "id:9100,\
     phase:1,\
     deny,\
     status:403,\
     log,\
     auditlog,\
     msg:'PolyShell URL-evasion: image-extension trailing path on PHP',\
     tag:'attack-polyshell',\
     tag:'attack-url-evasion',\
     severity:'CRITICAL'"
```

Notes:
- Phase 1 is correct — the URI is enough. No body inspection needed.
- The regex is anchored on `.php` followed by an optional path-info segment followed by an image extension. Tighter than blocking all `.jpg` PHP requests (which would block legitimate URL rewrites).
- `auditlog` ensures the block surfaces in `/var/log/apache2/modsec_audit.log` for post-hoc review.

### Credential-harvest endpoint protection

The attack: POST to `/admin/auth` (or the obfuscated admin URL) at high rate with credential pairs, or POST with a session-stealing payload after harvesting from a compromised host.

```apache
SecRule REQUEST_URI "@rx ^/(admin|backend)/.*\b(auth|login)\b" \
    "id:9200,\
     phase:2,\
     chain,\
     deny,\
     status:429,\
     log,\
     msg:'Credential-harvest rate gate triggered',\
     tag:'attack-cred-harvest',\
     severity:'WARNING'"
    SecRule IP:cred_attempts "@gt 5" \
        "setvar:'IP.cred_attempts=+1',\
         expirevar:'IP.cred_attempts=300'"
```

Notes:
- Phase 2 because the chained rule reads request state.
- Chained rules: the first `SecRule` matches and arms; the second runs only if the first matched, and applies the disposition only if its own operator matches.
- `expirevar` decays the counter — a sustained low rate is allowed; a burst is blocked.

### Anticipatory block: known-bad C2 callback in egress

The attack: the host has been compromised and the operator is about to make a callback. blacklight knows the callback domain from prior cases on other hosts and blocks it on every host in the fleet, including ones never compromised.

```apache
SecRule REQUEST_HEADERS:Host "@pmFromFile /etc/modsec/blacklight-c2-domains.txt" \
    "id:9300,\
     phase:1,\
     deny,\
     status:403,\
     log,\
     auditlog,\
     msg:'blacklight: outbound to known C2 host',\
     tag:'attack-c2-callback',\
     severity:'CRITICAL'"
```

Notes:
- Outbound filtering via mod_security in front of `mod_proxy` (when the host proxies). Pure-server hosts also get this rule for cases where the webshell makes outbound via PHP `curl` and the request flows through a local Apache that proxies.
- `@pmFromFile` is the right operator for "any of N strings" — much faster than a giant `@rx` alternation.
- The file is generated by blacklight and shipped via the manifest; bl-apply drops it at the path Apache reads.

### Path-traversal + arbitrary file read

```apache
SecRule REQUEST_URI|ARGS|REQUEST_BODY "@rx (\.\./){2,}|%2e%2e%2f|%2e%2e/" \
    "id:9400,\
     phase:2,\
     deny,\
     status:403,\
     log,\
     t:none,t:urlDecode,t:lowercase,\
     msg:'Path traversal payload',\
     tag:'attack-path-traversal',\
     severity:'CRITICAL'"
```

Notes:
- Three transformations in chain: `none` to clear inheritance, `urlDecode` to normalize percent-encoding, `lowercase` so the regex doesn't have to alternate case.
- Catches `../../etc/passwd`, `%2e%2e%2fetc%2fpasswd`, `..%2f..%2fetc%2fpasswd` — the regex covers double-up the percent encoding plus the literal.

### File-upload screening (PHP in places PHP shouldn't be)

```apache
SecRule FILES_NAMES "@rx \.(php|php\d|phtml|phar|inc)$" \
    "id:9500,\
     phase:2,\
     deny,\
     status:403,\
     log,\
     auditlog,\
     msg:'File upload contains PHP-class extension',\
     tag:'attack-file-upload',\
     severity:'CRITICAL'"
```

Notes:
- `FILES_NAMES` is the multipart-form upload filename. The regex covers `.php`, `.php5`, `.php7`, `.phtml`, `.phar`, `.inc` — PHP can be invoked under any of these depending on host config.
- Pair with a separate phase-2 rule that inspects `FILES_TMP_CONTENT` for PHP magic bytes when paranoid — but at higher cost.

---

## Exception-list idioms

Most rules need carve-outs. The wrong way to express a carve-out is to widen the rule until the exception is implicit; that loses enforcement on cases the operator didn't anticipate. The right way is two-rule with explicit exception, or `ctl:ruleRemoveById` scoped to the legitimate path.

### Path-scoped exception via `ctl:`

```apache
# In the location-specific config or a phase:1 rule
SecRule REQUEST_URI "@beginsWith /vendor/legitimate/library/" \
    "id:9099,\
     phase:1,\
     pass,\
     nolog,\
     ctl:ruleRemoveById=9100"
```

The `ctl:ruleRemoveById=9100` strips rule `9100` (the URL-evasion rule) for this request only. ID `9099` sits one below the rule it's exempting — convention helps audit.

### Negation in the rule itself

For exceptions known at rule-write time:

```apache
SecRule REQUEST_URI "@rx ^/admin/(?!healthcheck/).*" \
    "id:9201,\
     phase:1,\
     ..."
```

Negative lookahead in the regex skips `/admin/healthcheck/...`. Use sparingly — regex-embedded exceptions are easy to mis-author and hard to audit.

### Known-benign IP allowlist

```apache
SecRule REMOTE_ADDR "@ipMatch 10.0.0.0/8,192.168.0.0/16,172.16.0.0/12" \
    "id:9001,\
     phase:1,\
     pass,\
     nolog,\
     ctl:ruleEngine=Off"
```

Disables the rule engine for internal-network requests. Use only when the internal network has its own controls — `ruleEngine=Off` lifts *all* rules for the request.

---

## Severity and disposition conventions

| Severity | When | Disposition |
|---|---|---|
| `CRITICAL` | Confirmed attack class, low FP risk | `deny, status:403` |
| `ERROR` | Strong signal, moderate FP risk | `deny, status:403, log, auditlog` |
| `WARNING` | Anomaly worth flagging, FP plausible | `pass, log, auditlog` |
| `NOTICE` | Behavioral marker for correlation | `pass, log` (no auditlog overhead) |

Status code conventions:
- `403` Forbidden — the default block response. Generic enough not to confirm rule presence.
- `404` Not Found — for traversal and probe attempts; tells the attacker their target doesn't exist.
- `429` Too Many Requests — rate-limit responses; semantic match for credential-harvest gates.
- `500` Server Error — avoid; tells the attacker something went wrong on the server side.

Never `301`/`302` — redirects can leak information and complicate logs.

---

## Rule ID allocation

ModSec rule IDs are integers, globally unique within the host's config. Collisions cause `apachectl configtest` to fail. blacklight reserves the range:

- `9000–9099` — exception/allowlist rules
- `9100–9199` — URL-evasion class
- `9200–9299` — credential-harvest class
- `9300–9399` — C2/egress class
- `9400–9499` — path-traversal class
- `9500–9599` — file-upload class
- `9600–9699` — XSS/SQLi (when CRS isn't sufficient)
- `9700–9799` — anticipatory rules (driven by `likely_next` capability map entries)
- `9800–9899` — case-specific custom rules (manifest carries the case_id mapping)
- `9900–9999` — reserved for operator manual additions; blacklight never auto-allocates here

Within each class, rules are allocated sequentially. The synthesizer must check the manifest's allocated IDs and pick the next available; ID collisions on regeneration are a `configtest` failure.

---

## Validator failure modes seen in the field

Things `apachectl configtest` rejects that the model needs to avoid:

- **Unescaped quotes inside the action string.** `msg:'It's a trap'` fails — the apostrophe terminates the string. Fix: `msg:'It\\'s a trap'` or rephrase to avoid the apostrophe.
- **Trailing commas in the action list.** `id:9100,phase:2,deny,` — the trailing comma is a parse error.
- **Newlines in action strings.** Multi-line `msg:` values break unless properly continued; safer to keep `msg:` to a single line.
- **`chain` without a follow-on `SecRule`.** A rule with `chain` action requires the *next* directive to be a `SecRule` that completes the chain. A `SecAction` or comment in between breaks the chain.
- **Unknown actions or operators.** The host's ModSec build determines which `@operators` and which actions exist. `@detectXSS` requires libinjection compiled in; older ModSec builds reject it.
- **Invalid phase numbers.** Phase 5 cannot have `deny`. Phase 1 cannot reference `ARGS` or `FILES_*` (no body yet).
- **Regex compile failures.** PCRE quirks: unescaped `{` in some positions, atomic groups in non-PCRE2 builds, named captures with hyphens. Test the regex with `pcregrep` against a fixture before emitting.
- **Variable-length lookbehinds.** PCRE rejects `(?<=.*)` patterns. Fix by anchoring the regex differently or using `@beginsWith` / `@endsWith`.

When `configtest` fails, the synthesizer captures the stderr block and writes it into the rule's `suggested_rules` entry. The operator sees the actual ModSec parser error, not a synthesizer-level summary.

---

## What this file is *not*

- Not the ModSec reference. See the OWASP ModSecurity v2/v3 reference manuals for full grammar.
- Not the OWASP CRS. CRS is a heavier ruleset; blacklight emits *case-specific* rules that complement CRS, not replace it.
- Not an iptables/APF reference. Network-layer blocks belong in `apf-grammar/` skill files.

<!-- public-source authored — extend with operator-specific addenda below -->
