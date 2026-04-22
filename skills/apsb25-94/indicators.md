# APSB25-94 — Adobe Commerce / Magento indicators (public advisory digest)

**Scope.** This skill summarizes publicly disclosed indicators and behaviors
associated with Adobe Security Bulletin APSB25-94, targeting Adobe Commerce
and Magento Open Source 2.4.x pre-auth RCE and post-exploitation
(March 2026 advisory). Content is drawn **exclusively** from the public
advisory and public threat-intel reporting — no operator-side customer data,
no non-public IOCs. See HANDOFF §"Data" and CLAUDE.md "Data" sections.

## Authoritative sources
- Adobe Security Bulletin APSB25-94 (public URL — **TODO: paste exact URL**
  from the advisory page)
- Adobe Magento Open Source advisory follow-up (**TODO: paste URL**)
- Public CERT / CVE references (**TODO: list**)

## Affected versions
**TODO:** paste the exact version ranges from the public advisory rather than
summarizing from memory. Source-of-truth discipline — if it isn't a direct
quote from the advisory, it doesn't go here.

## Publicly documented indicators
*Structured by category. Each indicator must cite a public source URL.*

### URL-evasion behavior
**TODO:** the `.jpg` / `.png` / `.gif` → PHP execution routing pattern as
documented in the advisory.

### Initial-access payload characteristics
**TODO:** from the advisory's described payload class. Cite.

### Post-exploitation artifacts (publicly reported)
**TODO:** file-system paths and names reported in public write-ups. Cite
each.

### C2 infrastructure patterns (publicly reported)
**TODO:** `.top` TLD callbacks and domain-structure patterns from public
reporting. Cite each.

## Timing
**TODO:** advisory publication date, patch availability window, and first
publicly reported in-the-wild exploitation. Cite.

## How this skill is used
Loaded by the router when:
- The target stack includes Magento 2.x, AND
- The Adobe advisory publication date is **after** the earliest suspicious
  filesystem mtime observed on a host (i.e., the compromise plausibly
  exploits this advisory).

Drives: intent reconstructor's dormant-capability inference for APSB25-94-class
PolyShell deployments; synthesizer's reactive rule shaping for URL-evasion
blocks.

## Operator note
Operator led incident response for APSB25-94 at scale in late March 2026.
The operator's lived understanding informs *which public advisory details
matter* for IR triage, but **no content in this file derives from
non-public data**. If a detail cannot be sourced to a public URL, it does
not appear here.
