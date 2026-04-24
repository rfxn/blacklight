# PIVOT v2 — skills-first defensive agent, supercharge-not-replace

**Date:** 2026-04-24 (Friday; Day 4 of 6-day hackathon sprint)
**Supersedes:** `PIVOT.md` (2026-04-23, ratified as direction but overscoped)
**Execution window:** Fri 14:00 CT → Sun 15:00 CT = ~49 hours, ~32 productive hours.
**Status:** This document is canonical for the remaining sprint. All other planning docs (`PLAN.md`, `BRIEF.md`, `PRD.md`, `HANDOFF.md`, `RULES.md`, `docs/workflow-example.md`) are legacy.

---

## 1. The one-sentence pitch

> Attackers have agents. Defenders still have grep.
>
> **blacklight is the defender's counter** — a portable bash wrapper driven by a skills-native Managed Agent that directs fifteen years of battle-tested Linux defensive primitives at the speed attackers now operate. ModSec, APF, CSF, iptables, nftables, LMD, ClamAV, YARA, Apache logs, `.htaccess` walks, crontab audits — all wielded at agent speed, authored from operator-voice skills any defender can read, fork, or extend.
>
> **Man-days to agentic-minutes. Skills are the moat; the agent is the engine; the wrapper is the hands. No new platform. No fleet migration. No analyst retraining.**

The architecture is a direct consequence of this pitch. Anything that contradicts it is out of scope.

---

## 2. Where we are — current state, decomposed

### 2.1 Project inventory (Fri 2026-04-24 14:00)

| Surface | Size / count | Role | v2 disposition |
|---|---:|---|---|
| `LICENSE` (GPL v2) | 18 KB | Legal | **keep** |
| `bl-ctl` | 2 KB | CLI seed | **grow into `bl`** |
| `skills/` (11 dirs, ~18 files) | ~60 KB | Operator-voice knowledge — the moat | **curate + extend to ~20** |
| `curator/` (Python) | ~400 lines | Managed Agents session wiring | **cut — replaced by `bl setup` bash subroutine** |
| `prompts/` (7 files) | ~30 KB | Agent role prompts | **curate to 3: curator, synthesizer, intent** |
| `exhibits/fleet-01/` | scaffolded | PolyShell demo fixture | **keep, finish** |
| `docs/managed-agents.md` | 985 lines | API reference captured 2026-04-23 | **keep** |
| `.gitattributes`, `.gitignore` | small | Release hygiene | **keep** |
| `PLAN.md` | 432 KB | Phase tracker (29/48 phases) | **archive to `legacy/`** |
| `PIVOT.md` | 71 KB | v1 pivot brief | **archive to `legacy/`** |
| `BRIEF.md` + `PRD.md` + `HANDOFF.md` + `RULES.md` | 147 KB total | Overlapping spec layers | **archive to `legacy/`** |
| `docs/workflow-example.md` | 38 KB | Aspirational walkthrough | **archive to `legacy/`** |
| `docs/specs/*` | 4 design docs | Phase planning | **archive to `legacy/` except `managed-agents.md`** |
| `bl-agent/` | stub dir | Fleet daemon (per v1 pivot) | **cut — violates no-rearchitecture pitch** |
| `compose/` | docker compose | Demo scaffolding | **collapse to single root `docker-compose.yml`** |
| `AUDIT.md`, `ALT.md`, `VOICE.md`, `EXHIBITS.md`, `FUTURE.md`, `PROMPTS.md` | ~70 KB combined | Ancillary docs | **archive to `legacy/`** |
| `README.md` | 12 KB | Public face | **rewrite with the pitch as hero** |

**Net v2 starting state: ~12 load-bearing files and directories. Everything else is ceremony, moved to `legacy/` for git-history continuity without contaminating the tree.**

### 2.2 What PIVOT v1 got right

- Naming the asymmetry: AI dossier + ModSec bundle is ~10% of the incident workload. Evidence extraction + cross-substrate deployment + cleanup is the remaining 90%.
- Identifying Managed Agents as architecture, not feature — the curator session *is* the product state, not a nice-to-have.
- JSONL pre-parse + summary-in-context / raw-in-files as the agent-IO discipline.
- Case-tagged action ledger solving the `138.199.46.68`-class retirement problem.

### 2.3 What PIVOT v1 got wrong

- Re-expanded scope the moment it won the scope debate. Four layers, five memory stores, orchestrator, fleet daemon, HTML brief renderer, hot-swap choreography, precedent re-injection demo beat — a platform build, not a sprint deliverable.
- Modeled the incident as a single-host compression event (T+26s collect, T+4m synthesize, T+13m defend) rather than the actual multi-week multi-actor arc with premature closure, post-exploit lag, and cross-CVE layering.
- Lead with the wrapper as secondary to the AI surface. The wrapper IS the product; the AI is the direction.
- Treated remediation as an afterthought. The real PolyShell pain — gsocket cron cleanup, `.htaccess` poisoning removal, argv-spoofed process kills — gets one-line mentions in v1. In v2 it is first-class.
- No "why Managed Agents" or "why 1M context" narrative that a judge can defend. Model-choice architecture was locked but unargued.

---

## 3. Recent findings driving v2

Six observations from the Thursday–Friday adversarial pass:

1. **The real PolyShell arc was five months long before disclosure.** SessionReaper (APSB25-88) was exploiting the MA fleet since October 2025; 1,193 hosts compromised before PolyShell (APSB25-94) was even announced. The team's incident response was archaeology on top of live exploitation, not a fresh response.

2. **Heavy-weight lifts happened in the unglamorous phases.** Fleet scoping across 1,900 MA hosts + ~50 MH hosts; iterative signature authoring (15+ new sigs in a single interval); cross-substrate deployment (Puppet on MA, Ansible on MH, manual SSH on cPanel edge); gsocket implant discovery on Day 14 (should have been Day 1); premature incident closure (IC-5727 closed Mar 20, re-opened Mar 25).

3. **Agent-directed REPL beats batch dossier analysis.** Instead of "collect giant bundle → agent thinks for 4 minutes → writes a report," the right shape is operator-agent conversation: agent prescribes next observation, wrapper runs it, agent revises, wrapper applies defenses, operator holds veto on destructive steps. This matches how IR teams actually worked the incident in Slack, just faster and structured.

4. **Remediation is first-class, not decorative.** The PolyShell cleanup surface includes: removing injected `<FilesMatch>` blocks from `.htaccess`, scrubbing ANSI-obscured crontab entries referencing gsocket binaries in `~/.config/htop/`, killing argv[0]-spoofed `mariadbd`/`lsphp` processes, quarantining webshell polyglots. No existing tool automates these cleanly. A `bl clean` namespace with diff-shown, confirm-gated remediation is the highest-leverage surface the tool can ship.

5. **Skills-over-agents is the Discord signal, and it validates the architecture.** Community feedback consistently favors skills-native frameworks over bespoke agent code. Memory stores as skill-load mechanism at session creation maps perfectly: the curator boots with 20 operator-voice skills mounted read-only, reasons from them, authors defenses using the grammars they teach. Third-party defenders extend by authoring their own skills, not by forking the wrapper.

