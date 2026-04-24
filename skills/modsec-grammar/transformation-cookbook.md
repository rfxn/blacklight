# modsec-grammar — transformation cookbook for evasion shapes

Loaded on every `bl consult --synthesize-defense` call when the evidence-pattern class shows evasion signals (transformation-laden payload, double-encoding, base64-wrapped body). Pairs with `rules-101.md` for the grammar floor; this file is the recipe catalog of *which transformation chains counter which evasion shapes* and *what the cost of each chain is at scale*.

Authoritative references: ModSecurity Reference Manual v3 on GitHub (`github.com/SpiderLabs/ModSecurity/wiki/Reference-Manual-(v3.x)`) for the transformation catalog and evaluation semantics; OWASP Core Rule Set `REQUEST-901-INITIALIZATION.conf` and `REQUEST-942-APPLICATION-ATTACK-SQLI.conf` for the transformation-chain idioms the CRS applies globally; OWASP Evasion cheat-sheet for the adversary-side shapes the chains counter. `rules-101.md:101-115` already enumerates the transformation list; this file composes them into recipes.

Note: `tag:'application-attack'` and `tag:'sqli'` strings are ModSec rule-engine grammar literals (OWASP CRS convention) — preserved verbatim for tool compatibility.

---

## Why transformations matter

A request arrives at the server encoded per the HTTP wire format: URL-encoded in the path and query string, form-urlencoded or multipart in `POST` bodies, occasionally base64-wrapped by intermediate tooling. An adversary leans on encoding to make a malicious payload look syntactically different from a naive signature until the moment the application decodes it. The transformation chain is how ModSec re-aligns the inspected value to the shape the application will execute.

Two invariants from the Reference Manual (transformations chapter):

- Transformations apply to the variable value before the operator runs. They do not mutate the request — downstream rules on the same variable see the untransformed value unless they re-state the chain.
- Transformations apply left to right. `t:urlDecodeUni,t:lowercase` is not the same as `t:lowercase,t:urlDecodeUni` — the second form lowercases the `%` sequence before decoding, which usually still works for ASCII but fails on `%C0` byte pairs that the `t:urlDecodeUni` operator handles differently at different case.

`t:none` resets the chain, so `"t:none,t:urlDecodeUni,t:lowercase"` explicitly overrides any default transformations from the surrounding config block (`SecDefaultAction` or a `SecRuleUpdateActionById`).

---

## The transformation catalog (selected)

Recap of the load-bearing transformations from `rules-101.md:101-115`, with the evasion shape each one counters:

- `t:urlDecode` — decodes `%xx`. Counters single-pass URL-encoded payloads. Example input `%75%6e%69%6f%6e%20%73%65%6c%65%63%74` → `union select`.
- `t:urlDecodeUni` — decodes `%xx` and `%uXXXX`. Adds IIS-style `%u0075` Unicode sequences. Broader than `t:urlDecode`; use as the default unless the body is known ASCII.
- `t:htmlEntityDecode` — decodes `&#65;`, `&amp;`, `&lt;`, etc. Counters HTML-entity-wrapped payloads in XSS contexts.
- `t:base64Decode` — decodes base64 from a variable value. Counters payloads smuggled as base64 strings (common in `POST` bodies wrapped for transport).
- `t:removeNulls` — strips `\0` bytes. Counters null-byte truncation patterns against backends that C-string the value.
- `t:lowercase` — case-fold. Counters `UnIoN sElEcT` case-randomization.
- `t:compressWhitespace` — collapse runs of whitespace to a single space. Counters `union/**/select` and `union  select` noise injection.
- `t:replaceComments` — replace `/* ... */` sequences with a single space. Counters `union/*anything*/select`.
- `t:normalizePath` — collapse `..` and `//` in path-like values. Counters path-traversal obfuscation.

The cost structure: every transformation runs per matching variable per request. A rule inspecting `ARGS` (a collection of many parameters) applies the full chain to every parameter value. Rules inspecting a single-variable target (`REQUEST_URI`, `REQUEST_HEADERS:X-Custom`) pay the chain once.

---

## Recipe — URL-encoded payload

The baseline chain every phase:2 content rule opens with:

```
SecRule ARGS "@rx (?:union\s+select|select.+from\s+[\w.]+)" \
    "id:100601,phase:2,deny,status:403,log,\
     t:none,t:urlDecodeUni,t:lowercase,t:compressWhitespace,\
     msg:'SQLi-shape in argument',\
     tag:'application-attack',tag:'sqli'"
```

Order matters:

1. `t:none` — drop any default transformations, so the chain is deterministic regardless of surrounding `SecDefaultAction`.
2. `t:urlDecodeUni` — decode wire-format URL encoding. After this, `%75` is `u`, `%uNNNN` is the Unicode code point.
3. `t:lowercase` — case-fold so the regex does not need `(?i)` or explicit alternation.
4. `t:compressWhitespace` — collapse multi-space and tab runs so the regex `\s+` matches cleanly against `union   select` or `union/**/select` (the latter after `t:replaceComments` if comment injection is in scope).

The chain composes for most phase:2 rules. Phase:1 rules against `REQUEST_URI` use the same opening but skip `t:compressWhitespace` — URIs do not typically carry whitespace, so the transformation is wasted work.

---

## Recipe — double-encoded

An adversary double-encodes (`%2575%256e%2569%256f%256e` → URL-decoded once → `%75%6e%69%6f%6e` → URL-decoded twice → `union`) to bypass one-pass rules.

Two approaches:

1. **Two-pass decode in the chain.** `t:none,t:urlDecodeUni,t:urlDecodeUni,t:lowercase`. The double application of `t:urlDecodeUni` re-decodes whatever the first pass produced. Cheap on a single variable; adds second-pass cost on a collection.
2. **Phase:1 normalization with sanity check.** A chained rule in phase:1 that sets a transaction variable when `REQUEST_URI_RAW` differs materially from `REQUEST_URI` post-decode; phase:2 rules then decode once more and key on the transaction variable. More plumbing, but avoids paying the second-pass cost on every request regardless of whether double-encoding was present.

The second pattern appears in OWASP CRS `REQUEST-901-INITIALIZATION.conf` — the CRS pre-computes normalization decisions in phase:1 and later rules key on transaction variables rather than re-decoding.

---

## Recipe — base64-wrapped body

A `POST` body of `cmd=ZWNobyAic2hlbGwi` (base64 of `echo "shell"`) evades a signature that looks for literal `echo` in `ARGS`.

```
SecRule ARGS:cmd "@rx (?:echo|system|passthru|shell_exec|eval)\s*[(\"'`]" \
    "id:100701,phase:2,deny,status:403,log,\
     t:none,t:base64Decode,t:lowercase,\
     msg:'command-exec shape in base64-wrapped argument',\
     tag:'application-attack',tag:'rce'"
```

`t:base64Decode` runs first because the variable value is the base64 string; lowercasing it before decode would produce a case-corrupted base64 string that decodes to garbage (`A` and `a` are different base64 code points). Decode, then lowercase the result, then match.

For a whole-body base64 wrap (an adversary uses `Content-Encoding: base64` or an API that treats the body as a base64-encoded inner payload), apply the transformation to `REQUEST_BODY`:

```
SecRule REQUEST_BODY "@rx ..." \
    "id:100702,phase:2,deny,t:none,t:base64Decode,..."
```

Cost on whole-body base64: one decode per request, bounded by `SecRequestBodyLimit`. Cheap at small body sizes; expensive at file-upload sizes — scope the rule by path or content-type to avoid paying the decode on legitimate large bodies.

---

## Recipe — Unicode normalization tricks

Adversaries substitute visually-identical Unicode code points for ASCII characters (`admin` with a Cyrillic `а` U+0430 for the `a`). A strict `@streq admin` fails to match.

```
SecRule REQUEST_URI "@rx /admin/" \
    "id:100801,phase:1,log,pass,\
     t:none,t:urlDecodeUni,t:lowercase,\
     msg:'admin-path request — inspection pass'"
