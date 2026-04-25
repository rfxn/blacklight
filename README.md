# blacklight

*Attackers have agents. Defenders still have grep. blacklight is the counter.*

At 03:42 UTC on a Saturday, a hosting provider's on-call engineer gets the APSB25-94
advisory: Magento stores are actively backdoored via a double-extension webshell hidden
in the media cache. Eight hours later the team has run grep, find, modsec log scrapes,
ClamAV scans, APF drops, and crontab audits across forty hosts — by hand. blacklight
collapses that arc into agent-directed motions on the same Linux substrate the defender
already runs. No platform buy-in. No fleet migration. No analyst retraining. The curator
agent holds the case across days; the operator runs the steps it prescribes.

## Install

One-liner (curl-pipe-bash safe):

```bash
curl -fsSL https://raw.githubusercontent.com/rfxn/blacklight/main/install.sh | sudo bash
export ANTHROPIC_API_KEY="sk-ant-..."
bl setup
```

Requires: bash 4.1+, curl, jq. Tested on Debian 12, Ubuntu 20.04 / 22.04 / 24.04,
CentOS 7, Rocky 8 / 9.

`bl setup` provisions a Managed Agent session in the operator's Anthropic workspace
(one-time per workspace). Subsequent `bl` invocations reuse that session.

## Try it

Scenario: APSB25-94 advisory drops. One host is suspected. The operator opens a case,
collects evidence, and applies a ModSec rule — all in under ten minutes.

**Step 1 — collect Apache logs and check the filesystem:**

```bash
bl observe apache --path /var/log/apache2/access.log --since 2026-03-22T00:00:00Z
bl observe fs --path /var/www/html --ext php --since 2026-03-20T00:00:00Z
```

```
blacklight: obs-0001 apache log sweep complete — 3 findings
  url_evasion  203.0.113.42  GET /pub/media/catalog/product/.cache/a.php/banner.jpg  (14:22:07Z)
  url_evasion  203.0.113.42  POST /pub/media/catalog/product/.cache/a.php  (14:23:51Z)
  url_evasion  203.0.113.42  GET /pub/media/catalog/product/.cache/a.php/logo.gif  (14:31:09Z)

blacklight: obs-0002 fs scan complete — 1 finding
  unusual_php_path  /var/www/html/pub/media/catalog/product/.cache/a.php  (mtime 2026-03-21T23:58Z)
```

**Step 2 — open a case and consult the curator:**

```bash
bl consult --new --trigger "APSB25-94 double-extension webshell — obs-0001 obs-0002"
```

```
blacklight: CASE-2026-0001 opened
blacklight: curator session wake enqueued
blacklight: pending step s-0001 ready
  verb:    observe.modsec
  tier:    read-only
  reason:  confirm rule coverage before prescribing defensive payload
Run: bl run s-0001
```

**Step 3 — execute the curator-prescribed step:**

```bash
bl run s-0001
```

```
blacklight: s-0001 observe.modsec [read-only] — running
  modsec rule hit on REQUEST_URI @rx /\.php/[^/]+\.(jpg|png|gif)  id:920450
blacklight: result written to case memstore
blacklight: pending step s-0043 ready
  verb:    defend.modsec
  tier:    suggested
  reason:  obs-0001 + obs-0002 + s-0001 confirm polyshell staging pattern
  diff:    +SecRule REQUEST_FILENAME "@rx \.php/[^/]+\.(jpg|png|gif)$" \
               "id:941999,phase:2,deny,log,msg:'polyshell double-ext staging'"
Confirm and apply? [y/N]
```

**Step 4 — apply the ModSec rule:**

```bash
bl run s-0043 --yes
```

```
blacklight: s-0043 defend.modsec [suggested] — applying
  apachectl -t ... OK
  rule installed: /etc/apache2/mods-enabled/bl-CASE-2026-0001-941999.conf
  apache2ctl graceful ... OK
blacklight: ledger event defend_applied written
blacklight: CASE-2026-0001 defense step complete
```

## Why Managed Agents

The curator is an Anthropic Managed Agent — not a stateless API call wrapped in a prompt.
On first `bl setup`, blacklight creates a named agent (`bl-curator`), a tool environment
(`bl-curator-env`), and two memory stores (`bl-skills`, `bl-case`). These IDs are
persisted to `/var/lib/bl/state/` and reused on every subsequent invocation. The
practical consequence: an operator runs `bl consult` on Monday morning to open a case,
collects more evidence Tuesday afternoon via `bl observe`, and calls `bl consult` again —
the curator already holds the case hypothesis, the prior evidence, and the pending steps.
There is no re-prompt, no context reconstruction, no "please remember what we discussed."
Case state accumulates across sim-days because it is stored in the agent's memory store,
not in the operator's shell session. This is architecture, not a feature flag. Concretely:
the agent ID, environment ID, and both memstore IDs are single-valued entries in
`/var/lib/bl/state/` that `bl_preflight` validates on every run. See `DESIGN.md` §8
for the full setup-and-reuse contract.

