# ic-brief-format/operator-addendum-compliance — hosting-fleet compliance fields for IC briefs

Loaded on `bl case close` when the case's severity or attribution triggers a compliance-regime reporting requirement. Extends `ic-brief-format/template.md` with the compliance-metadata fields that convert the brief into regulatory / customer-QSA / BAA submission artifacts. Pairs with `severity-vocab.md` §P-ladder for trigger mapping.

---

## §1 — The scenario

02:43 UTC. A mid-market Magento merchant on the shared fleet — Braintree-tokenized checkout, assumed PCI SAQ-A, last QSA attestation 351 days ago, anniversary in 14 days — trips the curator's skimmer-injection finding on their checkout template. The curator's `hypothesis.md` crossed `confidence=0.84` at 02:37 UTC. The `attribution.md` capability map shows `observed` through `T1071.001 application-layer callback` (confirmed), `inferred` through `T1005 data-from-local-system`, `likely-next` on `T1041 exfil-over-C2-channel`. Two other tenants on the same shared node are PCI SAQ-D merchants; one is co-signed on a BAA with a telehealth customer. The merchant's residents include EU data subjects per the customer-residency table. `open-questions.md` is empty. `bl case close` is staged.

Four compliance-clocks started between 02:37 (first intrusion-confirming `observe.*`) and 02:43 (confidence crossed 0.5 with personal-data implication): PCI DSS §11.6.3 detection-recording for the merchant's next attestation; GDPR Art. 33 72-hour supervisory-authority notification (awareness crossed at 02:37); customer-contract 2-hour SLA notification for the enterprise-tier MSP wrapping the merchant; and — because the BAA-signed telehealth neighbor shares the node — a conditional HIPAA §164.408 clock pending tenant-isolation verification. SOC 2 Type II evidence capture started at case-open (02:29) and continues through close; the attestation window closes 2026-09-30, so the incident lands inside the current audit sample pool.

Which fields in the outgoing brief convert it into the customer's QSA evidence package rather than a narrative one-pager? Which curator findings become per-regime state the customer submits, versus provider-internal SOC 2 evidence? Which clock is the easiest to miss, and which is the costliest? Get those fields wrong in the brief and three things go wrong: the customer's QSA rejects the addendum as inapplicable boilerplate at anniversary, the provider's GDPR Art. 33 clock starts four hours late and triggers Art. 83(4) exposure, and the SOC 2 Type II auditor cannot tie the case file to Trust Services Criteria evidence at the next audit cycle.

## §2 — The non-obvious rule

**In web/platform-hosting IR, compliance drives the brief's metadata layer, not its narrative.** The same prose narrative (what happened, when, how, what we did) serves every regime. What changes per-regime is the *field set* appended to the brief that converts it into a regulatory submission, a QSA evidence package, a BAA incident report, or a SOC 2 Type II evidence artifact. The operator addendum is exactly this field set — and it is authored from the regimes that actually grade hosting, not the enterprise-SOC regimes generic compliance primers default to.

Why this matters: a generic name-drop ("PCI / HIPAA / GDPR / SOC 2 / ISO 27001 applicable") without hosting-specific grading produces addendum fields that do not help the customer's actual attestation and cannot be audited against the provider's actual control set. A hosting customer's QSA does not want "compliance officer signature" and "board notification"; the QSA wants detection timestamp, containment timestamp, affected-systems scope, customer-notification evidence, root-cause analysis, remediation confirmation. Those are the fields — derived from case state the curator already writes.

Corollary: the narrative body of the brief (per `template.md` §§1–9) never changes shape based on regime. The addendum is appended after §9 Lessons learned. A brief without an addendum is a brief for a regime-free case; a brief with an addendum that wrongly cites regimes is worse than no addendum at all.

## §3 — The hosting compliance grid

Regimes that actually grade web/platform-hosting IR, with the hosting-specific scope shift and clock-start for each. The provider's addendum cites only the regimes that apply to the implicated tenants.

