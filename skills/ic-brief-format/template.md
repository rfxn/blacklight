# ic-brief-format — incident communication brief template

Loaded by the router when the curator is producing an operator-facing or customer-facing brief. The brief is the artifact the on-call engineer hands to a customer success owner, an internal incident channel, or a post-mortem reviewer; it is the case file rendered as prose. This file is the section list, the voice rules, and the worked-example shape.

## Section order (fixed)

A brief has eight sections in this order. Sections never reorder; an empty section is omitted, not reordered.

1. **TL;DR** — three to five sentences. Lead with impact and current status.
2. **Severity** — single line, named with the operator scale.
3. **Timeline** — UTC ISO-8601, append-only, most recent at the bottom.
4. **Indicators of Compromise** — fenced code block, copy-pasteable, organized by class.
5. **Affected scope** — host count, customer count, data class.
6. **Containment actions taken** — chronological, who took each action.
7. **Remaining risk** — what is still being investigated, ETAs.
8. **Defensive measures deployed** — rules, manifests, cleanup actions.
9. **Lessons learned** — single section, never embedded throughout earlier sections.

The brief is read top-down by people who skim. The TL;DR carries the load if nothing else is read; the IOC block is the second-most-read section because it is the operational handoff.

## TL;DR — three to five sentences

The lead sentence names the impact and status: what was hit, how many customers, are we still being hit. Sentences two through four cover the attack class, the entry vector, and the current containment state. The last sentence names the next gating moment — when the next status will land or what unlocks resolved.

Voice anchors:

- Past tense for completed actions ("blocked at 03:14 UTC").
- Present continuous for in-flight ("Triage is ongoing across 4 additional hosts").
- Never future-perfect ("we will have completed by 06:00 UTC" — say "expected complete by 06:00 UTC" instead).

A bad TL;DR opens with attack-class jargon and buries the impact: "An unauthenticated remote code execution vulnerability in Adobe Commerce was exploited..." A good TL;DR opens with what happened to whom: "Twelve customer Magento storefronts were compromised between 02:00 and 03:30 UTC via the APSB25-94 vulnerability; nine are contained, three are in active cleanup."

## Severity — operator scale

Severity uses the operator's scale, named explicitly:

- **P1** — customer-impacting active compromise. Active data flow, active C2, active customer-visible service degradation. Pages on-call.
- **P2** — customer-impacting suspected compromise. Strong signal but no confirmed exfiltration or service degradation. Pages on-call during business hours, escalates to P1 on confirmation.
- **P3** — internal-impacting. System-side issue (a server compromised but no tenant data implicated; a misconfigured rule blocking legitimate traffic). Notify channel; no page.
- **P4** — informational. Notable finding for the record; no action required. Posted to the incident channel for awareness.

The severity line names both the level and the trigger: `Severity: P1 — active C2 callbacks observed from compromised hosts to externally-controlled infrastructure.`

Severity can be downgraded across the lifetime of the brief (P1 → P2 → P3) as containment lands. Each downgrade is a timeline entry naming the trigger. Severity does not get downgraded silently in the header; the trigger is recorded.

## Timeline — UTC ISO-8601, append-only

Every entry is a single line: timestamp, then a one-line description of what happened or what was done.

```
2026-04-22T02:14:33Z — Hunter `webshell-php` flagged 3 PHP files under /home/c1234/public_html/pub/media/.cache on host-7
2026-04-22T02:18:01Z — Engineer J on-call paged via P1 trigger
2026-04-22T02:31:14Z — Containment hold placed on host-7 (httpd stop, account suspend)
2026-04-22T02:47:55Z — Cross-host correlation identified hosts 2, 4, 9 sharing callback domain
2026-04-22T03:04:09Z — APF block deployed for callback IP across fleet
2026-04-22T03:14:22Z — ModSec rule 100501 deployed blocking the URL-evasion request shape
```

Conventions:

- Timestamps are absolute, never relative. "At 03:14 UTC" not "this morning" or "ten minutes ago" — relative timing breaks the moment the brief is read in a different timezone or hours later.
- ISO-8601 with `Z` suffix. Local-time conversion is the reader's responsibility.
- Append-only across brief revisions. A wrong entry is corrected with a follow-up entry naming the correction, not by editing the original.
- Each entry names the actor when it matters: "Engineer J", "Hunter `webshell-php`", "Customer support agent K". Anonymous actions ("a block was deployed") obscure the audit trail.
- Sub-minute precision is appropriate for high-cadence sequences; minute precision is fine for slower work.

## Indicators of Compromise — fenced code block

The IOC block is structured for copy-paste into a SIEM, a threat-intel platform, or a downstream block list. Prose interspersed with IOCs forces the reader to parse; a clean block does not.

```
## File-system indicators
/home/<user>/public_html/pub/media/.cache/<random>.php
/home/<user>/public_html/.htaccess  (modified, auto_prepend_file directive added)
/home/<user>/.config/systemd/user/<random>.service

## Hashes (SHA-256)
3f4a7c... <random>.php variant 1
8c1d9e... <random>.php variant 2
b22f5a... loader.php (auto_prepend_file target)

## Network indicators
198.51.100.42  (initial-access source IP)
203.0.113.17   (C2 callback destination)
malicious[.]example[.]top  (C2 hostname; defanged in non-machine-readable contexts)

## URL patterns
POST /rest/V1/<endpoint>  (initial access vector, request body length > 8192)
GET /pub/media/.cache/<random>.php  (post-exploitation access)
```

IOC discipline:

- File paths use generic placeholders (`<user>`, `<random>`) when the brief is shared outside the responding team; full paths only inside the originating team's own brief.
- Hashes are SHA-256, full length, with a one-line label naming what the hash represents.
- Network indicators include source IPs, destination IPs, hostnames, and observed user-agent strings if relevant.
- Hostnames and URLs use defanged notation (`.` → `[.]`) when the brief crosses organizational boundaries to prevent click-fishing in chat clients.
- URL patterns include the request method and any body-length or header signature that distinguishes the malicious request from a legitimate one of the same shape.

## Affected scope

Three numbers, all named explicitly:

- **Host count** — how many systems show the indicators.
- **Customer count** — how many distinct customer accounts are implicated.
- **Data class** — what category of data is potentially exposed (PII, payment, credentials, none-known). Always include the basis for the data-class call: "PII potentially exposed via Magento customer database read access; no confirmed exfiltration as of <timestamp>".

Avoid "we don't know yet" as a final answer in this section. If the count is in flight, name the bound: "between 4 and 12 hosts; precise count pending fleet sweep, expected complete by 04:30 UTC".

## Containment actions taken

Chronological. Each entry names what was done, when, and by whom. Containment is distinct from defense — containment stops the immediate bleed; defense prevents recurrence.

```
- 02:31 UTC, Engineer J — placed containment hold on host-7 (httpd stop, account suspend)
- 02:48 UTC, Engineer J — extended containment hold to hosts 2, 4, 9
- 03:04 UTC, Engineer K — APF deny inserted across fleet for callback IP 203.0.113.17
- 03:22 UTC, Engineer J — customer notification sent for affected accounts
```

A containment action that turned out to be wrong (over-blocked, suspended the wrong account) is reverted with a new timeline entry, not by deleting the original.

## Remaining risk

What is not yet known, what is not yet contained, what could still emerge. Each item is one sentence ending in an ETA or a gating event.

```
- Cleanup of dropped files on hosts 2, 4 is in progress; complete by 06:00 UTC.
- Forensic image capture for host-7 in progress for post-incident review; complete by 12:00 UTC.
- Customer-database integrity audit pending for 9 implicated accounts; preliminary results by 18:00 UTC.
- Open question: whether attacker established persistence beyond the visible droppers; under investigation, no signal yet either way.
```

The "open question" framing maps directly onto the case engine's `open_questions_additions` field — the brief's open items are the case's open questions in prose form.

## Defensive measures deployed

Distinct from containment. Defensive measures are the lasting changes that prevent recurrence: ModSec rules, APF blocks, configuration hardening, vendor patches.

```
- ModSec rule 100501 deployed across fleet blocking the URL-evasion request shape (image-extension URI with PHP handler).
- APF deny added for 203.0.113.17 across fleet via shared `/etc/apf/import/incident-2026-04-22.rules`.
- Magento 2.4.7-p4 upgrade scheduled for affected accounts, communicated to customers, target completion 2026-04-23.
- Hunter signature `webshell-polyshell-v2` updated with the obfuscation variant observed in this incident.
```

Each measure is a deliverable: rule id, manifest entry, ticket reference, signature update. Vague entries ("hardened the firewall") are not measures; specific entries are.

## Lessons learned

Single section, near the end. Never embed lessons in earlier sections — earlier sections are the record of what happened, this section is the meta-commentary.

The lessons-learned format is two to five bullets, each one sentence:

- One thing that worked — name the specific tool, signal, or process.
- One thing that did not work — name the specific gap.
- One process change that follows from the gap, with an owner and a target date.

```
- The cross-host correlation hunter caught the campaign shape within 33 minutes of the first single-host alert; that latency is acceptable.
- The initial APF deploy was manual per-host; deploying via the shared import file would have cut deployment time from 18 minutes to under 2.
- Process change: incident-response runbook updated with shared-import deploy pattern. Owner: J. Target: 2026-04-29.
```

Lessons learned are specific or they are nothing. "We need better tooling" is not a lesson. "The cross-host correlation hunter caught the campaign within 33 minutes; the per-host deploy took 18 minutes that the import-file deploy would have cut to 2" is.

## Voice rules across the whole brief

- Absolute timestamps, never relative.
- Past tense for completed actions, present continuous for in-flight, neutral future for scheduled work ("expected complete by", not "will have been completed by").
- Named actors when attribution matters, anonymous when it does not (the customer notification email is not the place for individual engineer names).
- IOC blocks as fenced code, never as inline prose.
- Numbers, not adjectives. "Twelve customers affected" not "several customers"; "33-minute correlation latency" not "fast correlation".
- No "we believe", "appears to", "may have" hedging on confirmed facts. Reserve hedging for genuinely uncertain calls and pair with a confidence number.
- Defensive framing throughout: "the URL-evasion request shape was blocked", not "we exploited the rule we wrote".

## Brief revision lifecycle

A brief is updated, not replaced, across the incident:

- Initial brief at incident open: TL;DR + Severity + Timeline (one entry) + IOC block (preliminary). Other sections empty.
- Mid-incident updates: append timeline entries, expand IOC block, fill in scope and containment as data lands.
- Post-incident final: all sections populated, lessons-learned written, severity downgraded to closed.

Every revision carries a revision header at the very top:

```
Brief: incident-2026-04-22 — Magento APSB25-94 cross-host campaign
Revision: 4 of N (final pending lessons-learned review)
Last updated: 2026-04-22T05:14:00Z by Engineer J
```

The revision number plus update timestamp prevents the most common operational failure: two readers acting on different revisions and stepping on each other's containment moves.

<!-- public-source authored — extend with operator-specific addenda below -->
