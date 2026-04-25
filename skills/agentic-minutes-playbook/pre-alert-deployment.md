# agentic-minutes-playbook — pre-alert deployment gate

Loaded alongside `advisory-to-detection-flow.md` whenever this bundle is in scope. The flow names the six stages; this file names the gate that decides when a queued action may deploy ahead of any local detection, and when it must wait.

---

## Two advisories, one week

APSB25-94 publishes 2025-10-14 with a high-confidence IOC (specific `POST` paths under `/rest/V1/<endpoint>`, body shape Adobe describes, image-extension URL-evasion per `apsb25-94/exploit-chain.md §Initial access vector`), public reproduction inside 48 hours, OWASP CRS reference rule. Three days later a second advisory drops with a vague capability ("file inclusion possible") — no IOC, no reproduction, no reference rule.

The first is a candidate for pre-alert deployment. The second is not — the rule is technically authorable, the FP-gate may pass, but the IOC is too vague to bet the fleet on. The gate decides which profile permits which posture.

---

## The four-axis gate

Pre-alert deployment is multi-axis, not scalar. Four axes evaluated independently, combined as AND for `auto` tier:

| Axis | Pass | Partial | Fail |
|------|------|---------|------|
| **Advisory-confidence** | Vendor advisory + IOC specificity (paths, body fields, file magic) + public reproduction | Vendor + partial IOC (class named, no pattern) | Capability without IOC, or third-hand without primary cite |
| **FP-gate** | Zero matches on benign corpus (≥1000 PHP per `sig-injection.md §Corpus FP gate`) | Non-zero, bounded paths | Non-zero outside bounded paths, OR floor not met |
| **Rollback envelope** | Single-command rollback parses, names same artifact | — | No rollback, OR does not parse, OR non-existent verb |
| **Blast-radius** | Low (no legitimate tenant; ASN off CDN safelist) | Medium (some tenants; partial CDN overlap) | High (most tenants; ASN on CDN safelist per `firewall-rules.md`) |

Pre-alert deploy on `auto` requires pass on all four. Any partial flips `action_tier` to `suggested`. Any fail flips to wait-for-detection — action sits in `actions/pending/` with `gate_status: rejected, reason: <axis>_<level>` until profile improves or a local fire anchors a true-positive.

---

## The silent-failure mode

A vague advisory still produces an authorable rule. Syntax passes. FP-gate may pass — no benign-corpus collision because the IOC is so specific nothing matches. Trap: the rule misses the actual exploitation when it arrives, because the advisory's IOC was wrong. Operator believes the fleet is defended; exploitation fires through the gap.

The failure is silent — the rule returns no error, it just does not match the bytes the adversary sends. The four-axis gate refuses the deploy *despite* technical validity, because the advisory does not name a specific enough IOC for the bet to be sound.

The wrapper enforces refusal at the `actions/pending/` → `actions/applied/` transition: `gate_status: rejected, reason: low_advisory_confidence` writes into the ledger so the next-on-call sees the axis it failed on.

---

## No rollback path = no deploy

If the curator cannot author a single-command rollback, deploy is gated to wait-for-detection regardless of the other axes. Inventory:

- ModSec → `bl defend modsec --remove <id>`.
- Firewall → `bl defend firewall --remove <ip>` (backend per `firewall-rules.md`).
- Signature → `bl defend sig --remove <name>` (per `sig-injection.md §Append-then-reload atomicity`).

A genuinely irreversible action routes to `destructive` tier per `docs/action-tiers.md` and waits for sign-off plus a local true-positive.

---

## Operator-supplied threshold judgment

The four-axis gate is the public-only floor. Live operator practice — which advisories the team has paid for in past incidents — is supplied at runtime, not skill-encoded. The gate hands a structured `gate_status` and four axis verdicts; the operator decides override (`--unsafe --yes`) or wait.

---

## Public-source grounding

- OWASP CRS — `https://coreruleset.org/docs/`.
- Adobe APSB25-94 — `https://helpx.adobe.com/security/products/magento/apsb25-94.html` (advisory-confidence axis example).
- `defense-synthesis/firewall-rules.md` — CDN safelist, blast-radius.
- `false-positives/assessment-discipline.md` — FP-gate parent.
- `ir-playbook/case-lifecycle.md` §Calibrated confidence — confidence parent.

---

## Cross-references

`SKILL.md`, `advisory-to-detection-flow.md`, `defense-synthesis/*`, `false-positives/assessment-discipline.md`, `ir-playbook/case-lifecycle.md`.

<!-- public-source authored — extend with operator-specific addenda below -->
