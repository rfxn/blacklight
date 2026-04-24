# Claude Managed Agents — reference notes

Working reference for blacklight. Distilled from
`platform.claude.com/docs/en/managed-agents/*` and
`platform.claude.com/docs/en/build-with-claude/files` as of 2026-04-23.
Not a substitute for the live docs — check the source before
load-bearing implementation. Beta feature; behaviors may shift.

All endpoints require header `anthropic-beta: managed-agents-2026-04-01`.
Research-preview features (multi-agent, outcomes) additionally require
`managed-agents-2026-04-01-research-preview`. Files API operations need
`files-api-2025-04-14`. SDKs set these automatically.

---

## 1. Mental model

Four first-class concepts plus two attached resource types:

| Concept       | Identity            | What it is                                              | Lifetime                       |
|---------------|---------------------|---------------------------------------------------------|--------------------------------|
| Agent         | `agent_...`         | Versioned config: model, system prompt, tools, MCP servers, skills, callable_agents | Until archived |
| Environment   | `env_...` (or name) | Container template: packages, networking, base image    | Until archived or deleted      |
| Session       | `sesn_...`          | A running agent instance in an environment, with its own container + filesystem + conversation history | Until deleted; checkpoint expires 30d after last activity |
| Event         | (ids on events)     | Messages between your app and the agent (user events → agent/session/span events ←) | Persisted with session         |
| Memory Store  | `memstore_...`      | Workspace-scoped, versioned document store. Small atomic files (≤100 KB). Attached at session creation only; read/write enforced at FS layer. | Until archived or deleted      |
| File          | `file_...`          | Workspace-scoped blob (≤500 MB). Mounted read-only in session containers. **Hot-swappable** on running sessions. | Persist until deleted (not tied to session/checkpoint) |

The key relationship: **an agent is a recipe, an environment is a kitchen template, a session is a dinner service, events are the conversation, memory stores are the chef's notebook, files are the ingredients and the finished dishes.** Sessions don't share filesystems. Memory stores + files are how state and raw inputs cross session boundaries — with different sweet spots (§10.5).

### Model of "what Managed Agents does for you that `messages.create` doesn't"

1. Runs the agent loop (tool dispatch, multi-turn reasoning, compaction) in managed infra — you don't write it.
2. Provisions a sandboxed Ubuntu 22.04 container per session with bash/file/web tools preloaded.
3. Checkpoints the container on idle so it can resume cleanly (30-day retention).
4. Event-stream observability with server-side replay (SSE + event history API).
5. First-class state primitive (memory stores) with immutable version history and optimistic concurrency.
6. First-class blob primitive (files) with session-scoped retrieval and free I/O.
7. Hosted prompt caching (5-minute TTL, automatic).
8. Optional research-preview surfaces: multi-agent delegation, outcome-driven work.

---

## 2. API basics

**Beta header:** `anthropic-beta: managed-agents-2026-04-01` on every call.
**API version:** `anthropic-version: 2023-06-01`.
**Auth:** `x-api-key: $ANTHROPIC_API_KEY`.

**Rate limits (org-scoped):**
- Create endpoints (agents, sessions, environments, memory_stores, events.send): **300 RPM**.
- Read endpoints (retrieve, list, stream): **600 RPM**.
- Org-level spend + tier rate limits also apply.

**SDKs with Managed Agents support:** Python, TypeScript, C#, Go, Java, Ruby, PHP. Anthropic CLI (`ant`) is the first-class shell tool.

**Install refs:** `pip install anthropic`, `npm install @anthropic-ai/sdk`, `go get github.com/anthropics/anthropic-sdk-go`, `dotnet add package Anthropic`, `composer require anthropic-ai/sdk`, `gem 'anthropic'`, Maven `com.anthropic:anthropic-java`. CLI: `brew install anthropics/tap/ant` or `go install github.com/anthropics/anthropic-cli/cmd/ant@latest`.

---

## 3. Agents

An agent is a **reusable, versioned** configuration. Created once, referenced by ID from sessions. Updates generate a new version (starts at 1, monotonically increments).

### Fields

| Field            | Req | Purpose                                                                                     |
|------------------|-----|---------------------------------------------------------------------------------------------|
| `name`           | Y   | Human-readable. Must be unique within workspace.                                            |
| `model`          | Y   | Claude 4.5 or later. Pass string `"claude-opus-4-7"` OR object `{"id":"claude-opus-4-6","speed":"fast"}` for Opus 4.6 fast mode. |
| `system`         | N   | System prompt. Nullable (pass `null` to clear).                                             |
| `tools`          | N   | Array: `agent_toolset_20260401` bundle, custom tool objects, MCP tool refs.                 |
| `mcp_servers`    | N   | MCP server definitions for third-party tools.                                               |
| `skills`         | N   | Anthropic pre-built or custom; see §7.                                                      |
| `callable_agents`| N   | Agents this one can delegate to (multi-agent research preview).                             |
| `description`    | N   | Free-form description.                                                                      |
| `metadata`       | N   | K/V for your tracking; merged on update.                                                    |

### Versioning semantics

- `version` starts at 1, increments on every non-no-op update.
- Update payload must include current `version` — acts as a precondition.
- Omitted fields preserved; arrays replaced wholesale when provided; metadata merged key-level (empty-string value deletes a key); `system`/`description` clearable via `null`; `model`/`name` cannot be cleared.
- **No-op detection:** identical payload does not bump version.
- **Archive** is one-way (no unarchive). Existing sessions continue; new sessions cannot reference an archived agent.

### Session↔agent binding

Session creation takes either:
- `"agent": "$AGENT_ID"` (string) → binds to **latest** version.
- `"agent": {"type":"agent", "id":"$AGENT_ID", "version": 1}` → pinned. Use for staged rollouts.

### Code — create

```python
agent = client.beta.agents.create(
    name="Coding Assistant",
    model="claude-opus-4-7",
    system="You are a helpful coding agent.",
    tools=[{"type": "agent_toolset_20260401"}],
)
# agent.id = "agent_01HqR2k7..."; agent.version = 1
```

### Code — update

```python
updated = client.beta.agents.update(
    agent.id,
    version=agent.version,         # precondition
    system="You are a helpful coding agent. Always write tests.",
)
# updated.version = 2
```

### Response shape

```json
{
  "id": "agent_01HqR2k7vXbZ9mNpL3wYcT8f",
  "type": "agent",
  "name": "Coding Assistant",
  "model": {"id": "claude-opus-4-7", "speed": "standard"},
  "system": "…",
  "tools": [{"type": "agent_toolset_20260401", "default_config": {"permission_policy": {"type": "always_allow"}}}],
  "skills": [],
  "mcp_servers": [],
  "metadata": {},
  "version": 1,
  "created_at": "…",
  "updated_at": "…",
  "archived_at": null
}
```

### Branding note
When integrating, use "Claude Agent" / "{YourAgentName} Powered by Claude". Do NOT use "Claude Code" / "Claude Cowork" branding or mimicking ASCII art.

