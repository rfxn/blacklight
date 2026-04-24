# IOC Categorization

**Source authority:** the STIX 2.1 IOC taxonomy from OASIS
<https://oasis-open.github.io/cti-documentation/stix/intro>
and the operator-voice category convention used across published IR briefs from CISA and Sansec. STIX provides the superset taxonomy; this skill narrows to the eight categories that consistently appear in hands-on managed-fleet briefs. The curator loads this skill when populating Section 4 of a brief — the section the reader greps against their own logs for self-check.

---

## The 8-category mandatory order

Section 4 presents indicators in this order. The order reflects how an operator reads the section — signatures first (scanner match is the fastest self-check), then network indicators (block at the edge), then file and behavioral indicators (cleanup work), then soft indicators (diagnostic only), then response-code patterns and grep-ready strings (self-audit tools).

1. **Signatures**
2. **Adversary IPs**
3. **File artifacts**
4. **Post-exploitation indicators**
5. **Domains / URLs**
6. **User-Agents**
7. **HTTP response codes**
8. **Log-detection strings**

Every category gets its own heading, its own table, and a one-sentence charter. Do not fold two categories into a single table.

---

## Category 1 — Signatures

Scanner-rule name paired with the scanner. Operators running the same scanner can self-check immediately.

| Signature | Scanner | Family | Notes |
|-----------|---------|--------|-------|
| `PHP.Backdoor.PolyShell.UNOFFICIAL` | LMD | PolyShell | 9 variants (see `webshell-families/polyshell.md`) |
| `PHP.Backdoor.AccessOn.UNOFFICIAL` | LMD | AccessOn | Cookie-gated backdoor |

If more than one scanner is in use, add a column per scanner with the matching rule name from each.

---

## Category 2 — Adversary IPs

One row per IP per role per time-range. Columns: IP, Role, Confidence, First-seen, Last-seen, Request count.

| IP | Role | Confidence | First seen | Last seen | Requests |
|----|------|------------|------------|-----------|----------|
| 198.51.100.42 | Initial-intrusion | Confirmed | 2026-04-12 08:14 | 2026-04-12 08:47 | 18 |
| 198.51.100.42 | C2 / poll | High | 2026-04-14 02:00 | 2026-04-19 23:50 | 1,412 |
| 203.0.113.7 | Scanner | Suspected | 2026-04-11 15:20 | 2026-04-19 22:55 | 342 |

Role vocabulary comes from [../actor-attribution/role-taxonomy.md](../actor-attribution/role-taxonomy.md). Confidence labels come from the calibration section below.

**IP format rules:**

- Use the documentation-reserved ranges (`198.51.100.0/24`, `203.0.113.0/24`, `192.0.2.0/24` per RFC 5737) in skill examples. Actual incident IPs go in the brief, not in this skill file.
- Sansec-published adversary IPs may appear in a brief when cited with the Sansec research URL; never quote them without the citation.
- Commercial-scanner IPs (Shodan, Censys, Binary Edge) are filtered before the table — see the anti-pattern below.

---

## Category 3 — File Artifacts

Path-shape + hash + count-observed across the fleet.

| Path shape | Hash (sha256) | Observed on |
|-----------|---------------|-------------|
| `/HOME/CUSTOMER_N/public_html/pub/media/custom_options/quote/<hashname>.gif` | 3a8c...f21e | 14 hosts |
| `/HOME/CUSTOMER_N/public_html/pub/media/accesson.php` | 7b2d...a49c | 8 hosts |

**Path-shape convention:** every file path in the IOC table uses the sanitized shape `/HOME/CUSTOMER_N/public_html/...`. Never the raw hosting path (`/home/acmecorp/public_html/...`). Never the internal customer identifier. The `N` in `CUSTOMER_N` is a placeholder; `_1`, `_2` indices are permissible when separating multiple customers in the same incident.

**Non-obvious rule:** an IOC list must be **publishable-safe**. Customer-identifiable paths turn the brief into a privacy-escalation risk and make external publication impossible. Sanitize on authoring, not on export.

---

## Category 4 — Post-Exploitation Indicators

Behavioral indicators that do not fit a signature or a single file path. `.htaccess` additions, admin-user additions, cron-job additions, sprayed filenames.

| Indicator | Location | Count | Notes |
|-----------|----------|-------|-------|
| `.htaccess` with `SetHandler application/x-httpd-php` for a non-standard extension | `/HOME/CUSTOMER_N/public_html/pub/media/` | 3 hosts | Enables `.gif`/`.png` to execute as PHP |
| Unexplained admin user added to `admin_user` table | Magento DB | 2 hosts | Username often `support` or `admin2` |
| Cron entry invoking PHP binary with base64-encoded argument | `/etc/cron.d/` or Magento `cron_schedule` table | 1 host | Persistence layer |
| `accesson.php` sprayed across 5-10 directories | `pub/media/`, `app/code/`, `app/etc/` | 8 hosts | See `magento-attacks/admin-backdoor.md` |

---

## Category 5 — Domains / URLs

C2 endpoints, exfiltration endpoints, callback URLs. WebRTC STUN / TURN destinations when a Magecart-class skimmer is in scope.

| Endpoint | Protocol | Role | First seen |
|----------|----------|------|------------|
| `skim.example[.]org/collect` | HTTPS POST | Exfil | 2026-04-15 |
| `stun.<opaque>[.]org:3479` | WebRTC STUN | C2 channel | 2026-04-16 |

Defang domains in the brief (`example[.]org`) following standard IR-brief convention. Do not defang scanner signatures or file paths — they are not clickable.

---

## Category 6 — User-Agents

