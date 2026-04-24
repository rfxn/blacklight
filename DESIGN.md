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
│  agent         bl-curator  (Opus 4.7 + adaptive thinking + 1M context)   │
│  environment   bl-curator-env  (apt: apache2, mod_security2, yara,       │
│                jq, zstd, duckdb — installed once at env creation)        │
│  memory store  bl-skills   ~22 operator-voice files, read_only           │
│  memory store  bl-case     hypothesis + evidence + pending + results     │
│  files         evidence bundles, shell samples, closed-case briefs       │
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
                                                    read bl-skills/*
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

**Key mechanical choice: async step-emit over polled memory-store files, not synchronous SSE tool-result.** The agent writes proposed step JSON to `bl-case/pending/<id>.json`; the wrapper polls `bl-case/pending/` every 2–3s, executes, writes to `bl-case/results/<id>.json`, sends a wake event. This avoids SSE bidirectional plumbing in bash, makes the case memory a self-documenting audit log, and keeps `bl` a short-lived command rather than a long-running REPL process. Polling overhead (~2–5s/turn) is invisible against agent reasoning time.

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
    bl_preflight || return 64              # §8.1
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

### 7.1 `bl-skills` memory store

- Access: `read_only` from the agent's perspective (mounted at session creation)
- Written only by `bl setup` via the external Memories API
- Contents: ~22 operator-voice markdown files (see §9)
- Size target: ≤ 50 KB total
- **Kernel-enforced read-only is load-bearing**: attacker-supplied log content cannot rewrite operator knowledge mid-investigation

### 7.2 `bl-case` memory store

- Access: `read_write` from the agent's perspective
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
│   │   ├── pending/<act-id>.yaml     # awaiting operator approval
│   │   ├── applied/<act-id>.yaml     # applied; carries retire-hint
│   │   └── retired/<act-id>.yaml     # closed; no longer active
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
        return 64
    fi

    mkdir -p /var/lib/bl/state && printf '%s' "$BL_AGENT_ID" > /var/lib/bl/state/agent-id
}
```

### 8.2 Setup operations (one-time per workspace)

`bl setup` performs these operations idempotently. Each step checks for existing state before creating.

1. **Create agent** `bl-curator` via `POST /v1/agents` with:
   - `model: "claude-opus-4-7"`
   - `system`: loaded from `prompts/curator-agent.md`
   - `tools: [{"type": "agent_toolset_20260401"}]` — the Managed Agents built-in toolset bundle (includes `bash`, file-edit, `read`, `write`, `glob`, `grep`)
   - `output_config.format = {type: "json_schema", schema: <step-emit schema>}` — structured output for step emissions
   - `thinking: {type: "adaptive", display: "summarized"}`
2. **Create environment** `bl-curator-env`:
   - `type: cloud`
   - `packages.apt: [apache2, libapache2-mod-security2, modsecurity-crs, yara, jq, zstd, duckdb]`
   - `networking: {type: unrestricted}` (required for apt at env creation; sessions can use `limited` thereafter)
3. **Create memory stores**:
   - `bl-skills` (`access: read_only` to agent)
   - `bl-case` (`access: read_write` to agent)
4. **Seed skills**: iterate `skills/**/*.md`, POST each via the Memories API, compute sha256 of each, store in `bl-skills/MANIFEST.json` for delta detection on future `--sync`.
5. **Persist IDs** to `/var/lib/bl/state/`:
   - `agent-id`
   - `env-id`
   - `memstore-skills-id`
   - `memstore-case-id`
6. **Print operator exports**:
   ```
   export ANTHROPIC_API_KEY="<unchanged — use your current key>"
   export BL_READY=1
   ```

### 8.3 Source-of-truth resolution

`bl setup` discovers skill content in this order:

1. Current working directory has `skills/` and `prompts/` — use those
2. `$BL_REPO_URL` set — shallow clone to `$XDG_CACHE_HOME/blacklight/repo`, use
3. Default → `git clone https://github.com/rfxn/blacklight $XDG_CACHE_HOME/blacklight/repo`, use

This covers three adoption paths: operator-from-clone, operator-from-fork, operator-from-quickstart.