---

## 4. Environments

Container template. Created once, referenced by many sessions. **Each session gets an isolated container instance** — sessions do not share filesystems.

Environments are **not versioned**. If you change one, log it yourself to correlate env state with session behavior.

### Fields

- `name` — unique per org/workspace.
- `config` — type (`cloud`), `packages`, `networking`.

### Packages

Pre-installed before the agent starts. Cached across sessions sharing the env. When multiple package managers specified, run in alpha order: `apt, cargo, gem, go, npm, pip`.

| Field  | PM     | Example                                              |
|--------|--------|------------------------------------------------------|
| `apt`  | apt    | `"ffmpeg"`                                            |
| `cargo`| cargo  | `"ripgrep@14.0.0"`                                   |
| `gem`  | gem    | `"rails:7.1.0"`                                       |
| `go`   | go mod | `"golang.org/x/tools/cmd/goimports@latest"`          |
| `npm`  | npm    | `"express@4.18.0"`                                    |
| `pip`  | pip    | `"pandas==2.2.0"`                                     |

### Networking

- `unrestricted` (default) — full outbound *except* general safety blocklist (exact blocklist not publicly enumerated — do not rely on a particular host being reachable without testing).
- `limited` — allowlist model:
  - `allowed_hosts: ["api.example.com"]` — HTTPS-prefixed.
  - `allow_mcp_servers: true|false` (default false) — outbound to MCP endpoints.
  - `allow_package_managers: true|false` (default false) — PyPI/npm/etc.

Anthropic's **production-deployment advice**: use `limited` with an explicit allowlist. Note this applies to the *container's outbound* — it does not constrain the `web_search` or `web_fetch` tools' own allowed domains.

### Container specs (as of 2026-04-23)

| Property          | Value                                       |
|-------------------|---------------------------------------------|
| OS                | Ubuntu 22.04 LTS                            |
| Arch              | x86_64 (amd64)                              |
| Memory            | Up to 8 GB                                  |
| Disk              | Up to 10 GB                                 |
| Network           | Disabled by default unless env says otherwise |

### Pre-installed runtimes

| Language | Version | PM(s)               |
|----------|---------|---------------------|
| Python   | 3.12+   | pip, uv             |
| Node.js  | 20+     | npm, yarn, pnpm     |
| Go       | 1.22+   | go modules          |
| Rust     | 1.77+   | cargo               |
| Java     | 21+     | maven, gradle       |
| Ruby     | 3.3+    | bundler, gem        |
| PHP      | 8.3+    | composer            |
| C/C++    | GCC 13+ | make, cmake         |

### Pre-installed tools

- **DBs:** SQLite native; `psql`, `redis-cli` clients only (no server daemons).
- **Dev:** `git`, `make`, `cmake`, `docker` (limited), `ripgrep` (`rg`), `tree`, `htop`.
- **Net:** `curl`, `wget`, `ssh`, `scp`.
- **Text:** `sed`, `awk`, `grep`, `jq`, `vim`, `nano`, `diff`, `patch`.
- **Archive:** `tar`, `zip`, `unzip`.
- **Multiplexers:** `tmux`, `screen`.

### Lifecycle

- Archive — read-only; existing sessions keep running.
- Delete — only when no sessions reference it.
- Listing returns all non-archived by default.

---

## 5. Sessions

A session is a running agent instance within an env. **Creation provisions** the container but does **not** start any work — work begins when you send a `user.message` (or `user.define_outcome`) event.

### Fields

- `agent` — string (latest version) or `{type, id, version}` (pinned).
- `environment_id` — string.
- `title` — optional human label (seen in `quickstart`).
- `resources[]` — attached resources at creation time. Only type `memory_store` documented so far.
  - `memory_store`: `{type, memory_store_id, access, instructions}`.
  - Memory stores **cannot be added/removed mid-session**.
- `vault_ids[]` — refs to vaults carrying MCP OAuth creds; see §14.

### Statuses

| Status          | Meaning                                                                 |
|-----------------|-------------------------------------------------------------------------|
| `idle`          | Waiting for input (session starts here; also the post-task resting state) |
| `running`       | Agent is actively working                                                |
| `rescheduling`  | Transient error; platform retrying automatically                         |
| `terminated`    | Unrecoverable error; session ended                                       |

### Idle behavior + checkpoints

- When a session goes idle, the container is **checkpointed** — filesystem, installed packages, files the agent created are preserved.
- Checkpoints live **30 days** from last activity.
- To keep a long-running session warm beyond 30d, send periodic `user.message` events to reset the timer — or design around session recreation from persistent state (preferred for blacklight).
- Session history (events, metadata) persists until the session is explicitly deleted; only the *container* checkpoint expires.

### Lifecycle operations

- `retrieve(id)` — fetch metadata + cumulative `usage`.
- `list()` — paginated list of sessions.
- `archive(id)` — prevent new events; preserves history.
- `delete(id)` — removes session + events + container. A `running` session cannot be deleted; send `user.interrupt` first. Files, memory stores, envs, agents are independent and not affected by session deletion.

### Usage tracking

Session object carries cumulative token counts:

```json
{
  "id": "sesn_01...",
  "status": "idle",
  "usage": {
    "input_tokens": 5000,
    "output_tokens": 3200,
    "cache_creation_input_tokens": 2000,
    "cache_read_input_tokens": 20000
  }
}
```

Prompt caching is automatic with a **5-minute TTL**. Back-to-back turns within that window hit cache_read (cheap). `input_tokens` reports *uncached* tokens.

---

## 6. Events & streaming

Communication is event-based. You send **user events** in → you receive **agent / session / span events** out.

Event names follow `{domain}.{action}`. Every event carries `processed_at` (null = queued, not yet handled).

### User events (you → platform)

| Type                         | Purpose                                                                 |
|------------------------------|-------------------------------------------------------------------------|
| `user.message`               | Text content; kicks off or continues work.                              |
| `user.interrupt`             | Stop mid-execution. Follow with another event to redirect.              |
| `user.custom_tool_result`    | Reply to an `agent.custom_tool_use`, keyed by `custom_tool_use_id`.     |
| `user.tool_confirmation`     | Approve/deny a tool call when permission policy requires confirmation. Keyed by `tool_use_id`. `result: allow|deny`, optional `deny_message`. |
| `user.define_outcome`        | Start an outcome-oriented session (research preview).                    |

### Agent events (platform → you)

| Type                              | Purpose                                                      |
|-----------------------------------|--------------------------------------------------------------|
| `agent.message`                   | Text content blocks from the model.                          |
| `agent.thinking`                  | Thinking content (emitted separately from messages).         |
| `agent.tool_use`                  | Invocation of a pre-built tool (bash, read, etc.).           |
| `agent.tool_result`               | Result of a pre-built tool invocation.                       |
| `agent.mcp_tool_use`              | MCP server tool invocation.                                   |
| `agent.mcp_tool_result`           | Result of MCP tool invocation.                                |
| `agent.custom_tool_use`           | Invocation of a user-defined tool — requires your reply.     |
| `agent.thread_context_compacted`  | Conversation history was compacted to fit context.           |
| `agent.thread_message_sent`       | Multi-agent: message sent to another thread.                 |
| `agent.thread_message_received`   | Multi-agent: message received from another thread.           |

