# defense-synthesis — signature injection

Loaded by the router when a case has multi-host file evidence with shared family signature but divergent sha256 hashes — the shape that calls for a YARA or scanner rule instead of N quarantine actions. Complements `skills/ioc-aggregation/file-pattern-extraction.md` (which authors the rule body from the evidence) and `skills/webshell-families/polyshell.md` (which grounds the family signature). This file is about *delivering* a synthesized signature to the fleet's scanner without breaking the customer's benign PHP.

Every rule described here lands via the `synthesize_defense` custom tool (DESIGN.md §12.2) with `kind: sig`. The curator authors the rule body; the wrapper runs the corpus FP gate; the operator confirms or the `auto` tier applies automatically on FP-pass.

---

## Scenario

A PolyShell variant surfaced across three Magento hosts in the last ninety minutes. All three artifacts match the family signature (obfuscated eval-chain, media-tree drop path, unconditional C2 callback) but each has a distinct sha256 — the loaders differ by variable name mangling and chunk-reassembly shape. Quarantining the three artifacts closes the symptom but not the class; the next drop landing in the next hour will have a fourth sha256 and the quarantine won't fire on it.

The curator's job: author one YARA signature that matches the family across variants, deploy it to the fleet's scanner (LMD / ClamAV / standalone YARA, whichever the host runs), and do so without false-positiving the operator's benign composer vendor tree. The sections below are the discipline the curator follows to get that delivery right.

---

## Scanner detection — detect at apply

The curator does not pre-decide which scanner the fleet runs. The wrapper detects at apply time via directory presence and adapts the signature format, reload command, and scan verb. Detection probes:

| Scanner | Detection path | Sig format | Reload command | Active-scan command |
|---------|----------------|------------|----------------|---------------------|
| LMD (Linux Malware Detect) | `/usr/local/maldetect/sigs/` | Custom `.hex` or `.ndb` (ClamAV-compatible HDB) | `maldet -u` (refresh + signature activation) | `maldet -a <path>` |
| ClamAV | `/var/lib/clamav/` | `.hdb`, `.ndb`, `.ldb`, or `.yar` via `--yara-rules` | `freshclam` (or signal clamd to reload: `clamdscan --reload`) | `clamscan -r <path>` |
| standalone YARA | `/etc/yara/rules/` | `.yar` / `.yara` | `pkill -HUP yara` (if long-running daemon) or nothing (per-invocation scan) | `yara -r /etc/yara/rules/*.yar <path>` |

The wrapper checks in that order and picks the first match. If multiple scanners coexist on the host (LMD + ClamAV is common on cPanel fleets), the curator emits one `synthesize_defense` per scanner — the rule body is adapted to each format by the synthesizer sandbox. LMD consumes ClamAV-compatible HDB databases plus its own `.hex` format; ClamAV consumes YARA via `--yara-rules` starting ClamAV 0.100; standalone YARA is the most portable but requires the operator to wire the scan cadence themselves.

Public references:
- https://www.rfxn.com/projects/linux-malware-detect/ (LMD signature format + `sigpack` conventions)
- https://docs.clamav.net/ (ClamAV signature reference, YARA integration docs)
- https://github.com/VirusTotal/yara (YARA canonical repo, rule reference)

---

## Corpus FP gate — every signature runs against the operator's benign corpus first

This is the gate the `sig` kind of `synthesize_defense` preflights on. The curator sandbox:

