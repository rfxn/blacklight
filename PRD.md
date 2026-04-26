# PRD — blacklight v0.6.0

> Defensive post-incident Linux forensics on the substrate the defender already owns.
> A portable bash CLI driven by a skills-native Anthropic Managed Agent that wields
> ModSec, APF/CSF/iptables/nftables, LMD, ClamAV, YARA, and the rest of the stack
> the operator already trusts — at agent speed, from operator-voice skills, GPL v2.

`bl` is a single bash file (~10.7K lines, assembled from 26 numbered parts under
`src/bl.d/`). It runs on bash 4.1+ from CentOS 6 forward. It owns no daemon, no
database, no service port. State lives in two places: `/var/lib/bl/` on the host
and a Managed Agent session in the operator's Anthropic workspace. The agent is
the direction; the wrapper is the hands; the host's existing primitives are the
muscle.

> **Targeted release: 0.6.0.** This document is written against post-M16 source — collectors + bridge + writeback complete; curator end-to-end loop runs cleanly.
>
> **Note on Skills primitive references.** Routing-skills are described throughout as "description-routed platform Skills primitives" — that is the architectural design and the runtime path when the workspace is allowlisted for `/v1/skills`. In the submitted-build runtime, Anthropic's Skills endpoint is allowlist-gated for this workspace (HTTP 404), so the bundles upload through the Files surface. The architectural shape is preserved; the upgrade path is zero-code-change once allowlist propagates. See `ANTHROPIC-API-NOTES.md` for the gated-runtime detail.

---

## 1. Executive frame

Attackers have agents. Defenders still have grep.

The hosting industry — shared, VPS, managed Magento, cPanel/DirectAdmin/Plesk
fleets, MSPs running Linux estates on $10/month margins — runs the OSS Linux
defensive stack: iptables (1998), mod_security (2002), ClamAV (2002), APF (2002),
fail2ban (2004), CSF (~2006), YARA (2008), LMD (2009), nftables (2014), BFD
(~2005). The same defenders have no agentic-defensive answer to the speed at
which offense now operates. Charlotte AI, Microsoft Security Copilot, Palo Alto
Purple, Google SecLM are bound to enterprise EDR/XDR platforms whose commercial
shape cannot bend below ~$150/endpoint/year. The hosts that need help most are
the hosts those tools structurally cannot reach.

blacklight is the defender's counter for that market. It drops in via
`curl -fsSL https://raw.githubusercontent.com/rfxn/blacklight/main/install.sh | sudo bash`
(the operator runs `bl setup` after install completes), talks to Anthropic
Managed Agents over the public API with one workspace key, and supercharges
the primitives the operator already trusts. Man-days of incident response become agentic-minutes — on the substrate
the defender already owns. **No new platform. No fleet migration. No analyst
retraining. No ecosystem buy-in.**

**Named adopter class:** the LMD / APF / BFD user base — hundreds of thousands
of Linux servers running R-fx Networks defensive tooling since 2002, plus the
hosting providers and MSPs who ship those tools as their default stack.
blacklight is not a competing product they evaluate. It is the natural next
release in a product family they have trusted for two decades.

**Why now:** Opus 4.7 with 1M context, Anthropic Managed Agents (beta header
`managed-agents-2026-04-01`), and the skills-native pattern proven by CrossBeam
in February 2026 are the three primitives that make agentic IR with multi-day
case continuity buildable in 2026 and not before.

---

## 1.5 Why bash

The architectural choice of bash + curl + jq is operator-truth, not a
shortcut. The hosting fleet `bl` is built for runs on a portability floor
that an enterprise-Python-stack tool cannot reach.

- **Portability floor: bash 4.1+ from 2011 (RHEL/CentOS 6 era).** RHEL 6
  GA was November 2010; bash 4.1 shipped December 2009. The version
  guard at `src/bl.d/00-header.sh:48` (`(( BASH_VERSINFO[0] * 100 +
  BASH_VERSINFO[1] < 401 ))`) is the explicit floor. Tens of millions
  of legacy hosting environments still run on or near this floor —
  cPanel only retired CentOS 6 support in 2020; CentOS 7 EOL was June
  2024 and many hosting fleets are still mid-migration.
- **Pre-usr-merge handling.** CentOS 6 has coreutils at `/bin/`, not
  `/usr/bin/`; modern distros have them at `/usr/bin/`. `bl` never
  hardcodes either — every coreutil call goes through the `command`
  builtin for portable PATH resolution. The discipline shows up
  consistently across the source tree: `grep -c "command " src/bl.d/*.sh`
  reports the prefix in **24 of 26 parts** (the two exempt parts —
  `00-header.sh` and `10-log.sh` — are pure-bash with no coreutil calls).
- **Zero runtime daemons, zero databases, zero service ports.** State
  lives in two places only: `/var/lib/bl/` on the host (operator-owned)
  and the Anthropic Managed Agents workspace (operator-owned). The
  wrapper exits when its operation completes; nothing listens between
  invocations.
- **Single secret = `$ANTHROPIC_API_KEY`.** No service account, no
  long-lived token, no mTLS, no certificate management. Preflight at
  `src/bl.d/30-preflight.sh:4` rejects an unset key; line 8 rejects an
  empty key; that is the entire authentication surface. The blast
  radius of a compromised credential is the workspace boundary, which
  is operator-provisioned and operator-owned.
- **Dependency floor (host runtime):** bash 4.1+, coreutils, curl, awk,
  sed, grep, jq. Tier-2 optional: zstd (gzip-5 fallback). Tier-3
  (curator sandbox only, never on host): apache2,
  libapache2-mod-security2, modsecurity-crs, yara, duckdb, pandoc,
  weasyprint — installed per-session by the agent via the bash tool,
  not pre-installed at env-create.
