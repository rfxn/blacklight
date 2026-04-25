# Live-trace placeholder — CASE-2026-DEMO

> **Status:** operator-run capture pending. This file ships as a placeholder
> so the demo video and the README cross-references resolve. The actual
> captured trace will be appended below before the M11 release tag.

## What this file will hold

A redacted round-trip trace of `bl setup` + `bl consult --new` against the
operator's real Anthropic workspace. Captured against the pinned production
build (M11 HEAD). Three log groups:

1. **Setup trace** (`bl setup` output): agent + env + memstore creation
   confirmations; `agent_id` / `session_id` printed; preflight idempotency
   check against subsequent `bl --check` runs.
2. **Consult trace** (`bl consult --new` output): case allocation (CASE-id),
   wake event POSTed to memstore, `bl_poll_pending` returns the curator's
   first emitted step, `report_step` custom-tool payload visible.
3. **Run trace** (`bl run --list` + `bl case show`): renders the pending
   step set with no execution; case directory tree + ledger entries shown.

## Redaction policy (per CLAUDE.md data fences)

Redacted:
- `sk-ant-...` → `sk-ant-REDACTED`
- Operator-host customer hostnames → `<redacted-host>`

Kept (workspace-scoped, safe to commit):
- `agent_id` (e.g. `agent_xyz123`)
- `session_id` / memstore `id` values
- `case_id`, step IDs
- Custom-tool emit payloads (`report_step`, `synthesize_defense`,
  `reconstruct_intent`)
- Timestamps

## What this proves (checklist — to be filled at capture time)

- [ ] Live API round-trip — POST `/v1/agents` returns 200 with seeded `agent_id`
- [ ] `report_step` custom-tool emit captured in raw form
- [ ] Memstore write observed (POST `/v1/memory_stores/<id>/memories`)
- [ ] Curator follows skills bundle — cite a specific skill the curator
      referenced in `reasoning` (e.g. `apsb25-94/indicators.md`)
- [ ] Sonnet 4.6 path exercised via `bl observe bundle`
- [ ] Haiku 4.5 FP-gate path exercised via `bl defend sig`
