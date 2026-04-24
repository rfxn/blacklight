# defense-synthesis — firewall rules

Loaded by the router when a case has clustered network-layer indicators (a tight IP set, a coordinated callback domain on shared hosts, or a `defend.firewall` step proposal in `bl-case/CASE-<id>/pending/`). Complements `skills/ioc-aggregation/ip-clustering.md` — that file tells the curator how to cluster IPs into actor infrastructure; this file tells it how to turn the cluster into applied rules without taking down the customer's site.

Every rule this file describes lands in `bl-case/CASE-<id>/actions/pending/<act-id>.yaml` via the `synthesize_defense` custom tool (DESIGN.md §12.2), runs the ASN-safelist preflight inside the curator sandbox, and promotes to `actions/applied/` only after operator `bl run --yes`. The curator does not SSH into hosts to install blocks — it proposes typed actions the wrapper executes under the tier gate.

---

## Scenario

APSB25-94 post-exploit callback traffic is hitting a hosting fleet. The curator has twelve IPs from `ip-clustering.md` analysis — four `/24`-colocated in a Contabo block, five on DigitalOcean droplets in two `/24`s, three scattered Hetzner residentials. The operator has six affected customers on shared hosting and sixty more on the same Apache fleet whose traffic is served through Cloudflare. The request: deploy blocks across the fleet without severing legitimate traffic for the un-affected sixty, retire the rules automatically once the incident cools, and leave a breadcrumb for the next responder to understand why each block exists.

Wrong move: one wide `iptables -A INPUT -j DROP` on a `/16` that contains a CDN origin-pull range. Cascading outage within three minutes.

Right move: per-IP `/32` blocks with per-rule retire hints, a CDN safelist sweep before each apply, and a comment tag tying every rule back to the case. The sections below are the rules the curator applies to author that move.

---

## Backend semantics

blacklight supports four firewall backends. Each ships different syntax; all converge on the same semantic: drop packets from `<source>` to `<destination-port>`, optionally with a comment and a rate bucket. The wrapper auto-detects backend on `bl observe firewall` (DESIGN.md §5.1) and the curator picks the matching syntax in `synthesize_defense`.

| Backend | Deny syntax | Safe-list (skip) syntax | Reload command |
|---------|-------------|-------------------------|----------------|
| APF | `apf -d <ip> "<comment>"` | `apf -a <ip> "<comment>"` | `apf -r` |
| CSF | `csf -d <ip> "<comment>"` | `csf -a <ip> "<comment>"` | `csf -r` |
| iptables | `iptables -A INPUT -s <cidr> -p tcp -m multiport --dports 80,443 -j DROP -m comment --comment "<tag>"` | `iptables -I INPUT -s <cidr> -j ACCEPT -m comment --comment "<tag>"` | `iptables-save > /etc/iptables/rules.v4` |
| nftables | `nft add rule inet filter input ip saddr <cidr> tcp dport { 80, 443 } drop comment "<tag>"` | `nft insert rule inet filter input position 0 ip saddr <cidr> accept comment "<tag>"` | `nft -s list ruleset > /etc/nftables.conf` |

Key semantic unlocks:

- **APF and CSF sit on top of iptables/nftables.** Applying via APF/CSF is preferred on hosts where they're installed because they carry their own allow-list precedence and reload discipline. Skipping straight to `iptables -A` on an APF/CSF host fights the wrapper's tooling — rules get stripped on the next `apf -r`.
- **Deny-rule ordering matters on iptables/nftables.** A safelist entry MUST precede the deny-rule in the chain (`-I INPUT` for safelists, `-A INPUT` for denies). An `-A`-appended safelist after an already-applied `-A` deny never fires.
- **`multiport` is a portability floor.** `-p tcp -m multiport --dports 80,443` is supported on every iptables build blacklight targets (CentOS 6+). Newer builds support `--dports` directly on some modules; avoid those for fleet-homogeneous rules.
- **Comment discipline is load-bearing.** Every rule carries a case tag + retire-by date in the comment. `iptables -S | grep bl-case-CASE-2026-` is the "what's still mine" query the retire sweep runs.

Public reference: https://www.rfxn.com/projects/advanced-policy-firewall/ (APF command reference), https://netfilter.org/documentation/ (iptables/nftables canonical docs).

---

## Rate-limit vs hard-drop

The apparent-reasonable move on a beacon C2 callback is a rate-limit — "drop if more than N requests per minute" — because it leaves the adversary's connections mostly working and gives the responder time to react. Against PolyShell-class infrastructure this is wrong.

