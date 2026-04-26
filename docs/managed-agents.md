# Anthropic Managed Agents — primitives reference

Authoritative reference for the Anthropic Managed Agents primitives used by blacklight.
Cross-references `DESIGN.md §3.4` (Primitives map) and `DESIGN.md §12` (model calls).
All live-beta API constraints reflect confirmed probe results from 2026-04-24 (see
`docs/setup-flow.md §8` for verbatim request/response logs).

---

## 1. Overview

Anthropic Managed Agents exposes four first-class workspace primitives accessible under
the `managed-agents-2026-04-01` beta header:

| Primitive | API surface | Description |
|-----------|-------------|-------------|
| **Memory Store** | `/v1/memory_stores` | Mutable agent-written key-value store; 100 KB per file; 30-day `memver_` audit trail |
| **Files** | `/v1/files` | Read-only binary/text blobs; hot-attachable to sessions; no TTL |
| **Skills** | `/v1/skills` | Description-routed, lazy-loaded behavior modules; ≤1024-char description; ≤500-line body |
| **Sessions** | `/v1/sessions` | Stateful reasoning context; agent + env + resources (Files + Memory Stores + Skills) |

blacklight uses all four. Each primitive's role is described in §2–§5. Path C mapping is in §11.

---

## 2. Memory Store

Working memory for the curator agent across an investigation.

- **Create:** `POST /v1/memory_stores` `{"name": "bl-case"}`
- **Write (agent):** agent invokes memstore tool; `POST /v1/memory_stores/<id>/memories` from
  the wrapper for bootstrap writes
- **Read:** `GET /v1/memory_stores/<id>/memories?path_prefix=<prefix>` (leading-slash paths)
- **Delete:** `DELETE /v1/memory_stores/<id>/memories/<mem-id>` (no PATCH with sha256 in
  `managed-agents-2026-04-01` — last-write-wins via DELETE+POST)
- **Audit:** `memver_` versioning provides 30-day immutable revision history; operator can
  reconstruct hypothesis revision chain from `GET /v1/memory_stores/<id>/memories?path=<path>`
  `X-Memver-At` header
- **Cap:** 100 KB per file; 8 memory stores per session (blacklight uses 1 of 8 in Path C)
- **Access control:** set at attachment time via `resources[]` — `read_only` or `read_write`;
  the store itself carries no global access mode

**Path C:** `bl-case` is the single memstore (read_write). `bl-skills` memstore is retired —
skill content lives in Skills primitives. See §4 and §11.

---

## 3. Files

Immutable blob store for evidence bundles, shell samples, and closed-case briefs.

- **Upload:** `POST /v1/files` multipart form (`file` field + `purpose: assistants`)
- **List:** `GET /v1/files` (no filtering by path; client-side filter by metadata)
- **Delete:** `DELETE /v1/files/<file-id>` (idempotent; 404 → success)
- **Pricing:** storage ops free; content billed only when referenced in a session message
- **TTL:** none — files persist until explicitly deleted
- **Cap:** 500 MB per workspace (beta limit; subject to change)
- **Per-session cap:** 100 files per session via `resources[]`
- **Hot-attach:** `POST /v1/sessions/<sid>/resources` `{"type":"file","file_id":"<id>"}` —
  files can be mounted and unmounted mid-session without restarting

**Path C:** evidence bundles (`/case/<id>/raw/<source>.jsonl`), corpus files (routing-skill
corpora + foundations), and closed-case briefs are all stored as Files. See §11.

---

## 4. Skills

Description-routed, lazy-loaded behavior modules authored from operator knowledge.

- **Create:** `POST /v1/skills` `{"name": "<slug>", "description": "<≤1024 chars>", "body": "<≤500 lines>"}`
- **Version:** `POST /v1/skills/<id>/versions` creates a new immutable version; returns
  `{"version": "<version-string>"}`
- **List:** `GET /v1/skills` returns `{data: [{id, name, version}]}`
- **Get:** `GET /v1/skills/<id>` (by id) or `GET /v1/skills?name=<name>` (by name, client-side filter)
- **Delete:** `DELETE /v1/skills/<id>` removes the skill record
- **Routing:** the agent selects which skills to invoke based on description matching — no
  explicit tool_call required. Skills are lazy-loaded; only invoked when the description
  matches the agent's current reasoning need
- **Description cap:** 1024 characters (hard limit)
- **Body cap:** 500 lines (recommended; platform may enforce at a higher limit)
- **Attachment:** skills are attached at session creation via `resources[]` `{"type":"skill","skill_id":"<id>"}`;
  they cannot be hot-swapped mid-session (unlike Files)

**Path C:** 6 routing Skills cover the curator's primary reasoning modes. See §11.

---

## 5. Sessions

Stateful reasoning context that ties together agent, environment, and resources.

- **Create:** `POST /v1/sessions` `{"agent_id": "<id>", "environment_id": "<id>", "resources": [...]}`
- **Wake:** `POST /v1/sessions/<sid>/events` `{"type": "user.message", "content": "<msg>"}`
- **Poll:** `GET /v1/sessions/<sid>/events?after=<event-id>` for the SSE stream
- **Resources add:** `POST /v1/sessions/<sid>/resources` (hot-attach Files mid-session)
- **Resources remove:** `DELETE /v1/sessions/<sid>/resources/<resource-id>` (detach Files on case close)
- **Resume:** sessions are resumable within the 30-day checkpoint window; same `session_id`
  picks up where the last turn ended
