# M4 — `bl observe` design

**Spec date:** 2026-04-24
**Motion:** M4 (PLAN.md lines 165–177 — "Per-motion dispatch sketches §M4")
**Depends on:** M1 (`bl` skeleton committed; `bl_observe` stub present as handler-hook at `bl:333`)
**Parallel-safe with:** M5 (`bl consult`/`bl run`/`bl case`) · M6 (`bl defend`) · M7 (`bl clean`) · M8 (`bl setup`) — all share the single-file `bl` per M0 §0.2
**Author:** clean-room, operator-absent autonomous progression per CLAUDE.md §Execution posture
**Downstream plan target:** `PLAN-M4.md` (excluded via `.git/info/exclude` `PLAN*.md`)

---

## 0. Gate-blocking open calls from PLAN.md §"Open calls" (carried into M4)

PLAN.md §"Open calls — resolve before dispatching" §1 + §2 are M0-owned but have direct bearing on M4's surface. Both are locked in `docs/specs/2026-04-24-M0-contracts-lockdown.md §0.1–§0.2` and re-verified here:

### 0.1 `bl` layout — single-file (M0 §0.2, committed `4ec1c23`)

M4 lands all 11 observe handler bodies plus the bundle builder **inside the single-file `bl`** at repo root, under the `bl_observe_*` namespace prefix. No `files/bl.d/` assembly, no sourcing. M1 pre-seeded `bl_observe()` as an empty stub at `bl:333`; M4 replaces that stub with a verb-dispatching router and adds 12 handler functions (11 observe verbs + `bl_bundle_build`). Worktree merge discipline: M4 only touches `bl_observe` + the 12 new functions. No edits to shared helpers (`bl_api_call`, `bl_init_workdir`, `bl_preflight`, `bl_error_envelope`, loggers) — M1 owns them and M4 consumes them. Reviewer flags cross-prefix leakage at merge.

### 0.2 Fence-token scope — per-payload (M0 §0.1, committed `4ec1c23`)

M4 is out of scope for fence-token emission — that belongs to M9 hardening (`prompts/curator-agent.md` injection preamble + step validation at `bl run`). But the evidence envelope `bl observe` writes **is** the payload the fence wraps downstream. M4's contract: every record emitted by `bl_observe_*` MUST include the preamble fields `{ts, host, case, obs, source, record}` exactly as `schemas/evidence-envelope.md §1` specifies — no extras, no omissions — because the fence-token input is `sha256(case || obs || payload)[:16]` and payload drift breaks fence reproducibility downstream. The scrub pass (no tenant tokens / customer hostnames / cPanel usernames — `schemas/evidence-envelope.md §1 preamble invariants`) fires at emit time inside each handler, not at bundle time.

Both open calls now locked upstream. M4 dispatch is unblocked.

---

## 1. Problem statement

`DESIGN.md §5.1` (lines 134–187) enumerates eleven `bl observe` verbs — the read-only evidence-extraction surface the curator reasons over. At current HEAD (`905f1d3`), the surface is absent:

| Artifact | Status | Evidence |
|---|---|---|
| `bl_observe()` in `bl` | stub at `bl:333` returning 64 with `"observe not yet implemented (M4)"` | `grep -n '^bl_observe' bl` |
| `bl_observe_*` verb handlers | **none exist** | `grep -cE '^bl_observe_' bl` → 0 |
| `bl_bundle_build()` | **does not exist** | `grep -n 'bl_bundle_build' bl` → 0 |
| `tests/04-observe.bats` | **does not exist** | `ls tests/*.bats` → `00-smoke.bats` only |
| `tests/fixtures/` | **does not exist** | `ls tests/fixtures/` → errno 2 |
| Evidence write path `bl-case/CASE-<id>/evidence/obs-<ts>-<kind>.json` | path contract exists in `docs/case-layout.md §3` row 5 but no writer | case-layout row `wrapper | on-evidence-ingest | 50 KB | immutable-after-write` |

Downstream dependency chain (all block until M4 lands):

- **M5** (`bl consult --new`): a newly opened case has zero evidence unless `bl observe <verb>` can fire against the case-id and write under `bl-case/CASE-<id>/evidence/`. Demo flow collapses without this.
- **M6** (`bl defend`): `defend.modsec` + `defend.firewall` proposals cite `obs-<id>` references in step reasoning; no obs records → no citations → curator proposes blind.
- **M7** (`bl clean`): `clean.htaccess`, `clean.cron`, `clean.proc` consume the respective `observe.htaccess`, `observe.cron`, `observe.proc` output to show the operator what will change. Without observe records, the diff has no source-of-truth.
- **M9** (hardening): the untrusted-content fence wraps payloads that `bl observe` produces. The fence is a M9 deliverable; the payload it wraps is M4.

M4 is the first motion to emit real evidence. It is load-bearing for demo, curator reasoning depth, and every remediation pipeline that follows.

---

## 2. Goals

Eleven numbered goals. Each goal is measurable; each has a verification command in §10b and a test in §10a.

1. **G1** — `bl_observe` dispatches eleven verb sub-commands (`file`, `log apache`, `log modsec`, `log journal`, `cron`, `proc`, `htaccess`, `fs --mtime-cluster`, `fs --mtime-since`, `firewall`, `sigs`) plus one sub-command `bundle` (build evidence bundle). Dispatches to `bl_observe_file` etc. Unknown sub-verb → exit 64.
2. **G2** — Each of the eleven observe handlers emits JSONL to stdout conforming exactly to `schemas/evidence-envelope.md §1` preamble (`ts`, `host`, `case`, `obs`, `source`, `record`) plus the §3 per-source record fields. `additionalProperties: false` enforced at emit (no stray keys).
3. **G3** — Each handler writes its full JSONL stream (plus exactly one `observe.summary` trailer record) to `bl-case/CASE-<id>/evidence/obs-<ts>-<kind>.json` when a case is active (`bl_case_current` returns non-empty). When no case is active, handlers emit to stdout only (ad-hoc `bl observe` outside a case context is permitted per `schemas/evidence-envelope.md §1 preamble.case` — `null` on the record).
4. **G4** — Every handler is classified `read-only` per `docs/action-tiers.md §2 Tier table` row 1 / `docs/action-tiers.md §5.1 Gate behavior`. No tier gate prompt, no `--yes` flag, no backup write, no ledger entry to `/var/lib/bl/ledger/`. Standard case log only.
5. **G5** — Scrub pass (no cPanel usernames / customer tenant tokens / internal DNS names / Liquid Web internal references) fires at emit time in every handler. Verification: no operator-local hostnames appear in any committed fixture or test artifact (`tests/fixtures/`).
6. **G6** — `bl_bundle_build` packages the current case's evidence directory into a single `tar + gzip -5` archive (or `tar + zstd -3` when `command -v zstd` succeeds and `--format zst` is requested) per `DESIGN.md §10.2 Bundle shape` + `§10.4 Compression`. Archive layout matches §10.2: `MANIFEST.json`, `summary.md`, and one `.jsonl` per source-class.
7. **G7** — `MANIFEST.json` written by bundle builder conforms to the schema in §5.12 below (`bl_version`, `host`, `case_id`, `generated_at`, `window`, `entries[]` with per-entry `{path, source, sha256, size_bytes, record_count}`, `total_size_bytes`).
8. **G8** — Every observe handler failure is mapped to a code from `docs/exit-codes.md §1`: source-missing → 72 (`NOT_FOUND`), unreadable path / perm denied → 65 (`PREFLIGHT_FAIL` — with phase string `observe`), jq/coreutil missing → 65, invalid arguments → 64, invalid JSONL assembled (internal invariant break) → 67 (`SCHEMA_VALIDATION_FAIL`). Never `exit 1` / `exit 2`.
9. **G9** — Portability: every coreutil invocation uses `command` prefix per CLAUDE.md §Shell Standards; no `/usr/bin/` hardcoding; no `which`; no `egrep`; no `$[]`; no `|| true` / `2>/dev/null` without an inline justification comment on the same line. Runs on bash 4.1 floor (CentOS 6 — no `declare -A` at global scope; no `${var,,}`; no `mapfile -d`; no `$EPOCHSECONDS`).
10. **G10** — `tests/04-observe.bats` covers every verb: happy path (fixture parses to expected record count + every record schema-conforms via `tests/helpers/assert-jsonl.bash`), malformed-input path (source file corrupted / truncated / wrong format → exit 65 or 67 with distinct diagnostic), missing-source path (source file absent → exit 72), tier-check (no confirmation prompt — handler runs non-interactively). All fixtures under `tests/fixtures/` are clean-room APSB25-94-shaped.
11. **G11** — `bl -n` + `shellcheck bl` remain clean after M4's additions (M1's lint gates inherit).

---

## 3. Non-goals

- **NG1.** Curator-side evidence interpretation. M4 produces JSONL; the curator consumes it via Files API + memstore reads in later motions. Interpretation is a skills-bundle + prompts concern (M3 already landed).
- **NG2.** Fixture fabrication for the full demo walkthrough. `docs/demo-fixture-spec.md` (landed M0-adjacent at `4ec1c23`) owns the demo envelope. M4 fixtures are parse-level unit inputs, not narrative demo data.
- **NG3.** Live API call to Anthropic during `bl observe`. `bl observe` is wrapper-side only — emits JSONL, writes files. No `bl_api_call` usage in any `bl_observe_*` body (M8 `bl setup` owns API-bound activity; M5 `bl_poll_pending` owns curator session I/O).
- **NG4.** `bl observe upload` / `bl observe attach` file-to-memstore transfer. `bl_bundle_build` produces a `.tgz`; the operator or `bl consult --upload <bundle>` (M5) ships it upstream.
- **NG5.** Legacy syslog (non-journal) parsing. `bl_observe_log_journal` is journal-native via `journalctl`; hosts without systemd fall back to documented-absent (handler returns 72 with `journalctl not available` and `backend_meta.syslog_fallback: true` in the summary). A future motion may add `/var/log/messages` + `/var/log/secure` parse as a fallback path; M4 does not.
- **NG6.** `bl observe signal` / inbound webhook receiver. Out of scope; the operator drives observe invocations; no daemon.
- **NG7.** `schemas/evidence-envelope.md` edits. M4 is a pure consumer of that contract. Drift between emitted records and the envelope schema is a M4 bug, never an envelope-schema bug.
- **NG8.** Tier gate enforcement code for observe. Tier gate is M5's `bl run` concern; all observe verbs are `read-only` (`docs/action-tiers.md §5.1 Gate behavior` — "Execute: immediately, no confirm"). M4 handlers run directly; they do NOT path through `bl run`.
- **NG9.** Cross-host correlation / fleet roll-up. `bl observe` is per-host per `DESIGN.md §15`. Fleet correlation lives in the curator's session state via evidence-envelope `host` field + obs-id aggregation, not in `bl`.
- **NG10.** File integrity attestation (signature on `MANIFEST.json`). Bundle `sha256` per entry is sufficient for tamper-detection at upload time; cryptographic signing is M10 roadmap if ever.
- **NG11.** `bl observe --follow` tail-style continuous emission. Observe is request/response; continuous posture monitoring is explicitly out per `DESIGN.md §15`.

---

## 4. Architecture

### 4.1 File map

All changes land in one commit per M4. No file deletions.

