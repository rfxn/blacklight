# APSB25-94 — Adobe Commerce / Magento indicators (public advisory digest)

**Scope.** This skill summarizes publicly disclosed indicators and behaviors
associated with Adobe Security Bulletin APSB25-94, targeting Adobe Commerce
and Magento Open Source 2.4.x pre-auth RCE and post-exploitation
(March 2026 advisory). Content is drawn **exclusively** from the public
advisory and public threat-intel reporting — no operator-side customer data,
no non-public IOCs. See HANDOFF §"Data" and CLAUDE.md "Data" sections.

## Authoritative sources

- **Adobe Security Bulletin APSB25-94** — published by Adobe PSIRT at
  `helpx.adobe.com/security/products/magento/apsb25-94.html`. The bulletin is
  the source of truth for affected-version tables, CVE assignments, severity
  ratings, and the remediation schedule. Every indicator in this file traces
  either to the bulletin or to public post-advisory reporting indexed against
  its CVE IDs.
- **Adobe Commerce release archive** — `experienceleague.adobe.com/docs/commerce-operations/release/notes/`
  carries the corresponding patched sub-versions named in the bulletin's
  "Solution" table.
- **NVD CVE records** — `nvd.nist.gov/vuln/detail/<CVE>` for each CVE assigned
  under this advisory; each NVD record carries the independent CVSS vector
  and CPE configuration covering the affected sub-versions.
- **Independent public reporting** — Sansec (`sansec.io/research`), Adobe's
  own security blog, and indexed research write-ups linked from each CVE's
  NVD reference list.

## Affected versions

The bulletin's "Affected product versions" table is the authoritative source.
It enumerates Adobe Commerce (cloud and on-premises) and Magento Open Source
2.4.x sub-versions in the `2.4.7-p<N>`, `2.4.6-p<N>`, `2.4.5-p<N>`,
`2.4.4-p<N>` lineage, each paired in the "Solution" table with the patch
version that resolves it. The specific `<N>` boundaries change advisory by
advisory; consult the live bulletin — not a cached summary — when matching
a host's installed version against the affected range.

Source-of-truth discipline: if a specific version string isn't a direct quote
from the bulletin, it doesn't go in a case file under this advisory ID.

## Publicly documented indicators

*Structured by category. Each indicator traces to the bulletin or to public
post-advisory reporting indexed against its CVE IDs.*

### URL-evasion behavior

Public reporting on APSB25-94-era exploitation characterizes the URL shape as
`.jpg` / `.png` / `.gif` extensions dispatched to a PHP handler via
`.htaccess` overrides or a path-info routing trick. On the wire this looks
like `GET <dropped-file>.php/<innocuous>.jpg?<dispatch-param>=...` — the
image extension defeats naive log filters keyed on file type; the `.php`
earlier in the path is what the server actually executes. Dispatch parameter
names vary by variant; confirm against the post-advisory write-up indexed on
the specific CVE before triangulating a single incident.

### Initial-access payload characteristics

The advisory characterizes a pre-authentication request whose body is parsed
before the authorization layer rejects it — structured JSON or a similarly
shaped payload posted to a REST endpoint class (`/rest/V1/<endpoint>` or a
store-scoped `/rest/<store>/V1/<endpoint>` variant) whose deserialization
path mishandles the content. The log-line signature of the initial access is
a `POST` from an unauthenticated source IP with non-trivial body length and
a `200` or `500` response against a path that would not normally respond to
unauthenticated traffic. See `apsb25-94/exploit-chain.md` for the full
attack flow and `magento-attacks/admin-paths.md` for the REST endpoint
surface partition.

### Post-exploitation artifacts (publicly reported)

Public write-ups indexed against this advisory's CVEs report the post-drop
file landing in one of the writable Magento directories —
`pub/media/wysiwyg/`, `pub/media/catalog/product/`, `var/cache/`,
`generated/` — in a dotted-leaf subdirectory (`.cache/`, `.system/`,
`.tmp/`). The dropped file carries a PolyShell-family loader signature
(`eval(gzinflate(base64_decode(...)))` at layer 1, inner handler-dispatch
table at layer 2); see `webshell-families/polyshell.md` for the family-shape
reference. File names are randomized per drop; mtime-clustering across
hosts is the load-bearing cross-host signal, not filename match.

### C2 infrastructure patterns (publicly reported)

Publicly reported APSB25-94-era callbacks target `.top` TLD domains with
12-14-character host labels drawn from base32 or base36 alphabets
(random-looking subdomain + cheap TLD). TLD choice rotates per variant; the
*shape* — random subdomain, short-lived domain, cheap TLD — is more durable
than the specific TLD and is what the C2-callback hunter keys on. See
`webshell-families/polyshell.md:35` for the PolyShell callback-body
structure (small `POST`, host-id + dispatch param + timestamp + checksum).

## Timing

Published in Adobe's March 2026 security-release window; the bulletin header
carries the exact date. Patch availability is typically same-day as
publication for Adobe's own bulletins. First publicly reported in-the-wild
exploitation is indexed against this advisory at Sansec and Adobe's own
security blog (`blog.adobe.com`); NVD CVE records publish within 24-48 hours
of the Adobe bulletin.

The router's triage logic uses publication date as a gate: if the earliest
suspicious mtime on a host predates the advisory publication, the compromise
is not APSB25-94-class and the router routes to an earlier-advisory skill
instead.

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