### Session events (platform → you)

| Type                           | Purpose                                                      |
|--------------------------------|--------------------------------------------------------------|
| `session.status_running`       | Agent is actively processing.                                |
| `session.status_idle`          | Task complete (or blocked) — includes `stop_reason`.         |
| `session.status_rescheduled`   | Transient error; retrying.                                   |
| `session.status_terminated`    | Unrecoverable error — session ended.                         |
| `session.error`                | Typed `error` with `retry_status`.                           |
| `session.outcome_evaluated`    | Outcome grader reached terminal status.                      |
| `session.thread_created`       | Multi-agent: coordinator spawned a new thread.               |
| `session.thread_idle`          | Multi-agent: a thread finished its current work.             |

### Span events (observability markers)

| Type                              | Purpose                                                 |
|-----------------------------------|---------------------------------------------------------|
| `span.model_request_start`        | Model call started.                                      |
| `span.model_request_end`          | Model call ended — includes `model_usage` token counts.  |
| `span.outcome_evaluation_start`   | Grader iteration began.                                 |
| `span.outcome_evaluation_ongoing` | Heartbeat during a grader run.                          |
| `span.outcome_evaluation_end`     | Grader finished one iteration.                          |

### Stop reasons on `session.status_idle`

- `end_turn` — agent chose to stop; you can send a new `user.message`.
- `requires_action` — agent is paused awaiting input. `stop_reason.event_ids[]` lists the blocking events. For each id:
  - If it's an `agent.custom_tool_use` → reply with `user.custom_tool_result` carrying `custom_tool_use_id`.
  - If it's a permission-gated tool call → reply with `user.tool_confirmation` carrying `tool_use_id` + `result`.
  - Session returns to `running` when all blocking events resolved.

### Streaming — critical gotcha

> "Only events emitted after the stream is opened are delivered, so open the stream before sending events to avoid a race condition."

Canonical pattern:
```python
with client.beta.sessions.events.stream(session.id) as stream:
    client.beta.sessions.events.send(
        session.id,
        events=[{"type": "user.message", "content": [{"type": "text", "text": "…"}]}],
    )
    for event in stream:
        match event.type:
            case "agent.message":
                for block in event.content:
                    if block.type == "text": print(block.text, end="")
            case "session.status_idle":
                break
            case "session.error":
                print(f"\n[Error: {event.error.message if event.error else 'unknown'}]")
                break
```

### Resume without missing events

Open stream → list history → dedup by `event.id`.

```python
with client.beta.sessions.events.stream(session.id) as stream:
    seen = {e.id for e in client.beta.sessions.events.list(session.id)}
    for event in stream:
        if event.id in seen: continue
        seen.add(event.id)
        # handle …
```

### Interrupt + redirect

Send `user.interrupt` followed immediately by `user.message` with the new direction (both in the same `events.send` payload works).

### Event history

`GET /v1/sessions/:id/events` returns paginated event log. Every event has a stable `id`. Useful for audit, replay, post-hoc review.

---

## 7. Tools

### Built-in agent toolset

`{"type": "agent_toolset_20260401"}` enables:

| Tool        | Name        | Purpose                                     |
|-------------|-------------|---------------------------------------------|
| Bash        | `bash`      | Shell in the container.                     |
| Read        | `read`      | Read local file.                            |
| Write       | `write`     | Write local file.                           |
| Edit        | `edit`      | String replacement in a file.               |
| Glob        | `glob`      | Glob-pattern file matching.                 |
| Grep        | `grep`      | Regex text search.                          |
| Web fetch   | `web_fetch` | HTTP GET a URL.                              |
| Web search  | `web_search`| Search the web.                              |

### Disable / enable subset

Per-tool `enabled: false` on individual entries; or `default_config.enabled: false` and allowlist specific tools. Supports per-tool `permission_policy` (see agent create response: `"default_config": {"permission_policy": {"type": "always_allow"}}`).

### Custom tools

Shape is Messages API–style:

```json
{
  "type": "custom",
  "name": "get_weather",
  "description": "Get current weather for a location",
  "input_schema": {
    "type": "object",
    "properties": {"location": {"type": "string", "description": "City name"}},
    "required": ["location"]
  }
}
```

Flow:
1. Agent emits `agent.custom_tool_use`.
2. Session pauses with `session.status_idle` + `stop_reason: requires_action` + `event_ids[]`.
3. Your code executes the tool out-of-band and sends a `user.custom_tool_result` with matching `custom_tool_use_id`.
4. Session returns to `running`.

### Best practices for custom tool descriptions

Straight from the docs:
- **Provide extremely detailed descriptions.** 3–4 sentences minimum. Explain what, when to use, when *not* to use, what each parameter means, caveats.
- **Consolidate related ops into fewer tools.** Prefer a single `manage_pr(action, …)` to `create_pr` + `review_pr` + `merge_pr`.
- **Namespace tool names** when your surface spans resources: `db_query`, `storage_read`.
- **Return high-signal responses.** Semantic/stable IDs (slugs, UUIDs), minimum fields needed to reason about next step.

### Permission policies

Two kinds of confirmation loops pause the session with `requires_action`:
- Custom-tool execution (you own the logic → reply with result).
- Pre-built / MCP tool call with an `always_ask` permission policy (you gate → reply with `allow|deny`).

Full policy reference: `/docs/en/managed-agents/permission-policies` (not fetched here — check live when building).

---

## 8. Skills

Two kinds, both attached at **agent creation**:
- `{"type": "anthropic", "skill_id": "xlsx"}` — pre-built (xlsx, pdf, etc.).
- `{"type": "custom", "skill_id": "skill_abc123", "version": "latest"}` — author via the Agent Skills surface, reference by id.

**Cap:** max **20 skills per session** — counted across all agents if multi-agent is in play.

Skills load **on demand**. Unlike system prompts, they only enter context when the agent determines they're relevant (progressive disclosure).

Authoring and router/best-practices live at `/docs/en/agents-and-tools/agent-skills/*` — outside the Managed Agents surface proper.

**Relationship to memory stores:** Skills are agent-scoped knowledge; memory stores are session-scoped mutable state. Blacklight uses both — see §12.

---

## 9. Memory stores — the brain

**The single most important primitive for blacklight.** Memory stores are how knowledge and state cross session boundaries.

### What they are

- Workspace-scoped named document stores (`memstore_...`).
- Attached at session creation via `resources[]` (up to 8 per session).
- Mounted inside the sandbox at `/mnt/memory/<mount-name>/`.
- Agent reads/writes with normal file tools (`read`, `write`, `edit`, `glob`, `grep`).
- External API (`memories.create/update/retrieve/delete`) — your out-of-session code writes to the same store the agent reads.