| Regime | Applies when | Hosting-specific scope shift | Clock-start |
|---|---|---|---|
| PCI DSS v4.0 §11.6.3 | Any e-commerce tenant (Magento / Woo / BigCommerce / custom) after 2025-03-31 | Client-side tampering detection is a requirement even for tokenized SAQ-A merchants; provider's detection capability *is* the customer's §11.6 mechanism | Per-tenant attestation anniversary; detection-to-remediation is evidence for next attestation |
| PCI DSS SAQ-D | Shared-tenant node where any one tenant handles raw PAN (pre-tokenization or via vaulted form) | A single raw-PAN tenant pulls the provider into SAQ-D scope across the shared node | Quarterly re-scan cadence; immediate on confirmed compromise |
| SOC 2 Type II CC7.2 / CC7.3 / CC7.4 | Provider directly — virtually all commercial hosts carry Type II | Incident response is a Trust Services Criterion; case files *are* evidence, not supplementary to it | Annual attestation window; evidence-retention immediate on case open |
| HIPAA Security Rule §164.308(a)(6) / §164.408 | Tenant is a healthcare-SaaS covered entity under BAA + provider co-signed BAA; OR provider handles PHI in operational logs | Rare direct application in general hosting; sometimes pulled in via POST-body-logging LB configs | 60 days from discovery for individual notification (§164.408); immediate (without unreasonable delay) for >500 records |
| GDPR Art. 33 / Art. 34 | Any tenant or provider with EU data-subject scope | Awareness-based clock, not confirmation-based | 72 hours to supervisory authority from *awareness*; "without undue delay" to data subjects if high-risk |
| CCPA + US state breach laws | Any tenant with residents in a covered state (all 50 states have some form by 2026) | State-by-state timing variance; most 30 days, some 14 | 30–90 days typical; some states (TN, WA) 14 days from confirmation |
| ISO 27001 / 27035 | Provider contract requires certification | Incident management is documented process scope | Contract-defined; typically annual audit cycle |
| Customer-contract SLA | Enterprise MSP contracts with named-incident notification clauses | Often tighter than regulatory floor | 2-hour detection-to-notification is common for enterprise tiers |

Column authorities: PCI DSS v4.0.1 (PCI Security Standards Council); GDPR Art. 33 + Art. 34 (Regulation (EU) 2016/679) and EDPB Guideline 9/2022 on personal data breach notification; SOC 2 Trust Services Criteria (AICPA TSP 100, 2017 with 2022 revised points of focus); HIPAA Breach Notification Rule at `https://www.hhs.gov/hipaa/for-professionals/breach-notification/`.

## §4 — The addendum field set

Appended to the brief after §9 Lessons learned. Curator populates fields derivable from case state directly; operator-fill fields are marked inline.

