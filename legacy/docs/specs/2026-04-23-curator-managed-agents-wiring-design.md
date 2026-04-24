# Design Spec — curator Managed Agents session wiring

**Date:** 2026-04-23
**Status:** draft (pre-plan)
**Target plan:** `PLAN-managed-agents-wiring.md`
**Submission window:** 2026-04-23 Thu — 2026-04-25 Sat 12:00 CT (before P43 18:00 CT recording gate)
**Prize target:** $5k **Best Use of Claude Managed Agents** + preservation of grand-prize Depth & Execution signal

---

## 1. Why

The README, HANDOFF architecture, MEMORY.md, and CLAUDE.md all claim the curator is a long-running Claude Managed Agents session. An audit (2026-04-23 session, memory entry pending) found the runtime does not back the claim:

- `curator/managed_agents.py::first_contact_smoke_test()` proved the `beta.agents.create` / `beta.environments.create` / `beta.sessions.create` round-trip works. Agent + env IDs persist in `.secrets/env`.
- Every hot-path Claude call — hunters (`hunters/base.py:138`), case engine (`case_engine.py:302+313`), intent (`intent.py:124+136`), synthesizer (`synthesizer.py:214+225`) — uses direct `anthropic.Anthropic().messages.create(...)` against stateless `/v1/messages`. No session.
- `stream_events()` at `managed_agents.py:133` is dead code — scaffolded for a session path that was never opened.
- The only runtime coupling to `managed_agents.py` is the two string constants `MODEL_CURATOR` and `MODEL_HUNTER`.

A judge reading `orchestrator.py` for 90 seconds sees `messages.create()` everywhere, no session. The Managed Agents prize claim collapses on code inspection; Depth & Execution (20%) and Opus 4.7 Use (20%) both take visible hits.

## 2. Goal

Make the curator's investigation loop actually run inside a Managed Agents session, so:

- `orchestrator.py::process_report` opens or reuses a session, sends evidence into it via `user.message`, receives structured output via custom-tool events.
- Persistent `BL_CURATOR_AGENT_ID` / `BL_CURATOR_ENV_ID` are production IDs, not smoke-test leftovers.
- The README's three "Why this is a Managed Agent" bullets (persistent state, cross-invocation reasoning, autonomous artifact production) verify from `orchestrator.py` alone.
- Existing 136 tests remain green with `BL_SKIP_LIVE=1`; P43 Saturday recording gate passes against session-wired code.
- Day-3 hypothesis-revision capability (the load-bearing one) is strictly preserved — no regression on `tests/test_revision.py` behavior.

## 3. SDK reality (read before the decision)

From `platform.claude.com/docs/en/managed-agents/` fetch 2026-04-23:

1. **Agent config fields (closed set):** `name`, `model`, `system`, `tools`, `mcp_servers`, `skills`, `callable_agents`, `description`, `metadata`. **No `thinking` kwarg. No `output_config` kwarg. No `response_format` kwarg.**
2. **Session config (closed set):** `agent`, `environment_id`, `title`, `vault_ids`. No thinking/output_config.
3. **Event send payload:** `{events: [{type: "user.message", content: [{type: "text", text: ...}]}]}`. No thinking/output_config.
4. **Structured output mechanism:** custom tools. Agent config accepts `{type: "custom", name, description, input_schema: {...JSON Schema...}}`. When the agent decides to invoke a custom tool, an `agent.custom_tool_use` event carries the structured input; the orchestrator responds with `user.custom_tool_result`.
5. **No forced `tool_choice`.** Agent chooses autonomously; the system prompt + tool description are the steering levers.
6. **Thinking on Opus 4.7 inside sessions:** `agent.thinking` events ARE streamed (Opus 4.7 auto-thinks); there is no kwarg to force `{type: "adaptive"}` explicitly. This is a silent loss of the per-call `thinking={"type":"adaptive"}` control the current code has — the session path delegates depth to the model's default agentic behavior.
7. **Skills** attach to the agent as progressive-disclosure domain context (maps directly to `skills/` bundle).
8. **Session persistence:** send a new `user.message` to the same session_id after `session.status_idle` — conversation history is maintained server-side across turns.
9. **Pricing:** normal token rates + $0.08/session-hour runtime, metered only while status=`running` (idle/rescheduling/terminated = no runtime billing).
10. **Parallelism inside a session:** a session is one linear conversation thread. Parallel turns are not supported. Parallelism for hunters must stay outside the session.

This materially shapes the decision. The session gives us persistent conversation + custom-tool structured output + skills — but costs us explicit thinking-depth control and parallel turns.

## 4. Architectural decision (the load-bearing one — Q5)

**Recommended: Minimal Viable Wiring (MVW).** Move the Day-3 `case_engine.revise()` call inside the session via a `report_case_revision` custom tool. Leave `intent.reconstruct()`, `synthesize()`, and the three hunters as direct `messages.create` calls.

**Why MVW over Full Wiring (move all Opus 4.7 calls into the session):**

