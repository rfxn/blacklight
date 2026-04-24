# ioc-aggregation — file pattern extraction

Loaded by the router when a case has multi-host file evidence sharing family signature but divergent sha256 hashes — the shape that calls for a single generalized YARA rule instead of per-hash quarantine actions. Complements `skills/ioc-aggregation/ip-clustering.md` (which clusters IP infrastructure from behavioral features) and `skills/ioc-aggregation/url-pattern-extraction.md` (which generalizes URL strings into ModSec rules); this file is the parallel discipline for file evidence.

The output of this work lands in `bl-case/CASE-<id>/file-patterns.md` (the case memory-store pointer file — see `docs/case-layout.md` §3) and becomes the rule-body payload for a `synthesize_defense` call with `kind: sig`. The delivery discipline for the rule — scanner detection, FP-gate mechanics, append-then-reload atomicity — lives in `skills/defense-synthesis/sig-injection.md`; this file is about feature selection from the per-file evidence, not the deploy mechanics.

---

## Scenario

Twelve PHP files have been quarantined across five compromised Magento hosts in the last six hours. All twelve match the PolyShell family signature (see `skills/webshell-families/polyshell.md` § Family signature) — obfuscated eval-chain entry, media-tree drop path, unconditional C2 callback in the decoded payload. All twelve have distinct sha256 hashes because each loader was generated fresh per drop: variable-name mangling rotates, the chunk-reassembly shape varies, the callback URL host label differs per host.

Hash-based quarantine closed the twelve symptoms. The thirteenth drop lands in the next hour with a thirteenth sha256; the hash-based rule set doesn't fire. The curator's job is to extract the features common across the twelve, pick the two or three that generalize without false-positiving the operator's benign composer-installed vendor trees, and compose one YARA rule that matches the family.

Wrong move A: emit twelve `BL_polyshell_<sha256>` rules. Rule file grows linearly with every case; scanner performance degrades; next drop sidesteps the entire set by changing one byte.

Wrong move B: emit one rule with `strings: $a = "eval(base64_decode" condition: $a`. Matches the twelve — and matches every ionCube-encoded commercial library, every SourceGuardian-obfuscated Magento extension, every WordPress plugin obfuscated for license enforcement. Benign-corpus false-positive rate blows through the FP gate (`skills/defense-synthesis/sig-injection.md` § Corpus FP gate) immediately and the rule stays in `suggested/` forever.

Right move: pick features on two or three distinct axes, combine them in a `condition:` block that requires co-occurrence, validate against a ≥1000-file benign corpus before promotion. The sections below are the discipline.

---

## Three feature axes

Every quarantined file varies on a handful of axes. Three axes generalize cleanly across PolyShell-class evidence; combinations of two or three of them are the feature set a deployable rule is built from.

**Magic-byte / string axis.** Strings that appear in every variant's file body. For PolyShell the durable strings are the obfuscation idioms themselves — the loader boilerplate and the assembled function name. Concrete shapes drawn from the files:

- `eval\s*\(\s*gzinflate\s*\(\s*base64_decode` — the canonical transform stack (detailed in `skills/obfuscation/gzinflate.md` and `skills/obfuscation/base64-chains.md`).
- `\$[a-zA-Z_]\w{0,8}\s*=\s*'ass'\s*\.\s*'ert'` — the split-string `assert` assembly that survives loader-axis rotation (`skills/webshell-families/minimal-eval.md` § Variable function call documents the variant).
- `chr\s*\(\s*0x\w{2}\s*\)\s*\.` — the chr-ladder alternative entry shape when the author wants to defeat `base64_decode|gzinflate` greps.
- `\$[a-zA-Z_][a-zA-Z0-9_]*\s*=\s*'AAAA'\s*\.\s*'BBBB'` — chunk-reassembly reassembly shape (`skills/obfuscation/base64-chains.md` § Split-string + base64 covers the variant class).