### Attach semantics

```python
session = client.beta.sessions.create(
    agent=agent.id,
    environment_id=environment.id,
    resources=[{
        "type": "memory_store",
        "memory_store_id": store.id,
        "access": "read_write",           # or "read_only"
        "instructions": "User preferences and project context. Check before starting any task.",
    }],
)
```

- `access` enforced at the filesystem layer: `read_only` mounts reject writes at the kernel level; `read_write` writes create versions.
- `instructions` (≤ 4,096 chars) auto-renders into the system prompt alongside the store's `description`. The agent is *told* where each mount is and what's in it.
- **Cannot hot-swap.** Adding/removing stores requires creating a new session.

### CRUD — store

- `POST /v1/memory_stores` — `{name, description}`.
- `retrieve`, `update`, `list`, `archive`, `delete`. Archive is one-way → read-only, can't attach to new sessions. `delete` removes everything including versions.

### CRUD — memory (individual file)

- `create` — `{path, content}`. Does not overwrite.
- `retrieve` — full content.
- `update` — change `path` (rename) or `content` or both. Supports optimistic concurrency via `precondition: {"type": "content_sha256", "content_sha256": "…"}` — update only applies if the stored hash still matches.
- `delete`.
- `list` — supports `path_prefix`, `depth`, `order_by: path|updated_at`.

### Memory versions — free audit trail

- Every mutation creates an immutable `memver_...`.
- `/v1/memory_stores/:id/memory_versions` to list (supports `memory_id` filter).
- Retrieve a version → returns full `content` and metadata.
- **`redact(version_id)`** — scrubs content from a historical version while keeping the audit record (who/when). Required compliance tool. Cannot redact a version that is the current head — write a new version first, then redact the old one.
- **Retention:** versions retained **30 days**. Recent versions always kept regardless of age (so low-churn memories may keep more history). No dedicated restore endpoint — write the old `content` back via `update` to roll back. Versions outlive their parent memory (so you can recover deleted memories via `memories.create` with old version content).
- **Export-for-compliance** is on you if you need > 30 days.

### Limits

| Limit                                | Value                      |
|--------------------------------------|----------------------------|
| Memory stores per org                | 1,000                      |
| Memories per store                   | 2,000                      |
| Total storage per store              | 100 MB (104,857,600 bytes) |
| Versions per store                   | 250,000                    |
| Size per memory                      | 100 kB (102,400 bytes) *~25k tokens* |
| Version history retention            | 30 days                    |
| Memory stores per session            | 8                          |
| `instructions` field per attachment  | 4,096 characters           |

**Doc's explicit guidance:** "Structure memory as many small focused files, not a few large ones."

### Prompt-injection warning (direct from docs)

> "Memory stores attach with `read_write` access by default. If the agent processes untrusted input (user-supplied prompts, fetched web content, or third-party tool output), a successful prompt injection could write malicious content into the store. Later sessions then read that content as trusted memory. Use `read_only` for reference material, shared lookups, and any store the agent does not need to modify."

**Translation for blacklight:** skills/knowledge/fleet-topology stores MUST be read_only. The curator processes log lines, web-fetched advisories, and third-party scanner output — all attacker-reachable surfaces. An attacker who poisons `/mnt/memory/bl-skills/…` permanently corrupts curator reasoning. The read_only mount makes this impossible at the kernel layer.

### Use-case patterns (from docs)

- **Shared reference material** — one read-only store attached to many sessions.
- **Per-user / per-team / per-project** — one store each, single agent config.
- **Different lifecycles** — a store that outlives sessions, or archives on its own schedule.

---

## 10. Files — raw blobs & deliverables

Files is a separate beta (`files-api-2025-04-14`) but integrates with Managed Agents at two points: `resources[]` for mounting into a session's container, and `scope_id` filters for retrieving files the agent produced.

### What it is

- Workspace-scoped immutable blob storage.
- Each file has a stable `file_id` (`file_011CNha8iCJcU1wXNR6q4V8w`), `filename`, `mime_type`, `size_bytes`, `created_at`, `downloadable` (bool).
- Upload via `POST /v1/files` (multipart). Lives until you `DELETE`.
- **Two provenance classes:**
  - User-uploaded — `downloadable: false`. The agent can read; you **cannot** download the raw file back via the API. (You can re-fetch metadata, use it in messages, or mount it in a session.)
  - Agent-produced (via skills or code execution tool) — `downloadable: true`. You can download via `GET /v1/files/:id/content`.

### Limits

| Limit                       | Value                                        |
|-----------------------------|----------------------------------------------|
| Max file size               | **500 MB** per file                          |
| Total workspace storage     | **500 GB** per organization                  |
| Files per session           | **100** via `resources[]`                    |
| Files API rate limit        | **~100 RPM** during beta                     |
| Filename constraints        | 1–255 chars; forbidden: `<>:"|?*\/` and unicode 0–31 |

### Pricing

- Upload / download / list / metadata / delete — **free**.
- File content referenced in `Messages` requests is billed as **input tokens** (plus output tokens on responses).
- Large PDFs + big CSVs inside messages hit context-window limits before cost limits.

### Mount a file into a Managed Agents session (attach at creation)

Add entries to `resources[]`. `mount_path` is absolute; parent dirs auto-created:

```python
session = client.beta.sessions.create(
    agent=agent.id,
    environment_id=environment.id,
    resources=[
        {"type": "file", "file_id": file.id, "mount_path": "/workspace/data.csv"},
        {"type": "memory_store", "memory_store_id": store.id, "access": "read_only",
         "instructions": "Reference data. Check before starting any task."},
    ],
)
```

`mount_path` is optional — the platform picks a default if omitted. **Tip from docs:** if you omit `mount_path`, make sure the uploaded filename is descriptive so the agent can find it.

When mounted, the platform creates a **new `file_id` for the session-scoped copy**. That copy does **not** count against workspace storage limits. The original is untouched.

### Hot-swap on a running session (files only, NOT memory stores)

This is the big structural difference from memory stores. You can add or remove files on a live session via `/v1/sessions/:sid/resources`:

```python
resource = client.beta.sessions.resources.add(
    session.id,
    type="file",
    file_id=file.id,  # mount_path optional
)
# resource.id e.g. "sesrsc_01ABC..."

listed = client.beta.sessions.resources.list(session.id)
for r in listed.data:
    print(r.id, r.type)

client.beta.sessions.resources.delete(resource.id, session_id=session.id)
```

This is why evidence bundles should ride on files, not memory stores: a long-lived curator session can receive *new* evidence mounts without having to be recreated.

### Read-only mount semantics

> "Files mounted in the container are read-only copies. The agent can read them but cannot modify the original uploaded file. To work with modified versions, the agent writes to new paths within the container."

