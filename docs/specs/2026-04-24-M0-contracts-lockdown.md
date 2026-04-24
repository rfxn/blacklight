# M0 — Contracts lockdown (blacklight v2)

**Spec date:** 2026-04-24
**Motion:** M0 (PLAN.md lines 73–85)
**Author:** primary engineer (operator absent; directional resolutions recorded inline)
**Downstream plan:** `PLAN-M0.md` (named, uncommitted per `.git/info/exclude` `PLAN*.md`)

---

## 0. Gate-blocking open calls from PLAN.md §"Open calls" (resolved directionally)

PLAN.md lines 244–251 list two calls "to resolve before dispatching M0". Operator absent → resolved directionally against judging weights (Impact · Demo · Opus-4.7-Use · Depth). Both resolutions become contract-frozen at M0 commit time.

### 0.1 Fence-token scope — **per-payload** (not per-case)

- **Resolution:** Fence-token derivation is `sha256(case-id || obs-id || payload)[:16]`, recomputed per envelope.
- **Rationale:** The evidence-envelope contract at `schemas/evidence-envelope.md §4` *already* encodes per-payload derivation: "session-unique and derived from `sha256(case || obs || payload)[:16]` — 64 bits of preimage resistance". The "per-case vs per-payload" call in PLAN.md is a retcon of an already-shipped contract — per-payload won at authorship time. Impact weight: an attacker who witnesses a fence in one payload cannot reuse it across payloads. Depth weight: aligns with already-frozen contract at `4ec1c23`.
- **Cache-friendliness concern (PLAN.md line 248) dispatched:** The curator's *system prompt* carries the untrusted-content fence TAXONOMY (role reassignment, schema override, verdict flip — DESIGN.md §13.2); that prompt is identical across steps and caches. Per-envelope tokens live in USER messages and are billed non-cached regardless of scope choice; per-case would not make them cacheable.
- **Downstream lock:** M9 hardening work must keep derivation `case || obs || payload`. Change requires DESIGN.md §13.2 + `schemas/evidence-envelope.md §4` + this resolution updated in one commit.

### 0.2 `bl` layout — **single-file** (not assembled from `files/bl.d/*.sh`)

- **Resolution:** `bl` ships as one source file at repo root. All namespace handlers live in that file with disjoint function prefixes: `bl_observe_*`, `bl_defend_*`, `bl_clean_*`, `bl_consult_*`, `bl_run_*`, `bl_case_*`, `bl_setup_*`.
- **Rationale:** Demo weight + Impact weight. DESIGN.md §8.1 documents the one-liner install path `curl -fsSL https://raw.githubusercontent.com/rfxn/blacklight/main/bl | bash -s setup` — that path requires a single-file `bl`. Adding an assembly toolchain (Make target + `cat files/bl.d/*.sh` at install time) breaks curl-to-bash and adds a dependency on repo-state at install time. PLAN.md line 51 already commits to "each motion owns a disjoint function prefix... merge conflicts limited to shared helpers"; single-file + disjoint prefix IS the merge-safe worktree strategy.
- **Worktree merge discipline:** Wave 2/3 motions (M4–M8) each add their handler functions into the single `bl` file. Shared sections (top-of-file helpers, dispatcher case statement pre-seeded by M1) are touched by multiple worktrees; non-shared handler function bodies don't collide because they live in disjoint name-prefix regions of the file. Reviewer at merge time checks for cross-prefix leakage.
- **Downstream lock:** M1 seeds the case-statement with all 7 namespace entries routing to named-but-empty handlers. M4–M8 worktrees *add* their handler bodies without moving case-statement lines. M10 ship-ready documents this layout in README.

Both open calls now locked. M0 build may dispatch.

---

## 1. Problem statement

blacklight v2 has ratified a scorched-earth rewrite (commit `c5e4806`). `PLAN.md` (landed `ab467ae`) fans six motions off a single `M0 Contracts` gate: every downstream motion (M1 skeleton, M2 case templates, M3 knowledge, M4–M8 per-namespace handlers) depends on contracts M0 freezes.

Current state, measured:

| Artifact | Status | Evidence |
|----------|--------|----------|
| `schemas/step.json` | landed `4ec1c23` | 66 lines; live-beta compliant per inline probe |
| `schemas/step.md` | landed `4ec1c23` | 172 lines; per-field companion doc |
| `schemas/evidence-envelope.md` | landed `4ec1c23` | 186 lines; JSONL contract + 13 sources |
| `docs/action-tiers.md` | **missing** | 0 lines |
| `docs/setup-flow.md` | **missing** | 0 lines |
| `docs/case-layout.md` | **missing** | 0 lines |
| `docs/exit-codes.md` | **missing** | 0 lines |
| MEMORY.md §"DESIGN.md §12.1 reconciliation pending" | **stale warning** | MEMORY.md:56 carries an "⚠ pending" marker even though DESIGN.md §12.1 was reconciled at `4ec1c23` (same commit dropped `thinking`/`output_config` from the agent-create shape per the live probe). |

If M0 does not close, every parallel motion in Wave 1 (M1 + M2 + M3) ships against drifting contracts. M4–M8 worktrees then merge against conflicting shapes for `action_tier`, `step_id`, case paths, and exit-code discipline. The blast radius is the whole v2 build.

M0 is spec-only — no runtime code lands. Its output is five documents + one schema confirmation pass + one memory update + one confirmatory live probe.

## 2. Goals

