# blacklight — design spec

*Targeted release: 0.5.0 — bumps at release tag. Authored against post-M15 source carrying `BL_VERSION="0.4.0"`. Canonical at the 0.4.0 source / 0.5.0 release-tag boundary.*
*Companion to `PRD.md` (executive frame, problem, users, roadmap, competitive positioning). This document is the implementation-facing spec.*

---

## 1. Purpose of this document

`PRD.md` answers *why blacklight takes this shape* (executive frame, problem, users, competitive positioning, roadmap). This document answers *what the shape is, precisely enough to code against*. If you are writing `bl`, writing `bl setup`, extending a skill, or reading the repo cold to understand the system — this is the file to read.

Scope: architecture, command surface, runtime flow, state model, safety gates, evidence format, dependencies. Out of scope: competitive positioning, market framing, roadmap (all in `PRD.md`).

---

## 2. The pitch in one paragraph

**blacklight** is a portable bash wrapper (`bl`) that turns any Linux host into an agent-directed incident-response surface. The wrapper runs locally — bash 4.1+, `curl`, `awk`, `jq` — with zero daemons and zero Python. Every investigation is a conversation between the operator, the wrapper, and a **Managed Agents session** hosted in the operator's Anthropic workspace. That session — Opus 4.7, 1M context, six description-routed routing Skills + eight corpus Files mounted at creation (see §9) — decides what to look at next, authors the defensive payloads (ModSec rules, firewall entries, YARA sigs), and prescribes remediation (rogue cron stripping, `.htaccess` cleanup, quarantine). The wrapper executes; the agent directs; the existing defensive primitives your host already runs (ModSec, APF, CSF, iptables, nftables, LMD, ClamAV, YARA) are the hands. Man-days of manual IR become agentic-minutes on the substrate the defender already owns.

---

## 3. Architecture — three layers

```
┌─ Layer A — `bl` on the host ─────────────────────────────────────────────┐
│                                                                           │
│  bash 4.1+ (CentOS 6 / RHEL 6 floor, December 2009 / November 2010).      │
│  26 numbered source parts in src/bl.d/; ~10,700-line assembled binary;    │
│  137 reusable bl_* functions exposed as a bash SDK (see §17).             │
│                                                                           │
│  observe  consult  run  defend  clean  case  setup  flush  trigger        │
│                                                                           │
│  Deps: bash ≥4.1, curl, awk, jq, grep, sed, tar, gzip. No daemon.         │
│  Built from src/bl.d/NN-*.sh via `make bl`. Single file ships.            │
│                                                                           │
└─────────────────────────────────────────────┬─────────────────────────────┘
                                              │ HTTPS + API key (curl)
                                              ↓
┌─ Layer B — Managed Agent session (Anthropic-hosted) ─────────────────────┐
│                                                                           │
│  agent           bl-curator (Opus 4.7, 1M ctx, Managed Agent session)     │
│  environment     bl-curator-env (cloud sandbox; packages installed        │
│                  per-session by agent: apache2, libapache2-mod-security2, │
│                  modsecurity-crs, yara, jq, zstd, duckdb, pandoc,         │
│                  weasyprint)                                              │
│  routing Skills  6 (description-routed, lazy-loaded)                      │
│  corpus Files    8 (foundations + skill corpora + substrate-context)      │
│  memory store    bl-case (read_write) — hypothesis, steps, actions, hist  │
│  per-case Files  evidence bundles + closed-case briefs (hot-attached)     │
│                                                                           │
│  No local runtime process. The session lives in the Anthropic workspace.  │
│  `bl` reaches it via HTTPS on every invocation.                           │
│                                                                           │
└─────────────────────────────────────────────┬─────────────────────────────┘
                                              │ step directives
                                              ↓
┌─ Layer C — existing defensive primitives on the host ────────────────────┐
│                                                                           │
│  apachectl + mod_security, APF, CSF, iptables, nftables, LMD, ClamAV,    │
│  YARA, Apache/nginx logs, journalctl, crontab, find, stat, cat -v        │
│                                                                           │
└───────────────────────────────────────────────────────────────────────────┘
```

**Layer boundary invariants:**

- Layer A never decides load-bearing actions. It executes what Layer B prescribes (gated by safety tiers) and reports results.
- Layer B never touches the host filesystem or primitives directly. It reasons, authors, prescribes — never applies.
- Layer C is untouched by blacklight source code. No new rule engines, no new manifests, no new wire formats — only native usage of existing primitives.

### 3.4 Primitives map (Path C — M13 Skills realignment)

M13 realigned the Layer B surface from the pre-Path-C layout (two memory stores: `bl-skills` read_only + `bl-case` read_write) to the full four-primitive Managed Agents surface.

| Primitive | Instance | blacklight role | Path key in `state.json` |
|-----------|----------|-----------------|--------------------------|
| **Skills** | 6 routing Skills | Description-routed lazy-loaded operator-voice behavior (synthesizing-evidence, prescribing-defensive-payloads, curating-cases, gating-false-positives, extracting-iocs, authoring-incident-briefs) | `agent.skill_versions.<slug>` |
| **Files** (workspace) | 8 corpus files | Skill corpora (foundations + 6 routing-skill corpora + substrate-context); mounted at session create | `files.<slug>.file_id` |
| **Files** (per-case) | Evidence bundles + briefs | Raw observation JSONL + closed-case briefs; hot-attached mid-session; GC'd after close | `case_files.<case-id>.<path>.workspace_file_id` |
| **Memory Store** | `bl-case` (read_write) | Curator working memory: hypothesis + steps + actions + open-questions | `case_memstores._default` |
| **Sessions** | Per-case curator session | Opus 4.7, 1M context; case-scoped reasoning; resumable across 30-day checkpoint window | `session_ids.<case-id>` |
| **Triggers** | M14 LMD `post_scan_hook` adapter (`bl trigger lmd`) | Operator wires after install via `bl setup --install-hook lmd`; opens cases from existing detection signal. `install.sh` drops `bl-lmd-hook` into `/etc/blacklight/hooks/` but does not auto-edit `conf.maldet` | `triggers.lmd.installed` (recorded after operator runs the install-hook sub-verb) |

`bl-skills` memory store is **retired** in Path C. Skill content lives in the Skills primitive (description-routed, lazy-loaded) instead of a flat read_only memstore. See §7.1 for the retirement note.

**Skill-version pinning at session create.** Routing Skills are version-pinned at the moment a session is created — the agent sees the skill content frozen at that version for the life of the session, regardless of subsequent `bl setup --sync` updates. This is the load-bearing adversarial-content invariant (§13.2): attacker-supplied evidence cannot mutate operator knowledge mid-investigation, because the knowledge is read-only from the agent's perspective AND immutable for the session's duration. Operational consequence: an operator who updates a routing-skill body and re-syncs sees the new content only on *new* sessions. Active long-lived cases continue to reason against the pinned version. To rebind an active case to the new content, close and reopen the case (`bl case close` + `bl case --reopen <id> --reason "skill rebind: <slug>"`) — the reopen creates a fresh session that picks up the latest skill version at create time.

---

## 4. Runtime flow — the agent-directed REPL

blacklight investigations are operator-agent conversations, not batch dossier analyses. The canonical flow:

```
operator                  bl (Layer A)              Managed Agent (Layer B)
────────                  ────────────              ─────────────────────
$ bl consult --new \
   --trigger <hit>        preflight; allocate CASE-YYYY-NNNN;
                          POST /v1/sessions (workspace + per-case
                            Files attached); POST wake event
                                                    session.wake
                                                    routing Skills lazy-load
                                                    read bl-case/hypothesis
                                                    emit s-01..04 to
                                                      bl-case/pending/
                          bl_poll_pending loop:
                            GET memstore?path_prefix=…/pending/ (3s
                            cadence, dedup, exit on 3 empty cycles
                            or --timeout); show proposed steps
Accept? [Y/n] Y           exec each step; write …/results/s-NN.json;
                          POST wake
                                                    read results, revise,
                                                    emit next batch:
                                                      observe / defend /
                                                      clean / close_case
                          auto-exec read-only + auto-tier;
                          stop on destructive; show diff; --yes per step
Confirm cron removal? y   exec, write result, POST wake
                                                    propose close_case
                                                    when open_questions = 0
$ bl case close           md brief → Files API (canonical);
                          HTML/PDF rendered in curator sandbox
                          (graceful degrade if unreachable);
                          closed.md written; T+30d retire schedule
```