What is NOT durable on the string axis: the encoded blob itself (per-drop random), the variable names (per-drop mangled), the callback URL (per-host rotated). Authors who anchor a rule on the encoded blob's first 16 bytes get one-drop coverage and a zero-hit rule on the next drop.

**Path-leaf axis.** The filesystem path pattern where the artifact was found. PolyShell drop-path conventions (from `skills/webshell-families/polyshell.md` § Family signature) are remarkably stable across operator hands within a campaign:

- `pub/media/*/cache/*.php`
- `pub/media/wysiwyg/.system/*.php`
- `pub/static/frontend/*/.tmp/*.php`
- `vendor/*/cache.php`
- `app/code/*/Helper/.cache.php`

The `.cache`, `.tmp`, `.system` dotted-leaf convention is load-bearing — it survives cleanup tooling that filters on `*.php` directly under recognized public roots. Operators who drop outside these conventions exist (every few months) but they are a different actor class, not a PolyShell sub-variant.

**Filesize-band axis.** PolyShell loader-plus-payload files cluster in a tight byte range because the capability set is fixed and the obfuscation overhead is roughly constant. Observed bands:

- 4 KB – 12 KB: loader + single-capability payload (RCE only, or file-manager only).
- 8 KB – 20 KB: loader + multi-capability payload (RCE + file-manager + dormant harvester).
- 16 KB – 40 KB: loader + full capability set including skimmer module.

Below 2 KB: usually partial drops (the adversary aborted mid-upload) or minimal-eval variants (`skills/webshell-families/minimal-eval.md`) that are a different family.

Above 64 KB: almost never PolyShell. At that size the file is either a different family entirely (filesman, weevely) or a legitimate obfuscated library. A rule anchored on strings + filesize-band rejects the library class without needing a path-leaf match.

---

## YARA rule sketch template

The deployable shape combines ≥2 axes in the `condition:` block. A reference skeleton drawn from the Scenario's twelve files:

```yara
rule BL_polyshell_loader_20260424_a7f3b12c
{
    meta:
        family = "polyshell"
        variant = "loader"
        case = "CASE-2026-0012"
        authored = "2026-04-24"
        source_refs = "skills/webshell-families/polyshell.md, skills/obfuscation/base64-chains.md, skills/obfuscation/gzinflate.md"

    strings:
        $eval_chain = /eval\s*\(\s*gzinflate\s*\(\s*base64_decode/
        $assert_loader = /\$[a-zA-Z_]\w{0,8}\s*=\s*'ass'\s*\.\s*'ert'/
        $chr_ladder = /chr\s*\(\s*0x\w{2}\s*\)\s*\./
        $chunk_reassembly = /\$[a-zA-Z_]\w*\s*=\s*'[A-Za-z0-9+\/=]{4}'\s*\.\s*'[A-Za-z0-9+\/=]{4}'/

    condition:
        any of them
        and filesize < 16384
        and filesize > 2048
        and filepath matches /pub\/(media|static)\/.*\/(cache|\.system|\.tmp)\//
}
```

Three axes combined:

1. **Strings axis:** `any of them` across four alternative loader entry idioms. Any one PolyShell variant matches at least one; an operator who rotates the loader entry between drops still matches another.
2. **Filesize axis:** `filesize < 16384 and filesize > 2048`. Rejects 1 KB partial drops (under-size) and 20 KB+ obfuscated libraries (over-size). The band is tunable per case based on the observed fleet's loader size distribution.
3. **Path-leaf axis:** `filepath matches /pub\/(media|static)\/.*\/(cache|\.system|\.tmp)\//` — the standard PolyShell drop-path conventions. Non-standard drop paths fall through and don't match.

YARA's `filepath` external variable is scanner-specific — LMD supports it natively via its scan-context wrapping, standalone YARA requires `-d filepath=...` on invocation, ClamAV's YARA integration passes the file path as `filename` or `filepath` depending on build. The curator emits one rule body and the synthesizer sandbox adapts the variable name per detected scanner (see `skills/defense-synthesis/sig-injection.md` § Scanner detection).

---

