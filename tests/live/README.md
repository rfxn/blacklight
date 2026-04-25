# tests/live/ — behavioral verification against real Anthropic API

This directory holds the live-fire end-to-end harness that exercises
blacklight's full Managed Agents runtime path against the real
Anthropic API. It is **separate from CI** — the standard BATS suite
(`tests/*.bats`) runs against `tests/helpers/curator-mock.bash`
fixtures and stays mock-driven.

## Why a separate harness

CI must stay deterministic, fast, and free. CI mocks every API call.
But a mocked test cannot prove that the curator agent actually wakes
from a session event, processes a 360k-token bundle, and writes
`hypothesis.md` back to the memory store within demo-acceptable timing.
This harness does — once per release, against the real API, with
committed evidence.

## How to run

```bash
source .secrets/env                                # provides ANTHROPIC_API_KEY
tools/synth-corpus.sh --seed 42                    # if exhibits/fleet-01/large-corpus/ missing
make live-trace                                    # full end-to-end run, ~3-5 min
make live-trace-grade EVIDENCE=tests/live/evidence/live-trace-<TS>.md
```

## What the harness does

1. Sources `.secrets/env` for `ANTHROPIC_API_KEY`. Aborts loudly if absent.
2. Provisions or reuses `bl-curator` Managed Agent in your workspace.
3. Runs the §End-to-end CLI demo scenario from `PLAN-M12.md` top to bottom:
   setup -> consult --new -> 6 observations -> consult --attach (curator wake)
   -> run --tier auto -> case --show -> sim-day-2 attach (persistence proof).
4. Captures every `bl_api_call` request + response to `tests/live/evidence/.trace-<TS>.jsonl`.
5. Emits committed evidence to `tests/live/evidence/live-trace-<TS>.md`.

## What the grader checks

6-point rubric (pass = >=5/6):

1. Hypothesis names the `.cache/*.php` polyglot pattern
2. C2 IP correlated across apache + cron (cross-stream)
3. Step tier distribution covers auto + suggested + destructive
4. Sim-day-2 hypothesis cites prior obs IDs (persistence)
5. Curator turn input in 300k-500k token band (1M context exercised)
6. Wall-clock for hypothesis turn <=90s

## Cost

Roughly $5-15 per run. The harness aborts at $50 and warns at $25.

## Failure modes

- **No API key:** harness exits 65 with a clear message. Fix: source `.secrets/env`.
- **Corpus missing:** exits 65. Fix: run `tools/synth-corpus.sh`.
- **gawk missing:** exits 65. Fix: install gawk (required for cost-cap arithmetic).
- **Hypothesis timeout (120s):** typically a curator-side issue (prompt too thin,
  bundle malformed, model overload). Re-run; if persistent, iterate `prompts/curator-agent.md`.
- **Grader fail (<5/6):** evidence file shows which checks failed and why.
  Common causes: hypothesis did not cross-stream-correlate (Phase 4 prompt issue),
  curator inferred wrong tier (Phase 4 tier rule issue), bundle came in under 300k tokens
  (Phase 2 corpus issue).

## Evidence files

`tests/live/evidence/live-trace-<YYYYMMDD-HHMM>.md` — committed after a successful
Phase 6 run. The hidden `.trace-<TS>.jsonl` file alongside it contains the raw
request/response log; it is gitignored (too large to track).