**Key mechanical choice: async step-emit over polled memory-store paths, not synchronous SSE tool-result.** The agent writes proposed step JSON to `bl-case/<case>/pending/<step-id>.json`; the wrapper consumes pending steps via two modes:

- **Foreground REPL (`bl consult` polling):** `bl_poll_pending` (in `src/bl.d/20-api.sh`) issues `GET /v1/memory_stores/<id>/memories?path_prefix=bl-case/<case>/pending/` every 3s, dedups against an in-process seen-set file, and exits on either 3 consecutive empty-listing cycles (`end_turn` proxy) or a caller-supplied `--timeout`.
- **On-demand single-fetch (`bl run --list`):** `bl_run_list` (in `src/bl.d/60-run.sh`) issues one list call and prints each pending step's tier + synopsis. Used by batched/async operator workflows.

Both paths execute the step, write to `bl-case/<case>/results/<step-id>.json`, and POST a wake event to `/v1/sessions/<sid>/events`. This avoids SSE bidirectional plumbing in bash, makes the case memory a self-documenting audit log, and keeps `bl` a short-lived command per invocation. Polling overhead (~3-9s per loop tick) is invisible against agent reasoning time.

---

## 5. Command namespace — full reference

Nine namespaces. All bash functions in a single `bl` script (assembled from `src/bl.d/NN-*.sh` via `make bl`). Dispatched by first argument from `main()` in `90-main.sh`.

| Namespace | Source part | Purpose |
|-----------|-------------|---------|
| `observe` | `41-observe-collectors.sh` + `42-observe-router.sh` + `45-cpanel.sh` | Read-only evidence extraction |
| `consult` | `50-consult.sh` | Open / attach a case via the curator agent |
| `run`     | `60-run.sh` | Execute an agent-prescribed step (tier-gated) |
| `defend`  | `82-defend.sh` | Apply a defensive payload (modsec / firewall / sig) |
| `clean`   | `83-clean.sh` | Apply remediation (diff-confirmed; quarantine preserved) |
| `case`    | `70-case.sh` | Inspect / log / close / reopen cases |
| `setup`   | `84-setup.sh` (preflight bypass; carries its own local preflight) | Provision or sync the Anthropic workspace |
| `trigger` | `29-trigger.sh` | Open a case from a hook-fired event (LMD post_scan_hook) |
| `flush`   | `27-outbox.sh` via `90-main.sh` dispatch | Drain queued outbox records (`bl flush --outbox`) |

Top-level `-h|--help|help` and `-v|--version` bypass preflight; per-verb `bl <verb> --help` also bypasses preflight (so `bl setup --help` works on an unseeded host).

### 5.1 `bl observe` — read-only evidence extraction

Auto-runs (no confirm). Emits JSONL to stdout and appends structured output to the current case bundle.

```
bl observe file <path>          stat, magic, sha256, strings, file(1)
bl observe log apache --around <path> [--window 6h] [--site <fqdn>]
bl observe log modsec [--txn <id>] [--rule <id>] [--around <path>]
bl observe log journal --since <time> [--grep <pattern>]
bl observe cron --user <user> [--system]      # cat -v reveals ANSI ESC[2J
bl observe proc --user <user> [--verify-argv]
bl observe htaccess <dir> [--recursive]
bl observe fs --mtime-cluster <path> --window <N>s [--ext <list>]
bl observe fs --mtime-since <date> [--under <path>] [--ext <list>]
bl observe firewall [--backend auto]
bl observe sigs [--scanner lmd|clamav|yara]
bl observe substrate            # cPanel / EasyApache / hosting-stack inventory
bl observe bundle               # assemble all collected artifacts → evidence bundle
```

cPanel-specific helpers (`45-cpanel.sh`) are invoked from the observe collectors when cPanel layouts are detected (`/var/cpanel`, `/usr/local/cpanel`); they walk the cPanel-specific directory tree (homedirs, EasyApache, vhost configs).

### 5.2 `bl consult` — case lifecycle open / attach

```
bl consult --new --trigger <path-or-event> [--notes "..."] [--dedup]
    Allocate CASE-YYYY-NNNN (flock-serialized counter), materialize
    case templates into bl-case memstore, create a session via
    POST /v1/sessions with workspace + per-case Files attached, POST
    wake event. Returns case-id on stdout.
    --dedup: trigger fingerprint matches an open case → attach instead.

bl consult --attach <case-id>
    Format-guard CASE-YYYY-NNNN, probe hypothesis.md, set case.current.

bl consult --sweep-mode [--cve <id>]
    Read-only inventory of closed cases; optional CVE filter against
    each case's hypothesis.
```

### 5.3 `bl run` — execute agent-prescribed step (tier-gated)

```
bl run <step-id> [--yes] [--dry-run] [--unsafe] [--explain]
    Pull <step-id> from bl-case/<case>/pending/, validate against
    schemas/step.json (jq schema-check), prompt for confirmation
    per tier policy, execute, write result, append to ledger and
    memstore. --yes is permitted only at suggested tier; destructive
    requires both --unsafe and --yes. --dry-run shows the plan
    without applying. --explain dumps the step's reasoning field.

bl run --list
    Single-fetch listing of all pending steps for the current case
    with their action tier and one-line synopsis.

bl run --batch [--max <N>] [--yes]
    Execute up to <N> pending steps in order (default --max 16).
    Read-only and auto tier auto-run; suggested honours --yes;
    destructive still gates per-step (no batch auto-confirm).
```

### 5.4 `bl defend` — apply agent-authored payload

```
bl defend modsec <rule-file-or-id> [--remove] [--rollback <event-id>]
    apachectl configtest pre-flight; on pass symlink-swap +
    apachectl graceful; on fail rollback to previous symlink target.

bl defend firewall <ip> [--backend auto] [--case <id>] [--reason <str>]
                        [--retire <duration>]
    Auto-detect APF/CSF/iptables/nftables; CDN-safelist check
    (internal allowlist + ASN lookup via public WHOIS cache); apply;
    write ledger entry with retire-hint. --retire defaults to 30d.

bl defend sig <sig-file> [--scanner lmd|clamav|yara|all]
    Corpus-FP gate (run sig against /var/lib/bl/fp-corpus/) →
    Haiku 4.5 adjudication of borderline hits → on 0 FP, append
    to scanner sig file and reload. Auto-tier iff FP gate passes.
```

### 5.5 `bl clean` — remediation (destructive, diff-confirmed)

```
bl clean htaccess <dir> [--patch <file>]    # diff + backup + apply
bl clean cron --user <user> [--patch <file>]
bl clean proc <pid> [--capture]           # default: capture-on
bl clean file <path> [--reason <str>]     # quarantine, never unlink
bl clean --undo <backup-id>
bl clean --unquarantine <entry-id>
```

### 5.6 `bl case` — case lifecycle

Cases are allocated via `bl consult --new` (see §5.2); `bl case` exposes
inspect / log / close / reopen only. The dispatcher in `70-case.sh` accepts
exactly the sub-verbs below — no `open` and no `note`.

```
bl case list [--open|--closed|--all]
                             enumerate cases on this host
bl case show [<id>]          print 6-section summary
bl case log [<id>] [--audit] full chronological ledger; --audit appends
                             per-kind summary + decoded fence-wrapped wake
                             entries from outbox (uses bl_fence_kind for
                             forensic review)
bl case close [<id>] [--force]
                             agent validates open-questions empty;
                             render brief (md canonical, html/pdf best-
                             effort via curator sandbox); close.md
                             written; T+30d firewall-block retire-sweep
                             scheduled
bl case reopen <id> --reason <str>
                             re-attach a closed case to its session
```

Operator-authored case notes that need to live with the case state are
appended via the memory-store path (`bl-case/<case>/<artifact>.md`)
rather than via a dedicated `case note` verb. The in-source `bl_help_*`
strings in `30-preflight.sh` still mention `case open` / `case note`;
these are stale and tracked for alignment with the live dispatchers in a
follow-up sweep.

### 5.7 `bl setup` — workspace bootstrap (see §8)

```
bl setup --sync [--dry-run]      provision agent + Skills + Files (idempotent)
bl setup --reset [--force]       archive agent + delete Skills + workspace Files
bl setup --gc                    purge files_pending_deletion when no live session refs
bl setup --eval [--promote]      live skill-routing eval (BL_EVAL_LIVE=1)
bl setup --check                 print state.json snapshot + per-resource health
bl setup --install-hook lmd      install bl-lmd-hook + wire LMD post_scan_hook
bl setup --import-from-lmd       import LMD notify keys → /etc/blacklight/notify.d/*
```