## Corpus FP pre-gate — pattern-extraction discipline

The rule-body author's responsibility is the feature selection; the FP-gate mechanics belong to `skills/defense-synthesis/sig-injection.md` § Corpus FP gate. This section is about how the feature-selection choices affect FP-gate outcomes before the rule even reaches the gate.

Rules author themselves into FP-gate pass or fail by the axes they choose:

- **Single-axis rules fail.** A rule with `condition: $a` on any string axis is guaranteed to FP on a ≥1000-file corpus. The strings that appear in PolyShell also appear in legitimate encoded libraries; strings-only matching cannot distinguish them.
- **Two-axis rules usually pass.** Strings + filesize catches PolyShell while rejecting commercial libraries (which sit in a different filesize band — typically 64 KB+ for ionCube bundles). Strings + path-leaf also works well because commercial libraries live under `vendor/` with composer conventions, not under `pub/media/*/cache/`.
- **Three-axis rules are the safe default.** Strings + filesize + path-leaf requires co-occurrence across all three; the legitimate-library false-positive surface vanishes.

The feature-selection contract: **default to three axes unless one axis is genuinely absent from the evidence**. If the twelve files span five different filesize bands with no clustering, drop filesize. If the path-leaf axis is too noisy (operator-customized drop paths vary widely), drop path-leaf. Never drop the strings axis — strings are the only axis anchored to adversary tooling rather than drop environment.

---

## Non-obvious rule — condition MUST combine ≥2 axes

A one-axis condition block is a triage signal, not a deployable rule. The curator uses one-axis rules for `observe.file` exploration (`strings: $a = "eval(base64_decode" condition: $a` is fine as a candidate-surfacing filter when the goal is "show me every PHP file that might be a loader"). It is never emitted as `defend.sig`.

Rule: **every `synthesize_defense` sig emit for `kind: file-pattern` MUST have a `condition:` block combining at least two distinct feature axes**. Axes defined as: strings, filesize, filepath, filemagic (first-N-bytes match). The same axis does not count twice — two strings are still one axis. The sandbox rejects one-axis conditions with `REQUIRES_SECOND_AXIS` before the FP gate even runs.

Applied to the template above: `any of them and filesize < 16384 and filesize > 2048 and filepath matches ...` combines strings + filesize + filepath = three axes. Minimum acceptable. A rule with just `any of them and filepath matches ...` would be two axes (strings + filepath) and still pass the sandbox — acceptable but lower-confidence. A rule with just `any of them` on strings alone is one axis and the sandbox rejects it.

The rule is the operator-protection floor. It exists because pre-blacklight responders authored one-axis rules under incident pressure, generated tens of thousands of false-positive hits on customer fleets, and spent the remediation window triaging allowlists instead of hunting the actor. Two-axis minimum is what turns that into a preflight-blocked sandbox rejection rather than a production false-positive storm.

---

## Worked example — twelve files, one rule

Input: twelve quarantined PolyShell-era files from the Scenario. Axis analysis:

- **Strings:** all twelve match `eval\s*\(\s*gzinflate\s*\(\s*base64_decode`. Eight of twelve also match `\$[a-zA-Z_]\w{0,8}\s*=\s*'ass'\s*\.\s*'ert'`. Three match the chr-ladder `chr\s*\(\s*0x\w{2}\s*\)\s*\.`. One matches only the chunk-reassembly `'AAAA'\s*\.\s*'BBBB'` shape. Any of the four string alternatives catches every variant.
- **Filesize:** eleven of twelve land 3.2 KB – 11.8 KB. One outlier at 22 KB (carries dormant skimmer capability per `skills/webshell-families/polyshell.md` § Standard capability set). Band selection: `filesize > 2048 and filesize < 16384` covers the main cluster; the 22 KB outlier would need a second rule targeting the skimmer-carrying variant class separately, or a wider band `< 32768` if the operator wants one-rule coverage.
- **Path-leaf:** twelve of twelve under `pub/media/*/cache/*.php` or `pub/media/wysiwyg/.system/*.php` or `pub/static/frontend/*/.tmp/*.php`. Single regex `/pub\/(media|static)\/.*\/(cache|\.system|\.tmp)\//` covers all.