- **Distro matrix (CI-tested):** CentOS 6+, Debian 8+, Ubuntu 16.04+,
  RHEL 7+, Rocky 8+, Ubuntu 24.04. The repo ships
  `tests/Dockerfile`, `tests/Dockerfile.rocky9`, and
  `tests/Dockerfile.centos6`; `tests/Makefile` exposes `test`
  (debian12 default), `test-rocky9`, `test-quick`, and `test-all`
  (full release matrix).

This is not a "bash because we ran out of time" story. The hosting
industry runs on this floor; an enterprise-Python-stack tool cannot
reach it; the bash + curl + jq runtime IS the commercial moat against
Charlotte-class platforms because Charlotte cannot deploy here either.

---

## 2. The problem

When a host is compromised in the hosting industry, a specific failure mode
plays out hundreds of times a day. A ticket is opened. A tier-2 technician
either escalates or closes it. Escalated tickets get twenty minutes of senior
attention; the file gets removed; the ticket is closed. No case file is opened.
No cross-host check is run. No defense is authored against the family. Two
weeks later, a different host in the same fleet gets popped by the same actor
using the same technique, and the entire process starts over from scratch. The
attacker is running a campaign; the defender is running a triage queue.

The grounding incident for blacklight's design is **APSB25-94** — Adobe's
March 2026 advisory for the PolyShell / SessionReaper exploitation wave against
Adobe Commerce / Magento. SessionReaper (APSB25-88) had been actively exploiting
the merchant fleet since October 2025; ~1,193 hosts compromised before
PolyShell was even disclosed. The lived response to APSB25-94 surfaced the
class of failures blacklight is built to close:

- **Premature closure.** Cases marked resolved on day-N reopened on day-N+5
  when the actor returned through a persistence mechanism that was never
  audited (gsocket implants in `~/.config/htop/`, ANSI-obscured crontabs,
  argv[0]-spoofed `mariadbd`/`lsphp` processes).
- **Cross-host thread loss.** Two non-overlapping attacker clusters operating
  the same family of vulnerabilities across 97 hosts looked like one campaign
  to anyone holding less than the full evidence set in their head. Shift
  changes break attribution.
- **Premature exit at the artifact layer.** A senior engineer removes the
  webshell, but the `<FilesMatch>` block in `.htaccess` that routes
  `*.jpg`/`*.png`/`*.gif` to PHP execution stays. The actor's next polyglot
  finds a path back in.
- **Consultant-grade IR cost structure.** External IR firms charge ~$600/hour
  and 3–4 hours per host. Fleet-scale incident response across dozens of
  customer environments costs four-to-five figures per month and arrives
  weeks behind the campaign.

The gap that matters is not detection — LMD has solved that adequately since
2006. The gap is **continuity**: nobody is maintaining the investigative thread
across hosts, days, shifts, and CVEs. blacklight closes that gap with a Managed
Agent session that does not sleep, does not hand off, and produces a case file
that survives the attention span of any individual human.

---

## 3. Users

Four operator profiles, in priority order:

| Profile | Pain | What `bl` gives them |
|---|---|---|
| **L1 SOC analyst** at a managed hosting provider | Triages dozens of ModSec / LMD / fail2ban alerts per shift. Loses context at every handoff. Cannot author a defense. | `bl trigger lmd <hit>` opens a case from the existing hook surface; the curator drives observation, defense, and cleanup. The L1 confirms tier-gated steps. |
| **L2 IR engineer** at an MSP | Owns the cross-host attribution thread for active campaigns. Re-derives context every time evidence arrives on a new host. | One curator session per case, resumable for 30 days. New evidence attaches via the Files API; the curator extends the hypothesis instead of restarting. |
| **Hosting product owner** | Cannot ship enterprise EDR ($150+/endpoint/year) on $10/month customer margins. Has no agentic-defensive answer for their fleet. | GPL v2, zero license cost, single bash file, $ANTHROPIC_API_KEY is the only credential. Operator pays Anthropic API usage; that is the entire cost. |
| **Defender / sysadmin** on a small fleet | Already runs LMD, APF, ModSec by hand. Wants the agentic layer without rearchitecting. | Vocabulary stays the same — `bl observe cron --user x` is what they would have typed. Skills are markdown; they read or fork them. |

---

## 4. Goals & non-goals

### 4.1 Goals (what `bl` does today)

- **Direct existing defensive primitives at agent speed.** ModSec, APF, CSF,
  iptables, nftables, LMD, ClamAV are wielded as the host already exposes
  them. No re-abstraction.
- **Maintain a case as a first-class multi-day artifact.** One Managed Agent
  session per case. The session is the case state.
- **Produce auditable change.** Every defense, every clean operation, every
  observation is appended to a case ledger; backups precede destructive ops;
  quarantine replaces deletion.
- **Preserve operator vocabulary.** `bl observe cron --user x`,
  `bl defend modsec <rule>`, `bl clean htaccess <dir>` — what the analyst
  would have typed anyway.
- **Be auditable in 30 minutes.** Single bash file plus markdown skills. No
  closed binaries.

### 4.2 Non-goals (explicit cuts)

- **Not an EDR.** No kernel sensor, no endpoint telemetry agent, no platform
  to roll out fleetwide.
- **Not a SIEM.** No log aggregation substrate; `bl` consumes existing logs in
  place.
- **Not a daemon or service.** `bl` is invoked once per operator thought and
  exits. State is kept in `/var/lib/bl/` and the Anthropic-hosted session.
- **Not a fleet manager.** v0.6.0 is single-host. Fleet propagation rides the
  customer's existing Puppet/Ansible/Salt/Chef.
- **Not multi-tenant SaaS.** The Anthropic workspace is operator-provisioned
  and operator-owned.
- **Not a replacement for ModSec/APF/LMD.** `bl` directs them. It does not
  replace them. The "supercharge-not-rearchitect" pitch is load-bearing.
