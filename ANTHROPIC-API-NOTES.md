# Anthropic Managed Agents API — integration notes (operator log)

Concrete friction points hit while building blacklight against the
`managed-agents-2026-04-01` beta. Each entry is a real probe result, not
speculation. Useful to Anthropic as feedback; useful to a future blacklight
engineer to know what's a workaround vs. what's the real shape.

- Workspace probed: blacklight curator workspace (operator's API key).
- Probe window: 2026-04-24 → 2026-04-26.
- Reference: `docs/managed-agents.md` (primitives), `docs/setup-flow.md §8` (verbatim probe logs).

Severity scale:
- **BLOCKING** — cannot ship the dependent capability at all.
- **DEGRADED** — working workaround exists; ergonomics or fidelity suffer.
- **MINOR** — cosmetic, observability, or one-time discovery cost.

---

## 1. Environments — no package install at create  ·  DEGRADED

**Tried:** `POST /v1/environments` with `{name, type:"cloud", packages:{apt:[apache2, libapache2-mod-security2, modsecurity-crs, yara, jq, zstd, duckdb, pandoc, weasyprint]}, networking:{type:"unrestricted"}}`.

**Got:** HTTP 400 — `type`, `packages`, `networking` all rejected as "Extra inputs are not permitted". The accepted body is `{name, config:{type:"cloud", networking:{type:"unrestricted"|"package_managers_and_custom"}}}`. There is no `packages`, `setup_script`, `image`, or `init` field anywhere in the public surface.

**Workaround (current):** Curator system prompt drives `apt install` via the bash tool at session boot. `networking.type:"unrestricted"` is required so `apt` can reach mirrors. Cost: every fresh session pays the install latency before doing real work; per-session caching does not survive across sessions.

**Ideal:** A `config.setup_commands:[…]` or `config.image:"ghcr.io/.../bl-curator:0.4.0"` field, executed once at env-create and reused across all sessions bound to that env_id.

---

## 2. Skills — workspace allowlist gate  ·  DEGRADED

**Tried:** `POST /v1/skills` with `{name, description, body}` for the six routing skills. `OPTIONS /v1/skills` returns `Allow: POST`, suggesting the endpoint is alive.

**Got:** HTTP 404 on POST/GET against `/v1/skills` for our workspace. The endpoint exists per the OPTIONS reflector, but is gated to allowlisted workspaces.

**Workaround (current — Path C fallback in `bl_setup_seed_skills_as_files`):** Upload each `routing-skills/<name>/SKILL.md` as a workspace File at `/skills/<name>-skill.md`. Curator system prompt names the corpus paths explicitly. Loses Anthropic's description-routed skill selection — every "skill" is now visible as a static corpus file the agent has to choose from itself.

**Ideal:** Open the allowlist, OR document explicitly that workspaces self-serve allowlist via a flag/contact. The 404 (vs. a 403 with reason) makes it indistinguishable from "endpoint moved" during integration debugging.

---

## 3. Sessions — `events` wrapper recently required  ·  MINOR (resolved)

**Tried:** `POST /v1/sessions/<sid>/events` with body `{type:"user.message", content:[…]}` (matched older docs we had cached).

**Got:** HTTP 400 — `content: Extra inputs are not permitted`. Real shape is `{events:[{type:"user.message", content:[…]}]}`.

**Workaround:** Wrapped event payloads in `{events:[…]}` across `27-outbox.sh`, `50-consult.sh`, `60-run.sh`, `70-case.sh`.

**Note for Anthropic:** The bare-object form was working in the same workspace through M12 P5.5 (2026-04-25 — last live-trace harness run). The wrapper requirement surfaced 24 hours later during M15 P8 live integration smoke (2026-04-26) under the same `managed-agents-2026-04-01` beta header. The breakage is silent — same header, same endpoint, new shape. A schema-versioned beta header (`managed-agents-2026-04-01-events-v2`?) or deprecation lead time on shape changes would have cost less to integrate.

---

## 4. Sessions — `agent` not `agent_id`, `environment_id` required  ·  MINOR (resolved)

**Tried:** `POST /v1/sessions` with `{agent_id, resources:[…]}`.

**Got:** HTTP 400 — `agent_id: Extra inputs are not permitted. Did you mean 'agent'?` (this hint is genuinely helpful; thank you). Separately, `environment_id` is required — omitting it returns `environment_id: Field required` even if the workspace has only one env.

**Workaround:** Body is now `{agent, environment_id, resources}`. State persisted to `state.json .env_id`.

**Ideal:** If only one env exists in the workspace, default it server-side. Keeps the single-host-single-env case ergonomic.

---

## 5. Memory stores — no sha256 PATCH, no upsert  ·  DEGRADED

**Tried:** `PATCH /v1/memory_stores/<id>/memories/<mem-id>` with `if_content_sha256` (per earlier `agent-memory-*` beta sketches).

**Got:** Endpoint not present under `managed-agents-2026-04-01`. POST + DELETE only.

**Workaround:** Last-write-wins via DELETE-then-POST. We lost the optimistic-CAS write surface that prior beta sketches had. For the case-INDEX append, we eat the race window: if two writers append concurrently, one row is dropped. Mitigation is application-level (`bl_consult_update_index_row_append` retries 3×; flock serializes single-host writers).

**Operational quirk:** `409 memory_path_conflict_error` carries `conflicting_memory_id` + `conflicting_path` in the body — useful for retry logic. We use it to fast-forward the case-id counter past already-used IDs (shared workspace + multiple hosts collide on case allocation).

**Ideal:** Either (a) bring back PATCH with `if_content_sha256`, or (b) document an idempotent upsert verb.

---

## 6. Skills/Agents — `?name=` query is not a server-side filter  ·  MINOR

**Tried:** `GET /v1/agents?name=bl-curator`.

**Got:** Returns the entire workspace agent list. The query parameter is silently accepted, not an error, but does no filtering.

**Workaround:** Client-side filter via `jq -r '.data[] | select(.name == "bl-curator") | .id'`.

**Ideal:** Either honor the filter server-side, or reject unknown query params with 400 so integrators know the filter is a no-op.

---

## 7. Files — no per-file in-use enumeration  ·  DEGRADED

**Tried:** Locate an endpoint that answers "which sessions reference `file_<id>` right now?" so `bl setup --gc` can safely delete superseded corpus files without orphaning live sessions.

**Got:** No such endpoint. `GET /v1/sessions/<sid>/resources` lists files attached to one session, but there's no inverse index.

**Workaround:** Conservative GC — only delete `files_pending_deletion[]` entries when state.json shows zero live `session_ids`. This means deletion lags real-world safety: a file is GC-eligible long after the last session referencing it actually closed.

**Ideal:** `GET /v1/files/<file-id>/sessions` or include a `resources_referencing_count` in `GET /v1/files/<file-id>`.

---

## 8. Agents — strict-field policy is correct, just under-documented  ·  MINOR (resolved)

**Tried:** `POST /v1/agents` body initially carried `thinking`, `output_config`, `skill_versions`, `skills[]` (top level), and tool `input_schema.additionalProperties` + per-field `description`.

**Got:** Each rejected with HTTP 400 "Extra inputs are not permitted" or "input_schema is invalid". Required: `name + model + system + tools[]`. Tool descriptions are required (not optional) on every custom tool.

**Workaround:** Stripped the rejected fields. Documented in `docs/managed-agents.md §9` (constraint matrix) so the next integrator doesn't repeat the probe loop.

**Ideal:** A published JSON Schema for `POST /v1/agents` body would have collapsed our 6-probe discovery loop to one schema-validate pass.

---

## 9. Beta header coexistence — undocumented incompatibilities  ·  MINOR

**Tried:** Various combinations of `anthropic-beta: managed-agents-2026-04-01,files-api-2025-04-14,agent-api-2025-…,agent-memory-…`.

**Got:** Some pairs return 400 with no useful body. The working pair for blacklight is `managed-agents-2026-04-01` + (optionally) `files-api-2025-04-14` for multipart uploads. Older `agent-api-*` and `agent-memory-*` flags appear to be retired but co-existence rules are not documented.

**Workaround:** Stick to the two betas above; never combine with the older series.

**Ideal:** Document the beta-header compatibility matrix in the API docs.

---

## 10. Cost / token observability — operator-side wiring required  ·  MINOR

**Tried:** Find a per-session or per-call cost/token usage endpoint.

**Got:** Token usage is on each response payload (`usage.input_tokens`, `usage.output_tokens`); no aggregated billing/cost endpoint.

**Workaround:** `bl_api_call` appends every 2xx response body to `$BL_CURL_TRACE_LOG` when set; `tests/skill-routing/eval-runner.bats` awks the file for usage totals to enforce a per-eval cost cap.

**Ideal:** A `GET /v1/usage?session_id=…` or `?agent_id=…&since=…` rollup endpoint. Especially useful for ops/oncall, not just dev.

---

## Architectural impact on blacklight

The cumulative effect of #1, #2, #5, #7 is that blacklight currently lives in a **hybrid architecture**:

- Skills route via Files (corpus), not via Anthropic's description-router.
- Per-session env setup runs via bash tool, not a pre-baked image.
- Memory writes are last-write-wins with application-level retry.
- File GC is conservative (deletion lags live-session lifecycle).

None of this is fatal — blacklight ships with the stack it has — but the **demo narrative bias toward Managed Agents primitives is weaker than the strategy doc assumes** (see `PIVOT-v2.md`). If items #2 and #1 land in the public surface before submission, blacklight's positioning sharpens materially: skills become real description-routed primitives, and per-session install latency disappears from the demo recording.

---

## Probe re-run protocol

When Anthropic ships a new managed-agents beta header (e.g. `managed-agents-2026-05-01`):

1. Re-probe every numbered item above against a fresh workspace.
2. For items that resolved, mark **(resolved YYYY-MM-DD, beta=…)** in the heading.
3. For items still gapping, refresh the workaround note if blacklight's behavior changed.
4. Cross-link to `docs/managed-agents.md §8` "verb summary" — that table is the authoritative quick-reference; this file is the back-story.
