# apf-grammar — Advanced Policy Firewall configuration reference

Loaded by the router on every `bl consult --synthesize-defense` call that targets APF. APF is an iptables/netfilter front-end with a configuration model built around stateful trust lists, port catalogs, and a daily reactive cycle. This file is the directive and rules-file reference; pair with `defense-synthesis/modsec-patterns.md` for the network-layer companion to ModSec rule synthesis. Upstream project: https://github.com/rfxn/advanced-policy-firewall (GPL v2).

## conf.apf — the top-level configuration

`/etc/apf/conf.apf` is the master configuration. Every directive is `KEY="value"` shell syntax — APF sources it with `bash`, so quoting matters and inline comments use `#`.

The directives that bind operational behavior:

- `DEVEL_MODE="0"` — when set to `1`, APF flushes its rules five minutes after start via a cron entry. Production must be `0`. A host where this is `1` is in development mode and rules will not survive past five minutes after the next start; surface this in triage as a misconfiguration before treating any APF rule as enforced.
- `IFACE_IN="eth0"` — interface for inbound rule application. Multi-interface hosts list comma-separated.
- `IFACE_OUT="eth0"` — interface for outbound rule application.
- `IFACE_TRUSTED=""` — interfaces to bypass entirely (loopback equivalents for trusted internal networks).
- `IG_TCP_CPORTS="22,80,443"` — ingress TCP common ports, comma-separated. The ports the world is allowed to connect to.
- `IG_UDP_CPORTS=""` — ingress UDP common ports.
- `EG_TCP_CPORTS="21,22,25,53,80,443"` — egress TCP common ports. Restrictive egress is the highest-leverage hardening; the default is permissive.
- `EG_UDP_CPORTS="20,21,53"` — egress UDP common ports.
- `EGF="0"` — egress filtering master switch. `0` allows all outbound; `1` enforces `EG_*_CPORTS`. A host with `EGF="0"` has no outbound enforcement regardless of the egress port catalog.
- `BLK_PRVNET="1"` — block private network address space on public interfaces. Defends against spoofed RFC1918 sources.
- `BLK_RESNET="1"` — block reserved/bogon address space.
- `BLK_IT="1"` — block invalid TCP states (out-of-order SYN/ACK combinations).
- `BLK_PRIVATE_RT="1"` — drop traffic to private/reserved networks on outbound (prevents the host from initiating connections to RFC1918 unless explicitly trusted).
- `BLK_FRAGMENTS="1"` — drop fragmented packets that cannot be reassembled cleanly.
- `RAB="1"` — Reactive Address Blocking subsystem enable. `1` lets APF accept blocks from external triggers (LFD, fail2ban, custom hooks).
- `RAB_TIMER="300"` — seconds an entry inserted by the reactive subsystem persists before automatic removal. Pair with `RAB_HITCOUNT` for retry-after-expire dynamics.
- `RAB_HITCOUNT="0"` — counter for repeat-offender escalation. `0` disables; integer enables.
- `LOG_DROP="0"` — log dropped packets. Useful during incident response, expensive at steady state because every dropped probe lands in `kern.log`.

## allow_hosts.rules and deny_hosts.rules

The two trust lists. APF reads both on every `apf -r` (restart) and applies them in order: deny first, then allow. An entry in `allow_hosts.rules` overrides any matching deny.

Format per line:

```
[protocol:flag:direction]:[port]:[address]
```

Examples:

```
198.51.100.42                            # bare IP — allow/deny all traffic, all ports, both directions
tcp:in:d=22:198.51.100.0/24              # CIDR — TCP inbound to port 22 from a /24
tcp:out:d=25:0/0                         # block outbound SMTP to anywhere
udp:in:d=53:203.0.113.5                  # UDP inbound from a single host on port 53
```

Field grammar:

- **protocol** — `tcp`, `udp`, `icmp`, or absent (defaults to all).
- **flag** — `in` or `out`. Required when a direction-restricted rule is intended; absent applies both directions.
- **d=<port>** — destination port. Use `s=<port>` for source port. Port ranges as `d=8000_8100`.
- **address** — IPv4, IPv6, or CIDR. Bare hostname is permitted but resolved at rule-load time (not at packet-evaluation time), so DNS changes do not propagate without an APF restart.

Comment + tag conventions in the rules files:

```
# {desc: Acme monitoring probe}
# d:2026-04-22 s:LFD e:2026-05-22
198.51.100.42
```

The four tags carry operational metadata:

- `desc:` — free-text description; what this entry is for.
- `d:` — date inserted (ISO-8601).
- `s:` — source of the insertion (`LFD`, `manual`, `<curator-verb-name>` such as `observe.log_apache`, customer ticket id).
- `e:` — expiration date. APF does not auto-prune on this tag; an operator cron walks the file and removes expired entries. Without the cron, the tag is documentation only.

These tags are convention, not parsed by APF itself, but downstream tooling (curator reasoning, audit reports) keys on them. Synthesis-emitted entries should always carry all four.

## Trust-system commands (ad-hoc inserts)

Three commands handle live trust changes without editing files by hand:

- `apf -a <ip-or-cidr> [comment]` — add to allow_hosts.rules. Persists across restarts.
- `apf -d <ip-or-cidr> [comment]` — add to deny_hosts.rules. Persists across restarts.
- `apf -u <ip-or-cidr>` — remove a matching entry from either list.

The `-a`/`-d`/`-u` commands write into the rules files at runtime; concurrent edits by hand can lose changes if the file is being rewritten. Synthesis-generated additions should always go through `apf -a`/`apf -d` rather than direct file writes.

For temporary blocks driven by reactive triggers (rate-limit hits, brute-force detection):

- `apf -t <minutes> <ip>` — temporary block for a fixed duration. Stored in a separate file from the persistent deny list.

## ICMP control

Three directives govern ICMP behavior:

- `HELPER_ICMP_ECHO="1"` — accept ICMP echo (ping) inbound.
- `HELPER_ICMP_TYPES="3,4,11,12,30"` — additional ICMP types to accept inbound. Defaults cover destination-unreachable, source-quench, time-exceeded, parameter-problem, and traceroute. Stripping these breaks PMTUD and traceroute diagnostics.
- `HELPER_ICMP_OUT="1"` — allow outbound ICMP. Required for the host to issue ping or traceroute.

Blocking ICMP echo is operator preference; the diagnostic ICMP types should not be blocked because PMTUD failure makes large-MTU TCP connections silently stall.

## SYN flood and connection-rate mitigations

`SYSCTL_SYN="1"` enables a set of kernel parameters tuned for SYN-flood resistance:

- `net.ipv4.tcp_syncookies=1`
- `net.ipv4.tcp_max_syn_backlog=4096`
- `net.ipv4.tcp_synack_retries=3`
- a few related `net.netfilter.nf_conntrack_*` adjustments.

The exact set varies by APF version. Applying these requires kernel support for SYN cookies (standard on every Linux kernel since the 2.6 era) and pushes some memory pressure to conntrack tables. Worth enabling on every public-facing host.

`SYSCTL_TCP="1"` enables a broader TCP-hardening set (window scaling tuning, RFC1337 mitigation, `tcp_timestamps` adjustments). Lower-impact than `SYSCTL_SYN` and safe on most workloads.

## Reactive mode and LFD interaction

APF integrates with ConfigServer's Login Failure Daemon (LFD, part of CSF) and with custom monitors via the `RAB` (Reactive Address Blocking) subsystem. When a monitor detects abuse (failed-auth bursts, scan signatures), it calls `apf -d <ip>` or invokes the RAB hook directly; APF inserts the block and the RAB timer auto-prunes the entry after `RAB_TIMER` seconds.

