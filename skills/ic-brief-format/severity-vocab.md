# ic-brief-format — severity vocabulary

Loaded alongside `template.md` when producing operator-facing briefs. This file is the lookup of *which severity level names which class of incident* and *what trigger downgrades a severity level during the incident lifecycle*.

Authoritative references: NIST SP 800-61 Rev.2 "Computer Security Incident Handling Guide" at `https://nvlpubs.nist.gov/nistpubs/SpecialPublications/NIST.SP.800-61r2.pdf` (Sections 3.2 Incident Response Lifecycle and 3.2.6 Incident Prioritization) for the containment/eradication phase framing; SANS Incident Handler's Handbook (`sans.org/white-papers`) for the functional-impact + information-impact two-axis severity model; FIRST Traffic Light Protocol 2.0 at `https://www.first.org/tlp/` for the notification-distribution axis. Severity definitions here extend `template.md:33-45`, which names P0-P4 but does not provide the class-to-severity mapping — that mapping is the point of this file.

The ladder is staged to the incident classes blacklight exercises in demo and in operator work: webshell, credential harvester, skimmer, false-positive, recon. Any class not in the mapping below requires explicit operator override on the brief's severity line.

---

## The P0-P4 ladder

Five levels. Each level names a named trigger (who is affected, what is in motion) and a named pager behavior.

- **P0 — system-level active compromise.** Root-or-equivalent execution on shared platform; attacker-controlled code runs outside any single tenant's blast radius. Pager fires unconditionally, all hours. Examples: webshell written under `/usr/local/cpanel/`, credential harvester exfiltrating platform operator credentials, skimmer injected into a shared template affecting multiple tenants' checkouts.
- **P1 — tenant-level active compromise.** Single-tenant compromise with confirmed attacker-controlled execution and ongoing blast inside that tenant. Pager fires immediately, all hours. Examples: webshell in `/home/<user>/public_html/` with confirmed `POST` hits during the current incident window, active C2 callbacks observed in the access log.
- **P2 — tenant-level suspected compromise.** Strong signal but one load-bearing element not yet confirmed (no execution proof, no active callback, no verified downstream impact). Pager fires during business hours; escalates to P1 on confirmation. Example: PolyShell-family file discovered in a tenant docroot with no corresponding access-log hit in the last 7 days.
- **P3 — internal or low-blast issue.** System-side issue that does not implicate tenant data; or a tenant-side finding confirmed as false-positive with no lateral exposure. Notify the channel; no page. Examples: a ModSec rule blocking legitimate admin traffic; a flagged file resolved to a composer-installed vendor artifact per `false-positives/vendor-tree-allowlist.md`.
- **P4 — informational.** Notable for the record, no action required. Channel post for awareness. Examples: reconnaissance activity with no exploitation signal (admin-path wordlist probes from one source IP, all returning 404).

`template.md:38-41` already defines P1-P4 in prose; this file extends that with P0 for system-level classes and attaches the concrete trigger classes below.

---

## Class → severity default table

The defaults are the starting point. Every brief names the trigger on the severity line, which is also the point at which the level can diverge from the default (operator override on documented grounds).

| Incident class | Default severity | Load-bearing trigger |
|---|---|---|
| Webshell on shared platform (`/usr/local/cpanel/`, `/usr/local/`, system-owned paths) | P0 | Non-tenant path; attacker reached outside any single `/home/<user>/` subtree |
| Webshell in single tenant (`/home/<user>/public_html/`) with confirmed dispatch | P1 | Access-log hit on the file during incident window OR `.htaccess` change enabling handler routing |
| Webshell in single tenant, no dispatch evidence | P2 | File present, no log hit in retained window; needs confirmation pass |
| Credential harvester present AND active (any scope) | P0 | Harvester code path invoked per `webshell-families/polyshell.md:82-84` dormant-capability rule; exfil channel observed |
| Credential harvester staged but dormant | P2 | Capability present, not invoked; rank per dormant-capability inference rules |
| Skimmer injected into checkout AND active callback observed | P0 | Customer-visible payment data at risk; every transaction during the window is exposed |
| Skimmer injected, callback not yet active | P1 | Exposure imminent; containment time-bounded by the operator's activation gate |
| Lateral-movement confirmed (multi-tenant, shared infra) | P0 | Single tenant no longer describes the blast; shared credentials or NFS mounts in scope |
| False-positive confirmed, no blast | P3 | Triaged per `false-positives/` trees, no anomaly remaining |
| Recon only (wordlists, admin-path probes, 404 bursts, no exploitation) | P4 | No post-recon action observed; raise to P3 if recon source IP lands on an active block list |