### 5.8 `bl trigger` — hook-fired case open

```
bl trigger lmd --scanid <id> [--session-file <path>] [--source-conf <path>] [--unattended]
    Parse LMD per-session TSV → JSONL; compute cluster fingerprint
    sha256(scanid|sigs|paths)[:16]; bl_consult_new --dedup with
    --dedup-window-hours from blacklight.conf (default 24).
    Degraded path on empty/unreadable TSV opens stub case anyway.
```

### 5.9 `bl flush` — outbox drain

```
bl flush --outbox
    Best-effort drain of /var/lib/bl/outbox/ — replays queued
    wake / signal_upload / action_mirror records. Idempotent;
    safe to invoke manually or from cron.
```

### 5.10 Dispatcher entry

`main()` in `src/bl.d/90-main.sh`. Per-verb help bypass runs *before* preflight; non-bypassed verbs run `bl_preflight` first (see §8.1). Strict-mode (`set -euo pipefail`) is gated behind a source-execute guard — tests source `bl` to access `bl_*` functions and bash 4.1 (CentOS 6) propagates `errexit` from sourced files even with `|| true` masking, so strict-mode lives at the end of `main`, not at file head.

---

## 6. Action tiers + safety gates

Every action blacklight takes is classified into one of five tiers. The tier determines gate behavior.

| Tier | Examples | Gate behavior |
|---|---|---|
| **Read-only** | `observe *`, `consult *`, `case show/log/list` | Auto-execute; no confirm; ledger entry only |
| **Reversible, low-risk** (`auto`) | `defend firewall <ip>` (new block), `defend sig` (after corpus-FP-pass + Haiku 4.5 adjudication) | Auto-execute + Slack/stdout notification + 15-minute operator veto window (via `bl defend firewall --remove <ip>`); ledger entry created |
| **Reversible, high-impact** (`suggested`) | `defend modsec` (new rule) | Suggest → operator reviews diff → explicit `bl run --yes` to apply; `apachectl configtest` pre-flight mandatory |
| **Destructive** | `clean htaccess`, `clean cron`, `clean proc`, `clean file`, `defend modsec --remove` | Diff shown (file edits) or capture-then-kill (proc); explicit `--yes` per-operation required; no batch auto-confirm; backup written before apply |
| **Unknown** | Any bash command the agent proposes that does not map to a known verb | Deny by default; operator must invoke `bl run <step-id> --unsafe --yes` explicitly; discouraged |

**Tier is authored by the agent**, written into `bl-case/<case>/pending/<step-id>.json` as `action_tier: auto|suggested|destructive`. The wrapper enforces the gate based on this field plus the verb class, not trust from the agent alone. `schemas/step.json` declares the field; `bl_jq_schema_check` (in `20-api.sh`) validates before the wrapper acts.

---

## 7. State model — memory stores + files + local

One memory store (`bl-case`). Files for blobs (workspace + per-case). No local state store on the host beyond `/var/lib/bl/`.

### 7.1 `bl-skills` memory store — RETIRED (Path C, M13)

**Status: RETIRED.** The `bl-skills` memory store was removed in M13 (Skills primitive realignment). Skill content now lives in Anthropic Skills primitives (description-routed, lazy-loaded) instead of a flat read_only memory store. See §3.4 for the Path C primitives map.

Pre-Path-C contract (preserved for history): access `read_only` from the agent's perspective, written only by `bl setup` via the external Memories API, ~22 operator-voice markdown files, ≤50 KB total, kernel-enforced read-only so attacker-supplied log content could not rewrite operator knowledge mid-investigation. Routing Skills version-pinning at session creation preserves the same invariant under Path C — see §13.2.

### 7.2 `bl-case` memory store

- Access: `read_write` from the agent's perspective
- Written-by contract:

```
bl-case/
├── INDEX.md                          # workspace case roster + fingerprint column (M9.5+)
├── CASE-<YYYY>-<NNNN>/
│   ├── hypothesis.md                 # current hypothesis + confidence + reasoning
│   ├── history/<ISO-ts>.md           # each hypothesis revision immutable
│   ├── evidence/                     # pointer-style, one per observation
│   │   ├── evid-<id>.md              # {source, sha256, summary, file_id?}
│   │   └── obs-<id>-<kind>.json      # raw observation output (JSONL usually)
│   ├── attribution.md                # kill chain (upload/exec/persist/lateral/exfil)
│   ├── ip-clusters.md                # IP cluster analysis per skills/ioc-aggregation
│   ├── url-patterns.md               # URL evasion → generalized regex
│   ├── file-patterns.md              # magic bytes + naming → yara synthesis
│   ├── open-questions.md             # unresolved; gates case close
│   ├── pending/s-<id>.json           # agent-emitted proposed steps
│   ├── results/s-<id>.json           # wrapper-written step results
│   ├── actions/
│   │   ├── pending/<act-id>.json     # awaiting operator approval
│   │   ├── applied/<act-id>.json     # applied; carries retire-hint
│   │   └── retired/<act-id>.json     # closed; no longer active
│   ├── defense-hits.md               # running log of blocks that fired
│   ├── STEP_COUNTER                  # monotonic step-id allocator
│   └── closed.md                     # present iff case closed: brief file_ids + retirement schedule
```

- Size cap: 100 KB per memory per Managed Agents spec
- Memory-store API is path-based (`/bl-case/...`), not key-based; the wrapper's `bl_mem_*` helpers in `20-api.sh` translate `bl-case/<key>` ↔ `/bl-case/<key>` and use last-write-wins semantics (DELETE-then-POST) where the platform retired `if_content_sha256`

### 7.3 Files (Anthropic Files API)

- **Workspace files (8):** `foundations.md`, six routing-skill corpora, `substrate-context-corpus.md`. Mounted at session creation via `resources[]`. Skill-fallback mode (Skills API 404) re-uploads each routing-skill `SKILL.md` as a corpus file at `/skills/<name>-skill.md`.
- **Per-case files:** raw observation JSONL bundles + closed-case briefs. Hot-attached mid-session via `POST /v1/sessions/<id>/resources`.
- Persistence: indefinite; deleted only by explicit API call or via `bl setup --gc`.

### 7.4 Local state (`/var/lib/bl/`, override via `BL_VAR_DIR`)

```
/var/lib/bl/
├── state/
│   ├── state.json              # schema_version=1; agent.id, agent.version,
│   │                             env_id, skills{}, files{},
│   │                             files_pending_deletion[], case_memstores{},
│   │                             case_files{}, case_id_counter{}, case_current,
│   │                             session_ids{}, last_sync
│   ├── state.json.lock         # FD 203 — bl setup --sync serialization
│   ├── case-id-counter         # FD 201 — flock'd YYYY/NNNN allocator
│   ├── case.current            # current-case pointer for this shell
│   ├── agent-id                # cached agent id (legacy + first-run fallback)
│   └── session-<case>          # per-case session id (legacy mirror of state.session_ids)
├── ledger/<case>.jsonl         # FD 200 — flock'd append-only ledger (dual-write target)
├── backups/                    # pre-edit backups (htaccess, crontab, modsec)
├── quarantine/<case>/          # quarantined files keyed by case-id
├── fp-corpus/                  # benign corpus for sig FP-gating
└── outbox/                     # FD 202 — queued wake/signal_upload/action_mirror
```

`/var/lib/bl/` is wipeable without data loss; authoritative state lives in the workspace. `state.json` is the primary state authority — the M15 migration moved authoritative writes into JSON keys with a defensive timestamped backup at `state/migration-backup-<epoch>/` for one-cycle recovery. Per-key files (`agent-id`, `case.current`, `memstore-case-id`, `case-id-counter`, `env-id`) remain as fallback reads for backwards compatibility — `15-workdir.sh:27` reads `case.current` directly; `30-preflight.sh:37` caches `agent-id`; `20-api.sh`, `50-consult.sh`, `60-run.sh`, `70-case.sh` and `83-clean.sh` fall back to `memstore-case-id` when `BL_MEMSTORE_CASE_ID` is unset; `84-setup.sh:848` falls back to `env-id` during the migration window.

### 7.5 Ledger dual-write

Every applied action writes twice:

1. `bl-case/<case>/actions/applied/<act-id>.json` — remote, agent-visible, 30-day versioned
2. `/var/lib/bl/ledger/<case>.jsonl` — local, append-only, FD-200-flock'd

Outbox cycle-break invariant (`27-outbox.sh`): the queue's own `backpressure_reject` event is written via direct `printf` to the ledger file, never via the validated append helper, to prevent ledger-recursion through the P4 mirror_remote → outbox fallback. Drain reports use the validated helper exactly once per drain (the `outbox_drain` event).

---

## 8. `bl setup` — workspace bootstrap

### 8.1 Preflight (on every non-setup, non-help invocation)

`bl_preflight` (in `src/bl.d/30-preflight.sh`) runs before every verb except `setup` and `--help`/`--version`/`bl <verb> --help`. Eight ordered checks:

```bash
# 1. ANTHROPIC_API_KEY set + non-empty                        → 65 on fail
# 2. curl + jq on PATH                                        → 65 on fail
# 3. mkdir -p "$BL_STATE_DIR"                                 → 65 on fail (RO fs / perms)
# 4. Seed BL_MEMSTORE_CASE_ID from state.json's
#    .case_memstores._default (M15 — old per-key file retired)
# 5. Use cached BL_AGENT_ID_FILE if present (early return 0)
# 6. Else probe GET /v1/agents (list all; filter client-side
#    on .name == "bl-curator" — ?name= is NOT supported)
#    miss → emit bootstrap message, return 66 BL_EX_WORKSPACE_NOT_SEEDED
# 7. Age-gated outbox drain (oldest entry ≥ 1h)
# 8. M14: load /etc/blacklight/blacklight.conf (allowlisted keys),
#    register notify channels
```

Exit codes from preflight: 65 (`BL_EX_PREFLIGHT_FAIL`) on missing key/tool/RO-fs, 66 (`BL_EX_WORKSPACE_NOT_SEEDED`) on agent-not-found, 69/70 on upstream error / rate-limit while probing.

### 8.2 Setup operations (one-time per workspace)

`bl setup --sync` performs these operations idempotently. `state.json.lock` is held via `flock -x -w 30 203` for the full sync to serialize concurrent invocations.

1. **Local preflight** — `bl_setup_local_preflight` carries the same `ANTHROPIC_API_KEY` + `curl` + `jq` + state-dir checks as `bl_preflight` (which is bypassed for `setup`).
2. **Load state** — `bl_setup_load_state` reads `state.json`; first-run migration consumes any pre-M15 per-key files into the JSON, with a timestamped recovery backup.
3. **Ensure environment** `bl-curator-env` via `POST /v1/environments` with body `{name, config:{type:"cloud", networking:{type:"unrestricted"}}}` only — `packages` is **not** a valid env-create field on `managed-agents-2026-04-01` (probed 2026-04-26, see `bl_setup_compose_env_body` at `84-setup.sh:967-984`). Curator-side packages (`apache2`, `libapache2-mod-security2`, `modsecurity-crs`, `yara`, `jq`, `zstd`, `duckdb`, `pandoc`, `weasyprint`) are installed per-session by the agent via the bash tool when needed.
4. **Ensure memory store** `bl-case` (`POST /v1/memory_stores {name: "bl-case"}`). `bl-skills` is **not** created — retired in Path C.
5. **Seed corpus Files (8)** — `bl_setup_seed_corpus` SHA-256-diffs each `skills-corpus/*.md` against `state.files.<mount-path>.content_sha256`; uploads changed via `bl_files_create`; old `file_id` queued in `state.files_pending_deletion[]` for `--gc`. Mount path = `/skills/<basename>`.
6. **Seed routing Skills (6)** — `bl_setup_seed_skills` probes `/v1/skills` with raw curl; HTTP 200 → create / version-bump per `routing-skills/*/`; HTTP 404 → fallback to `bl_setup_seed_skills_as_files`, uploading each `SKILL.md` as a corpus file at `/skills/<name>-skill.md`. SHA-256 delta check covers both `description.txt` and `SKILL.md` bodies.
7. **Ensure agent** `bl-curator` — `bl_setup_ensure_agent` creates via `POST /v1/agents` if first-run, or updates via `POST /v1/agents/<id>` with optimistic-CAS body `{version: <current>, ...}` if existing. On HTTP 409 (`Concurrent modification detected`) the client refetches via `GET /v1/agents/<id>` and retries once with the fresh version. Body shape in §12.1.
8. **Save state** — `state.json` written atomically (`mv` from `.tmp.$$`). `last_sync` stamped.

### 8.3 Source-of-truth resolution

`bl_setup_resolve_source` discovers skill content in this order:

1. `BL_REPO_ROOT` env points at a tree containing `skills/` + `prompts/curator-agent.md` — use it (test infra + dev iteration override).
2. CWD has `skills/` + `prompts/curator-agent.md` — use CWD.
3. `BL_REPO_URL` set — shallow clone to `$XDG_CACHE_HOME/blacklight/repo`, use.
4. Default — `git clone --depth 1 https://github.com/rfxn/blacklight` to cache, use.

Network-failure on `BL_REPO_URL` falls through to the default GitHub URL with a warn; default-URL failure surfaces an operator-facing remediation hint.

### 8.4 `bl setup --reset`

Archives the agent (`POST /v1/agents/<id>/archive` — see §12.6), deletes Skills + workspace Files, clears `state.json` to a fresh schema-1 shape **but preserves `case_memstores`, `case_files`, `case_id_counter`, `case_current`** (so an operator who resets workspace identity keeps their case audit trail). Defensive ordering: agent archive must succeed before any deletes; an agent-archive failure aborts the reset rather than wipe `state.json` while a live agent still exists.

### 8.5 `bl setup --gc`

Walks `state.files_pending_deletion[]`; deletes each `file_id` via `DELETE /v1/files/<id>` if no live session in `state.session_ids` references it. Anthropic does not currently expose per-file usage enumeration — conservative posture is to skip when any live session is present.

### 8.6 Idempotency contract

All setup operations are safely re-executable. Agent exists → POST `/v1/agents/<id>` with CAS instead of POST `/v1/agents`. Memory-store exists → cache id, skip create. Skill / corpus content unchanged → SHA-256 match → skip push. Operator running `bl setup` on host 5 after host 1 produces a no-op with a friendly summary.

### 8.7 LMD integration sub-verbs

- `bl setup --install-hook lmd` — copies `files/hooks/bl-lmd-hook` to `/etc/blacklight/hooks/`, edits `/usr/local/maldetect/conf.maldet` to set `post_scan_hook="..."` (flock-serialized; `bash -n` syntax check on conf; restore-from-backup on parse fail).
- `bl setup --import-from-lmd` — reads `conf.maldet`, writes notification credentials (email, Slack, Telegram, Discord) under `/etc/blacklight/notify.d/*` with `chmod 0600`. Metacharacter rejection and key-allowlist before any write.

### 8.8 Workspace recovery — lost or corrupted `state.json`

`state.json` is operator-local; the agent / memory store / workspace files / skills all persist on Anthropic's side. An operator whose host loses `state.json` (reinstall, accidental rm, disk failure) recovers via re-running `bl setup --sync`:

1. **Agent rebind.** `GET /v1/agents` returns the workspace agent list; client-side filter on `.name == "bl-curator"` rebinds `state.agent.id` and `state.agent.version` from the live record. The CAS sequence resumes from whatever the live agent's `version` field reports.
2. **Environment / memory store / workspace Files / Skills rebind.** Each is name-keyed on the workspace; sync's idempotency contract (§8.6) treats existing-by-name as cache hit and skips create. The full workspace surface re-binds without re-uploading content. SHA-256 delta-check covers any local content that was edited between the loss and the recovery.
3. **What does NOT recover automatically.** `state.session_ids[<case>]` and `state.case_files[<case>]` live only in `state.json`. After recovery, prior cases are visible in the `bl-case` memory store but their per-case session ids are lost — the next `bl consult --attach <case>` opens a fresh session against the existing memory-store subtree (the hypothesis / open-questions / attribution state survives intact via the memory store; only the SSE session continuity is reset).
4. **Per-case Files (evidence bundles, briefs).** Recoverable by re-running observe verbs to regenerate bundles, or by reattaching from the workspace Files API if the `file_id` was recorded in the case memory store. Closed-case briefs likewise rebind from `bl-case/CASE-<id>/brief-file-id`.

