# schemas/defense.json — `synthesize_defense` custom-tool input

Wire-format for the `synthesize_defense` Managed-Agent custom tool. The curator
invokes this tool when correlated evidence in a case justifies a defensive
payload (ModSec rule, firewall block, scanner signature). The wrapper
(`bl setup` registers the input_schema; runtime synthesis flow is documented
in DESIGN.md §12.2) reads the payload, runs a kind-specific FP-gate inside the
sandbox, and only then promotes the action to `bl-case/<case-id>/actions/pending/`.

## Required fields

| Field | Type | Constraint | Purpose |
|---|---|---|---|
| `kind` | string | enum: `modsec` \| `firewall` \| `sig` | Selects the FP-gate path and the eventual apply target |
| `body` | string | — | Payload text — ModSec rule, IP/CIDR, sig body |
| `reasoning` | string | — | Curator-authored justification with evidence ids |
| `case_id` | string | `^CASE-[0-9]{4}-[0-9]{4}$` | Anchors the synthesis to a specific case |

## Optional fields (kind-specific)

| Field | Type | Used when | Purpose |
|---|---|---|---|
| `backend` | string enum (`apf`/`csf`/`nft`/`iptables`) | `kind=firewall` | Pin the firewall backend; otherwise auto-detect |
| `ip` | string | `kind=firewall` | The IP/CIDR to block (alternative to embedding in `body`) |
| `asn_safelist_checked` | boolean | `kind=firewall` | Curator asserts CDN-safelist was considered |
| `scanner` | string enum (`lmd`/`clamav`/`yara`) | `kind=sig` | Target scanner; default `auto` |
| `evidence_ids` | array<string> | any | Pointers to `evid-*.md` / observation records that warrant synthesis |

## Constraint notes

Per `DESIGN.md §12` (verified against `managed-agents-2026-04-01`):

- `additionalProperties` is **rejected** by Managed-Agents `input_schema`.
  Schema lists permitted properties; extras are not validated as forbidden.
- Per-field `description` keyword is **rejected**. Per-field rationale lives
  here in the companion `.md`, not in the schema body.
- `$schema`, `$id`, `title` are **stripped** by `bl_setup_compose_agent_body`
  before submitting to `POST /v1/agents` (defense-in-depth — the platform
  ignores them but stripping keeps the wire payload tight).

## FP-gate paths (wrapper-side, not curator-side)

| `kind` | Gate |
|---|---|
| `modsec` | `apachectl -t` against synthesized rule in staging conf.d |
| `firewall` | `_bl_defend_firewall_validate_ip` + CDN safelist (`_bl_defend_firewall_cdn_safelist_check`) |
| `sig` | `_bl_defend_sig_fp_gate` against `/var/lib/bl/fp-corpus/` |

Synthesis fails closed: gate failure → `gate_status=fail` reply to curator,
no promotion to pending actions.
