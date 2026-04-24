# `bl setup` — API call sequence spec

Authoritative call shape for `bl setup`. Describes which Anthropic API endpoints the bootstrap hits, in what order, with which headers + request bodies, and how idempotency is enforced. Narrative companion is `DESIGN.md §8` — this file is authoritative for the wire shape. `DESIGN.md §8` edits that disagree with this file are bugs.

---

## 1. Purpose

One-time (per Anthropic workspace) bootstrap. After `bl setup` completes on host 1, every subsequent host running `bl` against the same `ANTHROPIC_API_KEY` finds the workspace pre-seeded and skips the create path entirely (the preflight GET in §3 cache-hits). Re-runs are safe by contract (§5).

Outputs:
- 1 agent record (`bl-curator`) with the three custom tools mounted
- 1 environment record (`bl-curator-env`) with Apache + mod_security + YARA + jq + zstd + duckdb
- 2 memory stores (`bl-skills` read-only + `bl-case` read-write) seeded
- Local state cached at `/var/lib/bl/state/{agent-id,env-id,memstore-skills-id,memstore-case-id}`
- Operator-facing `export BL_READY=1` export line printed

---

## 2. Preconditions

- `ANTHROPIC_API_KEY` exported; 108-char key format (verified len check OK, actual format unchecked — first API call surfaces key-shape errors as exit 65).
- `curl` available (any version supporting `-sS`, `-w`, `-X`; essentially any curl since 2003).
- `jq` available (1.5+).
- Bash 4.1+ (`bl` floor; CentOS 6 era minimum).
- `/var/lib/bl/` writable by the invoking user (host-root or user with directory permission).
- `$BL_REPO_URL` optional (DESIGN.md §8.3 discovery order 2); defaults to public GitHub clone.

No TLS cert pinning beyond what `curl` + host OS certificate store provides. No mTLS. No service account. Sole secret = `ANTHROPIC_API_KEY`.

---

## 3. Happy path sequence

Six ordered steps. Each is idempotent — §5 covers re-invocation safety.

1. **Discover skill source** (`DESIGN.md §8.3` order: cwd `skills/` → `$BL_REPO_URL` clone → default clone).
2. **Preflight** — `GET /v1/agents?name=bl-curator`. If result list non-empty → cache the agent id to `/var/lib/bl/state/agent-id`, skip to step 5 (memstore probe). If empty → proceed to step 3.
3. **Create agent** — `POST /v1/agents` (§4.2). Capture the returned `id`; write to `/var/lib/bl/state/agent-id`.
4. **Create environment** — `POST /v1/environments` (§4.3). Capture `id`; write to `/var/lib/bl/state/env-id`.
5. **Probe + create memory stores** — `GET /v1/memory_stores?name=bl-skills` + `GET /v1/memory_stores?name=bl-case`; for each that returns empty → `POST /v1/memory_stores` (§4.4). Capture ids to `/var/lib/bl/state/memstore-{skills,case}-id`.
6. **Seed skills** — iterate `skills/**/*.md`, for each: `POST /v1/memory_stores/<skills-id>/memories` (§4.5). Compute sha256 per file; collect into `bl-skills/MANIFEST.json` (written via memstore) for delta detection on `bl setup --sync`.
7. **Print exports** — emit `export BL_READY=1` to stdout; operator sources their shell or adds to `.bashrc`.

---

## 4. Per-call specification

Standard request headers for every call (derived from Phase 1 probe at §8; absent `anthropic-version` causes 400 on otherwise-valid bodies — see §8.4):

```
x-api-key: $ANTHROPIC_API_KEY
anthropic-version: 2023-06-01
anthropic-beta: managed-agents-2026-04-01
content-type: application/json
```

### 4.1 Preflight — `GET /v1/agents?name=bl-curator`

- Method: `GET`
- Query: `name=bl-curator` (partial-match filter per observed beta behavior — see §8 note under 8.4; exact-match may not work, verify with a second filter)
- Body: (none)
- Success (200): response `.data[]` — 0 matches means proceed to create; 1+ means extract `.data[0].id`, cache, skip-create.
- Failure (401/403): bad or missing API key → exit 65 `PREFLIGHT_FAIL`.
- Failure (429): rate limited → exit 70 `RATE_LIMITED`; caller queues via `/var/lib/bl/outbox/` and retries with exponential backoff 2s/5s/10s/30s.
- Failure (5xx): upstream → exit 69 `UPSTREAM_ERROR` after 3 retries.