6. **Supercharge-not-rearchitect is the commercial lock.** Hosting providers will not rip out ModSec, APF, LMD. They WILL drop in a tool that makes those primitives 500× faster to wield. The v1 pivot drifted toward a platform. v2 is a layer — a thin, auditable, API-key-only bash binary that talks to an agent.

---

## 4. The v2 architecture

### 4.1 Three-layer stack (collapsed from v1's four)

```
┌─ Layer A — `bl` on the host (bash 4.1+, curl, awk, jq — ~1000 lines) ────┐
│                                                                           │
│  observe    read-only evidence (logs, fs, cron, proc, htaccess)          │
│  consult    open/attach a case via Managed Agents session                │
│  run        execute a step the agent prescribed (dry-run gated)          │
│  defend     apply a payload the agent authored (ModSec/firewall/sig)     │
│  clean      remediate (htaccess/cron/proc/file) — confirm-gated          │
│  case       show/log/close                                                │
│  setup      workspace preflight + bootstrap (one-time per workspace)     │
│                                                                           │
│  preflight on every invocation: detect seeded workspace; if unseeded,    │
│  advise `bl setup` with one-liner. Zero Python, zero daemons, zero       │
│  services. Single file; exits when done.                                  │
│                                                                           │
└─────────────────────────────────────────────┬─────────────────────────────┘
                                              │ HTTPS + API key (curl)
                                              ↓
┌─ Layer B — Managed Agent session (Anthropic-hosted, Opus 4.7, 1M ctx) ───┐
│                                                                           │
│  agent         bl-curator (created once by `bl setup`)                    │
│  environment   bl-curator-env (apt: apache2, mod_security2, yara, jq,    │
│                duckdb — installed once at env creation)                   │
│  memory store  bl-skills   ~22 operator-voice files, read_only           │
│  memory store  bl-case     hypothesis + evidence + pending steps + results│
│  files         evidence bundles, shell samples, closed-case briefs        │
│  tools         step emission via `bl-case/pending/*.json` (polled async)  │
│                                                                           │
│  no local runtime process. the session lives in the Anthropic workspace. │
│  `bl` reaches it via `curl` + `jq` on every invocation.                   │
│                                                                           │
└─────────────────────────────────────────────┬─────────────────────────────┘
                                              │ step directives
                                              ↓
┌─ Layer C — existing defensive primitives on the host ────────────────────┐
│                                                                           │
│  apachectl, mod_security, APF, CSF, iptables, nftables, LMD, ClamAV,     │
│  YARA, Apache/nginx logs, journalctl, crontab, find, stat, cat -v        │
│                                                                           │
└───────────────────────────────────────────────────────────────────────────┘
```

**Layer A** is one bash file. No daemon, no service, no port listening. Invoked once per operator thought; exits when done.

**Layer B** is one Managed Agents session per case, Opus 4.7, skills mounted, sandbox available for pre-flight.

**Layer C** is what the host already runs. v2 does not install, replace, or wrap new primitives — it directs the existing ones.

### 4.2 What the v1 pivot had that v2 does NOT

- No external orchestrator / Python polling loop on a curator host
- No fleet agent daemon (`bl-agent` is cut)
- No manifest memory store, no fleet memory store, no actions memory store
- No hot-swap choreography — evidence uploads attach at next session wake, not mid-session
- No multi-session hunter dispatch — single curator session does the correlation; 1M context makes this possible
- No HTML brief renderer as primary artifact — the terminal REPL is the demo; the archived brief is a side effect
- No `bl probe` remote attack-surface tester (that is a fleet-scoping tool — explicitly out of scope for v2 per operator ruling)
- No web frontend

### 4.3 Command namespace — `bl`

```
bl observe <what>                    # read-only, auto-runs
  bl observe file <path>             # stat + magic + strings + hash
  bl observe log apache --around <path> --window <N>h
  bl observe log modsec --txn <id>
  bl observe cron --user <u>         # crontab -l | cat -v (reveals ANSI)
  bl observe proc --user <u>         # argv[0] vs /proc/pid/exe mismatch
  bl observe htaccess <dir>          # walk tree, flag injected directives
  bl observe fs --mtime-cluster <path> --window <N>s

bl consult [--new|--attach <case-id>] [--trigger <evidence>]
                                     # open or attach case; get next step

bl run <step-id> [--yes|--dry-run]   # execute named step (agent prescribed)
                                     # --yes skips confirm for low-risk
                                     # --dry-run shows planned action

bl defend <kind> <arg>               # apply agent-authored payload
  bl defend modsec <file>            # apachectl -t + symlink swap + rollback
  bl defend firewall <ip>            # auto-detect APF/CSF/iptables/nft
  bl defend sig <file>               # LMD/ClamAV/YARA with corpus FP-gate

bl clean <kind> <target>             # remediation (diff-shown, confirm-gated)
  bl clean htaccess <dir>            # strip injected directives
  bl clean cron --user <u>           # strip rogue entries
  bl clean proc <pid>                # capture /proc snapshot, then kill
  bl clean file <path>               # move to quarantine + manifest entry

bl case <verb>                       # lifecycle
  bl case show
  bl case log                        # full observation + action ledger
  bl case close
```

Six namespaces, ~18 subcommands. Each is a bash function, 20–80 lines. All deps are `curl`, `awk`, `sed`, `grep`, `tar`, `gzip`, `jq`.

### 4.4 The agent-directed REPL — action tiers

| Tier | Examples | Gate |
|---|---|---|
| **Read-only** | `observe *`, `bl consult` | auto-execute |
| **Reversible, low-risk** | `defend firewall <ip>` (new IP block), `defend sig` after corpus-FP-pass | auto-execute + notify; 15-min operator veto window |
| **Reversible, high-impact** | `defend modsec` (new rule) | suggest → operator approves |
| **Destructive** | `clean *`, `defend modsec --remove` | diff shown, explain-before-confirm, explicit `--yes` required |
| **Unknown** | any bash command the agent proposes that doesn't map to a known verb | deny by default; operator unlocks with `bl run <id> --unsafe` |

---

## 5. Why Managed Agents — the narrative

Every defensive IR tool since 2005 has been a stateless batch analyzer. You submit logs, you get a report. Follow-up requires another batch. There is no running investigator, no case continuity, no place where "I'm mid-investigation, new evidence just arrived, incorporate it" is a first-class operation. SIEMs correlate at query time; SOAR runs playbooks but does not reason; AI-SOC products wrap LLM calls around tickets without persistent state.

**Managed Agents changes that shape.** A session is a running investigator — alive for days, responsive to events, accumulating state, hot-swappable to new evidence. That is architectural. It is not an implementation detail you could replicate with a cron job plus a database, because:

**1. The case IS the session.** Opening a case boots a curator session with `bl-skills` and `bl-case` memory stores mounted. Seven days later, the session is still alive and has read every hypothesis revision, every evidence summary, every defensive-hit record. When evidence arrives on day 5, the investigator extends — it does not restart, does not re-derive context, does not lose the thread. Container-state checkpointing (30-day retention) and session resumability make this the first primitive where a multi-day investigation is a first-class concept instead of a workflow simulation.

**2. Skills are files, not prompt strings.** `bl-skills` is a read-only memory store mounted at session creation. 20 operator-voice markdown files — IR playbook, webshell families, ModSec grammar, APF grammar, YARA rule templates, false-positive patterns, hosting-stack anatomy, Linux persistence patterns, kill-chain reconstruction, IP clustering, URL pattern extraction, file pattern extraction. The agent reads them as regular files; edits to a skill propagate to the next session without code deploy. A third-party hosting provider contributes a new skill via PR, it ships as a memory-store update. The skills *are* the programmable surface — this is exactly the shape Discord feedback is asking for, and Managed Agents is the only primitive that delivers it today.

**3. Pre-flight validation happens in the agent's own sandbox.** The curator's environment is provisioned with `apache2 + libapache2-mod-security2 + modsecurity-crs + yara + jq + duckdb`. When the agent authors a ModSec rule, the *agent itself* runs `apachectl -t` against its own config tree before promoting the rule to `bl-actions/pending/`. Tokens saved on iteration; operator time saved on bad rules reaching the fleet. No external validator service needed; no cross-machine handoff; no drift between "what the agent thought the rule would do" and "what apache would accept."

**4. The event stream IS the operator surface.** Every `tool_use`, every `thinking` span, every file mount, every structured-output emit is a bidirectional SSE event. The demo UI is literally `curl .../events | jq .` with light rendering. No custom frontend, no event-bus infrastructure, no pub/sub fabric. The session's observable state is the session itself. For a 3-minute hackathon demo this means: the operator runs `bl consult`, the event stream renders in a side pane, the judges see Opus reasoning + tool-calling + memory writes in real time. That is a demo that is also an architecture diagram.

**5. Workspace-scoped, commercially.** Sessions, skills, cases, evidence, deliverables all live in the workspace that authored them. A hosting provider deploying blacklight has their own workspace with their own skills extensions, their own case archive, their own fleet precedent. Zero multi-tenant engineering from us. The commercial boundary is enforced by the platform for free.

**6. Hot-swap for mid-investigation evidence.** Files can attach to a running session via `sessions.resources.add`. Memory stores cannot (attach-at-creation only). This distinction is load-bearing: structured case state lives in memory stores (never changes shape during a session), raw evidence lives as files (arrives unpredictably, must be absorbable without tearing down context). The v1 pivot called this out correctly; v2 preserves it.

**7. The prize brief literally names this.** *"Best Use of Claude Managed Agents ($5,000)"* asks for **meaningful, long-running tasks — not just a demo, but something you'd actually ship.** A seven-day IR case that maintains state across sessions, reads prior-case precedent via Files, and closes by archiving a permanent PDF brief that the next case reads as context — that is the definition verbatim. blacklight wins this prize not as a feature check but as a structural match.

**8. Operator self-bootstrap over the public API, in bash.** The agent record, environment, memory stores, and seeded skills all provision idempotently via the public Managed Agents API from a bash script the operator can audit line-by-line. `bl` preflight-detects an unseeded workspace on every invocation (one cheap `GET /v1/beta/agents?name=bl-curator`); if missing, it points to `bl setup` with a copy-pastable one-liner. One-time cost per workspace; every subsequent host invoking `bl` against the same API key finds the scaffolding ready and skips setup entirely. No curator-host to stand up. No service account to provision. No Python. The OSS repo IS the bootstrap — `curl | bash -s setup` from a clean host works, and reading the setup source is an operator-doable audit. This is the commercial shape the GPL-v2 OSS adopter class can justify, and the shape that keeps "one bash file and an API key" literally true.

---

## 6. Why Opus 4.7 + 1M context — the narrative

IR reasoning is correlation-heavy. "This URL-evasion variant on day 2 is the same actor as the .inc probing on day 4" is not a retrieval query — it is a pattern observation that only emerges when the reasoner can see both pieces of evidence simultaneously. At 200K context (Sonnet 4.6's ceiling), you are forced to chunk, summarize, retrieve. Retrieval-augmented reasoning is fine for Q&A; it is wrong for forensics. A retriever that picks "top 5 evidence items" will miss the one that matters precisely because it does not look relevant in isolation. Attribution requires the whole view.

**1M context changes the reasoning shape.** Our budget:

| Surface | Approximate tokens |
|---|---:|
| `bl-skills` memory store (20 files, ~40 KB markdown) | ~10,000 |
| `bl-case/hypothesis.md` + `history/` (17 revisions) | ~20,000 |
| `bl-case/evidence/*` (42 bundles, pointers + previews) | ~30,000 |
| Raw evidence excerpt (current turn, JSONL, pre-summarized) | ~10,000–30,000 |
| Prior-case precedent (1–3 archived briefs mounted) | ~10,000–30,000 |
| System prompt + tool definitions | ~3,000 |
| **Total per turn (hot case, mid-investigation)** | **~85,000–120,000** |

That is 8–12% of the 1M window. The curator reads the whole case on every wake. No retrieval layer. No chunking protocol. No summary-of-summary drift. The forensic correlation Opus 4.7 was trained to produce happens against the full case, not against a retriever's best-effort top-K.

**Why this matters specifically for our surface:**

**1. Cross-evidence correlation is the reasoning task.** The PolyShell incident had two non-overlapping attacker clusters (custom_options actors and customer_address actors, zero IP overlap) operating the same family of vulnerabilities across 97 hosts. That insight — "these are two campaigns, not one" — only falls out with both IP sets in view. A retriever that picks "most-recent 5 IPs" or "highest-confidence IPs" would smear them together.

**2. Hypothesis revision is calibrated-reasoning work.** Opus 4.7's adaptive thinking (`thinking: {type: adaptive, display: summarized}`, depth via `output_config.effort`) budgets reasoning to problem shape: a major revision (day 5 vector pivot) gets deep thinking; a rotated-IP confirmation gets shallow. `budget_tokens` is retired in 4.7; the model handles the budget internally. This is the behavior Opus 4.7 was specifically trained for — hypothesis revision with confidence calibration, not a decorative overlay.

**3. Structured output via `output_config.format` + json_schema.** Opus 4.7 only: rejects forced `tool_choice` with thinking on (HTTP 400, verified 2026-04-22), so we use `output_config.format = {type: json_schema, ...}`. The synthesizer returns a schema-valid `{rules: [...], firewall_actions: [...], sigs: [...]}` object directly — no regex-scraping model output, no fallback to "please return JSON" cajoling. This is the load-bearing primitive for the defensive payload authoring surface. Sonnet 4.6 supports `tool_use` output shaping but not the same json_schema discipline on free-form content.

**4. Prompt caching amortizes the window.** Automatic 5-minute TTL, Anthropic-side. The skills corpus (~10K tokens) is cached after the first read. The stable case history (~30K tokens) is cached across consecutive turns. Only the new evidence delta in this turn is uncached (~5–30K). A long-running case gets *cheaper* per turn, not more expensive. This is the primitive that makes the "one curator session per case" architecture economically sane.

**5. Sandbox tool-use integrates at native speed.** The curator runs `apachectl -t`, `jq`, `awk`, `duckdb` inside its Ubuntu 22.04 sandbox via the built-in `bash` tool. No cross-network round-trip to an external validator. Opus 4.7's tool-use is the current SOTA on reliable tool orchestration — chains bash → file-read → write-memory-store → thinking → tool-call without breaking structure.

**Sonnet 4.6 could fake parts of this at 200K:** aggressive chunking, external retriever, manual summary-refresh logic. That is 2–3 days of additional engineering to ship sub-par correlation. **Opus 4.7 + 1M makes the architecture one-shot.** The model choice is the system design. That is the defense the README's "Why these models" section carries — specific, measurable, non-generic.

### 6.1 Model assignments (confirmed)

| Role | Model | Features |
|---|---|---|
| Curator (the case-owning session) | Opus 4.7 | 1M context, adaptive thinking, Managed Agents session, all 20 skills loaded |
| Synthesizer (defense authoring call) | Opus 4.7 | structured output via `output_config.format` json_schema, no forced `tool_choice` with thinking |
| Intent reconstructor (shell analysis) | Opus 4.7 | extended thinking, runs against specific shell-sample files |
| Hunter (optional parallel dispatch) | Sonnet 4.6 | cheaper, faster, forced `tool_choice`, thinking off — used only when correlation scope exceeds the curator's turn budget |

Most v2 sessions run curator-only. Hunter parallelism is available but not load-bearing.

---

## 7. The skills architecture — the moat

### 7.1 Structure

```
skills/                               (mounted as bl-skills memory store, read_only)
├── INDEX.md                          (routing: what skill addresses what question)
├── ir-playbook/
│   ├── case-lifecycle.md             (when to open, revise, close)
│   └── kill-chain-reconstruction.md  (upload → exec → persist → lateral → exfil)
├── webshell-families/
│   └── polyshell.md                  (GIF89a polyglots, v1auth + v2sys variants)
├── defense-synthesis/
│   ├── modsec-patterns.md            (phase:1 vs phase:2, rule ID conventions, exception idiom)
│   ├── firewall-rules.md             (APF/CSF/iptables/nft cross-syntax + CDN-safe-list pattern)
│   └── sig-injection.md              (LMD rfxn.{hdb,ndb,yara}, ClamAV, YARA — FP-gate protocol)
├── false-positives/
│   ├── backup-artifact-patterns.md
│   └── vendor-tree-allowlist.md
├── hosting-stack/
│   ├── cpanel-anatomy.md             (domlogs, suphp, per-user dirs)
│   └── cloudlinux-cagefs-quirks.md
├── ic-brief-format/
│   ├── severity-vocab.md
│   └── template.md
├── linux-forensics/
│   ├── persistence.md                (cron/.bashrc/systemd/argv[0]-spoofing/gsocket patterns)
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
├── ioc-aggregation/                    [v2 additions — NEW]
│   ├── ip-clustering.md                (scanner / persistence / CDN-collateral buckets)
│   ├── url-pattern-extraction.md       (evasion variants → generalized regex)
│   └── file-pattern-extraction.md      (magic bytes, dimension fingerprints, yara synthesis)
```

**Total: ~22 files.** Floor of 20 maintained. The 3 new `ioc-aggregation/` files are authored from the PolyShell incident's lived evidence — they carry the clustering, pattern-extraction, and fingerprinting disciplines that produced the final rule/signature shape.

### 7.2 Authoring discipline (inherited from v1, non-negotiable)

Each operator-voice skill:
- Opens with a scenario from lived experience, not a definition.
- States the non-obvious rule — something a competent IR analyst who has not worked at this scale would get wrong.
- Gives one concrete example drawn from public APSB25-94 material, never operator-local.
- Names a failure mode and how the rule handles it.
- Assumes operator literacy. The value is the *judgment*, not the *dictionary*.

**If the only available draft would be generic IR/SOC boilerplate, flag the gap and land the file later — never ship slop.**

### 7.3 Third-party extensibility (the commercial story)

A defender running DirectAdmin or Virtualmin drops their own `skills/directadmin/` subtree into their memory store. The curator reads it on the next session wake. New vocabulary available; zero wrapper-code change; zero agent retraining. This is the "skills-over-agents" pattern Discord is asking for, delivered on day one because Managed Agents' memory-store mounting *is* the skill-loading mechanism. `bl-skills` is read-only to the agent (kernel-enforced — cannot be overwritten by attacker-reachable log content); skills edits happen via the Memories API from a trusted admin path.

---

## 8. Competitive positioning — platform-free agentic defense

The Mythos-class offensive narrative is one half of the frame. The other half is what the defensive incumbents offer today — because the judging question is not only *"is there a threat?"* but *"is there not already a defensive answer?"* There is an answer. It addresses a different market than blacklight's. Naming the gap explicitly is how the positioning locks.

### 8.1 The Charlotte-class constraint

The first wave of agentic defensive tooling — **CrowdStrike Charlotte AI** (bound to the Falcon EDR/XDR sensor), **Microsoft Security Copilot** (bound to Sentinel + Defender + M365 E5), **Google SecLM / Duet for Security** (bound to Chronicle), **Palo Alto Purple AI** (bound to Cortex) — shares a single structural constraint: **the operator must be inside the vendor platform before the agent is available.** The agentic capability is a feature of the platform, not a layer over existing defensive primitives. This is not accidental; it is the commercial shape of EDR/XDR. The sensor is the product; the AI assistant is the upsell.

The operational profile of adopting one:

| Barrier | Typical cost |
|---|---|
| Platform onboarding (sensor/agent rollout fleetwide) | 3–18 months |
| Per-endpoint licensing | $75–$250/host/year (Falcon Complete class: higher) |
| SIEM / SOAR / identity-provider integration work | Platform engineering team, quarters of effort |
| Analyst retraining on platform vocabulary, DSLs, playbooks | Weeks to months |
| Custom detection authoring in platform DSL | Ongoing operational burden |
| Lock-in on platform signatures, detections, runbooks | Permanent; migration cost compounds |

The agent quality on these platforms is genuinely good. The reasoning layer is not the bottleneck. **The bottleneck is platform reach.**

### 8.2 The hosts Charlotte will never reach

The OSS Linux security stack has a fifteen-year installed base that is structurally out of commercial reach for enterprise agentic tooling:

| Primitive | First release | Approximate installed base |
|---|---:|---|
| iptables / netfilter | 1998 | effectively every Linux server since 2.4 |
| Apache `mod_security` WAF | 2002 | millions of web-facing hosts |
| ClamAV | 2002 | millions (hosting, mail, storage) |
| APF *(R-fx Networks)* | 2002 | hundreds of thousands |
| fail2ban | 2004 | millions |
| OSSEC / Wazuh | 2004 | hundreds of thousands |
| CSF (ConfigServer) | ~2006 | hundreds of thousands (cPanel fleets) |
| YARA | 2008 | ~universal in serious DFIR shops |
| LMD / maldet *(R-fx Networks)* | 2009 | hundreds of thousands |
| nftables | 2014 | modern distros by default |
| BFD *(R-fx Networks)* | ~2005 | tens of thousands |

These primitives run on:
- Hosting providers (shared, VPS, managed Magento, cPanel / DirectAdmin / Plesk / InterWorx fleets)
- MSPs managing customer Linux estates
- Indie sysadmins, solo operators, homelabs, academic CS infra
- Small-to-medium businesses running Linux-based SaaS
- Anywhere $150/endpoint/year is 10× the monthly margin on the customer account

Charlotte AI cannot reach them — not because CrowdStrike does not want the market, but because **the platform-first commercial shape cannot bend that low.** The defenders of these hosts still wield these tools by hand, at human speed, in a world where attackers wield Mythos-class agents at machine speed. That is the asymmetry blacklight is built for.

The order-of-magnitude gap: **on the order of hundreds of millions of Linux hosts globally** run OSS defensive primitives and cannot economically justify enterprise agentic tooling. Their defenders are the market Charlotte cannot serve.

### 8.3 How blacklight closes the gap

blacklight is the defensive primitive-supercharger designed to exactly the shape of that install base:

| Dimension | Charlotte-class enterprise | blacklight |
|---|---|---|
| **Platform dependency** | Falcon / Sentinel / Cortex / Chronicle sensor on every endpoint | none |
| **Deployment time** | 3–18 months fleetwide | ~30 seconds per host (`curl \| bash -s setup` then `bl`) |
| **Licensing** | $75–$250/endpoint/year + platform SKUs | GPL v2, zero license cost; operator pays only Anthropic API usage |
| **Operator vocabulary** | Vendor DSL, platform-specific playbooks and detections | Existing operator vocabulary (`iptables`, ModSec conf, `crontab -l`, `maldet --scan`) |
| **Analyst retraining** | Weeks to months | Zero — `bl observe cron --user x` is what they would have typed anyway |
| **Extensibility surface** | Platform-specific rule authoring, often paid tier | Fork the repo, drop in a markdown skill, done — GPL |
| **Lock-in** | Per-vendor, migrations costly | Zero — skills and wrapper are GPL; the model layer is API-swappable in principle |
| **Works when the vendor platform is down** | No | Yes — `bl observe` is local bash; the agent is only the direction |
| **Runs on CentOS 6 / RHEL 7 / Debian 10 / older distros** | Rarely supported | Yes — bash 4.1 + `curl` is the floor |
| **Commercial compatibility with $10/mo customer margins** | No | Yes |
| **Auditable in 30 minutes by the operator** | No (closed platform) | Yes (single bash file + ~22 skills markdown) |

blacklight does not compete with Charlotte on enterprise accounts. **It addresses the market Charlotte cannot reach.** Hosting providers running 10,000 Linux hosts on $50/month shared-hosting margins have no enterprise-agentic option today; their incident response is a human reading `grep` output at 04:27 AM. blacklight is the first agentic tool whose commercial shape is compatible with that reality.

### 8.4 The twin-narrative positioning

The two narratives now compose cleanly into one:

> **Offensive AI is here. Mythos-class tools compress vuln-to-weaponized-exploit from weeks to hours. Defenders running enterprise platforms have an answer: Charlotte, Copilot, Purple, SecLM. Defenders running the OSS Linux security stack — iptables, mod_security, ClamAV, LMD, APF, YARA, the primitives that have defended hundreds of millions of hosts for fifteen years — do not. Their incident response is still manual at a moment when the threat is not.**
>
> **blacklight is the defender's counter for that market.** It drops into the fifteen-year Linux compatibility matrix without asking anyone to buy a platform, migrate a fleet, retrain an analyst team, or wait on an enterprise sales cycle. It supercharges the primitives those operators already trust with a skills-native Managed Agent authored from lived incident response. **No ecosystem buy-in. No operational momentum loss. No substrate change. Man-days of response become agentic-minutes — on the substrate the defender already owns.**

### 8.5 Compounding effect — R-fx Networks as the substrate vendor

For the named-adopter class (LMD / APF / BFD users), blacklight is not an external tool to evaluate against Charlotte. **It is the natural next release in a product family they have trusted for two decades.** The agentic-defensive era arrives as a feature of the Linux OSS security stack they have been running since 2002 — shipped by the organization that built a meaningful share of that stack. That is the structural moat enterprise vendors cannot match: Charlotte can replicate the reasoning quality given time, but it cannot retroactively acquire twenty years of sysadmin trust in LMD, APF, and BFD as the foundation layer. **blacklight lands the agentic era on top of that trust, not alongside it.**

---

## 9. Scope — what IS and IS NOT v2

### 9.1 MUST ship (Friday PM → Saturday PM, ~29h)

| # | Item | Est. | Notes |
|---|---|---:|---|
| 1 | `legacy/` archive move; clean-branch commit | 1h | scorched-earth, one commit |
| 2 | `DESIGN.md` (this document, trimmed to ≤5 KB as operator-facing spec) | 1h | open with pitch; body = namespace + REPL |
| 3 | `README.md` rewrite — pitch hero, namespace, "Why these models", "Why Managed Agents", "Skills architecture" | 3h | judge-skim optimized |
| 4 | `bl` bash wrapper — all six runtime namespaces, ~18 subcommands | 10h | one file, ~1000 lines |
| 5a | `bl setup` — workspace preflight + agent/env/memory-store/skills provisioning | 4h | bash; idempotent; `bl setup --sync` diff-and-push for deltas |
| 5b | `bl` session-wire subroutines — memory-store polled step-emit pattern | 3h | bash; async via `bl-case/pending/*.json`; no SSE plumbing |
| 6 | `bl-skills` seeding + ioc-aggregation/ × 3 authored | 3h | curate existing; author new |
| 7 | PolyShell exhibit finish (`exhibits/fleet-01/`) | 2h | one host + one evidence bundle + one shell sample |
| 8 | End-to-end smoke on clean Ubuntu 24.04 | 2h | operator types `bl consult --new` → rides loop |

**MUST total: ~29h.** Fits Friday evening through Saturday early afternoon.

### 9.2 SHOULD ship (Saturday PM, ~10h)

| # | Item | Est. | Notes |
|---|---|---:|---|
| 9 | `bl clean` remediation round-trip (htaccess + cron + proc + file) | 4h | this is the operator-love surface |
| 10 | Case archival (`bl case close` → brief to Files, precedent pointer) | 2h | closes Managed Agents prize narrative |
| 11 | CentOS 7 smoke-test fallback | 1h | portability credibility |
| 12 | Demo recording (first take) | 3h | Saturday 22:00 CT non-negotiable |

**SHOULD total: ~10h.**

### 9.3 Explicitly cut from v1 pivot

- Fleet daemon (`bl-agent` as a service) — **cut**
- External orchestrator Python loop polling pending actions — **cut**
- Five memory stores (bl-manifest, bl-fleet, bl-actions, bl-archive) — **collapse to 2: `bl-skills`, `bl-case`**
- Hot-swap mid-session file ingestion choreography — **cut** (files attach at session-wake boundary; good enough)
- HTML brief renderer as primary artifact — **cut** (terminal REPL is the demo)
- Multi-agent `callable_agents` dispatch — **cut** (1M context makes single-session correlation viable)
- `bl probe` remote attack-surface tester — **cut** (fleet-scoping; different product)
- `bl status` dashboard — **cut** (`bl case show` covers)
- Separate hunter sessions per domain (fs/logs/timeline) — **cut** (curator absorbs)
- Demo Beat A operator-CLI overlay + Beat B cold-open re-injection as separate beats — **collapse** (the REPL itself is both)

### 9.4 Deferred to FUTURE.md

- Fleet posture signal (`bl-fleet-health` as 6th memory store) — real but out-of-sprint
- Auto-reopen heuristic (T+5d silent verify on closed cases) — real but out-of-sprint
- Cross-tenant threat intelligence — post-MVP
- Outcome-driven synthesizer via `user.define_outcome` + rubric — research-preview gated
- Manifest retirement / rotation — v1 pivot scope, now a roadmap item
- Role-swap substrate (auditor / abuse / migration modes) — roadmap

---

## 10. Timeline — Friday 2026-04-24 14:00 CT → Sunday 2026-04-26 15:00 CT

All times CT. Submit deadline **Sun 2026-04-26 15:00 CT = 16:00 EDT** (4h buffer before 20:00 EDT hard cap).

### 10.1 Friday 2026-04-24

- **14:00–15:00** — scorched-earth commit: move everything in §2.1 disposition=archive to `legacy/`. One commit: `[Change] prune to primitive file set — PIVOT v2 rewrite base`.
- **15:00–17:00** — write `DESIGN.md` (trimmed from this doc to ≤5 KB) + `README.md` hero section with Draft B pitch + skills architecture section + "Why these models" section + "Why Managed Agents" section.
- **17:00–20:00** — curate `skills/`. Keep the 19 existing files. Author the 3 new `ioc-aggregation/` files from PolyShell material. Update `skills/INDEX.md`.
- **20:00–22:00** — begin `bl` bash wrapper: `bl observe *` namespace (7 subcommands, read-only, auto-runs). Test each against a local fixture.
- **22:00** — stop for sleep. Hypothesis-revision unit test (if already in flight pre-pivot) is irrelevant in v2; the single-curator design does not require it.

### 10.2 Saturday 2026-04-25

- **08:00–12:00** — finish `bl` bash wrapper: `consult`, `run`, `defend`, `clean`, `case` namespaces. Test each against live Anthropic API.
- **12:00–14:00** — `curator/` refactor: single Managed Agents session. Memory stores `bl-skills` (read-only, seeded) + `bl-case` (read-write). Three tools exposed to curator: `beacon_observe`, `beacon_defend`, `beacon_clean`, each writing step records. Session event-stream handler.
- **14:00** — **GO / NO-GO gate.** If `bl consult → curator reasons → bl run → curator revises` round-trip is not working end-to-end against the PolyShell exhibit, abort v2 rewrite and fall back to pre-pivot V5 build (already has 29/48 phases on pre-pivot branch). Sunday becomes polish day, not rescue day.
- **14:00–18:00** — integration + smoke test on the PolyShell exhibit. Operator rides the loop: trigger maldet hit → `bl consult --new` → agent walks the incident → `bl clean cron` cleanup → `bl defend modsec` apply → case closed.
- **18:00–22:00** — README polish. Exhibit polish. Demo script.
- **22:00** — **First full demo recording.** CLAUDE.md locks this as non-negotiable; v2 preserves it.

### 10.3 Sunday 2026-04-26

- **08:00–12:00** — reshoot demo if Saturday's didn't land. Polish. `docker compose up` cleanroom verification.
- **12:00–13:00** — write the 100–200 word submission summary (per workspace rule: after final video lock).
- **13:00–14:00** — Submission package: repo link + video URL + summary.
- **14:00–15:00** — Submission QA. Fresh clone. API-key-only operation verified. No operator-local data leaked (grep for `cloudhost-`, `lb1`, `nxcli.net`, customer tokens → zero hits).
- **15:00** — **Submit.**

---

## 11. Why the pitch matches the architecture (consistency audit)

A test of v2: every pitch claim maps to an architectural decision, and every architectural decision supports a pitch claim.

| Pitch claim | Architectural decision |
|---|---|
| "One bash file and an API key" | Net runtime dep tree: bash ≥ 4.1, `curl`, `awk`, `jq`, `grep`, `sed`, `tar`, `gzip`. Zero language runtimes of our own on any host. `bl setup` is bash. `bl` runtime is bash. The agent lives in Anthropic's workspace — nothing local to run. |
| "Portable bash wrapper" | Single bash file, deps `curl + awk + jq + grep`, CentOS 6 / bash 4.1 floor |
| "API-key only" | Only auth surface is `$ANTHROPIC_API_KEY`; no service discovery, no cert management, no account provisioning |
| "Skills-native Managed Agent" | `bl-skills` memory store mounted read-only at session create; 22 operator-voice files; third-party extensible |
| "15 years of defensive primitives" | Native ModSec / APF / CSF / iptables / nftables / LMD / ClamAV / YARA — no wrapping, no re-abstraction |
| "Man-days to agentic-minutes" | Agent-directed REPL vs batch dossier analysis; parallel defense authoring; automatic case continuity |
| "No new platform" | Zero daemons, zero services, zero databases of our own; `bl` is stateless; all state lives in Managed Agents |
| "No fleet migration" | v2 tool is single-host; fleet propagation rides existing customer Puppet/Ansible; we do not own deployment |
| "No analyst retraining" | Namespace is operator vocabulary (`observe / defend / clean`); skills carry the judgment; the operator types what they'd type anyway |
| "Always-on at the trigger boundary" | `bl consult` invoked by existing maldet inotify / auditd / ModSec critical hook; no polling loop |
| "Skills are the moat" | Skills authored from lived IR; extensible by defenders; Managed Agents loads them as the programmable surface |

No claim floats. No architecture element is unjustified.

---

## 12. Risks + mitigations

| Risk | Probability | Mitigation | Owner |
|---|---|---|---|
| Rewrite runway overshoot | Medium | 14:00 Sat go/no-go; fallback to pre-pivot V5 if REPL not working | Operator |
| Managed Agents beta surface changes | Low | `docs/managed-agents.md` frozen at 2026-04-23; re-verify memory-store attach semantics Fri AM | Claude |
| Apachectl in sandbox fails | Medium | Pre-provision `bl-curator-env` Fri 18:00; measure install time; cache | Claude |
| Corpus FP-gate compute time | Low | Use a smaller benign corpus (~1,000 PHP files) for demo; real 166K lives in FUTURE.md | Claude |
| Demo pacing unclear on first cut | Medium | Sat 22:00 record is non-negotiable; Sunday AM reshoot slot reserved | Operator |
| Clean-room concern on `polyscope-*.sh` absorption | Low | v2 drops the absorption path; `bl observe` is clean-written from spec, not derived | Claude |
| Scope creep inside the sprint | Medium | SHOULD items only if MUST landed cleanly; COULD is `FUTURE.md` | Operator |

---

## 13. What doesn't change

- **License**: GPL v2. `LICENSE` at root.
- **Project name**: blacklight. Repo: `rfxn/blacklight`. CLI: `bl`.
- **Zero runtime Python, anywhere.** `bl setup` and `bl` are the only executables; both are bash. Operator workstation has no Python dependency; fleet host has no Python dependency. The only language runtime in the stack is the one inside Anthropic's Managed Agents sandbox, which we do not operate.
- **Skills bundle**: ≥20 operator-voice files. Floor preserved and extended.
- **Model assignments**: Opus 4.7 on curator/synth/intent with adaptive thinking + json_schema output. Sonnet 4.6 available for hunter parallel dispatch (not load-bearing in v2).
- **Managed Agents** as architecture, not feature. Curator is a Managed Agent.
- **Submission deadline**: 2026-04-26 16:00 EDT, 4h buffer.
- **Demo runtime**: 3:00 hard cap.
- **Commit hygiene**: descriptive messages, no `Co-Authored-By`, no Claude/Anthropic attribution in source.
- **Reference data rule**: no operator-local content in the repo. Exhibits reconstruct from public APSB25-94 material only.
- **Named adopter class**: LMD / APF / BFD user base. Hosting providers. MSPs.

---

## 14. Success criteria

v2 is successful at submission if:

1. **`bl consult --new --trigger <sample>` on a fresh Ubuntu 24.04 produces a live REPL with a Managed Agents curator session** — architecture validated.
2. **The curator reads at least 3 skills during the session and cites them in its reasoning** — skills-native claim validated.
3. **At least one defense is authored and deployed in the REPL** (`defend modsec` or `defend firewall` or `defend sig`) — defensive-payload surface validated.
4. **At least one `clean` operation (htaccess or cron) runs with diff-shown confirm** — remediation surface validated.
5. **Demo video ≤ 3:00 shows the above end-to-end** — submission complete.
6. **README carries "Why Managed Agents" and "Why Opus 4.7 + 1M" sections grounded in specific primitives** — prize positioning complete.
7. **Zero operator-local data in the repo** (grep clean for `cloudhost-`, `nxcli.net`, customer tokens).
8. **Submitted by 2026-04-26 15:00 CT** (4h buffer).
9. **Git history shows Friday-Saturday-Sunday commit cadence** — demonstrable-work signal.

---

## 15. Immediate next actions (if ratified Fri 14:00)

1. Operator: **ratify v2** (or push back inline with specific cuts/adds).
2. Claude: **scorched-earth branch commit** — move v1 planning docs to `legacy/`, preserve `skills/`, `curator/`, `prompts/`, `exhibits/`, `bl-ctl`, `docs/managed-agents.md`.
3. Claude: **`DESIGN.md` + `README.md` draft** with pitch as hero + Why Managed Agents + Why Opus 4.7 + Skills architecture sections.
4. Claude: **`bl observe` namespace** begins Friday evening.
5. Operator: **spot-check skills/INDEX.md** to confirm the 22-file roster lands operator-voice, no slop.
6. Operator: **Slack a one-line go/no-go commitment to v2** so Saturday's 14:00 gate is procedural, not debated.

---

## 16. Appendix — commit plan

Descriptive messages; no `Co-Authored-By`; no Claude/Anthropic attribution.

```
1. [Change] archive v1 planning layer to legacy/ — PIVOT v2 rewrite base
2. [New] DESIGN.md + README hero — skills-first defensive agent framing
3. [New] bl observe namespace — read-only evidence extraction (file/log/cron/proc/htaccess/fs)
4. [New] bl consult — Managed Agents session create/attach + trigger intake
5. [New] bl run + bl defend + bl clean — agent-directed execution with tier gates
6. [New] bl setup + bl session-wire — bash workspace provisioner + memory-store polled step-emit pattern (no Python)
7. [New] skills/ioc-aggregation/* — ip-clustering, url-patterns, file-patterns (operator-authored)
8. [Change] skills/INDEX.md — v2 roster
9. [New] exhibits/fleet-01/polyshell-v1auth/ — public-safe incident fixture
10. [Change] README — Why Managed Agents + Why Opus 4.7 + 1M sections
11. [New] docker-compose.yml (root) — demo fixture only
12. [Change] README + demo/script.md — v2 narrative
```

---

## 17. Roadmap — post-hackathon

The hackathon ships the foundational node. Everything below extends that node into a product line without violating the "supercharge-not-rearchitect" pitch.

### 17.1 Phase P1 — stabilization + community release (Weeks 1–4 post-submission)

- Public GitHub release under `rfxn/blacklight` with GPL v2, operator-facing `README.md`, community `CONTRIBUTING.md`, skill-contribution issue template.
- First external operator trial: target one hosting provider beta (MSP class) running against a real CVE drop.
- `skills/` schema documented — frontmatter convention, scenario-first discipline, citation requirements, FP-gate expectations for defense-synthesis skills.
- `docker compose up` clean-room install path tested on Ubuntu 20/22/24, Rocky 9, Debian 12, CentOS 7.
- Exit gate: external operator runs a PolyShell-class incident through the loop without operator-of-record intervention; their own workspace accumulates case precedent.

### 17.2 Phase P2 — posture arc + cross-case intelligence (Months 2–3)

- `bl-fleet-health` memory store added (6th total): weekly posture sweep reads host-level indicators from `bl observe` outputs, flags trajectory changes (the SessionReaper-style "101 → 782 → 3,186 monthly hit growth nobody noticed").
- Auto-reopen heuristic: closed case runs a T+5-day silent verify sweep; non-zero hits reopens the case without operator. This directly closes the IC-5727 premature-closure pattern from the real PolyShell incident.
- Retrospective compromise sweep: `bl observe fs --mtime-since <cve-disclosure-date>` + `bl consult --sweep-mode` for "we just learned about this CVE, what's on disk already."
- Precedent re-injection surface: `bl consult` on a new case auto-surfaces relevant archived briefs from `bl-case` by family/CVE/platform tag and mounts them as Files for curator reading.
- Skills additions: `post-exploit/linux-persistence.md` promoted to standard (gsocket + argv spoofing + ANSI-obscured cron as canonical); `posture/fleet-health-signals.md` authored.
- Exit gate: second hosting provider onboard; 5+ community-contributed skills; first cross-case precedent-cite event in production.

### 17.3 Phase P3 — fleet propagation + multi-tenant (Months 3–6)

- `bl watch` systemd-oneshot mode for continuous posture (reads existing trigger infra: inotify, auditd, ModSec critical hook; not a daemon).
- Multi-workspace provisioning patterns for MSPs running multiple customer fleets: per-customer memory stores, per-customer skills overlays, per-customer case isolation — all native to Managed Agents workspace semantics.
- `bl probe` promoted from cut-list to Phase-3 feature: remote attack-surface validator (scoped to CVE class), runs as a scheduled task.
- Signature distribution orchestration: `bl sig ship` pattern for pushing FP-gated sigs across fleet via the customer's existing deployment primitive (Puppet, Ansible, Salt, Chef) — we generate the manifest, they propagate.
- Manifest retirement / rotation: ledger-driven, triggered by case close + T+30-day no-match; never rule-driven.
- Exit gate: 10+ hosting providers; 25+ community skills; 100+ active cases per month in aggregate across the installed base.

### 17.4 Phase P4 — platform breadth (Months 6–12)

- Outcome-driven synthesizer via `user.define_outcome` + rubric grader (research-preview → GA promotion): the curator iterates defense quality against operator-defined outcomes ("no false positives against our 166K benign corpus," "covers all 4 observed evasion variants," etc).
- `callable_agents` multi-agent for specialized forensic sub-agents: kernel-forensics, memory-forensics, network-forensics, each with its own skill subtree and sandbox tooling. Curator delegates where scope exceeds single-session reasoning.
- Role-swap substrate: same curator + same skills bundle, different decision profiles — `auditor` (read-only posture assessment), `abuse` (abuse-team response against customer-originated attacks), `migration` (pre-migration hardening). Different memory-store overlays, same foundation.
- BSD / FreeBSD support: many hosting providers run FreeBSD edge. `bl observe` gets FreeBSD variants; `bl defend firewall` gains pf-table support; skills/hosting-stack gains FreeBSD anatomy.
- Windows event-log parity: auditd → wevtutil/ETW analogs; ModSec → IIS Application Request Routing; APF → Windows Firewall. Same namespace, different primitives, same curator.
- Exit gate: 50+ hosting providers; 100+ community skills; "defensive-primitive agents" / "skills-native defensive AI" is a recognized product category in analyst reports.

### 17.5 Phase P5 — ecosystem + upstream (Year 1+)

- Upstream skills contributions to ModSec, LMD, YARA, APF/CSF, ClamAV projects — each project publishes an official `skills/` subtree consumable by blacklight and any compatible skills runner.
- Academic/industry paper: *"Skills-native defensive AI — the supercharge-not-replace pattern"* — formalize the pattern so vendors can build compatible implementations without inheriting blacklight code.
- Industry working group on agentic-minute response SLAs for disclosed CVEs: defined response-time tiers (agentic-minutes, agentic-hours, manual-hours) adopted by compliance frameworks.
- Reference implementation adopted by mainstream hosting vendors (cPanel, CloudLinux, Plesk, DirectAdmin) — either via `bl` ship-in-bundle or via compatible implementations talking to the same skills protocol.
- Exit gate: blacklight is the default tool in the hosting-industry IR toolkit; "skills" mean "blacklight-compatible skills" the way "YARA rules" mean a specific grammar.

### 17.6 Non-goals across the entire roadmap

The "supercharge-not-rearchitect" pitch stays load-bearing across all phases. Things blacklight will never do:

- Replace the defensive primitives themselves (ModSec, APF, LMD, etc.) with new engines of our own.
- Ship its own SIEM or log-aggregation substrate.
- Become a multi-tenant SaaS we host — the workspace model is customer-provisioned and customer-owned.
- Rewrite IR workflow from scratch; we plug into existing trigger surfaces (maldet inotify, auditd, ModSec critical hook, Nagios/Icinga/PRTG).
- Require Python on the host; bash + coreutils is the floor forever.
- Become a closed-core commercial product; GPL v2 is permanent.

---

## 18. Endstate

What does "won" look like? Four dimensions.

### 18.1 Operationally

- When a critical CVE drops, any hosting provider with blacklight installed runs `bl consult --cve <id>` on any vulnerable host and gets a skills-grounded kill chain, synthesized defensive payloads, and a remediation plan in minutes — matching the speed at which offense operates.
- Agentic-minute response is the industry baseline for responsible hosting. The tolerable-response-time for disclosed critical CVEs compresses from weeks to hours; the post-disclosure window where offense outpaces defense shrinks toward parity.
- Every hosting provider's Managed Agent workspace carries their fleet's precedent across years. New IR hires onboard by reading archived briefs; investigations extend institutional memory instead of rebuilding it from ticket grep.
- Premature incident closures become structurally rare — the case memory gates closure on open-questions resolution and schedules silent verify sweeps, not analyst gut-feel.
- Post-exploitation discovery (gsocket-class implants, rogue cron, argv[0] spoofing) happens on Day 1 of incident response, not Day 14 — because the `linux-forensics/persistence.md` skill is read on every case where persistence is a live hypothesis.

### 18.2 Ecosystemically

- A public skills ecosystem: 500+ skills covering every major CVE family, hosting stack variant, malware family, Linux/BSD/Windows primitive, compliance framework. Defenders contribute skills the way they contributed YARA rules a decade ago and Snort rules two decades ago.
- "Skills-native defensive AI" is a recognized product segment. Analyst reports name it. Vendors ship compatible implementations. Standards emerge around the `skills/` filesystem schema.
- The Managed Agents memory-store-as-skill-library pattern is the industry default for extensible agent systems, cited across security, ops, devex, scientific computing, customer support — anywhere long-running agentic tasks need programmable knowledge surfaces.
- Hosting provider and MSP IR teams are the visible user class, but the pattern spreads: DFIR consultancies, CERT teams, academic IR courses, red/blue team engagements all use skills-compatible runners.

### 18.3 Architecturally

- Anthropic Managed Agents has proven the long-running agent model at production scale; session-state + hot-swap files + memory-store-mounted skills becomes the default pattern for any multi-day agentic workload. The beta graduates; the primitives remain stable enough to build long-running products on.
- Opus 4.7 (and successors) + 1M-class context + adaptive thinking + structured output becomes the accepted baseline for correlation-heavy reasoning. Retrieval-only architectures are recognized as a compromise, not a default.
- The three-layer pattern — native primitives + skills-loaded agent + thin language-agnostic wrapper — becomes a well-known architectural idiom applied across domains, not just security.

### 18.4 Commercially (for R-fx Networks)

- blacklight is the halo product that positions LMD / APF / BFD as the substrate of the modern defensive stack. The OSS suite running on ~100K+ hosts becomes the preferred deployment surface for defensive agents.
- Hosting providers and MSPs adopting blacklight pull the rest of the rfxn OSS suite into their stack: LMD for file scanning, APF for firewall automation, BFD for brute-force detection, all directed by the same skills-loaded curator.
- Twenty years of operator-voice Linux security tooling pay out as the foundation layer of the agentic defensive era — not by becoming a closed commercial platform, but by becoming the reference implementation that vendors build against, MSPs adopt, and academia teaches.
- The named-adopter class (hosting providers, MSPs running LMD/APF/BFD) becomes the blacklight install base by default. No sales motion required — the tools are where the tools already are.

### 18.5 Strategically, against the Mythos-class offensive future

- The defender/attacker asymmetry narrows on response time. Attackers still enjoy first-mover advantage on novel 0-days; the *gap* between "vulnerability exploitable" and "fleet defended" shrinks from weeks to hours.
- Agentic defense becomes the expected baseline for responsible hosting. Regulators, insurers, and compliance frameworks reference agentic-minute SLAs for disclosed-CVE mitigation. Providers operating outside that standard face commercial pressure to adopt.
- The moment blacklight captures — *"we brought the agent to the primitives, instead of replacing the primitives"* — becomes a generational inflection point in defensive tooling, the way SIEM was in 2005 or EDR was in 2015. Every serious defensive product ten years from now is either skills-native-by-design or is losing share to something that is.
- Mythos-class offense does not disappear. It gets faster. But for the first time since its emergence, there is a defensive answer built to the same shape — running on tools the defensive side already trusts — that operates at the same tempo. That is enough.

---

## 19. Closing

v1 pivot was a correct diagnosis with an overscoped prescription. v2 takes the same diagnosis and delivers the minimum viable expression of it: **a bash wrapper, a skills-loaded Managed Agent, the defensive primitives your hosting stack already runs.** Everything else was ceremony.

The pitch — *Attackers have agents. Defenders still have grep. blacklight is the counter.* — and the architecture are now the same thing written twice. The roadmap extends the foundational node into an ecosystem without violating the pitch. The endstate is the answer to Mythos the defensive industry has been waiting for, running on tools it already trusts, at the speed the threat now moves.

That is the strongest position this project has had since Day 1.

Execute.

*End of PIVOT v2.*
