# Action tiers + safety gates

Authoritative spec for the 5 action tiers the `bl-curator` agent writes into every proposed step, and the gates the `bl` wrapper enforces before executing one. Promoted from `DESIGN.md §6` and anchored against the `schemas/step.json` `action_tier` enum (`read-only`, `auto`, `suggested`, `destructive`, `unknown`). Every proposed wrapper action is classified into exactly one of these tiers; the tier governs what confirmation (if any) the operator must give before the wrapper runs.

---

## 1. Preamble

Tier is **metadata the curator writes** at `report_step` emit time (see `DESIGN.md §12.1.1`) into the `action_tier` field of `schemas/step.json`. The **wrapper enforces the gate** based on that field plus the verb class — not trust from the agent alone (`DESIGN.md §6` line 347; `DESIGN.md §13.3`).

Two invariants:

- **Agent cannot escalate itself.** The curator can author a step with `action_tier: auto`, but if the verb is in the `clean.*` namespace the wrapper's verb-class lookup forces it back to `destructive` and logs the override. Same mechanism for the reverse direction.
- **`unknown` is always fail-closed.** If the curator emits a verb that does not map to a known verb enum in `schemas/step.json`, the wrapper rejects the step at validation time (exit 67 per `docs/exit-codes.md`). The `unknown` tier slot in `schemas/step.json` exists only for explicit operator override via `bl run <id> --unsafe --yes`; the curator does not author it.

Every step ultimately lands in one of the five tiers below, regardless of what the curator tried to label it.

---

## 2. Tier table

The normative 5-row table. Slug values (column 1) match `schemas/step.json` `action_tier` enum exactly — any edit here requires editing `schemas/step.json` + `docs/action-tiers.md §3` crosswalk in the same commit.

| Slug | Prose label | Gate behavior | Step verbs | Operator signal |
|------|-------------|---------------|------------|-----------------|
| `read-only` | Read-only | Auto-execute; no confirm; no ledger beyond standard case log | `observe.file`, `observe.log_apache`, `observe.log_modsec`, `observe.log_journal`, `observe.cron`, `observe.proc`, `observe.htaccess`, `observe.fs_mtime_cluster`, `observe.fs_mtime_since`, `observe.firewall`, `observe.sigs` | none (silent) |
| `auto` | Reversible, low-risk | Auto-execute + Slack/stdout notification + 15-minute operator veto window (revert via `bl defend firewall --remove <ip>` or equivalent); ledger entry written | `defend.firewall` (new block), `defend.sig` (after corpus-FP-pass) | notification |
| `suggested` | Reversible, high-impact | Diff shown; explicit `bl run <id> --yes` to apply; tier-specific preflight mandatory (`apachectl -t` for modsec; benign-corpus scan for sigs) | `defend.modsec` (new rule), `case.close`, `case.reopen` | confirm required |
| `destructive` | Destructive | Diff shown (file edits) or capture-then-kill (procs); explicit `--yes` per-operation required; no batch auto-confirm; backup written before apply | `clean.htaccess`, `clean.cron`, `clean.proc`, `clean.file`, `defend.modsec_remove` | confirm required + backup |
| `unknown` | Unknown | Deny by default; operator override only via `bl run <id> --unsafe --yes`; ledger entry always written; discouraged | (no enum value — see §6) | override required |

**Step verbs column scope:** Every entry in the "Step verbs" column is an **exact match** for a value in `schemas/step.json` `verb` enum — the curator emits these verbs via `report_step` and the wrapper gates them. **Operator-initiated CLI commands** (`bl consult`, `bl case show`, `bl case log`, `bl case list`) are **not** step envelopes; they dispatch directly through the `bl` dispatcher without a tier gate, because the curator never authors them. They are read-only by construction but do not appear in this table because they have no `schemas/step.json` mapping.

---

## 3. DESIGN §6 ↔ enum crosswalk

Normative mapping between DESIGN.md §6 prose labels and `schemas/step.json` `action_tier` enum slugs. Any drift between these is a bug.

| `schemas/step.json` enum | DESIGN.md §6 prose | Authoritative surface |
|--------------------------|--------------------|-----------------------|
| `read-only` | "Read-only" | slug |
| `auto` | "Reversible, low-risk" | slug |
| `suggested` | "Reversible, high-impact" | slug |
| `destructive` | "Destructive" | slug |
| `unknown` | "Unknown" | slug |