- **Not Python.** Zero language runtime on the host. `bl` is bash; the agent
  runs in Anthropic's sandbox; we do not operate it.
- **No live LLM in CI.** `BL_DISABLE_LLM=1` short-circuits LLM calls; the test
  suite is fixture-driven, not session-driven.

The tiebreaker on every build decision is the four judging weights —
**Impact 30 / Demo 25 / Managed-Agents 20 / Depth 20**. A change that does
not raise at least one weight is wrong.

---

## 5. Architecture summary

Three layers. Two state stores. One language runtime, and it is not on the host.

```
┌─ Layer A — bl on the host (bash 4.1+, curl, jq, awk, sed, grep, tar, gzip) ─┐
│                                                                              │
│   src/bl.d/00-header.sh     version, exit codes, BL_VAR_DIR, FD registry    │
│   src/bl.d/05-vendor-alert.sh  vendored rfxn alert lib (~1.2K lines)        │
│   src/bl.d/06-vendor-tlog.sh   vendored rfxn tlog lib (~0.8K lines)         │
│   src/bl.d/10-log.sh        bl_debug/info/warn/error                        │
│   src/bl.d/15-workdir.sh    BL_VAR_DIR lazy init + bl_case_current reader   │
│   src/bl.d/20-api.sh        bl_api_call (curl + retry + 429/5xx)            │
│   src/bl.d/22-models.sh     bl_messages_call (Sonnet/Haiku)                 │
│   src/bl.d/23-files.sh      Files API upload/list/delete                    │
│   src/bl.d/24-skills.sh     routing-skill push/sync                         │
│   src/bl.d/25-ledger.sh     append-only JSONL case ledger                   │
│   src/bl.d/26-fence.sh      session-unique injection-fence tokens           │
│   src/bl.d/27-outbox.sh     durable enqueue for memstore writes             │
│   src/bl.d/28-notify.sh     out-of-band channel routing                     │
│   src/bl.d/29-trigger.sh    LMD post_scan_hook handler                      │
│   src/bl.d/30-preflight.sh  workspace-seeded check, conf load               │
│   src/bl.d/40..42-observe   evidence collectors + bundle router             │
│   src/bl.d/45-cpanel.sh     EasyApache lockin coordination                  │
│   src/bl.d/50-consult.sh    open/attach a curator session for a case        │
│   src/bl.d/60-run.sh        execute agent-prescribed steps (tier-gated)     │
│   src/bl.d/70-case.sh       case show/list/log/close/reopen                 │
│   src/bl.d/82-defend.sh     modsec / firewall / sig with FP gate            │
│   src/bl.d/83-clean.sh      file/htaccess/cron/proc remediation             │
│   src/bl.d/84-setup.sh      provision agent + env + memstore + skills      │
│   src/bl.d/90-main.sh       verb dispatch + per-verb help                   │
│                                                                              │
│  bl is assembled by `make bl` (numeric-prefix concat). Curl-pipe-installable.│
│  Single file by design — review-load fits one head; no source-helper deps.  │
│  05/06 vendor parts are rfxn shared infra (alert + tlog), ~20% of LOC.      │
│                                                                              │
└─────────────────────────────────────┬────────────────────────────────────────┘
                                      │ HTTPS + ANTHROPIC_API_KEY (curl + jq)
                                      ↓
┌─ Layer B — Managed Agent session (Anthropic-hosted, Opus 4.7, 1M ctx) ──────┐
│                                                                              │
│  Agent           bl-curator         (created once by `bl setup`)            │
│  Environment     bl-curator-env     (cloud sandbox; packages installed     │
│                                      per-session by agent via the bash    │
│                                      tool — apache2, libapache2-mod-      │
│                                      security2, modsecurity-crs, yara,    │
│                                      jq, zstd, duckdb, pandoc,            │
│                                      weasyprint)                          │
│  Memory store    bl-case            read_write — one folder per case:       │
│                                      hypothesis, evidence index, pending    │
│                                      steps, completed steps, history       │
│  Routing skills  6 description-routed Skills (Path C / M13 realignment;    │
│                  bl-skills memory store retired). The platform router       │
│                  selects relevant skills by description on each turn.      │
│  Files           per-case evidence bundles; closed-case briefs as          │
│                  precedent; 8 workspace corpora as substrate context.      │
│  Custom tools    report_step          — propose a wrapper action           │
│                  synthesize_defense   — author a defensive payload         │
│                  reconstruct_intent   — analyse a shell sample              │
│                                                                              │
│  Live API surfaces (verified M15):                                          │
│    POST /v1/agents/<id>            update                                  │
│    POST /v1/agents/<id>/archive    retire                                  │
│    sessions.create body: { agent: <id>, ... }                               │
│                                                                              │
└─────────────────────────────────────┬────────────────────────────────────────┘
                                      │ step directives (report_step emissions)
                                      ↓
┌─ Layer C — existing host primitives (we do not install or replace these) ───┐
│                                                                              │
│   apachectl, mod_security2, ModSecurity-CRS                                 │
│   APF, CSF, iptables, nftables                                              │
│   LMD (maldet), ClamAV (clamscan), YARA                                     │
│   crontab, find, stat, ps, /proc                                            │
│   Apache/nginx access + error + modsec audit logs                           │
│   journalctl, auditd                                                        │
│                                                                              │
└──────────────────────────────────────────────────────────────────────────────┘
```

### 5.0.1 Bash SDK surface

`bl` is not just a CLI; it is a bash SDK. The assembled binary exposes
**137 `bl_*` functions** across 26 numbered source parts under
`src/bl.d/`. Operators or third-party tooling that source `bl`
(`source bl || true`) get reusable primitives for Anthropic Managed
Agents, Files, Memory Stores, Skills, Messages API, prompt-injection
fencing, ledger writes, outbox rate-limiting, and operator
notification — all in pure bash with no Python or service runtime.