### 4.2 Create agent — `POST /v1/agents`

- Method: `POST`
- Body (minimum viable, per DESIGN.md §12.1 + Phase 1 probes):

```json
{
  "name": "bl-curator",
  "model": "claude-opus-4-7",
  "system": "<contents of prompts/curator-agent.md — see §6>",
  "tools": [
    {"type": "agent_toolset_20260401"},
    {
      "type": "custom",
      "name": "report_step",
      "description": "Emit a proposed blacklight wrapper action. One call per step.",
      "input_schema": "<schemas/step.json with $schema/$id/title stripped>"
    },
    {
      "type": "custom",
      "name": "synthesize_defense",
      "description": "Propose a defensive payload for this case.",
      "input_schema": "<schemas/defense.json — stub until M6>"
    },
    {
      "type": "custom",
      "name": "reconstruct_intent",
      "description": "Walk obfuscation layers of a mounted shell sample.",
      "input_schema": "<schemas/intent.json — stub until M5>"
    }
  ]
}
```

Body MUST NOT include:
- `thinking` (rejected, §8.1)
- `output_config` (rejected, §8.2)
- `tools[].input_schema.additionalProperties` (rejected, §8.3)
- per-field `description` inside `tools[].input_schema.properties.<field>` (rejected by observation at §8.3; wrapper must strip at submit time)

Body MUST include:
- `tools[<custom>].description` — the custom tool's top-level description is **required**; a custom tool without it returns `400 "tools.1.description: Field required"` (discovered during Phase 1 probe authoring; see §8 provenance note under 8.4).

Body MAY include:
- `tools[<custom>].input_schema.properties.<field>.type` as a type-array union `["string", "null"]` — accepted, §8.4 confirms. Wrapper emits `diff` and `patch` fields with this shape in `schemas/step.json`.

- Success (200/201): response carries `id`. Persist to `/var/lib/bl/state/agent-id`.
- Failure (400 `invalid_request_error`): body-shape rejection — error message names the offending field. Surface to operator; exit 65 `PREFLIGHT_FAIL`.
- Failure (409 `already_exists`): name collision (another run raced ahead). Re-run preflight; proceed.

### 4.3 Create environment — `POST /v1/environments`

- Method: `POST`
- Body:

```json
{
  "name": "bl-curator-env",
  "type": "cloud",
  "packages": {
    "apt": ["apache2", "libapache2-mod-security2", "modsecurity-crs", "yara", "jq", "zstd", "duckdb"]
  },
  "networking": {"type": "unrestricted"}
}
```

`networking.type: unrestricted` is required at env creation for apt to reach its mirror. Sessions subsequently attached to this env can use `limited` networking without re-creating the env (per DESIGN.md §8.2 item 2).

- Success: persist `id` to `/var/lib/bl/state/env-id`.
- Failure modes: identical to §4.2.

### 4.4 Create memory stores — `POST /v1/memory_stores`

One call per store. Shape:

```json
{"name": "bl-skills"}
```

```json
{"name": "bl-case"}
```

Both are minimal. Access control is set when the memory store is **attached** to a session/agent via `resources[]` — the store itself carries no global access mode.

- Success: persist ids to `/var/lib/bl/state/memstore-{skills,case}-id`.
- Failure: §4.2.

### 4.5 Seed skills — `POST /v1/memory_stores/<skills-id>/memories`

One call per `skills/**/*.md` file. Body per Memories API contract:

```json
{
  "key": "<relative path, e.g., 'ir-playbook/case-lifecycle.md'>",
  "content": "<file content as string>",
  "metadata": {"sha256": "<hex>"}
}
```

After all files ingest, also write the skill manifest as a memory:

```json
{
  "key": "MANIFEST.json",
  "content": "<JSON array of {path, sha256} entries for all skills>",
  "metadata": {"generated_at": "<ISO-ts>"}
}
```