The **slug is always authoritative** — live-beta API traffic carries the slug, and the wire-format `schemas/step.json` is the contract. Prose labels exist for DESIGN.md narrative readability only.

---

## 4. Authoring rules (curator-facing)

Seven rules the curator applies at `report_step` emit time to assign `action_tier`. Written from DESIGN.md §6 + the curator's system prompt (promoted from `skills/ir-playbook/*` per M3).

1. **If the verb is in the `observe.*` family → `read-only`.** No exceptions. All `observe.*` verbs in `schemas/step.json` enum (see §2) cannot cause state change on the target host. (Operator-initiated CLI reads — `bl consult`, `bl case show/log/list` — never become step envelopes, so they never reach this rule.)
2. **If the verb is `defend.firewall` adding a NEW block → `auto` only if the IP is NOT on a CDN safelist.** If the IP falls inside a known CDN ASN (Cloudflare, Fastly, Akamai, CloudFront — list maintained in `skills/defense-synthesis/firewall-rules.md`) → `suggested` instead (operator must confirm; false positive risk is customer-traffic impact, not security).
3. **If the verb is `defend.sig` (signature injection) → `auto` only after FP-gate pass.** The curator sandbox runs the signature against `/var/lib/bl/fp-corpus/` before emit; no FP-pass → `suggested`. This is a hard gate — an `auto` `defend.sig` without a prior sandbox FP-pass in the case log is a policy violation and the wrapper logs it.
4. **If the verb is `defend.modsec` (new rule) → always `suggested`.** ModSec rules have large-scale false-positive risk (one bad regex can block every POST in the document root). Even with `apachectl -t` pre-flight, human sign-off is load-bearing.
5. **If the verb is `clean.*` or `defend.modsec_remove` → always `destructive`.** These modify host state irreversibly (crontab edits, file quarantines, proc kills). Diff or capture happens before any mutation.
6. **If the step includes an operator-supplied `--unsafe` precondition in `args` → the curator MAY emit `unknown`, otherwise NEVER.** The `unknown` tier is operator-authored at dispatch time, not curator-authored. If the curator finds itself wanting to emit `unknown`, it should instead open an `open-questions.md` entry describing the operation and wait for the operator.
7. **Tier is stable across revisions.** If the curator revises a step (same `step_id` reissued with modified `args` or `reasoning`), the `action_tier` MUST NOT change. Tier change requires a new `step_id` — this preserves the operator's per-step gate decision (confirm-once-per-step, not per-revision).

Rule conflicts are resolved in declared order: rule 1 beats rule 2, rule 5 beats rule 3, etc. The curator's system prompt includes this ordering verbatim.

---

## 5. Gate behavior (wrapper-facing)

Per-tier wrapper contract. Cites `DESIGN.md §6` + `DESIGN.md §11` (remediation safety model).

### 5.1 `read-only`

- **Execute:** immediately, no confirm.
- **Output:** JSONL evidence to stdout (see `schemas/evidence-envelope.md`); also written to `bl-case/<case-id>/results/<step_id>.json`.
- **Ledger:** standard case log only; no `/var/lib/bl/ledger/` entry (read-only operations do not mutate host state).
- **Failure modes:** command-not-found on the target host (e.g., `apachectl` missing for an `observe.log_modsec`) returns `observe.summary.backend_meta.*_missing: true`; curator sees the gap and proposes an alternate observation. Not an error.

### 5.2 `auto`

- **Execute:** after preflight pass (backend detection + rule/IP idempotency check).
- **Notification:** Slack webhook if configured (`$BL_SLACK_WEBHOOK` env var) + stdout notification with a `veto-window: 15m` marker.
- **Veto window:** 15 minutes. Operator can undo via `bl defend firewall --remove <ip>` (firewall case) or `bl defend sig --remove <sig-id>` (sig case). After the window closes, action graduates to normal-weight ledger entry.
- **Ledger:** dual-write to `bl-case/<case-id>/actions/applied/<act-id>.yaml` (remote, 30-day versioned) AND `/var/lib/bl/ledger/<case-id>.jsonl` (local, append-only). Per `DESIGN.md §13.4`.
- **Failure modes:** backend not detected → exit 65; upstream API error → exit 69; rate limit → exit 70 with queue to `/var/lib/bl/outbox/`.

