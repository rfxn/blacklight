# blacklight — design spec

*Authored: 2026-04-24. Canonical during v2 rewrite.*
*Companion to `PIVOT-v2.md` (strategy + narrative). This document is the implementation-facing spec.*

---

## 1. Purpose of this document

`PIVOT-v2.md` answers *why blacklight takes this shape*. This document answers *what the shape is, precisely enough to code against*. If you are writing `bl`, writing `bl setup`, extending a skill, or reading the repo cold to understand the system — this is the file to read.

Scope: architecture, command surface, runtime flow, state model, safety gates, evidence format, dependencies. Out of scope: competitive positioning, market framing, roadmap (all in `PIVOT-v2.md`).

---

## 2. The pitch in one paragraph

**blacklight** is a portable bash wrapper (`bl`) that turns any Linux host into an agent-directed incident-response surface. The wrapper runs locally — bash 4.1+, `curl`, `awk`, `jq` — with zero daemons and zero Python. Every investigation is a conversation between the operator, the wrapper, and a **Managed Agents session** hosted in the operator's Anthropic workspace. That session — Opus 4.7, 1M context, ~22 operator-voice skill files mounted at creation (see §9) — decides what to look at next, authors the defensive payloads (ModSec rules, firewall entries, YARA sigs), and prescribes remediation (rogue cron stripping, `.htaccess` cleanup, quarantine). The wrapper executes; the agent directs; the existing defensive primitives your host already runs (ModSec, APF, CSF, iptables, nftables, LMD, ClamAV, YARA) are the hands. Man-days of manual IR become agentic-minutes on the substrate the defender already owns.

---

## 3. Architecture — three layers

```
┌─ Layer A — `bl` on the host (bash, ~1000 lines, one file) ───────────────┐
│                                                                           │
│  bl observe  bl consult  bl run  bl defend  bl clean  bl case  bl setup  │
│                                                                           │
│  Dependencies: bash ≥ 4.1, curl, awk, jq, grep, sed, tar, gzip.          │
│  No daemons. No services. Invoked per operator thought; exits when done. │
│                                                                           │
└─────────────────────────────────────────────┬─────────────────────────────┘
                                              │ HTTPS + API key
                                              ↓
┌─ Layer B — Managed Agent session (Anthropic-hosted) ─────────────────────┐
│                                                                           │
│  agent         bl-curator  (Opus 4.7 + 1M context, Managed Agent session) │
│  environment   bl-curator-env  (apt: apache2, mod_security2, yara,       │
│                jq, zstd, duckdb — installed once at env creation)        │
│  skills        6 routing Skills (description-routed behavior modules)    │
│  memory store  bl-case     hypothesis + steps + working memory           │
│  files         corpus (8 files) + per-case evidence + closed briefs      │
│                                                                           │
│  No local runtime process. The session lives in the Anthropic workspace. │
│  `bl` reaches it via HTTPS on every invocation.                           │
│                                                                           │
└─────────────────────────────────────────────┬─────────────────────────────┘
                                              │ step directives
                                              ↓
┌─ Layer C — existing defensive primitives on the host ────────────────────┐
│                                                                           │
│  apachectl + mod_security, APF, CSF, iptables, nftables, LMD, ClamAV,    │
│  YARA, Apache / nginx logs, journalctl, crontab, find, stat, cat -v      │
│                                                                           │
│  blacklight directs these; it does not install, replace, or re-abstract  │
│  them. They predate blacklight and will outlive it.                       │
│                                                                           │
└───────────────────────────────────────────────────────────────────────────┘
```

**Layer boundary invariants:**

- Layer A never decides load-bearing actions. It executes what Layer B prescribes (gated by safety tiers) and reports results.
- Layer B never touches the host filesystem or primitives directly. It reasons, authors, prescribes — never applies.
- Layer C is untouched by blacklight source code. No new rule engines, no new manifests, no new wire formats — only native usage of existing primitives.

### 3.4 Primitives map (Path C — M13 Skills realignment)

M13 realigned the Layer B surface from the pre-Path-C layout (two memory stores: `bl-skills`
read_only + `bl-case` read_write) to the full four-primitive Managed Agents surface.

| Primitive | Instance | blacklight role | Path key in `state.json` |
|-----------|----------|-----------------|--------------------------|
| **Skills** | 6 routing Skills | Description-routed lazy-loaded operator-voice behavior (synthesizing-evidence, prescribing-defensive-payloads, curating-cases, gating-false-positives, extracting-iocs, authoring-incident-briefs) | `agent.skill_versions.<slug>` |
| **Files** (workspace) | 8 corpus files | Skill corpora (foundations + 6 routing-skill corpora + substrate-context); mounted at session create | `files.<slug>.file_id` |
| **Files** (per-case) | Evidence bundles + briefs | Raw observation JSONL + closed-case briefs; hot-attached mid-session; GC'd after close | `case_files.<case-id>.<path>.workspace_file_id` |
| **Memory Store** | `bl-case` (read_write) | Curator working memory: hypothesis + steps + actions + open-questions | `case_memstores._legacy` |
| **Sessions** | Per-case curator session | Opus 4.7, 1M context; case-scoped reasoning; resumable across 30-day checkpoint window | `session_ids.<case-id>` |

`bl-skills` memory store is **retired** in Path C. See §7.1 for the retirement note.

Full primitives reference: `docs/managed-agents.md`.

---

## 4. Runtime flow — the agent-directed REPL

blacklight investigations are operator-agent conversations, not batch dossier analyses. The canonical flow:

```
operator                  bl (Layer A)              Managed Agent (Layer B)
────────                  ────────────              ─────────────────────
$ bl consult \
  --new --trigger <hit>   ┐
                           │  preflight workspace
                           │  create case record
                           │  POST session event
                                                    session.wake
                                                    invoke routing Skills
                                                    read bl-case/hypothesis
                                                    reason, emit 4 steps to
                                                    bl-case/pending/s-01..04

                           poll bl-case/pending
                           show proposed steps:
                              s-01 observe log apache --around … --window 6h
                              s-02 observe fs --mtime-cluster …
                              s-03 observe htaccess …
                              s-04 observe cron --user …

Accept? [Y/n]  Y         ┐
                           │  exec each step locally
                           │  write result to
                           │  bl-case/results/s-01..04.json
                           │  POST wake event

                                                    read results
                                                    revise hypothesis
                                                    emit next batch:
                                                      s-05..07 observe
                                                      s-08 defend firewall
                                                      s-09 defend modsec
                                                      s-10 clean cron
                                                      s-11 clean htaccess

                           auto-exec read-only
                           auto-exec auto-tier
                           stop on destructive;
                           show diff; require
                           --yes per step
Confirm cron removal? y
                           exec, write result
                           …
                                                    propose close_case
                                                    when open_questions = 0

$ bl case close           ┐
                           │  archive brief to Files
                           │  precedent pointer in bl-case
                           │  retire firewall blocks @ T+30d
```

**Key mechanical choice: async step-emit over polled memory-store files, not synchronous SSE tool-result.** The agent writes proposed step JSON to `bl-case/pending/<id>.json`; the wrapper consumes pending steps via two modes: (a) a continuous poll loop (`bl_poll_pending`, in `src/bl.d/20-api.sh`) used by `bl consult` foreground REPL — `GET /v1/memory_stores/<id>/memories?key_prefix=bl-case/<case>/pending/` every 3s, dedup-against-seen-set, exit on `end_turn` or `--timeout`; and (b) on-demand single-fetch via `bl run --list` (`bl_run_list`, in `src/bl.d/60-run.sh`) used by batched/async operator workflows. Both paths execute, write to `bl-case/results/<id>.json`, and send wake events. This avoids SSE bidirectional plumbing in bash, makes the case memory a self-documenting audit log, and keeps `bl` a short-lived command per invocation. Polling overhead (~3-9s per loop tick) is invisible against agent reasoning time.

---

## 5. Command namespace — full reference

Six runtime namespaces + one setup command. All bash functions in a single `bl` script, dispatched by first argument.

### 5.1 `bl observe` — read-only evidence extraction

Auto-runs (no confirm). Emits JSONL to stdout and appends structured output to the current case.

```
bl observe file <path>
    Stat, magic bytes, first 512 bytes, sha256, strings (printable ≥ 6),
    file(1) classification. Output: bl-case/evidence/obs-<ts>-file.json

bl observe log apache --around <path> [--window 6h] [--site <fqdn>]
    Locate vhost log for <path>, time-window filter to ±window around
    <path>'s mtime, parse to JSONL (pre-parsed Apache combined),
    compute: top 20 IPs by count, top 20 paths by 200s, POST-to-PHP
    requests, status histogram.

bl observe log modsec [--txn <id>] [--rule <id>] [--around <path> --window 6h]
    Parse ModSec audit log (A/B/F/H sections). Output JSONL with
    txn_id, client, uri, rule_id, action, phase, timestamp.

bl observe log journal --since <time> [--grep <pattern>]
    journalctl --since + optional filter. JSONL output.

bl observe cron --user <user> [--system]
    `crontab -u <user> -l | cat -v` (cat -v reveals ANSI ESC[2J
    obscuration). `--system` includes /etc/cron.d/, /etc/crontab,
    /etc/cron.{hourly,daily,weekly,monthly}/.

bl observe proc --user <user> [--verify-argv]
    ps -u <user>, then for each pid compare argv[0] (from ps) against
    /proc/<pid>/exe basename. Mismatch = argv-spoofing signal
    (gsocket class).

bl observe htaccess <dir> [--recursive]
    Walk .htaccess tree, flag injected directives: <FilesMatch> with
    <?php>-enabling blocks, AddHandler for suspicious extensions,
    DirectoryIndex overrides pointing to webshell names.

bl observe fs --mtime-cluster <path> --window <N>s [--ext <extlist>]
    Find files in <path> within N-second mtime cluster. Group by
    mtime bucket. Report cluster size, time span, file list.

bl observe fs --mtime-since <date> [--under <path>] [--ext <extlist>]
    All files modified since date; retrospective sweep (e.g. "since
    CVE disclosure").

bl observe firewall [--backend auto]
    Detect active backend (APF/CSF/iptables/nftables), list current
    deny rules, case-tag rules if present (blacklight writes case
    IDs into comment/reason fields on add).

bl observe sigs [--scanner lmd|clamav|yara]
    List currently-loaded signatures per scanner (hit counts from
    last-N-days via maldet hit.hist or clamscan --verbose).
```

### 5.2 `bl consult` — session attach / case management