Implication: evidence bundles land at their mount path immutably. If the curator wants to extract a `.tgz`, it writes to `/tmp/extract-0042/…` — the mount stays clean.

### Supported file types

Straight from the docs: "The agent can work with any file type."

- Source code (`.py`, `.js`, `.ts`, `.go`, `.rs`, …)
- Data files (`.csv`, `.json`, `.xml`, `.yaml`)
- Documents (`.txt`, `.md`, `.pdf`)
- Archives (`.zip`, `.tar.gz`) — extract via bash
- Binary — process with appropriate tools

### File types for Messages API (separate from MA sandbox mounts)

When referenced directly in a `messages.create` call (not mounted in an MA session), the content block type must match:

| File type             | MIME                                            | Content block         |
|-----------------------|-------------------------------------------------|-----------------------|
| PDF                   | `application/pdf`                               | `document`            |
| Plain text            | `text/plain`                                    | `document`            |
| Images                | `image/jpeg|png|gif|webp`                       | `image`               |
| Datasets, code-exec inputs | varies                                     | `container_upload`    |

Unsupported types (`.csv`, `.docx`, `.xlsx`, `.md` as document) — convert to plain text and inline. For `.docx` with images, convert to PDF first.

### Retrieving files the agent produced

List + download by `scope_id` = the session id. Requires both beta headers:

```python
# List files scoped to a session (agent-produced + inputs)
files = client.beta.files.list(
    scope_id=session.id,
    betas=["managed-agents-2026-04-01"],
)
for f in files:
    print(f.id, f.filename)

# Download one (must be downloadable — agent-produced, skills/code-exec outputs)
content = client.beta.files.download(files.data[0].id)
content.write_to_file("output.txt")
```

The outcomes docs say deliverables land at `/mnt/session/outputs/` and are retrievable this way. For non-outcome sessions, the agent can write anywhere in the sandbox; scope-filtering then picks up what got captured into Files on session-end.

### File lifecycle

- Files persist until you `DELETE`. No TTL.
- Deletes are effectively immediate for new API calls but "may persist in active `Messages` API calls and associated tool uses."
- User-uploaded files and agent-produced files share the same CRUD surface, but only agent-produced are downloadable.
- ZDR: Files API is **not** ZDR-eligible. Data follows standard retention.

### Errors to plan for

- `404` — file_id missing or no access.
- `400` invalid file type — content block mismatch.
- `400` exceeds context window — e.g. 500 MB plaintext in a messages call.
- `400` invalid filename — length or forbidden chars.
- `413` — file >500 MB.
- `403` — 500 GB org quota hit.

---

## 10.5. Memory stores vs Files — when to use which

| Dimension                | Memory Store                                        | File                                               |
|--------------------------|-----------------------------------------------------|----------------------------------------------------|
| Sweet spot               | Structured, small, high-churn state (<100 KB each) | Raw blobs, archives, deliverables (≤500 MB each)   |
| Attach timing            | Session creation only                               | Session creation OR hot-swap on running session     |
| Versioning               | Built-in `memver_` audit trail (30 d)               | None (each upload = new file_id)                    |
| Mutability from agent    | Read or read-write (access at attach)               | Read-only in container (write to new path)          |
| External write API       | `memories.create/update/delete` + SHA-256 preconditions | `files.upload` only (no in-place update)         |
| Prompt-injection risk    | High if `read_write` — attacker can poison future sessions. Use `read_only` for reference material. | Low for mounts (read-only); normal for message refs. |
| System-prompt surface    | Store `description` + `instructions` auto-rendered  | None — just a file in the filesystem                |
| Pricing                  | Undocumented here; check workspace quotas           | Ops free; content billed as tokens when in messages |
| Capacity                 | 8 stores / session; 2,000 files / store; 100 KB / file; 100 MB / store | 100 files / session; 500 MB / file; 500 GB / org |
| Natural use              | Case files, hypothesis history, action ledger, manifest, skills bundle, fleet topology | Evidence bundles (.tgz), raw log captures, PDFs, attacker artifacts, finished dossiers |

**Rule of thumb for blacklight:**
- If the agent will read-and-reason-on-summaries and you want versioned history → **memory store**.
- If the data is a large, semi-opaque blob the agent will open-and-extract on demand → **file**.
- If new evidence needs to arrive on an active investigation without tearing down the session → **file** (hot-swap) carrying the evidence, with a *pointer* written to the case memory store.
- If the agent produces a deliverable (HTML brief, YAML manifest, PDF incident report) → the agent writes to the sandbox; Files API `scope_id=$session_id` retrieves it; you store the file id in the case memory store for cross-session reference.

---

## 11. Multi-agent (research preview)

Research preview — need `managed-agents-2026-04-01-research-preview` beta header and enablement.

### Model

- One **coordinator** agent creates a session. Coordinator lists `callable_agents` at agent-creation time.
- Sub-agents run in the **same container** (shared filesystem) but each has its own **thread** — a context-isolated event stream with its own conversation history.
- Each thread uses the callee agent's own model/system/tools/skills — not inherited from coordinator.
- Threads are **persistent** — coordinator can re-invoke a sub-agent and it keeps prior-turn memory.
- **Only one level of delegation.** Coordinator → sub-agent is allowed; sub-agent → sub-sub-agent is not.

### Config

```python
orchestrator = client.beta.agents.create(
    name="Engineering Lead",
    model="claude-opus-4-7",
    system="…",
    tools=[{"type": "agent_toolset_20260401"}],
    callable_agents=[
        {"type": "agent", "id": reviewer.id, "version": reviewer.version},
        {"type": "agent", "id": test_writer.id, "version": test_writer.version},
    ],
)
```

Session references only the orchestrator; callable agents resolve from its config.

### Observability

- **Primary thread** = session-level event stream. Condensed view; sees sub-agent start/end but not their inner traces.
- **Per-thread stream** at `/v1/sessions/:sid/threads/:tid/stream` — drill-down per agent.
- `/v1/sessions/:sid/threads` — list all threads.
- Session status is the **aggregate** — running if any thread is running.
- Multi-agent events on primary stream: `session.thread_created`, `session.thread_idle`, `agent.thread_message_sent`, `agent.thread_message_received`.

### Tool confirmation / custom-tool-result routing

When a sub-agent's tool call needs your input, the `requires_action` event arrives on the **session** stream with an additional `session_thread_id` field. Your response must **echo the `session_thread_id`** so the platform routes the reply back to the waiting thread.

Rules:
- `session_thread_id` **present** → came from a sub-agent thread; echo it on reply.
- `session_thread_id` **absent** → came from primary thread; reply without it.
- Always match on `tool_use_id` to pair requests with responses.

---

## 12. Outcomes (research preview)

Research preview — same additional beta header as multi-agent.

### Concept

Elevate a session from *conversation* to *goal-directed work*. You define:
- A `description` — what done looks like.
- A `rubric` — gradeable markdown criteria.
- Optional `max_iterations` (default 3, max 20).