- **Resources at create:** `resources[]` accepts `{type:"memory_store", memory_store_id}`,
  `{type:"file", file_id}`, `{type:"skill", skill_id}`, `{type:"environment", environment_id}`

---

## 6. Caps summary

| Primitive | Cap | Source |
|-----------|-----|--------|
| Memory Store files | 100 KB each | Platform spec |
| Memory Stores per session | 8 | Platform spec |
| Files per session | 100 | Beta limit |
| Files workspace total | 500 MB | Beta limit |
| Skill description | 1024 chars | Enforced at create/update |
| Skill body | 500 lines | Recommended; authoring discipline |

---

## 7. Required beta headers

Every managed-agents call requires both headers:

```
anthropic-version: 2023-06-01
anthropic-beta: managed-agents-2026-04-01
```

Files API additionally requires:

```
anthropic-beta: files-api-2025-04-14
```

`anthropic-version` alone (without the beta flag) returns 400 on Managed Agents endpoints.
The beta flags cannot be combined with `agent-api-*` or `agent-memory-*` values (see
`docs/setup-flow.md §8.4` probe note on beta-flag incompatibility).

---

## 8. SDK references

blacklight uses the raw Anthropic REST API via `curl` — no SDK. All endpoints are
documented at https://docs.anthropic.com/en/api/managed-agents (beta).

Relevant API shapes confirmed against the `managed-agents-2026-04-01` beta:

- `POST /v1/agents` — body MUST NOT include `thinking` or `output_config` (HTTP 400)
- `tools[].input_schema` — MUST NOT include `additionalProperties` or per-field `description`
- `tools[].description` — required on every custom tool (400 if omitted)
- Memory store paths use leading-slash form (`/case/...`); `?path_prefix=` query parameter
  uses the same leading-slash form
- Session cleanup: `POST /v1/agents/<id>/archive` (DELETE is incompatible with managed-agents beta)

See `docs/setup-flow.md §8` for verbatim probe logs.

---

## 9. Agent-create constraint matrix

| Field | At `agents.create` | At session creation |
|-------|-------------------|---------------------|
| `model` | Required | N/A |
| `system` | Required | N/A |
| `tools[]` | Required (≥1: agent_toolset) | N/A |
| `thinking` | Rejected (HTTP 400) | N/A |
| `output_config` | Rejected (HTTP 400) | N/A |
| `input_schema.additionalProperties` | Rejected (HTTP 400) | N/A |
| `input_schema.properties.<field>.description` | Rejected (HTTP 400) | N/A |
| `resources[]` | Not applicable | Where Skills + Files + Memory Stores attach |

---

## 10. Memory Store path schema (Path C)

After M13 migration, the `bl-case` memstore holds only curator working memory:

```
/case/<YYYY>-<NNNN>/hypothesis.md
/case/<YYYY>-<NNNN>/history/<ISO-ts>.md
/case/<YYYY>-<NNNN>/attribution.md
/case/<YYYY>-<NNNN>/ip-clusters.md
/case/<YYYY>-<NNNN>/url-patterns.md
/case/<YYYY>-<NNNN>/file-patterns.md
/case/<YYYY>-<NNNN>/open-questions.md
/case/<YYYY>-<NNNN>/pending/<step-id>.json
/case/<YYYY>-<NNNN>/results/<step-id>.json
/case/<YYYY>-<NNNN>/actions/pending/<act-id>.json
/case/<YYYY>-<NNNN>/actions/applied/<act-id>.json
/case/<YYYY>-<NNNN>/actions/retired/<act-id>.json
/case/<YYYY>-<NNNN>/defense-hits.md
/case/<YYYY>-<NNNN>/closed.md
/INDEX.md
```

Raw evidence blobs and corpus files are in the Files API (§11), not the memstore.

---

## 11. Path C primitives map

How blacklight uses each Anthropic primitive in Path C (M13 Skills realignment):

| Primitive | blacklight usage | State key in `state.json` | Lifecycle |
|-----------|-----------------|--------------------------|-----------|
| **Memory Store** (`bl-case`) | Hypothesis + steps + actions + working memory | `case_memstores._legacy` | Created once at `bl setup`; lives for the workspace lifetime |
| **Files** (workspace corpus) | Skill corpus files (foundations + 6 corpora + substrate-context) | `files.<slug>.file_id` | Uploaded at `bl setup`; replaced on `bl setup --sync` (old ID → `files_pending_deletion`) |
| **Files** (per-case evidence) | Raw observation bundles + closed-case briefs | `case_files.<case-id>.<path>.workspace_file_id` | Uploaded at `bl observe` (on rotate); detached at `bl case close`; deleted by `bl setup --gc` |
| **Skills** (routing) | 6 operator-voice behavior modules description-routed by curator | `agent.skill_versions.<slug>` | Created at `bl setup`; versioned on `bl setup --sync` when body changes |
| **Sessions** | Per-case curator reasoning context (Opus 4.7, 1M context) | `session_ids.<case-id>` | Created at `bl consult --new`; resumed on `bl consult --attach`; resources detached at `bl case close` |

Cross-references: `DESIGN.md §3.4` (Primitives map), `docs/case-layout.md §11` (evidence path convention), `docs/setup-flow.md §4` (Path C verbs).
