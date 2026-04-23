# blacklight

**A fleet-scoped Linux forensics agent that thinks continuously, revises its
conclusions as evidence arrives, and turns forensic reasoning into deployable
defenses — so the host that was never compromised blocks the next attack.**

Built for managed hosting providers and MSPs triaging APSB25-94-class Magento
PolyShell incidents — currently a multi-week, $600/hr human process.

The payoff this repo is optimized for: a host with no compromise indicators of
its own blocks an attack because the curator attributed earlier activity on
*other* hosts to a coherent actor with a predicted next move. Every
engineering decision serves that frame.

## Try it

```bash
git clone https://github.com/rfxn/blacklight.git
cd blacklight
cp .secrets/env.example .secrets/env    # add your ANTHROPIC_API_KEY
. .secrets/env
COMPOSE_FILE=compose/docker-compose.yml docker compose up -d --build
```

The fleet comes up as seven containers: `bl-curator` (the investigator,
Managed Agent) plus six hosts. Four Apache + ModSec hosts stage APSB25-94
PolyShell variants or a skimmer campaign (hosts 2/4/5/7). One clean Apache
host (`bl-host-1`) is the payoff — never compromised, but defended by rules
authored from activity on the others. One clean Nginx host (`bl-host-3`)
demonstrates the stack-profile skip.

```bash
# Health
docker exec bl-curator curl -fsS http://localhost:8080/health

# Push a forensic report from host-2 → curator inbox
docker exec bl-host-2 /opt/bl-agent/bl-report
docker exec bl-curator ls /app/inbox/

# Investigate: dispatches three Sonnet 4.6 hunters in parallel, opens a case
docker exec -e ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" bl-curator \
    bash -c 'python -m curator.orchestrator /app/inbox/*.tar'

# Read the case file
docker exec bl-curator cat /app/curator/storage/cases/CASE-2026-0007.yaml

# Run the time-compression sim (replays a multi-day arc in ~90 seconds)
docker exec -e ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" bl-curator \
    python -m demo.time_compression --paced
```

The first run materializes `CASE-2026-0007` at confidence 0.4. Subsequent
reports trigger the Opus 4.7 hypothesis-revision path; the case's
`hypothesis.history[]` records every revision with the evidence cited, the
prior confidence, and the reason for the change. That `history[]` is the
audit trail no dashboard can draw.

## Why this is a Managed Agent, not a tool loop

- **Hypothesis revision runs inside a persistent Claude Managed Agents
  session.** When a second report arrives on an active case, the curator
  sends the new evidence into a long-running session where the agent has
  already seen every prior turn. The agent rereads its own earlier
  revision — from session-native conversation history, not from a YAML
  we reconstruct — and emits the next revision through a structured
  `report_case_revision` custom tool call. See
  [`curator/session_runner.py`](curator/session_runner.py) for the
  session event loop.
- **Persistent state crosses sim-days.** One fleet-wide session carries
  investigation context across the full multi-day arc; `session_id` is
  persisted alongside agent/environment IDs in operator-local env so the
  same session survives container restarts.
- **Cross-invocation reasoning is literal.** `hypothesis.history[]` on
  every case records prior confidence, revision rationale, and evidence
  IDs. The agent sees its prior turns in session memory and
  contradicts itself when evidence demands.
- **Autonomous artifact production.** The session's revision emits into
  a pydantic-validated `RevisionResult` which feeds `apply_revision()` +
  case YAML write. Intent reconstruction and rule synthesis remain
  direct Opus 4.7 calls — they are bounded one-shots per artifact and
  benefit from the strict `output_config.format.json_schema` guarantee
  that the beta Managed Agents SDK does not yet offer. This is a
  deliberate boundary, not an omission.

The investigation loop's revision step runs inside a Claude Managed
Agents session (`curator/session_runner.py`); local Flask is plumbing
for the manifest endpoint and report inbox.

## Why these models

Model choice is part of the system design, not a sponsorship.

- **Sonnet 4.6 runs the three hunters** (`fs`, `log`, `timeline`). Filesystem
  anomaly detection, log-cadence analysis, and timeline correlation are
  structured pattern-matching at volume. Three hunters run in parallel; cost
  and speed matter; thinking is off; structured output via forced
  `tool_choice`.

- **Opus 4.7 runs the intent reconstructor.** Deobfuscating a multi-layer
  PolyShell (base64 → gzinflate → eval, with mangled variables and
  capability markers hidden in commented dead code) is sustained code
  comprehension, not pattern matching. Adaptive thinking enabled
  (`thinking={"type": "adaptive", "display": "summarized"}`). Structured
  output via `output_config.format` json_schema — forced `tool_choice` is
  incompatible with thinking on Opus 4.7 (HTTP 400, verified 2026-04-22).