1. **Schedule.** Full Wiring is 11-14h of work 48h from the recording gate. MVW is 7-9h and ships Friday. The plan surfaces both paths with an explicit cut at Friday 22:00 CT: if MVW isn't live-smoke green by then, revert the session-wiring commits and ship Option 2 (soften README).
2. **Schema rigor preserved.** The synthesizer's `apachectl configtest` gate is load-bearing — it cannot move into the session (the agent emits a rule; we validate it externally; we respond with tool_result). But keeping synthesizer as a direct call also preserves its tight `output_config.format.json_schema` guarantee vs. a custom-tool input where the agent might drift off-schema.
3. **Session semantic = what the prize wants.** "Persistent case state, cross-invocation reasoning" lands on hypothesis revision — the agent reads its own prior revision in session-native conversation history, not in orchestrator-reconstructed YAML. Intent and synthesis are bounded one-shots per case — they don't benefit meaningfully from session history.
4. **Hunters stay stateless.** Three Sonnet 4.6 calls running in parallel via `asyncio.gather` is the demo's speed story. Putting them inside a single session serializes them and reshapes the prompt surface in a way that invalidates the existing `tests/test_hunters_base.py` mock strategy.

**Prize claim after MVW (defensible + load-bearing):** *The curator's hypothesis-revision capability — reading prior reasoning and revising conclusions as evidence arrives — runs inside a persistent Claude Managed Agents session. The agent literally reads what it wrote on the prior report, via session-native conversation history, before emitting its next revision through a structured custom-tool call.*

**Full Wiring** remains the aspirational post-hackathon path and is documented in §11 Roadmap. If MVW lands by Thursday evening with 24h to spare, we can promote intent + synthesis into the session as a Friday-afternoon scope add — but we do not plan for it.

**Reviewer M1 pushback — prize-claim surface thinness:** a judge grepping `messages.create` after MVW still sees ~6 hits (hunters + intent + synthesize). "Best Use" is judged on what judges see, not what the spec argues. The plan must:
1. Commit to the exact README rewrite text (pasted verbatim in §6.2), not a "~20 LOC" summary.
2. Add a demo-recording-visible session cue (caption or log line) during the revision beat so the judge watching the video sees the session in action.
3. Add a §15 verification grep that the README Managed Agents section names `curator/session_runner.py` at `file:line` and does NOT over-claim session coverage for intent/synthesize.

**Reviewer M2 pushback — custom-tool invocation reliability is asserted, not measured:**
MVW semantic collapses to Option 2 if the agent emits text instead of invoking `report_case_revision`. The plan adds a pre-phase P0 spike (1-2h, carved from the 11h budget): `work-output/session-tool-invocation-probe.py` runs 5 live probes against real Opus 4.7 with the final prompt shape, records direct tool-invocation rate. Gate:
- ≥4/5 direct tool calls → green-light MVW.
- <4/5 → abort MVW, ship Option 2 at Thursday 22:00, not Friday 22:00.

This moves the fallback decision forward by ~24h — before any implementation commits land.

## 5. Architectural decisions table (answers Q1-Q9)

| # | Question | Decision | One-sentence defense |
|---|----------|----------|---------------------|
| Q1 | Session topology | **One fleet-wide session** (reuse across sim-days + across both CASE-0007 and CASE-0008) | MEMORY.md noted "v1 keeps it simple"; session drops are rare; per-case sessions lose the cross-case context that makes the host-5 split moment ("family markers don't match prior") land in the demo. |
| Q2 | Session lifecycle (create) | **Lazy open on first revise()-path call; reuse for subsequent reports; env-pinned via `BL_CURATOR_SESSION_ID`** | Keeps session_id in `.secrets/env` alongside agent/env IDs; on container restart, orchestrator either reuses the pinned session (if still `idle`) or silently opens a new one and rewrites `.secrets/env`. |
| Q3 | Message envelope | **Structured JSON payload as a single `text` block**: `{case: <full YAML dump>, new_evidence: [row_summaries], host: host_id, report_id: report_id}` | HANDOFF.md:510 context-bloat fence — evidence summaries only, no raw_evidence_excerpt, no log lines; the agent has file tools but the session does not need to read raw artifact bytes for revision (intent reconstruction — which does read artifacts — stays direct per §4). |
| Q4 | Where hunters live | **Outside the session — stay as `asyncio.gather` direct Sonnet 4.6 `messages.create` calls** | Parallelism is load-bearing for demo speed; a session is serial; test mocks already target `run_sonnet_hunter`; no prize-claim benefit from moving them in. |
| Q5 | Case engine / intent / synthesizer in-session | **MVW: only `revise()` moves inside the session** via `report_case_revision` custom tool | §4 defends this; intent + synthesize stay direct for schedule + schema rigor. |
| Q6 | Thinking + output_config composition | **Custom tool `input_schema` replaces `output_config.format.json_schema`**; thinking is automatic (agent.thinking events stream but not configurable) | Managed Agents SDK has no per-call thinking kwarg (§3.1-3.6); accept the silent loss of explicit `effort: high` — Opus 4.7 auto-thinks adaptively on complex revision prompts; `agent.thinking` event emission is observable proof. |
| Q7 | Persistent state | **Host filesystem** (`curator/storage/` unchanged) — agent does NOT write case/manifest files | Managed Agents env has an ephemeral cloud container; our case YAMLs + evidence.db + manifest.yaml must survive container restarts + fleet tests; orchestrator owns storage; agent's custom-tool output is parsed and written by orchestrator. |
| Q8 | Test mocking strategy | **New test-level adapter**: `tests/_session_mock.py` provides `@contextmanager mock_session_run(findings, revision_payload)` that patches `anthropic.Anthropic().beta.sessions.events.stream()` + `.send()` + `.create()` to yield deterministic event sequences | Keeps `BL_SKIP_LIVE=1` as the runtime-skip path; tests mock at SDK layer not at our adapter layer, matching existing `test_revision.py` mock discipline. |
| Q9 | Rollback | **Single feature flag `BL_USE_MANAGED_SESSION` (default `1` after MVW lands)**. Revert path = flip to `0`. Also: the revise-in-session commits form one continuous range and can be `git revert` cleanly if the flag isn't trusted. | Flag-based rollback is cheaper than commit revert in a <24h reshoot window; flag defaults to `1` so the managed-agent path is the read-the-code default for judges. |