### 8.4 `bl setup --sync`

Compares local `skills/**/*.md` sha256 against `bl-skills/MANIFEST.json`, POSTs only changed files, updates manifest. Also detects deletions (local file missing → remote DELETE). Safe to re-run daily.

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

---

## 12. Model calls

Three distinct model calls, all Opus 4.7. Defined precisely so the implementation doesn't drift.

### 12.1 Curator (the session)

- Model: `claude-opus-4-7`
- Context: 1M
- Thinking: `{type: "adaptive", display: "summarized"}`
- Structured output: `output_config.format = {type: "json_schema", schema: <step-emit schema>}` — used when emitting to `bl-case/pending/*.json`
- Tools: `[{"type": "agent_toolset_20260401"}]` — Managed Agents built-in bundle (bash, file-edit, read, write, glob, grep)
- Memory stores: `bl-skills` (read-only) + `bl-case` (read-write), attached at session creation
- Lifetime: one session per case; resumable across 30-day checkpoint window; files can hot-swap via `/v1/sessions/:sid/resources`

### 12.2 Synthesizer (defense authoring call)

Invoked by the curator via `sessions.events.send` with a synthesize-this-defense prompt, scoped to specific case memory files. Produces `{rules: [...], firewall: [...], sigs: [...]}` schema-valid JSON.

- Model: `claude-opus-4-7`
- Thinking: on when rule authoring requires correlation across multiple evidence items; off for trivial emissions
- Output: json_schema-valid
- Reason for structured over tool_choice: Opus 4.7 rejects forced `tool_choice` when thinking is on (HTTP 400, verified 2026-04-22)
- `budget_tokens` is **not** used (retired on Opus 4.7); depth controlled by `output_config.effort`

### 12.3 Intent reconstructor (shell analysis)

Invoked on a specific shell-sample file (polyglot, binary, obfuscated PHP). Runs with extended thinking to peel obfuscation layers and map observed vs dormant capabilities.

- Model: `claude-opus-4-7`
- Thinking: adaptive + deep effort
- Input: file mounted via `sessions.resources.add`
- Output: attribution artifact → `bl-case/<case>/attribution.md`

### 12.4 When Sonnet 4.6 is used (rare in v2)

Hunter parallelism is available but not load-bearing in v2 — the 1M-context curator does single-session correlation directly. If a future case has a correlation scope exceeding the curator's turn budget (thousands of records), spawn Sonnet 4.6 hunters via direct `messages.create` with forced `tool_choice` and thinking off. v2 does not exercise this path by default.

---

## 13. Security model

blacklight operates with root-equivalent privilege on target hosts (modifying ModSec config, firewall state, crontab, webroot files). The security boundaries:

### 13.1 Auth surface

- Sole secret: `$ANTHROPIC_API_KEY` (operator-provisioned; never in repo)
- No service account; no long-lived tokens; no cert management
- API key scope = workspace scope = blast radius; operators should provision dedicated workspaces for production use

### 13.2 Prompt-injection hardening

- `bl-skills` is kernel-enforced read-only — attacker-supplied log content cannot rewrite operator knowledge
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
- **Skill** — an operator-voice markdown file in `bl-skills`. The programmable knowledge surface.
- **Trigger** — the first signal that opens a case (e.g. maldet quarantine, auditd critical event, ModSec rule fire).
- **Curator** — the Managed Agents session that owns a case.
- **Synthesizer** — a one-shot Opus 4.7 call invoked by the curator to author a specific defensive payload.
- **Intent reconstructor** — a one-shot Opus 4.7 call to analyze a specific malware sample.
- **Precedent** — a closed case accessible to future cases via `bl-archive/` (lives within `bl-case` memory store in v2, not a separate store).
- **Defense** — any applied change to host state that reduces attack surface (ModSec rule, firewall entry, scanner signature).
- **Remediation** — any applied change to host state that removes attacker presence (file quarantine, cron strip, .htaccess edit, process kill).

---

*End of DESIGN.md. For strategy, pitch, and roadmap see `PIVOT-v2.md`. For the operator-facing public face, see `README.md` (placeholder during rewrite).*