`bl setup --sync` (DESIGN.md §8.4) diffs local `skills/**/*.md` sha256 against the remote `MANIFEST.json` and issues per-file POST/PATCH/DELETE requests only for changed paths.

- Failure (413 payload too large): skill file >100 KB (platform cap). Split the file; flag in `open-questions.md` / skills-authoring checklist.
- Failure (429): rate limit; caller MUST throttle to ≤50 RPM (DESIGN.md §13.5) and queue via `/var/lib/bl/outbox/`.

### 4.6 Print exports

Stdout only. No API call. Contents:

```
export BL_READY=1
```

Operator pastes into their shell init. Future `bl` invocations source the cached state ids from `/var/lib/bl/state/` directly.

---

## 5. Idempotency contract

Every operation in §3 MUST be safely re-executable. Re-running `bl setup` on host 5 after host 1 already completed it produces a no-op summary:

- Step 2 preflight: agent-id returned; cached; steps 3–4 skipped.
- Step 5: each memstore GET probe hits; ids cached; no POST issued.
- Step 6: skill sha256s identical to remote MANIFEST.json; no memory writes.
- Step 7: exports printed regardless.

Strict-equals checks, not version-semantic compares: if a skill file's sha256 differs from remote → POST; if a new local file appears → POST; if a remote file has no local peer → DELETE (with operator opt-in via `bl setup --sync --prune`).

**Archiving on re-create collision:** if an operator runs `bl setup` in a workspace where a previous curator record exists but the operator wants a fresh agent (e.g., after DESIGN.md §12 shape changed), they can archive the old one via `POST /v1/agents/<id>/archive` (beta header `managed-agents-2026-04-01`). DELETE is not supported under the managed-agents beta; archive is the cleanup primitive. See §8 provenance note under probe cleanup.

---

## 6. Error envelope

Surfaced to operator on non-success. Mapping to `docs/exit-codes.md`:

| HTTP | bl exit | Cause | Operator message |
|------|---------|-------|------------------|
| 400 `invalid_request_error` | 65 | Body shape rejected | Error body carries the field name; wrapper prints `blacklight: setup: <field>: <message>` and bails |
| 401 / 403 | 65 | Bad or missing `x-api-key` | `blacklight: ANTHROPIC_API_KEY not accepted by API — verify key is active` |
| 404 (on preflight) | 66 | `WORKSPACE_NOT_SEEDED` | Printed by `bl_preflight()` with the full DESIGN.md §8.1 heredoc |
| 409 `already_exists` | 71 | Name collision on create | `blacklight: bl-curator agent already exists (id=<>); continuing with existing` |
| 413 | 65 | Skill file >100 KB | `blacklight: skills/<path> exceeds 100 KB memstore cap` |
| 429 | 70 | Rate limited | `blacklight: rate limited; queued to /var/lib/bl/outbox/<name>.json` |
| 5xx | 69 | Upstream error after 3 retries | `blacklight: upstream API error after 3 retries; try again in a few minutes` |

Exit code authority is `docs/exit-codes.md`. Any new code this doc needs becomes a two-file change.

---

## 7. Source-of-truth resolution

Reproduces DESIGN.md §8.3. `bl setup` discovers skill content in this order:

1. Current working directory has `skills/` and `prompts/` — use those.
2. `$BL_REPO_URL` set → shallow clone to `$XDG_CACHE_HOME/blacklight/repo`, use.
3. Default → `git clone https://github.com/rfxn/blacklight $XDG_CACHE_HOME/blacklight/repo`, use.

Three adoption paths: operator-from-clone, operator-from-fork, operator-from-quickstart.

---

## 8. Probe log (2026-04-24, confirmatory)

Four targeted POSTs against `/v1/agents` executed from `work-output/m0-probe.sh` on 2026-04-24. Verbatim request/response captured. `x-api-key` redacted; all other headers + body + response preserved.

### 8.1 `thinking` kwarg — rejection expected, rejection observed