## 6. Component delta

### 6.1 New files

| File | Lines (est) | Purpose |
|------|------------|---------|
| `curator/session_runner.py` | ~220 | Open-or-reuse session · send evidence `user.message` · consume event stream · dispatch `agent.custom_tool_use` events to pydantic validators · return `RevisionResult` or raise. |
| `prompts/curator-agent.md` | ~60 | System prompt for the curator agent. Instructs: "When evidence for an existing case arrives, reason about support_type, then invoke `report_case_revision` with your structured revision. Never emit revisions as plain text — always via the tool." |
| `tests/test_session_runner.py` | ~180 | Unit tests (SDK mocked): happy path · session-reuse · event-stream-interrupt · custom-tool-validation-failure · stub-mode returns deterministic RevisionResult. |
| `tests/_session_mock.py` | ~80 | Shared fixture helper — builds mock SDK event streams (agent.message, agent.thinking, agent.custom_tool_use, session.status_idle) from a declarative spec. |
| `work-output/session-live-smoke.py` | ~90 | Operator-runnable live smoke parallel to `work-output/revision-live-smoke.py` — drives one revise cycle through the session end-to-end against real Opus 4.7. |
| `curator/agent_setup.py` | ~110 | Bootstrap / upgrade script: `python -m curator.agent_setup` creates-or-updates the blacklight curator agent with the 1 custom tool + the 3 core skills attached; writes `BL_CURATOR_AGENT_ID`, `BL_CURATOR_AGENT_VERSION`, `BL_CURATOR_ENV_ID`, `BL_CURATOR_SESSION_ID` helper lines for `.secrets/env`. |

### 6.2 Modified files

| File | Change (LOC ≈) | Notes |
|------|----------------|-------|
| `curator/orchestrator.py` | +40 / -5 | In the existing revise-branch (lines 284-335): if `os.environ.get("BL_USE_MANAGED_SESSION", "1") == "1"` → route through `session_runner.revise_via_session(prior_case, rows)`; else keep current direct `revise()` path. |
| `curator/case_engine.py` | +0 / +0 | **No change to `revise()`** — remains as the non-session path; `session_runner.revise_via_session` calls `apply_revision()` directly on the validated `RevisionResult`, reusing all of `case_engine`'s merge/split/history logic. |
| `curator/managed_agents.py` | +0 / ~-30 | Delete dead `stream_events()` (lines 133-147) + unused `Iterator` import at line 7. `SessionHandle`, `create_curator_agent`, `create_fleet_environment`, `start_session` remain — now live via `session_runner` + `agent_setup`. |
| `curator/hunters/__init__.py` | -7 | Delete unused re-export block (dead-code audit finding B); reduce to docstring. |
| `README.md` | +28 / -14 | "Why this is a Managed Agent" section: **exact replacement text** below. |
| `demo/script.md` | +3 / -0 | Revision beat (sim-day 5 caption, line 77): add runner-emitted prefix `[session sid=sess_... reasoning-over-prior-turn]` so judges watching the video see the session bind lights up; add a pre-flight step to verify `BL_CURATOR_SESSION_ID` is set or auto-created. |
| `HANDOFF.md` | ±10 | Architecture diagram footnote: "Revise() runs in-session; intent + synth are direct calls (MVW)." |
| `MEMORY.md` | +10 | New entry documenting the MVW decision + the SDK-constraint findings (no thinking kwarg, custom-tool = structured output). |
| `PLAN.md` | +1 phase block | Add Phase 45 "Managed Agents session wiring (MVW)" + Phase 46 "Sentinel review + fix commits" at the end; inherits P44's trailing `---`. |

### 6.3 Deleted files

None. Everything reuses existing surfaces.

### 6.4 README "Why this is a Managed Agent" — exact replacement text

Strikes the current over-claim and replaces with the MVW-accurate version. Plan phase owns this verbatim:

```markdown
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
```

## 7. Message envelope shape (Q3 concrete)

**User message sent when a second+ report arrives on an existing case:**

