# escalation-routing — hosting-fleet curator escalation discipline

Loaded on every revision call that yields `hypothesis.current.confidence >= 0.7` or populates `attribution.md` with a cross-host signature. Complements `case-lifecycle.md §Case splits and merges` — that file decides what the case *is*; this file decides *who hears about it first*. This file replaces the `TODO(gap): escalation routing` placeholder at `case-lifecycle.md` line 144.

## 1. The scenario

03:47 UTC. The curator lands a revision on `CASE-2026-0138` with support type `extends` and confidence 0.78. `attribution.md` now carries a cross-host stanza: 23 hosts on shared CloudLinux node `nyc-7` (see `skills/hosting-stack/cloudlinux-cagefs-quirks.md` for the node-boundary semantics) share a callback domain family and a payload mtime cluster inside a 14-minute window. The attribution signature — same callback parent domain, identical base64 obfuscation wrapper, consistent `/skin/frontend/default/` drop-path per the APSB25-94 reconstruction (public Adobe advisory: https://helpx.adobe.com/security/products/magento/apsb25-94.html) — matches `CASE-2026-0091`, a prior engagement on one of the currently-implicated customers, closed 62 days ago.

The next pending step in the case ledger is `defend.firewall` proposing a `/24` block on a Contabo range. One of the four IPs in that `/24` is already on the operator's curated CDN safelist — Cloudflare origin-pull overlap, detected by the safelist-preflight check per `skills/defense-synthesis/firewall-rules.md §CDN safe-list discipline`. The 23 implicated hosts break down to 18 distinct tenant-brands. Two of those tenants are in the November-December peak-commerce window. One is under an active PCI DSS attestation cycle.

Who does the operator page, in what order, via what channel? The answer is not what an enterprise SOC playbook would say. NIST SP 800-61 r2 § 3.2.7 (https://csrc.nist.gov/publications/detail/sp/800-61/rev-2/final) gives a responder-first sequence — primary on-call, then incident commander, then external notification. That ordering is calibrated for one org, one customer, single-trust-boundary SOCs. Applied to a hosting fleet where the provider sits *between* the adversary and tens of downstream customer-brands, the same sequence creates a 30-60 minute window where customers hear about their own compromise from a third party (Sansec's research feed at https://sansec.io/research, their own fraud-detection vendor, press) before they hear from the provider they pay for visibility.

## 2. The routing axis — the non-obvious rule

**In hosting-fleet IR, routing is ordered by *customer-communication-ownership* first, *technical response* second.** The reverse ordering — the enterprise-SOC default — is wrong for this shape.

The mechanical reason: a customer who finds out about a compromise on their own Magento shop from the Sansec research feed (https://sansec.io/research) before hearing from their hosting provider has had the central truth of "this provider has visibility into my exposure" falsified in real time. Truth of visibility is the provider's entire product. Technical containment recovers in 4 hours; the trust deficit from a reversed notification sequence lasts 6 months and shows up as churn on the next renewal cycle.

The second-order reason: customer-success organisations carry the per-tenant communication preferences, the prior-engagement context, the regulatory-clock state, and the language discipline that keeps a technical containment action from being written up internally as a provider-initiated outage. Routing around them to reach technical oncall faster is a local optimum that costs the provider globally.

The third-order reason, less visible but operationally real: technical containment on a shared-hosting platform often involves moves that a single-tenant enterprise SOC never makes — disabling a customer's `.htaccess` rule, quarantining a cron that belongs to a legitimate site operator, blocking an IP range that turns out to include the customer's own office network. Each of those moves is a customer-visible event whether or not it is security-effective. The customer-success org is the only function in the provider that understands which of those moves a specific tenant will tolerate without escalating to their own legal team. Primary-oncall does not have that context; it lives in the customer-success ticket history.

This rule inverts for single-tenant enterprise SOCs. It holds firm for shared-hosting providers, MSPs managing tenant fleets, and any operator whose downstream consumers have independent communication channels (support desk, status page, press team, fraud-detection vendor, compliance auditor) that will fire on evidence they observe directly — either through in-band signals like CDN analytics anomalies or out-of-band signals like public IOC-sharing feeds.

## 3. The routing grid

Rows are trigger classes; columns are response lanes. Populate the named responder role in each cell; the operator's on-call rotation system (see §10) resolves the role to a human.

| trigger class | first-touch | defense-gate | customer-comms | documentation |
|---|---|---|---|---|
| single-host observation | primary-oncall | primary-oncall | customer-success (post-containment) | primary-oncall |
| single-customer multi-host | primary-oncall | primary-oncall | customer-success (pre-containment) | primary-oncall + customer-success |
| cross-customer shared-tenant | customer-success | customer-success + primary-oncall | customer-success (pre-containment, all impacted tenants) | customer-success |
| cross-customer cross-platform | customer-success + executive-responsible | executive-responsible + primary-oncall | executive-responsible signs, customer-success drafts | executive-responsible |
| recurring-adversary (prior case) | prior-engagement owner | prior-engagement owner + primary-oncall | prior-engagement owner | prior-engagement owner |

Responder classes named here are hosting-specific. Definitions:

- **primary-oncall** — the 24/7 technical first-responder. Runs the containment timeline: blocks, quarantine, process kills, evidence preservation. Expected SLA is minutes-to-acknowledge, not minutes-to-resolve.
- **customer-success** — the tenant-facing communication owner. Business-hours default plus paged-if-critical. Holds the per-tenant communication preferences (which email addresses to CC on incident notifications, whether the customer has a preferred channel like Slack shared channel or support ticket, the agreed escalation-latency tolerance captured at onboarding).
- **CDN-relationship-owner** (see §5) — typically sits with network engineering or the senior customer-success lead, not primary-oncall. Holds the relationship paper with the CDN providers and the playbook for cascading rollback if a CDN-overlap block gets applied and needs to be retracted.
- **compliance-officer** — looped in before any regulatory-clock-starting disclosure. Knows which customers are under PCI DSS / HIPAA / SOC 2 / regional privacy-law attestation and what the disclosure clock is for each.
- **executive-responsible** — the named exec who signs customer-trust-preserving communication at cross-customer incidents. On a cross-customer incident the email that goes to affected customers is not a support-desk template — it is a statement from the provider, signed by someone whose title the recipient recognises.
- **prior-engagement owner** — the named owner from the prior case's `closed.md` brief. Typically customer-success plus the SOC lead of record on the prior case. The brief names them explicitly in the handoff section.

The grid cells are the curator's suggested routing, not the final call. The operator confirms or redirects via the `open-questions.md` entry described in §8.

Two orthogonal flags layer on top of the grid rather than replacing rows. The CDN-overlap flag (§5) adds CDN-relationship-owner to the defense-gate column regardless of which row the trigger class landed in. The compliance-exposure flag adds compliance-officer to the first-touch column when any implicated tenant is under an active regulatory-attestation clock — the flag fires on the presence of an attestation-active marker in the tenant's context metadata, not on severity. The flags are additive to the row's named responders, not substitutive.

## 4. The cross-host campaign special case

When `attribution.md` gains a cross-host stanza — two or more hosts sharing callback infrastructure, payload family, or mtime cluster per `skills/ioc-aggregation/ip-clustering.md` — the grid's first two rows no longer apply. The routing flips: technical oncall becomes the SECOND touch, customer-success becomes FIRST. Specifically:

1. Primary-oncall is paged for awareness (they execute technical containment on their existing timeline).
2. Customer-success is paged for first-customer-contact (they own the narrative before any affected customer sees third-party evidence).
3. Any `defend.*` step emitted by the curator with blast radius crossing tenants requires customer-success approval before the operator promotes it from `suggested` to applied — `docs/action-tiers.md §4` tier rules still govern wrapper-side enforcement, but the tenant-crossing case adds an additional human gate on top.
4. Compliance-officer is pre-notified if any implicated customer is under an active compliance attestation window (PCI DSS, HIPAA, SOC 2 Type II — the specific regulatory clock is tenant-specific and lives in each customer's metadata, not in this file).

The curator detects the cross-host class from `attribution.md` alone — the presence of shared signature fields across host-scoped evidence rows. The routing classification lands as an `escalation-intent` paragraph inside `hypothesis.md` reasoning (see §8).

Practical detail that matters on a hosting fleet: the three attribution signatures that most reliably indicate a campaign versus opportunistic co-deployment are (a) shared callback domain or IP across hosts (per `skills/ioc-aggregation/ip-clustering.md`), (b) identical obfuscation grammar in the payload (per `skills/obfuscation/*`), and (c) an `observed_at` cluster tighter than 20 minutes across hosts. One of the three alone is weak evidence; two of three is the campaign-signature bar per `skills/actor-attribution/campaign-vs-opportunistic.md`. The curator does not flip routing on a single signature — `case-lifecycle.md §Calibrated confidence` keeps confidence below 0.7 until cross-category corroboration has landed.

## 5. The CDN-overlap pre-defense gate

Before any `defend.firewall` step with a CIDR overlapping Cloudflare / Akamai / Fastly / Sucuri / CloudFront ASN blocks (see `skills/defense-synthesis/firewall-rules.md §CDN safe-list discipline` for the range list + refresh cadence), the curator escalates to the CDN-relationship-owner role. This is a pre-defense gate, not a post-defense review.

The mechanical reason: a block on a CDN origin-pull range cascades a full-site outage across ALL CDN-fronted customers on the provider, within the CDN's cache-TTL window (typically 4-30 minutes). Blast radius on a CDN-overlap block is the intersection of the block CIDR and the provider's entire CDN-fronted tenant population — which on a mid-size shared-hosting fleet is multiple orders of magnitude wider than the original compromise. Rolling back is trivial (`apf -r` or equivalent), but the trust damage to customers who saw an unexpected 20-minute outage is not reversible inside the same incident window.

This gate is blacklight-specific because most enterprise-SOC operations do not sit in front of CDN origin-pull ranges. Hosting providers routinely do — the CDN is the customer's choice, the provider is the origin. A block at the provider's edge fires *before* the CDN's WAF has a chance to scrub the traffic, and affects every customer fronted by that CDN, not only the implicated one.

The curator surfaces the gate by emitting the `defend.firewall` step at `suggested` tier (per `docs/action-tiers.md §5.3`) rather than `auto`, with the CDN-overlap ASN named explicitly in the step `reasoning` field. The operator's approval path then includes the CDN-relationship-owner before the step applies.

The gate fires on partial overlap, not just exact match. A proposed `/24` block where one `/30` overlaps a Cloudflare range is still a gate trigger — the CIDR arithmetic happens at safelist-preflight time (per `skills/defense-synthesis/firewall-rules.md`), and any non-empty intersection flips the step from `auto` to `suggested`. This matches `docs/action-tiers.md §4` authoring rule 2 verbatim and is enforced wrapper-side regardless of the curator's tier assignment — the curator's job is to surface the overlap in `reasoning` so the approver does not have to re-derive it.

Rollback posture matters at this gate because the expected-value calculation the CDN-relationship-owner makes differs from the primary-oncall's. Primary-oncall sees: "block X prevents adversary Y on affected tenants". The CDN-relationship-owner sees: "block X prevents adversary Y on affected tenants AND cascades an origin-pull outage to unaffected tenants that lasts at least one CDN cache-TTL cycle". The rollback is mechanically fast (seconds via `apf -r <ip>` or `csf -dr <ip>`), but a rollback fires a second CDN cache-invalidation event that customers see as a flap — two anomalies in a window where they expected zero. The approver's call is a cost-weighted tradeoff, not a technical yes/no. The curator's job is to surface enough for the tradeoff to happen; the curator does not make the call.

## 6. The recurring-adversary routing rule

When the attribution signature on a fresh case matches a prior case on the same customer — callback domain family, payload family hash, drop-path convention, or the combination flagged as campaign-signature in `skills/actor-attribution/campaign-vs-opportunistic.md` — the routing does NOT go to a fresh primary-oncall. It goes to the prior-engagement owner of record (customer-success plus the SOC lead on the prior case).

The mechanical reasons, specific to hosting-fleet operations:

- Enterprise SOCs rarely encounter repeat adversaries on the same target. When they do, the adversary class is typically APT-grade and the routing is federal-law-enforcement-first (FBI IC3, CISA). That's a different playbook.
- Hosting providers encounter repeat adversaries constantly. Opportunistic actors scrape tenant lists from prior compromises (search for the same `/skin/frontend/` path pattern on Shodan) and return weeks later after the customer's remediation posture lapsed — the MITRE ATT&CK T1588.006 (https://attack.mitre.org/techniques/T1588/006/) "Vulnerabilities" reconnaissance pattern applies at the fleet level.
- Prior-engagement context is institutional memory. The prior case's `closed.md` brief carries the operator's remediation rationale, the customer-specific communication preferences captured during the engagement (who to CC, preferred channel, escalation-latency tolerance), and the regulatory clock-state at close.
- Routing to a fresh primary-oncall forces re-learning that context from the case ledger. The fresh responder will often communicate duplicate remediation recommendations — or worse, recommendations contradicting the prior engagement's agreed-upon posture — which erodes customer trust in the provider's continuity faster than the original compromise did.

The curator detects recurring-adversary by querying the attribution signature against prior-case briefs (`bl-case/CASE-*/closed.md`). When a match lands, the `escalation-intent` paragraph names the prior case id and the specific signature field that matched.

The match-signature bar matters. A shared callback domain parent alone (e.g., both cases have callbacks to `*.example-cdn-abuse.net`) is a weak match — opportunistic actors share abuse infrastructure, and the kill-chain stage T1071.001 per `skills/ir-playbook/kill-chain-reconstruction.md` maps to infrastructure that rotates across unrelated campaigns. A shared callback parent PLUS identical obfuscation grammar (same base64 padding convention, same variable-name pattern) PLUS drop-path convention matching across two or more components is the campaign-recurrence bar. The curator does not flip to prior-engagement-owner routing on a single signature field — that would flood the prior-engagement owner with false positives and erode the routing rule's credibility. The curator's `reasoning` names which of the three match components fired and cites the evidence row ids from both the current case and the prior-case brief.

Operator-side handoff: when prior-engagement routing fires, the operator's first move is to hand the prior-case `closed.md` to the fresh primary-oncall as shared context, not as a reading assignment. The brief carries a five-line "what the customer asked us to preserve" section (populated at close per `skills/ic-brief-format/template.md`) — the prior-engagement owner reads that section out loud in the incident channel as the opening move, before any technical triage starts. This is a context-transfer discipline, not a ceremony; it prevents the re-learn-everything failure mode in §9 by making the prior context verbal before it becomes textual.

## 7. The Magento-peak-hours special case

When a finding matches a pattern under `skills/magento-attacks/*.md` and lands during a known peak-commerce window — Black Friday week, Cyber Monday, November-December holiday retail, a customer-announced product-launch window — the routing adds an e-commerce-vertical responder and compresses the defense-gate decision timeline.

The mechanical reason: skimmer injection during peak (see `skills/ic-brief-format/ioc-categorization.md` §C2 callback category) has per-hour revenue impact that exceeds a standard incident by an order of magnitude. A Magento shop doing $50k/day during baseline is doing $400k/day during Black Friday week. A four-hour containment window that would be acceptable in February is a revenue event the customer will remember in March.

The defense-gate compression: steps that would normally emit at `suggested` tier (operator confirmation with no urgency floor) shift to `auto` tier with a 15-minute veto window per `docs/action-tiers.md §5.2`. The shift is NOT a safety downgrade — the curator still emits the full diff and reasoning — it is a timeout reduction on the operator's default confirmation window. The veto remains available; the default action if no veto arrives within 15 minutes is apply.

The curator detects the peak-hours case from a calendar fact in the `bl-case/CASE-<id>/context.md` header populated at case creation (the operator sets peak-window dates when provisioning tenant metadata). Absent a peak-window flag, the case defaults to standard-tier routing.

A second compression applies to customer-comms: during peak windows, the first-touch notification to affected customers moves from "best-effort inside the hour" to "pre-drafted template, sent within 15 minutes of cross-customer classification". The pre-drafted template lives with customer-success, not in this file. The curator's only responsibility is to flip the peak-hours flag in the `escalation-intent` paragraph so the operator knows to reach for the compressed template, not the standard-incident one.

Why the compression is load-bearing specifically during peak: skimmer-class compromises (card-data exfiltration via JavaScript injection into Magento checkout flow — see MITRE ATT&CK T1056.003 "Web Portal Capture" at https://attack.mitre.org/techniques/T1056/003/) have a per-customer fraud liability that scales with transaction volume. A four-hour skimmer window during Black Friday at a $400k/day shop is approximately $67k of fraud-liability exposure the customer will either absorb or litigate back to the provider. A four-hour window in February at the same shop is $8k. The compression is not about technical urgency — it is about capping the customer's liability exposure while the technical timeline runs to its normal length. Primary-oncall's containment SLA does not change; customer-comms' SLA does.

## 8. Handoff shape — what the curator emits

The curator does NOT make routing decisions. The curator emits enough structured context that the operator can execute routing without re-analysis. Three artifacts per escalation-warranting revision:

1. **`escalation-intent` paragraph inside `hypothesis.md` reasoning.** Named as such in the prose. Structure: trigger class (one of the five in §3), suggested first-touch role, suggested defense-gate role, any special-case flags (cross-host, CDN-overlap, recurring-adversary, Magento-peak). Example: "escalation-intent: trigger class = cross-host campaign (23 hosts nyc-7); first-touch = customer-success; defense-gate = customer-success + primary-oncall; CDN-overlap flag SET (one Contabo IP in proposed block overlaps Cloudflare origin-pull per skills/defense-synthesis/firewall-rules.md)."

2. **`open-questions.md` entry requesting operator confirmation.** One sentence, ending in a question mark per `case-lifecycle.md §Open questions grammar`. Example: "Routing class = cross-host campaign with CDN-overlap pre-defense gate — suggest customer-success first-touch, primary-oncall second-touch, CDN-relationship-owner before firewall step applies — confirm or redirect?"

3. **`case.log` step emission recording the routing intent.** The step is `verb: case.escalate`, `action_tier: read-only` (the step does not execute anything — it ledgers the intent), `reasoning` carrying the same paragraph as (1). The operator's rotation system consumes the case log, not this file.

Routing execution — actual paging, Slack post, customer email draft — is operator-side. The curator's job is to emit intent clearly enough that the operator can execute without re-reading the case.

What the curator must NOT emit:

- Specific human names, phone numbers, or channel IDs. Those are rotation-system state; they drift weekly and do not belong in case history. The curator names role classes; the operator's rotation resolves the role.
- A claim that a specific customer has been notified. The curator has no visibility into whether the operator has executed the notification; asserting notification status would falsify the ledger.
- Urgency vocabulary calibrated to enterprise-SOC severity scales (P0/P1/SEV-1). Hosting-fleet severity is a function of blast radius times tenant density times regulatory exposure — none of which map cleanly to enterprise severity tiers. The curator names the trigger class from §3; the operator's incident-management tool assigns the severity label.

What the curator SHOULD emit when the signal is available:

- The blast-radius estimate as host-count plus tenant-count ("23 hosts, 18 distinct tenants implicated") — the operator's triage decision is different at 18 tenants than at 3.
- The regulatory-exposure flag if any implicated tenant is under an active compliance clock. The curator does not assert the clock has started; it surfaces the flag so compliance-officer routing fires.
- The prior-case id when recurring-adversary detection fires, so the prior-engagement owner lookup is a grep rather than a re-analysis.

Worked example, continuing the §1 scenario. The revision on `CASE-2026-0138` emits:

> **escalation-intent.** Trigger class = cross-customer shared-tenant (23 hosts nyc-7, 18 distinct tenants). First-touch = customer-success. Defense-gate = customer-success + primary-oncall + CDN-relationship-owner. Documentation = customer-success. Flags: CDN-overlap SET (one Contabo `/30` in proposed `/24` block intersects Cloudflare origin-pull range 103.31.4.0/22 per `skills/defense-synthesis/firewall-rules.md`); recurring-adversary SET (signature matches `CASE-2026-0091` on same parent callback domain + base64 obfuscation grammar + drop-path convention, two of three campaign-match fields confirmed, prior-engagement owner named in `CASE-2026-0091/closed.md` handoff section); compliance-exposure SET (tenant `tenant-7b4a` under active PCI DSS attestation); Magento-peak-hours SET (November retail window, two affected tenants pre-flagged). Suggested sequence: customer-success first-touch within 15 minutes; prior-engagement owner loops in with prior-case brief; primary-oncall runs technical containment timeline in parallel; CDN-relationship-owner approves before firewall step applies; compliance-officer pre-notified on PCI-exposed tenant.

The corresponding `open-questions.md` entry: "Routing class = cross-customer shared-tenant with CDN-overlap, recurring-adversary (CASE-2026-0091), PCI compliance exposure, and Magento peak-window flags all SET — suggest customer-success first-touch, prior-engagement owner as context lead, CDN-relationship-owner pre-firewall gate, compliance-officer pre-notified — confirm routing sequence or redirect?"

The operator reads both, confirms or redirects in a single reply, and the rotation system handles the specific human resolutions. The curator's work on the routing axis is done; the next revision turn resumes evidence-driven hypothesis discipline per `case-lifecycle.md`.

## 9. Failure modes

Three failure modes the rule set exists to prevent. Each is a real pattern observed in hosting-provider IR retrospectives; each has a specific rule in this file that preempts it.

**The "technical-first" trap.** Primary-oncall is paged on what is actually a cross-host campaign. Technical containment lands in 40 minutes — blocks placed, webshells quarantined, the technical side of the case looks clean. During those 40 minutes, Sansec publishes IOC research on the callback infrastructure (https://sansec.io/research), affected customers' fraud-detection vendors flag anomalous outbound traffic, and customers hear about their own compromise from third parties before they hear from the provider. The provider's support desk is flooded with inbound tickets demanding to know why the provider didn't notice. Technical recovery is complete; trust recovery takes two quarters. **Rule preempt:** §4 — customer-success is FIRST touch when `attribution.md` carries a cross-host stanza; primary-oncall runs the technical timeline in parallel.

**The CDN-block cascade.** Primary-oncall approves a `/16` firewall block that was surfaced at `auto` tier — the curator did not flag CDN overlap because the overlap was in a `/22` subset of the proposed `/16`. Every CDN-fronted customer on the provider goes dark for 20 minutes before rollback. The blast radius times tenant density is a customer-trust incident larger than the original compromise. **Rule preempt:** §5 — the curator downgrades any `defend.firewall` step with ANY CDN-safelist overlap inside the proposed CIDR to `suggested` tier with the overlap CIDR named in `reasoning`; the CDN-relationship-owner is a named approver before the step applies.

**The re-learn-everything trap.** A recurring-adversary signature matches a prior case from 62 days ago. The new primary-oncall has no context on the prior engagement, does not know the customer's remediation preferences, and communicates recommendations that contradict the prior engagement's agreed posture. The customer's reading: the provider has no institutional memory, each incident is a fresh slate, every prior conversation was theatre. Churn event. **Rule preempt:** §6 — recurring-adversary routes to prior-engagement owner with the prior-case id + attribution-match evidence handed off directly in the escalation-intent paragraph; fresh primary-oncall loops in second, with the prior context already loaded.

A fourth pattern worth naming, even though it is not a failure of the routing grid but a failure of *not applying* it: the premature-executive-loop. On a large cross-customer incident, a well-meaning primary-oncall pages the executive-responsible role before the customer-success org has drafted communication language. The exec arrives in the incident channel with no prepared statement, publishes an ad-hoc message under time pressure, and the message goes out without the customer-specific communication-preference discipline customer-success would have applied. The result is an exec-signed statement that gets retracted 40 minutes later after a tenant escalates through their own legal team — a far worse trust event than a 20-minute delay in executive involvement would have produced. The rule set prevents this by sequencing customer-success FIRST on cross-customer classes; the executive-responsible role is the defense-gate and signature, not the first-touch.

## 10. What this file is not

- Not a replacement for the operator's on-call rotation system (PagerDuty, Opsgenie, VictorOps, FireHydrant, incident.io). The responder role classes named here map INTO the operator's rotation. Specific phone numbers, escalation timers, paging-channel IDs, on-call shift boundaries — all live in the operator's paging config, not in this file.
- Not a pager-service integration spec. The curator emits structured intent; operator tooling resolves role-to-human and routes.
- Not generic IR literature. NIST SP 800-61 r2, SANS IR playbook material, PagerDuty's incident cookbook — all valuable, all calibrated to enterprise-SOC operations. Every rule above is calibrated to hosting-fleet realities where enterprise-SOC literature gets the routing axis wrong.
- Not operator-specific routing config. This file describes the axis; the operator's on-call metadata file (not yet authored, tracked under `case-lifecycle.md §Operator-specific layers — deferred`) will carry the per-tenant mappings (which customer-success lead owns which tenant brand, which compliance officer covers which regulatory clock).
- Not a severity-classification schema. Enterprise-SOC severity models (P0/P1/P2, SEV-1/2/3) rank by technical impact. The trigger classes in §3 rank by who owns the customer conversation. A severity label and a trigger class are orthogonal attributes of the same incident; the operator's incident-management tool carries the severity, this file's grid carries the routing. Attempts to fold them into a single enum collapse information the operator needs kept separate.
- Not a notification-content template. What customer-success says to a specific affected tenant is a customer-success asset, calibrated to the tenant's communication-preference metadata. This file specifies *who sends* the first customer-comms message on each trigger class, not *what the message says*. The template library lives with customer-success tooling (typically a library of vetted language in Notion, Confluence, or a similar knowledge-base system), and is out of scope for the curator — the curator has no visibility into tenant communication preferences and should not fabricate them.
- Not a post-mortem shape. Routing during the incident is this file's scope. Post-incident review (blameless post-mortem, root-cause write-up, customer-facing incident report, regulatory filing timeline) is covered under `skills/ic-brief-format/template.md` and the case's `closed.md` generation flow. Routing decisions made during the incident become inputs to the post-mortem via the `case.log` entries described in §8; the post-mortem assesses whether the routing was right, this file tells the curator how to suggest it in the first place.

## 11. Vocabulary anchors

The routing grammar in this file is defensive-forensics vocabulary by deliberate choice. Specifically:

- `adversary` is the actor; `observed capability` is what the adversary has demonstrated on the fleet; `intrusion vector` is the path by which the capability was established. These are the three terms the curator uses to ground reasoning that would otherwise drift into offensive-security narration.
- `attribution signature` is the fingerprint across infrastructure, payload, and cadence that lets the curator tell campaign from coincidence; `recurring adversary` is the case where the attribution signature matches a prior engagement; `cross-host campaign` is the case where the attribution signature fires across tenants.
- The routing grid does NOT use severity words (`critical`, `high`, `major`). It uses trigger-class words (`single-host`, `cross-customer shared-tenant`, `recurring-adversary`) because the routing decision is a function of blast radius and communication ownership, not a function of a single severity scalar.
- The handoff paragraph in §8 is written as prose the operator reads, not as a structured enum. The enum lives in `schemas/step.json` for the `case.escalate` step; the prose is the reasoning the approver uses to confirm or redirect.

Everything above is consistent with `case-lifecycle.md §Anti-patterns` item 4 (no offensive-security vocabulary) and the project-level framing discipline. If a future edit to this file introduces severity language or offensive-security vocabulary, that edit is a regression and should be caught at review.

## 12. How this file gets loaded

The curator's router in `prompts/curator-agent.md` (see `DESIGN.md §5` for the Managed Agent session wiring) inspects the current revision's hypothesis payload on every turn. Two conditions trigger a load of this file into the turn's context:

1. `hypothesis.current.confidence >= 0.7` after the revision lands. Confidence below that threshold stays in the normal lifecycle discipline covered by `case-lifecycle.md`; confidence at or above that threshold is the bar where routing becomes a first-class concern per `case-lifecycle.md §Calibrated confidence`.
2. `attribution.md` gains a cross-host stanza on the current turn — any signature shared across two or more hosts, regardless of confidence level. A low-confidence cross-host pattern is still a routing-class shift (cross-customer shared-tenant at minimum per §3), and the router must load the file even if the confidence bar from condition (1) has not fired.

Either condition alone triggers a load; both firing simultaneously is the `CASE-2026-0138` scenario from §1 and is the scenario most of this file is calibrated against.

The file is NOT loaded on routine revision turns where confidence remains below 0.7 and `attribution.md` carries only single-host evidence. This keeps the curator's context budget focused on the evidence-reasoning discipline for cases that have not yet reached escalation-warranting shape; introducing routing vocabulary into a case that has not crossed the bar is noise.
