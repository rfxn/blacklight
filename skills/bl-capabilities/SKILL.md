# bl-capabilities — Wrapper Capability Map

**Always load at session start.** This file is the curator's enforcement reference
for every verb, tier, gate, and schema constraint that the `bl` wrapper exposes.
Read this before proposing any step or tier classification to the operator.

Reference source: `src/bl.d/` part files. Schema source: `schemas/step.json`,
`schemas/ledger-event.json`. Gate behavior source: `DESIGN.md §6`.

Read order: load `/skills/foundations.md` (ir-playbook lifecycle rules) alongside
this file. They are complementary — this file covers the wrapper surface; foundations
covers the case reasoning rules.

---

## 1. Verb index

Nine verbs. Every curator-prescribed step must use one of the `verb` enum values in
`schemas/step.json`. The wrapper's `90-main.sh` routes dispatches these verbs.

| Verb | Sub-verbs / flags | Primary purpose |
|---|---|---|
| `observe` | file, log_apache, log_modsec, log_journal, cron, proc, htaccess, fs_mtime_cluster, fs_mtime_since, firewall, sigs | Read-only evidence extraction; no host mutation |
| `consult` | (new, continue, show, log, list) | Manage curator session lifecycle |
| `run` | `--batch`, `--yes`, `--yes-auto-tier`, `--unsafe` | Execute a pending step by step_id |
| `defend` | modsec, modsec_remove, firewall, sig | Apply or remove a defensive artifact |
| `clean` | htaccess, cron, proc, file | Remediate a malicious or suspicious artifact |
| `case` | new, show, log, list, close, reopen | Case lifecycle management |
| `setup` | --sync, --reset, --gc, --eval, --check, --install-hook lmd, --import-from-lmd | Workspace bootstrap + agent provisioning |
| `flush` | outbox, (target) | Drain the outbox queue |
| `trigger` | lmd | Open a case from a hook-fired event source |

---

## 2. Action tiers

Every step carries an `action_tier` field (`auto`, `suggested`, `destructive`).
The wrapper enforces gate behavior from this field plus the verb class — tier trust
does not come from the agent alone.

| Tier | Gate behavior | Can run unattended? |
|---|---|---|
| **read-only** | Auto-execute; no confirm; standard ledger entry | Yes |
| **auto** (reversible, low-risk) | Auto-execute + operator notify (Slack/stdout) + 15-min veto window | Yes, unless verb=defend.modsec (see §4) |
| **suggested** (reversible, high-impact) | Operator reviews diff + explicit `bl run --yes` required | No (queued, notify dispatched) |
| **destructive** | Diff shown or capture-then-kill; explicit `--yes` per-operation; no batch confirm; backup before apply | No (queued, notify dispatched) |
| **unknown** | Deny by default; operator must invoke `bl run <step-id> --unsafe --yes` | No |

**Non-obvious rule — verb class overrides tier:** `defend.modsec` is always
`suggested` regardless of what the agent writes in `action_tier`. The wrapper
enforces `apachectl configtest` pre-flight before any `defend.modsec` apply.
The agent cannot bypass this by writing `action_tier: auto`.

---

## 3. Schema-enumerated verb forms (step.json)

The `verb` field in `bl-case/pending/<step-id>.json` must be one of these values
exactly. Unknown values route to the `unknown` tier and are denied.

```
observe.file              observe.log_apache         observe.log_modsec
observe.log_journal       observe.cron               observe.proc
observe.htaccess          observe.fs_mtime_cluster   observe.fs_mtime_since
observe.firewall          observe.sigs
defend.modsec             defend.modsec_remove       defend.firewall          defend.sig
clean.htaccess            clean.cron                 clean.proc               clean.file
case.close                case.reopen
trigger.lmd               setup.install_hook         setup.import_from_lmd
```

**Authoring discipline:** the verb string in the step must match the schema
enum exactly (dot separator; no spaces; lowercase). A mismatch causes
`schema_reject` in the ledger and the step is not executed.

---

## 4. Unattended-mode policy (M14 G5)

When `BL_UNATTENDED_FLAG=1` or `unattended_mode="1"` in `blacklight.conf`,
the wrapper applies the following tier policy:

| Tier | Unattended behavior |
|---|---|
| read-only | Auto-execute (same as interactive) |
| auto | Auto-execute iff `verb != defend.modsec` |
| auto + defend.modsec | **Queue, do not execute.** Notify dispatched. |
| suggested | Queue + notify operator. Step waits for `bl run --yes`. |
| destructive | Queue + notify operator. Step waits for `bl run --yes`. |
| unknown | Deny. No queue. Ledger entry `unknown_tier_deny`. |

`bl trigger lmd` sets `BL_UNATTENDED_FLAG=1` when invoked from the
`/etc/blacklight/hooks/bl-lmd-hook` adapter. All cases opened via the LMD
hook are unattended by design — the curator must not emit `defend.modsec` or
`destructive` steps expecting immediate execution.

---

## 5. Exit codes