```
POST https://api.anthropic.com/v1/agents
x-api-key: <REDACTED>
anthropic-version: 2023-06-01
anthropic-beta: managed-agents-2026-04-01
content-type: application/json

{"name":"bl-m0-probe-8-1","model":"claude-opus-4-7","system":"m0 probe","tools":[{"type":"agent_toolset_20260401"}],"thinking":{"type":"adaptive"}}

HTTP/1.1 400
{"type":"error","error":{"type":"invalid_request_error","message":"thinking: Extra inputs are not permitted"},"request_id":"req_011CaNJVVtgYm5QEVKDsVMtz"}

[verified 2026-04-24] 8.1 thinking kwarg reject expected
```

Conclusion: `thinking` is rejected at `agents.create`. Thinking is model-internal on Opus 4.7; not operator-configurable via this endpoint. DESIGN.md §12.1 line 671 correctly documents this.

### 8.2 `output_config` kwarg — rejection expected, rejection observed

```
POST https://api.anthropic.com/v1/agents
x-api-key: <REDACTED>
anthropic-version: 2023-06-01
anthropic-beta: managed-agents-2026-04-01
content-type: application/json

{"name":"bl-m0-probe-8-2","model":"claude-opus-4-7","system":"m0 probe","tools":[{"type":"agent_toolset_20260401"}],"output_config":{"effort":"high"}}

HTTP/1.1 400
{"type":"error","error":{"type":"invalid_request_error","message":"output_config: Extra inputs are not permitted"},"request_id":"req_011CaNJVWPBwiFeGyp2y7hgu"}

[verified 2026-04-24] 8.2 output_config kwarg reject expected
```

Conclusion: `output_config` is rejected at `agents.create`. Structured output ships through custom tools only — DESIGN.md §12.1 line 671 correctly documents this.

### 8.3 `input_schema.additionalProperties` — rejection expected, rejection observed

```
POST https://api.anthropic.com/v1/agents
x-api-key: <REDACTED>
anthropic-version: 2023-06-01
anthropic-beta: managed-agents-2026-04-01
content-type: application/json

{"name":"bl-m0-probe-8-3","model":"claude-opus-4-7","system":"m0 probe","tools":[{"type":"agent_toolset_20260401"},{"type":"custom","name":"probe_tool","description":"probe","input_schema":{"type":"object","additionalProperties":false,"properties":{"field_a":{"type":"string","description":"should be rejected"}}}}]}

HTTP/1.1 400
{"type":"error","error":{"type":"invalid_request_error","message":"tools.1.input_schema.additionalProperties: Extra inputs are not permitted"},"request_id":"req_011CaNJVWrDwLyn5JDqxUsfh"}

[verified 2026-04-24] 8.3 additionalProperties + description reject expected
```

Conclusion: `input_schema.additionalProperties` is rejected. Per-field `description` inside `input_schema.properties` was not independently evaluated in this probe (rejection fired on `additionalProperties` first), but DESIGN.md §12 historically documents it as rejected — and the probe agent's top-level custom tool carries a `description` field, so the top-level (as opposed to per-field) `description` IS accepted.

**Note:** custom tools REQUIRE a top-level `description` field. A probe without it (see `work-output/m0-probe-log.attempt1.txt` for forensics) returned `400 "tools.1.description: Field required"`. DESIGN.md §12 documents the custom tool shape; `bl setup` must supply `description` on every custom tool.

### 8.4 `input_schema` type-array union `["string", "null"]` — acceptance expected, acceptance observed

```
POST https://api.anthropic.com/v1/agents
x-api-key: <REDACTED>
anthropic-version: 2023-06-01
anthropic-beta: managed-agents-2026-04-01
content-type: application/json

{"name":"bl-m0-probe-8-4","model":"claude-opus-4-7","system":"m0 probe","tools":[{"type":"agent_toolset_20260401"},{"type":"custom","name":"probe_union","description":"probe for type-array union","input_schema":{"type":"object","properties":{"maybe":{"type":["string","null"]}},"required":["maybe"]}}]}

HTTP/1.1 200
{"archived_at":null,"created_at":"2026-04-24T08:44:58.752121Z","description":null,"id":"agent_011CaNJVXSwGTdtMoC2qjbQq","mcp_servers":[],"metadata":{},"model":{"id":"claude-opus-4-7","speed":"standard"},"name":"bl-m0-probe-8-4","skills":[],"system":"m0 probe","tools":[{"configs":[],"default_config":{"enabled":true,"permission_policy":{"type":"always_allow"}},"type":"agent_toolset_20260401"},{"description":"probe for type-array union","input_schema":{"properties":{"maybe":{"type":["string","null"]}},"required":["maybe"],"type":"object"},"name":"probe_union","type":"custom"}],"type":"agent","updated_at":"2026-04-24T08:44:58.752121Z","version":1}

[verified 2026-04-24] 8.4 type-array union accept/reject probe
```