Sansec's public research (https://sansec.io/research/magento-polyshell) documented a ~21-second beacon cadence on observed PolyShell deployments. A 60-requests-per-minute rate-limit is ineffective — the adversary is already beneath the threshold. A 5-requests-per-minute rate-limit catches the beacon but also catches legitimate Cloudflare origin-pull retries during cache-fill windows and RSS feed readers on news sites. The rate-limit band that cuts the adversary without cutting customers does not exist for low-cadence C2.

Default for blacklight: **hard-drop per observed actor IP**. Rate-limit is a `suggested`-tier override for the specific case where:

1. The IP falls on a high-priority customer ASN (the operator has whitelisted it explicitly at workspace scope).
2. Dropping fully would sever a legitimate traffic shape (e.g., an affiliate network's web-crawler pool that is also being spoofed by the adversary).
3. The curator has authored an explicit rate-band with evidence (a histogram from `observe.log_apache` showing legitimate and adversary traffic separable by request rate).

When rate-limit is chosen, it lands as a chained iptables `limit` match or an APF `--port` specific rule — not a blanket drop — and the authoring rule in `docs/action-tiers.md §4` rule 2 downgrades the tier from `auto` to `suggested` so the operator confirms the band.

---

## CDN safe-list discipline

The most expensive mistake a responder can make on a shared-hosting fleet is blocking a CDN origin-pull range. Cloudflare's `103.31.4.0/22`, Akamai's `23.0.0.0/12`, Fastly's `151.101.0.0/16`, Sucuri's `192.88.134.0/23` — all route real customer traffic through origin hosts. A block on any of them cascades a full-site outage within the CDN's cache-TTL window (minutes).

The curator runs a CDN safelist preflight **before every `defend.firewall` proposal** with `action_tier: auto`. The preflight:

1. Reads the cached safelist from `/var/lib/bl/state/cdn-safelist.json` (operator-local, 24h refresh per `docs/case-layout.md`).
2. Checks the candidate IP against every CDN range.
3. On match, downgrades `action_tier` from `auto` to `suggested` and writes the CDN provider name into `reasoning` so the operator sees the collision.
4. On zero match, `auto` stands and the wrapper's 15-minute veto window carries the rule.

Authoritative sources the safelist pulls from (curator refreshes once per 24h):

- https://www.cloudflare.com/ips/ (Cloudflare IPv4 + IPv6)
- https://www.akamai.com/us/en/support/ip-addresses.jsp (Akamai edge)
- https://api.fastly.com/public-ip-list (Fastly origin-pull)
- Sucuri static ranges (https://docs.sucuri.net/website-firewall/deployment/whitelisting-sucuri-waf-ip-addresses/)

ASN ranges rotate — Cloudflare has grown by a `/20` in the last eighteen months. A stale safelist that misses the `/20` is an outage waiting to happen. The 24h refresh cadence is the operator-protection floor; operators on heavy-change fleets should drop the refresh window to 4h via `/var/lib/bl/state/cdn-safelist.refresh`.

---

## Retire-hint convention

Every rule blacklight applies carries two markers in its comment: a `case-tag` pointing back to the case that authored it, and a `retire-by` ISO-date that tells the wrapper's retire sweep when to remove it.

Comment shape (iptables/nftables):

```
-m comment --comment "bl-case=CASE-2026-0007;retire-by=2026-05-24;reason=polyshell-c2"
```

Comment shape (APF/CSF):

```
apf -d 203.0.113.51 "bl-case=CASE-2026-0007 retire-by=2026-05-24 polyshell-c2"
```

Default retire-by windows by tier:

- `auto` tier: now + 7 days. Short-fuse blocks are the default for fresh evidence; the short window forces re-evaluation before the rule silently sticks around for months.
- `suggested` tier: now + 30 days. Operator-confirmed blocks carry more conviction; the longer window reflects that.
- `destructive` tier: N/A (firewall actions are never destructive — they're reversible).
- Operator-override: any value up to 365 days via `bl defend firewall <ip> --retire-in <duration>`.

`bl defend firewall --retire` sweeps every applied rule whose `retire-by` date has passed:

1. Parse iptables rules with case-tag comments (`iptables -S | grep 'bl-case='`).
2. Extract `retire-by` value.
3. If `retire-by < now`, move the rule to `bl-case/CASE-<id>/actions/retired/<act-id>.yaml` and `iptables -D` it.
4. Re-emit `iptables-save` for persistence.

The retire sweep runs as part of `bl case close` on every affected case and as a standalone sweep from cron at operator discretion. The sweep never touches non-blacklight rules (those without a `bl-case=` tag) — operator-installed blocks survive.

---

## Non-obvious rule — default `/32`, escalate to `/24` only on cross-host evidence

Operators reach for `/16` blocks when they're in a hurry. "Block the whole network; sort it out later." On shared-tenant ASNs — Contabo, Hetzner, DigitalOcean, Linode, OVH, Vultr — a `/16` block cascades an outage the operator did not intend. DigitalOcean's `178.62.0.0/16` contains customer droplets that legitimate traffic on the fleet routes through; a hasty `/16` takes all of them offline.

Rule: **default to `/32` per observed IP**. Escalate to `/24` only when ALL of:

1. Cross-host correlation confirms `/24` infrastructure — two or more distinct adversary IPs observed on the same `/24` within the case window (see `ip-clustering.md` §Target-path preferences).
2. The `/24` does not overlap any entry in the CDN safelist.
3. The `/24`'s ASN is NOT designated shared-tenant (Contabo, Hetzner, DigitalOcean, Linode, OVH, Vultr, Choopa, Contabo GmbH). For shared-tenant ASNs, `/32` holds regardless of cross-host evidence — the probability of collateral damage is too high.

Escalation to `/16` is never automatic. The curator can suggest it via `open-questions.md` but the operator must author the rule manually with `bl defend firewall <cidr> --unsafe --yes` — the `--unsafe` acknowledgment is the forcing function.

Sources for residential / shared-tenant ASN designation: operator-local `/var/lib/bl/state/asn-tenant-class.json` (curator refreshes weekly from public BGP tables). The list is operator-editable — operators with private intelligence about adversary-controlled ASN blocks can mark them for eager escalation.

---

## Failure mode — operator applies `/16` on a shared-tenant ASN

Concrete failure: an operator sees four adversary IPs all on DigitalOcean's `138.197.0.0/16` and types `bl defend firewall 138.197.0.0/16`. The wrapper's preflight triggers:

```
bl-firewall: REFUSED
  reason: target 138.197.0.0/16 is on shared-tenant ASN (DigitalOcean)
  asn: AS14061
  policy: shared-tenant ASNs require /32 per-IP blocks regardless of cross-host evidence
  escalate: bl defend firewall 138.197.0.0/16 --unsafe --yes
           (this will block all DigitalOcean droplets the fleet is transiting)
```

The rule preempts the cascade. The operator with patient cross-host signal still gets four `/32` blocks in one command; the rushed operator gets a policy-blocked prompt instead of an outage.

Observed from public research: Sansec documented APSB25-94 operators using Contabo VPS clusters for their callback infrastructure (https://sansec.io/research/magento-polyshell). Contabo is shared-tenant by policy — `/32` per observed IP, never `/24` even with three-hit cross-host correlation, unless the ASN-tenant-class file explicitly overrides.

---

## Applied example — the Scenario, fully proposed

The scenario's twelve IPs resolve under the rules above:

- **Contabo `/24` cluster (4 IPs):** `/32` each, comment `bl-case=CASE-2026-0007;retire-by=2026-04-30;reason=polyshell-c2-contabo`, backend auto-detect, tier `auto`.
- **DigitalOcean droplets (5 IPs across 2 `/24`s):** `/32` each, same comment shape with `reason=polyshell-c2-do`, tier `auto`.
- **Hetzner residentials (3 IPs):** `/32` each, `reason=polyshell-c2-hetzner`, tier `auto`.
- **CDN safelist preflight:** all twelve IPs clear (none on Cloudflare / Akamai / Fastly / Sucuri ranges).
- **Retire-by:** now + 7 days (tier `auto` default) — the operator sees a fresh retire sweep at the weekly cron boundary.

Twelve `defend.firewall` steps, each emitted via `report_step` with tier `auto` and the comment-tag population rules above. The wrapper applies, writes twelve entries to `bl-case/CASE-2026-0007/actions/applied/`, posts a Slack webhook, and sweeps on T+7.

If any of the twelve had been on Cloudflare origin-pull, it would have been downgraded to `suggested` with the CDN provider named in `reasoning` — the operator's confirmation step makes the CDN collision explicit.

---

## What this file is *not*

- Not a guide to writing iptables from scratch. See https://netfilter.org/documentation/ for canonical iptables/nftables docs.
- Not a replacement for the operator's own traffic allow-lists. blacklight blocks; it does not manage the full allowlist surface.
- Not an exhaustive CDN safelist. The list above rotates; the `/var/lib/bl/state/cdn-safelist.json` refresh is the runtime source of truth.