The recovery path assumes the workspace `ANTHROPIC_API_KEY` and Anthropic-side records are intact. A workspace that has itself been lost (organization-level deletion) has no recovery short of re-running `bl setup --sync` against a new workspace and accepting that prior case continuity is gone — the audit trail is in the closed-case briefs, which the operator should retain out-of-band per §13.4.

---

## 9. Skills architecture

### 9.1 Structure

70 markdown files across 23 subdirectories under `skills/` (raw research substrate).

```
skills/                  23 subdirs / 70 *.md — raw operator-voice research
  actor-attribution, agentic-minutes-playbook, apf-grammar, apsb25-94,
  bl-capabilities, cpanel-easyapache, defense-synthesis, false-positives,
  hosting-stack, ic-brief-format, ioc-aggregation, ir-playbook,
  legacy-os-pitfalls, linux-forensics, lmd-triggers, magento-attacks,
  modsec-grammar, obfuscation, remediation, ride-the-substrate,
  shared-hosting-attack-shapes, timeline, webshell-families

routing-skills/          6 routing Skills (description-routed, lazy-loaded)
  authoring-incident-briefs, curating-cases, extracting-iocs,
  gating-false-positives, prescribing-defensive-payloads,
  synthesizing-evidence

skills-corpus/           8 mounted corpus files (mounted at session create)
  foundations.md, substrate-context-corpus.md,
  <one-corpus-per-routing-skill>.md  (6 files)
```

Each routing Skill is a `<name>/{description.txt, SKILL.md}` pair: `description.txt` is the routing description the platform matches on; `SKILL.md` is the body that gets lazy-loaded into the curator's context when routed. Workspace corpus Files are mounted at session create as `/skills/<basename>` — always present, not lazy-loaded.

### 9.2 Authoring discipline

Each skill:
1. Opens with a scenario from lived experience (the incident, the shift boundary, the customer call) — not a definition.
2. States a non-obvious rule — something a competent analyst who has *not* worked at this scale would get wrong.
3. Gives a concrete example drawn from public APSB25-94 material (never operator-local).
4. Names a failure mode and how the rule handles it.
5. Assumes operator literacy; does not explain generic concepts.

**If the only available draft would be generic IR/SOC boilerplate, flag the gap and land the file later — never ship slop.**

### 9.3 Third-party extensibility

A defender running DirectAdmin, Virtualmin, or Plesk drops their own `skills/<platform>/*.md` subtree into the repo and runs `bl setup --sync`. SHA-256 delta-check picks up the additions; the curator reads them on next session wake. New vocabulary available; zero wrapper code change; zero agent retraining.

---

## 10. Evidence format contract

### 10.1 JSONL on the wire

Every `bl observe` output is JSONL, one record per line. Common preamble:

```json
{"ts": "2026-04-26T04:17:08Z", "host": "example-host", "source": "apache.transfer", "record": { /* source-specific */ }}
```

Apache transfer record fields: `client_ip`, `method`, `path`, `status`, `bytes`, `ua`, `referer`, `site`, plus derived: `path_class`, `is_post_to_php`, `status_bucket`.

### 10.2 Bundle shape

Evidence bundles are `tar + gzip -5` (or `zstd -3` if available):

```
bundle-<host>-<window>.tgz
├── MANIFEST.json           (host, window, sources, sha256s, bl version)
├── summary.md              (≤2 KB first-read — top IOCs, counts, hot paths)
├── transfer.log.jsonl      (pre-parsed Apache/nginx access records)
├── modsec_audit.jsonl      (pre-parsed ModSec audit events)
├── fs_anomalies.jsonl      (mtime clusters, perm drift, suid changes)
└── system_messages.jsonl   (journalctl extracts)
```

### 10.3 The `summary.md` convention

The first file the agent reads. ≤2 KB. Structured:

```
# Evidence bundle — <host> — <from> → <to>

## Trigger
<one-paragraph description of the artifact that prompted collection>

## Top-line findings
- <bullet list of ≤7 facts>

## Jump points
- <jq/grep expressions the agent can use to drill into the JSONL files>

## Attention-worthy
- <anomalies the pre-parse flagged>
```

`summary.md` is rendered by Sonnet 4.6 (`bl_messages_call` in `42-observe-router.sh`) over the bundle's structured pre-parse output. Raw logs never enter agent context directly — the agent reads `summary.md` first, drills into JSONL via `grep` / `jq` / `duckdb` tool-use on demand.

### 10.4 Compression

- Default: `gzip -5` — portable to CentOS 6 / bash 4.1 baseline without EPEL.
- Upgrade: `zstd -3` if `command -v zstd` succeeds — ~1.3× smaller, faster compress.
- Extension is `.tgz` regardless; tar magic-byte detects codec on decompress.

---

## 11. Remediation safety model

Five mechanical disciplines apply across every `bl clean` and `bl defend modsec/sig` operation.

### 11.1 Diff shown before apply

For file edits (`clean htaccess`, `clean cron`):

```
bl-clean 2026-04-26T04:27:15Z — CASE-2026-0017 step s-10
Target: /home/sitefoo/.../.htaccess

Diff (proposed):
   -  <FilesMatch "\.php$">
   -      Require all denied
   -  </FilesMatch>
   +  # (line removed — injected block, per agent analysis)

Backup: /var/lib/bl/backups/2026-04-26T04-27-15Z.htaccess
Apply? [y/N/diff-full/explain/abort]
```

`diff-full` shows the whole before/after file. `explain` requests the agent's reasoning field from the pending-step JSON. `abort` cancels and marks the step as operator-rejected.

### 11.2 Backup before apply

Every `bl clean` writes a pre-apply backup to `/var/lib/bl/backups/<ISO-ts>.<hash>.<basename>`. `bl case log` lists them; `bl clean --undo <backup-id>` restores.

### 11.3 `--dry-run` contract

Every `bl clean` subcommand supports `--dry-run`. Dry-run shows the full diff and backup path but takes no action and writes nothing.

### 11.4 Quarantine, not delete

`bl clean file` never unlinks. Files move to `/var/lib/bl/quarantine/<case-id>/<sha256>-<basename>` with a manifest entry per `schemas/quarantine-manifest.json`. `bl case show --quarantine` lists them; `bl clean --unquarantine <entry>` restores.

### 11.5 Capture before kill

`bl clean proc <pid>` captures `/proc/<pid>/{cmdline,environ,exe,cwd,maps,status}` and `lsof -p <pid>` to the case evidence before `SIGTERM` then `SIGKILL`. `--capture=off` disables; default is capture-on.

### 11.6 Brief rendering — Markdown canonical, HTML/PDF best-effort

`bl case close` always writes the case brief to the Files API as `text/markdown` (the `fid_md` returned to `bl-case/<case-id>/closed.md` is the canonical artifact). HTML and PDF renders are produced by the curator's environment-side `pandoc` + `weasyprint` toolchain (installed per-session by the agent via the bash tool) when the curator is running and reachable. If the env is unreachable or the render times out (60s), `bl case close` degrades gracefully — `closed.md` records empty `brief_file_id_html` / `brief_file_id_pdf` and the operator can re-run `bl case close --re-render` later.

Operators who need deterministic local-only rendering pass `BL_BRIEF_MIMES=text/markdown` to skip the stage-2 delegate entirely.

---

## 12. Model calls

**One curator agent, three custom-tool emit modes, plus two narrow Messages-API helpers.** v0.4 runs a single `bl-curator` Managed Agent record — Opus 4.7, 1M context — with three custom tools that specialise its emit surface: `report_step` (wrapper actions), `synthesize_defense` (rule/firewall/sig authoring), `reconstruct_intent` (shell-sample analysis). Two non-Managed-Agents calls supplement: Sonnet 4.6 for evidence-bundle summary rendering, Haiku 4.5 for sig-FP-gate adjudication. Both supplements use `bl_messages_call` (`POST /v1/messages`, no `anthropic-beta` header).

**Agent-create constraint (verified 2026-04-24 against `managed-agents-2026-04-01`):** `POST /v1/agents` rejects `thinking` and `output_config` as extra inputs (HTTP 400 `invalid_request_error`). The only create-time shape-controls on Managed Agents today are `name`, `model`, `system`, `tools`, `mcp_servers`, `skills`, `callable_agents`, `description`, `metadata`. Thinking is model-internal and not operator-configurable; structured output ships through custom tools.

