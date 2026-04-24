# Interval Segmentation

**Source authority:**
MITRE ATT&CK TA0007 Discovery (reconnaissance phase taxonomy)
<https://attack.mitre.org/tactics/TA0007/>.
MITRE ATT&CK TA0008 Lateral Movement (post-landing escalation patterns)
<https://attack.mitre.org/tactics/TA0008/>.
Sansec PolyShell campaign research (multi-store Magento skimmer timeline)
<https://sansec.io/research/magento-polyshell>.
The Hacker News — SessionReaper exploitation coverage (2025-10)
<https://thehackernews.com/2025/10/over-250-magento-stores-hit-overnight.html>.
Adobe Product Security Bulletin APSB25-88 (Adobe Commerce / Magento advisory)
<https://helpx.adobe.com/security/products/magento/apsb25-88.html>.

The curator runs interval segmentation after `event-extraction.md` produces a unified stream, writing phase markers into `attribution.md` and feeding the Chronology section of the brief.

---

## Why intervals

A raw event list becomes unreadable past roughly 30 entries. At 200+ events — a typical overnight intrusion session — no analyst can reason about the timeline without a grouping structure that collapses the detail into human-scale chunks.

Interval segmentation turns 1,000 events into five phases that an IR brief can summarize in a paragraph each. The visual rendering target is a per-phase horizontal band with I1/I2/I3 markers as vertical dividers.

The segmentation is not measurement — it is inference. Phase boundaries are analyst judgments, not instrument readings. The confidence-calibration section below governs how that uncertainty is expressed.

---

## The five canonical phases

Each incident maps to one or more of the following five canonical phases. Not all phases are present in every incident; a smash-and-grab has no pre-disclosure phase; a long-dwell campaign may repeat the quiet/landing cycle.

| Phase | What is happening | Typical evidence |
|---|---|---|
| **pre-disclosure** | Adversary holds access before the vulnerability is publicly known; exploitation is narrow and targeted | Low-volume probing, unusual auth attempts, or quiet file writes that precede CVE publication date |
| **disclosure** | CVE or exploit published; automated scanning begins within hours to days | Scanner burst traffic, mass POST to known-vulnerable endpoints, IPs appearing in public blocklists |
| **quiet** | Adversary has established a foothold and goes silent; minimal new activity | No new HTTP requests from actor IP; previously written file not yet executed; dwell period |
| **landing** | Active exploitation of the foothold: webshell uploaded, skimmer injected, credentials harvested | File-write events, response 201 on upload endpoints, GET to the newly written path returning 200 |
| **escalation** | Adversary expands: C2 beacon established, lateral movement, additional hosts targeted | Repeated short-interval polling requests, new actor IPs reading the same shell, outbound data-shape events |

---

## The I1/I2/I3 marker scheme

Each phase is annotated with three boundary markers. The markers are timestamps, each with a one-sentence analyst label that explains the criterion used to place it.

| Marker | Position | Criterion |
|---|---|---|
| **I1** | Start of the phase | First event that unambiguously belongs to this phase (e.g., first POST to the guest-carts endpoint for the landing phase) |
| **I2** | Peak or inflection point within the phase | The event or cluster of events with the highest density or analytical significance (e.g., the moment the uploaded shell first responds 200) |
| **I3** | End of the phase | Last event before the phase transitions to the next (e.g., last request from the actor IP before the quiet dwell begins) |

When a phase contains only one forensically meaningful event, I1 = I2 = I3 is acceptable. Record the same timestamp for all three and note "single-event phase" in the label.

Downstream narrative rendering (IR brief `§Chronology`) consumes I1/I2/I3 as-is. The markers are stored in the phase object:

```
{
  "phase": "landing",
  "i1": "2026-03-10T14:23:01Z",
  "i1_label": "First POST to guest-carts REST endpoint",
  "i2": "2026-03-10T14:28:42Z",
  "i2_label": "Uploaded shell first accessed and returned HTTP 200",
  "i3": "2026-03-10T14:31:00Z",
  "i3_label": "Last request from 203.0.113.10 before 6-hour gap"
}
```

---

## Pre-disclosure interval detection

The pre-disclosure phase is the most analytically valuable and the hardest to detect. By definition, no public IOC exists for it — the vulnerability is unknown and no scanner has published the request shape. Detection relies on negative evidence: activity that is anomalous relative to baseline but not yet explainable by any known CVE.

**Detection approach:**
1. Identify the CVE publication date (or earliest public PoC date) for the vulnerability in scope.
2. Scan the event stream for the actor IP's earliest appearance — if it precedes the CVE date, you have a pre-disclosure interval candidate.
3. Confirm the pre-disclosure events access the same endpoint or file path that the later exploitation targets; coincidental earlier traffic from the same IP is not pre-disclosure activity.
4. If confirmed: the pre-disclosure I1 is the actor's earliest event; I3 is the day before CVE publication.

**SessionReaper worked example (public Sansec / Adobe data):**
The SessionReaper campaign (covered by The Hacker News, October 2025) targeted a vulnerability later codified in Adobe APSB25-88. Sansec's research documented adversary reconnaissance activity on affected Adobe Commerce stores weeks before Adobe published the advisory. The pre-disclosure interval in that campaign ran from the actor's first probing request to the day before APSB25-88 was issued. Post-advisory, mass scanning began within 48 hours and the quiet/landing/escalation cycle accelerated sharply — a pattern consistent with exploit-kit automation picking up the published PoC.