### 5.3 `suggested`

- **Execute:** blocked until operator runs `bl run <step_id> --yes`.
- **Preflight (mandatory):** kind-specific validation before diff is shown. ModSec rules: `apachectl -t` against a staged config. Signatures: benign-corpus scan. Firewall-with-ASN-safelist: ASN lookup via `whois` or cached ASN table. Preflight fail → exit 68 (`TIER_GATE_DENIED`) with reason.
- **Diff:** shown to operator stdout + logged to `bl-case/<case-id>/actions/pending/<act-id>.yaml`. Operator inspects, then runs `bl run --yes` or `bl case open-question <reason>` to defer.
- **Ledger:** same dual-write as `auto` after apply.
- **Failure modes:** operator declines → exit 68; preflight fail → exit 68 with different reason; schema validation fail → exit 67.

### 5.4 `destructive`

- **Execute:** blocked until operator runs `bl run <step_id> --yes`. NO batch auto-confirm — each destructive step requires its own `--yes`.
- **Backup (mandatory):** `bl` writes the pre-mutation artifact to `/var/lib/bl/backups/<case-id>/<ISO-ts>-<step_id>.<kind>` BEFORE applying. File edits: full pre-image file. Process kills: full `/proc/<pid>/` snapshot + argv + env + open-fds listing.
- **Diff (for file edits):** shown to operator before apply; operator may redirect to `bl clean file --dry-run` for a review without apply.
- **Capture (for proc kills):** `clean.proc` with `--capture` writes a core dump + process map before `kill -9`. Without `--capture`, step fails pre-kill with exit 68 (operator must opt-in to uncaptured kill).
- **Quarantine not delete:** `clean.file` moves to `/var/lib/bl/quarantine/<case-id>/` — files are never `rm`'d. See `DESIGN.md §11.4`.
- **Ledger:** full dual-write including the pre-mutation backup path.
- **Failure modes:** operator declines → exit 68; backup-write fails → exit 65 and action aborted (do not mutate without backup); schema validation fail → exit 67.

### 5.5 `unknown`

- **Deny by default.** Wrapper returns exit 68 (`TIER_GATE_DENIED`) immediately.
- **Operator override:** `bl run <step_id> --unsafe --yes`. Both flags required. Either alone → deny.
- **Audit:** ledger entry written regardless of run/deny, with `reason: unknown-tier-override-<yes|no>`. Regulator and operator both see every `unknown` attempt.
- **Discouraged:** the `--unsafe` path is for emergency operator-known-better situations (e.g., a new verb under active development). Production use should resolve by adding the verb to `schemas/step.json` enum + the dispatcher's verb class.

### 5.6 Unattended-mode gate overrides

When `bl_is_unattended` returns true (M14 G5 tier policy, `src/bl.d/60-run.sh`), the wrapper
modifies gate behavior for `suggested` and `destructive` tiers. `read-only` and `auto` tiers are
unaffected — they execute normally regardless of unattended state.

**Detection (`bl_is_unattended`, `src/bl.d/30-preflight.sh`).**
Five-layer resolution chain (most-explicit-wins):

1. `--unattended` CLI flag (caller sets `BL_UNATTENDED_FLAG=1` before invoking `bl_run_step`)
2. `BL_UNATTENDED=1` environment variable
3. `unattended_mode="1"` in `/etc/blacklight/blacklight.conf` (exported as `BL_UNATTENDED_MODE`)
4. `BL_INVOKED_BY` non-empty (set by `bl-lmd-hook`, cron launchers, and future hook adapters)
5. No controlling TTY on both stdin and stdout (`[[ ! -t 0 ]] && [[ ! -t 1 ]]`)

Any layer returning true short-circuits the chain. The chain is evaluated at call time — the wrapper
does not cache the result across steps.

**Unattended tier policy table.**