Conclusion: type-array unions `["string", "null"]` are **accepted** inside `input_schema.properties.<field>.type`. DESIGN.md §12 line 673 correctly documents this. `schemas/step.json` `diff` and `patch` fields use this shape and require no change.

**Provenance note:** This probe required two correction passes during authoring, preserved for forensics in `work-output/m0-probe-log.attempt{1,2}.txt`:

- **attempt 1** omitted the custom tool's top-level `description` field; API rejected with `400 "tools.1.description: Field required"`. Lesson: top-level `description` is **required** on every custom tool — added to §4.2 contract and DESIGN.md §12 follow-up.
- **attempt 2** omitted the `anthropic-version` header; API rejected with `400 "anthropic-version: header is required"`. Lesson: both `anthropic-version` AND `anthropic-beta` are required (beta header alone is insufficient for managed-agents endpoints when the body is otherwise valid). Added to standard headers in §4.

Both lessons applied to the canonical probe log. The earlier rejections on 8.1/8.2/8.3 passed the header check by masking the missing version under body-validation short-circuits.

**Probe agent cleanup:** The agent created by 8.4 (`agent_011CaNJVXSwGTdtMoC2qjbQq`) was archived via `POST /v1/agents/<id>/archive` with the `managed-agents-2026-04-01` beta header. The `agent-api-2026-03-01` DELETE path is **incompatible** with `managed-agents-2026-04-01` — attempting to combine the beta flags returns `400 "anthropic-beta header cannot combine 'agent-api-*' or 'agent-memory-*' values with 'managed-agents-*' values"`. Archive (POST) is the cleanup primitive under managed-agents. Documented here for `bl setup`'s future deprecation path.

---

## 9. Delta vs DESIGN.md §12

No delta. All four probes confirm the `managed-agents-2026-04-01` create-time shape and `input_schema` subset documented in DESIGN.md §12 lines 671–673. `thinking` / `output_config` rejected at create (8.1, 8.2). `input_schema.additionalProperties` rejected inside custom tool schemas (8.3). Type-array unions accepted (8.4). No patch to DESIGN.md §12 or `schemas/step.json` required.

Supplementary findings (minor, memorialized in §4 + §5 + §8 rather than DESIGN.md):
- Custom tool top-level `description` is required (was implicit in DESIGN.md §12.1 tools array example but not called out as contract).
- `anthropic-version: 2023-06-01` header is required alongside `anthropic-beta: managed-agents-2026-04-01` when the body is otherwise valid.
- Agent cleanup is via `POST /v1/agents/<id>/archive`, not `DELETE /v1/agents/<id>` (managed-agents ↔ agent-api beta-flag incompatibility).

These are call-shape details the wrapper implements in `bl setup`; they do not change the underlying contract DESIGN.md §12 describes.

---

## 10. Change control

setup-flow.md is authoritative for **call shape** (endpoints, headers, body shapes, idempotency rules, error mapping). `DESIGN.md §8` is the narrative companion (why, adoption paths, operator experience). Any drift is a setup-flow.md bug — never a DESIGN.md bug.

Contract updates:
- API-surface change discovered in the wild → re-run `work-output/m0-probe.sh` → update §4 + §8 in one commit.
- DESIGN.md §8 text change affecting call shape → update setup-flow.md in the same commit; reviewer flags drift.
- Exit-code additions touched here → also update `docs/exit-codes.md` in the same commit.
- Memory-store endpoint changes → also update `docs/case-layout.md` if path contracts shift.

Probe log (§8) is append-only across revisions — future confirmatory probes add §8.5, §8.6, etc., preserving prior findings as dated forensic evidence.