| Family | # | Source | Purpose |
|---|---:|---|---|
| `bl_api_*` (incl. `bl_mem_*`, `bl_poll_*`, `bl_jq_*`) | 8 | `20-api.sh` | Managed Agents REST surface (POST/GET/poll/wake), backoff+retry, memory-store CRUD, schema check |
| `bl_messages_call` | 1 | `22-models.sh` | Messages API caller (Sonnet 4.6 / Haiku 4.5) |
| `bl_files_*` | 5 | `23-files.sh` | Anthropic Files API — upload, attach to session, GC orphans |
| `bl_skills_*` | 4 | `24-skills.sh` | Anthropic Skills API — upload routing skills, version-pin |
| `bl_ledger_*` | 2 | `25-ledger.sh` | Dual-write audit ledger (memory store + local JSONL) |
| `bl_fence_*` | 4 | `26-fence.sh` | Prompt-injection fence — session-unique tokens, untrusted-content wrap |
| `bl_outbox_*` | 5 | `27-outbox.sh` | Rate-limit queue with watermarks (500/1000) + age-gated drain |
| `bl_notify` | 1 | `28-notify.sh` | Multi-channel operator notification (alert_lib substrate) |
| `bl_trigger_*` | 3 | `29-trigger.sh` | Hook adapters (LMD `post_scan_hook` today) |
| `bl_preflight` + per-verb help | 12 | `30-preflight.sh` | Workspace + state validation, agent-id cache, conf load, per-verb usage |
| `bl_observe_*` | 16 | `40-observe-helpers.sh`, `41-observe-collectors.sh`, `42-observe-router.sh` | 10 evidence collectors (file/log/cron/proc/htaccess/fs/firewall/sigs/substrate/bundle) + helpers + router |
| `bl_consult_*` | 11 | `50-consult.sh` | Session lifecycle, case allocation, polled step-emit consumer |
| `bl_run_*` | 10 | `60-run.sh` | Step execution + tier-gate enforcement + schema validation + unattended queueing |
| `bl_case_*` | 12 | `70-case.sh` | Case lifecycle (show/list/log/close/reopen) |
| `bl_defend_*` | 4 | `82-defend.sh` | Defensive payload apply (modsec / firewall / sig) |
| `bl_clean_*` | 7 | `83-clean.sh` | Remediation (htaccess / cron / proc / file) with backup + diff + undo |
| `bl_setup_*` | 25 | `84-setup.sh` | Workspace bootstrap, idempotent skill upload, CAS update, archive |
| `alert_*` (vendored) | — | `05-vendor-alert.sh` (1,191 LOC) | Vendored from rfxn shared substrate |
| `tlog_*` (vendored) | — | `06-vendor-tlog.sh` (783 LOC) | Vendored from rfxn shared substrate |

Each family is a coherent SDK consumable from any other bash tool that
sources `bl`. The CLI dispatch in `90-main.sh` is one consumer of these
primitives; nothing prevents another consumer.

### 5.1 Model assignments

| Surface | Model | Why this model |
|---|---|---|
| Curator (per-case session) | **Opus 4.7** | 1M context absorbs full case state — hypothesis history, evidence index, prior bundles, mounted skills — without a retriever layer. Calibrated hypothesis revision is the trained behaviour. Sandbox tool-use orchestrates `apachectl -t`, `jq`, `awk` natively. |
| `synthesize_defense` (defense authoring) | **Opus 4.7** | Generating a ModSec rule + exception list + validation request as a coherent triple is a multi-artifact consistency problem. Validated in-sandbox before promotion to `bl-case/<case>/actions/pending/`. |
| `reconstruct_intent` (shell-sample analysis) | **Opus 4.7** | Multi-layer deobfuscation (base64 → gzinflate → eval) plus dormant-capability inference from family patterns. Code-comprehension at depth. |
| Bundle summary render | **Sonnet 4.6** | `bl observe bundle` produces a `summary.md` from JSONL evidence rows — pattern condensation at speed and cost. Falls back to deterministic helper on `--no-llm-summary` or `BL_DISABLE_LLM=1`. |
| FP-gate adjudication | **Haiku 4.5** | Binary-scan-passed signatures are spot-checked by Haiku before LMD/ClamAV append. Cheap, fast, schema-output, runs only after a deterministic gate already passed. |

`BL_DISABLE_LLM=1` short-circuits all LLM calls and forces deterministic
fallbacks — required for CI and operator dry-runs. The test suite never makes
a live API call; `tests/helpers/curator-mock.bash` shims `curl` against
`tests/fixtures/step-*.json`.

### 5.2 Why Managed Agents — the one-paragraph version

Managed Agents is the only primitive that turns "multi-day investigation" into
a first-class operation rather than a workflow simulation. The case is the
session. Skills mount as platform-routed Skills and propagate to the next
session without redeploying code. Pre-flight validation happens in the agent's
own sandbox — `apachectl -t` runs against the agent's config tree before any
rule is promoted. The event stream is the operator surface — `tool_use`,
reasoning content, file mounts are SSE events `bl` reads directly. Workspace
isolation is platform-enforced, so the commercial boundary needs zero
multi-tenant engineering from us. The "Best Use of Claude Managed Agents"
prize description names this verbatim: *meaningful, long-running tasks — not
just a demo, but something you'd actually ship.*

---

## 6. Command surface

Nine namespaces. Verb dispatch in `src/bl.d/90-main.sh`. Per-verb help bypasses
preflight (`bl <verb> --help` works on an unseeded workspace).