Diagnostic only. **Never use a User-Agent as a sole IOC.** UAs are cheap to spoof; treating them as authoritative produces false positives on legitimate browsers and false negatives on any adversary who rotates.

| User-Agent string | Paired signal | Notes |
|-------------------|---------------|-------|
| `python-requests/2.X` with POST to upload path | + IP cluster + path shape | Suggests automated scanner, not browser |
| `Mozilla/5.0 ... Chrome/... (Windows NT 10.0)` with POST to admin | + post-auth admin session | Normal browser shape, diagnostic only |

The UA table is the smallest in Section 4; include only UAs that pair with another signal to reach confidence.

---

## Category 7 — HTTP Response Codes

Response-code patterns that discriminate compromise state from mitigation state.

| Pattern | Meaning |
|---------|---------|
| `POST /pub/media/custom_options/... HTTP/1.1 200` | Upload succeeded; compromise signal if payload lands as `.php` |
| `POST /pub/media/accesson.php HTTP/1.1 200` | Shell executing; compromise confirmed |
| `POST /pub/media/accesson.php HTTP/1.1 403` | Webserver deny rule holding; mitigation effective |
| `POST /pub/media/accesson.php HTTP/1.1 404` | Shell removed OR path never existed; filesystem check required to disambiguate |
| `POST /pub/media/... HTTP/1.1 302` | Auth redirect; shell behind an auth layer, review intended |

A `200` response to a POST at an unexpected path is a compromise signal; a `403` at the same path is a mitigation-effectiveness signal. Same HTTP request, opposite operational meanings. The table captures this discrimination explicitly.

---

## Category 8 — Log-Detection Strings

Grep-ready patterns operators can run against their own logs to self-check for exposure.

```bash
# Apache combined log — POST to custom_options with 200
grep -E 'POST [^ ]*/custom_options/[^ ]+ HTTP/[0-9.]+" 200' access_log

# ModSec audit — any Section A block referencing the upload path
grep -B1 -A40 '/custom_options/' modsec_audit.log | grep -E 'Host:|Content-Type:'

# Filesystem — .php files written under pub/media in the last 30 days
find /HOME/*/public_html/pub/media -name '*.php' -mtime -30 -printf '%T@ %p\n' | sort -n
```

Every grep in this category operates against artifacts the operator already has on their own systems — no external lookups, no login-gated portals. This is the self-audit toolkit for readers who cannot wait for a vendor alert.

---

## De-duplication rule

**Same IP, same role, same time-range → one row.** No duplicate rows for identical (IP, role, window) tuples.

**Same IP, different roles across the incident → two rows with distinct time-ranges.** When an IP starts as an Initial-intrusion actor at 08:00 and returns at 14:00 as a C2 poll source, list both rows. The role transition is itself an IOC — collapsing it to one row erases that signal.

**Same IP, same role, different time-ranges → one row with the union of the ranges unless the gap is operationally meaningful.** A 3-minute gap within a session collapses; a 48-hour gap is two sessions and warrants two rows.

---

## Confidence calibration

Five bands; anything below 0.5 does not belong in Section 4 at all.

| Band | Label | Criteria |
|------|-------|----------|
| ≥ 0.9 | Confirmed | Multi-source corroboration — signature match + log evidence + filesystem artifact |
| 0.7 – 0.9 | High-confidence | Two independent signals from the list above |
| 0.5 – 0.7 | Suspected | One signal; other signals consistent but absent |
| 0.3 – 0.5 | — | Move to Section 8 (Open Items), not Section 4 |
| < 0.3 | — | Do not include anywhere; it is noise |

The label column in each IOC table uses `Confirmed`, `High`, `Suspected`. The numeric band is an authoring discipline, not a required column — include it only if the brief's reader has an analytic use for it.

---

## Anti-Pattern — Commercial-scanner padding

IOC lists padded with commercial-scanner IPs (Shodan, Censys, Binary Edge, Rapid7 Sonar) to inflate the indicator count are a recognizable failure mode. Reviewers catch it immediately; operators who run the brief against their own logs see the same scanner IPs against every host and lose trust in the whole list.

**Filter before listing.** Maintain a commercial-scanner allowlist and subtract it from the candidate pool before building the table. A brief with 17 real adversary IPs is stronger than a brief with 147 candidate IPs of which 130 are scanners.

---

## Triage checklist

- [ ] All 8 categories present in mandatory order
- [ ] Each category has its own heading and its own table
- [ ] All file paths use the sanitized `/HOME/CUSTOMER_N/...` shape
- [ ] Adversary-IP roles drawn from `actor-attribution/role-taxonomy.md`
- [ ] Confidence labels applied consistently across tables
- [ ] Commercial-scanner IPs filtered out before listing
- [ ] User-Agent table contains only UAs paired with another signal
- [ ] Domains defanged (`example[.]org`) per IR-brief convention
- [ ] Log-detection strings are grep-ready (copy-pasteable)
- [ ] Any entry at confidence <0.5 moved to Section 8 (Open Items)

---

## See also

- [template.md](template.md) — Section 4's placement in the overall brief
- [severity-vocab.md](severity-vocab.md) — severity phrasing paired with IOC confidence
- [executive-summary-voice.md](executive-summary-voice.md) — Section 1 that summarizes IOC roll-up counts
- [../actor-attribution/role-taxonomy.md](../actor-attribution/role-taxonomy.md) — role vocabulary for Category 2 adversary-IP rows
- [../linux-forensics/](../linux-forensics/) — log-artifact parsers that produce input for Categories 2, 7, and 8

<!-- adapted from beacon/skills/ic-brief-format/ioc-categorization.md (2026-04-23) — v2-reconciled -->
