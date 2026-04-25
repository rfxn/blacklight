# step envelope — field documentation

Human-readable companion to `schemas/step.json`. The JSON file is the wire-format contract; this file carries the per-field documentation the Anthropic Managed Agents custom-tool `input_schema` subset strips (`description` keywords are rejected inside `input_schema` per the managed-agents-2026-04-01 beta, verified 2026-04-24; see `docs/internal/managed-agents.md` §3 for the create-time shape, and the auto-memory entry `managed-agents-create-kwargs.md` for the probe evidence).

A step is one agent-prescribed wrapper action. The curator emits each step by invoking the `report_step` custom tool on its own agent definition (see `DESIGN.md §12.1.1`). The wrapper receives `agent.custom_tool_use`, validates the `input` against this schema (platform has already validated at emit time; the wrapper re-checks as defense-in-depth plus verb-specific arg-key checks), persists to `bl-case/<case-id>/pending/<step_id>.json`, and replies with `user.custom_tool_result`. Operator then runs `bl run <step_id>` under the gate specified by `action_tier`; result lands in `bl-case/<case-id>/results/<step_id>.json`.

---

## Field reference

### `step_id` (string, required)

Stable identifier. Format: `s-NNNN` where NNNN is a zero-padded 4-digit sequence allocated per case. Matches the filename stem under `bl-case/<case-id>/pending/`. The wrapper allocates ids through a `STEP_COUNTER` file in the case memory store — the curator SHOULD request a fresh id from the counter rather than guessing, though a collision is caught at wrapper validation time and responds with `user.custom_tool_result {status: "rejected", reason: "step_id collision"}`.

### `verb` (string, required, enum)

Namespaced execution verb. Format: `<namespace>.<action>`. One of:

| Verb | Namespace | Maps to | Tier (typical) |
|---|---|---|---|
| `observe.file` | observe | `bl observe file <path>` | read-only |
| `observe.log_apache` | observe | `bl observe log apache --around <path>` | read-only |
| `observe.log_modsec` | observe | `bl observe log modsec --txn <id>` | read-only |
| `observe.log_journal` | observe | `bl observe log journal --since <time>` | read-only |
| `observe.cron` | observe | `bl observe cron --user <u>` | read-only |
| `observe.proc` | observe | `bl observe proc --user <u>` | read-only |
| `observe.htaccess` | observe | `bl observe htaccess <dir>` | read-only |
| `observe.fs_mtime_cluster` | observe | `bl observe fs --mtime-cluster <path> --window <N>s` | read-only |
| `observe.fs_mtime_since` | observe | `bl observe fs --mtime-since <date>` | read-only |
| `observe.firewall` | observe | `bl observe firewall` | read-only |
| `observe.sigs` | observe | `bl observe sigs` | read-only |
| `defend.modsec` | defend | `bl defend modsec <rule-file>` (apply) | suggested |
| `defend.modsec_remove` | defend | `bl defend modsec <rule-id> --remove` | destructive |
| `defend.firewall` | defend | `bl defend firewall <ip>` | auto |
| `defend.sig` | defend | `bl defend sig <sig-file>` | auto (after FP-gate) |
| `clean.htaccess` | clean | `bl clean htaccess <dir>` | destructive |
| `clean.cron` | clean | `bl clean cron --user <u>` | destructive |
| `clean.proc` | clean | `bl clean proc <pid> [--capture]` | destructive |
| `clean.file` | clean | `bl clean file <path>` | destructive |
| `case.close` | case | `bl case close` — curator-initiated when open-questions resolved | suggested |
| `case.reopen` | case | `bl case reopen <case-id>` — curator-initiated when T+5d verify sweep fires | suggested |

**Operator-only (no agent-emit verb).** `bl clean --undo <backup-id>` and `bl clean --unquarantine <entry>` are rollback operations invoked by the operator, not by the curator. The agent cannot propose them via `report_step`; this is deliberate — undo paths exist for operator recovery from over-aggressive cleanup, and putting them on the agent-proposable surface defeats that purpose. If a future posture loop wants agent-proposable undo, it earns its own review pass before the verb enters this enum.

### `action_tier` (string, required, enum)

Gate classification authored by the agent; enforced by the wrapper per `DESIGN.md §6`.

- `read-only` — observe verbs; auto-executes without confirm.
- `auto` — reversible low-risk application (new firewall block, sig install after FP-gate); auto-applies with Slack/stdout notification + 15-minute operator veto window.
- `suggested` — reversible but high-impact (new ModSec rule); requires operator `--yes`.
- `destructive` — file edits, process kills, file quarantine, rule removal; requires per-step `--yes`; MUST carry `diff` or `patch`.
- `unknown` — the wrapper's fallback for unrecognised intent; denies by default.

The wrapper validates the declared tier against the verb's expected tier class — a `defend.firewall` declared as `destructive` is an agent bug; a `clean.file` declared as `read-only` is a deny-by-default rejection.

### `reasoning` (string, required)

