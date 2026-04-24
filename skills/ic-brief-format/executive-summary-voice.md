# Executive Summary — Voice Calibration

**Source authority:** the operator-voice convention shared by published incident-response briefs from CISA
<https://www.cisa.gov/news-events/cybersecurity-advisories>,
US-CERT historical alerts
<https://www.cisa.gov/news-events/alerts>,
and the SANS Internet Storm Center diary archive
<https://isc.sans.edu/diaryarchive.html>.
These three sources converge on a common shape for the opening paragraph of an incident brief; this skill encodes that shape. The curator loads this skill when composing the brief written at `case.close` — the Files API-rendered PDF/HTML/MD artifact that closes the case.

---

## The one-paragraph mandate

The Executive Summary is **exactly one paragraph**. Not two, not a bulleted list, not a heading followed by paragraphs. One paragraph, 4–8 sentences, 120–300 words. A reader who reads only this paragraph should be able to answer: what happened, to what, when, and what should the reader do next.

The paragraph is self-contained. It does not assume the reader has read Section 2, Section 9, or any other section. It cites those sections for drill-down, but every claim it makes is comprehensible on its own.

---

## Required elements in order

Six elements, in this sequence:

1. **Date range + detection vector.** "Between 2026-04-12 and 2026-04-19, maldet sessions across the managed fleet flagged PolyShell-family drops..." The opening clause anchors the reader in time and identifies how the incident surfaced.
2. **Affected platform + version scope.** "...on Adobe Commerce / Magento Open Source installs running 2.4.4 through 2.4.8-p1." Gives the reader the blast-radius question-answer before any narrative.
3. **Active-exploitation language.** "The underlying vulnerability (APSB25-94) has been actively exploited in the wild since 2026-03-19, with mass-scanning observed by external researchers." Tells the reader the clock is already running.
4. **Fleet scope.** "42 of 318 managed hosts show confirmed compromise; 24 additional hosts are in mitigation-holding state pending cleanup verification." Numeric counts, named states. No adjectives.
5. **Primary mitigation + status.** "Webserver-layer deny rules for the upload path were deployed across all 318 hosts on 2026-04-20; vendor patch rollout is 60% complete." Mechanism and deployment state in one sentence.
6. **Next action or open risk.** "Customer data exposure review is pending for the 42 confirmed hosts; remediation timeline TBD pending log-retention verification." Closes the paragraph with what is still unresolved.

If any element is genuinely unknown at authoring time, say so explicitly — "Mass-exploitation date unverified (see §8)" — rather than omitting the element.

---

## Voice calibration

The table below pairs each anti-pattern with its corrected form. Numbers in the examples are illustrative, not drawn from any live incident.

| Use | Avoid |
|---|---|
| "Actively exploited as of 2026-03-19" | "Potentially exploitable" |
| "42 of 318 hosts confirmed compromised" | "Several hosts affected" |
| "Mitigations deployed 2026-04-20" | "Mitigations are being developed" |
| "Hotfix VULN-XXXXX applied on 24 of 318 hosts" | "We are working on a patch" |
| "Customer payment data exposure under review (§8)" | "No customer data affected" |
| "Vendor patch rollout 60% complete" | "Vendor patch deployment is progressing" |

Illustrative numbers (42, 318, 24) are hypothetical — use the actual counts from the incident being documented.

---

## Tone rules

- **Direct.** Lead with the conclusion; do not build up to it.
- **Evidence-first.** Every claim pairs with a source section number or a delegated citation.
- **Anti-hype.** No marketing verbs — `leverage`, `robust`, `cutting-edge`, `best-in-class`, `seamless` have no place here.
- **Numbers over adjectives.** "42 of 318" beats "many"; "4 days" beats "recent"; "0.4 requests per second per IP" beats "low-volume".
- **Dates over relative time.** "Since 2026-03-19" beats "since recently"; "within the last 72 hours" beats "very recently".
- **Section-number pointers.** Every non-trivial claim ends with a parenthetical section reference — `(§2)`, `(§6)`, `(§9)` — so the reader can drill down without searching.

---

## Forbidden constructions