```
bl consult --new --trigger <path-or-event>
    Create a new case. POST session wake event with trigger
    fingerprint. Return case-id. Attach any evidence bundles
    previously uploaded via `bl signal`.

bl consult --attach <case-id>
    Attach subsequent observations to an existing open case.
    Subsequent `bl observe` writes are tagged with this case-id.

bl consult --sweep-mode --cve <id>
    Retrospective posture case (not a live incident). Reads the
    `posture/*.md` skill subtree. Produces a fleet-vulnerability
    readout without opening a formal case.
```

### 5.3 `bl run` — execute agent-prescribed step

```
bl run <step-id> [--yes] [--dry-run]
    Read bl-case/pending/<step-id>.json, display the proposed
    action, require confirmation (unless tier=auto or --yes),
    execute, write bl-case/results/<step-id>.json, POST wake.

bl run --batch s-01..s-07 [--yes-auto-tier]
    Execute a contiguous batch of agent-prescribed steps. Auto-tier
    and read-only steps run without per-step confirm; destructive
    steps still require per-step confirm unless --yes is passed
    globally.

bl run --list
    Show all pending steps for the current case with their action
    tier and a one-line synopsis.
```

### 5.4 `bl defend` — apply agent-authored payload

```
bl defend modsec <rule-file-or-id>
    If <rule-file>: copy to /etc/httpd/conf.d/bl-rules-v<N>.conf,
      run `apachectl configtest`, on pass symlink-swap + apachectl
      graceful, on fail rollback to previous symlink target.
    If <rule-id>: remove by ID (requires --remove flag; destructive
      tier; confirms).

bl defend firewall <ip> [--backend auto] [--case <id>] [--reason <str>]
    Auto-detect backend, CDN-safe-list check (internal allowlist +
    ASN lookup via public WHOIS cache), apply, write ledger entry
    to bl-case/actions/applied/ with retire-hint.

bl defend sig <sig-file> [--scanner lmd|clamav|yara|all]
    Corpus-FP gate first (run sig against benign corpus at
    /var/lib/bl/fp-corpus/); if 0 FP, append to scanner sig file
    and reload. Auto-tier iff FP gate passes.
```

### 5.5 `bl clean` — remediation (destructive, diff-confirmed)

```
bl clean htaccess <dir> [--patch <id>]
    Read agent-authored removal patch from bl-case/pending/clean-<id>.
    Show diff against current .htaccess. On --yes or confirm,
    backup to /var/lib/bl/backups/ and apply.

bl clean cron --user <user> [--patch <id>]
    Same pattern: agent authors the exact entries to strip (including
    any ANSI-obscured lines), wrapper shows diff, confirms, writes
    backup, installs new crontab.

bl clean proc <pid> [--capture]
    If --capture: snapshot /proc/<pid>/{cmdline,environ,exe,cwd,
    maps,status} + lsof to bl-case/evidence/ before SIGTERM then
    SIGKILL. Default: just kill with snapshot.

bl clean file <path> [--reason <str>]
    Move to /var/lib/bl/quarantine/<case-id>/<sha256>-<basename>
    with manifest entry (original path, size, sha256, owner,
    perms, mtime, case-id, reason). Restore path:
    `bl case show --quarantine` + operator-executed restore.
```

### 5.6 `bl case` — case lifecycle

```
bl case show [<case-id>]
    Print current hypothesis, evidence list, pending steps,
    applied actions, defense-hit log, open questions.

bl case log [<case-id>]
    Full chronological ledger: every observation, every step
    prescribed, every action applied, every diff confirmed.

bl case list [--open|--closed|--all]
    Enumerate cases in this workspace.

bl case close [<case-id>]
    Agent validates open-questions are resolved, renders brief
    to Files API as permanent PDF + HTML + MD, writes precedent
    pointer to bl-case (marked closed), schedules T+5d silent
    verify sweep + T+30d firewall-block retire-sweep.

bl case reopen <case-id> [--reason <str>]
    Re-attach the closed case to the curator session. New evidence
    can arrive via `bl consult --attach`.
```

### 5.7 `bl setup` — workspace bootstrap

```
bl setup
    Idempotently provision the Anthropic workspace: create agent,
    environment, memory stores, seed skills. See §8.

bl setup --sync
    Diff local skills against remote memory-store manifest; push
    only changed files. Safe to re-run.

bl setup --check
    Dry-run preflight only. Report what would be created/updated.
```

### 5.8 Dispatcher entry

Every runtime invocation starts with preflight:

```bash
bl() {
    bl_preflight || return $?              # §8.1 — propagate preflight's actual exit code
    case "$1" in
        observe)  shift; bl_observe "$@"  ;;
        consult)  shift; bl_consult "$@"  ;;
        run)      shift; bl_run "$@"      ;;
        defend)   shift; bl_defend "$@"   ;;
        clean)    shift; bl_clean "$@"    ;;
        case)     shift; bl_case "$@"     ;;
        setup)    shift; bl_setup "$@"    ;;
        help|-h|--help) bl_help "$@"      ;;
        *) echo "unknown: $1" >&2; return 64 ;;
    esac
}
```

---

## 6. Action tiers + safety gates

Every action blacklight takes is classified into one of five tiers. The tier determines gate behavior.

| Tier | Examples | Gate behavior |
|---|---|---|
| **Read-only** | `observe *`, `consult *`, `case show/log/list` | Auto-execute; no confirm; no audit write beyond standard case ledger |
| **Reversible, low-risk** | `defend firewall <ip>` (new block), `defend sig` (after corpus-FP-pass) | Auto-execute + Slack/stdout notification + 15-minute operator veto window (via `bl defend firewall --remove <ip>`); ledger entry created |
| **Reversible, high-impact** | `defend modsec` (new rule) | Suggest → operator reviews diff → explicit `bl run --yes` to apply; `apachectl configtest` pre-flight mandatory |
| **Destructive** | `clean htaccess`, `clean cron`, `clean proc`, `clean file`, `defend modsec --remove` | Diff shown (for file edits) or capture-then-kill (for proc); explicit `--yes` per-operation required; no batch auto-confirm; backup written before apply |
| **Unknown** | Any bash command the agent proposes that does not map to a known verb | Deny by default; operator must invoke `bl run <step-id> --unsafe --yes` explicitly; discouraged |

**Tier is authored by the agent**, written into `bl-case/pending/<step-id>.json` as `action_tier: auto|suggested|destructive`. The wrapper enforces the gate based on this field plus the verb class, not trust from the agent alone.

---

## 7. State model — memory stores + files

Two memory stores. Files for blobs. No local state store on the host beyond `/var/lib/bl/`.

### 7.1 `bl-skills` memory store — RETIRED (Path C, M13)

**Status: RETIRED.** The `bl-skills` memory store was removed in M13 (Skills primitive
realignment). Skill content now lives in Anthropic Skills primitives (description-routed,
lazy-loaded) instead of a flat read_only memory store. See §3.4 for the Path C primitives
map and `docs/managed-agents.md §4` for the Skills primitive reference.

Pre-Path-C contract (preserved for history):
- Access: `read_only` from the agent's perspective (mounted at session creation)
- Written only by `bl setup` via the external Memories API
- Contents: ~22 operator-voice markdown files (see §9)
- Size target: ≤ 50 KB total
- Kernel-enforced read-only: attacker-supplied log content cannot rewrite operator knowledge mid-investigation

### 7.2 `bl-case` memory store

- Access: `read_write` from the agent's perspective
- See also: `docs/case-layout.md` — writer-owner contract (who writes which path when), size budget, lifecycle transitions, `STEP_COUNTER` addendum
- Structure:

```
bl-case/
├── INDEX.md                          # workspace case roster + pointers to closed briefs
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
│   ├── pending/                      # agent-emitted proposed steps
│   │   └── s-<id>.json
│   ├── results/                      # wrapper-written step results
│   │   └── s-<id>.json
│   ├── actions/
│   │   ├── pending/<act-id>.json     # awaiting operator approval
│   │   ├── applied/<act-id>.json     # applied; carries retire-hint
│   │   └── retired/<act-id>.json     # closed; no longer active
│   ├── defense-hits.md               # running log of blocks that fired
│   └── closed.md                     # present iff case closed: brief file_ids + retirement schedule
```

- Size cap: 100 KB per file per Managed Agents spec; 8 memory stores per session cap (we use 2 of 8)
- `memver_` immutable audit trail (30-day retention) — operator sees every revision, regulator sees the reasoning chain

### 7.3 Files (Anthropic Files API)

- Raw evidence bundles (`.tgz` of JSONL + summary.md + MANIFEST.json)
- Shell samples / binary captures for intent reconstruction
- Closed-case briefs (PDF + HTML + MD rendered by `bl case close`)
- Mount via `resources[]` at session creation or `sessions.resources.add` during runtime (files hot-swap; memory stores do not)
- Persistence: indefinite (no TTL; deleted only by explicit API call)
- Pricing: ops free; content billed only when referenced in a message

### 7.4 Local state (`/var/lib/bl/`)

- `/var/lib/bl/backups/` — pre-edit backups (crontab, .htaccess, modsec conf symlinks)
- `/var/lib/bl/quarantine/` — quarantined files, keyed by case-id
- `/var/lib/bl/fp-corpus/` — benign-file corpus for YARA FP-gating
- `/var/lib/bl/state/case.current` — active case pointer for the current shell session
- No long-term state. `/var/lib/bl/` is wipeable without data loss; authoritative state lives in the workspace.

---

## 8. `bl setup` — workspace bootstrap

### 8.1 Preflight (on every invocation)

```bash
bl_preflight() {
    : "${ANTHROPIC_API_KEY:?blacklight: ANTHROPIC_API_KEY not set}"

    # One GET; ~200 ms; cached in /var/lib/bl/state/agent-id for subsequent runs
    if [[ -f /var/lib/bl/state/agent-id ]]; then
        BL_AGENT_ID=$(< /var/lib/bl/state/agent-id)
        return 0
    fi

    local resp
    resp=$(curl -sf \
        -H "x-api-key: $ANTHROPIC_API_KEY" \
        -H "anthropic-beta: managed-agents-2026-04-01" \
        "https://api.anthropic.com/v1/agents?name=bl-curator")

    BL_AGENT_ID=$(printf '%s\n' "$resp" | jq -r '.data[0].id // empty')

    if [[ -z "$BL_AGENT_ID" ]]; then
        cat >&2 <<EOF
blacklight: this Anthropic workspace has not been seeded.

Run one of the following (one-time per workspace):

  # Local clone:
  bl setup

  # Direct from OSS repo:
  curl -fsSL https://raw.githubusercontent.com/rfxn/blacklight/main/bl | bash -s setup

After setup completes the first host's worth of provisioning,
every subsequent host running 'bl' against the same API key
finds the workspace pre-seeded and skips this step.
EOF
        return 66
    fi

    mkdir -p /var/lib/bl/state && printf '%s' "$BL_AGENT_ID" > /var/lib/bl/state/agent-id
}
```

### 8.2 Setup operations (one-time per workspace)

`bl setup` performs these operations idempotently. Each step checks for existing state before creating.

1. **Create agent** `bl-curator` via `POST /v1/agents`. Full shape in §12.1. Summary: model `claude-opus-4-7`, system prompt from `prompts/curator-agent.md`, tools array = `agent_toolset_20260401` plus three custom tools (`report_step`, `synthesize_defense`, `reconstruct_intent`) with input_schemas loaded from `schemas/*.json` (top-level `$schema`/`$id`/`title` stripped). No `output_config` and no `thinking` fields — both rejected by the managed-agents-2026-04-01 create endpoint (HTTP 400, verified 2026-04-24); neither applies to the Managed Agents surface.
2. **Create environment** `bl-curator-env`:
   - `type: cloud`
   - `packages.apt: [apache2, libapache2-mod-security2, modsecurity-crs, yara, jq, zstd, duckdb]`
   - `networking: {type: unrestricted}` (required for apt at env creation; sessions can use `limited` thereafter)
3. **Create memory store** `bl-case` (`access: read_write` to agent). Note: `bl-skills`
   memory store is retired in Path C (M13) — skill content lives in Anthropic Skills
   primitives. See §3.4 and §7.1.
4. **Upload routing Skills** (6): synthesizing-evidence, prescribing-defensive-payloads,
   curating-cases, gating-false-positives, extracting-iocs, authoring-incident-briefs.
   SHA-256 delta check: skip if already uploaded at the current version. See `routing-skills/`.
5. **Upload corpus Files** (8): foundations + 6 routing-skill corpora + substrate-context.
   SHA-256 delta check: skip if content unchanged. Replaces old file_id on change;
   queues old ID for `bl setup --gc`. See `skills-corpus/`.
6. **Persist state** to `$BL_STATE_DIR/state.json` (schema: `docs/state-schema.md`).
7. **Print operator exports**:
   ```
   export ANTHROPIC_API_KEY="<unchanged — use your current key>"
   export BL_READY=1
   ```

### 8.3 Source-of-truth resolution

`bl setup` discovers skill content in this order:

1. Current working directory has `routing-skills/`, `skills-corpus/`, and `prompts/` — use those
2. `$BL_REPO_URL` set — shallow clone to `$XDG_CACHE_HOME/blacklight/repo`, use
3. Default → `git clone https://github.com/rfxn/blacklight $XDG_CACHE_HOME/blacklight/repo`, use

This covers three adoption paths: operator-from-clone, operator-from-fork, operator-from-quickstart.

### 8.4 `bl setup --sync`

Delta-push routing Skills and corpus Files: compute SHA-256 per file, compare against
`state.json .skills` and `.files` maps, upload only changed files. Replaces old file_ids
on content change; old IDs are queued in `files_pending_deletion[]` for `bl setup --gc`.
Safe to re-run daily.

### 8.5 Idempotency contract

All setup operations must be safely re-executable. If agent exists → skip create. If memory-store exists → skip create. If skill content unchanged → skip push. Operator running `bl setup` on host 5 after already running it on host 1 produces a no-op with a friendly summary.

---

## 9. Skills architecture

### 9.1 Structure (~22 files)

```
skills/
├── INDEX.md                                       (router)
├── ir-playbook/
│   ├── case-lifecycle.md
│   └── kill-chain-reconstruction.md
├── webshell-families/
│   └── polyshell.md
├── defense-synthesis/
│   ├── modsec-patterns.md
│   ├── firewall-rules.md                          [v2 add]
│   └── sig-injection.md                           [v2 add]
├── false-positives/
│   ├── backup-artifact-patterns.md
│   └── vendor-tree-allowlist.md
├── hosting-stack/
│   ├── cpanel-anatomy.md
│   └── cloudlinux-cagefs-quirks.md
├── ic-brief-format/
│   ├── severity-vocab.md
│   └── template.md
├── linux-forensics/
│   ├── persistence.md                             (gsocket, argv-spoof, ANSI-cron patterns)
│   └── net-patterns.md
├── magento-attacks/
│   ├── admin-paths.md
│   └── writable-paths.md
├── modsec-grammar/
│   ├── rules-101.md
│   └── transformation-cookbook.md
├── apf-grammar/
│   ├── basics.md
│   └── deny-patterns.md
├── apsb25-94/
│   ├── exploit-chain.md
│   └── indicators.md
└── ioc-aggregation/                               [v2 add — operator-voice]
    ├── ip-clustering.md
    ├── url-pattern-extraction.md
    └── file-pattern-extraction.md
```

### 9.2 Authoring discipline

Each skill:
1. Opens with a scenario from lived experience (the incident, the shift boundary, the customer call) — not a definition
2. States a non-obvious rule — something a competent analyst who has *not* worked at this scale would get wrong
3. Gives a concrete example drawn from public APSB25-94 material (never operator-local)
4. Names a failure mode and how the rule handles it
5. Assumes operator literacy; does not explain generic concepts

**If the only available draft would be generic IR/SOC boilerplate, flag the gap and land the file later — never ship slop.**

### 9.3 Third-party extensibility

A defender running DirectAdmin, Virtualmin, Plesk drops their own `skills/<platform>/*.md` subtree into their memory store via `bl setup --sync`. The curator reads it on next session wake. New vocabulary available; zero wrapper code change; zero agent retraining.

This is the "skills over agents" pattern. Managed Agents' memory-store-as-skill-loader IS the skills runtime.

---

## 10. Evidence format contract

### 10.1 JSONL on the wire

Every `bl observe` output is JSONL, one record per line. Fields vary by source but share a common preamble:

```json
{"ts": "2026-04-24T04:17:08Z", "host": "example-host", "source": "apache.transfer", "record": { /* source-specific fields */ }}
```

Apache transfer record fields: `client_ip`, `method`, `path`, `status`, `bytes`, `ua`, `referer`, `site`, plus derived: `path_class`, `is_post_to_php`, `status_bucket`.

### 10.2 Bundle shape

Evidence bundles (for `consult --upload`) are `tar + gzip -5` with this layout:

```
bundle-<host>-<window>.tgz
├── MANIFEST.json           (host, window, sources, sha256s, bl version)
├── summary.md              (1–2 KB first-read — top IOCs, counts, hot paths)
├── transfer.log.jsonl      (pre-parsed Apache/nginx access records)
├── modsec_audit.jsonl      (pre-parsed ModSec audit events)
├── fs_anomalies.jsonl      (mtime clusters, perm drift, suid changes)
└── system_messages.jsonl   (journalctl extracts)
```

### 10.3 The summary.md convention

The first file the agent reads. ≤ 2 KB. Structured:

```
# Evidence bundle — <host> — <from> → <to>

