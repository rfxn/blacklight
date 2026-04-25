# schemas/intent.json — `reconstruct_intent` custom-tool input

Wire-format for the `reconstruct_intent` Managed-Agent custom tool. The curator
invokes this tool to walk obfuscation layers of a mounted shell sample
(polyglot, base64-encoded webshell, polyshell family). The wrapper receives
the tool call, the curator separately writes a structured attribution artifact
to `bl-case/<case-id>/attribution.md` keyed by `file_id`, and the wrapper
replies with `{status: queued, attribution_id}`.

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

## Depth thresholds (curator-side rule, prompt §8)

Per `prompts/curator-agent.md §8` and the `skills/webshell-families/` bundle:

- `shallow` — routine polyglot: chr-ladder + base64 + gzinflate shapes; small files (<2 KB) that look like minimal eval-chain loaders
- `deep` — novel obfuscation; larger files (>8 KB) or files with multiple layered decode primitives; APSB25-94 polyshell family always warrants `deep`

## Constraint notes

Per `DESIGN.md §12` (Managed-Agents `managed-agents-2026-04-01`):

- `additionalProperties` rejected; per-field `description` rejected.
- `$schema` / `$id` / `title` stripped by `bl_setup_compose_agent_body`
  before agent-create POST.

## Output (wrapper-side, not part of input contract)

The reconstruction emits a structured attribution artifact to
`bl-case/<case-id>/attribution.md` containing:

- `observed_capability[]` — capabilities the sample actually exercises
- `dormant_capability[]` — capabilities present in payload but not invoked
- `decode_layers[]` — ordered list of obfuscation layers walked

These are output fields; the curator does not author them in the tool input.
The split is deliberate (PIVOT-v2.md): observed vs dormant capability is the
attribution distinction that prevents over-claiming during IC briefing.