## Why Opus 4.7 + 1M context

Post-incident reconstruction requires the whole evidence bundle in a single reasoning
pass. A realistic APSB25-94-shaped case accumulates Apache access logs, ModSec audit
entries, filesystem mtime clusters, crontab diffs, and process snapshots — routinely
250,000 to 400,000 tokens of raw evidence before the curator has authored a single
hypothesis. Chunking that evidence across multiple calls destroys the cross-stream
correlation that distinguishes signal from noise: the webshell URL in the access log,
the double-extension filesystem path, and the injected cron entry are only causally
connected when the curator can see all three at once. The 1M context window makes that
possible without compromise. Opus 4.7 with adaptive thinking provides the reasoning
depth needed for forensic synthesis — distinguishing a staging artifact from a false
positive requires the model to apply knowledge from ModSecurity grammar, Magento path
conventions, and attacker TTPs simultaneously. The `exhibits/fleet-01/` directory in
this repository contains a worked APSB25-94-shaped case that exercises the full bundle
shape, reconstructed entirely from the public Adobe security advisory.

## Skills architecture

Each defensive motion ships as a skill bundle: a directory of ~20 markdown files
authored from public sources — Adobe security advisories, ModSecurity grammar
documentation, Magento developer docs, Linux hosting-stack documentation, public
YARA rule repositories. The curator agent loads these skill bundles as read-only
memory store content at session creation via `bl setup --sync`. The operator never
touches the skill files at runtime; the curator reads them, applies them to the
evidence, and prescribes steps. New skills can be authored and synced without
modifying `bl` source. The current bundle covers thirteen defensive domains:
`apsb25-94`, `modsec-grammar`, `apf-grammar`, `ir-playbook`, `linux-forensics`,
`magento-attacks`, `obfuscation`, `webshell-families`, `actor-attribution`,
`false-positives`, `defense-synthesis`, `remediation`, and `timeline`. Total
skill surface: 48 files across 13 subdirectories. Skill authoring discipline and
bundle structure are documented in `DESIGN.md` §9.

## Model choice

| Role | Model | Rationale |
|------|-------|-----------|
| Curator agent | `claude-opus-4-7` | Forensic synthesis across 250k-400k token evidence bundles; 1M context; adaptive thinking for hypothesis ranking |
| Step execution | `claude-sonnet-4-6` | Lower latency for tier-gated operator confirmations; sufficient reasoning depth for step validation |
| FP corpus gating | `claude-haiku-4-5` | Lightweight classification before signature append; high throughput, low cost for yes/no FP gate decisions |

The three-tier model routing is not cosmetic. Curator calls are infrequent and
expensive by design — they carry the full evidence bundle. Step-execution and
FP-gating calls are frequent and cheap by design — they carry only the step payload
or the candidate signature. Using the same model everywhere would either make
investigations prohibitively expensive or leave the reasoning-intensive curator
step under-resourced.

## Roadmap

Deferred to v2.1+. New ideas go to `FUTURE.md` during the current build window.

- Interactive review shell (`bl shell`) for multi-step investigation flows.
- Multi-host fan-out (`bl observe --fleet`) coordinating across N hosts via a single curator session.
- SaaS control plane: managed agents hosted per-tenant; per-tenant case retention.
- Additional defensive backends: firewalld, nft jumps, fail2ban integration.
- Incident brief PDF export via Files API (pandoc + weasyprint pipeline already
  documented in `docs/setup-flow.md §4.3`; implementation deferred).

Track active scoping discussions in [GitHub Issues](https://github.com/rfxn/blacklight/issues).

## Documentation

- Architecture and command reference: [`DESIGN.md`](DESIGN.md)
- Strategy and positioning: [`PIVOT-v2.md`](PIVOT-v2.md)
- Command help: `bl --help` and `bl <verb> --help`
- Exit codes: [`docs/exit-codes.md`](docs/exit-codes.md)
- Setup contract: [`docs/setup-flow.md`](docs/setup-flow.md)

## License

GNU GPL v2. See [`LICENSE`](LICENSE).

Part of the R-fx Networks defensive OSS portfolio — alongside
[LMD](https://github.com/rfxn/linux-malware-detect),
[APF](https://github.com/rfxn/advanced-policy-firewall),
[BFD](https://github.com/rfxn/brute-force-detection).

---

*Hackathon build — Opus 4.7, Cerebral Valley "Built with 4.7" April 2026.*