| Code | Constant | Meaning |
|---|---|---|
| 0 | `BL_EX_OK` | Success |
| 64 | `BL_EX_USAGE` | Bad arguments / unknown verb |
| 65 | `BL_EX_PREFLIGHT_FAIL` | Preflight check failed (jq/curl/key missing; mktemp fail) |
| 66 | `BL_EX_WORKSPACE_NOT_SEEDED` | `bl setup --sync` has not been run |
| 67 | `BL_EX_SCHEMA_VALIDATION_FAIL` | Step or result failed JSON schema validation |
| 68 | `BL_EX_TIER_GATE_DENIED` | Operator declined a prompted step |
| 69 | `BL_EX_UPSTREAM_ERROR` | API exhausted 5xx retries |
| 70 | `BL_EX_RATE_LIMITED` | API exhausted 429 retries |
| 71 | `BL_EX_CONFLICT` | Case allocator collision after retries; fence collision |
| 72 | `BL_EX_NOT_FOUND` | Referenced step_id or resource not found |

**Non-obvious:** exit code 68 (`BL_EX_TIER_GATE_DENIED`) fires when the
*operator* declines a prompted step, not when the tier gate prevents
execution from an automated caller. When `BL_UNATTENDED_FLAG=1` and a
destructive step is queued rather than executed, the return code is still
`0` (step queued successfully). The operator's subsequent `bl run --yes`
or decline produces 68 on decline.

---

## 6. Ledger event kinds (ledger-event.json)

The `kind` field in ledger events must match the schema enum. Key events:

**Case lifecycle:** `case_opened`, `case_attached`, `case_closed`, `case_reopened`

**Gate events:** `schema_reject`, `unknown_tier_deny`, `preflight_fail`,
`operator_decline`, `fence_collision_deny`, `result_schema_reject`

**Step execution:** `step_run`, `clean_apply`, `clean_undo`, `clean_unquarantine`,
`defend_applied`, `defend_rollback`, `defend_refused`, `defend_sig_rejected`

**Outbox:** `outbox_drain`, `outbox_retry`, `outbox_quarantine`, `backpressure_reject`

**Trigger + notify:** `lmd_hook_received`, `trigger_dedup_attached`, `lmd_hit_degraded`,
`notify_dispatched`, `notify_failed`

**cPanel Stage 4:** `cpanel_lockin_invoked`, `cpanel_lockin_failed`,
`cpanel_lockin_rolled_back`

---

## 7. Consult dedup / fingerprint contract

`bl consult --dedup yes --fingerprint <hex16> --dedup-window-hours <N>` prevents
duplicate case opening within the dedup window. The fingerprint must be 16
lowercase hex characters.

For LMD-triggered cases, the fingerprint is:
```
sha256("<scanid>|<sorted-sigs>|<sorted-paths>")[:16]
```

Two bl trigger lmd calls with identical fingerprints within the dedup window
produce `trigger_dedup_attached` in the ledger and return the existing case_id
rather than opening a new case. This is expected behavior — the curator should
continue the existing case, not start fresh.

---

## 8. Setup verb surface

`bl setup` bypasses `bl_preflight` — it carries its own checks (ANTHROPIC_API_KEY,
curl, jq, state-dir). It does not require an existing agent session to run.

| Sub-command | What it does |
|---|---|
| `--sync` | Provision agent + upload Skills + seed Files (idempotent) |
| `--reset [--force]` | Delete agent + Skills + workspace Files |
| `--gc` | Delete Files marked `files_pending_deletion` |
| `--eval [--promote]` | Live promotion eval against the 50-case fixture set |
| `--check` | Print `state.json` snapshot |
| `--install-hook lmd` | Install bl-lmd-hook adapter; write `conf.maldet` post_scan_hook stanza |
| `--import-from-lmd` | Import existing LMD quarantine/session data as bootstrap evidence |

`setup.install_hook` and `setup.import_from_lmd` are schema-enumerated verb
forms (step.json) — they can be prescribed by the agent in a pending step.

---

## 9. What bl explicitly cannot do

The following actions are outside bl's verb surface. Curator must not propose them.

- **Execute arbitrary shell commands.** The only execution path is a named
  `bl run <step-id>` with a step whose verb maps to a known schema enum. There
  is no `exec`, `shell`, `bash`, or `script` verb. Unknown verbs route to the
  `unknown` tier and are denied unless the operator explicitly passes `--unsafe --yes`.

- **Re-implement defensive primitives.** `bl` directs `apachectl`, `apf`, `csf`,
  `iptables`, `nftables`, `maldet`, `clamscan`, `yara` — it does not replace them.
  If a primitive is absent, the relevant defend verb will fail pre-flight; bl does
  not install primitives as a side effect.

- **Quarantine LMD hits a second time.** LMD runs its own quarantine at scan time.
  When a case is opened via `bl trigger lmd`, LMD has already isolated the flagged
  files. `bl` does not re-quarantine them. See
  `/skills/lmd-triggers/quarantine-vs-cleanup.md` for the discipline.

- **Access non-case memory stores.** The wrapper can read and write `bl-case/`
  (the `read_write` memory store). It cannot directly read the Skills or corpus
  Files — those are mounted by the Anthropic session layer, not accessible to the
  wrapper at the bash level.

- **Mutate running sessions.** The curator's session is the Managed Agent session.
  `bl` sends messages to the session and reads responses. It cannot modify session
  metadata, skill bindings, or file resources via the wrapper's verb surface.

- **Delete evidence files.** Evidence bundles uploaded via the Files API are
  permanent during a case's active lifecycle. `bl setup --gc` deletes files marked
  `files_pending_deletion` only — it does not accept arbitrary file_ids.

---

## §5 Pointers

- `/skills/foundations.md` — ir-playbook lifecycle and adversarial-content rules
- `/skills/prescribing-defensive-payloads-corpus.md` — payload authoring grammar
- `/skills/curating-cases-corpus.md` — case lifecycle state machine