The harness provisions a **grader** in a separate context window that evaluates the artifact against the rubric and feeds per-criterion gaps back for revision.

### API

Create a session, then send a `user.define_outcome` event. Agent starts immediately; no separate `user.message` needed.

```json
{
  "type": "user.define_outcome",
  "description": "Build a DCF model for Costco in .xlsx",
  "rubric": {"type": "text", "content": "# DCF Model Rubric\n…"},
  "max_iterations": 5
}
```

Alternate rubric form: `{"type": "file", "file_id": "file_01…"}` (requires `files-api-2025-04-14` beta header to upload).

### Outcome events

- `span.outcome_evaluation_start` (`iteration: N`, 0-indexed).
- `span.outcome_evaluation_ongoing` (heartbeat; grader reasoning is opaque).
- `span.outcome_evaluation_end` with `result`:
  - `satisfied` → idle.
  - `needs_revision` → next iteration.
  - `max_iterations_reached` → final revision then idle.
  - `failed` → rubric doesn't match task (rubric/description contradict each other).
  - `interrupted` → only if `outcome_evaluation_start` already fired.

### Deliverables

Agent writes outputs to `/mnt/session/outputs/`. After idle, list + download via Files API scoped to the session:

```bash
curl -fsSL "https://api.anthropic.com/v1/files?scope_id=$session_id" \
  -H "anthropic-beta: files-api-2025-04-14,managed-agents-2026-04-01-research-preview" …
```

### Session continuation

After an outcome terminates, the session can continue conversationally OR be given a new outcome (one at a time — chain via sequential `user.define_outcome` events). History of prior outcomes is retained.

### Rubric-writing tip (from docs)

If you don't have a rubric, show Claude an exemplar and have it derive one. "Middle-ground" approach outperforms writing criteria from scratch.

---

## 13. Blacklight mapping — concrete architecture

This section binds the Managed Agents primitives to blacklight's curator design so any future session starts from a coherent picture.

### Agents (plural)

- **`bl-curator`** — Opus 4.7, extended thinking on (adaptive). System prompt = curator voice + IR playbook anchors. Tools: `agent_toolset_20260401` + custom tool `bl_dispatch_hunter` + custom tool `bl_emit_action`. Skills: custom blacklight skill bundle (case-lifecycle, webshell-families, defense-synthesis, false-positives, hosting-stack, ic-brief-format, …). Memory stores: all five in §below. **This is the Managed Agent.**
- **`bl-hunter-filesystem`, `bl-hunter-logs`, `bl-hunter-timeline`** — Sonnet 4.6, no extended thinking. Separate agent IDs. Dispatched from the curator as sub-agents (via `callable_agents` once multi-agent is enabled; until then, spawned via direct `messages.create` calls with structured outputs).
- **`bl-intent-reconstructor`** — Opus 4.7, extended thinking on. Sub-agent.
- **`bl-synthesizer`** — Opus 4.7, extended thinking off. Sub-agent.

Model choice rationale is load-bearing for the "Why these models" README section — defended in §14 below.

### Environment (singular)

- **`bl-curator-env`** — Ubuntu 22.04 default. Packages: `pip: [anthropic, pydantic, pyyaml, flask, requests]`, `apt: [jq, sqlite3]`. Networking: **`limited`** with `allowed_hosts: [api.anthropic.com, the curator's own manifest endpoint for verification, public advisory sources if needed]`, `allow_mcp_servers: true` (for Slack / GitHub MCPs if used), `allow_package_managers: false` (packages are pre-baked). If we need `bl` CLI in the sandbox, `apt: [coreutils, bash, …]` is already there; custom binaries installed via package managers or bootstrap script in first session.

Principle-of-least-privilege applies. Do **not** ship with `unrestricted` networking.

### Memory stores (five — room for three more within 8/session cap)

| Store              | Access      | Shape                                                                 | Why                                                                 |
|--------------------|-------------|-----------------------------------------------------------------------|---------------------------------------------------------------------|
| `bl-skills`        | `read_only` | `/ir-playbook/…`, `/webshell-families/…`, `/defense-synthesis/…`, etc. | Operator knowledge. Poisoning this would corrupt curator reasoning — read-only at kernel level. |
| `bl-cases`         | `read_write`| `/CASE-2026-0017/hypothesis.md`, `…/history/<ts>.md`, `…/evidence/<id>.md`, `…/attribution.md`, `…/open-questions.md` | Living investigations. Every revision auto-versioned via `memver_`. |
| `bl-actions`       | `read_write`| `/pending/<action-id>.yaml`, `/applied/<action-id>.yaml`, `/retired/<action-id>.yaml` | Fleet memory. The `138.199.46.68` unblock problem, structurally solved. |
| `bl-manifest`      | `read_write`| `/current.yaml`, `/suggested/<rule-id>.yaml`, `/versions/v<N>.yaml`     | Defense catalog; double-versioned (memory versions + explicit v{N} history). |
| `bl-fleet`         | `read_only` | `/hosts/<host>.yaml`, `/stacks/<profile>.yaml`                        | Fleet topology. Operator-authored out-of-band. Read-only prevents log-line injection from rewriting topology. |