| # | Goal | Verification |
|---|------|--------------|
| G1 | Four new docs authored and committed: `docs/action-tiers.md`, `docs/setup-flow.md`, `docs/case-layout.md`, `docs/exit-codes.md`. | `ls docs/{action-tiers,setup-flow,case-layout,exit-codes}.md` (4 paths exist) |
| G2 | `MEMORY.md` no longer contains the stale "⚠ DESIGN.md §12.1 reconciliation pending" marker. | `! grep -q '⚠ DESIGN.md §12.1 reconciliation pending' MEMORY.md` |
| G3 | A confirmatory Managed Agents live probe was run, and its verbatim result (including HTTP status + error message) is quoted inline in `docs/setup-flow.md §N Probe log`. | `grep -c 'HTTP/1.1 400' docs/setup-flow.md` returns >= 3 |
| G4 | `docs/action-tiers.md §2 Tier table` normative rows name exactly the `schemas/step.json` `action_tier` enum values: `read-only`, `auto`, `suggested`, `destructive`, `unknown`. | Scoped check on the normative §2 table only, not the full doc (see §10b step 4) |
| G5 | `docs/case-layout.md §3 Writer-owner contract` covers every path enumerated in the fixture list §10b-fixture (derived from DESIGN.md §7.2 tree block + DESIGN.md §12 `STEP_COUNTER` reference + `schemas/step.md` `STEP_COUNTER` reference). | Hardcoded fixture list diffed against §3 table (see §10b step 5) |
| G6 | `docs/exit-codes.md` defines 0, 64–72 (10 codes); anything else explicitly reserved. | `grep -cE '^\| `([0-9]+)`' docs/exit-codes.md` == 10 |
| G7 | Confirmatory probe set covers FOUR targeted calls (per §5.2 §8): `thinking` reject, `output_config` reject, `input_schema.additionalProperties` + `input_schema.description` reject, `input_schema` type-array-union `["string","null"]` accept/reject. If any probe surfaces a NEW result not yet captured in `schemas/step.json` or `DESIGN.md §12`, it is patched in the SAME commit. | `grep -c '^POST https://api.anthropic.com/v1/agents' docs/setup-flow.md` returns >= 4; `git show HEAD -- DESIGN.md schemas/step.json` shows matching delta if probe surfaced one |
| G8 | One commit lands all four new docs + MEMORY.md scrub + (if applicable) any probe-surfaced deltas. Tree is never in a half-reconciled state. | `git log --oneline -1 --name-only` shows all five-or-more files in one commit |

## 3. Non-goals

- **No runtime code lands.** M0 is spec-only. Any `bl` function body, `install.sh` edit, or `pkg/` touch is M1+ territory.
- **No skills authoring.** `skills/**/*.md` belongs to M3 (PLAN.md line 126).
- **No demo fixtures.** Fixture shape was ratified separately in `docs/demo-fixture-spec.md` at `4ec1c23`; M4+ owns fabrication.
- **No governance refresh.** `.rdf/governance/*` still describes v1 (Python curator, Flask, hunters). Governance refresh is deferred to M10 ship-ready.
- **No DESIGN.md redesign.** §12.1 was reconciled at `4ec1c23`. §6 is the source for `action-tiers.md` promotion; §7.2 is the source for `case-layout.md`. If the confirmatory probe surfaces a delta, §12 may receive a surgical patch — not a redesign.
- **No `schemas/step.json` redesign.** 66-line wire-format landed 1h ago under live probe. Touched only if confirmatory probe surfaces a new rejection.
- **No `schemas/evidence-envelope.md` redesign.** 186-line contract landed at `4ec1c23`. Reviewed for cross-doc consistency but not rewritten.
- **No `bl setup --sync` sequence spec.** DESIGN.md §8.4 is enough for M8; `docs/setup-flow.md` covers the first-invocation happy path + error envelope.
- **No third-party skill extension docs.** `DESIGN.md §9.3` is enough.
- **No `schemas/defense.json` or `schemas/intent.json` authoring.** DESIGN.md §12.2 + §12.3 declare these as stubs. Schema authorship is explicitly owned by **M6** (`synthesize_defense`) and **M5** (`reconstruct_intent`) per PLAN.md. M0 does NOT author them; the M6/M5 dispatch payloads own that work. If M0's confirmatory probe surfaces a broader `input_schema` rejection (e.g., type-array unions rejected), both future schemas inherit the tighter constraint.

## 4. Architecture

### 4.1 File map

| # | File | Kind | Est. lines | One-line purpose |
|---|------|------|------------|------------------|
| 1 | `docs/action-tiers.md` | new | 180–240 | 5-tier authoritative table + tier-assignment rules + per-tier examples + fail-closed contract for `unknown` |
| 2 | `docs/setup-flow.md` | new | 260–340 | `bl setup` happy-path API call sequence + confirmatory-probe log + error envelope + idempotency contract |
| 3 | `docs/case-layout.md` | new | 200–260 | `bl-case/` directory contract + writer-owner table per path + size budget + lifecycle transitions |
| 4 | `docs/exit-codes.md` | new | 100–140 | `bl` exit-code taxonomy (10 codes), dispatch-site rules, reserved-range contract |
| 5 | `MEMORY.md` | modified | -1 to -3 lines | Drop "⚠ DESIGN.md §12.1 reconciliation pending" marker; add closed-loop confirmation stamp with `4ec1c23` hash |
| 6 | `DESIGN.md` | modified (conditional) | 0–10 lines | Patched ONLY if confirmatory probe surfaces a new rejection not already in §12 |
| 7 | `schemas/step.json` | modified (conditional) | 0–5 lines | Patched ONLY if probe surfaces a new rejection affecting the wire form |

### 4.2 Size comparison

| Surface | Before | After (min) | After (max) |
|---------|--------|-------------|-------------|
| `docs/` (M0-governed subset) | 2 files / 1276 lines | 6 files / ~2016 lines | 6 files / ~2256 lines |
| `schemas/` | 3 files / 424 lines | 3 files / 424 lines | 3 files / ~429 lines |
| `MEMORY.md` | 56 lines | 54–58 lines | — |
| `docs/specs/` | 0 files | 1 file (this spec) | — |