Output: the YARA rule above (main cluster, 11 of 12 files) plus an open-questions entry flagging the 22 KB skimmer-carrying outlier for a separate rule authored when more skimmer-variant evidence compounds. The main rule passes the FP gate at zero matches against a 4,200-file benign corpus (reference Magento install + composer vendor trees + two WordPress plugin baselines).

Before: twelve per-sha256 hash rules with one-case-only coverage.
After: one family rule with 11-of-12 coverage and variant-drift resilience. The thirteenth drop that lands tomorrow with a fresh sha256 matches on strings + filesize + filepath and fires at fleet-wide scan.

---

## Failure mode — rule author tests against a small corpus and misses the ionCube false-positive

Concrete failure: curator authors a two-axis rule (`any of them and filesize < 16384`) against a 50-file benign corpus seeded from the operator's own homedir. The 50 files are all legitimate Magento core PHP, none obfuscated. FP gate passes at zero matches. Rule promotes to `auto`. Deploy lands on a customer's ionCube-licensed extension tree — 400 FP hits across the customer's fleet within minutes of scan activation. Responder rolls the rule back; case's sig-coverage drops to zero.

The rule preempts:

1. **Corpus floor is ≥1000 benign PHP files.** `skills/defense-synthesis/sig-injection.md` § Corpus FP gate enforces this as a wrapper-level floor. 50 files is a skip-promotion condition.
2. **Corpus composition MUST include commercial-encoded samples.** At minimum: one ionCube sample, one SourceGuardian sample, one WordPress license-plugin obfuscation shape. Operators whose fleets host PHP-encoded commercial libraries MUST seed at least one representative file per encoder per release-version they support. The corpus is operator-maintained; the curator surfaces gaps via `open-questions.md` entries ("Corpus missing ionCube sample; next sig promotion may FP on customer ionCube trees").
3. **Three-axis preferred over two-axis for first-time family rules.** When the curator has evidence on the path-leaf axis, use it. The path-leaf axis is the strongest discriminator from commercial libraries (which live under `vendor/` with composer conventions).

Observed from public research: ionCube's obfuscation pattern (`IonCube Loader` comment, preceded by an `<?php` and a long base64 blob consumed by the ionCube binary) has string-axis overlap with PolyShell's eval-chain entry, but ionCube files are consistently 64 KB+ and live under `vendor/` subtrees. A three-axis rule rejects them cleanly. A two-axis rule without the filepath axis catches them. A one-axis rule catches them and also catches every WordPress plugin obfuscated for license enforcement.

Public references: https://yara.readthedocs.io/ (YARA rule reference, filesize and external-variable semantics), https://www.rfxn.com/projects/linux-malware-detect/ (LMD signature conventions, path-context wrapping), https://helpx.adobe.com/security/products/magento/apsb25-94.html (Adobe advisory grounding the PolyShell family evidence), https://sansec.io/research/magento-polyshell (Sansec's PolyShell research documenting drop-path conventions and loader variants).

---

## What this file is *not*

- Not a YARA reference. See https://yara.readthedocs.io/ for the canonical rule syntax, string-match semantics, and condition-block grammar.
- Not the delivery-mechanics spec. Scanner detection, FP-gate enforcement, and append-then-reload atomicity live in `skills/defense-synthesis/sig-injection.md`.
- Not the family-signature reference. The PolyShell family traits (drop-path conventions, loader-axis variants, dispatch-table shape) live in `skills/webshell-families/polyshell.md`; this file cites them as input, not as subject.
- Not an exhaustive feature catalogue. Other axes exist (import-table fingerprints for compiled PHP extensions, AST-shape matching for non-obfuscated shells). The three axes above are durable across PolyShell-class evidence and generalize to other PHP-webshell families with similar obfuscation-plus-path conventions.