| Tier | Verb | Unattended behavior | Exit |
|------|------|---------------------|------|
| `destructive` | any | Queue to `queued/` + `operator_decline` ledger event (`policy:"unattended"`) + `bl_notify` warn — even if `--yes` was passed | 68 |
| `suggested` | any except `defend.modsec` | Queue to `queued/` + `operator_decline` ledger event (`policy:"unattended"`) + `bl_notify` warn | 68 |
| `suggested` | `defend.modsec` only | Preflight gate already passed (§5.3); auto-apply without prompt | 0 |
| `read-only` | any | No change — execute immediately | 0 |
| `auto` | any | No change — execute with 15-minute veto window | 0 |

**Queue-to-outbox semantic (`bl_run_queue_unattended`, `src/bl.d/60-run.sh`).**
Queued steps are written to `bl-case/<case-id>/actions/queued/<step_id>.json` in the memstore via
`bl_mem_patch`. The pending entry at `actions/pending/<step_id>.json` is removed (best-effort — the
entry may be transient). The operator drains queued steps via `bl run --batch <step_id> --yes` in an
interactive session. The `operator_decline` ledger event carries `policy:"unattended"` to distinguish
unattended queuing from an operator explicitly declining in an interactive session.

**Downgrade rules.**
The unattended gate fires AFTER the tier-specific preflight (§5.3 preflight for `suggested`,
§5.4 backup-write for `destructive`) completes and BEFORE the interactive prompt. If preflight fails,
exit 68 is returned from the preflight path — the unattended queue path is not reached. The
`defend.modsec` auto-apply exception is the only downgrade: `suggested → execute-without-prompt` when
unattended and preflight passes.

**Escape hatch.**
Set `unattended_mode="0"` in `/etc/blacklight/blacklight.conf` to force interactive mode even when
invoked from a hook or cron. This overrides layers 4 and 5 but NOT layers 1 or 2 (explicit CLI flag
and `BL_UNATTENDED=1` always win). The `blacklight.conf.default` ships with `unattended_mode="0"`
so operator configuration is required to enable unattended behavior.

---

## 6. Fail-closed contract for `unknown`

Expanded from §5.5. The `unknown` tier is a **safety floor**, not a default. Three properties:

1. **No implicit `unknown`.** Every verb in `schemas/step.json` `verb` enum has an explicit `action_tier` mapping in `schemas/step.md` (see the "Tier (typical)" column). If a step arrives with `verb: <unknown-value>`, the wrapper rejects at schema-validation (exit 67) — it never reaches `unknown`-tier evaluation. The `unknown` tier exists only for operator-explicit `--unsafe` bypass, not for curator-authored anomalies.
2. **Audit is non-negotiable.** Even a denied `unknown` step writes a ledger entry. This creates forensic evidence of the curator attempting a novel verb — useful signal for "what's the agent trying to do that the wrapper doesn't support yet".
3. **Operator override is two-flag.** `--unsafe` (acknowledges the tier) + `--yes` (acknowledges the specific step). Single-flag forms are rejected; this prevents operator-muscle-memory `bl run s-XXXX --yes` from escalating an `unknown` action into execution.

Authoring rule echo (§4 rule 6): the curator should route would-be-`unknown` operations to `open-questions.md` instead. Regulator-friendly, operator-reviewable, and reversible by default.

---

## 7. Worked examples

Three JSON `report_step` payloads, one per non-trivial tier. All are jq-parseable and schema-conformant against `schemas/step.json`.

### 7.1 `auto` — new firewall block, CDN-safelist-clear

```json
{
  "step_id": "s-0042",
  "verb": "defend.firewall",
  "action_tier": "auto",
  "reasoning": "obs-0071 identified client_ip 203.0.113.51 generating 8412 POST /a.php/banner.jpg requests across 6 compromised hosts in 30 minutes. ASN lookup: not on the CDN safelist (skills/defense-synthesis/firewall-rules.md Cloudflare+Fastly+Akamai+CloudFront list checked). Per authoring rule 2, action_tier=auto with 15-minute veto window.",
  "args": [
    {"key": "ip", "value": "203.0.113.51"},
    {"key": "backend", "value": "iptables"},
    {"key": "case_tag", "value": "CASE-2026-0007"}
  ],
  "diff": "+ iptables -I INPUT -s 203.0.113.51 -j DROP -m comment --comment \"bl-case CASE-2026-0007 polyshell-c2\"",
  "patch": ""
}
```

