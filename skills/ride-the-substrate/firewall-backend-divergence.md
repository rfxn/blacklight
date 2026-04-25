# firewall-backend-divergence — six backends, one intent

Loaded by the router when `defend firewall` is pending, or when the substrate report flags multiple firewall backends installed on the same host. This file is the lookup of which firewall command this host wants and the trap that several backends can coexist where only one is the live ruleset. Pairs with `enumeration-before-action.md` (the why) and gates `defense-synthesis/firewall-rules.md` (the rule content this skill binds to a backend).

## The block-an-IP problem, six ways

A C2 callback IP needs blocking. The defensive intent is the same on every Linux host since 1998: drop one /32. The command that effects it is six different commands depending on substrate.

```
apf -d <ip>                                              # APF (rfxn)
csf -d <ip>                                              # ConfigServer Security & Firewall
iptables -I INPUT -s <ip> -j DROP                        # iptables-direct
nft add rule inet filter input ip saddr <ip> drop        # nftables-direct
ufw deny from <ip>                                       # Uncomplicated Firewall
firewall-cmd --add-rich-rule='rule family=ipv4 source address=<ip> reject'   # firewalld
```

Six commands; one intent. The substrate read picks which command this host actually wants; `defense-synthesis/firewall-rules.md` carries the CDN-overlap safelist that applies before any of them.

## Three rules that bind every `defend firewall` step

**1. The "active" firewall is whichever frontend last wrote to the kernel netfilter tables.** Two backends installed both claim authority on `command -v`. The kernel honours whichever wrote last; the next reload from either flushes the other's rules. Common coexistence shapes:

- **APF + firewalld on RHEL/Rocky.** Migration from CentOS 6/7 to Rocky 9 frequently leaves both installed; firewalld is enabled by default, APF was carried over. `systemctl is-active firewalld` and `apf -s` both return success.
- **CSF + firewalld** on cPanel hosts where firewalld was not deliberately disabled during cPanel install.
- **ufw + iptables-direct** on Debian/Ubuntu where an operator hand-added `iptables -I` lines outside ufw's awareness; ufw's `iptables-restore` on next reload flushes them.
- **iptables + nftables coexistence** on modern kernels. Both can write to netfilter; evaluation depends on which utility is installed and whether `iptables-nft` (the nftables-backed iptables shim) is in use. Upstream wiki: `https://wiki.nftables.org/wiki-nftables/index.php/Troubleshooting#iptables_and_nftables_are_both_active`.

The `defend firewall` step must name which backend it wrote against in `actions/applied/<id>.yaml`. The substrate read does not just enumerate `installed=true` — it observes `live=true` per backend by reading kernel-table provenance (`iptables -S`, `nft list ruleset`, `firewall-cmd --list-all`, `ufw status verbose`, plus backend status under `/etc/apf/internals/` or `/etc/csf/`).

**2. Direct iptables / nftables blocks do not persist by default.** A curator that emits an `iptables -I` step against a host without `iptables-services` (RHEL) or `iptables-persistent` / `netfilter-persistent` (Debian) loses the block on next reboot. Skill rule: if backend is iptables-direct or nftables-direct AND no persistence hook is configured, append a persistence step before apply. See `iptables(8)`, `nft(8)`, and `https://packages.debian.org/iptables-persistent`.

Persistence-hook detection per backend:

- iptables-direct: `systemctl is-enabled iptables.service` or `dpkg -l iptables-persistent`.
- nftables-direct: `systemctl is-enabled nftables.service` plus `/etc/nftables.conf` materialized.
- APF (`https://github.com/rfxn/advanced-policy-firewall`): `/etc/apf/deny_hosts.rules` — `apf -d` writes, `apf -r` reapplies.
- CSF (`https://configserver.com/cp/csf.html`): `/etc/csf/csf.deny`.
- ufw: persists by design.
- firewalld: `--permanent` on `firewall-cmd`; without it, runtime-only and lost on `firewall-cmd --reload`.

**3. CDN-overlap is the per-backend gate that does not change shape.** The CDN safelist (Cloudflare ASN, Akamai, Fastly) applies before backend selection — a `/32` block of a Cloudflare IP appears to the host as a block of every site Cloudflare proxies. The safelist content lives in `defense-synthesis/firewall-rules.md` §CDN safe-list discipline; this skill binds the gate to all six backends. Every `defend firewall` step runs the CDN-overlap check first, regardless of which command will drop the rule.

## Failure mode named

A curator emits `apf -d <ip>` on a Rocky 9 host where APF was installed during CentOS 7 migration but the live blocker is `firewalld`. APF writes to `/etc/apf/deny_hosts.rules` and runs its reload. APF's iptables chain is *not* in firewalld's effective ruleset because firewalld owns the live tables and does not read APF's rule file. The IP continues to reach the host. The case ledger shows the rule applied; the actual block is absent.

Mitigation: enumerate the *live* backend by kernel-table provenance (`iptables -S | head`, `firewall-cmd --state`), not the *installed* backend (`command -v apf`). The substrate report emits `firewall.installed=[apf,firewalld]` and `firewall.live=firewalld`, and `defend firewall` routes to firewalld's command grammar even when `apf` is the muscle-memory choice.

## Cross-references

- `enumeration-before-action.md` — bundle spine, firewall-specialized here.
- `defense-synthesis/firewall-rules.md` — downstream rule content (CDN safelist, `/32`-vs-`/24`) gated by backend.
- `apf-grammar/basics.md`, `apf-grammar/deny-patterns.md` — APF-specific grammar when `firewall.live=apf`.

<!-- public-source authored — extend with operator-specific addenda below -->