Free-text justification for this step. Cites evidence record ids (`obs-NNNN` or sha256 prefixes) and hypothesis revision pointers. Treated as UNTRUSTED by the wrapper (attacker-reachable log content can steer the curator's reasoning field via the injection taxonomy in `DESIGN.md §13.2`) and is never parsed as a directive — only displayed to the operator at the `bl run --explain` prompt.

### `args` (array, required, array-of-keyed-maps)

Verb-specific arguments as an ordered list of `{key, value}` string pairs. This satisfies the "array-of-keyed-maps over dict-maps" live-beta json_schema subset preference and keeps the schema shape stable regardless of verb.

Each `value` is an opaque string from the schema's perspective. Numeric values (`"3600"`), durations (`"6h"`), booleans (`"true"`), and comma-separated lists (`"php,phtml,inc"`) are all encoded as strings and parsed by the wrapper per-key. Multi-line string values (e.g. a `reason:` field carrying several lines of operator context) are valid — the wrapper treats `value` as opaque and never line-splits. Parsers that want to treat `value` as structured (e.g. duration parsing) do so at the per-verb arg-handler, not at schema level.

Per-verb allowed keys (wrapper-enforced; unknown keys → rejection at `bl run` time):

| Verb | Required keys | Optional keys |
|---|---|---|
| `observe.file` | `path` | — |
| `observe.log_apache` | `around` | `window`, `site` |
| `observe.log_modsec` | — | `txn`, `rule`, `around`, `window` |
| `observe.log_journal` | `since` | `grep` |
| `observe.cron` | `user` | `system` |
| `observe.proc` | `user` | `verify_argv` |
| `observe.htaccess` | `dir` | `recursive` |
| `observe.fs_mtime_cluster` | `path`, `window` | `ext` |
| `observe.fs_mtime_since` | `since` | `under`, `ext` |
| `observe.firewall` | — | `backend` |
| `observe.sigs` | — | `scanner` |
| `defend.modsec` | `rule_file` | — |
| `defend.modsec_remove` | `rule_id` | — |
| `defend.firewall` | `ip` | `backend`, `case`, `reason` |
| `defend.sig` | `sig_file` | `scanner` |
| `clean.htaccess` | `dir` | `patch` (cross-referenced to top-level `patch`) |
| `clean.cron` | `user` | `patch` |
| `clean.proc` | `pid` | `capture` |
| `clean.file` | `path` | `reason` |
| `case.close` | — | — |
| `case.reopen` | `case` | `reason` |

### `diff` (string-or-null, required)

Unified diff against current file state. Required-non-null when `verb` is `clean.htaccess` or `clean.cron`. Null for all other verbs. Wrapper-enforced at execution time — schema allows null so observe/defend/case steps do not have to populate.

### `patch` (string-or-null, required)

Payload body:

- `defend.modsec`: ModSec rule text (`SecRule` lines).
- `defend.firewall`: null (the single IP lives in `args`); `patch` is reserved for multi-IP atomic blocks in a future verb expansion.
- `defend.sig`: signature text (LMD MD5/MD6/HDB/NDB, ClamAV `.ndb`/`.ldb`, YARA `.yar` rule body).

Null for observe, clean, case verbs. Cross-check: a `clean.htaccess` step carries its file edit in `diff`, not `patch`. A `defend.modsec` step carries its rule text in `patch`, not `diff`.

---

## Why no `additionalProperties: false`, no per-property `description`

The Anthropic custom-tool `input_schema` subset under `managed-agents-2026-04-01` rejects both keywords:

- `tools[N].input_schema.additionalProperties: Extra inputs are not permitted` (HTTP 400, probe verified 2026-04-24)
- `tools[N].input_schema.description: Extra inputs are not permitted` (HTTP 400, same probe)

`step.json` ships as the wire-format input_schema for the `report_step` custom tool. `bl setup` reads it, strips the top-level `$schema`, `$id`, `title` (those are repo-legibility metadata outside the subset), and submits the remainder as `tools[].input_schema` at `POST /v1/agents` time. The per-field documentation lives here in `step.md` instead; the wrapper's local jq-based validation adds `additionalProperties: false` enforcement as defense-in-depth since the platform cannot.

See `DESIGN.md §12.1.1` for the full `report_step` call shape and the auto-memory entry `managed-agents-create-kwargs.md` for the probe evidence.

---

## Example step record

Observe step (read-only, no diff/patch):

```json
{
  "step_id": "s-0003",
  "verb": "observe.fs_mtime_cluster",
  "action_tier": "read-only",
  "reasoning": "Post-`obs-0002` Apache log reveals POSTs to /pub/media/.../a.php at 14:22:07Z; looking for mtime cluster within 60s of that path.",
  "args": [
    {"key": "path", "value": "/var/www/html/pub/media/catalog/product"},
    {"key": "window", "value": "60"},
    {"key": "ext", "value": "php,phtml,inc"}
  ],
  "diff": null,
  "patch": null
}
```

Destructive clean step (diff required):

```json
{
  "step_id": "s-0011",
  "verb": "clean.htaccess",
  "action_tier": "destructive",
  "reasoning": "File walker (obs-0007) flagged injected `AddHandler application/x-httpd-php .jpg` at line 42; matches polyshell staging pattern in skills/webshell-families/polyshell.md §2.",
  "args": [
    {"key": "dir", "value": "/var/www/html/pub/media"}
  ],
  "diff": "--- a/.htaccess\n+++ b/.htaccess\n@@ -40,3 +40,0 @@\n-<FilesMatch ...>\n-  AddHandler application/x-httpd-php .jpg\n-</FilesMatch>\n",
  "patch": null
}
```

Defend apply step (patch required):

```json
{
  "step_id": "s-0009",
  "verb": "defend.modsec",
  "action_tier": "suggested",
  "reasoning": "Three IP addresses in the 203.0.113.0/24 range issued POSTs with `.php/banner.jpg` double-extension URL patterns; synthesize rule per skills/modsec-grammar/rules-101.md §4.",
  "args": [
    {"key": "rule_file", "value": "/var/lib/bl/case/CASE-2026-0017/drafts/bl-rules-v3.conf"}
  ],
  "diff": null,
  "patch": "SecRule REQUEST_URI \"@rx \\\\.php/.*\\\\.(jpg|png|gif)$\" \"id:920450,phase:1,deny,msg:'polyshell double-ext URL evasion'\"\n"
}
```