```json
{
  "type": "user.message",
  "content": [{
    "type": "text",
    "text": "NEW EVIDENCE for CASE-2026-0007:\n\n```yaml\n<case.yaml dump with evidence summaries, no raw_evidence_excerpt>\n```\n\nNEW REPORT: host=host-4, report_id=rpt-abc123\n\nNEW EVIDENCE ROWS (hunter summaries):\n```json\n[\n  {\"id\": \"...\", \"hunter\": \"fs\", \"category\": \"unusual_php_path\", \"finding\": \"...\", \"confidence\": 0.88, ...},\n  ...\n]\n```\n\nReason about whether this evidence supports, contradicts, extends, is unrelated to, or is ambiguous w.r.t. the current hypothesis. Consult `skills/ir-playbook/case-lifecycle.md` for revision discipline (confidence anchors, split/merge rules). Then invoke `report_case_revision` with your structured revision. Do not emit the revision as plain text — the tool is the only valid output path."
  }]
}
```

Payload budget: ≤30KB per user.message (10KB case + 15KB evidence rows + 5KB instruction scaffold). Well under any reasonable session context cap.

**Reviewer S1 pushback — cumulative session history growth.** Fleet-wide session (Q1) with full-YAML-per-turn is O(n²) over beats. Projected sizes for the P43 four-beat arc (each re-sending the full case YAML):

| Beat | Sim day | Case YAML size | User.message size | Cumulative server-side |
|------|---------|---------------|-------------------|----------------------|
| 1 (initial host-2 report) | baseline | N/A (first-report path, no session) | N/A | 0 |
| 2 (host-4 revise) | 5 | ~8KB | ~24KB | ~24KB |
| 3 (host-7 revise) | 7 | ~14KB | ~32KB | ~56KB |
| 4 (host-1 revise) | 10 | ~20KB | ~40KB | ~96KB |
| 5 (host-5 split path) | 14 | ~26KB on CASE-0007 | ~48KB | ~144KB |

At N≤4 revise beats with ~150KB cumulative server-side, we are well under any reasonable session context cap. This is acceptable for MVW.

**Post-MVW (Full Wiring) requirement:** switch to delta envelopes — user.message carries *only new evidence since turn N* + a case-ID reference; the agent reads prior case state from its own session history. Logged as a FUTURE.md entry, not a plan phase.

**Reviewer S2 pushback — skill attachment clarification.** The skill file `skills/ir-playbook/case-lifecycle.md` is attached to the agent via `agents.create(..., skills=[...])` at `agent_setup.py` time (progressive disclosure; no per-turn cost). The user.message references it *by name only* ("Consult `skills/ir-playbook/case-lifecycle.md`") — the agent knows to load it because it's in the agent's skills list. Zero kilobyte cost per user.message from the skill reference.

## 8. Custom tool shape (Q6 concrete)

The agent is configured (at `python -m curator.agent_setup` time) with a single custom tool whose `input_schema` is derived from `curator.case_schema.RevisionResult`:

```python
REPORT_CASE_REVISION_TOOL = {
    "type": "custom",
    "name": "report_case_revision",
    "description": (
        "Emit the structured revision of the current case hypothesis. "
        "Call this tool exactly once per user.message carrying new evidence. "
        "Set revision_warranted=true only if new_hypothesis differs from the current "
        "hypothesis in summary, reasoning, or confidence. Set support_type to one of "
        "'supports', 'contradicts', 'extends', 'unrelated', 'ambiguous' — pick "
        "'unrelated' when the new evidence does not belong to this case and a split "
        "should be triggered downstream. Confidence values must be in [0.0, 1.0]. "
        "See skills/ir-playbook/case-lifecycle.md for per-value discipline."
    ),
    "input_schema": _build_revision_schema(),  # reuse existing helper from case_engine.py:69
}
```

`_build_revision_schema()` is already shaped for the SDK's live-beta constraints (no `oneOf`, no `min/max` on numbers, dict-maps rewritten as array-of-pairs) — see commit 36863d6 + MEMORY.md 2026-04-22 entry. The same schema lifts unchanged into the custom tool's `input_schema`. Pydantic `RevisionResult.model_validate(payload)` is the validator on receipt.

**Why this shape works without forced tool_choice:** system prompt tells the agent "the tool is the only valid output path"; the tool description repeats it; the user.message instruction concludes with it. Across three reinforcement sites, the agent reliably complies. If it doesn't (test during live smoke), fall back to parsing the agent.message text block for embedded JSON as a secondary path before erroring.

## 9. Session lifecycle (Q1+Q2 concrete)

```
          ┌──────────────────────────────────────────────────────────────┐
          │                   curator process_report()                    │
          └──────────────────────┬───────────────────────────────────────┘
                                 │
               first report?     │     Nth report on existing case?
                                 │
             ┌───────────────────┼────────────────────────┐
             ▼                                            ▼
   [unchanged Day-2 path]                   session_runner.revise_via_session()
   - hunters run                                          │
   - evidence written                                     │
   - _open_case() deterministic hypothesis                │
   - no session opened                                    │
             │                                            │
             │                     ┌──────────────────────┴───┐
             │                     │ BL_CURATOR_SESSION_ID?    │
             │                     └────┬──────────────────┬───┘
             │                 yes → idle?                 no
             │                    │                        │
             │             ┌──────┴──────┐                 │
             │          reuse          closed/terminated   │
             │             │              └────┬───────────┘
             │             │                   ▼
             │             │        client.beta.sessions.create(agent, env, title=...)
             │             │        persist new session_id → .secrets/env (append)
             │             │                   │
             │             └───────────────────┤
             │                                 ▼
             │               stream = client.beta.sessions.events.stream(sid)
             │               client.beta.sessions.events.send(sid, [user.message])
             │                                 │
             │                  ┌──────────────┴─────────────────┐
             │                  │ consume events until idle       │
             │                  │   agent.message      → log       │
             │                  │   agent.thinking     → log       │
             │                  │   agent.custom_tool_use →        │
             │                  │     validate payload via         │
             │                  │     RevisionResult.model_validate│
             │                  │     send user.custom_tool_result │
             │                  │   session.status_idle → break   │
             │                  │   session.status_terminated → raise│
             │                  └──────────────┬─────────────────┘
             │                                 ▼
             │                    RevisionResult returned
             │                    (or SessionProtocolError raised
             │                     — orchestrator falls back to
             │                     direct revise() if BL_USE_MANAGED_SESSION_FALLBACK=1)
             │                                 │
             └─────────────────────────────────┤
                                               ▼
                          apply_revision(prior_case, result, trigger)
                              (unchanged case_engine logic)
                                               │
                                               ▼
                                    updated case YAML written
