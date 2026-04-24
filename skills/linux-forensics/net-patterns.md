# linux-forensics — outbound network patterns after web-shell access

Loaded by the router when access.log or auth.log shows suspicious outbound callbacks. Pairs with `webshell-families/polyshell.md` (which describes the C2-callback capability shape) and `defense-synthesis/modsec-patterns.md` (which describes the rule shapes that block callbacks at the edge). This file is the lookup of *what callback evidence looks like in logs* and *which patterns separate adversary outbound from legitimate egress*.

## Where outbound evidence lands

Web-shell callbacks leave traces in five log surfaces. Check each; do not stop at the first signal.

- **Apache access.log** — the source-of-truth for HTTP requests handled by the host. Outbound calls made by PHP via `curl`, `file_get_contents`, or `fsockopen` do NOT appear here (they are outbound from the PHP process, not handled by Apache as inbound). What does appear: requests from external IPs to the webshell file paths themselves, and reverse-proxy access logs when the host is a proxy.
- **Apache modsec_audit.log** — when ModSec is in audit-on mode, full request body is captured for any rule that fires `auditlog`. The audit log is where exfiltrated data shows up if a rule was tracking it; also where the request that *triggered* a callback is most readable.
- **PHP-FPM error log** (`/var/log/php8.x-fpm.log` or `/var/log/php-fpm/error.log`) — outbound `curl` from PHP that fails or warns may surface here. Successful callbacks are usually silent, but a misconfigured target leaks the URL into the error log.
- **System auth.log / secure** — sshd outbound (the host being used as a pivot) lands here; sudo to run a network command also.
- **Firewall + EDR logs** — `iptables`/`nftables` LOG-target rules, APF dynamic block log (`/var/log/apf_log.log`), conntrack audit, any host-EDR egress capture. These are the only logs that catch outbound that the application stack does not.

DNS resolution evidence often sits separately: `/var/log/named/` if the host runs its own resolver, or via systemd-resolved (`journalctl -u systemd-resolved`). DNS queries to adversary infrastructure precede the HTTP callback by milliseconds — a DNS query is sometimes the only signal when the HTTP callback was rejected by an upstream firewall.

## Callback request shapes

Web-shell callbacks have a small set of recognizable request shapes. The shape is more durable than the destination — domains rotate, the structural pattern persists.

- **Unconditional POST on every command dispatch.** PolyShell-class shells (see `webshell-families/polyshell.md`) call back on every handler dispatch. The body is typically small (under 1 KB) and includes an identifier, a timestamp, and a checksum or HMAC. The request method is POST; the path is short; the User-Agent is generic (`curl/7.x`, `python-requests`, sometimes spoofed to a browser string).
- **Beaconing at fixed intervals.** Some shells beacon independently of dispatch — every N seconds or N minutes — to confirm the host is still alive. Beacon intervals are often suspicious round numbers: 30s, 60s, 300s. Cron-driven beacons land at the top of the minute or on `*/5` boundaries.
- **Long-poll callbacks.** Some shells open an outbound HTTP connection and hold it open waiting for commands. These look like a single long-duration TCP session in conntrack and a single long-duration request in the destination's logs (not visible from the source). conntrack `tcp ESTABLISHED` entries with high age and small total bytes transferred are the signal.
- **Burst exfil.** Skimmer hosts and credential-harvest hosts exfil in bursts when buffers reach a threshold. The pattern: long quiet, then several KB-to-MB POSTs in close succession, then quiet again. Volume is the signal — sustained high-rate small-POST traffic is the inverse pattern (beaconing); bursts of larger payloads with quiet between are exfil.

## Domain and IP signatures

Adversary infrastructure shape varies, but the patterns below recur enough to anchor on.

- **Cheap-TLD callbacks.** `.top`, `.xyz`, `.click`, `.icu`, `.cyou`, `.cfd`, `.bond` — registrars are inexpensive, registration friction is low, takedown response is slow. The TLD itself is not malicious; the *combination* of cheap TLD + random-looking subdomain + recent registration is the signal.
- **DGA-style hostnames.** Random-looking 10-16 character labels (`vagqea4wrlkdg.top`, `k3qmz8wpt7fdx.top`) generated from base32/base36 alphabets. A single-host visit to such a hostname is a near-certain adversary callback.
- **Free DNS infrastructure.** Subdomains under `*.duckdns.org`, `*.no-ip.com`, `*.dynu.net`, `*.freedns.afraid.org`, `*.serveo.net` — operator-controlled namespaces hosted on free dynamic DNS. Common in low-budget operations.
- **Tunneling endpoints.** `*.ngrok.io`, `*.serveo.net`, `*.localtunnel.me`, `*.lhr.life`, Cloudflare Tunnel `*.trycloudflare.com` — public reverse-tunnel endpoints used to expose adversary-side localhost services. Outbound traffic to these from a customer host is rarely legitimate.
- **Pastebin-class data drops.** `pastebin.com`, `paste.ee`, `hastebin.com`, `0x0.st`, `transfer.sh`, `gist.github.com`/raw — used as both payload retrieval (POST→download) and small exfil targets. A web-server process making a request to a pastebin is suspicious by category.
- **Known-good domains used as exfil.** Telegram bot API (`api.telegram.org`), Discord webhooks (`discord.com/api/webhooks/`), Slack webhooks, Microsoft Teams incoming webhooks, GitHub raw content. These are the hardest to filter because the destination is a category the host might legitimately need to reach. The signal here is *the process making the request* — a web-server worker has no business POSTing to a Discord webhook, even if the host's admin sometimes does.