Wrapper behavior: applies iptables rule, writes ledger entry, sends Slack notification with `veto-window: 15m` marker, returns exit 0.

### 7.2 `suggested` — new ModSec rule

```json
{
  "step_id": "s-0043",
  "verb": "defend.modsec",
  "action_tier": "suggested",
  "reasoning": "obs-0038 + obs-0041 confirm polyshell staging at /pub/media/.../a.php/banner.jpg. Rule targets REQUEST_FILENAME matching \\.php/[^/]+\\.(jpg|png|gif)$ in phase:2. apachectl -t passes against staged config. Per authoring rule 4, defend.modsec is always suggested — operator confirms the regex won't false-positive on legitimate Magento asset paths before apply.",
  "args": [
    {"key": "rule_file", "value": "/var/lib/bl/cases/CASE-2026-0007/actions/pending/act-0003.conf"}
  ],
  "diff": "--- a/etc/modsecurity/crs/REQUEST-941.conf\n+++ b/etc/modsecurity/crs/REQUEST-941.conf\n@@ ...\n+SecRule REQUEST_FILENAME \"@rx \\.php/[^/]+\\.(jpg|png|gif)$\" \\\n+    \"id:941999,phase:2,deny,log,msg:'polyshell double-ext staging'\"",
  "patch": ""
}
```

Wrapper behavior: runs `apachectl -t` on staged config → displays diff → blocks until `bl run s-0043 --yes` → applies + ledgers. Operator declines → exit 68 with `reason: operator-declined`.

### 7.3 `destructive` — remove injected `.htaccess` directive

```json
{
  "step_id": "s-0044",
  "verb": "clean.htaccess",
  "action_tier": "destructive",
  "reasoning": "obs-0055 flagged /var/www/html/.htaccess line 42 'AddHandler application/x-httpd-php .jpg' as injected (polyshell staging mechanism per skills/webshell-families/polyshell.md). Removing the directive closes the PHP-as-image execution path. Backup written to /var/lib/bl/backups/ before edit per authoring rule 5.",
  "args": [
    {"key": "file", "value": "/var/www/html/.htaccess"},
    {"key": "line", "value": "42"},
    {"key": "expected_sha256", "value": "a3f5..."}
  ],
  "diff": "--- a/var/www/html/.htaccess\n+++ b/var/www/html/.htaccess\n@@ -40,7 +40,5 @@\n RewriteRule ^(.*)$ index.php [L]\n </IfModule>\n \n-AddHandler application/x-httpd-php .jpg\n-\n # End of file",
  "patch": ""
}
```

Wrapper behavior: reads `/var/www/html/.htaccess`, verifies `sha256 == expected_sha256` (drift detection), writes pre-image to `/var/lib/bl/backups/CASE-2026-0007/2026-04-24T14:22:07Z-s-0044.htaccess`, displays diff → blocks until `bl run s-0044 --yes` → applies + ledgers.

---

## 8. Change control

Tier metadata is a **three-way contract** between `schemas/step.json` (wire form), `docs/action-tiers.md §2` + §3 (this file, authoritative prose), and `DESIGN.md §6` (narrative companion). Any edit that touches any of the three must update all three in the same commit. Specifically:

- Adding a tier: `schemas/step.json` `action_tier.enum[]` + §2 row + §3 crosswalk row + §5 subsection + DESIGN.md §6 table + at least one authoring rule in §4. Same commit. The reviewer flags missing targets as MUST-FIX.
- Removing a tier: only if no verb in `schemas/step.json` `verb.enum[]` maps to it (grep `schemas/step.md` "Tier (typical)" column). Remove from all three surfaces + strip from `DESIGN.md §6` + scrub any skills/ reference. Same commit.
- Renaming a slug: breaking change at the wire level — every `report_step` payload in memory stores from before the rename becomes invalid. Not recommended; prefer additive changes.
- Reordering rows: cosmetic; not breaking; but update §3 crosswalk to preserve the slug ↔ prose mapping invariant.

Adding a verb without touching tier metadata is fine — new verb lands in `schemas/step.json` `verb.enum[]` + `schemas/step.md` tier-typical column; tier table unchanged. The tier table defines the five *classes*; individual verbs map into those classes.