## Trigger
<one-paragraph description of the artifact that prompted collection>

## Top-line findings
- <bullet list of ≤ 7 facts>

## Jump points
- <jq/grep expressions the agent can use to drill into the JSONL files>

## Attention-worthy
- <anomalies the pre-parse flagged>
```

Raw logs never enter agent context directly. The agent reads `summary.md` first, drills into JSONL via `grep`/`jq`/`duckdb` tool-use on demand.

### 10.4 Compression

- Default: `gzip -5` — portable to CentOS 6 / bash 4.1 baseline without EPEL
- Upgrade path: `zstd -3` if `command -v zstd` succeeds — ~1.3× smaller, faster compress
- Detection: `bl collect` picks best available codec; extension is `.tgz` regardless (tar magic-byte detects codec on the decompress side)

---

## 11. Remediation safety model

Remediation — the `bl clean` namespace — is the highest-leverage and highest-risk surface. Five mechanical disciplines apply.

### 11.1 Diff shown before apply

For file edits (`clean htaccess`, `clean cron`):
```
bl-clean 2026-04-24T04:27:15Z — CASE-2026-0017 step s-10
Target: /home/sitefoo/.../.htaccess

Diff (proposed):
   -  <FilesMatch "\.php$">
   -      Require all denied
   -  </FilesMatch>
   +  # (line removed — injected block, per agent analysis)