```

**Session drop recovery:** On `session.status_terminated` OR `ConnectionError` on the stream, the runner catches, logs, and re-creates a new session for the next report. The new session's conversation history is empty — so the first user.message after recovery has to include the full prior-case YAML in the envelope (which it already does per §7). Continuity is preserved via the YAML payload, not via session memory.

## 10. State migration (Q7 concrete)

**Nothing moves.** `curator/storage/` stays on the host filesystem:
- `curator/storage/cases/CASE-*.yaml` — written by orchestrator after `apply_revision()` returns.
- `curator/storage/evidence.db` — written by orchestrator after `insert_evidence()`.
- `curator/storage/manifest.yaml[.sha256]` — written by synthesize CLI (unchanged; out-of-session).

**Why not move storage into the agent's cloud env:** the env is ephemeral (container lifecycle tied to session runtime); our case YAMLs must survive `docker compose down -v` cycles during demo prep; test isolation requires `BL_STORAGE=tmp_path`-style override which only works on host filesystem.

**What the agent DOES have in-env:** nothing we rely on. The `agent_toolset_20260401` bundle (bash, read, write, edit, glob, grep, web_fetch, web_search) is a capability reserve for post-MVW expansion (e.g., Full Wiring lets the agent grep its own skills bundle). For MVW, the agent receives structured input and emits structured output via the custom tool — no file I/O in the env.

**Reviewer S4 pushback — subprocess-invoked synthesize must not touch the session.** `demo/time_compression.py:106` subprocess-forks `python -m curator.synthesize` between beats; the child process inherits `BL_CURATOR_SESSION_ID`. If `curator.synthesize` ever opens or sends to the same session, two processes share one session → protocol violation. MVW scope explicitly forbids this. Enforcement:
- Spec §15 verification grep #9: `grep -n 'beta\.sessions' curator/synthesize.py` → expect **0 matches**.
- Spec §15 verification grep #10: `grep -n 'BL_CURATOR_SESSION_ID' curator/synthesize.py` → expect **0 matches**.
- Sentinel P9 must cite both greps in its verdict.

## 11. Test strategy (Q8 concrete)

**Live-vs-stub path map:**

| Test surface | Live path | Stub path |
|--------------|-----------|-----------|
| `test_revision.py` (existing 18 tests) | N/A — all gated on `BL_SKIP_LIVE=1` | ✅ already works; `_stub_result` unchanged |
| `test_orchestrator_smoke.py` (second-report scenarios) | N/A | ✅ must still pass; set `BL_USE_MANAGED_SESSION=0` in these tests to force the direct path (keeps existing mock strategy valid) |
| `test_session_runner.py` **NEW** | N/A | ✅ mocks `anthropic.Anthropic().beta.sessions.events.stream()` via `tests/_session_mock.py`; tests happy path + session-reuse + protocol errors |
| `work-output/revision-live-smoke.py` (existing) | ✅ runs direct `revise()` against real Opus 4.7 | — |
| `work-output/session-live-smoke.py` **NEW** | ✅ runs `session_runner.revise_via_session()` against real Opus 4.7 + agent + env + session; ≤$1 spend per run | — |
| `demo/time_compression.py --mode=live` (P43) | ✅ exercises session path end-to-end against real API for 4 beats; ≤$4 spend per full run | — |
| `demo/time_compression.py --mode=stub` | — | ✅ BL_USE_MANAGED_SESSION unaffected; `_stub_result` in case_engine still serves (session_runner detects `BL_SKIP_LIVE=1` and returns same stub without opening a session) |

**Mock adapter pattern (shared):**

```python
# tests/_session_mock.py
@contextmanager
def mock_session_run(*, revision_payload: dict, extra_events: list = ()):
    """Patch anthropic.Anthropic().beta.* for one session_runner invocation.

    revision_payload: dict matching RevisionResult json schema — emitted as
        agent.custom_tool_use event with tool_use_id="tu-stub-1".
    extra_events: any additional events to splice before the custom_tool_use
        (e.g., agent.thinking summaries, agent.message preamble).
    """
    events = [
        _build_agent_message("Analyzing new evidence against prior hypothesis..."),
        *extra_events,
        _build_custom_tool_use("tu-stub-1", "report_case_revision", revision_payload),
        _build_session_idle("end_turn"),
    ]
    with patch("anthropic.Anthropic") as mock_cls:
        mock_cls.return_value = _build_mock_client(events=events)
        yield
