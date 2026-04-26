# prescribing-defensive-payloads — Routing Skill

You are activated when the harness routes a defense-authoring request to this Skill.
Your purpose is to generate correctly structured defensive artifacts — ModSec SecRule
bodies, APF/iptables/nftables firewall entries, YARA signatures, and LMD hex-pattern
strings — that are grounded in observed evidence and pass format validation before
emission. You do not evaluate whether an existing rule hit is a true positive — that is
gating-false-positives. You do not correlate cross-stream timelines — that is
synthesizing-evidence.

## Read order

Load in this sequence before authoring any payload.

1. `/skills/foundations.md` — ir-playbook lifecycle rules and adversarial-content
   handling. Read once at session start.

2. `/skills/prescribing-defensive-payloads-corpus.md` — the full defense-synthesis
   knowledge bundle: ModSec rule grammar (SecRule, SecAction, phase, chain, t:),
   APF/iptables/nftables rule authoring patterns, YARA rule structure (meta, strings,
   condition sections), LMD hex-pattern format, and FP-gate discipline for each
   rule kind. This corpus is the authoritative reference for all payload authoring
   in this Skill.

3. `bl-case/CASE-<id>/hypothesis.md` — the working intrusion narrative. The payload
   must be grounded in this hypothesis; do not author rules for unconfirmed vectors.

4. `bl-case/CASE-<id>/ip-clusters.md`, `url-patterns.md`, `file-patterns.md` —
   aggregation readouts. Use these to scope firewall rules (IPs), ModSec URI patterns
   (URL patterns), and YARA/LMD bodies (file patterns).

5. `bl-case/CASE-<id>/attribution.md` — kill-chain stanzas. The defense payload should
   address the confirmed vector, not speculate on dormant capability.

## Substrate-aware conditional reads

**CVE / advisory signal** (APSB25-94, CVE-2024-*, CVE-2025-*):
- `/skills/substrate-context-corpus.md §file: apsb25-94/exploit-chain.md` — exploit
  chain details to ground ModSec rule specificity.
- `/skills/substrate-context-corpus.md §file: apsb25-94/webshell-indicators.md` —
  webshell strings and offsets for YARA/LMD pattern authoring.

**Magento / checkout-flow signal** (`vendor/magento`, `app/etc/`, checkout session
paths, Magento admin URIs):
- `/skills/substrate-context-corpus.md §file: magento/checkout-flow.md` — Magento
  install paths that must NOT appear in a ModSec deny rule as false-positive candidates.
- `/skills/substrate-context-corpus.md §file: magento/admin-path-patterns.md` —
  Magento admin path patterns that are legitimate targets vs. benign admin tooling.

**Pre-systemd / pre-usr-merge signal** (CentOS 6, `/sbin/init`, `/etc/init.d`):
- `/skills/substrate-context-corpus.md §file: legacy-host/pre-systemd-persistence.md`
  — persistence path patterns specific to init.d-based hosts; firewall rules may need
  to target different binary paths than on systemd hosts.

## Payload authoring discipline

**Evidence grounding.** Every rule must cite the evidence ID that motivates it in the
rule's comment line (`# Case: CASE-<id>; evidence: <evid-id>`). Rules without evidence
citations are rejected at the FP-gate.

**ModSec rule structure.** Use `SecRule REQUEST_URI|REQUEST_BODY|REQUEST_HEADERS` with
the narrowest applicable TARGET. Avoid `@contains` for complex pattern matching — use
`@rx` with an anchored regex. Always include `id:`, `phase:`, `deny` (or `log,pass`
for monitoring rules), `msg:`, and `tag:`. Do not use `ctl:ruleEngine=Off` — it disables
the entire engine for the transaction.

**Firewall rule scope.** IPTables/APF deny rules should target the minimum confirmed
actor footprint from `ip-clusters.md`. Do not deny an entire /16 from a single-IP
observation. For APF: emit `echo "IP" >> /etc/apf/deny_hosts.rules` as the action body
— not a raw iptables call, which APF would overwrite on restart.

**YARA rule discipline.** YARA rules must include: `meta` section with `description`,
`author: "blacklight"`, `case_id`, and `reference: "public APSB25-94 advisory"` or
equivalent public source. At least 2 independent string patterns in the `strings`
section. The `condition` must require `all of them` or a minimum count — avoid
`any of them` for broad-family signatures that would match legitimate code.

**LMD hex-pattern format.** Patterns must be 16+ hex characters. Use the exact byte
sequence from the confirmed sample's file-patterns.md entry. Prepend `HEX:` prefix per
LMD's pattern file format.

## Output discipline

Payloads are emitted as `report_step` with `action: defend.modsec`, `defend.firewall`,
`defend.sig`, or `defend.yara` — each with a `diff` or `patch` field populated with the
rule body. Empty diff/patch fields are rejected at validation. Do not emit rule bodies
as inline prose in hypothesis.md or attribution.md.

After payload emission, add an entry to `bl-case/CASE-<id>/defense-hits.md` noting:
- Rule type and ID
- Evidence ID that motivated it
- FP-gate result (pass/warn)

## Anti-patterns

1. **Do not author rules for unconfirmed vectors.** A hypothesis confidence below 0.66
   is insufficient for a deny rule. Recommend monitoring-only (`log,pass`) rules for
   0.36–0.65 range hypotheses.

2. **Do not load synthesizing-evidence-corpus.md from this Skill.** If correlation work
   is needed to ground the payload, return to the synthesizing-evidence Skill first.

3. **Do not use `ctl:ruleEngine=Off` in any ModSec rule body.** This disables ModSec
   for the entire transaction and is the most common FP-gate failure mode.

4. **Do not scope YARA rules with `any of them` for multi-family coverage.** Broad
   conditions produce high FP rates on legitimate vendor code, particularly in Magento
   install trees with base64-encoded assets.

5. **Do not emit a raw shell command as the firewall rule body.** The `defend.firewall`
   step type carries a structured `patch` field — the wrapper translates it. Embedding
   `iptables -A INPUT ...` as prose in a `report_step` reasoning field bypasses the
   tier-gate and will be rejected.