**Custom-tool `input_schema` subset (verified same probe):** `additionalProperties` and per-field `description` are rejected inside `input_schema`. Accepted keywords for the blacklight schemas: `type`, `properties`, `required`, `enum`, `items`, type-array unions like `["string", "null"]`. The wire-format files in `schemas/*.json` are minimal-subset; per-field documentation lives in companion `schemas/*.md` files. `bl setup` strips top-level metadata (`$schema`, `$id`, `title`) before submit.

`BL_DISABLE_LLM=1` short-circuits all LLM calls (curator session + bundle summary + FP-gate). The test suite exports this — no live Anthropic API in CI. `tests/helpers/curator-mock.bash` shims `curl` against `tests/fixtures/step-*.json` for fixture-driven flow.

### 12.1 Curator — agent-create shape

- Model: `claude-opus-4-7`
- Context: 1M
- System prompt: `prompts/curator-agent.md` (curator voice + IR playbook anchors + untrusted-content fence taxonomy from §13.2)
- Tools (`bl_setup_compose_agent_body` in `84-setup.sh`):
  ```json
  [
    {"type": "agent_toolset_20260401"},
    {"type": "custom", "name": "report_step",
     "description": "Emit a proposed blacklight wrapper action. One call per step.",
     "input_schema": "<schemas/step.json stripped of $schema/$id/title>"},
    {"type": "custom", "name": "synthesize_defense",
     "description": "Propose a defensive payload for this case.",
     "input_schema": "<schemas/defense.json stripped>"},
    {"type": "custom", "name": "reconstruct_intent",
     "description": "Walk obfuscation layers of a mounted shell sample.",
     "input_schema": "<schemas/intent.json stripped>"}
  ]
  ```
- Resources at session creation: `bl-case` memory store + workspace corpus Files (8) + per-case Files (hot-attached via `POST /v1/sessions/<sid>/resources`). Sessions.create body uses `agent: <id>` + `environment_id: <id>` + `resources: [...]` (see §12.6 for the field-name correction).
- Lifetime: one session per case; resumable across 30-day checkpoint window; per-case session id persisted to `state.session_ids[<case>]`.
- Reasoning behavior: Opus 4.7 reasoning is model-internal. The platform SSE stream surfaces reasoning content at runtime via dedicated event types; blacklight does not configure or control reasoning depth.

### 12.1.1 `report_step` — step-emit surface

The curator emits each proposed wrapper action as one `agent.custom_tool_use` event invoking `report_step`. Flow:

1. Curator invokes `report_step` with the step envelope as `input`.
2. Platform validates `input` against `input_schema`, emits `agent.custom_tool_use` with `custom_tool_use_id`; session status → `idle` + `stop_reason: requires_action`.
3. Wrapper consumes via `bl_poll_pending` (foreground) or `bl_run_list` (on-demand). For each emit:
   - Re-validate against `schemas/step.json` (`bl_jq_schema_check` covers required / enum / additionalProperties; per-kind pattern guards in callers).
   - On pass: write `bl-case/<case-id>/pending/<step_id>.json`; reply with `user.custom_tool_result` carrying `{status: "queued", step_id}`.
   - On fail: reply with `{status: "rejected", step_id, reason}`. No partial writes.
4. Operator runs `bl run <step_id>` (or `bl run --batch`); wrapper executes under the gate defined by `action_tier`; result lands in `bl-case/<case-id>/results/<step_id>.json`; wrapper sends a wake event referencing the new result records.

`schemas/step.json` is the single wire-format source of truth (platform-side `input_schema` value + wrapper-side pre-write validation).

### 12.2 `synthesize_defense` — defense-authoring surface

Curator invokes when a case has enough correlated evidence to justify authoring a defensive payload (ModSec rule body, firewall entry set, scanner signature). Wrapper reads payload, writes to `bl-case/<case>/actions/pending/<act-id>.json`, runs the kind-specific FP-gate inside the curator's sandbox (`apachectl configtest` for ModSec, benign-corpus scan for sigs, CDN safe-list for firewall), and replies with `gate_status={pass, fail, deferred}`.

### 12.3 `reconstruct_intent` — sample-analysis surface

Curator invokes when it wants a focused pass on a specific shell sample mounted via `POST /v1/sessions/<sid>/resources`. Tool input names the mounted `file_id` and analysis depth (`shallow` / `deep`). Wrapper reads the attribution artifact the curator wrote to `bl-case/<case>/attribution.md`, replies with `{status: queued, attribution_id}`. Intent reconstruction runs inside the curator's own reasoning — no separate session, no separate model.

### 12.4 Sonnet 4.6 — bundle summary render

`bl observe bundle` calls `bl_messages_call claude-sonnet-4-6 <sys-prompt> <user-msg> 1500` (in `42-observe-router.sh`) over the assembled JSONL pre-parse output to produce `summary.md`. Output is uploaded to the Files API and recorded in `state.case_files[<case>]`. `BL_DISABLE_LLM=1` skips the call.

### 12.5 Haiku 4.5 — FP-gate adjudication

`bl defend sig` calls `bl_messages_call claude-haiku-4-5 <sys-prompt> <user-msg> 200` (in `82-defend.sh`) when the corpus FP-scan returns borderline hits — Haiku adjudicates pass/fail. Verdict is embedded in the action JSON; no Files API write. `BL_DISABLE_LLM=1` skips, defaulting to fail-closed.

### 12.6 Live API divergence (probed 2026-04-26 — M15)

Three corrections applied in M15 against the live Anthropic Managed Agents API surface (`anthropic-beta: managed-agents-2026-04-01`):

1. **Agent update verb** — `POST /v1/agents/<id>` with CAS `version` field in the body, **not** `PATCH /v1/agents/<id>`. PATCH returns 405. Concurrent updates surface as HTTP 409 (`Concurrent modification detected`); client refetches via `GET /v1/agents/<id>` and retries with the new version. Implemented as `bl_setup_update_agent_cas` in `84-setup.sh`.
2. **Agent retire verb** — `POST /v1/agents/<id>/archive`, **not** `DELETE /v1/agents/<id>`. DELETE returns 405. Empty `{}` body matches the documented archive verb shape. `bl setup --reset` aborts if archive fails — the local `state.json` must never be wiped while a live agent still exists.
3. **Sessions.create body field name** — `agent: <id>`, **not** `agent_id: <id>`. The wrong name is rejected with `agent_id: Extra inputs are not permitted. Did you mean 'agent'?`. The response shape is unrelated and may still carry `agent_id`. Implemented in `bl_consult_create_session` in `50-consult.sh`.

`bl_api_call` (in `20-api.sh`) maps the conflict to `BL_EX_CONFLICT=71`; agent-update's CAS retry is the only caller that distinguishes 409 from other 4xx by exit code.

### 12.7 Primitives deliberately not used

Two Managed Agents primitives are intentionally absent from blacklight's Layer B surface. The omission is a framing decision, not a roadmap deferral.

**`callable_agents` — not used.** The v1 architecture dispatched per-evidence-class hunters (log-hunter, fs-hunter, timeline-hunter) as separate Sonnet 4.6 sessions and merged their output. v2 retired that pattern in favor of single-session 1M-context cross-stream correlation: every evidence stream loads into the same session and the curator reasons over the full bundle in one pass (`prompts/curator-agent.md` §1, `PIVOT-v2.md §4.2`). The cross-stream correlation that distinguishes signal from noise only resolves when every stream is in scope simultaneously — sub-agent dispatch fragments that bundle. Re-introducing `callable_agents` would re-introduce the v1 fragmentation; the 1M context is the architectural answer, not a workaround.

**`mcp_servers` — not used.** blacklight's pitch is the host's own defensive primitives (ModSec, APF, CSF, iptables, nftables, LMD, ClamAV, YARA) directed by the curator. MCP integrations would extend the surface to external systems (cloud firewalls, ticketing, SIEM forwarders) — valuable, but a different product. The Layer C boundary in §3 ("existing defensive primitives on the host") is the framing constraint; an MCP-exposed external system is *not* on the host. Items 18 (notification channels) and 5 (additional firewall backends) in `FUTURE.md` cover the externalization path through wrapper-side adapters when the surface needs to grow there, keeping the curator's tool-invocation contract local.

The two helper Messages-API calls (`bl_messages_call` against Sonnet 4.6 for bundle summary and Haiku 4.5 for FP-gate adjudication, §12.4-§12.5) are wrapper-side cost optimizations *outside* the curator session — not callable_agents from inside it. The distinction is load-bearing: the curator reasons in a single 1M-context session; the wrapper independently reaches for cheaper models on bounded tasks the curator does not need to see.

