# blacklight

**Fleet-scoped Linux forensics that thinks continuously, revises its own
conclusions as evidence arrives, and turns forensic reasoning into deployable
defenses.**

Built for managed hosting providers and MSPs triaging APSB25-94-class Magento
PolyShell incidents — today a multi-week, $600/hr human process.

The payoff: **a host that was never compromised blocks the next attack.** The
curator attributes earlier activity on *other* hosts to a coherent actor,
predicts a next move, synthesizes a ModSec rule, and every host in the fleet
pulls it — including the one that was never touched. That's the one that
catches the next wave.

## Demo

3-minute video: *link lands on submission day (2026-04-26).*

The payoff window is **1:15 – 1:55**. A six-host fleet, a multi-day
investigation replayed in ~90s by a time-compression simulator, and a
ModSec rule born out of a hypothesis revision that blocks an attack on a
never-compromised host.

## Try it

```bash
git clone https://github.com/rfxn/blacklight.git
cd blacklight
cp .secrets/env.example .secrets/env    # add your ANTHROPIC_API_KEY
. .secrets/env
COMPOSE_FILE=compose/docker-compose.yml docker compose up -d --build
```

Seven containers come up: `bl-curator` (Managed Agent) plus six hosts.
Four Apache + ModSec hosts stage APSB25-94 PolyShell variants or a skimmer
campaign (hosts 2/4/5/7). One clean Apache host (`bl-host-1`) is the
payoff — never compromised, but defended by rules authored from activity
on the others. One clean Nginx host (`bl-host-3`) demonstrates the
stack-profile skip.

```bash
# Ship a forensic report from a compromised host → curator inbox
docker exec bl-host-2 /opt/bl-agent/bl-report

# Investigate: three Sonnet 4.6 hunters dispatch in parallel, case opens
docker exec -e ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" bl-curator \
    bash -c 'python -m curator.orchestrator "$(ls -t /app/inbox/*.tar | head -1)"'

# Read the case file — the audit trail no dashboard can draw
docker exec bl-curator cat /app/curator/storage/cases/CASE-2026-0007.yaml

# Replay the multi-day arc in ~90 seconds
docker exec -e ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" bl-curator \
    python -m demo.time_compression --paced
```

## The artifact: `hypothesis.history[]`

Every case carries a running record of what the curator believed, when, why
it changed, and what evidence drove the change:

```yaml
case_id: CASE-2026-0007
status: active
hypothesis:
  current:
    summary: "Campaign — PolyShell deployed across host-2 and host-4, shared C2 on .top TLD"
    confidence: 0.6
    reasoning: "Two hosts, matching multi-layer base64+gzinflate obfuscation, shared callback
                domain pattern. Magento 2.4.x common. Consistent with APSB25-94 exploitation wave."
  history:
    - at: 2026-04-01T14:32:11Z
      confidence: 0.4
      summary: "Single host compromise — PolyShell at /pub/media/catalog/.cache/a.php"
      trigger: "initial fs_hunter report on host-2"

capability_map:
  observed:   [arbitrary PHP execution, C2 callback via .top domain]
  inferred:   [credential harvest capability — PolyShell family ships this module]
  likely_next: [lateral movement via DB credential reuse, skimmer injection into storefront JS]

actions_taken:
  - action: "promoted_defense"
    defense_id: "MODSEC-RULE-2026-0014"
    reason: "Block .top callback pattern on hosts with Magento 2.4.x profile"
```

Prior confidence, revision trigger, evidence IDs, actions taken — all
addressable. The case engine re-reads this record on every new report and
either extends, contradicts, or holds its own prior reasoning. Honest
uncertainty is the feature.

## Why this is a Managed Agent, not a tool loop

The curator **is** a Managed Agents session. Architecture, not cosmetics.

- **Revision runs inside a persistent Claude Managed Agents session.** New
  evidence arrives on an active case and the agent reads its own prior
  turns from session-native conversation history — not from a YAML we
  reconstruct — then emits the next revision through a
  `report_case_revision` custom tool call. See
  [`curator/session_runner.py`](curator/session_runner.py).
- **State survives sim-days.** One fleet-wide session carries investigation
  context across the full multi-day arc; `session_id` is persisted
  alongside agent/environment IDs so the same session survives container
  restarts.
- **Cross-invocation reasoning is literal.** `hypothesis.history[]`
  records every prior revision. The agent contradicts itself when
  evidence demands.
- **Autonomous artifact production.** Session revision emits into a
  pydantic-validated `RevisionResult` which feeds `apply_revision()` +
  case YAML write.

Intent reconstruction and rule synthesis remain direct Opus 4.7 calls —
they're bounded one-shots per artifact and benefit from the strict
`output_config.format.json_schema` guarantee that the beta Managed Agents
SDK does not yet offer. A deliberate boundary, not an omission.

## Why these models

Model choice is system design, not sponsorship.

- **Sonnet 4.6 — the three hunters** (`fs`, `log`, `timeline`). Filesystem
  anomaly, log cadence, timeline correlation: structured pattern-matching
  at volume. Three in parallel, thinking off, forced `tool_choice`.
- **Opus 4.7 — intent reconstructor.** Peeling a multi-layer PolyShell
  (base64 → gzinflate → eval, mangled variables, capability markers in
  commented dead code) is sustained code comprehension, not pattern
  matching. Adaptive thinking enabled.