| Verb | One-liner |
|---|---|
| `bl observe` | Read-only evidence extraction — `file`, `log {apache\|modsec\|journal}`, `cron`, `proc`, `htaccess`, `fs`, `firewall`, `sigs`, `substrate`, `bundle`. JSONL or human output. |
| `bl consult` | Open or attach an investigation case via the `bl-curator` Managed Agent. Cases are allocated via `bl consult --new`. Posts the case bundle, receives action-tier recommendations. |
| `bl run` | Execute an agent-prescribed step. Schema-validated against `schemas/step.json`, tier-gated, ledger-logged. Flags: `--yes`, `--dry-run`, `--unsafe`, `--explain`; modes `--list` and `--batch [--max <N>]` (default 16). |
| `bl defend` | Apply an agent-authored defensive payload — `modsec` (rule apply / `--remove` / rollback), `firewall` (APF/CSF/iptables/nftables, CDN-safelist aware, `--retire <duration>` default 30d), `sig` (LMD/ClamAV signature append, FP-corpus gated). |
| `bl clean` | Diff-shown remediation — `file` (quarantine, never unlink), `htaccess` (`--patch <file>`), `cron` (`--patch <file>`), `proc` (capture-then-SIGTERM). `--undo <backup-id>` and `--unquarantine <entry-id>` round-trip. |
| `bl case` | Lifecycle — `show`, `list`, `log [--audit]`, `close`, `reopen`. (Cases are allocated by `bl consult --new`, not by a `case open` verb.) |
| `bl setup` | One-time-per-workspace bootstrap. Creates the agent, environment, memory store; uploads workspace corpora to Files; registers six routing Skills. `--sync` for delta-push, `--reset --force` for teardown, `--gc`, `--eval`, `--check`. |
| `bl trigger` | Hook-driven case open from existing trigger surfaces. Today: LMD `post_scan_hook`. |
| `bl flush` | Drain the durable outbox of queued memstore writes (cron-driven). |

Bash-pipe-source guard: `bl` may be sourced by tests (so `bl_*` functions are
inspectable) without inheriting `set -euo pipefail` — strict-mode gates on the
execute path only. Source-mode is required by the bash 4.1 floor (CentOS 6
propagates errexit through `|| true` masking from sourced files).

Exit codes (`docs/exit-codes.md`):

| Code | Meaning |
|---|---|
| 0 | OK |
| 64 | Usage |
| 65 | Preflight fail (missing `ANTHROPIC_API_KEY`, `curl`, `jq`, or unwritable `/var/lib/bl`) |
| 66 | Workspace not seeded (run `bl setup`) |
| 67 | Schema validation fail (a step or payload did not match `schemas/`) |
| 68 | Tier gate denied |
| 69 | Upstream API error (5xx exhausted retries) |
| 70 | Rate limited (429 exhausted retries) |
| 71 | Conflict (concurrent state mutation) |
| 72 | Not found |

---

## 7. Skills bundle

Operator-voice knowledge is the moat. The bundle is grounded in twenty-five
years of Linux hosting security operations, not in research.

**Inventory:** 73 skill files (70 `.md` content + 3 `description.txt` routing metadata) across 23 directories under `skills/` —
authoring sources for the platform-routed Skill descriptions and the corpora.

```
skills/
├── actor-attribution/           ├── ir-playbook/
├── agentic-minutes-playbook/    ├── legacy-os-pitfalls/
├── apf-grammar/                 ├── linux-forensics/
├── apsb25-94/                   ├── lmd-triggers/
├── bl-capabilities/             ├── magento-attacks/
├── cpanel-easyapache/           ├── modsec-grammar/
├── defense-synthesis/           ├── obfuscation/
├── false-positives/             ├── remediation/
├── hosting-stack/               ├── ride-the-substrate/
├── ic-brief-format/             ├── shared-hosting-attack-shapes/
├── ioc-aggregation/             ├── timeline/
└── webshell-families/

routing-skills/                  (6 platform Skills, description-routed)
├── authoring-incident-briefs/
├── curating-cases/
├── extracting-iocs/
├── gating-false-positives/
├── prescribing-defensive-payloads/
└── synthesizing-evidence/

skills-corpus/                   (8 workspace corpora, mounted as Files)
├── authoring-incident-briefs-corpus.md
├── curating-cases-corpus.md
├── extracting-iocs-corpus.md
├── foundations.md
├── gating-false-positives-corpus.md
├── prescribing-defensive-payloads-corpus.md
├── substrate-context-corpus.md
└── synthesizing-evidence-corpus.md
```

**Routing model (M13 Path C realignment):** the legacy `bl-skills` memory
store has been retired. Skills are now authored under `skills/` and shipped as
**six description-routed platform Skills** under `routing-skills/`, with the
deeper substrate carried by the eight corpus files in `skills-corpus/`. The
platform router selects skills per turn from the description; per-turn token
load on routed Skills is bounded.

**Authoring discipline (non-negotiable):**

- Each operator-voice skill opens with a scenario from lived experience, not
  a definition.
- It states the non-obvious rule — something a competent IR analyst at smaller
  scale would get wrong.
- One concrete example per file, drawn from public APSB25-94 material —
  never operator-local.
- Names a failure mode and how the rule handles it.
- If the only available draft would be generic IR/SOC boilerplate, the gap
  is flagged and the file lands later. Slop is not shipped.

**Extensibility:** a defender running DirectAdmin or Virtualmin authors their
own skills, adds them under `routing-skills/` with a description, and the
curator picks them up on the next session. Skills are GPL v2 markdown.
Read, fork, extend.

---

## 8. Safety model

Five action tiers, evaluated by `bl_run_evaluate_tier` against the step JSON
emitted by `report_step`. The wrapper enforces the gate; the agent cannot
override it.

| Tier | Examples | Gate behaviour |
|---|---|---|
| **read-only** | `observe.*`, `consult` | Auto-execute. |
| **auto** (reversible, low-risk) | `defend.firewall <new-ip>`, `defend.sig` (FP-gate passed), `case.note` | Auto-execute + notify; operator veto window via `bl run --batch`. |
| **suggested** (reversible, high-impact) | `defend.modsec` (new rule) | Operator confirmation required. `--yes` permitted at this tier. |
| **destructive** | `clean.*`, `defend.modsec --remove`, `case.close` | Diff shown; `--unsafe` AND `--yes` both required. Backup or quarantine entry written before the operation runs. |
| **unknown** | Anything that does not map to a known verb | Deny by default. Exit 68 (`TIER_GATE_DENIED`). Override requires `--unsafe --yes`. |