```markdown
## §10 Compliance addendum

### §10.1 Timestamps (curator-populated from case state)
- Detection — first curator-emitted `observe.*` confirming intrusion: <case.timeline first intrusion-confirming observe row>
- Awareness — operator acknowledges case: <operator-populated; GDPR Art. 33 clock starts here>
- Containment — first `defend.*` or `clean.*` step applied: <first `bl-case/actions/applied/*.yaml` timestamp>
- Remediation confirmed — `bl case close` emitted: <closed.md timestamp>

### §10.2 Scope (curator-populated from hypothesis + attribution)
- Affected hosts: <count from hypothesis evidence-thread host list>
- Affected tenants: <count derived from host-to-customer mapping — operator-fill if mapping not in case>
- Data class at risk: <derived from `attribution.md` observed + inferred capability set>
- Confirmed data exfiltration: <yes | no | unknown> with citing evidence row id(s)

### §10.3 Attestation targets (operator-fill)
- PCI DSS attestation anniversary: <YYYY-MM-DD per implicated tenant>
- PCI DSS §11.6.3 in scope: <yes | no> (default yes for e-commerce tenants post-2025-03-31)
- PCI DSS SAQ level implicated: <A | A-EP | D-Merchant | D-SP | none>
- SOC 2 Type II audit window: <YYYY-MM-DD to YYYY-MM-DD>
- BAA-signed customers implicated: <list or "none">
- Regulatory jurisdictions in scope: <GDPR | CCPA | state-list — derived from tenant-residency data>

### §10.4 Regulatory submission state (operator-fill)
- GDPR Art. 33 submission required: <yes | no>
- GDPR Art. 33 submission timestamp: <ISO-8601 or "pending — due <deadline>">
- GDPR Art. 34 data-subject communication required: <yes | no — based on high-risk determination>
- US state-breach notifications triggered: <list of states + deadline per state>
- Customer-contract SLA notifications triggered: <list of customer-tier + notification timestamp>
- HIPAA §164.408 notification required: <yes | no>; if yes: <individual | media | HHS> recipients

### §10.5 Evidence preservation (operator-fill with curator-derived defaults)
- Chain-of-custody start: <case.open timestamp + operator name>
- Forensic artifact retention location: <e.g. /var/lib/bl/case-archive/<case-id>/ or operator S3 bucket>
- Artifact retention window: <PCI=3 years min; SOC 2=7 years min; HIPAA=6 years; GDPR=regime-defined>
- Destruction authority: <operator-fill>

### §10.6 Provider-side SOC 2 Type II evidence markers (curator-populated)
- CC7.2 monitoring evidence: <case.timeline of `observe.*` emissions; count + span>
- CC7.3 incident response evidence: <`bl-case/actions/applied/` ledger; count + span>
- CC7.4 recovery evidence: <case.close brief `closed.md` + T+30-day retire schedule>
- Sampled incident disposition: <case-id reference for auditor's annual sample>
```

Every curator-populated field maps to a specific case-state path per `DESIGN.md` §7.2. Operator-fill fields are the ones that require regime-specific knowledge the case state does not carry (tenant residency, contract tier, QSA identity, retention jurisdiction, risk-determination judgment). The addendum fails closed: any field left blank on a triggered regime is a case-close-blocker, enforced by `bl case close` exit 68 (see `case-lifecycle.md §Open questions grammar` — compliance addendum gaps route through `open-questions.md`).

Validation rules the wrapper enforces at close-time, in addition to the field-completeness check:

- `§10.1 Detection` must be <= `§10.1 Awareness` must be <= `§10.1 Containment` must be <= `§10.1 Remediation` (strictly monotonic; a violation usually indicates a mis-populated awareness field).
- If `§10.3 PCI §11.6.3 in scope: yes` and no §5-specific fields populated, exit 68.
- If `§10.3 BAA-signed customers implicated: <non-empty>` and `§10.4 HIPAA §164.408 notification required` is blank, exit 68.
- If `§10.4 GDPR Art. 33 submission required: yes` and `§10.4 GDPR Art. 33 submission timestamp` is blank *and* case-close is >72h after `§10.1 Awareness`, the wrapper emits a hard error naming the overrun rather than just exit 68.
- `§10.5 Artifact retention window` must be the maximum across all triggered regimes (PCI 3y, SOC 2 7y, HIPAA 6y, GDPR jurisdiction-specific), not the minimum — the addendum field validation computes the max from the triggered-regime list.

## §5 — PCI DSS v4.0 §11.6.3 specifics (Magento / e-commerce hosting)

The §11.6.3 mandate is named separately because it is the compliance grading point most commonly missed on hosting IR, because it is new (effective 2025-03-31), and because it applies *to the provider's detection capability* in ways enterprise-SOC compliance primers do not surface.

Requirement text (per PCI DSS v4.0.1): §11.6.3 requires "a mechanism is implemented to alert personnel to unauthorized modification" of payment pages, "at least weekly or at the frequency defined in the entity's targeted risk analysis." The requirement applies to all SAQ levels that include payment-page delivery, including SAQ-A merchants whose only involvement is iframe / hosted-field delivery of third-party-processor checkout.

Hosting-specific grading:

- The provider's client-side tampering detection (blacklight's skimmer detection via `skills/defense-synthesis/sig-injection.md` and `skills/magento-attacks/admin-backdoor.md`) *is* the customer merchant's §11.6.3 mechanism when the merchant relies on the provider for payment-page delivery. The merchant's QSA re-attests §11.6 conformance by citing the provider's attestation of the detection capability and the per-incident disposition of detection events.
- When blacklight lands a skimmer-injection finding, the addendum must include these §11.6.3-specific fields:
  - `§11.6.3 detection timestamp` — case.timeline first intrusion-confirming `observe.*` row
  - `§11.6.3 detection mechanism` — blacklight version + scanner-chain signature ID (e.g. `blacklight-0.3.1 + sig-skimmer-magento-v4`)
  - `§11.6.3 alert delivery` — to whom, when (operator-fill or derived from notification-channel config)
  - `§11.6.3 containment action` — first `defend.*` step applied + timestamp
  - `§11.6.3 customer QSA notification` — disposition per implicated tenant (notified / pending / not-applicable)
- These fields convert the brief into the merchant's §11.6 conformance-retest evidence for the next attestation. Without them, the merchant's QSA has no artifact to cite and the provider's detection capability does not count toward the merchant's re-attestation.

Edge case: tokenized SAQ-A merchants are sometimes coached by prior-generation QSAs that §11.6 "does not apply because we do not touch PAN." This is wrong post-2025-03-31 (PCI SSC FAQ 1588). The default for the addendum is `§11.6.3 in scope: yes` for all e-commerce tenants; the operator overrides only with a documented QSA determination that the specific merchant is out of scope.

Operational workflow at the §11.6.3 detection boundary: when a skimmer-injection finding crosses `confidence >= 0.7` on an e-commerce tenant, the curator emits an `open-questions.md` entry naming the tenant, the §11.6.3 detection timestamp, and the attestation anniversary (operator-fill). The operator resolves the entry at close-time by populating the §11.6.3 addendum fields; the brief cannot emit closed.md with an unresolved §11.6.3 question. The brief becomes the merchant's per-incident §11.6 evidence record, retained for the three-year PCI minimum retention window per PCI DSS v4.0 §10.5.1.

## §6 — GDPR Art. 33 awareness vs confirmation

The 72-hour clock is the most commonly mis-started clock in hosting IR. Art. 33(1) text (per `https://gdpr-info.eu/art-33-gdpr/`): "In the case of a personal data breach, the controller shall without undue delay and, where feasible, not later than 72 hours after having become aware of it, notify the personal data breach to the competent supervisory authority..."

"Aware" is not "confirmed." The EDPB Guideline 9/2022 on personal data breach notification clarifies awareness as "a reasonable degree of certainty that a security incident has occurred that has led to personal data being compromised." Awareness is meaningfully earlier than remediation and usually earlier than containment.

For hosting providers running blacklight, the operational mapping:

- Awareness = the first curator hypothesis revision where `hypothesis.md confidence >= 0.5` on a case that implicates tenant personal data per `attribution.md` observed-or-inferred data-at-risk capability. Per `case-lifecycle.md §Calibrated confidence`, this is the cross-category-corroboration anchor — one `observe.*` verb alone does not constitute awareness; two converging `observe.*` verbs do.
- The 72-hour clock starts at this timestamp, which is typically 2–8 hours before containment lands and 1–5 days before case close.
- The addendum `GDPR Art. 33 submission timestamp` field must record this awareness timestamp — not the confirmation timestamp, not the remediation timestamp.
- A brief that records the Art. 33 deadline relative to case.close rather than relative to awareness is the most common way providers miss the 72-hour window. Regulatory fines under Art. 83(4) reach 2% of global annual turnover for this specific failure mode.

Operational rule: when the curator crosses `confidence=0.5` on a personal-data-implicating case, the curator emits an `open-questions.md` entry of the form "GDPR Art. 33 awareness threshold crossed at <ISO timestamp>; operator: confirm EU data-subject scope and start 72-hour clock if applicable." This surfaces the clock-start to the operator before any other compliance decision.

Art. 34 data-subject communication is a separate clock with a "without undue delay" floor, triggered when the breach is "likely to result in a high risk to the rights and freedoms of natural persons" (Art. 34(1)). The addendum field `GDPR Art. 34 data-subject communication required` is operator-fill because the high-risk determination depends on data categories, exfiltration confirmation, and identifiability — case state surfaces the inputs but does not compute the determination. The curator's contribution is naming the data categories at risk per `attribution.md` capability inference; the operator's contribution is the risk-determination judgment.

Non-EU-but-adjacent regimes the addendum treats as GDPR-parallel for clock purposes: UK GDPR + Data Protection Act 2018 (same 72-hour clock, ICO as supervisory authority); Swiss FADP (72-hour clock); Brazilian LGPD (clock defined by ANPD guidance, typically 72-hour floor). The addendum field names the regime and the supervisory authority per implicated jurisdiction rather than assuming EU-default.

## §7 — SOC 2 Type II evidence integration

Most commercial hosting providers carry SOC 2 Type II attestations; the attestation is a required contractual artifact for enterprise MSP and hosted-SaaS sales motions.

The Trust Services Criteria that map directly to blacklight case state (per AICPA TSP 100, 2017 with 2022 revised points of focus):

- **CC7.2 — System monitoring.** The curator's `observe.*` emissions across the case are the monitoring evidence. A full case timeline demonstrates continuous observability across the incident window, not retrospective log-stitching. The addendum field `CC7.2 monitoring evidence` cites the timeline span (first observe → last observe) and the observe-verb count; auditors verify the span covers the full incident window with no gaps.
- **CC7.3 — Security incident response.** The `actions/pending → applied` transitions in `bl-case/actions/` are the response evidence. Each transition carries a timestamp, operator attribution, and a `defend.*` or `clean.*` verb. The addendum field `CC7.3 incident response evidence` cites the applied-ledger span and the action count; auditors verify that a documented response existed and escalated at appropriate severity thresholds per `severity-vocab.md`.
- **CC7.4 — Recovery.** The `closed.md` brief artifact plus the T+30-day firewall-retire schedule (per `DESIGN.md` §5.6 `bl case close`) are the recovery evidence. The addendum field `CC7.4 recovery evidence` cites the closed.md file_id and the retire-schedule reference; auditors verify that recovery completed and that residual controls (blocks, rules, sigs) have a planned lifecycle, not permanent accumulation.

The grading hook most enterprise-compliance content misses: SOC 2 Type II audits ask for sampled incident evidence annually. A blacklight-generated brief with the compliance addendum is a *self-contained evidence unit* for CC7.2–7.4 — the auditor does not need to stitch together logs, tickets, and runbook artifacts across separate systems. One case file carries all three criteria's evidence in one addendum block. This is the structural advantage that makes case files first-class SOC 2 artifacts rather than supplementary documentation.

For providers with ISO 27035 incident-management requirements, the same case file + addendum satisfies ISO 27035 §6 (incident reporting) and §7 (incident response) evidence; the regime-specific addendum field is ISO-audit-cycle timestamp rather than SOC 2 attestation window. ISO 27001 Annex A.16 (information security incident management) is satisfied by the same evidence with a different audit-cycle reference.

## §7.5 — SAQ-D spillover and customer-contract SLA

Two hosting-specific dynamics worth naming separately because they are frequent failure modes on the addendum:

**SAQ-D spillover on shared-tenant nodes.** When a single tenant on a shared node handles raw PAN (pre-tokenization form, vaulted-form exception, or legacy integration), the provider's scope for that node rises to SAQ-D regardless of other tenants' SAQ levels. A skimmer incident on a SAQ-A tenant sharing a node with a SAQ-D tenant pulls the SAQ-D tenant's attestation into the incident addendum — the SAQ-D tenant's QSA is entitled to evidence that the shared-node compromise did not traverse tenant isolation. The addendum must enumerate *all* tenants on the affected node, not just the directly-implicated tenant, with an isolation-integrity note per tenant ("tenant-isolation verified per per-user `open_basedir` + CageFS boundaries, no cross-tenant reads in incident window"). PCI SSC guidance on shared environments: PCI DSS Shared Hosting Guidelines (Information Supplement).

**Customer-contract SLA notification clocks.** Enterprise MSP contracts commonly impose notification clocks tighter than any regulatory regime — 2-hour detection-to-notification is standard for enterprise-tier contracts, 4-hour for mid-market, 24-hour for SMB. Customer-contract clocks are addendum-relevant because they typically start at *detection*, not awareness — earlier than the GDPR clock, usually earlier than containment. The addendum field `Customer-contract SLA notifications triggered` must enumerate per-tenant tier + contractual clock-start + actual notification timestamp; a contractual clock missed is a contract-breach remediation path (service credits, termination-for-cause triggers) separate from the regulatory path. The curator cannot populate contract-tier from case state — the `operator-fill` discipline on this field is absolute.

## §8 — What this file is not

- Not a generic enterprise-compliance primer. ISO 27001 Annex A controls, NIST CSF functions, COBIT 2019 objectives, HITRUST CSF, StateRAMP, FedRAMP Moderate — these regimes exist and some apply to hosting in specific contracts, but they do not change the *brief field set* for web/platform-hosting IR in ways that justify dedicated skill coverage. The addendum scales to new regimes by adding fields, not by re-authoring the skill.
- Not a regulatory-submission template. The addendum names the *field set*; the actual submission format is per-regulator — GDPR supervisory-authority portal forms, state AG breach-notification templates, PCI Report on Compliance (ROC), HIPAA §164.408 submission forms. Operators adapt the field values to the regime-specific form on submission.
- Not legal advice. References to compliance regimes are operational, not legal. The provider's compliance counsel makes in/out-of-scope determinations per customer contract; the addendum captures the evidence their determination rides on.
- Not a replacement for the provider's overall SOC 2 / ISO 27001 / PCI DSS policy set. This skill populates the *incident-response slice* of those programs. The full program includes vendor management, access control, change management, BCP/DR — blacklight cases are a single control-family's evidence, not the whole program.
- Not operator-specific escalation routing. On-call paging, named-responder ownership, incident-channel conventions — covered separately by the TODO(gap) in `case-lifecycle.md §Operator-specific layers` when that layer lands.

## §9 — Failure modes

Three concrete failure modes, each with a rule preempt.

**Failure mode 1 — the generic-compliance-boilerplate trap.** Operator addendum cites "HIPAA Privacy Rule notification required" on a non-healthcare customer's case because a generic template enumerated HIPAA as one of the named regimes. Customer's QSA reviews the addendum at anniversary attestation and flags it as inapplicable boilerplate; customer's audit credibility takes damage; provider's own SOC 2 auditor questions the provider's process rigor. *Rule preempt:* §3 hosting compliance grid lists only regimes that apply to hosting; §4 addendum field set requires the provider to *name the implicated tenant* when citing a regime. A HIPAA line without a BAA-signed customer entry is invalid; `bl case close` rejects the brief with exit 68 and routes back to `open-questions.md`.

**Failure mode 2 — the 72-hour-clock miss.** Operator starts the GDPR Art. 33 clock at `case.close` (remediation confirmed) rather than at awareness; submits to the supervisory authority 96 hours after awareness; regulator fines the provider directly under Art. 83(4) for the 24-hour overrun. *Rule preempt:* §6 defines awareness operationally — first curator hypothesis crossing `confidence=0.5` on a personal-data-implicating case. The curator emits an `open-questions.md` entry at that threshold naming the clock-start; the operator cannot close the case without addressing it. The addendum field `GDPR Art. 33 submission timestamp` is validated against the awareness timestamp at case-close time.

**Failure mode 3 — the PCI §11.6 invisibility.** Operator closes a Magento-tenant skimmer case without flagging §11.6.3 in the addendum because the tenant is SAQ-A (tokenized). Customer's QSA discovers the gap at the merchant's anniversary attestation; the merchant cannot re-attest §11.6 conformance without the detection-capability evidence; the provider is named in the merchant's §11.6 conformance failure; cascading contract impact across other merchants on the shared node. *Rule preempt:* §5 makes `§11.6.3 in scope: yes` the default for all e-commerce tenants post-2025-03-31 regardless of SAQ level. Operator overrides only with a documented QSA determination; the override is a field-value, not a field-omission.

**Failure mode 4 — SAQ-D spillover silently dropped.** Operator closes a single-tenant skimmer case on a SAQ-A merchant without enumerating the SAQ-D tenant sharing the shared-hosting node, because the SAQ-D tenant showed no direct indicators. The SAQ-D tenant's QSA audit lands six months later with a request for evidence that the shared-node compromise did not traverse tenant isolation during the incident window; the provider cannot produce the isolation-integrity attestation because it was never captured in the case file. *Rule preempt:* §7.5 requires the addendum to enumerate all tenants on the affected node with per-tenant isolation-integrity notes, not just the directly-implicated tenant. The wrapper validation at case-close time checks `§10.2 Affected tenants` against the node's tenant-residency table and surfaces missing per-tenant isolation notes as an `open-questions.md` entry before closure.

## §A — Worked example — the §1 scenario rendered

Skill-internal appendix (not a brief section). The brief's §10 is the Compliance addendum block per §4; this appendix shows what that block looks like when rendered from a real case.

The §1 scenario's addendum, populated from case state at close-time. Illustrative values; real deployment would carry the operator's actual tenant names, jurisdictions, and contract tiers.

```markdown
## §10 Compliance addendum

### §10.1 Timestamps
- Detection: 2026-04-24T02:37:11Z (first intrusion-confirming `observe.htaccess` row id evid-0041)
- Awareness: 2026-04-24T02:43:02Z (hypothesis confidence crossed 0.5 on personal-data-implicating case)
- Containment: 2026-04-24T03:14:57Z (first defend.firewall applied; callback IP blocked at APF edge)
- Remediation confirmed: 2026-04-24T08:52:18Z (case close; checkout template restored, §11.6.3 detection re-verified)

### §10.2 Scope
- Affected hosts: 1 (shared node node-7)
- Affected tenants: 1 directly + 2 co-located (SAQ-D + BAA-telehealth)
- Data class at risk: tokenized payment data via T1071.001 confirmed callback; inferred T1005 local-data read
- Confirmed data exfiltration: unknown; callback established but observed payload size zero during window (evid-0048)

### §10.3 Attestation targets
- PCI DSS attestation anniversary: 2026-05-08 (tenant mage-merchant-a)
- PCI DSS §11.6.3 in scope: yes (e-commerce tenant post-2025-03-31)
- PCI DSS SAQ level implicated: A (direct); D-Merchant co-located on node-7 (tenant saq-d-neighbor)
- SOC 2 Type II audit window: 2025-10-01 to 2026-09-30
- BAA-signed customers implicated: telehealth-customer-b (co-located, no direct compromise signal)
- Regulatory jurisdictions in scope: GDPR (EU data subjects per tenant residency); CCPA (CA residents)

### §10.4 Regulatory submission state
- GDPR Art. 33 submission required: yes; deadline 2026-04-27T02:43:02Z; submitted 2026-04-24T11:17:00Z
- GDPR Art. 34 data-subject communication required: pending high-risk determination (operator-fill)
- US state-breach notifications triggered: CA (CCPA); deadline 2026-05-24
- Customer-contract SLA notifications triggered: mage-merchant-a (enterprise tier, 2h clock): notified 2026-04-24T04:30:00Z (within clock)
- HIPAA §164.408 notification required: no (telehealth tenant isolation verified; no PHI traversal)

### §10.5 Evidence preservation
- Chain-of-custody start: 2026-04-24T02:29:04Z (operator: on-call-a)
- Forensic artifact retention location: /var/lib/bl/case-archive/CASE-2026-0143/
- Artifact retention window: 7 years (SOC 2 max across triggered regimes)
- Destruction authority: compliance-lead (operator-fill)

### §10.6 SOC 2 Type II evidence markers
- CC7.2 monitoring evidence: 14 `observe.*` emissions across 6h23m span (02:29 → 08:52)
- CC7.3 incident response evidence: 4 applied actions across 5h38m span (03:14 → 08:52)
- CC7.4 recovery evidence: closed.md file_id fs-2026-0143-closed; retire schedule T+30d for firewall block (2026-05-24)
- Sampled incident disposition: CASE-2026-0143 (eligible for 2026 attestation sample pool)
```

Every field traces to a specific case-state path, a specific regime requirement, or an operator-fill decision. The auditor reads this addendum as a self-contained evidence record; the merchant's QSA reads it as §11.6 re-attestation input; the supervisory authority reads the §10.4 entries as Art. 33 submission backing; the SOC 2 auditor reads §10.6 as CC7.2–7.4 sample evidence. One artifact, many grading audiences.

---

*See also: `template.md` (brief section order); `severity-vocab.md` (P-ladder triggers that route to this addendum); `ioc-categorization.md` (IOC table this addendum summarizes into scope field); `executive-summary-voice.md` (§1 voice discipline that the addendum does not override); `case-lifecycle.md §Open questions grammar` (open-questions.md gate that holds compliance addendum unresolved fields).*