- **Opus 4.7 — case-file engine.** Hypothesis revision with calibrated
  uncertainty — deciding whether new evidence *supports*, *contradicts*, or
  *extends* prior reasoning, and writing a new hypothesis with honest
  confidence — is where 4.7's calibration earns its cost. The load-bearing
  capability of the entire system.
- **Opus 4.7 — synthesizer.** A ModSec rule that catches the observed
  attack + an exception list that preserves legitimate traffic + a
  validation test that proves both is multi-artifact coherent generation.
  Every emitted rule is gated through `apachectl configtest` before it
  joins the manifest.

Sonnet for volume. Opus for the reasoning that survives contradiction.

Structured output on the Opus 4.7 calls uses `output_config.format`
json_schema — forced `tool_choice` is incompatible with thinking on Opus
4.7 (HTTP 400, verified 2026-04-22). Hunters keep forced `tool_choice`
with thinking off.

## Architecture

```
host-{1..N}                          curator (Managed Agent)
├── bl-report ──tar──POST──▶  ┌────────────────────────────┐
├── bl-pull ◀─manifest+sha─┤  │  inbox/ (envelopes)         │
└── bl-apply ──configtest──┘  │  sqlite: evidence, cases    │
                              │                              │
                              │  ┌─ fs_hunter    (Sonnet 4.6) │
                              │  ├─ log_hunter   (Sonnet 4.6) │
                              │  └─ timeline_hunter (Sonnet 4.6)│
                              │        │                      │
                              │        ▼                      │
                              │  evidence rows                │
                              │        │                      │
                              │        ▼                      │
                              │  intent.reconstruct (Opus 4.7 + adaptive thinking)
                              │        │                      │
                              │        ▼                      │
                              │  case_engine.revise (Opus 4.7 + adaptive thinking)
                              │        │    ├─ history[] appended
                              │        │    └─ capability_map merged
                              │        ▼                      │
                              │  synthesizer.generate (Opus 4.7)
                              │        │   └─ apachectl configtest
                              │        ▼                      │
                              │  manifest.yaml + .sha256      │
                              └────────────────────────────┘
```

**Data-flow invariants** that make the audit trail addressable:

- Hunters never write case state — only evidence rows.
- Case engine never writes manifests — only cases.
- Synthesizer never writes cases — only rules.
- bl-agent never writes curator state — only pulls and applies locally.

The case engine reads evidence **summaries** from sqlite, never raw log
lines. Context-bloat fence so a 30-sim-day case doesn't drown the model.

## Skills bundle

Domain knowledge lives as files under `skills/`, routed by a decision
tree at [`skills/INDEX.md`](skills/INDEX.md). The router loads the
relevant subset per call rather than stuffing the whole bundle into
context — pattern borrowed from [CrossBeam's CA permit
AI](https://github.com/mikeOnBreeze/cc-crossbeam), which won the February
2026 Opus 4.6 hackathon treating skills as domain-knowledge injection.

Three operator-authored core files carry the moat:

- [`ir-playbook/case-lifecycle.md`](skills/ir-playbook/case-lifecycle.md) —
  when to revise, split, merge, or hold an investigation. Loaded on every
  case-engine call.
- [`webshell-families/polyshell.md`](skills/webshell-families/polyshell.md) —
  PolyShell family patterns + dormant-capability inference rules.
- [`defense-synthesis/modsec-patterns.md`](skills/defense-synthesis/modsec-patterns.md) —
  validated ModSec rule shapes with exception idioms.

20 files total (19 content + INDEX router): linux-forensics,
magento-attacks, modsec-grammar, apf-grammar, hosting-stack,
ic-brief-format, false-positives, and the APSB25-94 IOC summary.

## Roadmap — what blacklight does NOT do this week, by design

- **Manifest rotation / retirement.** Promotion-only today; production
  wants a managed lifecycle.
- **Role-swappable substrate.** Same Managed Agent + manifest + Bash-agent
  topology hosts other roles: continuous compliance auditor, abuse
  responder, migration supervisor, capacity planner. One role this week;
  the substrate is the platform.
- **GPG signing.** SHA-256 sidecar is enough for the demo; production
  wants cryptographic provenance on the manifest.
- **Web frontend.** Terminal + a generated HTML brief only. The terminal
  is the product surface.
- **Multi-tenant hosted offering.** Cross-tenant threat-intel sharing in
  privacy-preserving ways is a real product path; not a hackathon scope.

## Status · credits · license

Hackathon build started **2026-04-21 19:48 CT**. Submission target
**2026-04-26 16:00 EDT** (4-hour buffer before the 20:00 EDT deadline).
Built for the *Built with Opus 4.7* Claude Code hackathon, hosted by
Cerebral Valley — [event page](https://cerebralvalley.ai/e/built-with-4-7-hackathon).

Clean-room build. Zero pre-existing code carried forward.

Authored by Ryan MacDonald (R-fx Networks). 25+ years operating Linux
hosting infrastructure. Maintainer of [Linux Malware
Detect](https://github.com/rfxn/linux-malware-detect), [Advanced Policy
Firewall](https://github.com/rfxn/advanced-policy-firewall), and [Brute
Force Detection](https://github.com/rfxn/brute-force-detection). The
skills bundle encodes operator knowledge from that career.

GPL v2 — see [`LICENSE`](LICENSE). Matches the existing defensive OSS
portfolio.