Backup will be written to: /var/lib/bl/backups/2026-04-24T04-27-15Z.htaccess
Apply? [y/N/diff-full/explain/abort]
```

`diff-full` shows the whole before/after file. `explain` requests the agent's reasoning field from the pending-step JSON. `abort` cancels and marks the step as operator-rejected.

### 11.2 Backup before apply

Every `bl clean` operation writes a pre-apply backup to `/var/lib/bl/backups/<ISO-ts>.<hash>.<basename>`. The manifest tracks backups; `bl case log` lists them; `bl clean --undo <backup-id>` restores.

### 11.3 `--dry-run` contract

Every `bl clean` subcommand supports `--dry-run`. Dry-run shows the full diff and backup path but takes no action and writes nothing. Dry-run success is required before a non-dry-run is attempted — the wrapper enforces this.

### 11.4 Quarantine, not delete

`bl clean file` never unlinks. Files move to `/var/lib/bl/quarantine/<case-id>/<sha256>-<basename>` with a manifest entry. `bl case show --quarantine` lists them; `bl clean --unquarantine <entry>` restores. Operator-rescue is one command away.

### 11.5 Capture before kill

`bl clean proc <pid>` captures `/proc/<pid>/{cmdline,environ,exe,cwd,status,maps}` and `lsof -p <pid>` to the case evidence before sending signal. `--capture=off` disables (operator must pass explicitly). Default is capture-on because the forensic value of a running process's /proc snapshot is often higher than whatever latency the capture adds.

### 11.6 Brief rendering — MD canonical, HTML/PDF best-effort

`bl case close` always writes the case brief to the Files API as `text/markdown`
(the `fid_md` returned to `bl-case/<case-id>/closed.md` is the canonical artifact).
HTML and PDF renders are produced by the curator's environment-side `pandoc` +
`weasyprint` toolchain (apt-installed at env creation per §8.2) when the curator
is running and reachable. If the env is unreachable or the render times out
(60s), `bl case close` degrades gracefully — `closed.md` records empty
`brief_file_id_html` / `brief_file_id_pdf` and the operator can re-run
`bl case close --re-render` later. Operators who need deterministic local-only
rendering pass `BL_BRIEF_MIMES=text/markdown` to skip the stage-2 delegate.

---

## 12. Model calls

**One model, one agent, three tool-channelled reasoning modes.** v2 runs a single `bl-curator` agent record — Opus 4.7, 1M context — with three custom tools that specialise its emit surface: `report_step` (wrapper actions), `synthesize_defense` (rule/firewall/sig authoring), `reconstruct_intent` (shell-sample analysis). "Synthesizer" and "Intent reconstructor" are NOT separate agents or separate model calls in v2; they are structured-emit modes of the same curator session. This collapse is deliberate — PIVOT-v2.md §4.2 explicitly cuts multi-session hunter dispatch in favor of a single 1M-context curator.

**Agent-create constraint (verified 2026-04-24 against `managed-agents-2026-04-01`):** `POST /v1/agents` rejects `thinking` and `output_config` as extra inputs (HTTP 400 `invalid_request_error`). The only create-time shape-controls on Managed Agents today are `name`, `model`, `system`, `tools`, `mcp_servers`, `skills`, `callable_agents`, `description`, `metadata`. Thinking is model-internal and not operator-configurable; structured output ships through custom tools.

**Custom-tool `input_schema` subset (verified same probe):** `additionalProperties` and per-field `description` keywords are rejected inside `input_schema`. Accepted keywords for the blacklight schemas: `type`, `properties`, `required`, `enum`, `items`, type-array unions like `["string", "null"]`. The wire-format files in `schemas/*.json` are minimal-subset; per-field documentation lives in companion `schemas/*.md` files. `bl setup` strips top-level metadata (`$schema`, `$id`, `title`) before submit.

### 12.1 Curator — agent-create shape

- Model: `claude-opus-4-7`
- Context: 1M
- System prompt: `prompts/curator-agent.md` (curator voice + IR playbook anchors + untrusted-content fence taxonomy from §13.2)
- Tools: `agent_toolset_20260401` built-in bundle + three custom tools:
  ```json
  [
    {"type": "agent_toolset_20260401"},
    {"type": "custom", "name": "report_step",         "description": "<§12.1.1>", "input_schema": "<schemas/step.json stripped of $schema/$id/title>"},
    {"type": "custom", "name": "synthesize_defense",  "description": "<§12.2>",   "input_schema": "<schemas/defense.json>"},
    {"type": "custom", "name": "reconstruct_intent",  "description": "<§12.3>",   "input_schema": "<schemas/intent.json>"}
  ]
  ```
- Resources at session creation: `bl-case` memory store (read-write) + routing Skills (6, lazy-loaded) + corpus Files (8, read-only mounts) + per-case evidence Files (hot-attached via `sessions.resources.add`). See §3.4 for the full primitives map.
- Lifetime: one session per case; resumable across 30-day checkpoint window; files hot-swap via `/v1/sessions/:sid/resources`.
- Reasoning behavior: Opus 4.7 reasoning is model-internal. The platform SSE stream surfaces reasoning content at runtime via dedicated event types; blacklight does not configure or control reasoning depth — it is not an operator-settable parameter on the Managed Agents surface.

`schemas/defense.json` and `schemas/intent.json` are stubs as of this commit (authored alongside `report_step`'s wire form when §12.2 / §12.3 land in the build stream).

### 12.1.1 `report_step` custom tool (step-emit surface)

The curator emits each proposed wrapper action as one `agent.custom_tool_use` event invoking `report_step`. Tool shape:

```
name:        report_step
description: Emit a proposed blacklight wrapper action. One call per step.
             The wrapper validates the input against schemas/step.json,
             persists it to bl-case/<case-id>/pending/<step_id>.json, then
             replies with user.custom_tool_result containing
             {status: queued|rejected, step_id, reason?}. Do not batch multiple
             actions into one call — every step needs its own invocation so
             operator gates can apply per-step. Do not repeat step_id values
             within a case; the wrapper's allocator hands them out via
             bl-case/<case-id>/STEP_COUNTER — request a fresh id before emit.
input_schema: contents of schemas/step.json (wire form, post-strip)
```

Flow:

1. Curator invokes `report_step` with the step envelope as `input`.
2. Platform validates `input` against `input_schema`, emits `agent.custom_tool_use` with `custom_tool_use_id`; session status → `idle` + `stop_reason: requires_action`.
3. Wrapper consumes the event stream (or polls `bl-case/<case-id>/pending/` for the filesystem-materialised copy). For each emit:
   - Re-validate against `schemas/step.json` as defense-in-depth — the platform subset cannot enforce `additionalProperties: false`, so the wrapper jq-checks unknown keys and verb-specific arg-key conformance (see `schemas/step.md`).
   - On pass: write `bl-case/<case-id>/pending/<step_id>.json`; reply with `user.custom_tool_result` carrying `{status: "queued", step_id}`.
   - On fail: reply with `{status: "rejected", step_id, reason: "<validation error>"}` so the curator revises and re-emits. No partial writes, no silent drops.
4. Session returns to `running`. Curator may emit additional `report_step` calls or move to `end_turn`.
5. Operator runs `bl run <step_id>` (or `bl run --batch`); wrapper executes under the gate defined by `action_tier`; result lands in `bl-case/<case-id>/results/<step_id>.json`; `bl` sends a `user.message` wake event referencing the new result records.

Why a custom tool instead of free-form JSON in a message:

- **Platform-side structural enforcement.** The Managed Agents runtime validates `input` against `input_schema` before emit. The wrapper does not have to parse and discard malformed JSON from natural-language output.
- **Permission policy slot.** Custom tools carry an optional `permission_policy` for platform-level confirmation gating (unused in v2; reserved for P2 posture arc).
- **Event-stream correlation.** Every step carries a platform-allocated `custom_tool_use_id` the wrapper cites in its result reply. The audit trail is a platform primitive, not something the wrapper synthesises from filenames.
- **Managed-Agents-native.** `output_config.format` structured-output lives on `messages.create` (non-Managed-Agents surface). Inside a Managed Agents session, structured emit means tools.

`schemas/step.json` is the single wire-format source of truth: platform-side `input_schema` value and wrapper-side pre-write validation (plus defense-in-depth checks documented in `schemas/step.md`).

### 12.2 `synthesize_defense` custom tool (defense-authoring surface)

The curator invokes `synthesize_defense` when a case has enough correlated evidence to justify authoring a defensive payload (ModSec rule body, firewall entry set, scanner signature). One invocation per defense proposal; the wrapper reads the payload, writes it under `bl-case/<case-id>/actions/pending/<act-id>.json`, runs the FP-gate (`apachectl configtest` for ModSec, benign-corpus scan for signatures, CDN safe-list for firewall), and replies with the gate result. Tool shape:

```
name:         synthesize_defense
description:  Propose a defensive payload for this case. Payload kind is one
              of modsec (rule text), firewall (IP+backend+optional ASN-safelist
              check), sig (LMD/ClamAV/YARA body). The wrapper runs the
              kind-specific FP-gate inside the curator's sandbox before
              promoting to bl-case/<case-id>/actions/pending/. Reply with
              gate_status={pass, fail, deferred} and the action-id to the
              curator; on fail, reason carries the exact gate output.
input_schema: schemas/defense.json
```

Reasoning during synthesis is model-internal. The curator's sandbox runs `apachectl -t` on synthesized ModSec rules and FP-scans sigs against `/var/lib/bl/fp-corpus/` before the action is promoted — the validation is sandbox-side, not operator-side. (Schema stub; authored in the §12.2 build stream.)

### 12.3 `reconstruct_intent` custom tool (sample-analysis surface)

The curator invokes `reconstruct_intent` when it wants a focused pass on a specific shell sample mounted via `sessions.resources.add` — polyglot, binary, obfuscated PHP. The tool input names the mounted file_id and the analysis depth (`shallow` / `deep`); the wrapper receives the tool call, reads the attribution artifact the curator wrote to `bl-case/<case>/attribution.md`, and replies with `{status: queued, attribution_id}`. Tool shape:

```
name:         reconstruct_intent
description:  Walk the obfuscation layers of a mounted shell sample and
              separate observed capability from dormant capability. Writes
              a structured attribution artifact to
              bl-case/<case>/attribution.md keyed by sample file_id.
              Depth=shallow for routine polyglot (chr-ladder + base64 +
              gzinflate shapes); depth=deep for novel obfuscation.
input_schema: schemas/intent.json
```

The curator is responsible for attaching the sample via `sessions.resources.add` before invoking the tool. Intent reconstruction runs inside the curator's own reasoning — no separate session, no separate model call. (Schema stub; authored in the §12.3 build stream.)

### 12.4 When Sonnet 4.6 is used (rare in v2)

Hunter parallelism is not load-bearing in v2 — the 1M-context curator does single-session correlation directly. If a future case has a correlation scope exceeding the curator's turn budget (thousands of records), the P3 roadmap spawns Sonnet 4.6 hunters via direct `messages.create` calls OUTSIDE the Managed Agents surface (no session, no memory stores). `messages.create` is where `output_config.format` and forced `tool_choice` live — they apply to that call, not to the curator's agent-create shape. v2 does not exercise this path by default.

### 12.5 Model calls addendum — Path C (M13)

M13 introduced two additional model call contexts that emit to the Files API rather than
the memstore:

| Call | Model | Trigger | Output destination |
|------|-------|---------|-------------------|
| Bundle summary render | Sonnet 4.6 (`bl_messages_call`) | `bl observe` evidence rotate | Summary written to Files API as `/case/<id>/summary/<source>.md`; file_id recorded in `state.json case_files` |
| FP-gate adjudication | Haiku 4.5 (`bl_messages_call`) | `bl defend sig` before rule promotion | Pass/fail verdict; no Files API write — verdict embedded in action JSON |

Both calls use the Messages API (`POST /v1/messages`) — not the Managed Agents surface.
`output_config.format` and `tool_choice` constraints documented in §12.4 apply here.
`BL_DISABLE_LLM=1` bypasses both calls for testing and cost-control (tests export this
before each session).

---

## 13. Security model

blacklight operates with root-equivalent privilege on target hosts (modifying ModSec config, firewall state, crontab, webroot files). The security boundaries:

### 13.1 Auth surface

- Sole secret: `$ANTHROPIC_API_KEY` (operator-provisioned; never in repo)
- No service account; no long-lived tokens; no cert management
- API key scope = workspace scope = blast radius; operators should provision dedicated workspaces for production use

### 13.2 Prompt-injection hardening

- Routing Skills are version-pinned at session creation and cannot be modified by an active curator session — attacker-supplied log content cannot rewrite operator knowledge (Skills API does not expose a write path to the agent)
- Every evidence record is wrapped in an untrusted-content fence when passed to the curator; the curator's system prompt includes an explicit taxonomy of injection attempts (role reassignment, schema override, verdict flip) and routes those strings to evidence fields, never acts on them
- Session-unique fence tokens derived from the case-id + payload sha256 (64-bit entropy; attacker cannot forge a matching end-token without changing the payload hash)
- Pattern carried over from hardening done in prior commit (`9d56214`)

### 13.3 Agent output validation

- `bl run` validates the step-JSON schema (`jq` schema-check) before executing
- Unknown verbs fall into the "unknown" tier → deny by default
- The agent cannot emit arbitrary bash; it emits step records that map to named verbs with typed arguments
- Destructive steps fail validation if missing a `diff` or `patch` field

### 13.4 Operator ledger

- Every applied action is written to `bl-case/actions/applied/` in the memory store (remote, 30-day versioned) AND to `/var/lib/bl/ledger/<case-id>.jsonl` (local, append-only)
- Dual write protects against both "agent memory corrupted" and "host wiped" scenarios
- `bl case log --audit` prints the ledger in a regulator-friendly format

### 13.5 Rate limiting

- Files API rate limit ~100 RPM during beta — `bl signal` throttles uploads to ≤ 50 RPM and queues bursts locally in `/var/lib/bl/outbox/`
- Messages API rate limits are per-workspace; blacklight does not parallelize aggressively by default

---

## 14. Dependencies

### 14.1 Tier 1 — always present

Host runtime floor (CentOS 6+, Debian 8+, Ubuntu 16.04+, RHEL 7+, Rocky 8+):

- `bash` ≥ 4.1
- `coreutils` (`ls`, `cat`, `stat`, `find`, `sort`, `uniq`, `head`, `tail`, `wc`, `sha256sum`, `tar`, `gzip`)
- `curl`
- `awk` (mawk or gawk; prefer gawk for associative arrays)
- `sed`
- `grep` (GNU preferred for `-F -f patterns.txt` Aho-Corasick speed)

### 14.2 Tier 2 — ship as `bl` deps

Single-binary additions, trivial to install:

- `jq` — single static binary, ~3 MB, portable back to CentOS 6. Non-optional.
- `zstd` — optional, runtime-detected. Falls back to `gzip`.

### 14.3 Tier 3 — curator sandbox only (not host)

Inside the Anthropic-hosted environment, provisioned at env creation:

- `apache2 + libapache2-mod-security2 + modsecurity-crs` — for `apachectl -t` pre-flight of synthesized ModSec rules
- `yara` — for on-sandbox signature testing
- `duckdb` — for agentic SQL over JSONL (e.g. `SELECT client, count(*) FROM read_json_auto('transfer.jsonl') WHERE path LIKE '/custom_options/%' GROUP BY 1`)

None of these Tier-3 deps are installed on the fleet host. The sandbox has them; the host does not.

### 14.4 What is explicitly NOT required

- **No Python** at runtime on any host
- **No Docker** (operator can use docker for demo fixture; `bl` runs native)
- **No systemd** requirement (systemd-based trigger is convenient, not mandatory)
- **No database** (SQLite or otherwise) — all state in memory stores + files + small local ledger
- **No web server** or local HTTP listener — `bl` is a command, not a service

---

## 15. Non-goals (explicit)

This document and v2 deliberately do not describe:

- **Fleet-scope orchestration.** `bl` is per-host. Fleet propagation of defenses rides the operator's existing deployment primitive (Puppet, Ansible, Salt, Chef, manual SSH) — blacklight generates the payload; the operator propagates.
- **Continuous posture monitoring daemon.** v2 is trigger-bound. Posture arc (periodic sweeps, trajectory analysis) is roadmap P2.
- **Web frontend or dashboard.** The terminal REPL is the operator surface. A rendered HTML brief is a post-close artifact, not the primary interface.
- **Replacing defensive primitives.** blacklight directs `apachectl`, `apf`, `csf`, `iptables`, `nftables`, `maldet`, `clamscan`, `yara` — it does not re-implement any of them.
- **Cross-CVE threat intelligence sharing.** Roadmap P2+.
- **Windows / BSD support.** Roadmap P4. v2 is Linux only.

---

## 16. Glossary

- **Case** — an investigation; carries hypothesis, evidence, actions, precedent. One per incident.
- **Step** — a single action the agent prescribes. Has an action tier, a verb, typed arguments, and a reasoning field. Written to `bl-case/pending/`.
- **Action tier** — one of `read-only`, `auto`, `suggested`, `destructive`, `unknown`. Determines gate behavior.
- **Skill** — a description-routed operator-voice behavior module uploaded to the Anthropic Skills API. Lazy-loaded by the curator when the description matches the current reasoning need. Six routing Skills in Path C; corpus content delivered via Files API. See §3.4.
- **Trigger** — the first signal that opens a case (e.g. maldet quarantine, auditd critical event, ModSec rule fire).
- **Curator** — the Managed Agents session that owns a case.
- **Synthesizer** — a one-shot Opus 4.7 call invoked by the curator to author a specific defensive payload.
- **Intent reconstructor** — a one-shot Opus 4.7 call to analyze a specific malware sample.
- **Precedent** — a closed case accessible to future cases via `bl-archive/` (lives within `bl-case` memory store in v2, not a separate store).
- **Defense** — any applied change to host state that reduces attack surface (ModSec rule, firewall entry, scanner signature).
- **Remediation** — any applied change to host state that removes attacker presence (file quarantine, cron strip, .htaccess edit, process kill).

---

*End of DESIGN.md. For strategy, pitch, and roadmap see `PIVOT-v2.md`. For the operator-facing public face, see `README.md` (placeholder during rewrite).*
