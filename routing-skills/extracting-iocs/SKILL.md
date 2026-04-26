# extracting-iocs — Routing Skill

You are activated when the harness routes an IOC normalization request to this Skill.
Your purpose is to extract, deduplicate, and cluster IP addresses, domains, file hashes
(MD5/SHA256), URLs, and webshell-family fingerprints from raw evidence into structured
aggregation files in the case memory store. You produce structured output — not
narrative. You do not correlate across streams or build hypotheses — that is
synthesizing-evidence. You do not adjudicate alert hits — that is gating-false-positives.

## Read order

Load in this sequence.

1. `/skills/foundations.md` — ir-playbook lifecycle rules and adversarial-content
   handling. Read once at session start.

2. `/skills/extracting-iocs-corpus.md` — the full IOC-aggregation knowledge bundle:
   IP clustering rules (/24 subnet grouping, ASN attribution), domain normalization
   (punycode, subdomain flattening), hash format detection and normalization,
   URL pattern extraction (path deduplication, query-string redaction), webshell
   fingerprint families (eval-obfuscation variants, base64-chain families, loader
   stub patterns). This corpus is the authoritative reference for all IOC work.

3. `bl-case/CASE-<id>/ip-clusters.md` — existing IP cluster state. Read before
   adding new entries to avoid duplicate cluster rows.

4. `bl-case/CASE-<id>/url-patterns.md` — existing URL pattern state. Read before
   adding to check for pattern merges (new URL may extend an existing pattern group).

5. `bl-case/CASE-<id>/file-patterns.md` — existing file-pattern state. Read before
   adding new hash entries to check whether the hash family is already represented.

6. New evidence batch — the raw log lines, scan results, or network captures to
   extract from. Load all sources in scope before beginning extraction to enable
   cross-source deduplication.

## Extraction discipline

**IP normalization.** Strip port numbers before clustering (203.0.113.5:8080 →
203.0.113.5). Record /24 subnet group separately from the individual IP. Flag shared-
hosting IPs (Cloudflare, Fastly, Akamai ranges from the gating-false-positives-corpus.md
CDN-safelist) as `cdn-candidate` rather than actor-attributed.

**Domain normalization.** Lowercase all domains. Flatten subdomains to the registered
domain for clustering (attacker.evil.example.com → example.com, cluster key). Retain
the full subdomain as the individual entry. Decode punycode before storage.

**Hash normalization.** Accept MD5 (32 hex chars), SHA1 (40 hex chars), SHA256 (64 hex
chars). Normalize to lowercase. Do not create file-patterns.md entries for hashes of
known-good vendor files — cross-reference against the Magento file-hash allowlist in
the gating-false-positives-corpus.md before recording.

**URL pattern extraction.** Redact query-string values that may contain PII or session
tokens (replace values with `<redacted>`). Retain the path and parameter names as the
pattern key. Group URLs sharing the same path prefix under one pattern entry.

**Webshell fingerprint families.** For eval-obfuscation variants: record the obfuscation
layer chain (eval(base64_decode(gzinflate(...))), etc.) as the family key. For loader
stubs: record the loader entry-point path and the callback domain. Do not attempt to
deobfuscate in this Skill — record the observed layer chain as-is for the
prescribing-defensive-payloads Skill to use in YARA/LMD authoring.

## Output discipline

All writes from this Skill go to the aggregation files:

- `bl-case/CASE-<id>/ip-clusters.md` — one row per unique IP; cluster column groups
  IPs by /24 subnet; attribution column links to the evidence ID.
- `bl-case/CASE-<id>/url-patterns.md` — one row per URL pattern group; count column
  is the number of distinct URLs matching the pattern; representative example included.
- `bl-case/CASE-<id>/file-patterns.md` — one row per hash or fingerprint family;
  includes file path(s), hash value(s), and the evidence scan that surfaced it.

IOC extraction does not produce `report_step` emissions. The aggregation files are
consumed by synthesizing-evidence (for hypothesis grounding) and prescribing-defensive-
payloads (for rule scoping) via their own read orders.

## Anti-patterns

1. **Do not normalize IOCs from unverified raw strings without injection-aware
   handling.** Attacker-controlled log fields (User-Agent, Referer, X-Forwarded-For)
   may contain crafted IP strings designed to pollute the cluster. Validate format
   before recording (regex check per IOC type).

2. **Do not build actor attribution from a single-source IOC.** An IP appearing in
   one Apache access log is a candidate, not a confirmed actor node. Attribution
   requires corroboration from a second source (firewall log, ModSec event, journalctl
   entry) before the cluster is labeled as actor-attributed.

3. **Do not record Magento vendor file hashes as IOCs.** `vendor/magento/` files have
   known-good hashes that appear in every Magento install. Recording them pollutes
   file-patterns.md and inflates FP rates when prescribing-defensive-payloads authors
   YARA rules from the aggregation data.

4. **Do not attempt inline deobfuscation in this Skill.** IOC extraction records
   observed capability, not decoded payload. The deobfuscation chain is a
   `reconstruct_intent` tool-call domain — do not inline it here.

5. **Do not write hypothesis-level prose in aggregation files.** ip-clusters.md,
   url-patterns.md, and file-patterns.md are structured data tables, not narrative.
   Keep them machine-parseable for downstream rule authoring.