---

## 13. Security model

blacklight operates with root-equivalent privilege on target hosts (modifying ModSec config, firewall state, crontab, webroot files). The security boundaries:

### 13.1 Auth surface

- Sole secret: `$ANTHROPIC_API_KEY` (operator-provisioned; never in repo)
- No service account; no long-lived tokens; no cert management
- API key scope = workspace scope = blast radius; operators should provision dedicated workspaces for production use

### 13.2 Prompt-injection hardening (`26-fence.sh`)

- Routing Skills are version-pinned at session creation; the agent cannot modify them at runtime — attacker-supplied log content cannot rewrite operator knowledge (Skills primitive is read-only from the agent's perspective)
- Every untrusted evidence record is wrapped in a session-unique fence when handed to the curator. Fence tokens are `sha256(case_id || payload || nonce)[:16]` (64-bit entropy; per-record nonce); attacker cannot forge a matching end-token without changing the payload hash
- Curator system prompt includes an explicit taxonomy of injection attempts (role reassignment, schema override, verdict flip) and routes those strings to evidence fields, never acts on them
- `bl case log --audit` consumes the same fence-kind helper to decode wake-event entries from the outbox for forensic review

### 13.3 Agent output validation

- `bl run` validates the step-JSON schema (`bl_jq_schema_check`) before executing
- Unknown verbs fall into the "unknown" tier → deny by default
- The agent cannot emit arbitrary bash; it emits step records that map to named verbs with typed arguments
- Destructive steps fail validation if missing a `diff` or `patch` field
- Outbox payloads are schema-checked against `schemas/outbox-{wake,signal_upload,action_mirror}.json` plus per-kind regex pattern guards (the schema subset cannot enforce `pattern`)

### 13.4 Operator ledger (dual-write)

- Every applied action is written to `bl-case/<case>/actions/applied/` in the memory store (remote, agent-visible) AND to `/var/lib/bl/ledger/<case-id>.jsonl` (local, append-only, FD-200-flock'd)
- Dual write protects against both "agent memory corrupted" and "host wiped" scenarios
- `bl case log --audit` prints the ledger in a regulator-friendly format
- Ledger-recursion is structurally prevented: the outbox's own backpressure-reject record bypasses `bl_ledger_append` and writes via direct `printf` (cycle-break invariant in `27-outbox.sh`)

### 13.5 Rate limiting + outbox

- Files API rate limit ~100 RPM during beta — uploads enqueue via `bl_outbox_enqueue` and drain at ≤50 RPM
- Outbox watermarks: warn at 500, hard-stop at 1000 (returns `BL_EX_RATE_LIMITED=70`)
- Age-gated drain: preflight only drains when oldest entry is ≥`BL_OUTBOX_AGE_WARN_SECS` (1h) old — recently-enqueued events sit until next preflight or explicit `bl flush --outbox`

---

## 14. Dependencies

### 14.1 Tier 1 — always present

Host runtime floor (CentOS 6+, Debian 8+, Ubuntu 16.04+, RHEL 7+, Rocky 8+; bash 4.1+):

- `bash` ≥4.1
- `coreutils` (`ls`, `cat`, `stat`, `find`, `sort`, `uniq`, `head`, `tail`, `wc`, `sha256sum`, `tar`, `gzip`)
- `curl`
- `awk` (mawk or gawk; gawk preferred for associative arrays — interval-quantifier avoidance documented in `50-consult.sh`)
- `sed`
- `grep` (GNU preferred for `-F -f patterns.txt` Aho-Corasick speed)

### 14.2 Tier 2 — ship as `bl` deps

- `jq` — single static binary, ~3 MB, portable back to CentOS 6. **Required** (`bl_preflight` fails 65 if missing).
- `zstd` — optional, runtime-detected. Falls back to `gzip`.

### 14.3 Tier 3 — curator sandbox only (not host)

Inside the Anthropic-hosted environment, installed **per-session** by the agent
via the bash tool when the active step needs them (env-create body carries only
`{name, config}` — `packages` is not a valid create-time field today):

- `apache2 + libapache2-mod-security2 + modsecurity-crs` — for `apachectl -t` pre-flight of synthesized ModSec rules
- `yara` — for on-sandbox signature testing
- `duckdb` — for agentic SQL over JSONL (`SELECT client, count(*) FROM read_json_auto('transfer.jsonl') WHERE path LIKE '/custom_options/%' GROUP BY 1`)
- `pandoc` + `weasyprint` — for stage-2 brief HTML/PDF render (degrades gracefully if unavailable)

None of these Tier-3 deps are installed on the fleet host.

### 14.4 What is explicitly NOT required

- **No Python** at runtime on any host
- **No Docker** (operator can use docker for demo fixture; `bl` runs native)
- **No systemd** requirement (LMD `post_scan_hook` integration uses LMD's own mechanism, not systemd)
- **No database** (SQLite or otherwise) — all state in memory stores + files + small local ledger
- **No web server** or local HTTP listener — `bl` is a command, not a service

---

## 15. Non-goals (explicit)

This document and v0.4 deliberately do not describe:

- **Fleet-scope orchestration.** `bl` is per-host. Fleet propagation of defenses rides the operator's existing deployment primitive (Puppet, Ansible, Salt, Chef, manual SSH) — blacklight generates the payload; the operator propagates.
- **Continuous posture monitoring daemon.** v0.4 is trigger-bound. Posture arc (periodic sweeps, trajectory analysis) is roadmap P2.
- **Web frontend or dashboard.** The terminal REPL is the operator surface. A rendered HTML brief is a post-close artifact, not the primary interface.
- **Replacing defensive primitives.** blacklight directs `apachectl`, `apf`, `csf`, `iptables`, `nftables`, `maldet`, `clamscan`, `yara` — it does not re-implement any of them.
- **Cross-CVE threat intelligence sharing.** Roadmap P2+.
- **Windows / BSD support.** Roadmap P4. v0.4 is Linux only.

---

## 16. Glossary

- **Case** — an investigation; carries hypothesis, evidence, actions, precedent. One per incident; allocated as `CASE-YYYY-NNNN` via `bl_consult_allocate_case_id` (FD-201-flock'd).
- **Step** — a single action the agent prescribes. Has an action tier, a verb, typed arguments, and a reasoning field. Authored via the `report_step` custom tool; written to `bl-case/<case>/pending/`.
- **Action tier** — one of `read-only`, `auto`, `suggested`, `destructive`, `unknown`. Determines gate behavior. Authored by agent, enforced by wrapper.
- **Routing Skill** — a description-routed operator-voice behavior module uploaded to the Anthropic Skills primitive. Lazy-loaded by the curator when the description matches the current reasoning need. Six in Path C; corpus content delivered alongside via Files API.
- **Corpus File** — a workspace-scope markdown file mounted at session creation under `/skills/<basename>` (always present, not lazy-loaded). Eight in Path C.
- **Trigger** — the first signal that opens a case (e.g. maldet quarantine, auditd critical event, ModSec rule fire). Fingerprinted as `sha256(scanid|sigs|paths)[:16]` for LMD; `sha256(<artifact>)[:16]` for direct file triggers.
- **Curator** — the Managed Agents session that owns a case (`bl-curator`).
- **Synthesizer / Intent reconstructor** — structured-emit modes of the same curator (`synthesize_defense`, `reconstruct_intent` custom tools), not separate sessions.
- **Precedent** — a closed case accessible to future cases via `bl-case` memory store (lives within the same memstore in v0.4, not a separate store).
- **Defense** — any applied change to host state that reduces attack surface (ModSec rule, firewall entry, scanner signature).
- **Remediation** — any applied change to host state that removes attacker presence (file quarantine, cron strip, .htaccess edit, process kill).
- **Fence** — session-unique 64-bit-entropy token wrapping untrusted content; prevents prompt-injection via attacker-controlled log/file payloads.
- **Outbox** — `/var/lib/bl/outbox/`, the rate-limit queue for wake / signal_upload / action_mirror records when the workspace is unreachable or rate-limited.
- **Ledger** — `/var/lib/bl/ledger/<case>.jsonl`, the local append-only audit trail (dual-write target alongside `bl-case/actions/applied/`).

---

## 17. Bash SDK surface

`bl` is built as a bash SDK that the CLI dispatcher consumes — not the other way around. Sourcing `bl` (`source bl || true`) exposes 137 `bl_*` functions across the families below plus two vendored `alert_*` / `tlog_*` libraries. Stable surfaces: `bl_api_*`, `bl_files_*`, `bl_skills_*`, `bl_ledger_*`, `bl_outbox_*`, `bl_fence_*`, `bl_messages_call`, `bl_notify`. Internal (not stable): everything else.

| Family | Source part | Count | Stability | Purpose |
|---|---|---|---|---|
| `bl_api_*` | `20-api.sh` | 1 (`bl_api_call`) | **stable** | Managed Agents REST surface — POST/GET/poll/wake; HTTP 5xx backoff+retry; conflict→`BL_EX_CONFLICT=71`. Direct Messages API uses `bl_messages_call` (Sonnet 4.6 / Haiku 4.5 paths) |
| `bl_files_*` | `23-files.sh` | 5 | **stable** | Files API — upload, attach to session via `sessions.resources.add`, GC orphans queued in `files_pending_deletion[]` |
| `bl_skills_*` | `24-skills.sh` | 4 | **stable** | Skills API — upload routing skills, version-pin in `state.json agent.skill_versions` |
| `bl_ledger_*` | `25-ledger.sh` | 2 | **stable** | Dual-write audit (memory store `actions/applied/` + `/var/lib/bl/ledger/<case>.jsonl`); cycle-break invariant: `backpressure_reject` bypasses validated append |
| `bl_outbox_*` | `27-outbox.sh` | 5 | **stable** | Rate-limit queue — high watermark 1000, warn 500, age-gated drain at `BL_OUTBOX_AGE_WARN_SECS` (default 3600) |
| `bl_fence_*` | `26-fence.sh` | 4 | **stable** | Prompt-injection fence — `sha256(case_id \|\| payload \|\| nonce)[:16]`; session-unique untrusted-content wrap |
| `bl_messages_call` | `22-models.sh` | 1 | **stable** | Direct Messages API (`POST /v1/messages`, no `anthropic-beta` header) — Sonnet 4.6 bundle summary, Haiku 4.5 FP-gate adjudication |
| `bl_notify` | `28-notify.sh` | 1 | **stable** | Multi-channel operator notification — alert_lib substrate; channels registered via `bl_notify_register_channel` |
| Internal | various | 114 | internal | Observers, dispatchers, tier-gate, case lifecycle, setup orchestration, preflight, cpanel helpers — change without notice |

Vendored libraries shipped inside `bl`:
- `alert_*` from `05-vendor-alert.sh` (1,191 LOC) — rfxn shared multi-channel alert library
- `tlog_*` from `06-vendor-tlog.sh` (783 LOC) — rfxn shared structured logging substrate
- Together ~19% of assembled `bl` line count; vendored to satisfy curl-pipe-bash single-file install (§19.1) without a runtime dependency on rfxn shared lib path

Stable functions follow the pattern `bl_<family>_<verb>(...)` with documented stdin/stdout/exit-code contracts; internal functions may be renamed at any milestone. Operators consuming the SDK should pin to a specific tagged version of `bl`.

---

## 18. Portability + dependency floor

### 18.1 OS floor matrix

`bl` runtime works on:

- **CentOS / RHEL 6** (November 2010 / bash 4.1 / 2.6.32 kernel) — the documented floor
- CentOS 7 / Rocky 8 / Rocky 9
- Debian 8 / Debian 12
- Ubuntu 16.04 / 20.04 / 24.04
- Any RHEL-family or Debian-family Linux with bash 4.1+ and a working curl

Distro matrix coverage in CI:

- Pre-commit gate (default): `make -C tests test` (debian12) + `make -C tests test-rocky9`
- Release gate: `make -C tests test-all` (full matrix at `tests/Dockerfile*`; CentOS 6 image at `tests/Dockerfile.centos6` covers the legacy floor)

### 18.2 Pre-usr-merge handling

CentOS 6 has coreutils at `/bin/`; modern distros at `/usr/bin/`. `bl` resolves coreutils via `command <util>` (e.g. `command cat`, `command chmod`, `command mv`) — never via hardcoded `/bin/cat` or `/usr/bin/cat`. This is enforced project-wide by `make bl-lint` (`bash -n` + `shellcheck` against the assembled `bl`) plus the workspace verification grep block in `/root/admin/work/proj/CLAUDE.md` §Verification.

The `command` prefix is project-wide for ALL coreutils — `chmod`, `mkdir`, `cat`, `touch`, `ln`, `cp`, `mv`, `rm`, etc. Exception: `printf` and `echo` are bash builtins, used bare.

### 18.3 Bash 4.1+ floor — what is NOT used

Forbidden constructs (bash 4.2+):
- `${var,,}` / `${var^^}` (bash 4.0 — usable, but project policy avoids the case-fold trio)
- `mapfile -d` (bash 4.4)
- `declare -n` namerefs (bash 4.3)
- `$EPOCHSECONDS` (bash 5.0)
- `declare -A` for global state (breaks when sourced inside functions on bash 4.1; `local -A` inside functions is safe)

Verify the version check: `grep -n "BASH_VERSINFO" src/bl.d/00-header.sh` — explicit `4.1` floor at top-of-file (`BASH_VERSINFO[0] * 100 + BASH_VERSINFO[1] < 401` aborts startup).

### 18.4 Dependency tiers

§14 carries the canonical tiering. Highlights for portability review:

- Tier 1 (always present): bash ≥ 4.1, coreutils, curl, awk, sed, grep
- Tier 2 (ship as `bl` deps): jq (required, ~3 MB static), zstd (optional, gzip fallback)
- Tier 3 (curator sandbox only — NEVER on host): `apache2 + libapache2-mod-security2 + modsecurity-crs`, `yara`, `duckdb`, `pandoc`, `weasyprint`. Installed by the agent **per-session** via the bash tool — not at env-create (the env body carries only `{name, config}`)

What is explicitly NOT required on the host (mirrors §14.4): no Python, no Docker, no systemd, no database, no web server, no local HTTP listener, no service port.

---

## 19. Install + uninstall + packaging

### 19.1 install.sh

Curl-pipe-bash safe one-shot installer at `install.sh`. Operator-runnable as:

```bash
curl -fsSL https://raw.githubusercontent.com/rfxn/blacklight/main/install.sh | sudo bash
```

Or local: `./install.sh --local`. With prefix override: `BL_PREFIX=/opt ./install.sh`.

What it does:
1. Fetches `bl` from `BL_REPO_URL` (defaults to GitHub raw main); `--local` short-circuits to a CWD copy.
2. Installs to `${BL_PREFIX}/usr/local/bin/bl` (default `/usr/local/bin/bl`); requires root unless `BL_PREFIX` is set.
3. Provisions `${BL_PREFIX}/etc/blacklight/` config dir + `${BL_PREFIX}/etc/blacklight/hooks/`.
4. Drops the `bl-lmd-hook` adapter into the hooks dir (executable bit set). **Wiring `post_scan_hook` into `/usr/local/maldetect/conf.maldet` is a separate, operator-driven step** — `bl setup --install-hook lmd` (see §8.7) — so installer runs are read-only relative to maldet config.

### 19.2 uninstall.sh

Reverses install.sh:
- Default mode is **interactive** — prompts before any state purge.
- `--yes` purges with backup.
- `--keep-state` removes binary only, preserves `/var/lib/bl/`.
- `--prefix` matches install.sh.
- Removes the `post_scan_hook` line from `${BL_LMD_CONF_PATH:-/usr/local/maldetect/conf.maldet}` if previously wired (sed-edit with `.bl-uninstall-bak` backup).

### 19.3 RPM + DEB

Native packaging at `pkg/rpm/blacklight.spec` (RPM, EL7+) and `pkg/deb/debian/*` (DEB, Debian 8+ / Ubuntu 16.04+). GitHub Actions workflow at `pkg/.github/workflows/release.yml` builds both on tag-push.

Test images: `pkg/docker/Dockerfile.test-deb`, `Dockerfile.test-rpm`, `Dockerfile.rpm-el7`, `Dockerfile.rpm-el9`, `Dockerfile.deb`. Validation: `pkg/test/test-pkg-install.sh`. Build artifacts (sample RPM) live under `pkg/build/rpms/`.

---

*End of DESIGN.md. For strategy, pitch, and roadmap see `PRD.md`. For the operator-facing public face, see `README.md`. Historical strategy notes are preserved at `.rdf/archive/docs-internal/PIVOT-v2.md`.*