**Mechanical disciplines layered on top of the tier gate:**

- **Schema validation.** Every `report_step` emission is validated against
  `schemas/step.json` before persistence. Both the platform (via
  `input_schema`) and the wrapper (defense-in-depth) reject malformed
  envelopes with exit 67.
- **Prompt-injection fence.** Evidence records are wrapped in a session-unique
  fence token `sha256(case_id || payload || nonce)[:16]`. Content inside the
  fence is data; instructions inside the fence are ignored. The token changes
  per record so an attacker cannot forge a matching end-token without changing
  the payload hash. Schema-override injections are routed into
  `open-questions.md` as findings, never honoured as directives.
- **Backup-before-apply.** Every `clean` operation snapshots the original
  under `/var/lib/bl/quarantine/<entry-id>/`. `bl clean --undo` and
  `bl clean --unquarantine` round-trip restore.
- **Quarantine-not-delete.** `bl clean file` moves the file under
  `/var/lib/bl/quarantine/`; it does not unlink. Operators can re-examine
  evidence after the fact.
- **CDN-safelist-aware firewall.** `bl defend firewall` consults the
  configured CDN ranges before adding a rule that would null-route
  Cloudflare/Fastly/Akamai upstreams.
- **FP corpus gate.** Signature submissions to LMD/ClamAV pass two stages:
  a deterministic scan of the operator-provisioned FP corpus at
  `/var/lib/bl/fp-corpus/` (size depends on the host; demo fixtures
  ship a small reference corpus), then a Haiku 4.5 spot-check on
  borderline hits. Both must pass.
- **Append-only ledger.** Every action appends a JSONL event to
  `/var/lib/bl/ledger/<case>.jsonl` under `flock` FD 200. The ledger is the
  audit surface; `bl case log --audit` produces a per-kind summary.
- **Durable outbox.** Memory-store writes that fail (network, 429, 5xx) are
  enqueued under `/var/lib/bl/outbox/` and drained on the next preflight or
  via `bl flush --outbox`. Age-gated to avoid drain-on-every-invocation
  thrash.

---

## 9. Why Managed Agents — the architecture defence

Every defensive IR tool since 2005 has been a stateless batch analyzer: submit
logs, get a report, follow up requires another batch. SIEMs correlate at query
time; SOAR runs playbooks but does not reason; AI-SOC products wrap LLM calls
around tickets without persistent state. Managed Agents is the first primitive
where a multi-day investigation is a first-class concept instead of a workflow
simulation. Eight reasons this matters for the blacklight surface specifically:

1. **The case IS the session.** `bl consult` boots a curator session against
   the case memory store. Seven days later the session is still alive and has
   read every hypothesis revision, every evidence summary, every defensive
   hit. Day-5 evidence extends; it does not restart context.
2. **Skills are files, not prompt strings.** Routing Skills mount at session
   creation. Edits propagate to the next session without code deploy. A
   third-party hosting provider contributes a skill via PR; it ships as a
   memory-store update.
3. **Pre-flight validation runs in the agent's own sandbox.** `apachectl -t`
   runs against the agent's config tree before the rule is promoted to
   `pending/`. No external validator service. No cross-machine handoff. No
   drift between "what the agent thought" and "what apache would accept."
4. **The event stream is the operator surface.** `tool_use`, reasoning, file
   mounts are SSE events. The demo UI is `curl …/events | jq .`.
5. **Workspace-scoped, commercially.** Sessions, skills, cases live in the
   workspace that authored them. Multi-tenant engineering: zero. The platform
   enforces the boundary.
6. **Hot-swap mid-investigation evidence.** Files attach to a running session
   via `sessions.resources.add`. Memory stores attach at creation. This split
   is load-bearing: structured case state never changes shape; raw evidence
   arrives unpredictably and must absorb without tearing context.
7. **1M context absorbs the whole case.** A hot mid-investigation case lives
   at ~85K–120K tokens — 8–12% of the window. No retriever; no chunking; no
   summary-of-summary drift. Cross-evidence correlation operates on the full
   view. Prompt caching amortizes the stable portion (skills + history) across
   turns; only the new evidence delta is uncached.
8. **Operator self-bootstrap, in bash, against the public API.** `bl setup`
   provisions agent + environment + memory store + Files + Skills idempotently.
   `bl` preflight detects an unseeded workspace on every invocation
   (`GET /v1/agents`); if missing, it points to the one-line bootstrap. One
   workspace per operator, every host shares it.

---

## 10. Competitive positioning

The first wave of agentic defensive tooling — **CrowdStrike Charlotte AI**
(bound to Falcon EDR/XDR), **Microsoft Security Copilot** (bound to Sentinel
+ Defender + M365 E5), **Palo Alto Purple AI** (bound to Cortex), **Google
SecLM / Duet for Security** (bound to Chronicle) — shares one structural
constraint: **the operator must be inside the vendor platform before the agent
is available.** The reasoning quality is real. The bottleneck is platform
reach.

| Adoption barrier | Charlotte-class | blacklight |
|---|---|---|
| Platform onboarding | 3–18 months fleetwide | ~30 seconds (`curl \| bash`, then `bl setup`) |
| Per-endpoint licensing | $75–$250/host/year | $0; only Anthropic API usage |
| SIEM/SOAR/IdP integration | Quarters of platform engineering | None — `bl` reads existing logs in place |
| Analyst retraining | Weeks to months on vendor DSL | Zero — operator vocabulary preserved |
| Extensibility | Vendor-DSL detection authoring (often paid tier) | Fork the repo; drop in a markdown skill |
| Lock-in | Per-vendor; migration cost compounds | None — wrapper and skills are GPL v2 |
| Works on CentOS 6 / RHEL 7 / Debian 10 | Rarely supported | Yes — bash 4.1 + curl is the floor |
| Compatible with $10/month customer margins | No | Yes |
| Auditable in 30 minutes | No (closed platform) | Yes (single bash file + markdown) |

