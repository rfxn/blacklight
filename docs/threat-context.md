# Threat context — vulnerability-to-exploitation collapse

Why blacklight prioritizes post-incident forensics over patch-race acceleration.
Sourced summary of public 2025–2026 reporting on the disclosure-to-exploitation
window. All citations are public press, advisory, or vendor research. No
customer data, no non-public IOCs.

## 1. The collapsed window

The median time from public vulnerability disclosure to first observed
in-the-wild exploitation has fallen from **756 days (2018)** to hours (2025–26)
across multiple independent measurements:

- **Patchstack 2026** — weighted median time from WordPress vulnerability
  disclosure to first mass exploitation: **5 hours**. 46% of disclosed
  vulnerabilities had no patch available at disclosure time.
- **CISA KEV catalog** — 28.96% of 2026 entries were exploited on or before
  CVE publication day (up from 23.6% in 2024). Median time-to-KEV-inclusion
  fell from 8.5 to 5.0 days (Rapid7).
- **Mandiant M-Trends 2026** — adversary hand-off time (initial-access broker
  to ransomware operator) collapsed to 22 seconds.
- **Google/Mandiant** — 67.2% of exploited CVEs in 2026 are zero-days, up from
  16.1% in 2018. 55% of zero-days were exploited within one week of public
  disclosure; 28% of 2025 exploits were launched within one day.
- Vendors take an average of 15 days to patch actively-exploited
  vulnerabilities — longer than the exploitation window itself.

Mechanism: advisories that include affected file, parameter name, root-cause
explanation, or sample code are effectively turnkey. LLM-assisted exploit
development collapses the patch-diff → working-PoC pipeline from days to hours.
Attackers no longer wait for mass-exploitation kits — the advisory text is the
kit.

## 2. AI-stack tooling — three documented honeypot timelines

Sysdig's honeypot fleet produced three near-identical timelines in ~6 weeks of
early 2026, demonstrating that the pattern applies regardless of install-base
size:

| CVE | Product | First in-the-wild | Vector |
|---|---|---|---|
| CVE-2026-33626 | LMDeploy (LLM inference) | 12h31m | SSRF → IMDS, Redis, MySQL port-scan, DNS exfil |
| CVE-2026-39987 | Marimo (Python notebook) | 9h41m | Pre-auth RCE, CVSS 9.3; SSH key + .env harvest |
| CVE-2026-33017 | Langflow (LLM orchestration) | 20h | No public PoC — exploit built from advisory text alone |

Each was a critical or high-severity flaw in a tool with relatively narrow
adoption. Attackers scanned for vulnerable instances within hours of advisory
publication, regardless of install-base size.

## 3. Adobe Commerce / Magento — SessionReaper (CVE-2025-54236)

The exhibit blacklight reconstructs (`exhibits/fleet-01`) is the public
APSB25-94 / SessionReaper incident. Timeline as documented by Sansec, Adobe,
Searchlight Cyber, and CISA:

- **2025-09-04** — Adobe Commerce customers given advance patch notice
  (Magento Open Source users not alerted)
- **2025-09-09** — emergency out-of-band patch released after accidental leak;
  Adobe breaks regular two-month update cycle
- **2025-09 → 2025-10-22** — Sansec monitors 10% of install base; zero attacks
  observed for six weeks
- **2025-10-22** — Searchlight Cyber publishes technical deep-dive; mass
  exploitation begins same day
- **2025-10-22 + 24h** — Sansec observes 250+ exploitation attempts; attacker
  infrastructure scales from 5 IPs to 97 IPs in days
- **Late October 2025** — half of all Magento stores worldwide probed or
  attacked; only 38% patched at peak attack window
- **2025-10-24** — Adobe priority rating elevated to 1
- **2026-03** — CISA adds CVE-2025-54236 to Known Exploited Vulnerabilities
  catalog; probing continues

Vulnerability class: improper input validation → unauthenticated remote code
execution via nested deserialization in the Commerce REST API. CVSS 9.1.

Sansec's lineage frame, lightly paraphrased: SessionReaper is comparable to
Shoplift (2015), Ambionics SQLi (2019), TrojanOrder (2022), and CosmicSting
(CVE-2024-34102, 2024). Each time, thousands of stores were compromised,
sometimes within hours of disclosure. The pattern is recurring, and getting
faster.

## 4. WordPress and WooCommerce — the long-tail surface

Per Patchstack's *State of WordPress Security 2026*:

- 11,334 new WordPress ecosystem vulnerabilities in 2025 (+42% YoY)
- ~13,000 WordPress sites compromised per day (4.7M annually)
- January 2026: 250+ plugin vulnerabilities disclosed weekly
- More than half of plugin developers contacted by Patchstack did not patch
  before public disclosure
- **92% of successful WordPress breaches in 2025 originated in plugins or
  themes, not WordPress core**
- 87.8% of WordPress-specific exploits bypass standard hosting firewalls

Patchstack 2026 specifically calls out *vibe coding* — developers shipping
LLM-generated plugin code they cannot audit — as a structural driver of
unpatched vulnerabilities reaching production.

WooCommerce-specific note: the API-surface attack pattern. Headless
WooCommerce attacks land on `/wp-json/wc/store/v1` and bypass WAF rules tuned
for `wp-admin` and login pages. Recent examples:

- CVE-2025-13773 — Print Invoice & Delivery Notes RCE (unauth, all versions
  ≤5.8.0; Dompdf PHP eval)
- CVE-2025-60219 — WooCommerce Designer Pro arbitrary file upload
- CVE-2025-12955 — Live Sales Notification customer PII leak
- CVE-2025-64328 — Store API guest order exposure

Notable WordPress-core-adjacent CVEs:

- CVE-2025-8489 (King Addons for Elementor) — Wordfence blocked 48,400
  exploit attempts post-disclosure
- CVE-2025-14533 (ACF Extended) — 100k sites; ~half exposed despite a 4-day
  patch
- CVE-2026-0740 (Ninja Forms File Upload) — 50k sites, unauth PHP upload
- CVE-2026-3098 (Smart Slider 3) — 800k+ active installations exposed

## 5. Implication for defender tooling

Three structural facts follow from the above and shape blacklight's design:

1. **Patch cadence cannot win the race.** A 5-hour median exploitation window
   is shorter than monthly scans, weekly maintenance windows, or business
   hours. "Patch faster" is a necessary but insufficient control.
2. **The attack surface is the long tail.** 92% of WordPress compromises
   originate outside core. Hosting providers and MSPs cannot patch what they
   do not maintain — the third-party plugin and theme ecosystem.
3. **Post-incident forensics is where the time asymmetry is winnable.**
   Attacker dwell time, persistence, and lateral movement happen on
   minutes-to-hours timescales. Reconstructing what landed, what it modified,
   and what to eject is the defender's structural advantage — and the surface
   blacklight targets.

## Sources

### Cross-ecosystem trend
- [LMDeploy CVE-2026-33626 Exploited Within 13 Hours — The Hacker News](https://thehackernews.com/2026/04/lmdeploy-cve-2026-33626-flaw-exploited.html)
- [Marimo RCE CVE-2026-39987 Exploited Within 10 Hours — The Hacker News](https://thehackernews.com/2026/04/marimo-rce-flaw-cve-2026-39987.html)
- [Critical Langflow CVE-2026-33017 — The Hacker News](https://thehackernews.com/2026/03/critical-langflow-flaw-cve-2026-33017.html)
- [CVE-2026-33626: How attackers exploited LMDeploy in 12 hours — Sysdig](https://webflow.sysdig.com/blog/cve-2026-33626-how-attackers-exploited-lmdeploy-llm-inference-engines-in-12-hours)
- [Marimo vulnerability exploited within hours — SC Media](https://www.scworld.com/brief/marimo-vulnerability-exploited-within-hours-of-disclosure)
- [From CVE to RCE in Hours — Hive Security](https://hivesecurity.gitlab.io/blog/from-cve-to-rce-in-hours-attack-timeline-2026/)

### Adobe Commerce / Magento — SessionReaper
- [SessionReaper, unauthenticated RCE in Magento & Adobe Commerce (CVE-2025-54236) — Sansec](https://sansec.io/research/sessionreaper)
- [Over 250 Magento Stores Hit Overnight — The Hacker News](https://thehackernews.com/2025/10/over-250-magento-stores-hit-overnight.html)
- [Adobe Commerce SessionReaper — CSO Online](https://www.csoonline.com/article/4055037/adobe-commerce-and-magento-users-patch-critical-sessionreaper-flaw-now.html)
- [Fear the 'SessionReaper' — Dark Reading](https://www.darkreading.com/vulnerabilities-threats/sessionreaper-adobe-commerce-flaw-under-attack)
- [Critical Adobe Commerce vulnerability under attack — Help Net Security](https://www.helpnetsecurity.com/2025/10/23/adobe-magento-cve-2025-54236-attack/)
- [CISA adds Adobe Commerce/Magento to KEV — Security Affairs](https://securityaffairs.com/183815/security/u-s-cisa-adds-microsoft-wsus-and-adobe-commerce-and-magento-open-source-flaws-to-its-known-exploited-vulnerabilities-catalog.html)
- [Adobe Security Bulletin APSB25-88](https://helpx.adobe.com/security/products/magento/apsb25-88.html)

### WordPress and WooCommerce
- [State of WordPress Security in 2026 — Patchstack](https://patchstack.com/whitepaper/state-of-wordpress-security-in-2026/)
- [WordPress Plugin Vulnerability Exposes 800,000+ Sites — Cybersecurity News](https://cybersecuritynews.com/wordpress-plugin-vulnerability-exposes/)
- [Critical WordPress Plugin Admin Takeover — eSecurity Planet](https://www.esecurityplanet.com/threats/critical-wordpress-plugin-vulnerability-allows-admin-account-takeover/)
- [CVE-2025-13773: WooCommerce Delivery Notes RCE — SentinelOne](https://www.sentinelone.com/vulnerability-database/cve-2025-13773/)
- [CVE-2025-60219: WooCommerce Designer Pro File Upload — ZeroPath](https://zeropath.com/blog/cve-2025-60219-woocommerce-designer-pro-file-upload)
- [CVE-2025-12955: WooCommerce Plugin Info Disclosure — SentinelOne](https://www.sentinelone.com/vulnerability-database/cve-2025-12955/)
