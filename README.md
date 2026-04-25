# blacklight

*Attackers have agents. Defenders still have grep. blacklight is the counter.*

At 03:42 UTC on a Saturday, a hosting provider's on-call engineer gets the APSB25-94
advisory: Magento stores are actively backdoored via a double-extension webshell hidden
in the media cache. Eight hours later the team has run grep, find, modsec log scrapes,
ClamAV scans, APF drops, and crontab audits across forty hosts — by hand. blacklight
collapses that arc into agent-directed motions on the same Linux substrate the defender
already runs. No platform buy-in. No fleet migration. No analyst retraining. The curator
agent holds the case across days; the operator runs the steps it prescribes.

## Who this is for

Hosting providers, MSPs, and security teams already running the R-fx Networks
defensive OSS stack — [LMD](https://github.com/rfxn/linux-malware-detect)
(~tens of thousands of installs), [APF](https://github.com/rfxn/advanced-policy-firewall)
(~hundreds of thousands of installs), [BFD](https://github.com/rfxn/brute-force-detection).
blacklight is the agentic-defensive-era release in that family — same Linux substrate,
same install discipline, same operator vocabulary. No platform buy-in, no fleet
migration, no analyst retraining.

## Install

One-liner (curl-pipe-bash safe):

```bash
curl -fsSL https://raw.githubusercontent.com/rfxn/blacklight/main/install.sh | sudo bash
export ANTHROPIC_API_KEY="sk-ant-..."
bl setup
```

Requires: bash 4.1+, curl, jq. Per-commit CI gate: Debian 12 + Rocky 9 (full BATS
suite, both green). Release-matrix targets: Ubuntu 20.04 / 22.04 / 24.04, CentOS 7,
Rocky 8 (verified via packaging scripts; full BATS run before each release tag).

`bl setup` provisions a Managed Agent session in the operator's Anthropic workspace
(one-time per workspace). Subsequent `bl` invocations reuse that session.

## Try it

Scenario: APSB25-94 advisory drops. One host is suspected. The operator opens a case,
collects evidence, and applies a ModSec rule — all in under ten minutes.

**Step 1 — collect Apache logs and check the filesystem:**

```bash
bl observe log apache --around /var/www/html/pub/media/catalog/product/.cache/a.php --window 6h
bl observe fs --mtime-since --since 2026-03-20T00:00:00Z --under /var/www/html --ext php
```

```
blacklight: obs-0001 apache log records → bl-case/CASE-2026-0001/evidence/obs-0001-apache.transfer.json (3 records)
{"ts":"2026-03-22T14:22:07Z","host":"magento-prod-01","source":"apache.transfer","record":{"client_ip":"203.0.113.42","method":"GET","path":"/pub/media/catalog/product/.cache/a.php/banner.jpg","status":200,"path_class":"polyglot","is_post_to_php":false}}
{"ts":"2026-03-22T14:23:51Z","host":"magento-prod-01","source":"apache.transfer","record":{"client_ip":"203.0.113.42","method":"POST","path":"/pub/media/catalog/product/.cache/a.php","status":200,"path_class":"php_in_cache","is_post_to_php":true}}
{"ts":"2026-03-22T14:31:09Z","host":"magento-prod-01","source":"apache.transfer","record":{"client_ip":"203.0.113.42","method":"GET","path":"/pub/media/catalog/product/.cache/a.php/logo.gif","status":200,"path_class":"polyglot","is_post_to_php":false}}

blacklight: obs-0002 fs records → bl-case/CASE-2026-0001/evidence/obs-0002-fs.mtime-since.json (1 record)
{"ts":"2026-04-25T00:00:00Z","host":"magento-prod-01","source":"fs.mtime-since","record":{"path":"/var/www/html/pub/media/catalog/product/.cache/a.php","mtime":"2026-03-21T23:58Z","ext":"php"}}
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

Post-incident reconstruction requires cross-stream correlation — the webshell URL in
the access log, the double-extension filesystem path, and the injected cron entry are
only causally connected when the curator can see all three streams simultaneously. A
realistic APSB25-94-shaped case accumulates Apache access logs, ModSec audit entries,
filesystem mtime clusters, crontab diffs, and process snapshots — routinely 250,000 to
400,000 tokens of raw evidence before the curator has authored a single hypothesis.
Chunking that evidence across multiple calls destroys the correlation that distinguishes
signal from noise: a retriever picking "top 5 evidence items" will miss the one that
matters precisely because it does not look relevant in isolation. The 1M context window
makes full-bundle correlation possible without a retrieval layer. Opus 4.7 provides the
forensic reasoning depth needed to distinguish a staging artifact from a false positive
by applying knowledge from ModSecurity grammar, Magento path conventions, and attacker
TTPs simultaneously. The `exhibits/fleet-01/` directory in this repository contains a
worked APSB25-94-shaped case that exercises the full bundle shape, reconstructed
entirely from the public Adobe security advisory.

## Skills architecture

Defensive motions ship as a skill bundle — 65 markdown files across 20 defensive
domains, authored from public sources: Adobe security advisories, ModSecurity grammar
documentation, Magento developer docs, Linux hosting-stack documentation, public
YARA rule repositories. The curator agent loads these skill bundles as read-only
memory store content at session creation via `bl setup --sync`. The operator never
touches the skill files at runtime; the curator reads them, applies them to the
evidence, and prescribes steps. New skills can be authored and synced without
modifying `bl` source. The current bundle covers twenty defensive domains:
`actor-attribution`, `agentic-minutes-playbook`, `apf-grammar`, `apsb25-94`,
`defense-synthesis`, `false-positives`, `hosting-stack`, `ic-brief-format`,
`ioc-aggregation`, `ir-playbook`, `legacy-os-pitfalls`, `linux-forensics`,
`magento-attacks`, `modsec-grammar`, `obfuscation`, `remediation`,
`ride-the-substrate`, `shared-hosting-attack-shapes`, `timeline`, and
`webshell-families`. Total skill surface: 65 files across 20 subdirectories.
Skill authoring discipline and bundle structure are documented in
`DESIGN.md` §9.

## Model choice

| Role | Model | Rationale |
|------|-------|-----------|
| Curator agent | `claude-opus-4-7` | Forensic synthesis across 250k-400k token evidence bundles; 1M context; Managed Agent session with persistent case state |
| Step execution | `claude-sonnet-4-6` | Lower latency for tier-gated operator confirmations; sufficient reasoning depth for step validation |
| FP corpus gating | `claude-haiku-4-5` | Lightweight classification before signature append; high throughput, low cost for yes/no FP gate decisions |

The three-tier model routing is not cosmetic. Curator calls are infrequent and
expensive by design — they carry the full evidence bundle. Step-execution and
FP-gating calls are frequent and cheap by design — they carry only the step payload
or the candidate signature. Using the same model everywhere would either make
investigations prohibitively expensive or leave the reasoning-intensive curator
step under-resourced.

## Proof

Behavioral verification is committed evidence, not a claim. Two artifacts:

- **Live-trace evidence:** [`tests/live/evidence/`](tests/live/evidence/) — `make live-trace`
  exercises the end-to-end CLI walkthrough against the real Anthropic Managed Agents API.
  The committed trace shows workspace setup, case allocation, observation substrate
  assembly, and per-API-call cost capture. The current run (2026-04-25) is partial —
  Scenes 0/1/2 hermetic and green; the curator session-creation surface drifted in the
  `managed-agents-2026-04-01` beta and is being tracked for follow-up. Re-run locally
  with `make live-trace` (requires `ANTHROPIC_API_KEY` in `.secrets/env`).
- **Stress corpus:** [`exhibits/fleet-01/README.md`](exhibits/fleet-01/README.md) —
  a deterministic, byte-identical, ~360k-token APSB25-94 forensic bundle (apache +
  modsec + fs + cron + proc + journal + maldet) with attack needles buried in
  realistic noise. Regenerate with `tools/synth-corpus.sh --seed 42`. Sources
  documented; no operator-local data.

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