IP-only callbacks (no DNS) are rarer in modern operations because they are trivially indexed by passive DNS and threat-intel feeds. When they appear: hosting-provider netblocks frequented by malware (low-cost VPS providers, residential-proxy networks) are the usual source. CIDRs from passive-DNS feeds are the gating signal — confirm against current threat-intel before adding to a manifest.

## DNS exfil and tunneling shapes

When HTTP egress is filtered, adversaries fall back to DNS for both callback and exfil. DNS-only channels are noisier per byte transferred but bypass most layer-7 filters.

- **Long subdomain queries.** Exfil-via-DNS encodes data into subdomain labels: `<base32-encoded-payload>.<adversary-domain>`. Queries with subdomain labels longer than ~32 characters, especially when many such queries land in succession, are the pattern.
- **High-volume TXT queries.** TXT-record retrieval is the standard DNS-channel callback shape — operator stages commands as TXT records, host queries them on a schedule, runs the response. A host making many TXT queries to a single domain over a short window is suspicious.
- **NULL or unusual record types.** `NULL`, `KEY`, `PRIVATE` record-type queries to non-DNSSEC contexts are uncommon outside adversary tools (`iodine`, `dnscat2`).

DNS evidence is captured in resolver logs when the host runs its own; via `tcpdump port 53` or eBPF-based captures otherwise. Most fleets do not capture DNS by default — its absence is the operational gap to surface in `bl-case/CASE-<id>/open-questions.md`.

## ICMP tunneling

ICMP echo-payload tunneling (`ptunnel`, custom variants) is rare but high-impact. Detection requires either a host-side packet capture or upstream NetFlow/sFlow analysis showing high-volume ICMP traffic to a single destination. ICMP echo requests from a web-server host to an external destination at any sustained rate are abnormal — `ping` from production web hosts is uncommon and `ping` to the same external destination at packet rates above 1/s for any duration warrants explanation.

## Distinguishing adversary outbound from legitimate egress

The hard part of outbound triage: web hosts make legitimate outbound for package updates, vendor APIs, license checks, monitoring, log shipping. The shape signals below help separate adversary-driven egress from legitimate egress.

- **Process attribution.** Legitimate outbound has a recognizable parent: `apt`/`yum`/`dnf` against package-mirror hostnames; vendor monitoring agent against vendor-controlled FQDNs; log shipper against the central log host. PHP worker processes (`php-fpm`, `apache2` with mod_php) reaching arbitrary external hosts is the alarm — production PHP rarely needs egress beyond payment processors and vendor APIs already in the application's connection allowlist.
- **Time-of-day patterns.** Legitimate outbound is spread across business hours and follows update cadences (nightly cron windows, weekly maintenance windows). Adversary-driven outbound is spread across all hours, with bursts that don't align to maintenance windows.
- **Volume cadence.** Sustained low-rate small-POST traffic (under 1 KB, every few seconds) is beaconing. Bursts of KB-to-MB POSTs separated by quiet periods is exfil. Legitimate egress is bursty around maintenance windows, low otherwise.
- **TLS fingerprints.** Where JA3 / JA4 capture is available: the TLS client fingerprint of `curl` invoked from PHP differs from the fingerprint of a real browser, and from the fingerprint of vendor agents. Mismatch between expected fingerprint and observed fingerprint on egress to a vendor-API hostname is a man-in-the-middle or adversary-tunnel signal.

## What to capture into evidence records

When triage finds an outbound callback, the evidence record under `bl-case/CASE-<id>/evidence/evid-*.md` should record: the source process if attribution is available; the destination hostname AND IP (DNS resolution may rotate); the request method, URI, and Content-Length; the User-Agent; the timestamp; and the request body if captured (modsec_audit.log is the usual source). Hostnames go into evidence storage with the same defanged-vs-clear discipline as `ic-brief-format/template.md` describes — clear in evidence records, defanged in any prose that crosses team boundaries.

The C2 host pattern across cases is what enables anticipatory-block rule synthesis (via `bl consult --synthesize-defense`). Two evidence records from different hosts citing the same callback hostname is the seed for an `@pmFromFile` block list shipped via the manifest (see `defense-synthesis/modsec-patterns.md` § anticipatory-block pattern).

<!-- public-source authored — extend with operator-specific addenda below -->