### 4.3 Dependency tree

Contract authorship order is a directed acyclic graph:

```
                  PIVOT-v2.md  (strategy; already frozen)
                         │
                         ▼
                     DESIGN.md (reference spec; already frozen)
                         │
     ┌───────────────────┼──────────────────────┬────────────────────┐
     ▼                   ▼                      ▼                    ▼
  §6 (tiers)       §7.2 (case layout)     §12.1 (curator)    §8 (setup-flow)
     │                   │                      │                    │
     ▼                   ▼                      ▼                    ▼
 action-tiers.md    case-layout.md        MEMORY.md scrub     setup-flow.md
     │                                          │                    │
     └────────── matches enum in ───────────────┼─── cites probe ────┘
                       │                        │
                       ▼                        │
                 schemas/step.json              │
                       │                        │
                       └──── referenced by ─────┴─── referenced by ─── exit-codes.md
```

### 4.4 Key changes

1. **`action-tiers.md` unifies DESIGN.md §6 prose with `schemas/step.json` enum.** DESIGN.md §6 uses title-case prose labels ("Reversible, low-risk"); `schemas/step.json` enum uses lowercase slugs (`auto`). M0 declares the enum slugs normative and documents the mapping in a one-table crosswalk so future §6 edits or enum bumps land in one place.
2. **`setup-flow.md` memorializes the 2026-04-24 confirmatory probe inline** — HTTP requests, headers, response bodies quoted verbatim. Judges reading the spec see the direct evidence of API shape rather than hand-waved claims.
3. **`case-layout.md` adds a writer-owner column to DESIGN.md §7.2.** Every path in the tree gets `{writer, when, cap, lifecycle}`. Resolves who-writes-hypothesis.md (curator via `update_hypothesis` custom tool or wrapper? → curator) before M2 + M5 reach the contention point.
4. **`exit-codes.md` establishes dispatch discipline.** The 10-code taxonomy replaces ad-hoc `exit 1 / exit 2` patterns in every handler function before M1+ starts writing handlers. Reserved-range contract (128+ for signals, 80–127 never used) prevents future drift.
5. **MEMORY.md reconciliation closes a hanging loop** — the v1 Python-era warning has been actively misleading since `4ec1c23` reconciled DESIGN.md §12.1. Keeping it is an active lie.

### 4.5 Dependency rules

- Every doc MUST cite DESIGN.md by section + line-range anchor for traceability.
- Every doc MUST cross-reference `schemas/step.json` or `schemas/evidence-envelope.md` by filename when discussing the wire form.
- `action-tiers.md` normative tier names MUST match `schemas/step.json` `action_tier` enum (slug form). DESIGN.md §6 prose labels are descriptive only.
- `setup-flow.md` MUST include a dated probe block; a claim without a probe block is a MUST-FIX.
- `case-layout.md` MUST link back to `docs/case-layout.md` from `DESIGN.md §7.2` at commit time so the reference is bidirectional.
- No doc MAY introduce vocabulary not present in DESIGN.md without a justifying note.

## 5. File contents

### 5.1 `docs/action-tiers.md` — section inventory

| Section | Subject | Source |
|---------|---------|--------|
| 1. Preamble | Tier is agent-authored, wrapper-enforced | DESIGN.md §6 line 347 |
| 2. Tier table | 5 rows: `read-only`, `auto`, `suggested`, `destructive`, `unknown` — columns: slug / prose label / gate behavior / typical verbs / operator signal | DESIGN.md §6 table + step.json enum + step.md verb→tier column |
| 3. Crosswalk: DESIGN.md §6 prose ↔ step.json slug | 1-to-1 mapping in a 5-row table | this spec §4.4 |
| 4. Authoring rules (curator-facing) | Seven rules for how the curator chooses a tier at emit time; cites `skills/ir-playbook/*` | new — written from DESIGN.md §6 + CLAUDE.md §Framing |
| 5. Gate behavior (wrapper-facing) | Per-tier wrapper contract: auto-execute / veto-window / --yes / deny | DESIGN.md §6 + §11 |
| 6. Fail-closed contract for `unknown` | Deny by default; operator override via `bl run --unsafe --yes`; ledger entry regardless | DESIGN.md §6 row 5 + §13.3 |
| 7. Worked examples | 3 step envelopes, one per non-trivial tier (auto, suggested, destructive) — inline JSON blocks | new |
| 8. Change control | Tier-table edits require DESIGN.md §6 + step.json enum + this doc updated in one commit | new |

Function / content inventory:

| Heading | Purpose | Dependencies |
|---------|---------|--------------|
| `## 1. Preamble` | Tier is metadata the curator writes; wrapper enforces | DESIGN.md §6 |
| `## 2. Tier table` | The normative 5-row table | step.json enum |
| `## 3. DESIGN §6 ↔ enum crosswalk` | Prevents drift between prose label and slug | both |
| `## 4. Authoring rules` | Curator-side guidance for emit-time tier selection | DESIGN.md §6 + skills |
| `## 5. Gate behavior` | Wrapper-side enforcement per tier | DESIGN.md §6 + §11 |
| `## 6. `unknown` fail-closed` | Deny-by-default contract | DESIGN.md §13.3 |
| `## 7. Worked examples` | JSON envelopes to anchor reading | schemas/step.json |
| `## 8. Change control` | Triple-update discipline | this spec |

### 5.2 `docs/setup-flow.md` — section inventory