These never appear in an Executive Summary:

- **"We believe ..."** — either state the conclusion with evidence or mark the claim as Open Item (§8).
- **"It appears that ..."** — same failure mode.
- **"Possibly ..."** — if the confidence is <0.9, the claim belongs in Open Items, not Exec Summary.
- **"Multiple", "Several", "Numerous", "A handful"** — use the count.
- **"Recently", "Lately"** — use the date.
- **"Sophisticated threat actor"** — describes nothing. Use the role from [../actor-attribution/role-taxonomy.md](../actor-attribution/role-taxonomy.md) and the evidence.

State certainty or surface the uncertainty — do not hedge in the Exec Summary.

---

## Calibration examples

### Good — compact Exec Summary

> Between 2026-04-12 and 2026-04-19, maldet sessions across the managed Magento fleet flagged PolyShell-family webshell drops under `pub/media/custom_options/` (§3, §4). The underlying vulnerability, APSB25-94, has been actively exploited in the wild since 2026-03-19 with mass-scanning observed by Sansec (§9). 42 of 318 managed hosts show confirmed compromise; 24 additional hosts are in mitigation-holding state pending cleanup verification (§5). Webserver-layer deny rules for the upload path were deployed across all 318 hosts on 2026-04-20; vendor patch rollout is 60% complete (§6). Customer data exposure review is pending for the 42 confirmed hosts (§8).

Why it works: five sentences, 112 words, all six required elements in order, every claim carries a section pointer, no marketing verbs, no hedging.

### Good — single-host Exec Summary

> On 2026-04-18, maldet flagged a PolyShell-family webshell under `pub/media/custom_options/` on a single Magento host (§3). The underlying vulnerability is APSB25-94, actively exploited since 2026-03-19 (§9). One file dropped, no execution confirmed in the access log (§3, §4). Webserver deny rule deployed 2026-04-18; vendor patch applied 2026-04-19 (§6). File removed; no secondary persistence found (§7).

Why it works: 4 sentences, ~65 words, scaled down for a 1-host incident but still covers all six required elements.

### Bad — marketing-verb hedged

> Our cutting-edge detection pipeline recently identified potentially compromised hosts in the Magento fleet leveraging a sophisticated attack chain. We believe several hosts may be affected. Mitigations are being developed and will be rolled out in a timely manner.

Why it fails: "cutting-edge", "recently", "potentially", "sophisticated", "several", "we believe", "timely manner" — every element is wrong. Zero section pointers. Zero dates. Zero counts. Zero CVE reference.

### Bad — buried CVE

> Recent telemetry from our managed fleet has shown a concerning pattern of webshell activity. After careful analysis, we have determined the activity is related to a recently disclosed vulnerability in Adobe Commerce. Affected hosts are being addressed.

Why it fails: the CVE / bulletin ID never appears. Dates are vague ("recent", "recently disclosed"). Host count missing. Mitigation state missing. "Being addressed" hides everything operational.

---

## Triage checklist

- [ ] Exactly one paragraph — not two, not a list
- [ ] 4–8 sentences, 120–300 words
- [ ] All six required elements present, in order
- [ ] CVE or bulletin ID appears in the first two sentences
- [ ] Date range uses YYYY-MM-DD format, not "recently"
- [ ] Fleet scope uses counts (NN of MM), not adjectives
- [ ] Every non-trivial claim has a section pointer (§N)
- [ ] No forbidden constructions ("we believe", "it appears", "possibly", "several", "recently", "sophisticated")
- [ ] No marketing verbs ("leverage", "robust", "cutting-edge")

---

## See also

- [template.md](template.md) — where this paragraph sits in the overall brief
- [severity-vocab.md](severity-vocab.md) — severity phrasing referenced in the summary
- [ioc-categorization.md](ioc-categorization.md) — Section 4 that this paragraph summarizes
- [../actor-attribution/role-taxonomy.md](../actor-attribution/role-taxonomy.md) — role vocabulary referenced when describing adversaries in the summary

<!-- adapted from beacon/skills/ic-brief-format/executive-summary-voice.md (2026-04-23) — v2-reconciled -->