1. Receives the candidate rule body from the curator.
2. Runs the rule against `/var/lib/bl/fp-corpus/` (the operator's benign-file corpus).
3. Counts matches. Any match > 0 blocks promotion. Zero matches → promote to `actions/pending/` with `action_tier: auto`.
4. On any match, demotes to `action_tier: suggested` and writes the matching paths into `reasoning` so the operator sees the collision.

The corpus is operator-curated and MUST include the following family-class samples before any sig promotion is trusted:

- A reference Magento 2.x composer vendor tree — typically `vendor/` under a fresh `bin/magento setup:install` on the operator's standard Magento release, seeded once from an unmodified install.
- ionCube loader fragments — the ionCube-encoded PHP shape is a frequent false-positive for "loose eval chain" signatures. Operators serving customers on ionCube-licensed libraries MUST have at least one sample in the corpus.
- SourceGuardian fragments — same reasoning as ionCube; distinct signature shape; separate sample.
- WordPress plugins obfuscated for license enforcement — `all-in-one-wp-migration`, `wp-rocket`, commercial theme vendors. These are not malware but they share the eval-chain obfuscation pattern.
- Reference frameworks the fleet hosts — Laravel vendor tree, Symfony vendor tree, Drupal core, any other frameworks the operator runs at scale.

**Floor size: ≥1000 benign PHP files.** A corpus with 50 files is a skip-promotion condition, not a FP-gate. The wrapper refuses `synthesize_defense` with `kind: sig` if `find /var/lib/bl/fp-corpus/ -name '*.php' | wc -l` returns fewer than 1000 — operator must seed the corpus before the sig path is usable.

The corpus refresh discipline: re-seed on operator-release-version bump (new Magento release, new plugin version). Stale corpus is worse than no corpus — a plugin that the corpus covered pre-bump may have new obfuscation shapes post-bump that the sig mistakes for adversary activity.

---

## Append-then-reload atomicity

Writing a signature file mid-scan is a race. The wrapper follows append-then-reload atomicity for every sig deploy:

1. Write the new rule body to `/usr/local/maldetect/sigs/bl-rules.new` (or scanner-equivalent `.new` path).
2. Compute sha256 of the `.new` file and compare against the rule body the curator emitted. Mismatch → abort (disk corruption, truncation).
3. `command cp -a` the existing `bl-rules` file to `bl-rules.bak` — pre-state backup for rollback.
4. `command mv -T bl-rules.new bl-rules` — atomic rename on POSIX filesystems; no scanner sees a half-written file.
5. Run scanner-specific reload: `maldet -u`, `freshclam`, `pkill -HUP yara`, or nothing for per-invocation scans.
6. Run a scan against a single known-bad staging file to verify the rule loaded. On fail, restore from `bl-rules.bak` and reload again.
7. On success, write the applied action to `bl-case/CASE-<id>/actions/applied/<act-id>.yaml` with the rule body, backup path, and verification hit.

Rollback path on any step 2-6 failure: `command mv -T bl-rules.bak bl-rules` + scanner reload. The `.bak` file persists for 7 days by default; `/var/lib/bl/quarantine/` cleanup does not sweep it.

Why atomic: signature activation touches the fleet's real-time scanner. A half-written YARA rule doesn't just fail to load — on some scanner builds it crashes the scan daemon (ClamAV pre-0.104 is known to SIGSEGV on malformed YARA). Atomic rename means the scanner either sees the old file (valid, working) or the new file (valid, new rules) — never a concatenation of both.

---

## Rule-naming convention

Every signature blacklight emits carries a name that encodes attribution, axis, authoring date, and a content hash for de-duplication. Shape:

```
BL_<family>_<variant>_<YYYYMMDD>_<short-hash>
```

- `<family>`: attribution group. `polyshell`, `magecart`, `weevely`, `filesman`. Matches the corresponding `skills/webshell-families/*.md` file name when one exists; unknown families get a fresh slug and a new skill file.
- `<variant>`: axis of the specific rule. `loader` (entry-point eval chain), `dispatch` (handler table grep), `callback` (C2-URL pattern), `skimmer` (JS template rewrite). One rule per axis is the target; multi-axis combinations go in `skills/ioc-aggregation/file-pattern-extraction.md`'s worked example rule.
- `<YYYYMMDD>`: the authoring date in UTC. Not the case date — the rule date, because the same rule may be re-used across cases.
- `<short-hash>`: first 8 hex characters of `sha256(rule_body)`. The hash is computed after normalizing whitespace (tabs → spaces, trailing whitespace trimmed) so equivalent rules across re-emits collapse to the same hash.

Concrete: `BL_polyshell_loader_20260424_a7f3b12c`.

The hash suffix deduplicates. If the curator emits a rule the fleet already has (same body, same hash), the wrapper sees the existing rule name and skips the apply — idempotent re-emit. De-dup is load-bearing because the curator may propose the same rule across three hosts in the same batch; without dedup, the scanner's rule file would grow three duplicate entries and slow every future scan.

---

## Non-obvious rule — condition MUST combine ≥2 axes

A loose single-axis signature is a triage signal, not a deployable rule. `rule { strings: $a = "eval(base64_decode" condition: $a }` matches PolyShell — AND matches every ionCube-encoded library fragment, every SourceGuardian obfuscation, every WordPress plugin that the vendor has obfuscated for license enforcement. The rule would trip at scale on the operator's benign customer fleet.

Rule: **every `synthesize_defense` sig emit MUST combine at least two distinct feature axes in the `condition:` block**. Axes:

- **Strings axis:** `$foo` literal or regex matches in the file body.
- **Filesize axis:** `filesize < N` and/or `filesize > M`. PolyShell variants cluster 4–12 KB; a condition `filesize < 16384 and filesize > 2048` rejects 1 KB partial drops and 200 KB vendor bundles.
- **Path-leaf axis:** custom YARA external variable set by the scanner for the file's filesystem path (`import "filemagic"` not always available; YARA 4.x supports `filepath` via external variable or `@` meta-match with host configuration).
- **Magic-byte axis:** first-N-bytes match — `<?php\s+eval`, `<?php\s+\$_=` entry-point fingerprints distinguish drops from legitimate `<?php declare(strict_types=1)` preambles.

The `condition:` block combines ≥2 axes via `and`. One-axis rules (`condition: $a`) are triage signals — the curator uses them for `observe.*` exploration, not for `defend.sig` application.

Worked shape:

```yara
rule BL_polyshell_loader_20260424_a7f3b12c
{
    strings:
        $eval_chain = /eval\s*\(\s*gzinflate\s*\(\s*base64_decode/
        $chr_ladder = /chr\s*\(\s*0x\w{2}\s*\)\s*\./
    condition:
        any of them
        and filesize < 16384
        and filesize > 2048
}
```

The `any of them` clause on strings + the filesize band is two axes — strings axis plus filesize axis. A fleet-deployable rule. Single-string-axis rules without a filesize bracket get returned by the sandbox with a `REQUIRES_SECOND_AXIS` reason and stay in `pending/` until the curator revises.

---

## Failure mode — empty FP corpus

Concrete failure: operator bootstrapped blacklight yesterday. `/var/lib/bl/fp-corpus/` is empty. Curator authors a PolyShell rule, `synthesize_defense` runs — no FP corpus to test against. Wrong move: promote to `auto` anyway ("nothing to FP against, clean gate"). Right move: fail-closed.

The wrapper enforces the floor:

```
bl-defend sig: REFUSED
  reason: /var/lib/bl/fp-corpus/ contains 0 PHP files (floor: 1000)
  remediate: seed the corpus before any sig deploy
    bl setup fp-corpus --from-magento-reference-install <path>
    bl setup fp-corpus --from-ioncube-samples <path>
    bl setup fp-corpus --from-wordpress-plugin-audit <path>
  escalate: bl defend sig <rule> --unsafe --yes (deploys without FP gate; strongly discouraged)
```

The floor is the operator-protection boundary. Operators under pressure reach for `--unsafe --yes`; the flag pair acknowledges that the deploy is going out without FP confirmation. The ledger entry records the override so the next-on-call sees what happened.

The observed-from-field precedent: pre-blacklight, responders deployed YARA rules built from a single-host sample, scanned a customer fleet, and generated ~40k false-positive hits across ionCube-licensed libraries. The responder then spent six hours whitelisting the collisions. The corpus gate eliminates that class of failure at the preflight layer.

---

## Applied example — three hosts, one rule, one deploy

The scenario resolves under these disciplines:

1. Curator reads the three PolyShell artifacts via `observe.file` (JSONL summary into `bl-case/CASE-2026-0012/evidence/`).
2. `file-patterns.md` aggregation collapses the three sha256s onto a shared loader signature — `eval(gzinflate(base64_decode(`, chr-ladder alternative entry, media-tree drop path.
3. Curator invokes `synthesize_defense` with `kind: sig, payload: <rule body>, target_scanner: auto`.
4. Sandbox detects scanner — LMD on all three fleet-homogeneous hosts.
5. Sandbox adapts rule to LMD's YARA consumption format, runs against `/var/lib/bl/fp-corpus/` (operator-seeded corpus has 4,200 PHP files: reference Magento + composer vendor + two customer WordPress plugin baselines).
6. FP gate: zero matches. `action_tier` stays `auto`.
7. Wrapper writes the rule to `/usr/local/maldetect/sigs/bl-rules.new` on each host via parallel ssh, atomic-renames, runs `maldet -u`, verifies via a known-bad staging scan.
8. `actions/applied/` entry written with `rule_name: BL_polyshell_loader_20260424_a7f3b12c`, backup path, verification scan result, retire hint (90 days — sig rules have longer default retire than firewall blocks because they're lower-collateral).
9. Slack notification sent with a 15-minute veto window. No operator intervention → rule graduates to long-retention.

Five minutes from curator recognition to fleet-wide active defense. The corpus gate and the atomic rename are the two disciplines that make the auto-tier safe.

---

## What this file is *not*

- Not a YARA reference. See https://yara.readthedocs.io/ for the canonical rule reference.
- Not a replacement for the operator's scan cadence. blacklight deploys rules; scanning schedules remain operator-owned (LMD cron, ClamAV freshclam cadence, standalone YARA invocations).
- Not a guide to writing detection signatures from scratch. See `skills/ioc-aggregation/file-pattern-extraction.md` for rule-body synthesis from per-file evidence.