- **Opus 4.7 runs the case-file engine.** Hypothesis revision with
  calibrated uncertainty — reading prior reasoning, deciding whether new
  evidence *supports*, *contradicts*, or *extends* it, and writing a new
  hypothesis with honest confidence — is where 4.7's calibration earns its
  cost. Adaptive thinking enabled. This is the load-bearing capability of
  the entire system.

- **Opus 4.7 runs the synthesizer.** Generating a ModSec rule that catches
  the observed attack, an exception list that preserves legitimate traffic,
  and a validation test that proves both is multi-artifact coherent
  generation. Every emitted rule is gated through `apachectl configtest`
  before it joins the manifest.

Sonnet for volume; Opus for the reasoning that survives contradiction.

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

- Hunters never write case state directly — only evidence rows.
- Case engine never writes manifests — only cases.
- Synthesizer never writes cases — only rules.
- bl-agent never writes curator state — only pulls and applies locally.

The case engine reads evidence **summaries** from sqlite, never raw log
lines — context-bloat fence so a 30-sim-day case doesn't drown the model.

## The skills bundle

Domain knowledge lives as files under `skills/`, routed by a decision tree
at [`skills/INDEX.md`](skills/INDEX.md). The router loads the relevant
subset per call rather than stuffing the whole bundle into context. Pattern
borrowed from [CrossBeam's CA permit AI](https://github.com/mikeOnBreeze/cc-crossbeam),
which won the February 2026 Opus 4.6 hackathon by treating skills as
domain-knowledge injection.

Three operator-authored core files carry the moat:

- [`ir-playbook/case-lifecycle.md`](skills/ir-playbook/case-lifecycle.md) —
  the rules for when to revise, split, merge, and hold an investigation.
  Loaded on every case-engine call.
- [`webshell-families/polyshell.md`](skills/webshell-families/polyshell.md) —
  PolyShell family patterns + dormant-capability inference rules.
- [`defense-synthesis/modsec-patterns.md`](skills/defense-synthesis/modsec-patterns.md) —
  validated ModSec rule shapes with exception idioms.

20 files total (19 content + INDEX router), covering: linux-forensics,
magento-attacks, modsec-grammar, apf-grammar, hosting-stack, ic-brief-format,
false-positive patterns, and the APSB25-94 IOC summary. See `skills/INDEX.md`
for the full router.

## What you'll see in the demo

A 3-minute video. Six-host Dockerized fleet. A time-compression simulator
(`demo/time_compression.py`) that replays a multi-day investigation arc in
~90 seconds.

At **1:15**: a host that was never compromised blocks an attack. The
curator attributed earlier activity on hosts 2, 4, and 7 to a coherent
APSB25-94 actor, generated a ModSec rule that passed `apachectl configtest`,
and the rule was deployed to every host in the fleet via the manifest +
SHA-256 sidecar pull. The host that was never compromised is the one that
caught the next wave.

(Video link lands on submission day.)

## Roadmap

What blacklight does NOT do this week, by design — these get a paragraph,
not an implementation:

- **Manifest rotation / retirement.** Promotion-only today; defenses age out
  manually. Production deployment wants a managed lifecycle.
- **Role-swappable substrate.** The same Managed Agent + manifest + Bash
  agent topology can host other roles: continuous compliance auditor, abuse
  responder, migration supervisor, capacity planner. One role at a time
  this week; the substrate is the platform.
- **GPG signing.** SHA-256 sidecar is sufficient for the demo; production
  deployment wants cryptographic provenance on the manifest.
- **Web frontend.** Terminal + a generated HTML brief only. The terminal
  is the product surface; the brief is the takeaway artifact.
- **Multi-tenant hosted offering.** Cross-tenant threat-intel sharing in
  privacy-preserving ways is a real product if the operator pursues it; not
  a hackathon scope.

## Status

Hackathon build started **2026-04-21 19:48 CT**. Submission target
**2026-04-26 16:00 EDT** (4-hour buffer before the 20:00 EDT deadline).
Built for the *Built with Opus 4.7* Claude Code hackathon, hosted by
Cerebral Valley — [event page](https://cerebralvalley.ai/e/built-with-4-7-hackathon).

Clean-room build. Zero pre-existing code carried forward. License: **GPL v2**
— matches the operator's existing defensive OSS portfolio (LMD / APF /
BFD).

## Credits

Authored by Ryan MacDonald (R-fx Networks). 25+ years operating Linux
hosting infrastructure. Maintainer of [Linux Malware
Detect](https://github.com/rfxn/linux-malware-detect),
[Advanced Policy Firewall](https://github.com/rfxn/advanced-policy-firewall),
and [Brute Force Detection](https://github.com/rfxn/brute-force-detection).
The skills bundle encodes operator knowledge from that career.

GPL v2 — see `LICENSE`.