The OSS Linux defensive stack runs on **the order of hundreds of millions of
hosts** that Charlotte cannot reach — not because CrowdStrike does not want
the market, but because the platform-first commercial shape cannot bend that
low. blacklight does not compete with Charlotte on enterprise accounts. It
addresses the market Charlotte structurally cannot serve.

**Compounding effect for the named adopter class.** For LMD / APF / BFD
users, blacklight is not an external tool to evaluate. It is the natural next
release in a product family they have trusted for two decades. Charlotte can
match the reasoning given time. It cannot retroactively acquire twenty years
of sysadmin trust in LMD, APF, and BFD as the foundation layer. blacklight
lands the agentic era on top of that trust, not alongside it.

---

## 11. Non-goals — explicit list

What `bl` will not do, in this version or in future versions, regardless of
roadmap pressure:

- **Replace ModSec / APF / LMD / ClamAV / YARA with engines of our own.**
  We direct them. We do not displace them.
- **Ship a SIEM or log-aggregation substrate of our own.** `bl observe`
  consumes existing logs in place.
- **Become a multi-tenant SaaS we host.** The Anthropic workspace is
  customer-provisioned and customer-owned. Per-customer isolation is
  platform-native.
- **Rewrite IR workflow from scratch.** We plug into existing trigger surfaces
  — LMD `post_scan_hook` today, auditd / inotify / ModSec critical hook on
  the roadmap.
- **Require Python on the host.** Bash + coreutils + curl + jq is the floor
  forever.
- **Become a closed-core commercial product.** GPL v2 is permanent.

---

## 12. Roadmap (post-submission)

The hackathon ships the foundational node. The roadmap extends it without
violating the supercharge-not-rearchitect pitch.

**Phase P1 — stabilization + community release (Weeks 1–4).**
Public release under `rfxn/blacklight`. First external operator beta. Skills
authoring schema documented (frontmatter, scenario-first, FP-gate
expectations). `docker compose up` clean-room install verified on Ubuntu
20/22/24, Rocky 9, Debian 12, CentOS 7. Exit gate: external operator runs a
PolyShell-class incident through the loop without intervention from the
upstream maintainer.

**Phase P2 — posture arc + cross-case intelligence (Months 1–2).**
Posture sweep memory store added. Auto-reopen heuristic — closed cases run a
T+5-day silent verify and reopen on non-zero hits. Closes the IC-5727
premature-closure pattern from the lived APSB25-94 response. Retrospective
compromise sweep (`bl observe fs --mtime-since <cve-disclosure-date>`).
Precedent re-injection: `bl consult` on a new case auto-mounts relevant
archived briefs by family/CVE/platform tag.

**Phase P3 — fleet propagation + multi-tenant (Months 2–4).**
`bl watch` systemd-oneshot mode for continuous posture (consumes existing
trigger infra; not a daemon). Multi-workspace patterns for MSPs running
multiple customer fleets. `bl probe` remote attack-surface validator
(scoped to CVE class). Signature-distribution orchestration: `bl sig ship`
ladders manifests across fleets via the customer's existing deploy primitive.

**Phase P4 — platform breadth (Months 4–6).**
Outcome-driven synthesizer via `user.define_outcome` + rubric grader.
`callable_agents` multi-agent for kernel/memory/network forensics
sub-specialists. Role-swap substrate — same curator + same skills, different
decision profiles (auditor / abuse / migration). FreeBSD support;
Windows event-log parity via wevtutil/ETW analogs.

**Phase P5 — ecosystem + upstream (Months 6+).**
Upstream skills contributions to ModSec, LMD, YARA, APF/CSF, ClamAV.
Industry working group on agentic-minute response SLAs. Reference
implementation adopted by mainstream hosting vendors (cPanel, CloudLinux,
Plesk, DirectAdmin).

The roadmap moves the asymmetry between offence and defence on response
time. Mythos-class offensive automation does not disappear; the *gap*
between "vulnerability exploitable" and "fleet defended" shrinks from
weeks to hours, on tools the defensive side already trusts.

---

## 13. Success criteria (v0.6.0)

The current build clears each of these gates:

1. `bl consult --new --trigger <sample>` on a fresh Ubuntu 24.04 produces a
   live REPL backed by a Managed Agents curator session.
2. The curator reads at least three routing Skills during the session and
   cites them in `report_step` reasoning.
3. At least one defense (`defend.modsec` or `defend.firewall` or
   `defend.sig`) is authored, tier-gated, and applied.
4. At least one `clean` operation (htaccess or cron) runs with diff-shown
   confirmation and a quarantine entry written.
5. `bl case close` archives the case brief to Files; the brief is mountable
   as precedent on a subsequent case.
6. The full BATS suite — 373 tests across 19 files — runs green on Debian 12
   and Rocky 9 (the minimum pre-commit matrix); release matrix adds
   ubuntu2404, centos7, rocky8, ubuntu2004.
7. Zero operator-local data in the repo. Reference data (`~/admin/work/proj/depot/polyshell/`,
   `/home/sigforge/var/ioc/polyshell_out/`) is grounding-only and never
   committed.
8. `bl --version` reports `bl 0.5.0` after the release-tag version bump
   (current source carries 0.4.0; the bump lands with the tag).

---

## 14. MVP scope vs. shipped

PIVOT-v2 §14 set nine pre-submission MVP success criteria. The 0.5.0
codebase calibrates against them as follows.