```

`t:urlDecodeUni` handles the `%u0430` wire encoding. For post-decode Unicode (the request arrives with the actual UTF-8 bytes for U+0430, not the `%u` escape), there is no single transformation that case-folds across Unicode confusables. Compensations: use `@pmFromFile` with a confusable-expanded wordlist (OWASP evasion cheat-sheet ships one), or rely on the application's own canonicalization rather than ModSec inspection.

Unicode Technical Report 36 ("Unicode Security Considerations") catalogs the confusable-character problem. The ModSec side of the picture accepts the limitation rather than working around it — homoglyph defense lives in the application input layer, not in the WAF.

---

## Recipe — whitespace and comment insertion

SQLi signatures face `UNION/**/SELECT` and `UNION + tab + tab + SELECT` evasion patterns. The chain:

```
SecRule ARGS "@rx (?:union\s+select|select.+from)" \
    "id:100901,phase:2,deny,\
     t:none,t:urlDecodeUni,t:lowercase,t:replaceComments,t:compressWhitespace,\
     msg:'SQLi with comment or whitespace evasion',\
     tag:'application-attack',tag:'sqli'"
```

`t:replaceComments` runs before `t:compressWhitespace` because it produces whitespace — `/*foo*/` becomes ` ` (single space), and only after comment replacement does whitespace compression meaningfully collapse the result. Reversed order leaves the comment text embedded.

OWASP CRS `REQUEST-942-APPLICATION-ATTACK-SQLI.conf` applies this chain to every SQLi-class rule with one canonical ordering. Site-local rules that layer on top of CRS should match the ordering rather than inventing a new one — a split between CRS chain order and local chain order produces drift that shows up only when a specific evasion happens to fall between the two orderings.

---

## Cost implications

Every transformation runs per variable per request. Four cost-reduction patterns:

1. **Place rules in the earliest phase where the variables exist.** A URL-evasion rule in phase:1 against `REQUEST_URI` avoids the body parse entirely. `rules-101.md:21-29` frames this as the phase-cost rule of thumb.
2. **Restrict the variable target.** `ARGS:cmd` inspects one parameter; `ARGS` inspects every parameter. Rule writers reach for `ARGS` by default; the synthesis call should prefer the narrow target when the evidence-pattern class has a known parameter name.
3. **Scope by path or content-type.** Wrap expensive phase:2 rules in a `<LocationMatch>` or use an earlier chained rule to set a transaction flag. A base64-body rule that only applies to `/api/data` is cheaper than the same rule fleet-wide.
4. **Cache transformation results in `TX:` variables.** A phase:1 rule computes `TX:decoded_uri = %{REQUEST_URI}` after the chain runs; later phase:2 rules reference `TX:decoded_uri` directly. Avoids repeated transformation of the same value across a chain of rules inspecting the same variable.

Measured cost at scale is environment-dependent, but the ordering matters: a tight phase:1 rule with a short chain beats a broad phase:2 rule with a long chain for the same coverage, because the phase:1 rule fires before the body parse runs.

---

## Chain composition reference

Quick-reference table for synthesis-call emission. Each row names the evasion shape, the chain, and the minimum rule-side scoping to keep cost bounded.

| Evasion shape | Chain | Minimum scoping |
|---|---|---|
| URL-encoded SQLi | `t:none,t:urlDecodeUni,t:lowercase,t:compressWhitespace` | `ARGS:<named-param>` or phase:1 against `REQUEST_URI` |
| Double-encoded SQLi | `t:none,t:urlDecodeUni,t:urlDecodeUni,t:lowercase` | narrow variable target; phase:1 if inspecting URI |
| Base64-wrapped RCE arg | `t:none,t:base64Decode,t:lowercase` | `ARGS:<named-param>` only |
| Whole-body base64 | `t:none,t:base64Decode` | scope by `REQUEST_URI` path prefix |
| Comment-injection SQLi | `t:none,t:urlDecodeUni,t:lowercase,t:replaceComments,t:compressWhitespace` | same as URL-encoded SQLi |
| Unicode-confusable admin path | `t:none,t:urlDecodeUni,t:lowercase` + confusable wordlist via `@pmFromFile` | phase:1 against `REQUEST_URI` |
| Null-byte truncation | `t:none,t:removeNulls,t:lowercase` | depends on variable; phase:1 against `REQUEST_URI` for path-truncation shapes |
| Path-traversal obfuscation | `t:none,t:urlDecodeUni,t:lowercase,t:normalizePath` | phase:1 against `REQUEST_URI` or `REQUEST_FILENAME` |

The synthesis call selects a row by evidence-pattern class from the capability map and emits the chain plus the minimum-scoping directive. On operator review the chain can be tightened further (narrower variable target, tighter path scope) without changing the match semantics.

<!-- public-source authored — extend with operator-specific addenda below -->