| Section | Subject | Source |
|---------|---------|--------|
| 1. Purpose | Call sequence for `bl setup`; what endpoints it hits and why | DESIGN.md §8 |
| 2. Preconditions | `ANTHROPIC_API_KEY` set; curl + jq available; Bash 4.1+ | DESIGN.md §8.1 |
| 3. Happy path sequence | 6-step ordered list: discover → preflight → create agent → create env → create memstores → seed skills → persist ids → print exports | DESIGN.md §8.2 |
| 4. Per-call specification | One subsection per endpoint: method, URL, headers, request body (minimal), expected response shape, idempotency check, error envelope | DESIGN.md §8.2 + live probe |
| 5. Idempotency contract | Every operation is safely re-executable; existing-resource detection precedes create; see §8.5 | DESIGN.md §8.5 |
| 6. Error envelope | HTTP 4xx surface: unseeded workspace (64), bad key (65), beta header missing (65), rate-limit (15s backoff + retry) | DESIGN.md §8.1 + this spec exit-codes.md |
| 7. Source-of-truth resolution | skills/ + prompts/ discovery order (cwd / `$BL_REPO_URL` / default clone) | DESIGN.md §8.3 |
| 8. Probe log (2026-04-24, confirmatory) | Verbatim curl transcripts for FOUR targeted POSTs, dated + full HTTP response bodies: (8.1) `thinking` kwarg reject, (8.2) `output_config` kwarg reject, (8.3) `input_schema.additionalProperties` + per-field `description` reject, (8.4) `input_schema` type-array union `["string", "null"]` accept/reject (covers `diff` + `patch` fields in `schemas/step.json`) | new |
| 9. Delta vs DESIGN.md §12 | If probe surfaces a new rejection: quote the new rejection + note the follow-up DESIGN.md/step.json patch landing in the same commit. Else: "No delta." | new |
| 10. Change control | setup-flow.md is authoritative for call shape; DESIGN.md §8 is the motivational narrative | new |

### 5.3 `docs/case-layout.md` — section inventory

| Section | Subject | Source |
|---------|---------|--------|
| 1. Purpose | Canonical per-case directory contract; M2 writes the template; M5 manages the lifecycle | DESIGN.md §7.2 |
| 2. Tree | Reproduces DESIGN.md §7.2 tree verbatim with a backlink annotation | DESIGN.md §7.2 |
| 3. Writer-owner table | Every path labeled `{writer, write-moment, cap, lifecycle}` where writer ∈ {curator, wrapper, operator}, write-moment ∈ {on-open, on-step-emit, on-step-run, on-action-apply, on-close}, cap = max KB per memstore quota, lifecycle ∈ {append-only, mutable, immutable-after-close}. Must cover all 18 fixture paths (§10b G5 fixture), including `bl-case/CASE-<id>/STEP_COUNTER` (referenced in `schemas/step.md` but absent from DESIGN.md §7.2 tree — M0 explicitly adds it to the writer-owner table). | new |
| 4. Size budget | 100 KB per file cap (Managed Agents platform); estimated steady-state footprint per case | DESIGN.md §7.2 + platform |
| 5. Lifecycle transitions | open → active → close; state transitions and the files each touches | DESIGN.md §5.6 |
| 6. INDEX.md format | Workspace-level INDEX.md structure and update discipline | DESIGN.md §7.2 |
| 7. History append discipline | `history/<ISO-ts>.md` is append-only; never edit in place; even "typo fixes" get a new revision | DESIGN.md §7.2 + §13.4 |
| 8. Pending vs results | `pending/s-<id>.json` is curator-written; `results/s-<id>.json` is wrapper-written; do not cross-write | DESIGN.md §12.1.1 |
| 9. Actions pending → applied → retired | Action lifecycle (written by `synthesize_defense`, applied by `bl run`, retired by `bl defend --remove` or case close) | DESIGN.md §12.2 + §11 |
| 10. Local mirrors | `bl-case/…` is remote (memstore); `/var/lib/bl/ledger/<case>.jsonl` is local; dual-write discipline | DESIGN.md §13.4 |

### 5.4 `docs/exit-codes.md` — full enumeration

| Code | Name | Condition | Emitter |
|------|------|-----------|---------|
| 0 | `OK` | Successful operation | any handler on success |
| 64 | `USAGE` | Invalid CLI args, unknown flag, or missing required positional | dispatcher + any handler's argparse |
| 65 | `PREFLIGHT_FAIL` | `ANTHROPIC_API_KEY` unset, curl missing, jq missing | `bl_preflight()` |
| 66 | `WORKSPACE_NOT_SEEDED` | Preflight GET `/v1/agents?name=bl-curator` returns 0 matches | `bl_preflight()` |
| 67 | `SCHEMA_VALIDATION_FAIL` | A `report_step` payload failed wrapper-side defense-in-depth validation | `bl run` |
| 68 | `TIER_GATE_DENIED` | Operator declined a `suggested` or `destructive` step; or tier is `unknown` without `--unsafe --yes` | `bl run` |
| 69 | `UPSTREAM_ERROR` | HTTP 5xx from Anthropic API (after backoff+retry exhausted) | any API-calling handler |
| 70 | `RATE_LIMITED` | HTTP 429 after backoff exhausted; caller should queue via `/var/lib/bl/outbox/` | any API-calling handler |
| 71 | `CONFLICT` | Resource already exists where uniqueness is required; or optimistic-lock clash | `bl setup` (idempotency boundary) |
| 72 | `NOT_FOUND` | Referenced case-id or step-id does not exist | `bl case`, `bl run` |

Reserved ranges: 1–63 shell/bash conventional (not emitted by `bl`); 73–79 future blacklight expansion (documented but not yet assigned); 80–127 NEVER used; 128+ reserved by shell for signal-based exits.

### 5.5 `schemas/step.json` — confirm-only

Do NOT modify unless confirmatory probe surfaces a new rejection. Verification:

```bash
jq -e '.properties.action_tier.enum' schemas/step.json
# expect: ["read-only", "auto", "suggested", "destructive", "unknown"]
jq -e '.required' schemas/step.json
# expect: ["step_id", "verb", "action_tier", "reasoning", "args", "diff", "patch"]
```

### 5.6 `schemas/evidence-envelope.md` — confirm-only

Do NOT modify. 13 sources enumerated; preamble taxonomy stable. Verification:

```bash
grep -cE '^\| `[a-z.]+` \|' schemas/evidence-envelope.md
# expect: 13 (source taxonomy table)
```

### 5.7 `MEMORY.md` — scrub

Remove the "⚠ DESIGN.md §12.1 reconciliation pending" marker (currently at lines 52–56). Replace with a 4–5 line closed-loop stamp that carries enough forensic anchor for a future session to reconstruct prior state from commit history:

```
## Managed Agents SDK — structured output via custom tools (reconciled 2026-04-24)

Managed Agents does NOT support `thinking={...}` or `output_config={...}` on `agents.create` (HTTP 400 `invalid_request_error`; re-verified 2026-04-24, evidence at `docs/setup-flow.md §8.1–§8.2`). Structured output ships through custom tools only. `input_schema` accepted keywords: `type`, `properties`, `required`, `enum`, `items`, type-array unions like `["string", "null"]` (accepted 2026-04-24, `docs/setup-flow.md §8.4`). Rejected keywords: `additionalProperties`, per-field `description` (both HTTP 400, `docs/setup-flow.md §8.3`). DESIGN.md §12.1 was updated at commit `4ec1c23` to match; this stamp replaces the prior "⚠ DESIGN.md §12.1 reconciliation pending" marker that predated the reconciliation. Prior-state reconstruction: `git show 4ec1c23~1:MEMORY.md` shows the warning text; `git show 4ec1c23 -- DESIGN.md` shows the reconciliation diff.
```

