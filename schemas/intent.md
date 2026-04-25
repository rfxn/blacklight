# schemas/intent.json — `reconstruct_intent` custom-tool input + reply

Wire-format for the `reconstruct_intent` Managed-Agent custom tool. The curator
invokes this tool to walk obfuscation layers of a mounted shell sample
(polyglot, base64-encoded webshell, polyshell family). The wrapper receives
the tool call, the curator separately writes a structured attribution artifact
to `bl-case/<case-id>/attributions/<attribution_id>.json` keyed by `file_id`,
and the wrapper replies with `{status: queued, attribution_id}`.

The same schema covers both the curator-authored input (`file_id`, `depth`,
`case_id`, `reasoning`) and the curator-authored reply payload that ends up
written to the attribution memstore key (`attribution_id`, `layers_observed`,
`observed_capability`, `dormant_capability`). `bl observe file
--attribution-from <attr-id>` validates the fetched memstore content against
this schema before embedding it in the `obs-NNNN-file.json` record.

## Required fields

| Field | Type | Constraint | Purpose |
|---|---|---|---|
| `file_id` | string | — | Files-API id of the mounted sample (curator must `sessions.resources.add` the file before invoking) |
| `depth` | string | enum: `shallow` \| `deep` | Reconstruction depth — see thresholds below |
| `case_id` | string | `^CASE-[0-9]{4}-[0-9]{4}$` | Anchors the reconstruction to a specific case |

## Optional fields

| Field | Type | Purpose |
|---|---|---|
| `reasoning` | string | Curator-authored note pointing at the trigger (e.g. observed `eval`/`base64_decode`/`gzinflate` chain) |

## Reply-side fields (curator-authored attribution payload)

These fields are populated by the curator on the reply side and persisted to
`bl-case/<case-id>/attributions/<attribution_id>.json`. `bl observe file
--attribution-from <attr-id>` fetches this payload and `bl_jq_schema_check`s
it against this schema before embedding into the `obs-NNNN-file.json` record.

| Field | Type | Constraint | Purpose |
|---|---|---|---|
| `attribution_id` | string | `^attr-[A-Za-z0-9_-]{1,64}$` | Stable id assigned at reconstruction-emit time; doubles as the memstore-key suffix |
| `layers_observed` | string[] | enum: `base64` \| `gzinflate` \| `chr_ladder` \| `rot13` \| `string_concat` \| `eval_indirection` \| `html_polyglot` \| `binary_polyglot` | Ordered list of obfuscation layers actually walked during reconstruction |
| `observed_capability` | string[] | — | Capabilities the sample actually exercises at runtime (free-form short labels — `file_write`, `outbound_http`, `code_eval`, etc.) |
| `dormant_capability` | string[] | — | Capabilities present in the payload but not exercised on the observed run; tracked separately to avoid over-claiming during IC briefing |

The split between `observed_capability` and `dormant_capability` is
load-bearing (PIVOT-v2.md): a polyshell carrying an unused `socket_open`
primitive is materially different from one actively dialing out, and the
attribution record must reflect that distinction.

## Depth thresholds (curator-side rule, prompt §8)

Per `prompts/curator-agent.md §8` and the `skills/webshell-families/` bundle:

- `shallow` — routine polyglot: chr-ladder + base64 + gzinflate shapes; small files (<2 KB) that look like minimal eval-chain loaders
- `deep` — novel obfuscation; larger files (>8 KB) or files with multiple layered decode primitives; APSB25-94 polyshell family always warrants `deep`

## Constraint notes

Per `DESIGN.md §12` (Managed-Agents `managed-agents-2026-04-01`):

- `additionalProperties` rejected; per-field `description` rejected.
- `$schema` / `$id` / `title` stripped by `bl_setup_compose_agent_body`
  before agent-create POST.

## Wrapper consumption (`bl observe file --attribution-from`)

When the operator invokes `bl observe file --attribution-from <attr-id>
<path>`, the wrapper:

1. Validates the `<attr-id>` shape (`^attr-[A-Za-z0-9_-]{1,64}$`) — malformed → exit 64.
2. Resolves the active case via `bl_case_current` — empty → exit 72.
3. Fetches `/v1/memory_stores/$BL_MEMSTORE_CASE_ID/memories/bl-case/<case>/attributions/<attr-id>.json` via `bl_api_call` — 4xx → propagated as exit 65, 5xx → 69.
4. `bl_jq_schema_check`s the fetched `.content` against this schema — fail → exit 67.
5. Embeds the validated attribution payload as the `attribution` field of the `file.triage` JSONL record under `obs-NNNN-file.json`.

The wrapper never authors the reply-side fields itself — it only validates
and embeds the curator's attribution artifact. Without `--attribution-from`,
the `attribution` field is `null` and the `file.triage` record is unchanged
from its M5 shape (additive flag).