| # | MVP success criterion (PIVOT-v2 §14) | Shipped at 0.5.0 |
|---|---|---|
| 1 | `bl consult --new --trigger <sample>` produces live REPL on Ubuntu 24.04 | Live REPL **plus** CI-matrix coverage on debian12, rocky9, centos7, rocky8, ubuntu2004, ubuntu2404; live integration smoke at `tests/live/setup-live.bats` (BL_LIVE-gated) |
| 2 | Curator reads ≥3 skills and cites them | **73 skill files (70 `.md` content + 3 `description.txt` routing metadata) / 23 directories / 6 routing Skills / 8 corpus files**; description-routed lazy-load (M13 Path C); `bl setup --eval` skill-routing eval framework |
| 3 | One defense authored & deployed in REPL | All three families: ModSec (apply / `--remove` / rollback / `apachectl -t` gate), firewall (4 backends APF/CSF/iptables/nftables, CDN-safelist, `--retire <duration>` default 30d), signature (LMD/ClamAV body, FP-corpus deterministic gate + Haiku 4.5 adjudication) |
| 4 | One clean op with diff-shown confirm | All four targets: htaccess, cron, proc, file (quarantine, never delete); backup-before-apply; `--dry-run`; `--undo <backup-id>`; `--unquarantine <entry-id>` round-trip |
| 5 | ≤3:00 demo video | Plus `tests/live/setup-live.bats`, `tests/live/trace-runner.sh`, `tests/live/trace-grader.sh`, and a committed `tests/live/evidence/` capture; demo storyboard + fixture spec live operator-side under `docs/demo/` (gitignored) |
| 6 | README "Why Managed Agents" + "Why Opus 4.7 + 1M" | Plus this PRD, DESIGN.md, and 8 docs/ specifications: `action-tiers`, `case-layout`, `exit-codes`, `managed-agents`, `security-model`, `setup-flow`, `state-schema`, `threat-context` |
| 7 | Zero operator-local data | Verified at every commit; `.git/info/exclude` carries the working-file fence |
| 8 | Submitted by Sun 2026-04-26 16:00 EDT | Submitted on schedule; M13 (Skills primitive realignment) + M14 (cPanel Stage 4 + LMD trigger + unattended) + M15 (live API correctness) shipped post-submission |
| 9 | Steady commit cadence | 26 numbered source parts, 373 BATS tests across 19 files, 9 milestones M0→M15 |

### 14.1 Beyond the MVP — what 0.5.0 ships that wasn't on the original list

- **Bash SDK surface** — 137 reusable `bl_*` primitives across 14
  families (see §5.0.1); other bash tooling can source `bl` and call
  the Managed Agents primitives directly.
- **`install.sh` / `uninstall.sh`** — curl-pipe-bash one-liner, RPM
  `pkg/rpm/blacklight.spec`, DEB `pkg/deb/debian/*`, GitHub Actions
  release workflow at `pkg/.github/workflows/release.yml`, `--prefix`
  / `--keep-state` / interactive state-purge.
- **`bl trigger lmd`** (M14 P7) plus the `bl-lmd-hook` adapter shim. `install.sh` drops the shim into `/etc/blacklight/hooks/`; operator runs `bl setup --install-hook lmd` (per `src/bl.d/84-setup.sh:1146-1216`) to write the `post_scan_hook=` line into `conf.maldet`. `uninstall.sh --yes` reverses the conf wiring.
- **cPanel Stage 4 ModSec userdata** (M14 P8) — `bl observe substrate`
  and `bl_apply_modsec_cpanel` handle ModSec userdata nesting and
  `restartsrv_httpd`.
- **Unattended mode** (M14 P9) — `BL_UNATTENDED=1` (auto-detected when
  no TTY) defers tier-gated steps to the operator queue with
  notification; tier-gate G5 enforces.
- **`state.json` single-source-of-truth** (M14/M15) — replaces six
  per-key files (agent-id, env-id, memstore-skills-id, memstore-case-id,
  case-id-counter, case.current); per-key files retained as fallback
  reads.
- **CAS-versioned agent updates with HTTP 409 retry** (M15 P4) —
  POST `/v1/agents/<id>` with `version` field; concurrent-modification
  surfaces 409, refetches, retries (`bl_setup_update_agent_cas` at
  `src/bl.d/84-setup.sh:774`).
- **Operator-runbook documentation** (M15 P8) — orphan
  `BL_SKILL_ID_*` cleanup procedure, full-stack `BL_LIVE` smoke
  procedure.
- **10 well-defined exit codes** with documented reserved ranges
  (1–63 POSIX, 73–79 future, 80–127 unused, 128+ signal-based) — see
  `docs/exit-codes.md`.

The MVP shipped on schedule. The 0.5.0 codebase is approximately 4× the
surface area the PIVOT-v2 §14 criteria called for.

---

## 15. References

- `DESIGN.md` — implementation spec (command surface, state model, safety
  gates, model calls, API shapes — including the M15-verified live API
  corrections).
- `README.md` — operator-facing pitch and install path.
- `docs/exit-codes.md` — exit-code authority.
- `docs/action-tiers.md` — tier-gate policy authority.
- `schemas/step.json` — `report_step` envelope authority.
- `prompts/curator-agent.md` — curator system prompt.
- `prompts/bundle-summary-system.md` — Sonnet 4.6 bundle summary prompt.
- `prompts/fp-gate-haiku-system.md` — Haiku 4.5 FP-gate prompt.
- `.rdf/archive/legacy/` — superseded planning layer (PRD v1, BRIEF v1,
  PIVOT v1, HANDOFF v1) preserved for git-history continuity.
- `.rdf/archive/docs-internal/PIVOT-v2.md` — strategy + competitive framing
  (informational; v2 architecture has shipped).

---

*GPL v2. R-fx Networks <proj@rfxn.com>. Ryan MacDonald <ryan@rfxn.com>.*