For LFD specifically:

- LFD detects failed authentications across SSH, FTP, mail (POP/IMAP/SMTP), and web (cPanel, Webmail, Magento admin if a custom log pattern is configured).
- LFD calls APF to insert the block; APF logs the insertion with `s:LFD` if the integration is configured to tag it.
- The `RAB_TIMER` setting determines how long an LFD-inserted block lives. A short timer (300s) is useful for noisy false positives; a long timer (86400s) is appropriate for high-confidence detections.

For custom curator-driven blocks (the `bl defend firewall` step path), the integration shape is the same: emit `apf -d <ip> "{tag block}"` with a descriptive comment and rely on APF's persistence to keep the block across restarts.

## import directive

```
import:/etc/apf/import/cdn-allowlist.rules
```

The `import:` directive at the top of `allow_hosts.rules` or `deny_hosts.rules` pulls in another file at rule-load time. Use to share lists across hosts (deploy a maintained CDN allowlist as `cdn-allowlist.rules`, import it everywhere). The imported file uses the same line grammar as the host file.

Imported files do not auto-refresh; an APF restart is required to pick up changes. A cron that calls `apf -r` after pulling updated import files closes the loop.

## When to use APF vs iptables direct vs ModSec

APF, ModSec, and direct iptables/nftables are not interchangeable; each has the right scope.

- **APF** — IP/CIDR/port-level enforcement. Trust lists, blocklists, egress filtering, ICMP control. Use when the decision is "permit/deny this address on this port". Cheap, fast, no application context.
- **iptables / nftables direct** — when APF's grammar does not express the rule. Examples: connection-tracking rules with custom `ct state` matches, bandwidth shaping via `tc`, `string` module matches against packet payload, NAT/redirection. Direct rules survive APF restarts only if they are placed in `/etc/apf/postroute.rules` (APF re-applies these after its own rules) or `/etc/apf/preroute.rules` (applied before APF's own rules).
- **ModSec** — application-layer, content-aware. URL patterns, body inspection, header matching, response shaping. Use when the decision needs to read the HTTP request body or response. See `modsec-grammar/rules-101.md`.

A typical layered defense for a webshell-class incident:

1. APF deny on known-bad source IPs (cheap, drops at the network layer).
2. ModSec rule on the URL evasion pattern (catches the next adversary IP that hits the same vulnerability).
3. APF egress filter blocking the C2 callback destination (defense-in-depth if the ModSec rule misses).

Generating the right defense at the right layer is the synthesis call's responsibility; this file gives the grammar so the rule is syntactically valid when emitted.

## /etc/apf/postroute.rules and preroute.rules

Two escape hatches for rules that APF's directives do not express directly. Both files take raw `iptables` command lines (one per line, without the leading `iptables`):

```
# postroute.rules — applied after APF builds its ruleset
-I INPUT -p tcp --dport 9418 -j ACCEPT     # git protocol
-I OUTPUT -p tcp --dport 6667 -j REJECT    # IRC egress
```

`preroute.rules` runs before APF builds the standard set; useful for inserting rules that need to short-circuit APF's own logging or block decisions. `postroute.rules` runs after; useful for layering additional restrictions on top of APF's decisions.

Synthesis-emitted rules should prefer the directive layer (`conf.apf`, `allow_hosts.rules`, `deny_hosts.rules`) when expressible there, and fall back to `postroute.rules` only when the rule cannot be written in APF's native grammar.

## Validation

`apf -s` reloads the configuration without applying. `apf -r` restarts (apply). `apf -f` flushes all rules (returns the host to no-firewall state — never use during incident response).

The synthesis call should treat `apf -s` as the equivalent of `apachectl configtest` for ModSec: a successful syntax check before commit, an emit-as-`suggested_rules`-only on failure with the parse error captured for operator review.

<!-- public-source authored — extend with operator-specific addenda below -->