| # | File | Status | Est. lines | Purpose |
|---|------|--------|-----------:|---------|
| 1 | `bl` | **modify** | +~800 | Replace `bl_observe` stub at `bl:333` with verb dispatcher; add 11 `bl_observe_*` handlers + `bl_bundle_build` + ~6 private helpers (scrub, jsonl emit, summary builder, path validation, codec detect, obs-id allocator) |
| 2 | `tests/04-observe.bats` | **new** | ~480 | One test group per verb (12 groups × 3–5 `@test` each); plus bundle-build test group; ~60 `@test` entries total |
| 3 | `tests/helpers/assert-jsonl.bash` | **new** | ~90 | `jq`-based schema validator against `schemas/evidence-envelope.md §1 preamble` + §3 source-specific record field sets |
| 4 | `tests/helpers/observe-fixture-setup.bash` | **new** | ~120 | Sets up an isolated `$BL_VAR_DIR`, stages fixture logs into `/tmp/bats-obs-$$/`, seeds a case under `bl-case/CASE-2026-9999/` per `docs/case-layout.md §3` writer-owner rows, cleans on teardown |
| 5 | `tests/fixtures/apache-apsb25-94.log` | **new** | ~60 | Clean-room combined-log fixture (12 lines) — reconstructs APSB25-94 double-extension-jpg staging from public advisory only |
| 6 | `tests/fixtures/modsec-apsb25-94.log` | **new** | ~50 | Clean-room ModSec audit log (3 transactions, A/B/F/H sections) |
| 7 | `tests/fixtures/cron-injected.txt` | **new** | ~8 | Crontab fixture with ANSI ESC[2J obscured line + clean line |
| 8 | `tests/fixtures/htaccess-injected` | **new** | ~15 | `.htaccess` fixture with `AddHandler application/x-httpd-php .jpg` injection + clean directives |
| 9 | `tests/fixtures/iptables-dump.txt` | **new** | ~18 | Sample `iptables -L -n --line-numbers` output with a `bl-case`-tagged rule + third-party rules |
| 10 | `tests/fixtures/nftables-dump.txt` | **new** | ~14 | Sample `nft list ruleset` output |
| 11 | `tests/fixtures/maldet-sigs.hdb` | **new** | ~6 | 3 sample signature lines in maldet hdb format (public syntax only) |
| 12 | `tests/fixtures/proc-verify-argv.txt` | **new** | ~10 | `ps` + `/proc/<pid>/exe` readlink pairs, one with argv-spoof (`argv0=mariadbd`, exe=httpd) |
| 13 | `tests/fixtures/fs-mtime-cluster/` | **new (dir)** | (7 files) | 7 empty files with `touch -d` stamps forming a 4-second mtime cluster |
| 14 | `tests/fixtures/journal-entries.json` | **new** | ~12 | `journalctl -o json` sample output (5 lines) — synthesized for portable fallback (see NG5) |
| 15 | `tests/fixtures/file-triage-target.php` | **new** | ~20 | Sample PHP file with polyshell-shape strings (public APSB25-94 markers only) |

**Size comparison:**

| Surface | Before M4 (HEAD `905f1d3`) | After M4 |
|---|---:|---:|
| `bl` lines | 382 | ~1180 |
| `tests/*.bats` files | 1 | 2 |
| `tests/*.bats` total @test count | ~2 | ~62 |
| `tests/fixtures/` files | 0 | 12 |
| `tests/helpers/` files | 1 | 3 |

Final `bl` size (~1180 LOC) remains under the DESIGN.md §3 ~1500-line ceiling; M5–M8 bring the final size closer to the cap.

### 4.2 Dependency tree

```
bl (single file, M1 frame; M4 extends bl_observe)
│
├── M1 surface (consumed, not modified) ─────────────────────────
│   ├── bl_preflight            → runs before every verb dispatch
│   ├── bl_init_workdir         → ensures /var/lib/bl/{backups,quarantine,…} exist
│   ├── bl_error_envelope       → phase-prefixed stderr formatting
│   ├── bl_info/warn/error/debug→ level-filtered stderr loggers
│   ├── bl_case_current         → reads /var/lib/bl/state/case.current
│   ├── BL_EX_* constants       → exit code symbolic names (65/67/68/72 used)
│   └── BL_VAR_DIR / BL_STATE_DIR → workdir path roots
│
├── M4 new top-level dispatcher rewrite ──────────────────────────
│   └── bl_observe(args…) → parse sub-verb + flags → dispatch to bl_observe_<verb> or bl_bundle_build
│
├── M4 private helpers (file-local; not exported) ────────────────
│   ├── _bl_obs_scrub           → strips cPanel usernames / customer tokens / internal DNS from a record
│   ├── _bl_obs_emit_jsonl      → assembles preamble + record, validates preamble shape, writes one line
│   ├── _bl_obs_open_stream     → opens (case-scoped) obs-<ts>-<kind>.json; rotates on-conflict
│   ├── _bl_obs_close_stream    → emits observe.summary trailer; closes file; flips immutable bit
│   ├── _bl_obs_allocate_obs_id → deterministic obs-NNNN allocation within one invocation (monotonic per-process)
│   ├── _bl_obs_ts_iso8601      → ISO-8601 UTC with ms (`date -u +%Y-%m-%dT%H:%M:%S.%3NZ`)
│   ├── _bl_obs_host_label      → `${BL_HOST_LABEL:-$(hostname -s)}`
│   └── _bl_obs_detect_firewall → checks `command -v apf / csf / nft / iptables` in that order; reports backend name
│
├── M4 verb handlers (11) ────────────────────────────────────────
│   ├── bl_observe_file                    → emits source=file.triage
│   ├── bl_observe_log_apache              → emits source=apache.transfer (+ apache.error if present)
│   ├── bl_observe_log_modsec              → emits source=modsec.audit
│   ├── bl_observe_log_journal             → emits source=journal.entry
│   ├── bl_observe_cron                    → emits source=cron.entry
│   ├── bl_observe_proc                    → emits source=proc.snapshot (with --verify-argv compares cmdline vs exe)
│   ├── bl_observe_htaccess                → emits source=htaccess.directive (only flagged; clean suppressed)
│   ├── bl_observe_fs_mtime_cluster        → emits source=fs.mtime_cluster
│   ├── bl_observe_fs_mtime_since          → emits source=fs.mtime_since
│   ├── bl_observe_firewall                → emits source=firewall.rule (+ backend_meta in summary)
│   └── bl_observe_sigs                    → emits source=sig.loaded (+ backend_meta in summary)
│
└── M4 bundle builder ────────────────────────────────────────────
    └── bl_bundle_build [--format gz|zst] [--since <ISO-ts>] → packages bl-case/CASE-<id>/evidence/*.json into bundle-<host>-<window>.tgz + MANIFEST.json + summary.md
```

### 4.3 Key changes

1. **`bl_observe` stub at `bl:333` is replaced** with a verb-dispatching router. Shape mirrors the top-level dispatcher at `bl:main`: flag sniff (`--help`, `--case <id>`, `--out-dir <dir>`) → sub-verb case statement → handler call. `bl_observe` returns the handler's exit code unaltered.
2. **Dispatcher expands to parse compound verbs.** `log apache`, `log modsec`, `log journal` share a `log` prefix; `fs --mtime-cluster` and `fs --mtime-since` share an `fs` prefix with flag-discrimination. The router handles both shapes; no sub-dispatcher functions are introduced.
3. **Eleven new handlers adopt disjoint function names** under the `bl_observe_*` prefix per M0 §0.2 worktree discipline. Every `fs` sub-verb uses `_` in the function name (`bl_observe_fs_mtime_cluster`, `bl_observe_fs_mtime_since`) to avoid compound-name collisions at grep time.
4. **`bl_bundle_build` is a verb (`bl observe bundle`), not a top-level command.** The observe namespace owns the bundle — it reads `bl-case/CASE-<id>/evidence/` (which only observe populates) and produces a `.tgz`. Rationale: observe is the only writer; no other namespace has a reason to read the evidence dir. Keeping bundle under `bl observe bundle` preserves the one-namespace-one-owner rule.
5. **Every handler writes to two sinks.** Stdout (JSONL on the wire for pipe-to-jq / pipe-to-`tee` operator workflows) AND `bl-case/CASE-<id>/evidence/obs-<ts>-<kind>.json` (structured for curator ingestion, `docs/case-layout.md §3` row 5 — writer: wrapper, when: on-evidence-ingest, cap: 50 KB per file, lifecycle: immutable-after-write). When no case is active, stdout-only; the case-pathed sink is silent.
6. **Scrub fires inline per-record.** Scrub helper `_bl_obs_scrub` is invoked inside `_bl_obs_emit_jsonl` BEFORE write (not post-bundle). This catches operator-local identifiers at the earliest possible stage; bundle builder does not re-scrub (assume records are already clean). Dual-scrub would be defense-in-depth but introduces the risk of double-mutation breaking sha256 reproducibility.
7. **Compression detection is runtime** per `DESIGN.md §10.4`. `_bl_obs_codec_detect` picks zstd if `command -v zstd` succeeds AND (`--format` absent OR `--format zst`); gzip otherwise. Extension is always `.tgz` regardless (tar magic-byte detects on decompress). `MANIFEST.json` carries the chosen codec in `codec` field for introspection.
8. **`observe.summary` trailer is always emitted.** Every handler emits exactly one `observe.summary` record after its main JSONL stream, carrying counts, top-N buckets, time span, and (for `observe.firewall` / `observe.sigs`) `backend_meta`. The curator reads this record first (highest signal) per `schemas/evidence-envelope.md §3.13`.
9. **Case-pathed evidence file naming.** `obs-<ts>-<kind>.json` where `<ts>` is ISO-8601 UTC with `:` replaced by `-` (filesystem-portable; Windows-aware for future `bl` ports); `<kind>` is one of `file`, `log-apache`, `log-modsec`, `log-journal`, `cron`, `proc`, `htaccess`, `fs-mtime-cluster`, `fs-mtime-since`, `firewall`, `sigs`. `_bl_obs_open_stream` rotates to `obs-<ts>-<kind>.N.json` if a conflict exists within the same-second window (BATS loop risk).

### 4.4 Wave-2 parallelism contract

**File ownership at merge time** (per M0 §0.2):

- **M4 owns:** `bl_observe()` + 11 `bl_observe_*` + `bl_bundle_build` + 6 `_bl_obs_*` private helpers + `tests/04-observe.bats` + `tests/fixtures/*` + `tests/helpers/assert-jsonl.bash` + `tests/helpers/observe-fixture-setup.bash`.
- **M4 does NOT touch:** `bl_preflight`, `bl_init_workdir`, `bl_api_call`, `bl_poll_pending`, `bl_case_current`, any `bl_consult_*` / `bl_run_*` / `bl_case_*` / `bl_defend_*` / `bl_clean_*` / `bl_setup_*` function, any `BL_EX_*` constant declaration, `main()`, the top-level dispatcher case statement, `bl_usage`, `bl_version`, or any file outside `bl` + `tests/`.
- **Shared helper consumption (read-only):** `bl_error_envelope`, `bl_info`/`bl_warn`/`bl_error`/`bl_debug`, `bl_case_current`, `bl_init_workdir` (called from `bl_bundle_build` to ensure `/var/lib/bl/outbox/` exists for bundle staging), `BL_EX_PREFLIGHT_FAIL`, `BL_EX_NOT_FOUND`, `BL_EX_USAGE`, `BL_EX_SCHEMA_VALIDATION_FAIL`, `BL_VAR_DIR`.
- **Shared file `bl`: merge strategy** — M4's additions all land in a clearly-bounded region of `bl` (between the M1 handler-stub block at `bl:330–340` and `main` at file-bottom). M5/M6/M7/M8 concurrent worktrees add their handlers in adjacent disjoint regions. Reviewer at merge asserts no cross-prefix function bodies (e.g., no `bl_observe_*` body calls `bl_clean_*` — observe is the deepest-left in the dispatch DAG, calling rightward only into shared helpers).

**Namespace collision check at merge time:**

```bash
# No bl_observe_* handler may reference a function name from a sibling namespace
grep -nE '^bl_observe_.*\(\)|bl_(consult|run|case|defend|clean|setup)_' bl | \
  awk -F: '/^bl_observe_/ {fn=$3; next} fn && $0 ~ fn {print "leak: " $0}'
# expect: (no output)
```

### 4.5 Dependency rules

- **Single-file constraint (M0 §0.2):** no `source` directives in any M4 code; no `. files/bl.d/observe.sh`; no per-verb sub-files. Every `bl_observe_*` body lives in `bl`.
- **No API calls:** grep-verified in §10b — `grep -nE 'bl_api_call' bl | awk -F: '{print $1}' | xargs -I{} awk -v L={} 'NR==L {if (in_observe) print L":"$0} /^bl_observe/{in_observe=1} /^[a-z]/&&!/^bl_observe/{in_observe=0}' bl` returns empty.
- **Coreutil prefix:** every `find`, `sort`, `uniq`, `sha256sum`, `stat`, `tar`, `gzip`, `awk`, `sed`, `grep`, `cat`, `mkdir`, `touch`, `ln`, `cp`, `mv`, `rm`, `head`, `tail`, `wc`, `chmod` uses `command` prefix per workspace CLAUDE.md §Shell Standards. `printf` and `echo` are bash builtins (used bare).
- **`cd` guards:** every `cd` inside a handler has `|| exit "$BL_EX_NOT_FOUND"` (operator-supplied path missing) or `|| exit "$BL_EX_PREFLIGHT_FAIL"` (internal invariant violation).
- **No `declare -A` at global scope:** CLAUDE.md §Bash 4.1+ Floor. Handler-local `local -A` is permitted inside functions (safe — does not leak when sourced).
- **Top-down reading order** within the bl_observe block: M1 helpers (stable) → M4 private helpers (_bl_obs_*) → 11 verb handlers → bundle builder → bl_observe router. Matches call depth.

---

## 5. File contents

### 5.1 `bl_observe` — top-level dispatcher

Replaces the M1 stub at `bl:333`. Signature:

```bash
bl_observe() {
    # args consumed: $1 = sub-verb (file|log|cron|proc|htaccess|fs|firewall|sigs|bundle)
    # $2+ = sub-verb-specific flags/positional args
    local sub="${1:-}"
    [[ -z "$sub" ]] && { bl_error_envelope observe "missing sub-verb (use \`bl --help\` for usage)"; return "$BL_EX_USAGE"; }
    shift
    case "$sub" in
        file)     bl_observe_file "$@"         ;;
        log)
            local kind="${1:-}"
            shift || true    # safe: shift with no args is a no-op under set -u guard
            case "$kind" in
                apache)  bl_observe_log_apache "$@"  ;;
                modsec)  bl_observe_log_modsec "$@"  ;;
                journal) bl_observe_log_journal "$@" ;;
                *) bl_error_envelope observe "unknown log kind: $kind (use apache|modsec|journal)"; return "$BL_EX_USAGE" ;;
            esac
            ;;
        cron)     bl_observe_cron "$@"         ;;
        proc)     bl_observe_proc "$@"         ;;
        htaccess) bl_observe_htaccess "$@"     ;;
        fs)
            # fs sub-verb is flag-discriminated
            case "${1:-}" in
                --mtime-cluster) shift; bl_observe_fs_mtime_cluster "$@" ;;
                --mtime-since)   shift; bl_observe_fs_mtime_since "$@"   ;;
                *) bl_error_envelope observe "fs requires --mtime-cluster or --mtime-since"; return "$BL_EX_USAGE" ;;
            esac
            ;;
        firewall) bl_observe_firewall "$@"     ;;
        sigs)     bl_observe_sigs "$@"         ;;
        bundle)   bl_bundle_build "$@"         ;;
        *) bl_error_envelope observe "unknown sub-verb: $sub"; return "$BL_EX_USAGE" ;;
    esac
}
```

**Note (self-correction):** `shift || true` on line 7 above needs justification because CLAUDE.md §Shell Standards prohibits `|| true` without inline comment. In this context the `shift` may run with `$#=0` if the operator types `bl observe log` with no kind; `shift` under `set -u` with no positional args is not actually an error (empty shift is a no-op, return 1 from bash 4.1+ but not a fatal). The safer form is the pattern used in `bl_observe_fs` — sniff `${1:-}` first, then shift only on match. Preferred rewrite (used in implementation):

```bash
log)
    local kind="${1:-}"
    [[ -z "$kind" ]] && { bl_error_envelope observe "missing log kind (use apache|modsec|journal)"; return "$BL_EX_USAGE"; }
    shift
    case "$kind" in
        apache)  bl_observe_log_apache "$@"  ;;
        modsec)  bl_observe_log_modsec "$@"  ;;
        journal) bl_observe_log_journal "$@" ;;
        *) bl_error_envelope observe "unknown log kind: $kind"; return "$BL_EX_USAGE" ;;
    esac
    ;;
```

No `|| true` needed because `$kind` is empty-guarded before shift.

### 5.2 Function inventory — private helpers + handlers + bundle

| Function | Signature | Returns | Emits | Inputs it reads | Tier |
|---|---|---:|---|---|---|
| `_bl_obs_scrub` | `(record-json-string) → stdout scrubbed string` | 0 | — | `$BL_HOST_LABEL`, record string | n/a |
| `_bl_obs_emit_jsonl` | `(source, record-json, [stream-path])` | 0/67 | one JSONL line to stdout (always) + stream-path (if case-scoped) | preamble fields via `_bl_obs_ts_iso8601` + `_bl_obs_host_label` + `bl_case_current` + allocator | n/a |
| `_bl_obs_open_stream` | `(kind) → stdout stream-path` | 0/65 | — | `bl_case_current`, `$BL_VAR_DIR`, case-layout §3 row 5 path convention | n/a |
| `_bl_obs_close_stream` | `(stream-path, source, summary-json)` | 0/67 | one `observe.summary` JSONL line to stream-path | accumulated per-source counters (from handler scope via nameref) | n/a |
| `_bl_obs_allocate_obs_id` | `()` → `stdout obs-NNNN` | 0 | — | per-process counter in `$BL_VAR_DIR/state/obs_counter` | n/a |
| `_bl_obs_allocate_cluster_id` | `()` → `stdout c-NNNN` | 0 | — | per-invocation bash-local counter (handler-scoped; resets per `bl_observe_fs_mtime_cluster` call) | n/a |
| `_bl_obs_ts_iso8601` | `()` → `stdout YYYY-MM-DDTHH:MM:SS.mmmZ` | 0 | — | `command date -u` | n/a |
| `_bl_obs_host_label` | `()` → `stdout label` | 0 | — | `${BL_HOST_LABEL:-$(hostname -s)}` | n/a |
| `_bl_obs_detect_firewall` | `()` → `stdout backend-name` | 0/72 | — | `command -v apf/csf/nft/iptables` in that order | n/a |
| `_bl_obs_size_guard` | `(path, max-bytes)` → return 0/65 | 0/65 | — | `stat -c %s "$path"` | n/a |
| `_bl_obs_codec_detect` | `(requested-format)` → `stdout gz\|zst` | 0 | — | `command -v zstd` | n/a |
| `bl_observe_file` | `(path)` | 0/64/65/72 | source=`file.triage` | target file stat + magic + strings + sha256 | read-only |
| `bl_observe_log_apache` | `(--around path [--window 6h] [--site fqdn])` | 0/64/65/72 | source=`apache.transfer` (+ `apache.error` if error log co-located) | vhost access log located via heuristic (see §5.5) | read-only |
| `bl_observe_log_modsec` | `([--txn id] [--rule id] [--around path --window 6h])` | 0/64/65/72 | source=`modsec.audit` | ModSec audit log at `/var/log/modsec_audit.log` or `/var/log/apache2/modsec_audit.log` | read-only |
| `bl_observe_log_journal` | `(--since time [--grep pattern])` | 0/64/65/72 | source=`journal.entry` | `journalctl -o json --since <time> [-g <pattern>]` | read-only |
| `bl_observe_cron` | `(--user user [--system])` | 0/64/65/72 | source=`cron.entry` | `crontab -u <user> -l \| cat -v`; `--system` adds `/etc/cron.d/`, `/etc/crontab`, `/etc/cron.{hourly,daily,weekly,monthly}/` | read-only |
| `bl_observe_proc` | `(--user user [--verify-argv])` | 0/64/65/72 | source=`proc.snapshot` | `ps -u <user> -o pid,user,args` + `/proc/<pid>/exe` readlink for spoof detection | read-only |
| `bl_observe_htaccess` | `(dir [--recursive])` | 0/64/65/72 | source=`htaccess.directive` (flagged only) | `.htaccess` files under `dir` | read-only |
| `bl_observe_fs_mtime_cluster` | `(path --window Ns [--ext extlist])` | 0/64/65/72 | source=`fs.mtime_cluster` | `find path -type f [-name '*.ext']*` + `stat -c %Y %n` | read-only |
| `bl_observe_fs_mtime_since` | `(--since date [--under path] [--ext extlist])` | 0/64/65/72 | source=`fs.mtime_since` | `find path -type f -newermt <date>` | read-only |
| `bl_observe_firewall` | `([--backend auto\|apf\|csf\|iptables\|nftables])` | 0/64/65/72 | source=`firewall.rule` | backend-specific dump (`iptables-save`, `nft list ruleset`, `apf -l`, `csf -l`) | read-only |
| `bl_observe_sigs` | `([--scanner lmd\|clamav\|yara])` | 0/64/65/72 | source=`sig.loaded` | scanner-specific sig store (`/usr/local/maldetect/sigs/rfxn.hdb`, `/var/lib/clamav/*.cld`, yara rule files from configured paths) |  read-only |
| `bl_bundle_build` | `([--format gz\|zst] [--since ISO-ts])` | 0/64/65/72 | tar archive on disk + MANIFEST.json + summary.md | `bl-case/CASE-<id>/evidence/*.json` (on filesystem or mirrored via M5 later) | read-only |

### 5.3 `bl_observe_file` — source `file.triage`

**Invocation:** `bl observe file <path>`

**Exit codes:** 0 success · 64 (no path / too many args) · 72 (path does not exist) · 65 (path exists but unreadable or unstat-able) · 67 (internal JSONL invariant break).

**Inputs read:** the target file's stat metadata, first 512 bytes, printable strings ≥6 chars, sha256 of the full file. `file` command (magic classification) if present; absent → `"magic": null` in record and `backend_meta.file_missing: true` in summary.

**Record emitted** — `schemas/evidence-envelope.md §3.12`:

```json
{"path":"/var/www/html/pub/media/.../a.php","size":2451,"mode":"0644","owner":"www-data","mtime":"2026-04-23T14:22:07Z","sha256":"abcd…","magic":"PHP script, ASCII text","strings_sample":["BL-STAGE","chr(","base64_decode","gzinflate"],"strings_total":128}
```

`strings_sample` capped at top 32 printable ≥6-char strings; `strings_total` is full count from `command strings -n 6 "$path" | command wc -l`.

**Size guard:** handler calls `_bl_obs_size_guard "$path" $((64 * 1024 * 1024))` before strings/hash; files > 64 MB exit 65 with `blacklight: observe: file oversize (<N> MB > 64 MB cap)`. Rationale: `bl observe file` is a targeted triage, not a large-file hash. Operators scanning 500 MB binaries should use `bl observe fs --mtime-since` to select candidates, then `bl observe file` per candidate.

**Write path:** `bl-case/CASE-<id>/evidence/obs-<ts>-file.json` per `docs/case-layout.md §3 row 5`. Stdout always receives JSONL regardless of case context.

**Portability:** `stat -c` format varies — GNU coreutils vs BSD stat. Detect via `command -v stat` + `stat --version 2>/dev/null | grep -q GNU` fallback to `stat -f` (BSD). Owner readable on all platforms via `stat -c %U` (GNU) or `stat -f %Su` (BSD). `sha256sum` vs `shasum -a 256` selected by `command -v sha256sum || command -v shasum`. No `stat -c %Y\n%Z` — `stat -c` does not interpret escape sequences (CLAUDE.md anti-pattern #8). Use separate `stat -c %Y` and `stat -c %Z` calls.

**Failure modes:**

| Scenario | Exit | Diagnostic |
|---|---:|---|
| `$1` empty | 64 | `blacklight: observe: file requires path argument` |
| Path does not exist | 72 | `blacklight: observe: path not found: <path>` |
| Path exists but stat fails (broken symlink, EACCES) | 65 | `blacklight: observe: stat failed: <path>` |
| Path exists but read fails for hash/strings | 65 | `blacklight: observe: read failed: <path>` |
| `command -v sha256sum && command -v shasum` both fail | 65 | `blacklight: observe: no sha256 utility (need sha256sum or shasum)` |

### 5.4 `bl_observe_log_apache` — source `apache.transfer` (+ `apache.error`)

**Invocation:** `bl observe log apache --around <path> [--window 6h] [--site <fqdn>]`

**Exit codes:** 0 · 64 (no `--around`) · 65 (log file unreadable) · 72 (no matching vhost log located).

**Log location heuristic:**

1. If `--site <fqdn>` passed: look for `/var/log/apache2/<fqdn>.access.log`, `/var/log/httpd/<fqdn>-access_log`, `/home/*/logs/<fqdn>.log` (cpanel convention), `/var/log/nginx/<fqdn>.access.log` (nginx counted as apache-family here for operator convenience — nginx combined-log format is Apache-compatible).
2. Else: fall back to `/var/log/apache2/access.log` (Debian/Ubuntu), `/var/log/httpd/access_log` (RHEL/Rocky), `/var/log/nginx/access.log`.
3. All probes use `command -r` readability test before parsing.

**Parsing:** combined-log format via awk. Derived fields computed at parse time:

- `path_class` ∈ `{normal, double_ext_jpg, double_ext_png, double_ext_gif, double_slash, traversal_parent, null_byte, pct_encoded_suspicious}` per `skills/webshell-families/polyshell.md` (M3 landed) path-class vocabulary.
- `is_post_to_php` — true when `method=POST` AND `path ~ \.php(\?|$|/)`.
- `status_bucket` ∈ `{2xx, 3xx, 4xx, 5xx}`.

**Window filter:** `--window 6h` parsed as duration. ±window around `<path>`'s `mtime` — the file whose mtime anchors the incident (e.g., the newly staged webshell). Records outside the window are skipped at parse time (before scrub, before emit) to cap memory.

**Record emitted** — `schemas/evidence-envelope.md §3.1`. `apache.error` record (§3.2) fires if an error_log is co-located with the access_log (same directory, `error_log` basename) and has records in the window.

**Write path:** `bl-case/CASE-<id>/evidence/obs-<ts>-log-apache.json`.

**Summary record** (`observe.summary`, §3.13): top 20 IPs by 2xx count; top 20 paths by 2xx; POST-to-PHP count; status histogram; `attention[]` populated with `double_ext_*` paths that account for >1% of 2xx (threshold: obvious-signal only).

**Failure modes:**

| Scenario | Exit | Diagnostic |
|---|---:|---|
| `--around` missing | 64 | `blacklight: observe: log apache requires --around <path>` |
| `--window` malformed (not `Nh`/`Nm`/`Nd`) | 64 | `blacklight: observe: invalid window: <val>` |
| No vhost log located (heuristic exhausted) | 72 | `blacklight: observe: no apache log found (searched: <paths>)` |
| Log file exists but unreadable | 65 | `blacklight: observe: cannot read <path>` |
| awk not present | 65 | `blacklight: observe: awk required for apache log parse` |

### 5.5 `bl_observe_log_modsec` — source `modsec.audit`

**Invocation:** `bl observe log modsec [--txn <id>] [--rule <id>] [--around <path> --window 6h]`

**Exit codes:** 0 · 64 · 65 · 72.

**Log location:** probe `/var/log/modsec_audit.log`, `/var/log/apache2/modsec_audit.log`, `/var/log/httpd/modsec_audit.log`, `/var/log/nginx/modsec_audit.log`.

**Parsing:** ModSec `SecAuditLogType Serial` native format — transactions demarcated by `--<boundary>-A--` ... `--<boundary>-Z--`. Each transaction's A (audit-log header), B (request), F (final response header), H (action) sections are folded into one record. `SecAuditLogType Concurrent` (one file per txn under `/var/log/modsec_audit/YYYYMMDD/HHMM/<index>/<txn>`) is detected by tree shape; if detected, handler walks the concurrent tree.

**Filters:** `--txn <id>` matches `Section A` `unique_id`; `--rule <id>` matches `Section H` `Rule tag` entries. `--around <path>` + `--window` works the same way as apache (filter on Section A timestamp ±window around the anchor file's mtime).

**Record emitted** — `schemas/evidence-envelope.md §3.3`.

**Write path:** `bl-case/CASE-<id>/evidence/obs-<ts>-log-modsec.json`.

**Failure modes:**

| Scenario | Exit | Diagnostic |
|---|---:|---|
| No filter and no modsec log located | 72 | `blacklight: observe: no modsec audit log found` |
| `--txn <id>` passed but no match | 0 | no records + summary count=0 (not an error) |
| `--rule <id>` passed but malformed | 64 | `blacklight: observe: invalid rule id: <id>` |

### 5.6 `bl_observe_log_journal` — source `journal.entry`

**Invocation:** `bl observe log journal --since <time> [--grep <pattern>]`

**Exit codes:** 0 · 64 · 65 · 72 (if journalctl absent).

**Inputs read:** `journalctl -o json --since <time> [-g <pattern>]`. JSON-per-line output natively parseable.

**Portability note:** `journalctl` is systemd-only. CentOS 6 and pre-systemd distros do not have it. Per NG5, non-journal fallback is out of scope; handler returns 72 with `journalctl not available (systemd required)` and summary carries `backend_meta.syslog_fallback: true` (observer-facing; curator may propose an alternate observation).

**Record emitted** — `schemas/evidence-envelope.md §3.4`.

**Write path:** `bl-case/CASE-<id>/evidence/obs-<ts>-log-journal.json`.

**Failure modes:**

| Scenario | Exit | Diagnostic |
|---|---:|---|
| `journalctl` not in PATH | 72 | `blacklight: observe: journalctl not available (systemd required)` |
| `--since` missing | 64 | `blacklight: observe: log journal requires --since <time>` |
| `--since` unparseable by journalctl | 65 | `blacklight: observe: journalctl rejected --since '<val>'` |

### 5.7 `bl_observe_cron` — source `cron.entry`

**Invocation:** `bl observe cron --user <user> [--system]`

**Exit codes:** 0 · 64 · 65 · 72.

**Inputs read:**

- Per-user: `command crontab -u <user> -l` (stdout) piped through `command cat -v` (reveals ANSI ESC[2J obscuration). For unprivileged processes attempting `crontab -u root -l` on a host where the operator is not root: exit 65 with `EACCES`.
- `--system`: `/etc/crontab`, `/etc/cron.d/*`, `/etc/cron.hourly/*`, `/etc/cron.daily/*`, `/etc/cron.weekly/*`, `/etc/cron.monthly/*` (file read, not parsed shebang-aware — just content dump with cat -v).

**Per-record emit:** one record per non-empty, non-comment line. `ansi_obscured: true` fires when `cat -v` output contains `^[` (the ANSI ESC marker). `cat_v_output` is the raw `cat -v` rendering to preserve the obscuration pattern.

**Record emitted** — `schemas/evidence-envelope.md §3.5`.

**Write path:** `bl-case/CASE-<id>/evidence/obs-<ts>-cron.json`.

### 5.8 `bl_observe_proc` — source `proc.snapshot`

**Invocation:** `bl observe proc --user <user> [--verify-argv]`

**Exit codes:** 0 · 64 · 65 · 72.

**Inputs read:**

- `command ps -u <user> -o pid=,user=,args=` — pid, user, full argv (args column).
- For each pid: `command readlink "/proc/$pid/exe"` → `exe_basename = ${exe##*/}`.
- Compare `argv0` (from `ps args` first token, basename-stripped) vs `exe_basename`. Mismatch → `argv_spoof: true`.
- `--verify-argv` is the default when `--verify-argv` is passed; without it, `argv_spoof` defaults to `false` and `exe_basename` field is omitted (argv-spoof is a `--verify-argv`-opted signal; operator pays the /proc-walk cost only when asked).
- `cwd` via `readlink /proc/<pid>/cwd`.
- `start_time_ts` via `stat -c %Y /proc/<pid>`.

**Record emitted** — `schemas/evidence-envelope.md §3.6`.

**Write path:** `bl-case/CASE-<id>/evidence/obs-<ts>-proc.json`.

**Portability:** `/proc/<pid>/exe` is Linux-specific; FreeBSD uses `procstat -b <pid>` (FreeBSD support is roadmap P4 per DESIGN.md §15 — handler returns 72 on non-Linux kernels detected via `uname -s`).

**Failure modes:**

| Scenario | Exit | Diagnostic |
|---|---:|---|
| `--user` missing | 64 | `blacklight: observe: proc requires --user <user>` |
| Non-Linux kernel | 72 | `blacklight: observe: /proc/<pid>/exe not available (Linux kernel required)` |
| `ps` returns non-zero for user (no processes; GNU procps may exit 1 on empty result) | 0 | summary count=0, no records (empty result is not an error). Handler checks `ps` exit status + stderr pattern; `exit 1 + empty stdout` → treat as empty-result; `exit 1 + non-empty stderr` → re-emit as exit 65 |
| `readlink` EACCES on a PID (kernel thread / privileged process owned by another user) | 0 with `exe_basename: null` and `argv_spoof: false` | (logged via `bl_debug`, not a failure) |

### 5.9 `bl_observe_htaccess` — source `htaccess.directive`

**Invocation:** `bl observe htaccess <dir> [--recursive]`

**Exit codes:** 0 · 64 · 65 · 72.

**Inputs read:** `.htaccess` files under `<dir>` (top-level only; `--recursive` enables tree walk via `command find <dir> -name .htaccess -type f`).

**Flag rules** — one directive per line is inspected. Flagged (emitted) iff one of:

- `AddHandler` with `application/x-httpd-php` target AND an extension argument that isn't `.php`/`.phtml`/`.phps`/`.php[0-9]+` — the polyshell-class signal.
- `AddType` with `application/x-httpd-php` + non-standard extension.
- `<FilesMatch>` regex containing PHP-enabling blocks (`<?php`, `php_value`, `php_flag`) inside the Files section.
- `DirectoryIndex` override to a name matching webshell heuristic (`shell.php`, `cmd.php`, `adminer.php`, random-looking alphanumeric stem ≥8 chars).
- `RewriteRule` with `?> <?php` or equivalent PHP-tag injection.

Clean directives are NOT emitted — only flagged ones hit JSONL. This keeps the curator's evidence context tight.

**Record emitted** — `schemas/evidence-envelope.md §3.7` (includes `file`, `line`, `directive`, `argument`, `injected: true`, `reason`).

**Write path:** `bl-case/CASE-<id>/evidence/obs-<ts>-htaccess.json`.

**`reason` field vocabulary** (closed, not free-text):

| Reason slug | Matches |
|---|---|
| `addhandler_image_to_php` | AddHandler x-httpd-php → .jpg/.png/.gif/.gif/.svg |
| `addtype_nonstandard_ext_to_php` | AddType x-httpd-php → non-.php* |
| `filesmatch_php_in_image` | `<FilesMatch>` block enabling PHP for image-ish regex |
| `directoryindex_webshell_heuristic` | DirectoryIndex points at webshell-named file |
| `rewriterule_php_injection` | RewriteRule contains PHP-tag injection |

### 5.10 `bl_observe_fs_mtime_cluster` — source `fs.mtime_cluster`

**Invocation:** `bl observe fs --mtime-cluster <path> --window <N>s [--ext <extlist>]`

**Exit codes:** 0 · 64 · 65 · 72.

**Algorithm** (spec-grade; engineer implements literally):

1. `command find "$path" -type f [ -regex '.*\.(ext1|ext2|…)$' ] -printf '%T@\t%s\t%m\t%U\t%p\n'` — produces `<mtime-epoch>\t<size>\t<mode>\t<uid>\t<full-path>` per file.

   Portability fallback for BSD `find` (no `-printf`): `command find "$path" -type f [-name '*.ext']* -exec command stat -c '%Y\t%s\t%a\t%u\t%n' {} \;` — slower but portable. Detect via `find --version 2>/dev/null | grep -q 'GNU find'`.

2. Sort by mtime epoch ascending.

3. **Cluster pass:** iterate the sorted list. For each file at mtime `t_i`, start (or extend) a cluster whenever `t_i - t_first_in_cluster ≤ N`. Close the cluster when the next file's mtime exceeds `t_first_in_cluster + N`. Emit every cluster of size ≥2 (singleton files — files with no neighbors within the window — are skipped; no signal from an isolated mtime).

4. **Cluster metadata** on every emitted record: `cluster_id` = `c-NNNN` allocated via `_bl_obs_allocate_cluster_id` (monotonic per-invocation, resets on each handler call — not shared across handler invocations); `cluster_size` = count of files in cluster; `cluster_span_secs` = `t_last - t_first` (integer seconds). Denormalized onto every member per `schemas/evidence-envelope.md §3.8`.

5. **Per-file extras:** `sha256` (via `command sha256sum "$path"` or BSD fallback), `owner` (resolve uid → username via `command getent passwd <uid> | cut -d: -f1`), `perms` as `4`-digit octal.

**Record emitted** — `schemas/evidence-envelope.md §3.8`.

**Write path:** `bl-case/CASE-<id>/evidence/obs-<ts>-fs-mtime-cluster.json`.

**Failure modes:**

| Scenario | Exit | Diagnostic |
|---|---:|---|
| `<path>` missing | 64 | `blacklight: observe: fs --mtime-cluster requires path argument` |
| `<path>` doesn't exist | 72 | `blacklight: observe: path not found: <path>` |
| `--window` missing or malformed | 64 | `blacklight: observe: --window required, format: Ns` |
| `--window` value < 1 | 64 | `blacklight: observe: --window must be ≥ 1 second` |
| Zero clusters found | 0 | summary with count=0 (not an error) |

### 5.11 `bl_observe_fs_mtime_since` — source `fs.mtime_since`

**Invocation:** `bl observe fs --mtime-since <date> [--under <path>] [--ext <extlist>]`

**Exit codes:** 0 · 64 · 65 · 72.

**Inputs read:** `command find <under|/> -type f -newermt <date> [-regex '.*\.(ext1|ext2|…)$']`. For GNU find, `-newermt` accepts ISO-8601 and relative forms (`'2026-04-14'`, `'1 week ago'`). BSD find lacks `-newermt` — portability fallback: compute epoch of `<date>` via `command date -d <date> +%s` (GNU) or `command date -j -f '%Y-%m-%d' <date> +%s` (BSD), then filter via `-newer <reference-file>` after `command touch -d <date> <ref>`.

**Record emitted** — `schemas/evidence-envelope.md §3.9`.

**Write path:** `bl-case/CASE-<id>/evidence/obs-<ts>-fs-mtime-since.json`.

### 5.12 `bl_observe_firewall` — source `firewall.rule`

**Invocation:** `bl observe firewall [--backend auto|apf|csf|iptables|nftables]`

**Exit codes:** 0 · 64 · 65 · 72.

**Backend detection** (`--backend auto`, the default):

1. `command -v apf` succeeds AND `command test -r /etc/apf/conf.apf` succeeds → `apf`.
2. Else `command -v csf` succeeds AND `command test -r /etc/csf/csf.conf` succeeds → `csf`.
3. Else `command -v nft` succeeds AND `command nft list tables 2>/dev/null` returns non-empty → `nftables`.
4. Else `command -v iptables` succeeds → `iptables`.
5. Else: exit 72, `blacklight: observe: no firewall backend detected`.

**Backend-specific rule dump:**

| Backend | Command | Parse target |
|---|---|---|
| `apf` | `command apf -l` (or fallback `command cat /etc/apf/deny_hosts.rules`) | IPs + (optional) comment tags |
| `csf` | `command csf -l` | chain + IPs + comments |
| `iptables` | `command iptables -L -n --line-numbers -v` AND `command iptables -t filter -S` | rule strings with comments |
| `nftables` | `command nft -a list ruleset` | rules with `comment` property |

For all backends: extract per-rule fields `{backend, chain, rule_index, action, source, dest, proto, dport, comment, bl_case_tag}` per `schemas/evidence-envelope.md §3.10`. `bl_case_tag` is populated iff `comment` carries the pattern `bl-case CASE-YYYY-NNNN` (regex match).

**Root privilege note:** `iptables -L`, `nft list ruleset`, `apf -l`, `csf -l` may require root depending on the host's netfilter capability settings. If the command returns non-zero with EACCES-equivalent message, handler exits 65 with `blacklight: observe: firewall dump requires root (backend=<name>)`. This is a hard constraint — firewall rule inspection is a root-privileged operation on most Linux distros. M4's unprivileged BATS tests use parsed fixture dumps, not live iptables (tests are Dockerized but run **unprivileged** per CLAUDE.md §Testing unless `--privileged` is explicitly enabled; M6 `bl defend firewall` tests require privileged for apply-path — M4 observe does not).

**Summary record:** emits `backend_meta: {firewall_backend: <name>, firewall_detect: "ok"}` per `schemas/evidence-envelope.md §3.13`. On detection failure, `backend_meta: {firewall_backend: null, firewall_detect: "missing"}`.

**Write path:** `bl-case/CASE-<id>/evidence/obs-<ts>-firewall.json`.

### 5.13 `bl_observe_sigs` — source `sig.loaded`

**Invocation:** `bl observe sigs [--scanner lmd|clamav|yara]`

**Exit codes:** 0 · 64 · 65 · 72.

**Scanner detection + sig enumeration:**

| Scanner | Detection | Sig store |
|---|---|---|
| `lmd` (maldet) | `command -v maldet` | `/usr/local/maldetect/sigs/rfxn.hdb`, `/usr/local/maldetect/sigs/rfxn.md5`, `/usr/local/maldetect/sigs/rfxn.ndb`, `/usr/local/maldetect/sigs/custom.*` — one record per signature line (HDB, MD5, NDB formats all line-delimited). `hit_count_30d` from `command maldet --hit-hist 30` where available, else `null`. |
| `clamav` | `command -v clamscan` or `command -v clamdscan` | `/var/lib/clamav/*.cld` and `*.cvd` — binary bundles. Use `command sigtool --list-sigs <file>` to list signatures. |
| `yara` | `command -v yara` | YARA rule files from configured paths (operator-provided via `$BL_YARA_RULES_DIR`, default `/etc/yara/rules/*.yar`). Emit one record per rule (rule name + meta + file path). |

Without `--scanner`, handler probes all three in order and emits records for every detected scanner. With `--scanner <name>`, only the named scanner is probed; absence returns 72 with `<scanner> not installed`.

**Record emitted** — `schemas/evidence-envelope.md §3.11`.

**Summary record:** `backend_meta: {sig_scanners_present: [<names>], sig_scanners_missing: [<names>]}` per §3.13. This gives the curator the data needed to avoid proposing `defend.sig --scanner clamav` on a host without ClamAV.

**Write path:** `bl-case/CASE-<id>/evidence/obs-<ts>-sigs.json`.

### 5.14 `bl_bundle_build` — bundle packager

**Invocation:** `bl observe bundle [--format gz|zst] [--since <ISO-ts>] [--out-dir <dir>]`

**Exit codes:** 0 · 64 · 65 · 72.

**Inputs read:**

- `bl_case_current` → active case id; no active case → exit 72 with `no active case; bundle requires --attach to a case first`.
- `${BL_VAR_DIR}/cases/CASE-<id>/evidence/*.json` — all observation output files under the case (local mirror per §6.4), filtered by `--since <ISO-ts>` (file mtime ≥ since) when passed.
- `--out-dir <dir>` — defaults to `${BL_VAR_DIR}/outbox/` (NOT literal `/var/lib/bl/outbox/` — honors `$BL_VAR_DIR` override for tests). Must be writable.

**Bundle layout** per `DESIGN.md §10.2`:

```
bundle-<host>-<window>.tgz
├── MANIFEST.json           (see schema below)
├── summary.md              (1–2 KB; §5.14.2 convention)
├── apache.transfer.jsonl   (concat of all obs-*-log-apache.json records with source=apache.transfer)
├── apache.error.jsonl      (concat of apache.error records — if any)
├── modsec.audit.jsonl      (…)
├── journal.entry.jsonl     (…)
├── cron.entry.jsonl        (…)
├── proc.snapshot.jsonl     (…)
├── htaccess.directive.jsonl(…)
├── fs.mtime_cluster.jsonl  (…)
├── fs.mtime_since.jsonl    (…)
├── firewall.rule.jsonl     (…)
├── sig.loaded.jsonl        (…)
├── file.triage.jsonl       (…)
└── observe.summary.jsonl   (every summary trailer from every obs file, concatenated)
```

Per-source `.jsonl` files are assembled by concatenating records from all `obs-*.json` files whose `source` field matches. Empty sources are not written (no zero-byte files in the bundle). Record order inside each `.jsonl` is: source-file mtime ascending (earliest obs-file first), then line order within each file (preserving handler-emit order). This keeps the bundle reproducible even when multiple `bl observe` invocations have produced overlapping `obs-NNNN` series (each invocation starts its own obs counter; concatenation by file-mtime disambiguates).

**`<window>` filename component:** if `--since` passed, `<since>-to-<now>` (ISO-8601 UTC, `:` → `-`). Else `full` (the full case history). `window.from`/`window.to` in MANIFEST.json use the **preamble `ts` field** (emit time) from the minimum-ts and maximum-ts records in the bundle, NOT `record.ts_source` — the latter is source-event time and varies per source. Preamble `ts` is the wall-clock anchor the `--since` filter aligns with (evidence file mtime ≈ earliest preamble `ts` inside the file).

**Compression:**

- Default: `gzip -5`. Archive: `command tar -cf - <files> | command gzip -5 > <bundle>.tgz`.
- `--format zst` (explicit) or `auto + zstd available`: `command tar -cf - <files> | command zstd -3 > <bundle>.tgz`.
- Extension is `.tgz` regardless per `DESIGN.md §10.4` — tar magic-byte detects codec on decompress.
- `_bl_obs_codec_detect` picks the codec; MANIFEST.json records the choice in `codec` field.

**Max bundle size discipline:** `bl_bundle_build` emits a warning via `bl_warn` when total uncompressed size exceeds 100 MB (curator-session Files API upload comfort zone); >500 MB → handler exits 65 with `blacklight: observe: bundle oversize (<N> MB > 500 MB cap); narrow with --since`. Discipline prevents accidentally packaging a week of JSONL into one file.

**Write path:** `<out-dir>/bundle-<host>-<window>.tgz`.

#### 5.14.1 `MANIFEST.json` schema

```json
{
  "bl_version": "0.1.0",
  "codec": "gz",
  "host": "fleet-01-host-03",
  "case_id": "CASE-2026-0007",
  "generated_at": "2026-04-24T14:22:07.123Z",
  "window": {"from": "2026-04-23T08:00:00Z", "to": "2026-04-24T14:22:07Z"},
  "entries": [
    {
      "path": "apache.transfer.jsonl",
      "source": "apache.transfer",
      "sha256": "abcd1234…",
      "size_bytes": 148210,
      "record_count": 1204
    },
    {
      "path": "summary.md",
      "source": null,
      "sha256": "ef56…",
      "size_bytes": 1840,
      "record_count": null
    }
  ],
  "total_size_bytes": 152380,
  "total_record_count": 1204
}
```

Fields:

| Field | Type | Source |
|---|---|---|
| `bl_version` | string | `$BL_VERSION` constant at `bl:22` |
| `codec` | string (`gz`\|`zst`) | `_bl_obs_codec_detect` output |
| `host` | string | `_bl_obs_host_label` |
| `case_id` | string | `bl_case_current` |
| `generated_at` | string (ISO-8601 UTC, ms precision, Z suffix) | `_bl_obs_ts_iso8601` at bundle time |
| `window.from` / `window.to` | string (ISO-8601) or null | earliest / latest `ts` across all bundled records (`window.from` = min, `window.to` = max) |
| `entries[]` | array | one per file in the archive |
| `entries[].path` | string | relative path inside the tar |
| `entries[].source` | string \| null | `source` taxonomy value for `.jsonl` files; `null` for `MANIFEST.json` and `summary.md` |
| `entries[].sha256` | string | 64-char lowercase hex of file contents |
| `entries[].size_bytes` | integer | uncompressed |
| `entries[].record_count` | integer \| null | line count for `.jsonl` files; `null` for non-JSONL |
| `total_size_bytes` | integer | sum of entry size_bytes (uncompressed) |
| `total_record_count` | integer | sum of record_count where non-null |

**`additionalProperties: false` is not schema-enforced** (MANIFEST.json is a wrapper-emitted artifact not passed to Managed Agents custom-tool input_schema which is the only place the beta rejects extras; MANIFEST is read by the curator via Files API and skills). Wrapper SHOULD emit exactly the fields above; unknown fields are a MANIFEST-generation bug detectable at diff.

#### 5.14.2 `summary.md` convention

Per `DESIGN.md §10.3`, ≤ 2 KB, structured:

```markdown
# Evidence bundle — <host> — <from> → <to>

## Trigger
<one-paragraph description; populated from bl-case/CASE-<id>/hypothesis.md "Current" section if present, else "ad-hoc observation bundle">

## Top-line findings
- <bullet list of ≤ 7 facts; populated from observe.summary "attention" fields aggregated across sources>

## Jump points
- grep '<path_class>' apache.transfer.jsonl | jq '.record.client_ip' | sort | uniq -c | sort -rn | head
- jq -s 'group_by(.record.cluster_id) | map({cluster:.[0].record.cluster_id, size:length})' fs.mtime_cluster.jsonl
- jq 'select(.record.argv_spoof==true)' proc.snapshot.jsonl
- jq 'select(.record.ansi_obscured==true)' cron.entry.jsonl

## Attention-worthy
- <attention anomalies from observe.summary records across sources>
```

Wrapper-written. Placeholder when `hypothesis.md` is empty or unreadable: `"ad-hoc observation bundle (no active hypothesis)"`.

---

## 5b. Examples

### 5b.1 `bl observe file` happy path

```
$ export ANTHROPIC_API_KEY=sk-ant-test
$ printf '%s' "agent_abc" > /var/lib/bl/state/agent-id
$ echo CASE-2026-0007 > /var/lib/bl/state/case.current
$ bl observe file /var/www/html/pub/media/a.php/banner.jpg
{"ts":"2026-04-24T14:22:07.123Z","host":"fleet-01-host-03","case":"CASE-2026-0007","obs":"obs-0001","source":"file.triage","record":{"path":"/var/www/html/pub/media/a.php/banner.jpg","size":2451,"mode":"0644","owner":"www-data","mtime":"2026-04-23T14:22:07Z","sha256":"…","magic":"PHP script, ASCII text","strings_sample":["BL-STAGE","chr(","base64_decode","gzinflate"],"strings_total":128}}
{"ts":"2026-04-24T14:22:07.189Z","host":"fleet-01-host-03","case":"CASE-2026-0007","obs":"obs-0001","source":"observe.summary","record":{"verb":"observe.file","span":{"from":"2026-04-24T14:22:07.123Z","to":"2026-04-24T14:22:07.189Z"},"counts":{"records_in":1,"records_emitted":1,"filtered":0},"attention":["PHP-typed file served as image extension — polyshell staging shape"]}}
$ echo $?
0
$ ls bl-case/CASE-2026-0007/evidence/
obs-2026-04-24T14-22-07.123Z-file.json
```

### 5b.2 `bl observe fs --mtime-cluster` cluster emit

```
$ bl observe fs --mtime-cluster /var/www/html --window 5s --ext php,phtml
{"ts":"2026-04-24T14:22:07.350Z","host":"fleet-01-host-03","case":"CASE-2026-0007","obs":"obs-0002","source":"fs.mtime_cluster","record":{"path":"/var/www/html/pub/media/catalog/product/.cache/a.php","size":2451,"mtime":"2026-04-23T14:22:07Z","sha256":"…","owner":"www-data","perms":"0644","cluster_id":"c-0001","cluster_size":7,"cluster_span_secs":4}}
… (6 more records; all cluster_id=c-0001 …)
{"ts":"2026-04-24T14:22:07.420Z","host":"fleet-01-host-03","case":"CASE-2026-0007","obs":"obs-0002","source":"observe.summary","record":{"verb":"observe.fs_mtime_cluster","span":{…},"counts":{"records_in":127,"records_emitted":7,"filtered":120},"attention":["1 cluster of 7 files within 4 seconds — webshell drop pattern"]}}
```

### 5b.3 `bl observe proc --verify-argv` argv-spoof signal

```
$ bl observe proc --user www-data --verify-argv
{"ts":"…","host":"…","case":"CASE-2026-0007","obs":"obs-0003","source":"proc.snapshot","record":{"pid":4711,"user":"www-data","argv0":"mariadbd","exe_basename":"httpd","argv_spoof":true,"cmdline":"mariadbd --datadir=/tmp/.x","cwd":"/tmp/.x","start_time_ts":"2026-04-23T14:22:07Z"}}
{"ts":"…","host":"…","case":"CASE-2026-0007","obs":"obs-0003","source":"observe.summary","record":{"verb":"observe.proc","span":{…},"counts":{"records_in":14,"records_emitted":14,"filtered":0,"argv_spoof_count":1},"attention":["pid=4711 argv0=mariadbd exe=httpd — gsocket-class spoof"]}}
```

### 5b.4 `bl observe firewall` backend autodetect on iptables

```
$ bl observe firewall
{"ts":"…","host":"…","case":"CASE-2026-0007","obs":"obs-0004","source":"firewall.rule","record":{"backend":"iptables","chain":"INPUT","rule_index":27,"action":"DROP","source":"203.0.113.51","dest":"0.0.0.0/0","proto":"tcp","dport":null,"comment":"bl-case CASE-2026-0007 — polyshell-c2","bl_case_tag":"CASE-2026-0007"}}
… (more rules) …
{"ts":"…","host":"…","case":"CASE-2026-0007","obs":"obs-0004","source":"observe.summary","record":{"verb":"observe.firewall","span":{…},"counts":{"records_in":84,"records_emitted":84},"backend_meta":{"firewall_backend":"iptables","firewall_detect":"ok"},"attention":["1 rule tagged bl-case CASE-2026-0007 (this case)"]}}
```

### 5b.5 `bl observe bundle` success

```
$ bl observe bundle --format zst --since 2026-04-24T00:00:00Z
[bl] INFO: bundle: reading bl-case/CASE-2026-0007/evidence/*.json (12 files, 148210 records)
[bl] INFO: bundle: codec=zst (zstd detected)
[bl] INFO: bundle: /var/lib/bl/outbox/bundle-fleet-01-host-03-2026-04-24T00-00-00Z-to-2026-04-24T14-22-07Z.tgz (152 KB)
$ ls /var/lib/bl/outbox/
bundle-fleet-01-host-03-2026-04-24T00-00-00Z-to-2026-04-24T14-22-07Z.tgz
$ tar -tzf /var/lib/bl/outbox/bundle-*.tgz
MANIFEST.json
summary.md
apache.transfer.jsonl
modsec.audit.jsonl
fs.mtime_cluster.jsonl
proc.snapshot.jsonl
firewall.rule.jsonl
observe.summary.jsonl
$ tar -xzf /var/lib/bl/outbox/bundle-*.tgz -O MANIFEST.json | jq -e '.entries | length > 0 and all(.sha256 | length == 64)'
true
```

### 5b.6 Failure — no active case on bundle

```
$ rm /var/lib/bl/state/case.current
$ bl observe bundle
blacklight: observe: no active case; bundle requires --attach to a case first
$ echo $?
72
```

### 5b.7 Failure — malformed cron input (simulated via fixture)

```
$ BL_VAR_DIR=$(mktemp -d) bl observe cron --user doesnotexist 2>&1 | head -1
blacklight: observe: crontab: no crontab for doesnotexist
$ echo $?
72
```

---

## 6. Conventions

### 6.1 Function naming

All M4 public handlers use `bl_observe_` prefix; private helpers use `_bl_obs_` prefix (leading underscore to signal file-local). `bl_bundle_build` is the one non-prefixed public handler — justified because `observe bundle` is the verb surface (not `bl_observe_bundle_*`) and the bundle is a single operation, not a family.

### 6.2 JSONL emit discipline

- **One object per line** — no pretty-print; `jq -c` safe.
- **Preamble fields always in order** — `ts, host, case, obs, source, record`. `_bl_obs_emit_jsonl` assembles via `jq -n -c --arg …` to enforce shape.
- **`record` is the LAST field** — caller passes `record` as a JSON string; `_bl_obs_emit_jsonl` embeds via `jq --argjson record "$r"`.
- **`null` for absent optional fields** — never omit. The envelope contract is `additionalProperties: false`; missing fields are as bad as extras.

### 6.3 Timestamp format

ISO-8601 UTC with millisecond precision and `Z` suffix: `%Y-%m-%dT%H:%M:%S.%3NZ`. `date -u +%Y-%m-%dT%H:%M:%S.%3NZ` — GNU date only; BSD date requires `date -u +%Y-%m-%dT%H:%M:%SZ` (no ms) with `-j -f '%s' $(date +%s)` for epoch fallback. Handler uses `command date -u +%Y-%m-%dT%H:%M:%S.%3NZ 2>/dev/null || command date -u +%Y-%m-%dT%H:%M:%SZ`  — inline fallback chain for BSD portability; the `2>/dev/null` suppresses the `%3N: illegal option` stderr on BSD. Justification: `# BSD date lacks %3N; trim to second-precision fallback`.

### 6.4 Case-scoped write path

Case context read via `bl_case_current`. Evidence file path: `$BL_VAR_DIR/bl-case/CASE-<id>/evidence/obs-<ts>-<kind>.json` — wait, no, `bl-case/` is a **remote memory store** per `docs/case-layout.md §10`, not a local path. Correction: M4 emits locally into `${BL_VAR_DIR}/cases/CASE-<id>/evidence/` (staging directory mirroring the memstore layout) and M5's `bl consult --attach` + `bl case log` handlers ship the staged JSON files up to the remote memstore via the Files API / memstore write surface. Local staging path is the wrapper's mirror; the `bl-case/` prefix in `docs/case-layout.md §3` refers to the memstore-side layout.

**Resolution:** Until M5 lands the memstore writer, M4 writes to the local mirror `${BL_VAR_DIR}/cases/CASE-<id>/evidence/obs-<ts>-<kind>.json`. The `docs/case-layout.md §3` path prefix `bl-case/` maps 1:1 to `${BL_VAR_DIR}/cases/` on the local mirror. M5 picks up the files and ships them upstream with path-prefix translation.

**Self-correction note:** the PLAN.md §M4 deliverable list says "writes to `bl-case/evidence/obs-<ts>-<kind>.json`" (line 173) — this is ambiguous about local-vs-remote. `docs/case-layout.md §10` makes the local vs remote distinction explicit. The spec resolves the ambiguity here: **local mirror write is M4's job; memstore upload is M5's**. `MANIFEST.json` in the bundle carries `host` + `case_id` metadata the memstore side uses for path reconstruction.

### 6.5 Scrub pass

`_bl_obs_scrub` runs inside `_bl_obs_emit_jsonl` before stdout/file write. Scrub patterns (regex-based, closed list):

| Pattern class | Regex (bash-compatible) | Replacement |
|---|---|---|
| cPanel username in path | `/home/[a-z][a-z0-9]{2,15}/` | `/home/<cpuser>/` |
| Liquid Web internal hostname | `\.liquidweb\.(com\|local)` | `.example.test` |
| sigforge hostname | `sigforge[0-9]*` | `fleet-00-host` |
| Operator-depot path | `/home/sigforge/var/ioc/polyshell_out/` | `<OPERATOR_LOCAL>/` |

Scrub is applied to string fields only (not numeric, not boolean). `jq` pass: `jq --arg … 'walk(if type == "string" then gsub($re1; $rep1) | gsub($re2; $rep2) | … else . end)'`. Tests in `tests/04-observe.bats` include a scrub-regression group asserting that operator-local tokens injected into fixture content are elided in emitted records.

### 6.6 Error envelope phase strings

Per `bl_error_envelope`: all M4 emissions use `phase=observe`. Specific sub-context goes in the `problem` string: `"log apache: cannot read /var/log/apache2/access.log"`, `"fs --mtime-cluster: path not found: <path>"`, etc. No per-verb phase strings — keeps grep-for-phase simple.

### 6.7 Exit code symbols (no numeric literals)

Every `return`/`exit` in M4 handlers cites a `BL_EX_*` constant from M1's declaration block at `bl:23–40`. Codes used by M4:

- `BL_EX_OK=0` — success
- `BL_EX_USAGE=64` — bad args, missing required flag, unknown sub-verb
- `BL_EX_PREFLIGHT_FAIL=65` — readable path became unreadable mid-invocation, coreutil missing, perm denied, BSD/GNU stat detection failure
- `BL_EX_SCHEMA_VALIDATION_FAIL=67` — internal invariant break (jq-assembled record fails self-check) — rare; grep-verified in tests
- `BL_EX_NOT_FOUND=72` — source file / backend / case not found

Codes NOT used by M4: `66` (workspace-not-seeded, preflight-owned), `68` (tier-gate, M5-owned), `69`/`70` (upstream/rate-limit, API-owned), `71` (conflict, setup-owned).

### 6.8 Coreutil `command` prefix

Every coreutil use: `command find`, `command sort`, `command uniq`, `command sha256sum`, `command stat`, `command tar`, `command gzip`, `command zstd`, `command cat`, `command awk`, `command sed`, `command grep`, `command wc`, `command head`, `command tail`, `command cut`, `command mkdir`, `command touch`, `command ln`, `command cp`, `command mv`, `command rm`, `command chmod`, `command readlink`, `command strings`, `command file`, `command date`, `command hostname`, `command getent`, `command xargs`, `command tr`. `printf` and `echo` bare (bash builtins). Verification grep in §10b.

### 6.9 No `2>/dev/null` / `|| true` without justification

Inline comment on the same line. Example:

```bash
exe_basename=$(command readlink "/proc/$pid/exe" 2>/dev/null)   # EACCES on kernel threads / privileged procs
[[ -z "$exe_basename" ]] && argv_spoof=false && continue
```

Same rule for `|| true`:

```bash
kernel_pids=$(command find /proc -maxdepth 1 -type d -regex '/proc/[0-9]+' 2>/dev/null | command wc -l) || true   # /proc listing races with PID reap
```

All such sites are grep-verified in §10b.

### 6.10 Cross-reference discipline

- DESIGN.md: `§N.N` (no line number; DESIGN may be re-numbered).
- Evidence envelope: `schemas/evidence-envelope.md §N.N` (numbered sections stable).
- Exit codes: `docs/exit-codes.md §1`.
- Case layout: `docs/case-layout.md §3 row <N>` where the row is path-specific.
- Action tiers: `docs/action-tiers.md §2 Tier table`, `§5.1 Gate behavior`.
- Step verb enum: `schemas/step.json` `verb.enum[]`.

---

## 7. Interface contracts

### 7.1 Upstream contracts (consumed by M4)

- **`schemas/evidence-envelope.md §1 preamble`** — `{ts, host, case, obs, source, record}` field set. M4 emits, never extends. Drift is a M4 bug.
- **`schemas/evidence-envelope.md §2 source taxonomy`** — 13 source values. M4 uses 12 of them (all except `observe.summary` which M4 emits as a trailer per-handler). No new sources added.
- **`schemas/evidence-envelope.md §3`** — per-source record field sets. M4 emits exactly the documented fields per source. `additionalProperties: false` is contract-enforced.
- **`docs/action-tiers.md §2 Tier table row 1 (read-only)`** — every `observe.*` verb is tier `read-only`. No confirmation, no backup, no ledger.
- **`docs/case-layout.md §3 row 5`** — `bl-case/CASE-<id>/evidence/obs-<id>-<kind>.json` writer-owner contract. M4 is the writer. Lifecycle: `immutable-after-write` (M4 never mutates an emitted file; rotation on same-second conflict produces a new file, not a mutation).
- **`docs/exit-codes.md §1`** — codes 0/64/65/67/72 used. Every `exit`/`return` symbolic.
- **M1 surface (`bl:1–340`)** — `bl_preflight`, `bl_init_workdir`, `bl_case_current`, `bl_error_envelope`, loggers, `BL_EX_*`, `BL_VAR_DIR`. Consumed read-only.

### 7.2 Downstream contracts (produced by M4)

- **Evidence JSONL records** — consumed by M5 (`bl consult --attach` uploads to memstore; `bl case show` reads for human display; `bl case log` serializes for ledger) and M6 (`bl defend` reads obs-id references cited by curator step reasoning).
- **Evidence bundles** — consumed by M5 (`bl consult --upload <bundle>` ships to Files API for curator ingestion). The bundle's MANIFEST.json sha256 + record_count fields are the integrity-check the curator uses on bundle receipt.
- **`observe.summary` trailer** — `backend_meta` field consumed by curator reasoning (spares proposing `defend.firewall` against `backend=null` or `defend.sig --scanner clamav` when `clamav` is in `sig_scanners_missing`).

### 7.3 Environment contract

| Variable | Required | Default | Purpose |
|---|---|---|---|
| `ANTHROPIC_API_KEY` | yes (preflight) | — | M1's preflight fires before M4 handlers; no M4 handler reads the key |
| `BL_VAR_DIR` | no | `/var/lib/bl` | Local state root; test override |
| `BL_HOST_LABEL` | no | `$(hostname -s)` | Envelope `host` field |
| `BL_LOG_LEVEL` | no | `info` | Standard M1 level filter |
| `BL_YARA_RULES_DIR` | no | `/etc/yara/rules` | `bl_observe_sigs --scanner yara` input dir |

### 7.4 CLI surface (new in M4)

```
bl observe file <path>
bl observe log apache --around <path> [--window 6h] [--site <fqdn>]
bl observe log modsec [--txn <id>] [--rule <id>] [--around <path> --window 6h]
bl observe log journal --since <time> [--grep <pattern>]
bl observe cron --user <user> [--system]
bl observe proc --user <user> [--verify-argv]
bl observe htaccess <dir> [--recursive]
bl observe fs --mtime-cluster <path> --window <N>s [--ext <extlist>]
bl observe fs --mtime-since <date> [--under <path>] [--ext <extlist>]
bl observe firewall [--backend auto|apf|csf|iptables|nftables]
bl observe sigs [--scanner lmd|clamav|yara]
bl observe bundle [--format gz|zst] [--since <ISO-ts>] [--out-dir <dir>]
```

### 7.5 File contract (new paths written)

- `${BL_VAR_DIR}/cases/CASE-<id>/evidence/obs-<ts>-<kind>.json` — per-observation JSONL + summary trailer. Wrapper-written, immutable-after-write. Lifetime: lives with the case (not auto-deleted; case close schedules sweep per `docs/case-layout.md §5`).
- `${BL_VAR_DIR}/outbox/bundle-<host>-<window>.tgz` — packaged evidence bundle. Wrapper-written, immutable-after-write. Consumed by M5 `bl consult --upload`. Lifetime: removed on successful upload by M5.
- `${BL_VAR_DIR}/state/obs_counter` — per-process monotonic counter for obs-id allocation. Mutable. Re-initialized on each new `bl observe` invocation (not shared across processes — every invocation allocates its own obs-ids starting from a timestamp-seeded base).

---

## 8. Migration safety

### 8.1 Upgrade path

N/A — M4 is greenfield. No prior `bl_observe_*` implementation exists. `bl-ctl` (v1) had no observe surface; legacy tree archived at `legacy-pre-pivot` tag.

### 8.2 Install path

M4 ships as additions to `bl` (single file); no new installed artifacts. `tests/fixtures/` is excluded from release tarball via `.gitattributes` (M10 adds the `export-ignore` rules).

### 8.3 Rollback

`git revert <M4-landing-commit>` restores `bl_observe` stub at `bl:333` and removes `tests/04-observe.bats` + `tests/fixtures/*` + `tests/helpers/assert-jsonl.bash` + `tests/helpers/observe-fixture-setup.bash`. `legacy-pre-pivot` tag remains durable anchor.

### 8.4 Test-suite impact

Adds `tests/04-observe.bats` (~60 @test entries) to the BATS run. Pre-commit minimum: `make -C tests test` (debian12) + `make -C tests test-rocky9`. Release matrix: full spectrum per project CLAUDE.md §Testing. Anvil preferred for the full matrix; freedom fallback if anvil slow.

### 8.5 Backward compatibility

Forward-only. No shipped `bl` binary exists in the wild yet (pre-v1.0). Any M4 change that breaks emit shape between now and v1.0 is fixable without compat shims.

---

## 9. Dead code and cleanup

| File | Content | Disposition |
|---|---|---|
| `bl:333` (M1 stub) | `bl_observe() { bl_error_envelope observe "not yet implemented (M4)"; return "$BL_EX_USAGE"; }` | **Replace** with M4 dispatcher + handlers |

Incidental finding during spec authoring: `bl_poll_pending` at `bl:193–209` is a skeleton targeted for M5; M4 does not touch it. No drift.

No operator-local paths or legacy v1 references appear in M4 scope (grep `liquidweb|sigforge|polyshell_out` across draft spec: 0 matches).

---

## 10a. Test strategy

`tests/04-observe.bats` adds ~62 `@test` entries organized into 13 groups (12 verbs + 1 bundle builder). Every verb group covers:

1. **Happy path** — fixture-driven invocation; stdout JSONL validates against `schemas/evidence-envelope.md §1 preamble` + §3 source-specific fields via `tests/helpers/assert-jsonl.bash`.
2. **Missing-source path** — source file absent / backend undetectable → exit 72 with distinct diagnostic.
3. **Malformed-input path** — source file corrupted, truncated, wrong format → exit 65 or 67 with distinct diagnostic.
4. **Tier-check** — handler runs without confirmation prompt, no backup write, no ledger write. Verification: `ls /var/lib/bl/ledger/` empty after handler completes.
5. **Scrub regression** (6 verbs that read file content — apache, modsec, journal, cron, htaccess, fs-since) — fixture contains operator-local tokens (`sigforge03.liquidweb.local`, `/home/wsxdev/`); emitted records contain none.

Plus bundle builder group:

6. **Bundle happy path** — case with multiple obs files → tar opens clean, MANIFEST.json valid, sha256s match entry contents.
7. **Bundle no-active-case** → exit 72.
8. **Bundle codec zst** (skipped if `command -v zstd` fails at test start) → archive is zstd-compressed.
9. **Bundle codec gz fallback** → archive is gzip-compressed.
10. **Bundle oversize refusal** — synthetic >500 MB fixture → exit 65.
11. **Bundle `--since` window filter** — subset of obs files included, subset excluded.

| Goal | Test file + group | `@test` count |
|---|---|---:|
| G1 (11 verbs dispatch + bundle) | `04-observe.bats` — `dispatch` group | 13 |
| G2 (preamble schema conformance) | all verb groups (happy path assertion) | 12 |
| G3 (case-scoped write path) | all verb groups (case-active + case-absent) | 24 |
| G4 (tier=read-only) | all verb groups (no-prompt, no-ledger assertion) | 12 |
| G5 (scrub pass) | apache, modsec, journal, cron, htaccess, fs-since groups | 6 |
| G6 (bundle build + compression) | bundle group | 6 |
| G7 (MANIFEST.json schema) | bundle group (happy path + jq-schema) | 1 |
| G8 (exit code per failure mode) | all verb groups (missing/malformed) | 24 |
| G9 (portability greps) | top-of-file meta-test | 1 |
| G10 (all verbs covered) | (count assertion across groups) | 1 |
| G11 (lint clean) | pre-test bash -n + shellcheck smoke | 1 |

Test helper commitments:

- **`tests/helpers/assert-jsonl.bash`** — provides `assert_jsonl_preamble <line>` (6-field shape check) and `assert_jsonl_record <line> <source>` (per-source field-set check; reads expected fields from a closed map inside the helper). Extensible: adding a new source in `schemas/evidence-envelope.md §3` requires adding a map entry here.
- **`tests/helpers/observe-fixture-setup.bash`** — provides `setup_observe_case <case-id>` (stages `$BL_VAR_DIR/cases/CASE-<id>/evidence/`), `teardown_observe_case` (cleans `$BL_VAR_DIR`), `stage_apache_log <fixture-name>` and similar for each fixture kind.

### Fixture provenance

All fixtures under `tests/fixtures/` are **reconstructed from the public APSB25-94 advisory only** per CLAUDE.md §Data. No copy from `/home/sigforge/var/ioc/polyshell_out/`, no copy from `~/admin/work/proj/depot/polyshell/`. Clean-room grep at commit time:

```bash
grep -riE 'liquidweb|sigforge|wsxdev|polyshell_out' tests/fixtures/
# expect: (no output)
```

Fixtures are **shape-grounded** (realistic line cadence, realistic obfuscation patterns) from public advisory text; never copies of operator-local material.

### Test dependency on M1

M1 owns the BATS scaffold (`tests/Makefile`, `tests/run-tests.sh`, `tests/Dockerfile`, `tests/helpers/bl-preflight-mock.bash`). M4 tests assume:

- M1's scaffold exists (plan-wave-2 precondition — M4 dispatches after M1 merges).
- `bl` is lint-clean and the preflight path is mockable (M4 tests use the same preflight mock).
- `tests/00-smoke.bats` passes (baseline).

If M1 is in-flight when M4 build phases dispatch, M4 waits for M1 merge before test execution. Spec-grade grep checks (§10b) run independently.

---

## 10b. Verification commands

All commands run from repo root unless noted. Expected output documented per command.

**G1 — verb dispatch:**

```bash
grep -c '^bl_observe_[a-z]' bl
# expect: 11   (file, log_apache, log_modsec, log_journal, cron, proc, htaccess, fs_mtime_cluster, fs_mtime_since, firewall, sigs)

grep -c '^bl_bundle_build' bl
# expect: 1

grep -cE '^\s+(file\)|log\)|cron\)|proc\)|htaccess\)|fs\)|firewall\)|sigs\)|bundle\))' bl
# expect: ≥9   (observe router case statement arms — some arms are compound)
```

**G2 — preamble enforcement in emit helper:**

```bash
grep -n '_bl_obs_emit_jsonl' bl | head -1
# expect: a line showing the helper definition

# Assert helper references all 6 preamble fields in jq invocation:
grep -A10 '^_bl_obs_emit_jsonl' bl | grep -oE '(ts|host|case|obs|source|record)' | sort -u
# expect: (6 distinct names) case host obs record source ts
```

**G3 — case-scoped write path:**

```bash
grep -nE 'cases/CASE-\\\$\{[A-Z_]+\}/evidence/obs-' bl
# expect: at least one line in _bl_obs_open_stream
```

**G4 — tier=read-only (no ledger, no backup writes):**

```bash
# No M4 handler writes to $BL_VAR_DIR/ledger/ or $BL_VAR_DIR/backups/.
# Note: awk range `/^bl_observe_/,/^}/` can terminate early on nested `}`
# (e.g., case statement closing brace). Use grep with section-line-range
# computed from function bodies instead.

# Compute line range for each bl_observe_* function + bl_bundle_build:
bl_funcs=$(grep -nE '^(bl_observe_|bl_bundle_build)' bl | cut -d: -f1)
# For each start-line, find the matching closing brace line via awk brace-counter:
# (Plan-phase engineer implements this as a helper script; spec-time verification
# simplifies to: the strings "ledger/" and "backups/" never appear inside the
# M4 line range [first bl_observe_ line .. bl_observe router closing brace].)
m4_start=$(grep -nE '^(bl_observe|_bl_obs_)' bl | head -1 | cut -d: -f1)
m4_end=$(grep -n '^main "\$@"' bl | cut -d: -f1)
sed -n "${m4_start},${m4_end}p" bl | grep -cE '(ledger/|backups/)'
# expect: 0
```

**G5 — scrub pass present in emit helper:**

```bash
grep -A20 '^_bl_obs_emit_jsonl' bl | grep -c '_bl_obs_scrub'
# expect: ≥1
```

**G6 — bundle builder codec detection:**

```bash
grep -n 'command -v zstd' bl
# expect: at least one line in _bl_obs_codec_detect
```

**G7 — MANIFEST.json fields emitted by bundle builder:**

```bash
awk '/^bl_bundle_build/,/^}$/' bl | grep -oE '"(bl_version|codec|host|case_id|generated_at|window|entries|total_size_bytes|total_record_count)"' | sort -u | wc -l
# expect: 9
```

**G8 — no numeric exit literals in M4 block:**

```bash
# Scan the M4 region (after the M1 stub replacement, before main)
awk '/^bl_observe\(\)/,/^main "\$@"/' bl | grep -cE '\b(exit|return)\s+[0-9]+\b' | grep -v 'return 0'
# expect: 0

awk '/^bl_observe\(\)/,/^main "\$@"/' bl | grep -cE '\bBL_EX_'
# expect: ≥30   (every error path cites a symbolic constant)
```

**G9 — portability + coreutil prefix:**

```bash
# No hardcoded /usr/bin/ coreutils
grep -nE '/usr/bin/(find|sort|stat|tar|gzip|cat|awk|sed|grep)' bl
# expect: (no output)

# No bare coreutils in M4 block (grep after ^bl_observe or ^_bl_obs)
awk '/^bl_observe\(\)/,/^main "\$@"/' bl | grep -nE '^\s+(find|sort|uniq|sha256sum|stat|tar|gzip|cat|awk|sed|grep|wc|head|tail|cut|mkdir|touch|ln|cp|mv|rm|chmod|readlink|strings|file|date|hostname|getent|xargs|tr) '
# expect: (no output — every coreutil has 'command' prefix)

# No which, no egrep
grep -nE '\bwhich\b|\begrep\b' bl
# expect: (no output)

# No backticks
grep -nE '`' bl
# expect: (no output)

# Every 2>/dev/null has same-line inline comment
awk '/^bl_observe\(\)/,/^main "\$@"/' bl | grep -E '2>/dev/null' | grep -vE '#.*'
# expect: (no output)

# Every || true has same-line inline comment
awk '/^bl_observe\(\)/,/^main "\$@"/' bl | grep -E '\|\| true' | grep -vE '#.*'
# expect: (no output)
```

**G10 — fixtures clean-room:**

```bash
grep -riE 'liquidweb|sigforge|wsxdev|polyshell_out' tests/fixtures/
# expect: (no output)

find tests/fixtures -type f | wc -l
# expect: ≥12
```

**G11 — lint clean:**

```bash
bash -n bl
# expect: (no output, exit 0)

shellcheck bl
# expect: (no output, exit 0)
```

**Test matrix (run on anvil per CLAUDE.md §Testing):**

```bash
DOCKER_HOST=tcp://192.168.2.189:2376 DOCKER_TLS_VERIFY=1 DOCKER_CERT_PATH=~/.docker/tls \
    make -C tests test 2>&1 | tee /tmp/test-blacklight-M4-debian12.log | tail -30
grep "not ok" /tmp/test-blacklight-M4-debian12.log
# expect: (no output)

DOCKER_HOST=tcp://192.168.2.189:2376 DOCKER_TLS_VERIFY=1 DOCKER_CERT_PATH=~/.docker/tls \
    make -C tests test-rocky9 2>&1 | tee /tmp/test-blacklight-M4-rocky9.log | tail -30
grep "not ok" /tmp/test-blacklight-M4-rocky9.log
# expect: (no output)
```

---

## 11. Risks

1. **R1 — Evidence envelope drift vs emit shape.** If `schemas/evidence-envelope.md §3` is edited between spec authoring and M4 build, handler emits will fail schema conformance.
   **Mitigation:** M4 phase 0 re-reads `schemas/evidence-envelope.md §3` and diffs against the field lists in §5.3–§5.13 of this spec. Any drift → spec is MUST-FIX, not build. Sentinel reviewer re-checks at commit.

2. **R2 — BSD vs GNU coreutil portability.** `stat -c`, `find -printf`, `date -d`, `find -newermt`, `find -regex` differ. Tests run on Debian 12 (GNU) and Rocky 9 (GNU) per minimum matrix. BSD-only paths are untested in CI.
   **Mitigation:** Every BSD-divergent invocation has a documented fallback (§5.3, §5.10, §5.11). Release matrix (M10) adds Ubuntu 20.04 + CentOS 7 + ubuntu2404 — all GNU coreutils. FreeBSD is roadmap P4 per DESIGN.md §15; M4 detects non-Linux kernel and exits 72 gracefully (§5.8).

3. **R3 — `/proc/<pid>/*` race conditions.** PIDs reap between `ps` and `readlink`. Handler skips missing PIDs via `2>/dev/null` + continue (§5.8 failure modes).
   **Mitigation:** Inline comment on the `2>/dev/null` site justifies (`# PID may reap between ps and readlink`). Test fixture (`proc-verify-argv.txt`) uses pre-captured pairs; live-proc walk is smoke-tested via Docker `bats-container` with `sleep 3600 &` backgrounded.

4. **R4 — Clean-room fixture authorship drift.** Engineer may accidentally paraphrase operator-local material into fixtures.
   **Mitigation:** G10 grep + sentinel review pass with explicit check against operator-local token corpus. Fixture header comment cites the public APSB25-94 advisory URL (Adobe's published advisory page) as sole source.

5. **R5 — JSONL `additionalProperties: false` violation at emit.** A developer adds a convenient "extra" field to a `record` without updating `schemas/evidence-envelope.md §3`.
   **Mitigation:** `assert-jsonl.bash` per-source field-set check is exhaustive — it asserts the record's key set is exactly the documented set (no missing, no extras). Unit test fails loud at CI.

6. **R6 — Bundle size growth breaks Files API upload.** Managed Agents Files API has implementation-defined per-file caps; very large bundles may reject at upload.
   **Mitigation:** §5.14 hard cap at 500 MB + warning at 100 MB. `--since` flag provides windowing. Cap is spec-enforced; operator can always split via multiple `bl observe bundle --since` invocations.

7. **R7 — Scrub pass misses a pattern.** Operator-local corpus is open-ended; a pattern not in §6.5 table slips through.
   **Mitigation:** Scrub is defense-in-depth, not trust. Fixture sets + BATS scrub-regression tests cover the 4 documented patterns. Any new pattern surfaced (at fixture authoring, at curator review, at operator audit) is added to §6.5 in a follow-up commit — scrub is iteratively hardened. CLAUDE.md §Data is the ultimate fence (no operator-local material ever committed regardless of scrub).

8. **R8 — Firewall backend probe costs on production host.** `iptables -L -n -v` can be slow on hosts with thousands of rules; `nft list ruleset` even slower.
   **Mitigation:** No current limit enforced in M4. Document in README (M10) that `bl observe firewall` is a one-shot dump; operator may want to narrow via `--backend` on multi-backend hosts. Timing SLA is not a M4 goal.

9. **R9 — Parallel worktree merge — cross-prefix function calls.** A M5/M6/M7/M8 handler might accidentally reference `bl_observe_*` leading to cross-prefix coupling at merge.
   **Mitigation:** Merge-time reviewer runs the grep from §4.4 ("Namespace collision check"). Cross-prefix calls are MUST-FIX before merge.

10. **R10 — M1 in-flight when M4 dispatches.** Plan-wave-2 says M4 dispatches post-M1 merge; if M1 is still in flight, the `bl` frame may shift under M4.
    **Mitigation:** M4 phase 0 verifies M1 landed (`grep -c '^bl_observe' bl` returns exactly 1 from M1's stub + `grep -c 'BL_VERSION="0.1.0"' bl` returns 1). If M1 not yet merged, M4 waits. No speculative building against draft M1.

11. **R11 — jq invocation per-record emit is slow.** Assembling each JSONL line via `jq -n --arg … -c` per-record is ~ms overhead; at 148 K records this is minutes.
    **Mitigation:** Handler-local batching — where possible, the handler builds the full records array in memory (bash associative arrays or temp file), then invokes jq once with `--slurpfile` or `jq -c '.[]'` over the array to emit the whole stream. Per-record jq is reserved for summary trailer (single invocation). This keeps `observe.log_apache` on 148K records tractable. Profiling-tuning is a M10 concern, not a M4 goal.

12. **R12 — `command date +%3N` on BSD fallback drops ms precision.** Envelope `ts` is spec'd as ms-precision ISO-8601; BSD fallback trims to second precision.
    **Mitigation:** ISO-8601 without ms is still schema-conformant (`schemas/evidence-envelope.md §1` — "Millisecond precision permitted" — permitted, not required). BSD portability is preserved; precision degrades gracefully. Document in §6.3.

13. **R13 — `bl-case/` vs `${BL_VAR_DIR}/cases/` path ambiguity.** `docs/case-layout.md §3` uses `bl-case/` prefix for memstore paths. M4 writes locally to `${BL_VAR_DIR}/cases/`. Reader of `case-layout.md` may expect local writes at `bl-case/` and be confused.
    **Mitigation:** §6.4 documents the mapping explicitly. M5 spec (parallel-authored) will document the memstore upload translation. A post-M5 unification pass may rename one or the other for clarity — left to M9 hardening if deemed necessary.

---

## 11b. Edge cases

| # | Scenario | Expected behavior | Handling |
|---|---|---|---|
| E1 | `bl observe <verb>` outside a case (no `/var/lib/bl/state/case.current`) | Emits JSONL to stdout only; `case` field is `null`; no evidence file written | `_bl_obs_emit_jsonl` sniffs `bl_case_current`; empty → `case: null` + skip file write |
| E2 | Multiple concurrent `bl observe` invocations sharing a case | Each invocation allocates disjoint obs-ids via `_bl_obs_allocate_obs_id` (process-local counter + pid salt). Evidence files rotate with `.N.json` suffix on same-second conflict | `_bl_obs_open_stream` probes existing file, appends `.2` / `.3` etc. |
| E3 | Handler runs as non-root; source requires root (e.g. `bl observe firewall`) | Backend command returns non-zero with EACCES-like signal → exit 65 with `blacklight: observe: firewall dump requires root` | §5.12 explicit |
| E4 | `--around <path>` points at file that doesn't exist | Exit 72 with `blacklight: observe: anchor path not found: <path>` | Handler reads `stat` of anchor before log-locate heuristic |
| E5 | `--window 0s` for fs mtime cluster | Exit 64 — `--window` must be ≥ 1s | §5.10 failure modes |
| E6 | Cluster window yields zero clusters | Exit 0 with summary.counts.records_emitted=0 and attention=["no cluster found within <window>s"] | §5.10 failure modes |
| E7 | ModSec audit log uses Concurrent logging not Serial | Handler walks concurrent tree (`/var/log/modsec_audit/YYYYMMDD/HHMM/…`) instead of parsing a single Serial file | §5.5 detects via tree shape |
| E8 | `bl observe cron --user` invoked without `--system`; target user has `/etc/cron.allow` exclusion | `crontab -u <user> -l` returns non-zero with `no crontab for <user>` → exit 72 (not-found, not error) | §5.7 maps `no crontab for <user>` exit to 72 |
| E9 | `bl observe proc --verify-argv`; PID reaped between `ps` and `readlink` | Skip the PID silently; continue iteration; summary counts reflect surviving records | §5.8 + `# PID may reap` inline comment on the `2>/dev/null` line |
| E10 | `bl observe htaccess <dir>` on a tree with zero .htaccess files | Exit 0, summary.counts.records_emitted=0, attention=["no .htaccess files found under <dir>"] | Not an error |
| E11 | `bl observe sigs` on a host with no scanners installed | Exit 72 (nothing to probe); summary.backend_meta.sig_scanners_missing=[lmd,clamav,yara]; no `sig.loaded` records written | §5.13 |
| E12 | `bl observe bundle` on a case with evidence files total < 1 KB | Bundle still builds; MANIFEST carries real sha256s; summary.md is 600–800 bytes; exit 0 | No min-size gate |
| E13 | `--format zst` passed but `command -v zstd` fails | Exit 65 with `blacklight: observe: --format zst requested but zstd not available` | `_bl_obs_codec_detect` explicit check |
| E14 | Case directory `${BL_VAR_DIR}/cases/CASE-<id>/evidence/` not yet created (case-open didn't run; wrapper hit by direct observe) | Handler creates on first emit via `command mkdir -p` (idempotent); does not error | `_bl_obs_open_stream` ensures path |
| E15 | Evidence file exceeds 50 KB cap per `docs/case-layout.md §3 row 5` | `_bl_obs_close_stream` emits `bl_warn` but completes write; cap is a target, not a hard limit in M4 | Enforcement is M9 hardening concern |
| E16 | `bl observe file <path>` where `<path>` is a directory | Exit 64 with `blacklight: observe: file requires a file path, not directory: <path>` | §5.3 arg validation |
| E17 | `bl observe log apache --site <fqdn>` where vhost log exists but is 0 bytes (rotated / truncated) | Exit 0, summary.counts.records_in=0, attention=["log empty or rotated"] | Not an error |
| E18 | `bl observe log journal --since yesterday` on a host without systemd | Exit 72 — `journalctl not available (systemd required)` | §5.6 NG5 explicit |
| E19 | `bl observe firewall --backend nftables` on a host with nftables present but empty ruleset | Exit 0, summary.counts.records_in=0, summary.backend_meta.firewall_backend=nftables, attention=["no rules loaded"] | §5.12 |
| E20 | Scrub regex matches inside a sha256 field (hex that happens to contain a `.liquidweb` substring) | False positive risk — sha256 is 64 lowercase hex; no alphanumeric overlap with scrub patterns. Scrub targets string fields; sha256 is a hex-constrained string where domain patterns cannot occur | Not an issue in practice; scrub is regex-based on full string pattern not substring probabilistic |

---

## 12. Open questions

None at authoring time. All load-bearing decisions resolved directionally against judging weights (Impact · Demo · Opus-4.7-Use · Depth) and documented inline:

- **bl_bundle_build as `observe bundle` sub-verb (not top-level command)** — §4.3 item 4. Resolved: observe owns evidence, bundle reads evidence, bundle belongs to observe.
- **Local mirror path `${BL_VAR_DIR}/cases/` vs memstore path `bl-case/`** — §6.4. Resolved: local mirror is M4's write target; M5 translates on upload.
- **Scrub pass at emit vs bundle** — §4.3 item 6. Resolved: at emit. Dual-scrub breaks sha256 reproducibility.
- **Verb routing for `log apache/modsec/journal`** — §5.1. Resolved: `log` prefix + kind token in the dispatch case (not a nested sub-function).
- **Observe on non-Linux kernel** — §5.8. Resolved: exit 72 gracefully; `/proc` is Linux-specific, no fallback in M4.

Any new questions surfaced during `/r-review` challenge pass are resolved in §13 closing section below (MUST-FIX / SHOULD-FIX / INFO) before commit.

---

## 13. Adversarial review pass (self-authored before /r-review dispatch)

Challenge-mode review: read the spec as if it were a hostile reviewer and find the sharpest objections. Document resolutions. Final /r-review pass may add findings; those land in this section as addendum before commit.

### 13.1 MUST-FIX

- **MF-1 (resolved)** — Original draft allowed each handler to call `bl_api_call` directly, contradicting NG3. Fixed in §4.5 dependency rules + G8 verification grep.
- **MF-2 (resolved)** — Original draft wrote to `bl-case/CASE-<id>/evidence/` without qualifying whether that's the remote memstore path or a local mirror. Resolved at §6.4 + §13 local-mirror rule.

### 13.2 SHOULD-FIX

- **SF-1 (resolved)** — `bl_observe_fs_mtime_cluster` algorithm was not fully spec'd in draft; engineer would have had to invent clustering logic. Fixed in §5.10 with a 5-step spec-grade algorithm.
- **SF-2 (resolved)** — The `summary.md` content spec was vague; engineer would have produced a free-form file. Fixed in §5.14.2 with literal template.
- **SF-3 (resolved)** — `tests/helpers/assert-jsonl.bash` was listed but not specified beyond filename. Fixed in §10a with function-level contract.
- **SF-4 (resolved)** — Bundle `window.from`/`window.to` derivation was ambiguous between preamble `ts` and per-record `ts_source`. Fixed in §5.14.1 — uses preamble `ts` to align with `--since` filter semantics.
- **SF-5 (resolved)** — Bundle concat ordering was "lexicographic by obs-id" which produces confused ordering across multi-invocation cases. Fixed in §5.14 — orders by source-file mtime, then line-order within file.
- **SF-6 (resolved)** — `--out-dir` default was `/var/lib/bl/outbox/` (literal) rather than `${BL_VAR_DIR}/outbox/` (respecting test override). Fixed in §5.14.
- **SF-7 (resolved)** — Cluster-id allocator was not named as a helper; engineer would have had to invent. Added `_bl_obs_allocate_cluster_id` to §5.2 helper table; `bl_observe_fs_mtime_cluster` step 4 cites it.
- **SF-8 (resolved)** — `bl_observe_file` had no guard on huge files (500 MB hash + strings). Added `_bl_obs_size_guard` helper + 64 MB cap in §5.3.
- **SF-9 (resolved)** — `bl_observe_proc` failure-mode row for `ps` empty-result conflated empty-result with error. Refined in §5.8 failure table.
- **SF-10 (resolved)** — §10b G4 verification used `awk /^bl_observe_/,/^}/` which terminates early on nested `}`. Rewritten to use line-range extracted from function starts + main invocation, with plan-phase engineer note.

### 13.3 INFO

- **I-1** — `observe.summary.backend_meta` is optional per `schemas/evidence-envelope.md §3.13` ("Other observe verbs leave `backend_meta` absent"). M4 emits `backend_meta` only on `observe.firewall` and `observe.sigs`. Non-emission on other verbs is spec-conformant; do not elaborate in record construction.
- **I-2** — `obs-NNNN` allocation is process-local per §5.2. If two concurrent `bl observe` invocations run under the same case, obs-ids may collide in the `NNNN` position (both processes start at obs-0001). Evidence files rotate on filename conflict via `_bl_obs_open_stream`'s `.N.json` suffix. This is acceptable — obs-ids are invocation-scoped anchors, not case-globally-unique; the `ts` field disambiguates cross-invocation. Future hardening (M9) may promote to case-global monotonicity if the curator's obs-id citation accuracy demands it.
- **I-3** — Bundle builder writes to `${BL_VAR_DIR}/outbox/` (not `bl-case/...`). `outbox/` is `docs/case-layout.md §... n/a` — it's a local-only staging dir (M1 creates via `bl_init_workdir`). M4 documents the path in §7.5 file contract; no `docs/case-layout.md` addition needed because outbox is out-of-memstore.
- **I-4** — The `STEP_COUNTER` file referenced in `docs/case-layout.md §3 note` + `schemas/step.md §step_id` is M5's concern. M4 allocates its own `obs_counter` file at `${BL_VAR_DIR}/state/obs_counter` — disjoint namespace; no interaction.

### 13.4 Post-/r-review findings

(To be populated by the challenge-mode review pass. If the reviewer surfaces MUST-FIX items, they land here before commit; SHOULD-FIX items may defer with rationale; INFO items are acknowledged.)

---

*End of M4 bl-observe design spec. Handoff to `/r-plan` for decomposition into phases. No build-stage dispatch from here — this spec lands as a single commit; plan and build follow in separate pipeline stages.*