```

**Regression preservation:** `test_orchestrator_smoke.py::test_second_report_triggers_revision` (line 259) is the canary — it must remain green with `BL_USE_MANAGED_SESSION=0` forced via monkeypatch. A second test scenario with `BL_USE_MANAGED_SESSION=1` + `mock_session_run` exercises the new path.

## 12. Edge cases (covered by spec, planner must map to phases)

| # | Case | Coverage |
|---|------|----------|
| E1 | Session creation fails (network / 429 / 5xx) | `session_runner` catches, logs, raises `SessionProtocolError`; orchestrator catches and falls back to direct `revise()` if `BL_USE_MANAGED_SESSION_FALLBACK=1` (default). Soft-fail exit unchanged. |
| E2 | `session.status_terminated` mid-stream | Runner catches, invalidates `BL_CURATOR_SESSION_ID`, re-opens a new session for the next call. Current call raises if no custom tool fired before terminate. |
| E3 | Agent emits `agent.message` text instead of calling `report_case_revision` | Runner inspects accumulated agent.message text for embedded `{...}` JSON; if one parses as `RevisionResult`, accept it with a WARN log. Otherwise raise. (Fallback path, not the default.) |
| E4 | Custom tool payload fails pydantic validation | Runner sends `user.custom_tool_result` with `{"content": [{"type": "text", "text": "<pydantic error>"}], "is_error": true}`; agent may retry. After 2 retries raise `SessionProtocolError`. |
| E5 | Session drops + reopens mid-sim (mid `time_compression` run) | §9 drop-recovery: new session gets full case YAML in the next user.message; no state loss. |
| E6 | `BL_CURATOR_AGENT_ID` not set / agent archived | `agent_setup` idempotently creates or updates; orchestrator bails with a clear "run `python -m curator.agent_setup` first" message (not a silent session.create failure). |
| E7 | Schema mismatch between `report_case_revision.input_schema` and `RevisionResult` pydantic model | `agent_setup` runs a round-trip probe (build schema → sample payload → pydantic validate) at agent-create time; refuses to create the agent on mismatch. |
| E8 | Two concurrent `process_report` calls on the same session | Session is single-threaded at Anthropic; the second send() blocks until the first idle. Orchestrator must serialize — add an `asyncio.Lock` on the session runner (single-process assumption OK for hackathon; cross-process = don't). |
| E9 | `BL_SKIP_LIVE=1` set | Runner short-circuits before opening any session — delegates to `case_engine._stub_result(case, rows)` and returns. No API traffic. |
| E10 | `BL_STUB_UNRELATED_HOST=host-5` set (demo sim day-14) | Stub path covers this exactly as today (split-branch returns `support_type="unrelated"`); session path does NOT need to implement — Mode=stub is the only mode that drives this beat in the sim. |
| E11 | Custom-tool schema SDK-beta rejects an edge construct | Live probe at `agent_setup` time surfaces the rejection; fallback to the current `_build_revision_schema` (already patched for the 36863d6 constraints). If a new constraint surfaces, document and adapt. |

## 13. Risk register + rollback triggers

| Risk | Severity | Trigger | Action |
|------|----------|---------|--------|
| Custom tool not invoked (agent replies with plain text) | MED | Live smoke at Phase 5 shows agent never calls `report_case_revision` across 3 attempts | (a) Strengthen system prompt with "MUST use the tool" + few-shot example of tool input; (b) if still flaky, accept E3 JSON-in-text fallback; (c) if unreliable, flip `BL_USE_MANAGED_SESSION=0` and ship Option 2 (softened README). |
| Session cost overruns budget | LOW | Live smoke + P43 full run exceeds $15 aggregate | Burn is mostly token-side; runtime at $0.08/session-hour is negligible for our use. Cap: close session before exit via `sessions.archive()`. |
| Opus 4.7 adaptive-thinking silently off inside sessions | MED | `agent.thinking` events never fire during live smoke | Check SDK docs for explicit thinking configuration (may require model object `{id, thinking: {...}}`); if no knob exists, accept the loss and note in README "Why these models" — the Opus 4.7 choice still earns on reasoning quality, just without explicit per-call depth control. |
| Test flake from mock SDK drift | LOW | `tests/_session_mock.py` fixtures don't match real event shapes after an SDK update | Live smoke is the truth-tester; if mocks diverge from reality, update mocks to match real recorded event samples. |
| MVW ships but demo pacing wrong | MED | First Saturday recording (P43) shows the session path takes >>current ~7s per revise call | (a) Current Opus 4.7 revise is ~7s; session overhead adds ~1-2s for session.create/reuse + event stream open; acceptable. (b) If >>15s, narrative adaptation: add a visible "curator session active ✓" banner at demo start and accept a longer think-pause as a feature (adaptive thinking visible on screen). |
| Blow past Friday 22:00 CT cut line | HIGH | MVW not green on live smoke by Friday 22:00 CT | Immediate rollback: `git revert` the session-wiring commits; flip branch back to `main@085caa0-era`; ship Option 2 — soften README to remove the "runs inside a session" claim entirely. **Option 2 forfeits the $5k Managed Agents special prize** — it is a retreat, not a soft rebrand. Grand-prize Depth 20% remains defensible because the case engine, skills bundle, and demo all still ship. Do not mislabel Option 2 as "preserves prize contention at softer framing" — it does not. |
| Custom-tool invocation reliability below MVW bar | HIGH | P0 spike shows <4/5 direct `report_case_revision` invocations on live Opus 4.7 | Abort MVW **before** any implementation commits land. Ship Option 2 Thursday 22:00 instead of Friday 22:00 — 24h earlier cut. Spec §4 M2 fix. |

**The cut line is not negotiable.** Saturday 18:00 CT recording is the prize-preservation gate. If Friday 22:00 finds MVW not green, the plan's rollback trigger fires — not a "one more attempt on Saturday morning" decision.

## 14. Effort estimate

| Phase | Est | Notes |
|-------|-----|-------|
| **P0: Custom-tool invocation reliability spike (M2 gate)** | **1.5h** | `work-output/session-tool-invocation-probe.py` — 5 live probes; records direct-invocation rate. Gate ≥4/5 to proceed. **Runs Thursday evening, before any other phase.** |
| P1: `agent_setup.py` + agent create/update with custom tool + skills + schema-roundtrip probe + probe-failure diagnostic runbook | 2h | Includes E7 schema-roundtrip validation and E6 operator-facing error paths (reviewer S5). |
| P2: `session_runner.py` core — open-or-reuse, send user.message, consume events, dispatch custom-tool events, validate via pydantic | 3h | The bulk of new code. |
| P3: Orchestrator wiring — split into `_revise_via_session()` + `_revise_direct()` helpers (not a flag-branch inside revise), `BL_USE_MANAGED_SESSION` selects | 1h | Reviewer S3 — two named code paths, independent test surface. |
| P4: Tests — `_session_mock.py` + `test_session_runner.py` + update `test_orchestrator_smoke.py` second-report tests (both paths) | 2.5h | Uses existing mock-at-SDK-boundary discipline. |
| P5: Live smoke + `work-output/session-live-smoke.py` + assertion that `agent.thinking` events fire (reviewer C2 + risk row 3) | 1h | Operator-runnable; $0.50-$1 spend per run. |
| P6: README exact-replacement text + HANDOFF footnote + MEMORY entry + demo/script.md session-active cue | 1h | M1 fix — exact text in §6.4, demo-visible session cue on revision beat. |
| P7: Dead-code cleanup (`stream_events`, `hunters/__init__.py` re-exports) — riding the commit range | 0.5h | Audit findings from session-start. |
| P8: P43 gate re-run inside curator container + commit marker + log inspection grep (C2 — assert "session opened" / "session reused" log lines fire) | 0.5h | Validates session-wired full flow against the demo. |
| P9: Sentinel review + fixup commits | 1-2h | Standard post-impl review. |
| **Total MVW (incl P0 spike)** | **~13h** | Reviewer pushback accepted: 11h → 13h was honest. |

**Schedule:**
- Thu 2026-04-23 evening 19:00-22:00: **P0 spike (M2 gate)**. Outcome decides MVW vs Option 2 — 24h earlier than original cut line.
- Thu 2026-04-23 22:00: **EARLY CUT LINE** — if P0 spike shows <4/5 direct tool invocations, abort MVW and ship Option 2 Friday morning instead. Spec is done either way.
- Fri 2026-04-24 08:00-20:00: P1-P5 (code + tests + live smoke).
- Fri 2026-04-24 22:00: **LATE CUT LINE** — MVW green on live smoke + demo-caption visible OR `git revert` + Option 2. Note: revert must be clean — reviewer S/E2 — plan uses a feature branch `mca-wiring` squash-merged at P9 so the revert is one commit.
- Sat 2026-04-25 morning: P6-P8 (docs + dead-code + P43 rerun).
- Sat 2026-04-25 18:00: Recording.
- Sat 2026-04-25 evening: P9 (sentinel).
- Sun 2026-04-26 morning: reshoot slot if needed.
- Sun 2026-04-26 16:00 EDT: submission.

**Feature branch isolation:** the plan uses a local branch `mca-wiring` off `main@085caa0` (or current HEAD at plan-start). All MVW commits land there; P9 squash-merges back to main. This keeps the rollback atomic (reviewer E2) — rollback = `git checkout main && git branch -D mca-wiring`. No P42/P43 commit history is disturbed.

## 15. Verification (sentinel greps)

The P9 sentinel must verify:

1. `grep -rn 'anthropic\.Anthropic\(\)\.messages\.create\|anthropic\.AsyncAnthropic\(\)\.messages\.create' curator/` → hunters + intent + synthesize present; revise absent from the hot path (`curator/case_engine.py::revise` remains as the `BL_USE_MANAGED_SESSION=0` / `BL_SKIP_LIVE=1` stub path).
2. `grep -rn 'client.beta.sessions' curator/` → `session_runner.py` is the only consumer.
3. README "Why this is a Managed Agent" section cites `curator/session_runner.py` and describes MVW accurately (not the Full Wiring aspiration).
4. `curator/managed_agents.py` — `stream_events()` removed; `Iterator` import removed; `create_curator_agent`, `create_fleet_environment`, `start_session`, `SessionHandle` all reachable from `curator/session_runner.py` or `curator/agent_setup.py`.
5. `BL_USE_MANAGED_SESSION` flag documented at default `1`; rollback via flag is a single env var flip.
6. No bare `messages.create()` inside `session_runner` — it uses sessions.events exclusively.
7. `tests/test_orchestrator_smoke.py::test_second_report_triggers_revision` remains green (via `BL_USE_MANAGED_SESSION=0` forced in the test). New session-path test green with mocked SDK.
8. (M1 fix) `grep -n 'curator/session_runner.py' README.md` → ≥1 match (explicit code pointer); `grep -c 'messages\.create' README.md` → 0 (README does not over-claim session coverage for intent/synthesize; the MVW boundary is described honestly).
9. (S4 fix) `grep -n 'beta\.sessions' curator/synthesize.py` → 0 matches.
10. (S4 fix) `grep -n 'BL_CURATOR_SESSION_ID' curator/synthesize.py` → 0 matches.
11. (C2 fix) **Runtime log inspection** on P43 full-sim run: `grep -E 'session (opened|reused)' /tmp/bl-day5-sim.log` → ≥1 match per revise beat (3 revise beats in the 4-beat arc: host-4 day-5, host-7 day-7, host-5 day-14 split path). Absence = cosmetic-claim failure mode (session API imported but never actually called at runtime).

## 16. Files touched (planner expands)

Full list (the plan phases will own these):

**New:**
- `curator/session_runner.py`
- `curator/agent_setup.py`
- `prompts/curator-agent.md`
- `tests/test_session_runner.py`
- `tests/_session_mock.py`
- `work-output/session-live-smoke.py`
- `work-output/session-tool-invocation-probe.py` (P0 spike script — M2 gate; deleted after P1 once the question is answered)
- `work-output/agent-setup-diagnostics.md` (P1 operator runbook — reviewer S5)

**Modified:**
- `curator/orchestrator.py` — split into `_revise_via_session()` + `_revise_direct()` helpers (reviewer S3)
- `curator/managed_agents.py` — delete `stream_events` + unused `Iterator` import; otherwise unchanged
- `curator/hunters/__init__.py` — reduce to docstring (dead-code audit finding B)
- `README.md` — exact replacement text in §6.4
- `demo/script.md` — runner-emitted session-active prefix on revision beat caption (M1 fix)
- `HANDOFF.md` — one-line footnote
- `MEMORY.md` — MVW decision + SDK-constraint findings entry
- `PLAN.md` — append P45-P46 (managed-agents wiring + sentinel)
- `FUTURE.md` — Full Wiring roadmap entry + delta-envelope post-MVW requirement (S1)

**Deleted:** none.

## 17. Non-goals

- Full Wiring (intent + synthesize into session) — post-hackathon roadmap.
- Changing hunters to session tool calls — violates Q4 parallelism decision.
- MCP server integration — Skills on the agent suffice for our domain context.
- Agent memory / outcomes / multi-agent (research-preview features) — out of scope.
- Agent auto-creation on every process_report — one-shot setup via `agent_setup.py`.
- Schema rewrite of `RevisionResult` — the existing `_build_revision_schema` lifts into the custom tool unchanged.

## 18. Sources (2026-04-23 fetches)

- [Managed Agents overview](https://platform.claude.com/docs/en/managed-agents/overview)
- [Managed Agents quickstart](https://platform.claude.com/docs/en/managed-agents/quickstart)
- [Agent setup](https://platform.claude.com/docs/en/managed-agents/agent-setup)
- [Tools (built-in + custom)](https://platform.claude.com/docs/en/managed-agents/tools)
- [Sessions](https://platform.claude.com/docs/en/managed-agents/sessions)
- [Events and streaming](https://platform.claude.com/docs/en/managed-agents/events-and-streaming)

Internal:
- `curator/orchestrator.py:227-335` — the revise path to wire.
- `curator/case_engine.py:288-370` — `revise()` + schema builder that lifts into the tool.
- `work-output/mca-roundtrip-probe.py` — proven session round-trip shape.
- `.secrets/env` (operator-local) — persistent agent/env IDs.
- MEMORY.md 2026-04-22 entries — Opus 4.7 `output_config` / `thinking` live-beta constraints.