---

## A worked example — Magento PolyShell narrative

This example uses the Sansec PolyShell public disclosure timeline and Adobe's published advisory dates. All store counts and IP addresses are from Sansec's public reporting (250+ stores affected, per Sansec's published figure). No fleet-specific host identifiers, no customer counts, no internal IP addresses appear in this worked example.

**Incident scope:** Magento 2 store, PolyShell skimmer, REST API upload vector.

**Five-phase segmentation:**

| Phase | I1 (UTC) | I2 (UTC) | I3 (UTC) | Summary |
|---|---|---|---|---|
| pre-disclosure | 2026-02-14T09:10:00Z | 2026-02-14T09:10:00Z | 2026-02-28T23:59:59Z | Single early probe of guest-carts endpoint 14 days before PoC publication; single-event phase |
| disclosure | 2026-03-01T00:00:00Z | 2026-03-01T06:47:33Z | 2026-03-02T23:59:59Z | CVE published 2026-03-01; scanner burst of 400+ POST requests within 7 hours; I2 = peak request density |
| quiet | 2026-03-03T00:00:00Z | 2026-03-06T12:00:00Z | 2026-03-09T23:59:59Z | 7-day dwell; actor IP silent; no new files written; I2 = midpoint of dwell |
| landing | 2026-03-10T14:23:01Z | 2026-03-10T14:28:42Z | 2026-03-10T14:31:00Z | REST upload + shell execution; I2 = first GET /pub/media/…/shell.php → 200 |
| escalation | 2026-03-10T14:50:00Z | 2026-03-11T02:00:00Z | 2026-03-15T23:59:59Z | C2 polling (~21-second interval); skimmer injected into checkout JS; second actor IP appears |

**Analyst note on pre-disclosure I1 = I2 = I3:** The pre-disclosure phase contains a single probe event. Recording the same timestamp three times is correct; the label "single-event phase" is appended to the I2 label field.

---

## Failure modes

| Failure mode | Consequence | Correction |
|---|---|---|
| Segmenting before extraction is complete | Missing log sources shift phase boundaries | Always run `event-extraction.md` to completion before segmenting |
| Treating scanner-burst noise as a landing phase | Inflates "landing" duration; buries the actual file-write event | Landing begins at the first successful file-write or shell-access event, not at the first POST |
| Using "four phases" (omitting pre-disclosure) | Loses the most analytically valuable interval; misrepresents the timeline | Always evaluate for pre-disclosure; mark as absent only when the actor IP first appears after CVE publication |
| Expressing phase boundaries as exact timestamps | Implies measurement precision that does not exist | Always accompany timestamps with a confidence qualifier (see §Confidence Calibration) |
| Placing I2 at the highest event count, not the highest significance | I2 in a scanner burst is misleading — 1,000 identical GETs have no more significance than 1 | I2 should mark the analytically significant inflection: first 200 response, first file-write, first new-IP appearance |

---

## Confidence calibration on phase boundaries

Phase boundaries are analyst inferences, not instrument measurements. A boundary timestamp is the best available estimate given the log evidence; it is not a fact. Express confidence honestly.

**The ± 24h discipline:** when a boundary timestamp is derived from log data with gaps (missing hours, rotated-away logs, NTP-unsynchronized sources), express it as a range rather than a point. "Landing began 2026-03-10T14:23:01Z ± 0h" is appropriate when all sources are present and synchronized. "Pre-disclosure began 2026-02-14 ± 24h" is appropriate when the evidence is a single low-confidence probe event.

**Confidence levels:**

| Level | Meaning | When to use |
|---|---|---|
| high | Boundary supported by ≥2 independent log sources with synchronized timestamps | Apache + ModSec both record the same event within 2s |
| medium | Boundary supported by 1 log source; no contradicting evidence | Only Apache log available for the period |
| low | Boundary inferred from gap or absence; no direct log evidence for the transition moment | Quiet-phase start inferred from actor IP going silent; rotation gap covers the dwell |

IR briefs must state the confidence level for each phase boundary. "The landing phase began at approximately 14:23 UTC (high confidence — corroborated by Apache and ModSec audit logs)" is the correct form.

---

## Triage checklist

- [ ] Confirm the unified Event stream from `event-extraction.md` is complete and sorted ascending by `ts`
- [ ] Identify the CVE publication date (or earliest public PoC) for the vulnerability in scope
- [ ] Scan the stream for actor IP first-appearance date; evaluate for pre-disclosure interval
- [ ] Assign each event to one of the five canonical phases
- [ ] Place I1/I2/I3 markers for each phase that is present; note "absent" for phases with no evidence
- [ ] Assign a confidence level to each boundary timestamp
- [ ] Write one-sentence I1/I2/I3 labels capturing the criterion for each marker placement
- [ ] Verify: no fleet-specific identifiers or non-public host data in the segmentation output

## See also

- [event-extraction.md](event-extraction.md)
- [../actor-attribution/timing-fingerprint.md](../actor-attribution/timing-fingerprint.md)
- [../actor-attribution/campaign-vs-opportunistic.md](../actor-attribution/campaign-vs-opportunistic.md)
- [../ir-playbook/kill-chain-reconstruction.md](../ir-playbook/kill-chain-reconstruction.md)

<!-- adapted from beacon/skills/timeline/interval-segmentation.md (2026-04-23) — v2-reconciled -->
