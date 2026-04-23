# apf-grammar — deny_hosts.rules patterns for campaign IOCs

Loaded by the router on every synthesizer call that targets APF when the capability map includes C2 callback IOCs. Pairs with `basics.md` for the APF grammar floor; this file is the lookup of *which deny patterns the synthesizer emits for campaign IOCs* and *how those patterns propagate across a fleet via the import-file mechanism*.

Upstream project: https://github.com/rfxn/advanced-policy-firewall (GPL v2). Field grammar and command reference sourced from the APF README and `apf(8)` man page; fail2ban integration shape sourced from fail2ban `action.d/` documentation (`fail2ban.org/wiki/index.php/Actions`). Rule patterns below are composable against the grammar in `basics.md:30-71`.

---

## deny_hosts.rules entries for campaign IOCs

The field grammar from `basics.md:36-55`: `[protocol:flag:direction]:[port]:[address]`. A campaign IOC block pins protocol + direction + port + address all at once so adjacent legitimate traffic is not caught.

Typical synthesizer-emitted entries for an APSB25-94-class campaign:

```
# {desc: PolyShell C2 callback destination — APSB25-94 campaign}
# d:2026-04-22 s:synth e:2026-07-22
tcp:out:d=443:203.0.113.17

# {desc: PolyShell exfil endpoint — credential harvester output}
# d:2026-04-22 s:synth e:2026-07-22
tcp:out:d=443:198.51.100.42

# {desc: initial-access source IP — APSB25-94 probe}
# d:2026-04-22 s:hunter-webshell-php e:2026-05-22
tcp:in:d=80:203.0.113.99
tcp:in:d=443:203.0.113.99
```

Tag conventions follow `basics.md:57-71`. The synthesizer fills all four tag fields on every emitted entry:

- `desc:` — one-line description naming the IOC class and the campaign.
- `d:` — ISO-8601 date. Always the date of emission, not the date the evidence was first seen; the case file carries the evidence date separately.
- `s:` — source. Synthesizer-emitted entries use `s:synth`. Hunter-emitted direct blocks use `s:hunter-<name>`. Case-linked blocks add `s:case-<id>`.
- `e:` — expiration date. APF does not auto-prune (`basics.md:69`); the expiration is read by the operator cron that walks the rules file. Default horizon for campaign IOCs is 90 days; shorter for low-confidence hunters.

Egress destinations target TCP ports 80, 443, 8080, and 8443 — the common attacker-controlled HTTP(S) listeners. UDP egress blocks are rare in this class; PolyShell-family callbacks are HTTP.

---

## Shared import-file blocklist

The `import:` directive (`basics.md:122-130`) pulls in a separately-managed rules file at APF-restart time. Fleet-wide IOC propagation uses this.

Synthesizer emit pattern:

```
# /etc/apf/import/campaign-YYYYMMDD.rules
# Fleet-wide blocks for APSB25-94 campaign, generated 2026-04-22
# Fields follow deny_hosts.rules grammar (basics.md:36-55)

# {desc: PolyShell C2 callback — multi-host attribution}
# d:2026-04-22 s:synth-case-<id>
tcp:out:d=443:203.0.113.17

# {desc: Initial-access probe source IP}
# d:2026-04-22 s:synth-case-<id>
tcp:in:d=443:203.0.113.99
```

Deploy sequence across the fleet:

1. Synthesizer writes the import file to a shared location (object store, config-management source-of-truth).
2. Per-host config-management agent pulls the file into `/etc/apf/import/` on every host.
3. `/etc/apf/deny_hosts.rules` includes the import directive: `import:/etc/apf/import/campaign-YYYYMMDD.rules` on the first line (or any operator-chosen anchor position).
4. `apf -r` runs on every host to rebuild the ruleset with the new import.

A typical fleet-wide deploy on a shared-hosting platform takes under 2 minutes end-to-end when the config-management fan-out and the APF restart are both automated. `template.md:161-162` calls out this deploy latency as a routine operational metric on incident briefs.

---

## fail2ban integration

fail2ban emits block commands via `action.d/` scripts. The APF integration shape:

```ini
# /etc/fail2ban/action.d/apf-block.conf
[Definition]
actionstart =
actionstop =
actioncheck =
actionban = /usr/local/sbin/apf -d <ip> "{apf-ban jail=<name>}"
actionunban = /usr/local/sbin/apf -u <ip>
```

The `actionban` command calls `apf -d <ip> [comment]` per `basics.md:78`. The comment string encodes the fail2ban jail name so the downstream audit path can attribute the block back to the specific fail2ban filter that fired.

Jail definitions reference the action:

```ini
# /etc/fail2ban/jail.d/magento-admin.conf
[magento-admin]
enabled = true
filter = magento-admin
action = apf-block[name=magento-admin]
logpath = /var/log/apache2/domlogs/*.log
maxretry = 10
findtime = 300
bantime = 3600
```

Caveats when RAB is also active (`basics.md:25-27`): RAB-inserted blocks carry an `apf -t <minutes>` shape from the reactive subsystem, and fail2ban-inserted blocks use the persistent `apf -d`. Both coexist fine; the operator reading the rules file should expect two distinct emit shapes with different tag vocabularies.

---

## Temp-ban vs persistent

Two commands, two lifetimes, two use cases.

- **`apf -t <minutes> <ip>`** — temporary block. Stored in a separate file from the persistent deny list (`basics.md:83-85`). Right for noisy, low-confidence signals where the source IP is likely to be an innocent proxy or a dynamic residential IP that will rotate shortly. Typical durations: 15-60 minutes for rate-limit hits; 24 hours (1440 minutes) for LFD-driven failed-auth bursts.
- **`apf -d <ip> [comment]`** — persistent block. Written to `deny_hosts.rules`. Right for high-confidence campaign attribution where the source is attacker-controlled infrastructure (bulletproof hosting, confirmed C2 endpoint, malware distribution node). Lives until the operator removes it or the expiration cron walks it.

Decision rule for the synthesizer: if the capability map names the IP in `observed` with source-refs to at least two independent evidence rows (e.g., access log hit + multi-host correlation), emit persistent. If only one evidence row supports, emit temporary at 1440 minutes and flag for operator review on the brief's Remaining-Risk section.

---

## Manifest-driven inserts

The synthesizer's output contract carries APF entries as manifest rows (`ir-playbook/case-lifecycle.md` evidence discipline). `bl-apply` reads these and emits the corresponding `apf -d` commands with the synthesizer-composed comment string.

Emit format:

```json
{
  "layer": "apf",
  "action": "deny",
  "target": "203.0.113.17",
  "direction": "out",
  "port": 443,
  "protocol": "tcp",
  "tags": {
    "desc": "PolyShell C2 callback — APSB25-94 campaign",
    "d": "2026-04-22",
    "s": "synth",
    "e": "2026-07-22"
  },
  "case_id": "case-2026-04-22-001"
}
```

The `s:` tag carries the source provenance; `synth` is the floor. Hunter-driven entries use `s:hunter-<name>`. Case-linked entries add `s:case-<id>` so later operator queries against the rules file can filter to one case's emissions.

Tag vocabulary extends `basics.md:67-71` with three synthesizer-specific values: `s:synth`, `s:hunter-<name>`, `s:case-<id>`. Every synth-emitted entry carries all three where applicable; every operator-emitted entry carries at least `s:manual` plus a ticket reference.

---

## Validation

The synthesizer never emits directly to the live ruleset. Emit path:

1. Write the proposed entry to a temp rules file.
2. Run `apf -s` against the temp file (`basics.md:162-166`) — syntax check, no apply. This is the APF equivalent of `apachectl configtest` for ModSec rules.
3. On pass, the manifest row carries `confidence: high` and `bl-apply` may commit directly.
4. On fail, the row downgrades to `suggested_rules[]` with the parse error attached. `bl-apply` does not commit these; operator review is required.

The downgrade path is mandatory — silent failure on a deny-rules emit would leak attacker-controlled traffic past the blocklist. The failure mode is "entry visible to operator, not yet applied" rather than "entry silently dropped".

<!-- public-source authored — extend with operator-specific addenda below -->