Rows collapse across two axes: **functional impact** (what the attacker can do right now) and **scope** (how many tenants or systems are affected). A class moves up when scope widens (single-tenant → shared platform, single-host → fleet) or when functional impact lands (dormant capability → active capability).

---

## Downgrade ladder

Severity is not static across a brief's lifetime. Downgrades are triggered by containment landing; each downgrade records the trigger inline on the brief's severity line and a matching timeline entry.

P0 → P1 triggers:
- Platform-scope containment in place; blast confined to a single tenant. Example: shared template restored from backup, per-tenant isolation confirmed, platform-scope callback blocked at the edge.
- System-level write path closed; no further attacker-controlled execution outside the affected tenant.

P1 → P2 triggers:
- Tenant account suspended via `whmapi1 suspendacct` (`hosting-stack/cpanel-anatomy.md:104-109`); no new access-log hits since suspension.
- C2 callback IP blocked at APF edge; no outbound to the callback for a documented quiet window (minimum 30 minutes observed).

P2 → P3 triggers:
- All dropped files removed and baseline confirmed; no persistence mechanism identified.
- Customer notification delivered; post-incident audit scheduled.

P3 → closed triggers:
- All defensive measures deployed and validated (ModSec rules loaded, APF denies active, vendor patches applied).
- Lessons-learned section written and reviewed.

A downgrade that later reverses (post-cleanup finding of persistence) re-opens the brief at the higher level with a new timeline entry. Silent downgrades — severity changed in the header without a timeline entry naming the trigger — violate `template.md:44`.

---

## Notification matrix

Who gets what, at what severity. The distribution model is FIRST TLP 2.0 applied to internal-incident distribution rather than external information-sharing.

- **P0** — on-call incident commander paged; secondary on-call paged; platform operations lead paged; customer-success on-call notified within 15 minutes of brief publication; compliance/legal notified if PII or payment data is in scope.
- **P1** — on-call engineer paged; incident commander paged; customer-success on-call notified when the affected tenant list is confirmed; compliance/legal notified if PII or payment data is in scope.
- **P2** — on-call engineer paged during business hours only; channel post at incident-open and at status-change moments.
- **P3** — channel post only; no page. Include the finding, the FP-resolution basis, and any adjacent followup.
- **P4** — channel post only; low-cadence. Batch P4 items in a weekly digest rather than posting each individually during active hours.

The notification line appears in the brief immediately below the severity line, formatted as: `Notifications: <who-paged>; <who-notified>; <who-info>`.

---

## Severity-line format

One line. Named level, named trigger, named scope. No prose, no hedging.

```
Severity: P1 — active C2 callbacks from compromised tenant storefront to external infrastructure; scope: 1 tenant, 0 adjacent tenants implicated.
Severity: P0 — webshell execution observed under /usr/local/cpanel/; scope: platform-wide.
Severity: P3 — flagged vendor/magento/framework/Filesystem/*.php resolved as composer-installed; no anomaly.
```

The trigger phrase answers the "why P<N>" question inline, so a reader scanning the brief never needs to guess which class produced the level. Matches `template.md:42` format; adds explicit scope annotation.

Never-silent-downgrade rule (also in `template.md:44`): any change to the severity level across brief revisions generates a timeline entry whose content is the trigger phrase from the new severity line. Readers comparing revision N to revision N-1 should be able to name the trigger without reading the full brief twice.

<!-- public-source authored — extend with operator-specific addenda below -->