Line accounting: -5 lines (drop warning heading + 4 lines) + 5 lines (closed-loop stamp) = 0 net; if probe 8.4 surfaces a type-array-union rejection, the stamp adjusts in the same commit to document the workaround (typically collapsing `["string", "null"]` to just `"string"` with null values expressed as empty-string sentinels — inherited by M5/M6's `defense.json` / `intent.json`).

## 5b. Examples

### 5b.1 `docs/action-tiers.md` §7 worked example (one of three)

```json
{
  "step_id": "s-0041",
  "verb": "defend.modsec",
  "action_tier": "suggested",
  "reasoning": "Polyshell staging observed at /pub/media/.../a.php/banner.jpg (obs-0038). Rule body matches the double-extension path_class with a SecRule in phase:2 targeting REQUEST_FILENAME.",
  "args": [{"key": "rule_file", "value": "/var/lib/bl/cases/CASE-2026-0007/actions/pending/act-0003.conf"}],
  "diff": "--- a/etc/modsecurity/crs/REQUEST-941.conf\n+++ b/etc/modsecurity/crs/REQUEST-941.conf\n@@ ...\n+SecRule REQUEST_FILENAME \"@rx \\.php/[^/]+\\.(jpg|png|gif)$\" \\\n+    \"id:941999,phase:2,deny,log,msg:'polyshell double-ext staging'\"",
  "patch": null
}
```

Expected wrapper behavior: `apachectl -t` pre-flight → diff displayed → operator runs `bl run s-0041 --yes` → apply → ledger entry written to `/var/lib/bl/ledger/CASE-2026-0007.jsonl` AND `bl-case/CASE-2026-0007/actions/applied/act-0003.yaml`.

### 5b.2 `docs/setup-flow.md §8` probe block (shape)

```
### 8.1 Probe: `thinking` kwarg rejection

POST https://api.anthropic.com/v1/agents
x-api-key: $ANTHROPIC_API_KEY
anthropic-beta: managed-agents-2026-04-01
content-type: application/json

{"name": "bl-probe", "model": "claude-opus-4-7", "system": "probe", "tools": [{"type": "agent_toolset_20260401"}], "thinking": {"type": "adaptive"}}

HTTP/1.1 400 Bad Request
{"type": "error", "error": {"type": "invalid_request_error", "message": "thinking: Extra inputs are not permitted"}}

Conclusion: `thinking` is rejected at `agents.create` time. Thinking is model-internal on Opus 4.7; not operator-configurable via this endpoint. [verified 2026-04-24]
```

(Identical shape for probes 8.2 `output_config`, 8.3 `input_schema.additionalProperties` + per-field `description`, and 8.4 `input_schema` type-array union `["string", "null"]`. Probe 8.4 is the one that may return either 200 OK (accepted, expected) or 400 (rejected — see R9 workaround).)

### 5b.3 `docs/exit-codes.md` dispatch example

```bash
$ bl run s-9999
blacklight: step s-9999 not found in bl-case/CASE-2026-0007/pending/
$ echo $?
72
```

### 5b.4 `docs/case-layout.md §3` writer-owner row (one of ~15)

| Path | Writer | When | Cap | Lifecycle |
|------|--------|------|-----|-----------|
| `bl-case/CASE-<id>/hypothesis.md` | curator | on-open + on-hypothesis-revision | 50 KB | mutable; previous values archived to `history/` |
| `bl-case/CASE-<id>/history/<ISO-ts>.md` | curator | on-hypothesis-revision (before mutating hypothesis.md) | 20 KB | append-only; immutable after write |
| `bl-case/CASE-<id>/pending/s-<id>.json` | curator (via `report_step`) | on-step-emit | 10 KB | mutable until `bl run`; then archived to `results/` |
| `bl-case/CASE-<id>/results/s-<id>.json` | wrapper | on-step-run | 50 KB | immutable after write |
| `bl-case/CASE-<id>/actions/applied/<act-id>.yaml` | wrapper | on-action-apply | 20 KB | immutable after write (retire by moving to `retired/`) |
| `bl-case/INDEX.md` | wrapper (updates on case-open + case-close) | on-open + on-close | 100 KB workspace-wide | append-mostly; closed-case lines may be edited to update brief `file_id` |
| `bl-case/CASE-<id>/STEP_COUNTER` | wrapper | allocated-on-demand (pre-step-emit); incremented at each allocation | 16 bytes (counter value) | mutable; monotonic non-decreasing |

## 6. Conventions

- **Heading depth:** top-level `#` for doc title; `##` for sections; `###` for subsections; deeper nesting reserved for tables-inside-subsections.
- **Tier name casing:** slug form (`auto`, not `Auto`) when referring to the enum value; prose form ("automatically executed") when describing behavior.
- **Section numbering:** 1-indexed; use `## N. Title` form. Makes cross-doc references stable (`docs/action-tiers.md §5`).
- **Code blocks:** JSON blocks MUST be valid JSON (no trailing commas, no JS-style comments). Probe blocks use plain ``` (no language tag) because they contain HTTP transcripts, not a single language.
- **Probe dating:** every probe block carries a `[verified YYYY-MM-DD]` trailer naming the date the curl was run.
- **Cross-reference format:** `DESIGN.md §N.N` (no linebreak), `schemas/step.json`, `PLAN.md M0`.
- **Copyright/license:** no per-doc license headers — repo-wide `LICENSE` governs; `docs/` inherits. Matches existing `DESIGN.md` and `PLAN.md` convention.
- **Line length:** not enforced; use 1-line-per-sentence or 80-ish, whichever is more readable for the surrounding prose.

## 7. Interface contracts

- **`schemas/step.json` wire form:** unchanged (confirmed only). External contract for the `report_step` custom tool `input_schema`.
- **`schemas/evidence-envelope.md` JSONL preamble:** unchanged. External contract for `bl observe` emit.
- **`bl setup` API call sequence:** frozen by `docs/setup-flow.md` §3. Changes require setup-flow.md + DESIGN.md §8 updated in one commit.
- **`bl` exit codes 0 and 64–72:** frozen by `docs/exit-codes.md`. New codes require exit-codes.md update + grep of every handler's dispatch site.
- **`bl-case/` directory shape:** frozen by `docs/case-layout.md`. Changes cascade to M2 (template writer) and M5 (`bl case` lifecycle handlers). No silent path additions — every new path MUST land in case-layout.md §3 writer-owner table first.

## 8. Migration safety

- **Test-suite impact:** no runtime tests land in M0. M0 outputs are prose + tables; there is no BATS coverage to add. First BATS tests land in M1 (dispatcher + preflight).
- **Install/upgrade path:** none. M0 doesn't touch `install.sh`, `pkg/`, or runtime artifacts.
- **Backward compatibility:** v1 Python stack is archived under `legacy/` (`c5e4806`). M0 makes no claim about v1 consumers; there are none.
- **Uninstall:** no installed artifacts. M0 adds 5 files to the tree; removing them is a git revert, no cleanup hooks needed.
- **Rollback:** single commit → single `git revert` restores the pre-M0 state, returning MEMORY.md's pending-warning and dropping the 4 new docs.
- **Documentation drift:** M0 adds 4 docs cross-referencing DESIGN.md §6, §7.2, §8, §12. If DESIGN.md changes later, the change-control rules in each doc's final section require the doc to be updated in the same commit. Governance refresh (stale `.rdf/governance/*.md` v1-era content) is OUT of M0 scope — deferred to M10.

## 9. Dead code and cleanup

No code in scope. Dead content found during reading:

| File | Content | Disposition |
|------|---------|-------------|
| MEMORY.md:52–56 | "⚠ DESIGN.md §12.1 reconciliation pending" warning — actively misleading since `4ec1c23` reconciled §12.1 | **Remove** — goal G2 |
| DESIGN.md | No dead content; §12.1 is current per live probe | Keep |
| `schemas/step.json` | No dead content; wire form is minimal-subset compliant | Keep |
| `schemas/evidence-envelope.md` | No dead content; 186 lines all load-bearing | Keep |
| `.rdf/governance/*.md` | v1-era (Python curator, Flask, hunters, 48-phase plan) | **Out of M0 scope** — deferred to M10 |

## 10a. Test strategy

M0 is spec-only; no runtime tests land. Verification is grep/jq-based contract checks run as part of G-verification (§10b).

| Goal | "Test" | Where it runs |
|------|--------|---------------|
| G1 (4 new docs exist) | `ls` check | §10b step 1 |
| G2 (no stale marker) | `grep -v` check | §10b step 2 |
| G3 (probe log present) | `grep -c 'HTTP/1.1 400'` | §10b step 3 |
| G4 (tier enum ↔ doc match) | `jq` vs `grep` diff | §10b step 4 |
| G5 (writer-owner cross-ref) | `diff` against `DESIGN.md §7.2` path list | §10b step 5 |
| G6 (exit-code count = 10) | `grep -cE` | §10b step 6 |
| G7 (delta captured atomically) | `git show HEAD --name-only` | §10b step 7 |
| G8 (single commit) | `git log --oneline -1 --name-only` | §10b step 8 |

No BATS / pytest coverage is applicable; blacklight v2 has no runtime tests yet (first surface — dispatcher — is M1). State this in the spec rather than inventing test files for documentation.

## 10b. Verification commands

```bash
# G1 — four new docs exist
test -f docs/action-tiers.md && \
test -f docs/setup-flow.md && \
test -f docs/case-layout.md && \
test -f docs/exit-codes.md && echo ok
# expect: ok

# G2 — stale marker removed
! grep -q '⚠ DESIGN.md §12.1 reconciliation pending' MEMORY.md && echo ok
# expect: ok

# G3 — confirmatory probe log present (4 probes × at least one HTTP status line each)
grep -c '^POST https://api.anthropic.com/v1/agents' docs/setup-flow.md
# expect: >= 4

# G4 — action-tiers.md §2 normative table rows name exactly the step.json enum.
# Scoped to §2 table only — avoids false positives from prose / examples / crosswalk.
jq -r '.properties.action_tier.enum[]' schemas/step.json | sort -u > /tmp/enum.txt
sed -n '/^## 2\. Tier table/,/^## 3\./p' docs/action-tiers.md | \
  grep -oE '^\| `(read-only|auto|suggested|destructive|unknown)`' | \
  tr -d '|` ' | sort -u > /tmp/doc.txt
diff /tmp/enum.txt /tmp/doc.txt
# expect: (no output — diff empty)

# G5 — every §7.2 tree path (plus STEP_COUNTER) is in case-layout.md §3 writer-owner table.
# Fixture path list — hardcoded to avoid false positives from prose-level bl-case/ refs.
# Source: DESIGN.md §7.2 tree (lines 368–392) + schemas/step.md §step_id (STEP_COUNTER ref).
cat > /tmp/fixture-paths.txt <<'EOF'
bl-case/INDEX.md
bl-case/CASE-<id>/hypothesis.md
bl-case/CASE-<id>/history/<ISO-ts>.md
bl-case/CASE-<id>/evidence/evid-<id>.md
bl-case/CASE-<id>/evidence/obs-<id>-<kind>.json
bl-case/CASE-<id>/attribution.md
bl-case/CASE-<id>/ip-clusters.md
bl-case/CASE-<id>/url-patterns.md
bl-case/CASE-<id>/file-patterns.md
bl-case/CASE-<id>/open-questions.md
bl-case/CASE-<id>/pending/s-<id>.json
bl-case/CASE-<id>/results/s-<id>.json
bl-case/CASE-<id>/actions/pending/<act-id>.yaml
bl-case/CASE-<id>/actions/applied/<act-id>.yaml
bl-case/CASE-<id>/actions/retired/<act-id>.yaml
bl-case/CASE-<id>/defense-hits.md
bl-case/CASE-<id>/closed.md
bl-case/CASE-<id>/STEP_COUNTER
EOF
sort -u /tmp/fixture-paths.txt > /tmp/fixture-sorted.txt
sed -n '/^## 3\. Writer-owner contract/,/^## 4\./p' docs/case-layout.md | \
  grep -oE '`bl-case/[^`]*`' | tr -d '`' | sort -u > /tmp/doc-paths.txt
comm -23 /tmp/fixture-sorted.txt /tmp/doc-paths.txt
# expect: (empty — every fixture path is covered)

# G6 — exit-codes.md has exactly 10 codes
grep -cE '^\| `[0-9]+` ' docs/exit-codes.md
# expect: 10

# G7 — if DESIGN.md/schemas changed, they're in the same commit
git log --oneline -1 --name-only | grep -E 'DESIGN.md|schemas/' || echo no-delta-ok
# expect: either the delta files OR "no-delta-ok"

# G8 — all M0 files in one commit
git log --oneline -1 --name-only
# expect: one commit listing docs/action-tiers.md, docs/setup-flow.md,
#         docs/case-layout.md, docs/exit-codes.md, MEMORY.md (and optionally
#         docs/specs/2026-04-24-M0-contracts-lockdown.md + conditional deltas)
```

## 11. Risks

| # | Risk | Mitigation |
|---|------|------------|
| R1 | Confirmatory probe surfaces a new rejection that requires redesigning DESIGN.md §12 mid-M0. | Run the probe FIRST in the plan phase (before authoring docs). If the probe surfaces a delta bigger than "one more rejected keyword", pause M0 and escalate — M0 is spec-only, a DESIGN.md §12 redesign is a separate motion (or goes to M9 hardening). Small deltas (one more rejected keyword) patch in the same commit. |
| R2 | Drift between `schemas/step.json` `action_tier` enum and `docs/action-tiers.md` normative labels emerges on a future edit. | G4 verification command + §8 change-control subsection in action-tiers.md requires triple-update discipline. |
| R3 | `docs/case-layout.md` writer-owner table diverges from actual M2 template content. | Cite `docs/case-layout.md` §3 from the M2 dispatch payload. M2 implementation MUST match; reviewer flags any new path not in the table. |
| R4 | Operator reads the spec and wants to add a new exit code not in the 10-code taxonomy. | §11 change-control in exit-codes.md requires doc + handler updated in one commit. Reviewer in M0 flags any handler-side exit code not in the doc. |
| R5 | MEMORY.md scrub removes context a future session needs. | Closed-loop stamp cites `4ec1c23` hash, the probe evidence at `docs/setup-flow.md §8`, and the DESIGN.md §12 anchor. Future session can reconstruct from any of three pointers. |
| R6 | Live probe consumes API budget on non-load-bearing calls. | Each probe POST is ~1 KB request, 1 KB response, mostly 400-range rejections (no tokens consumed beyond validation). 4 probes total; cost is effectively zero. |
| R7 | `docs/setup-flow.md` call-sequence drifts from DESIGN.md §8 narrative over time. | setup-flow.md declared authoritative for call shape; DESIGN.md §8 is the narrative companion. Any drift is a setup-flow.md bug, never a DESIGN.md bug. |
| R8 | `PLAN-M0.md` conflicts with `PLAN.md` motion-map naming. | `.git/info/exclude` already covers `PLAN*.md`; `PLAN-M0.md` stays uncommitted. Master `PLAN.md` is motion-map-only; per-motion plans are named. |
| R9 | Probe 8.4 surfaces type-array-union rejection, invalidating `schemas/step.json` `diff` / `patch` fields (`"type": ["string", "null"]`). | Workaround inherited into MEMORY.md stamp and DESIGN.md §12 patch in same commit: collapse to `"type": "string"` + express null values as empty-string sentinels. `schemas/step.json` patched at lines 60–63 to match. Downstream M5/M6 schemas inherit the constraint. |
| R10 | `STEP_COUNTER` file path is not in DESIGN.md §7.2 tree — M0 adds it to `case-layout.md §3` only. Future reader consulting §7.2 alone misses it. | `case-layout.md §3` preamble notes the discrepancy; `case-layout.md §10 change control` requires DESIGN.md §7.2 updated alongside any case-layout.md addition. (Or: land a 1-line DESIGN.md §7.2 patch in the same M0 commit to add `STEP_COUNTER`. Left as a plan-phase judgement call — both options preserve G5.) |
| R11 | Open calls §0.1 + §0.2 resolved without operator review. | Directional judgement recorded inline with rationale tied to judging weights. If the operator disagrees post-hoc, the resolutions can be reverted via a single DESIGN.md + evidence-envelope.md edit before M1 reaches the contract-touching line. Risk-window = interval between M0 merge and M1 dispatch. |

## 11b. Edge cases

| # | Scenario | Expected behavior | Handling |
|---|----------|-------------------|----------|
| E1 | Probe returns 200 OK (i.e., `thinking` kwarg is NOW accepted on agents.create) | Not a no-op — update DESIGN.md §12 + action-tiers if applicable + setup-flow to reflect the new state, still in same commit | Probe code documents both outcomes; MEMORY.md closed-loop stamp still lands |
| E2 | Probe returns network error or 5xx (transient) | Retry 3× with 2s/5s/10s backoff; if all fail, abort M0 plan phase; escalate | Plan phase `bl-probe.sh` script implements backoff; failure escalates to operator |
| E3 | DESIGN.md §7.2 has been quietly edited between spec authoring and plan execution | Diff detection at plan start: `git show HEAD:DESIGN.md --` compared against spec citation | Plan's phase 1 re-reads DESIGN.md §7.2; flags any mismatch |
| E4 | `MEMORY.md` contents > 200 lines (CLAUDE.md hard cap) after the reconciliation stamp | Unlikely; stamp is net -2 lines — but check | Verification: `wc -l MEMORY.md` after scrub; expect ≤ 56 |
| E5 | Another session lands a commit that touches MEMORY.md between M0 spec approval and M0 build | Re-read before edit; rebase if necessary | Plan phase reads MEMORY.md line-exact at execution time |
| E6 | Operator accidentally commits `PLAN-M0.md` by name | `.git/info/exclude` `PLAN*.md` glob catches it on fresh clone — but already-committed files need manual removal | Verification at commit time: `git diff --cached --name-only \| grep '^PLAN-M0.md'` must be empty |
| E7 | `docs/specs/2026-04-24-M0-contracts-lockdown.md` is listed in `.git/info/exclude` and gets suppressed | `.git/info/exclude` current list: HANDOFF.md, RULES.md, CLAUDE.md, MEMORY.md, P[0-9]*.md, AUDIT.md, FUTURE.md, PRD.md, BRIEF.md, ALT.md, EXHIBITS.md, PROMPTS.md, VOICE.md, .claude/, .rdf/, work-output/, audit-output/. `docs/specs/` is NOT excluded → commits through. | Verification: `git check-ignore -v docs/specs/2026-04-24-M0-contracts-lockdown.md` returns non-zero (not ignored) |
| E8 | `bl-case/INDEX.md` is described in DESIGN.md §7.2 but not listed in case-layout.md §3 | Writer-owner table MUST cover it | G5 verification catches via path diff |
| E9 | Tier name drift between DESIGN.md §6 ("Reversible, low-risk") and action-tiers.md ("auto") | Crosswalk table (§3) is the binding | action-tiers.md §3 is the single source of mapping; anyone adding a tier updates §3 + §2 + step.json enum simultaneously |
| E10 | Exit code 127 (command-not-found from PATH resolution) bubbles up through `bl` | Not emitted by `bl`; propagated from PATH resolution of an intended subcommand | exit-codes.md §reserved-ranges documents 128+ as signal-exits and leaves 127 uncovered (shell convention) |
| E11 | Probe 8.4 returns 200 OK → type-array union accepted (expected outcome per DESIGN.md §12 claim) | No schema patch needed; probe log records acceptance; MEMORY.md stamp carries the verified-accepted status | setup-flow.md §9 delta block reads "No delta." for §8.4 |
| E12 | Probe 8.4 returns 400 → type-array union rejected | See R9: `schemas/step.json` `diff` / `patch` collapse to `"type": "string"`; empty-string sentinels for null; DESIGN.md §12 patched in same commit; MEMORY.md stamp carries the rejection + workaround | Plan phase 1 handles this branch explicitly |
| E13 | DESIGN.md §7.2 tree is later edited to add `STEP_COUNTER` after M0 lands (post-hoc unification) | No-op for M0 contract (`case-layout.md §3` already carries STEP_COUNTER row). Unification reduces drift risk to zero going forward. | case-layout.md §10 change-control allows the later DESIGN.md edit without touching case-layout.md |

## 12. Open questions

None. PLAN.md §"Open calls" (fence-token scope + `bl` layout) resolved directionally in §0 above. All in-scope design questions resolved directionally against judging weights (Phase-2 brainstorm table in spec progress log). Remaining decision points are plan-phase judgement calls explicitly documented (R10 — whether to unify DESIGN.md §7.2 in the M0 commit or defer). Challenge review (second pass) is the gate.