Every memory is **small + focused** (per docs' explicit guidance). One case = a directory tree of ~10-50 files, each <100KB. One action = one file. One host = one file. No monolithic case YAML.

### Files (raw evidence + deliverables)

Memory stores carry structured state; files carry raw blobs. The split:

- **Inbound evidence bundles** — `bl collect` on a host produces a `.tar.gz` (maldet hits dump, modsec audit log excerpt, transfer logs, yara output, system messages). `bl-agent` uploads via Files API, gets `file_id`. Curator mounts via `sessions.resources.add(type="file", file_id=…, mount_path="/workspace/inbox/evid-<id>.tgz")` — **hot-swap, no session restart**. This is exactly the capability memory stores lack.
- **Attacker artifacts** — individual shell samples captured by hunters. Uploaded as files, mounted, passed to `bl-intent-reconstructor` as a sub-agent task. Kept as files (not memory) because they're opaque binary-ish content the intent reconstructor deobfuscates, not structured state anyone else reads.
- **Deliverables** — the HTML incident brief, the YAML manifest, the ModSec rule bundle, the signed case PDF. Curator writes to `/mnt/session/outputs/` (or any sandbox path). External code lists via `files.list(scope_id=session.id)` after idle, downloads with `files.download(file_id)`. File ID gets written into `bl-cases/<case>/deliverables.md` as a pointer for cross-session reference.
- **What stays in memory stores, not files** — pointers to files. Case file's `evidence` directory contains `.md` summaries that reference `file_id: file_01abc...` — the raw tarball lives in Files, the *summary the curator reasons about* lives in the memory store. Summary-in-memory, raw-in-files.

Rate-limit guardrail: Files API is ~100 RPM during beta. An incident producing 20 evidence bundles/minute at peak is fine; a fleet-wide sweep pushing 200/minute needs throttling at the uploader.

### Session lifecycle (revised with Files)

1. **Evidence arrival** — `bl-agent` on a host pushes a `.tar.gz` to the curator's HTTP inbox. External Python uploads the bundle to Files, gets `file_id`, writes a stub `bl-cases/<case>/evidence/evid-0042.md` carrying `{file_id, filename, size, host, window}` and a short semantic preview.
2. **Dispatch** — if the curator has an active session for this case, external Python calls `sessions.resources.add(session_id=…, type="file", file_id=…, mount_path="/workspace/inbox/evid-0042.tgz")` and sends a `user.message`: *"New evidence mounted at `/workspace/inbox/evid-0042.tgz`; stub at `/mnt/memory/bl-cases/<case>/evidence/evid-0042.md`. Process."* If no active session, external Python creates one with `bl-curator` + `bl-curator-env` + all five memory stores **and** the evidence file in initial `resources[]`.
3. **Curator runs** — reads skills + case state + evidence stub via memory mounts. Extracts the tarball into `/tmp/evid-0042/` (writing to tmp since the mount is read-only). Dispatches hunters via custom tool. Revises hypothesis — writes new `history/<ts>.md` to memory. Proposes actions — writes `bl-actions/pending/<id>.yaml`. Writes deliverable (e.g. rule bundle) to `/mnt/session/outputs/case-17-rules-v3.conf`.
4. **Idle** — session emits `session.status_idle` / `end_turn`. External worker reads `bl-actions/pending/`, lists `files.list(scope_id=session.id)` for deliverables, writes `file_id` pointers back into the case memory, promotes `--apply` actions to `bl-actions/applied/`, and dispatches `bl-agent` commands on the fleet.
5. **Container checkpoints** — 30-day retention. For blacklight this doesn't matter — *all load-bearing state is in memory stores + files*. We **recreate sessions freely**. The session is the CPU; memory stores are the brain; files are the notebooks and the produced artifacts.

### Agent-to-agent handoff

Curator → hunter:
```
tool_use: bl_dispatch_hunter(domain="filesystem", evidence_bundle_id="bundle-0042", case_id="CASE-2026-0017")
  ↓ (separate Sonnet messages.create call; not in curator's session context)
hunter writes 200 structured findings to bl-cases/CASE-2026-0017/evidence/evid-* via memories.create
  ↓
tool_result: {"finding_count": 200, "summary": "12 PHP at mtime 2026-03-28T04:17±30s in /pub/media/custom_options/; 3 match php.webshell.polyshell.v1auth", "memory_paths": ["/CASE-2026-0017/evidence/evid-1847.md", …]}
```

Curator reads the 2-line summary in its working memory. If it needs detail, it reads specific files from the mount. Raw never enters curator context. This is the summary-in-context-raw-in-store discipline.

If multi-agent graduates from research preview in time, the same architecture with `callable_agents` — hunters become threads sharing the same container filesystem, and memory stores are the durable handoff medium. Primary thread stays legible on the session stream; drill-down per-hunter is available via thread streams.

### Trust-boundary summary

- `bl-skills` + `bl-fleet` → `read_only` → can't be poisoned by attacker-reachable inputs.
- `bl-cases` + `bl-actions` + `bl-manifest` → `read_write` but curator is instructed to treat anything under `/mnt/memory/<store>/evidence/` as untrusted data, not trusted directives. Schema on writes (Pydantic or JSON Schema) prevents attacker-driven capability drift — already established in the synthesizer banned-action gate pattern (recent blacklight commit `9d56214`).

### Why multi-agent is a "soon" not "now"

Research preview + enablement-gated. Mitigation: dispatch hunters via direct `messages.create` + structured output today. When MA multi-agent is enabled for the account, swap the dispatcher to `callable_agents`. The memory-store interface doesn't change; only the dispatcher plumbing does.

### Why outcomes is tempting but not essential

Curator's work doesn't fit "rubric-gradable artifact" well — the output is *a living case + a stream of actions*, not *a single file satisfying criteria*. However, outcomes **could** wrap the synthesizer step: "produce a rule bundle for CASE-2026-0017 that passes the rubric: parses with `apachectl configtest`, does not match any row in the known-benign traffic sample, has confidence ≥ 0.8, covers all capabilities in `attribution.md`." That's a concrete future win for auto-hardening rule quality. Roadmap, not hackathon.

---

## 14. Pricing (what we know; verify before committing)

- **Session-hour billing** (~$0.08/hr per the BRIEF.md "Sharpenings" record from the launch announcement).
- **Tokens** billed normally, with automatic prompt caching (5-min TTL). Session object's `usage` object reports `input_tokens` (uncached), `output_tokens`, `cache_creation_input_tokens`, `cache_read_input_tokens`.
- **Memory stores** — no explicit price listed in the fetched /memory page. Assume storage is included in workspace quota until proven otherwise.
- **Files API ops** — upload / download / list / metadata / delete are **free** per the docs. File content referenced in `Messages` requests is billed as input tokens. Sandbox-mounted files read by the agent via filesystem tools are *not* direct-token-priced — they count only when actually read into context.

Bandwidth, session-scoped file copies, and memory-store storage per-GB all fall in the "not explicitly priced in the fetched pages" bucket. Budget-critical deployments must confirm against the live billing console.

The full pricing surface lives outside `/managed-agents/*` in the billing/console pages. **Always re-verify** cost assumptions at implementation time.

---

## 15. Security considerations

- **Networking** — default to `limited` in production. Explicit `allowed_hosts`. Audit regularly. Do not grant `allow_package_managers` unless the agent legitimately needs to install at runtime.
- **Memory store access** — default to `read_only` unless the agent genuinely needs to write. A single `read_write` mount receiving attacker-reachable content becomes a persistent attack vector across all future sessions.
- **Files not ZDR-eligible.** Don't upload files carrying content that must live under Zero Data Retention guarantees. Sensitive operator data (customer hostnames, non-public IOCs) should be scrubbed before upload — matches CLAUDE.md reference-data rules already.
- **File mounts are read-only** — good (attacker can't clobber the original). Anything the agent rewrites lives in sandbox-only paths and disappears with the session unless explicitly promoted back to Files via upload.
- **User-uploaded files are non-downloadable via API.** If you need the content back, you uploaded it — keep a source-of-truth copy yourself. Agent-produced files are the ones that round-trip.
- **MCP tools via vaults** — credentials live server-side; Anthropic handles refresh. See `/docs/en/managed-agents/vaults` for creation + attachment. Session takes `vault_ids[]` at creation.
- **Permission policies** — for tools that affect external state, set `always_ask` and approve via `user.tool_confirmation`. For blacklight, `bl_emit_action` with live-apply should require confirmation; `bl_emit_action --suggest` may be `always_allow`.
- **Prompt injection at the tool surface** — custom tool descriptions should specify exactly what each argument must / must not contain. Use strict input schemas (JSON Schema `pattern`, `enum`).
- **Event history** — persists until session deletion. Contains all tool inputs / outputs. Treat it as PII-sensitive if your tools consume user data.

---

## 16. Gotchas (will-bite-you list)

1. **Stream-before-send ordering.** Open the SSE stream first, then send `user.message`. Reverse order = race condition.
2. **Memory stores only attach at session creation.** If you need a new store mid-investigation, create a new session. Plan for cheap session recreation (all state in stores, no context-window load-bearing).
3. **Memory version retention 30 days.** Long-running cases must export snapshots if full history matters beyond that.
4. **Container checkpoint retention 30 days** — but session events persist until deletion. Blacklight doesn't depend on container state, so this is a non-issue for us.
5. **Only one outcome at a time per session.** Chain sequentially, don't parallel.
6. **Multi-agent callable_agents is one-level only.** Sub-agents cannot spawn their own sub-agents.
7. **`session_thread_id` routing** for multi-agent tool confirmations — easy to miss; the platform won't route your response back to the waiting thread without it.
8. **Agent name is unique per workspace.** Env name is unique per workspace. Plan for namespacing (`bl-curator`, `bl-hunter-filesystem`, etc.) to avoid collisions with other projects.
9. **Memory file 100 KB cap.** Design for atomic files up front. Don't build a case format that produces a 500 KB YAML and then discover the cap at integration time.
9a. **Files rate-limit 100 RPM during beta.** Sensitive for bursty-evidence workflows (fleet-wide sweep, batch re-scan). Queue / throttle at the uploader, not in the curator.
9b. **Files-per-session cap 100.** Hot-swap is the release valve — unmount stale evidence once the curator summary lands in memory store. Don't leak evidence mounts across weeks of a long case.
9c. **User-uploaded files aren't downloadable.** If the agent modifies a CSV, the modification lives only in the sandbox. To capture it, the agent must explicitly produce a new file in `/mnt/session/outputs/` (or use an appropriate tool path) so it becomes downloadable.
10. **`web_fetch` / `web_search` allowed domains are separate from env `allowed_hosts`.** Limiting env networking does NOT lock down those tools — configure per-tool if that matters.
11. **Container architecture is x86_64 only** (as of writing). Bash payloads that assume arm64 quirks will not apply.
12. **No unarchive.** Archive is one-way for agents, envs, stores.
13. **Update agent with stale version** → likely rejected. Always retrieve-then-update with current version in the payload.
14. **`model` field shape — string vs object.** Use the object form only when you want fast-mode on Opus 4.6 (`{"id":"claude-opus-4-6","speed":"fast"}`). All other cases, pass the string.
15. **Rate limits per org** — 300 create / 600 read per minute. If the curator is creating a session per evidence arrival, bursty incident replay could hit this. Batch or pace.

---

## 17. Open questions to verify live

1. **Memory-store billing dimension.** Not explicit on /memory page. Check workspace quota page before committing to a multi-store architecture.
2. **Multi-agent enablement status for this account.** Research preview; needs explicit request. Check before assuming `callable_agents` is available.
3. **Outcomes enablement status.** Same.
4. **MCP connector for Slack / GitHub** at session level. Docs exist at `/docs/en/managed-agents/mcp-connector` — not fetched here; verify when wiring.
5. **Exact contents of the unrestricted-networking safety blocklist.** Not documented publicly. Test any specific outbound before depending on it.
6. **Rate limits on `memories.create`.** Shares the 300/min create bucket? Undocumented here.
7. **Inter-workspace memory-store sharing.** Docs say "workspace-scoped" — cross-workspace reuse is not described.
8. **Session title field.** Appears in quickstart (`title: "Quickstart session"`) and in session create params, but not in the sessions-reference page feature table. Treat as informational metadata only.
9. **Files API rate limit under blacklight load.** 100 RPM is tight for fleet-wide replay scenarios. Confirm whether upload + list + download share the bucket or are separate, and whether it can be raised for our workspace.
10. **`scope_id` semantics on list.** Does `scope_id=$session_id` return *both* input files (user-mounted) and output files (agent-produced), or only one class? Docs imply both but doesn't state explicitly.
11. **Files hot-swap under running session — any propagation latency?** `sessions.resources.add` returns a `sesrsc_...` but not documented whether the mount is immediately visible to the running agent or requires a new turn/message to be picked up.
12. **Evidence bundle mounting vs direct inline in `user.message`.** For smaller bundles, is it cheaper to inline content as text in a `user.message` event (billed as tokens once) vs upload as file (free upload, read into context via `read` tool later)? Net-tokens likely equivalent; upload path wins on reusability across turns.

---

## 18. Load-bearing docs to re-read before implementation

- `/docs/en/managed-agents/memory` — before any memory store code lands.
- `/docs/en/managed-agents/files` + `/docs/en/build-with-claude/files` — before evidence-bundle ingestion + deliverable retrieval wire up. Covers `resources[]`, hot-swap via `sessions.resources.add/list/delete`, and `scope_id` list pattern.
- `/docs/en/managed-agents/events-and-streaming` — before the event loop is written; critical for custom tool + confirmation wiring.
- `/docs/en/managed-agents/permission-policies` — not fetched into this doc; needed before any `user.tool_confirmation` flow.
- `/docs/en/managed-agents/mcp-connector` — needed if Slack/GitHub MCPs get used.
- `/docs/en/managed-agents/vaults` — needed for MCP auth.
- `/docs/en/agents-and-tools/agent-skills/best-practices` — needed when authoring the `bl-skills` bundle for upload as a custom skill (vs. shipping as a file-tree in `bl-skills` memory store — TBD which is better).

---

## 19. Doc provenance

| Page                         | URL                                                                    |
|------------------------------|------------------------------------------------------------------------|
| Overview                     | `/docs/en/managed-agents/overview`                                     |
| Quickstart                   | `/docs/en/managed-agents/quickstart`                                   |
| Agent setup                  | `/docs/en/managed-agents/agent-setup`                                  |
| Environments                 | `/docs/en/managed-agents/environments`                                 |
| Sessions                     | `/docs/en/managed-agents/sessions`                                     |
| Events & streaming           | `/docs/en/managed-agents/events-and-streaming`                         |
| Tools                        | `/docs/en/managed-agents/tools`                                        |
| Skills                       | `/docs/en/managed-agents/skills`                                       |
| Memory                       | `/docs/en/managed-agents/memory`                                       |
| Files (core)                 | `/docs/en/build-with-claude/files`                                     |
| Files (Managed Agents mount) | `/docs/en/managed-agents/files`                                        |
| Multi-agent (RP)             | `/docs/en/managed-agents/multi-agent`                                  |
| Outcomes (RP)                | `/docs/en/managed-agents/define-outcomes`                              |
| Cloud container reference    | `/docs/en/managed-agents/cloud-containers`                             |

Captured 2026-04-23. Re-fetch before any commit that depends on precise API shape — beta is in active evolution.
