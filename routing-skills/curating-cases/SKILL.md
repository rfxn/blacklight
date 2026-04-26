# curating-cases — Routing Skill

You are activated when the harness routes a case lifecycle request to this Skill.
Your purpose is to execute the open/close/reopen/hold state machine, maintain the
INDEX row for the case, and emit agentic-minutes blocks that give the operator a
structured status summary, next planned step, and a single blocking question. You do
not synthesize evidence cross-stream — that is synthesizing-evidence. You do not author
the final incident-commander brief — that is authoring-incident-briefs.

## Read order

Load in this sequence.

1. `/skills/foundations.md` — ir-playbook lifecycle rules and adversarial-content
   handling. Read once at session start.

2. `/skills/curating-cases-corpus.md` — the full case-lifecycle knowledge bundle:
   open/close/reopen/hold state machine rules, INDEX row schema, agentic-minutes
   format, case-close conditions, and the open-questions gate. This corpus is the
   authoritative reference for all lifecycle operations in this Skill.

3. `bl-case/INDEX.md` — the current case registry. Read before any lifecycle
   transition to verify the case exists and to check its current state.

4. `bl-case/CASE-<id>/hypothesis.md` — the working hypothesis. For close operations,
   verify the hypothesis has a final confidence entry before proceeding.

5. `bl-case/CASE-<id>/open-questions.md` — the close gate. Close is blocked while
   any line is unresolved. Every line must carry a `[RESOLVED: <evidence-id>]` marker
   before `case.close` can be emitted.

6. `bl-case/CASE-<id>/attribution.md` — kill-chain stanzas. For close, verify no
   stanza is empty (all must either carry evidence-cited prose or an explicit
   "no evidence observed" entry).

## Lifecycle state machine

```
                   ┌───────────────────────────────────────────────────┐
  (new)  ──open──► │  ACTIVE  │ ──hold──► │  HOLD  │ ──resume──► ACTIVE │
                   │          │ ◄──close── │        │                   │
                   │          │ ──close──► │CLOSED │                   │
                   │          │ ◄──reopen─ │        │                   │
                   └───────────────────────────────────────────────────┘
```

**Open** (`case.open`): write `bl-case/CASE-<id>/` directory tree, initialize
`hypothesis.md` (confidence: 0.0, narrative: "case opened — no evidence ingested"),
`open-questions.md` (header only), `attribution.md` (five empty stanzas), and
`bl-case/INDEX.md` row.

**Hold** (`case.hold`): write `bl-case/CASE-<id>/hold.md` with reason and ISO
timestamp. Update INDEX row status to `hold`. Future `bl consult --attach` calls see
the hold marker and emit an agentic-minutes block before resuming.

**Close** (`case.close`): allowed only when open-questions.md is empty of unresolved
entries AND all attribution stanzas are populated. Write
`bl-case/CASE-<id>/closed.md` with the timeline header and final confidence.
Update INDEX row status to `closed`. Trigger authoring-incident-briefs for the
final brief (separate Skill invocation).

**Reopen** (`case.reopen`): requires a `reason` field citing new evidence. Archive
`closed.md` to `history/<ISO-ts>-closed.md`. Reset status to `active` in INDEX.

## Agentic-minutes format

Emit after every lifecycle transition and on any `bl consult` turn where the
operator's next action is not determined by a pending step:

```
status: <active|hold|closed>
next: <one proposed wrapper action — e.g., "run observe.log_apache for the 6-hour window">
ask: <one blocking question — e.g., "confirm the retention window for access logs">
```

One `next`, one `ask`. Do not pad with multiple next-steps — the operator resolves one
question at a time. Emit as a `report_step` with `action: case.minutes`, not as free-
form prose.

## Output discipline

Writes from this Skill go to the case memory store and INDEX:

- `bl-case/INDEX.md` — update the row for the affected case on every state transition.
- `bl-case/CASE-<id>/open-questions.md` — append new blocking questions; mark
  resolved entries with `[RESOLVED: <evidence-id>]`.
- `bl-case/CASE-<id>/closed.md` — written on `case.close`; includes final timeline
  summary and confidence.
- `bl-case/CASE-<id>/hold.md` — written on `case.hold`.

Lifecycle actions go out as `report_step` emissions with the appropriate `action:`
field. Do not write lifecycle state directly to `hypothesis.md` — hypothesis is the
evidence narrative, not the state machine output.

## Anti-patterns

1. **Do not close a case with unresolved open-questions.** The open-questions gate
   exists precisely because cases are re-examined under new evidence. Premature close
   loses the open-question context, forcing a reopen with incomplete attribution.

2. **Do not emit multiple `ask` lines in one agentic-minutes block.** Multiple
   questions in one turn overwhelm the operator and make it impossible to resume the
   session from a single answer. One question, one turn.

3. **Do not write the final incident brief from this Skill.** The brief narrative is
   authoring-incident-briefs domain. Close writes `closed.md` (state) and triggers a
   separate Skill invocation for the brief.

4. **Do not skip the INDEX row update on state transitions.** A case whose state is
   `active` in INDEX but `closed` on disk produces stale query results for
   `bl case --list` and blocks the next operator session from reading the right state.

5. **Do not reopen a case without a cited evidence reason.** A bare `case.reopen` with
   no new evidence reason destroys audit traceability. The reason must reference a
   specific evidence ID or operator-supplied alert that motivated the reopen.
