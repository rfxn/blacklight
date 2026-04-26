# blacklight

> *Attackers have agents. Defenders still have grep. **`bl`** is the counter — a portable bash CLI that turns your existing Linux defensive stack into an agent-directed incident-response surface, on the substrate the defender already owns.*

At 03:42 UTC on a Saturday, a hosting provider's on-call engineer gets the
APSB25-94 advisory: Magento stores are actively backdoored via a double-extension
webshell hidden in the media cache. Eight hours later the team has run `grep`,
`find`, ModSec audit scrapes, ClamAV scans, APF drops, and crontab audits across
forty hosts — by hand. **blacklight collapses that arc into agentic-minutes** on
the same Linux substrate the defender already runs. No platform buy-in. No
fleet migration. No analyst retraining. A Managed Agent curator holds the case
across days; the operator runs the steps it prescribes.

[![Version](https://img.shields.io/github/v/tag/rfxn/blacklight?label=version&color=blue&sort=semver)](https://github.com/rfxn/blacklight/tags)
[![License](https://img.shields.io/github/license/rfxn/blacklight?color=blue)](LICENSE)
[![Last commit](https://img.shields.io/github/last-commit/rfxn/blacklight?color=success)](https://github.com/rfxn/blacklight/commits/main)
[![Bash 4.1+](https://img.shields.io/badge/bash-4.1%2B-success.svg)](#why-bash)
[![Tests: 348 BATS / 17 files](https://img.shields.io/badge/tests-348%20BATS%20%2F%2017%20files-success.svg)](#proof)
[![Powered by Claude Opus 4.7](https://img.shields.io/badge/powered%20by-Claude%20Opus%204.7-d97757.svg)](#why-opus-47--1m-context)
[![Managed Agents](https://img.shields.io/badge/Anthropic-Managed%20Agents-7f4dff.svg)](#why-managed-agents)

> **v0.5.0 — hackathon build, Cerebral Valley "Built with 4.7" April 2026.**
> Production-shape, not production-tested at fleet scale. External operator
> beta is roadmap P1.

**Contents:** [Why this exists](#why-this-exists--apsb25-94-in-production) ·
[Who this is for](#who-this-is-for) ·
[How blacklight compares](#how-blacklight-compares) ·
[Install](#install) · [Try it](#try-it--apsb25-94-in-five-minutes) ·
[Verify yourself](#verify-yourself) ·
[Architecture](#architecture--three-views) ·
[Command surface](#command-surface) ·
[Why Managed Agents](#why-managed-agents) ·
[Why Opus 4.7](#why-opus-47--1m-context) ·
[Why bash](#why-bash) ·
[What blacklight is NOT](#what-blacklight-is-not) ·
[Safety model](#safety-model--five-tiers-eight-mechanics) ·
[Skills bundle](#skills-bundle) ·
[Bash SDK](#bash-sdk--136-reusable-bl_-primitives) ·
[Proof](#proof) · [Roadmap](#roadmap)

---

## Why this exists — APSB25-94, in production

In **mid-March 2026**, [Sansec](https://sansec.io) publicly disclosed
**PolyShell** as part of [APSB25-94](https://helpx.adobe.com/security/products/magento/apsb25-94.html)
— an unauthenticated file-upload RCE affecting **every version** of Magento 2
Community Edition and Adobe Commerce. **No vendor patch existed at
disclosure. None exists today.** Mass exploitation began within 48 hours.

We ran the response on the ground across a **managed-Magento hosting fleet
of a thousand-plus servers** — low-margin commerce, mostly small and
mid-sized merchants, a long-tail incident that stretched far beyond its
peak. The shape of what hit, drawn from public field reporting on the
campaign:

> ▸ **6,800+ unique attacker IPs** across multiple threat groups with separate C2 infrastructure
> ▸ **1.5M+ malicious requests, peaking at 210,000/day**
> ▸ **12+ path-evasion techniques** iterated in real time
> ▸ A separate upload vector traced back **months before public disclosure**
> ▸ Post-compromise C2 beacons, secondary backdoors, and JavaScript payment skimmers

Polyglot signatures had been flagging the artifacts since **late February** —
PHP hidden inside valid GIF and PNG images, shells on disk that looked
harmless to every file-type check. By the time the vulnerability was named,
detection was already running. Some layers held. Some didn't. Attackers
found evasion paths that bypassed initial WAF mitigations, and we iterated
rules through the persistent attack window. We built **50+ assessment
checks per store** mid-incident because existing tools didn't give us the
coverage the threat demanded. New signatures shipped for backdoors and
skimmer payloads we hadn't seen before. *Some countermeasures came from
lessons learned the hard way, not playbooks on the shelf.*

After the industry-wide persistent attack pattern, **attack volume dropped
99.9%** — while the rest of the ecosystem continued to wait for a patch
that still does not exist.

**Where Claude entered.** Resources were stretched thin across the peak and
the tail. Through that window, **Claude played a foundational role in
helping us gain leverage** — every IR analyst was pasting evidence into
chat, getting forensic synthesis back, and applying the result by hand. The
lesson by the end of that campaign was not "AI helps with IR." The lesson
was: **the agent doesn't belong in a chat window. It belongs in the shell,
holding the case across days, on the substrate the defender already runs.**
**blacklight is that lesson shipped** — the agent-directed CLI we wished
we'd had on day 1.

> *No customer data lives in this repo. The volumes cited above are from
> public field reporting on the campaign. The APSB25-94 reconstruction in
> [`exhibits/fleet-01/`](exhibits/fleet-01/) is built **only** from the
> public Adobe advisory, public Sansec analyses, and OWASP CRS / Magento
> developer documentation. Operator-local material was used solely to
> shape-check synthesis cadence and never copied, quoted, or referenced.*

---

## Who this is for

Hosting providers, MSPs, and security teams already running the R-fx Networks
defensive OSS stack — [LMD](https://github.com/rfxn/linux-malware-detect)
(~tens of thousands of installs), [APF](https://github.com/rfxn/advanced-policy-firewall)
(~hundreds of thousands of installs),
[BFD](https://github.com/rfxn/brute-force-detection). blacklight is the
agentic-defensive-era release in that family — same Linux substrate, same
install discipline, same operator vocabulary.

**Same maintainer.** blacklight is authored by the same maintainer as
LMD, APF, and BFD — defensive OSS for the Linux hosting industry continuously
since 2002. This is not a new vendor asking for trust. It is the next release
in a product family that has earned trust on hundreds of thousands of hosts
over twenty-four years.

| Operator profile | What `bl` gives them |
|---|---|
| **L1 SOC analyst** at a managed hosting provider | `bl trigger lmd <hit>` opens a case from the LMD post-scan hook; the curator drives observation, defense, and cleanup. The L1 confirms tier-gated steps. |
| **L2 IR engineer** at an MSP | One curator session per case, resumable for 30 days. New evidence attaches via the Files API; the curator extends the hypothesis instead of restarting. |
| **Hosting product owner** | GPL v2, zero license cost, single bash file, `$ANTHROPIC_API_KEY` is the only credential. Operator pays Anthropic API usage; that is the entire cost. |
| **Defender / sysadmin** on a small fleet | Vocabulary stays the same — `bl observe cron --user x` is what they would have typed. Skills are markdown; they read or fork them. |

---

## How blacklight compares

The first wave of agentic defensive tooling — **CrowdStrike Charlotte AI**
(bound to Falcon EDR/XDR), **Microsoft Security Copilot** (bound to Sentinel +
Defender + M365 E5), **Palo Alto Purple AI** (bound to Cortex), **Google
SecLM / Duet for Security** (bound to Chronicle) — shares one structural
constraint: the operator must be inside the vendor platform before the agent
is available. The reasoning quality is real. The bottleneck is platform reach.

| Adoption barrier | Charlotte-class | blacklight |
|---|---|---|
| Platform onboarding | 3–18 months fleetwide | ~30 seconds (`curl \| bash`, then `bl setup`) |
| Per-endpoint licensing | $75–$250 / host / year | $0; only Anthropic API usage |
| SIEM/SOAR/IdP integration | Quarters of platform engineering | None — `bl` reads existing logs in place |
| Analyst retraining | Weeks to months on vendor DSL | Zero — operator vocabulary preserved |
| Extensibility | Vendor DSL detection authoring | Fork the repo; drop in a markdown skill |
| Lock-in | Per-vendor; migration cost compounds | None — wrapper and skills are GPL v2 |
| Works on CentOS 6 / RHEL 7 / Debian 10 | Rarely supported | Yes — bash 4.1 + curl is the floor |
| Compatible with $10/month customer margins | No | Yes |
| Auditable in 30 minutes | No (closed platform) | Yes (single bash file + markdown) |

The OSS Linux defensive stack runs on the order of **hundreds of millions of
hosts** Charlotte structurally cannot reach. blacklight does not compete with
Charlotte on enterprise accounts — it addresses the market Charlotte cannot
serve. Full positioning in [`PRD.md`](PRD.md) §10.

---

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/rfxn/blacklight/main/install.sh | sudo bash
export ANTHROPIC_API_KEY="sk-ant-..."
bl setup
```

Requires: bash 4.1+, curl, jq. **Pre-commit gate (operator-run via `make`):**
the full BATS suite must pass on Debian 12 + Rocky 9 before every commit.
**Release matrix:** adds Ubuntu 20.04 / 24.04, CentOS 7, Rocky 8 (`make -C
tests test-all`, run before each release tag). RPM and DEB packaging live
under `pkg/`; `install.sh` is the curl-pipe-bash entry point.

`bl setup` is one-time per Anthropic workspace. It provisions the `bl-curator`
Managed Agent, the `bl-curator-env` cloud sandbox, the `bl-case` memory store,
uploads eight corpus Files, and registers six description-routed Skills against
the agent. Identifiers persist to `/var/lib/bl/state/state.json`; every host
that shares the workspace key reuses them. See [`docs/setup-flow.md`](docs/setup-flow.md).

---

## Try it — APSB25-94 in five minutes

Scenario: APSB25-94 advisory drops. One host is suspected. The operator opens
a case, collects evidence, and applies a ModSec rule — all in under ten
minutes.

> *Output below is illustrative — shaped by the public APSB25-94 advisory
> and pasted to show the loop. A recorded live trace lives at
> [`tests/live/evidence/`](tests/live/evidence/); regenerate locally with
> `make live-trace` (requires `ANTHROPIC_API_KEY`).*

**1 — collect Apache logs and check the filesystem:**

```bash
bl observe log apache --around /var/www/html/pub/media/catalog/product/.cache/a.php --window 6h
bl observe fs --mtime-since 2026-03-20T00:00:00Z --under /var/www/html --ext php
```

```
blacklight: obs-0001 apache log records → bl-case/CASE-2026-0001/evidence/obs-0001-apache.transfer.json (3 records)
{"ts":"2026-03-22T14:22:07Z","host":"magento-prod-01","source":"apache.transfer","record":{"client_ip":"203.0.113.42","method":"GET","path":"/pub/media/catalog/product/.cache/a.php/banner.jpg","status":200,"path_class":"polyglot","is_post_to_php":false}}
{"ts":"2026-03-22T14:23:51Z","host":"magento-prod-01","source":"apache.transfer","record":{"client_ip":"203.0.113.42","method":"POST","path":"/pub/media/catalog/product/.cache/a.php","status":200,"path_class":"php_in_cache","is_post_to_php":true}}

blacklight: obs-0002 fs records → bl-case/CASE-2026-0001/evidence/obs-0002-fs.mtime-since.json (1 record)
{"ts":"2026-04-25T00:00:00Z","host":"magento-prod-01","source":"fs.mtime-since","record":{"path":"/var/www/html/pub/media/catalog/product/.cache/a.php","mtime":"2026-03-21T23:58Z","ext":"php"}}
```

**2 — open a case and consult the curator:**

```bash
bl consult --new --trigger "APSB25-94 double-extension webshell — obs-0001 obs-0002"
```

```
blacklight: CASE-2026-0001 opened
blacklight: curator session wake enqueued
blacklight: pending step s-0001 ready
  verb:    observe.modsec
  tier:    read-only
  reason:  confirm rule coverage before prescribing defensive payload
Run: bl run s-0001
```

**3 — execute the curator-prescribed step:**

```bash
bl run s-0001
```

```
blacklight: s-0001 observe.modsec [read-only] — running
  modsec rule hit on REQUEST_URI @rx /\.php/[^/]+\.(jpg|png|gif)  id:920450
blacklight: result written to case memstore
blacklight: pending step s-0043 ready
  verb:    defend.modsec
  tier:    suggested
  reason:  obs-0001 + obs-0002 + s-0001 confirm polyshell staging pattern
  diff:    +SecRule REQUEST_FILENAME "@rx \.php/[^/]+\.(jpg|png|gif)$" \
               "id:941999,phase:2,deny,log,msg:'polyshell double-ext staging'"
Confirm and apply? [y/N]
```

**4 — apply the ModSec rule (tier-gated, `apachectl configtest` pre-flight, backup written):**

```bash
bl run s-0043 --yes
```

```
blacklight: s-0043 defend.modsec [suggested] — applying
  apachectl -t ... OK
  rule installed: /etc/apache2/mods-enabled/bl-CASE-2026-0001-941999.conf
  apache2ctl graceful ... OK
blacklight: ledger event defend_applied written
blacklight: CASE-2026-0001 defense step complete
```

The full APSB25-94 motion — observation → consult → defense → clean →
case close — is exercised end-to-end by
[`tests/live/setup-live.bats`](tests/live/setup-live.bats) (BL_LIVE-gated)
and captured for review at [`tests/live/evidence/`](tests/live/evidence/).

---

## Verify yourself

A judge or operator can verify install + smoke + version in under 60 seconds
without an Anthropic API key (the test suite is fixture-driven, never live):

```bash
git clone https://github.com/rfxn/blacklight && cd blacklight
make bl                                       # assemble bl from src/bl.d/NN-*.sh
./bl --version                                # → bl 0.5.0
./bl --help                                   # nine-namespace surface
make -C tests test-quick                      # 00-smoke + 01-cli-surface (~70s)
ls schemas/ skills/ routing-skills/ skills-corpus/   # 6 skill primitives + 8 corpora
git log --oneline | head -20                  # steady commit cadence
```

Full suite (Debian 12 default):

```bash
make -C tests test                            # 348 BATS tests, fixture-driven
make -C tests test-rocky9                     # second pre-commit distro
make -C tests test-all                        # full release matrix (6 distros)
```

Live API surfaces (requires `ANTHROPIC_API_KEY` in `.secrets/env`):

```bash
make live-trace                               # tests/live/setup-live.bats, BL_LIVE-gated
ls tests/live/evidence/                       # committed traces
```

---

## Architecture — three views

### View 1 — three-layer separation of concerns

```
┌─ Layer A — bl on the host (bash 4.1+, curl, jq, awk, sed, grep) ───────────┐
│   26 source parts under src/bl.d/, ~10,700-line assembled binary           │
│   136 reusable bl_* functions across 14 families (bash SDK — see §below)   │
│                                                                             │
│   bl observe   bl consult   bl run     bl defend   bl clean                 │
│   bl case      bl setup     bl trigger bl flush                             │
└──────────────────────────────────────────────┬──────────────────────────────┘
                                               │ HTTPS + ANTHROPIC_API_KEY
                                               ↓
┌─ Layer B — Managed Agent session (Anthropic-hosted, Opus 4.7, 1M ctx) ─────┐
│   Agent           bl-curator              (created once by `bl setup`)     │
│   Environment     bl-curator-env          (cloud sandbox; per-session pkg) │
│   Memory store    bl-case (read_write)    one folder per case              │
│   Skills          6 description-routed    lazy-loaded per turn             │
│   Files           8 workspace corpora     mounted at session create        │
│                   per-case evidence       hot-attached mid-session         │
│   Custom tools    report_step / synthesize_defense / reconstruct_intent    │
│   Triggers        LMD post_scan_hook adapter (M14)                         │
└──────────────────────────────────────────────┬──────────────────────────────┘
                                               │ step directives (JSON)
                                               ↓
┌─ Layer C — existing host primitives (we direct, never replace) ────────────┐
│   apachectl + ModSecurity-CRS · APF · CSF · iptables · nftables             │
│   LMD · ClamAV · YARA · Apache/nginx logs · journalctl · cron · /proc       │
└─────────────────────────────────────────────────────────────────────────────┘
```

**Layer-boundary invariants.** Layer A executes; Layer B reasons; Layer C is
untouched by blacklight source — no new rule engines, no new manifests, no
new wire formats. Cases are agent-directed REPLs, not batch dossier analyses.

### View 2 — investigation flow (async polled step-emit)

The wrapper does not hold an SSE socket. The agent writes proposed step JSON
to `bl-case/<case>/pending/<step-id>.json`; the wrapper polls and executes:

```
operator                bl (Layer A)              Managed Agent (Layer B)
────────                ────────────              ─────────────────────
$ bl consult --new \
   --trigger <hit>      preflight; allocate
                        CASE-YYYY-NNNN;
                        POST /v1/sessions
                        (workspace + per-case
                         Files attached);
                        POST wake event
                                                  session.wake
                                                  routing Skills lazy-load
                                                  read bl-case/hypothesis
                                                  emit s-01..04 to
                                                    bl-case/pending/
                        bl_poll_pending loop:
                          GET memstore?path_prefix=…/pending/
                          (3s cadence, dedup, exit on
                           3 empty cycles or --timeout)
Accept? [Y/n] Y         exec each step;
                        write …/results/s-NN.json;
                        POST wake
                                                  read results, revise,
                                                  emit next batch:
                                                    observe / defend /
                                                    clean / close_case
                        auto-exec read-only +
                        auto-tier; stop on
                        destructive; show diff;
                        --yes per step
Confirm cron removal? y exec, write result,
                        POST wake
                                                  propose close_case when
                                                  open_questions = 0
$ bl case close         brief → Files API;
                        T+30d firewall-block
                        retire-sweep scheduled
```

**Why polled, not synchronous SSE.** Bash + curl + jq does not do
bidirectional SSE well. Polling memory-store paths makes the case memory the
self-documenting audit log, keeps `bl` short-lived per invocation, and
absorbs agent latency invisibly (3-9s polling tick is a no-op against agent
reasoning time). Full mechanical detail: [`DESIGN.md`](DESIGN.md) §4.

### View 3 — Managed Agents primitive map

blacklight uses the **full five-primitive Managed Agents surface**. The
$5,000 special-prize hook is architectural, not cosmetic — every primitive
carries weight:

| Primitive | Instance | blacklight role | Path key in `state.json` |
|---|---|---|---|
| **Agent** | `bl-curator` (Opus 4.7, 1M ctx) | Persistent identity for every case session; CAS-versioned with HTTP 409 retry | `agent.id`, `agent.version` |
| **Environment** | `bl-curator-env` | Cloud sandbox; curator installs `apache2`, `mod_security2`, `yara`, `jq`, `duckdb`, `pandoc` per-session via the bash tool | `agent.environment_id` |
| **Skills** | 6 description-routed | `synthesizing-evidence`, `prescribing-defensive-payloads`, `curating-cases`, `gating-false-positives`, `extracting-iocs`, `authoring-incident-briefs` — platform router selects per turn | `agent.skill_versions.<slug>` |
| **Files (workspace)** | 8 corpora | `foundations.md` + 6 routing-skill corpora + `substrate-context-corpus.md`; mounted at session create | `files.<slug>.file_id` |
| **Files (per-case)** | Evidence bundles | Hot-attached mid-session via `sessions.resources.add`; closed-case briefs become precedent for the next case | `case_files.<case>.<path>.workspace_file_id` |
| **Memory Store** | `bl-case` (read_write) | Hypothesis + steps + actions + open-questions per case; the case IS the session state | `case_memstores._default` |
| **Sessions** | One per case | Opus 4.7, 1M context, resumable across the 30-day checkpoint window | `session_ids.<case-id>` |
| **Custom tools** | `report_step`, `synthesize_defense`, `reconstruct_intent` | Tier-classified step proposal; multi-artifact defense authoring; multi-layer deobfuscation | `prompts/curator-agent.md` |
| **Triggers** | LMD `post_scan_hook` adapter (M14) | Cases open from existing detection signal — not a new event surface | `triggers.lmd.installed` |

The legacy `bl-skills` memory store was **retired in M13** (Path C
realignment). Skill content lives in the Skills primitive
(description-routed, lazy-loaded), not a flat read_only memstore. Full spec:
[`DESIGN.md`](DESIGN.md) §3.4 + [`docs/managed-agents.md`](docs/managed-agents.md).

---

## Command surface

Nine namespaces, one assembled bash binary, per-verb help that bypasses
preflight (`bl <verb> --help` works on an unseeded workspace):

| Namespace | Purpose |
|---|---|
| `bl observe` | Read-only evidence: `file`, `log {apache\|modsec\|journal}`, `cron`, `proc`, `htaccess`, `fs`, `firewall`, `sigs`, `substrate`, `bundle`. JSONL out. |
| `bl consult` | Open or attach an investigation case via the `bl-curator` Managed Agent. |
| `bl run` | Execute an agent-prescribed step. Schema-validated, tier-gated, ledger-logged. `--list`, `--batch [--max <N>]`, `--dry-run`, `--explain`. |
| `bl defend` | Apply an agent-authored payload — `modsec` (rule apply / `--remove` / rollback), `firewall` (APF/CSF/iptables/nftables, CDN-safelist aware, `--retire <duration>`), `sig` (LMD/ClamAV append, FP-corpus gated). |
| `bl clean` | Diff-shown remediation — `file` (quarantine, never unlink), `htaccess`, `cron`, `proc` (capture-then-SIGTERM). `--undo`, `--unquarantine` round-trip. |
| `bl case` | Lifecycle — `show`, `list`, `log [--audit]`, `close`, `reopen`. |
| `bl setup` | Workspace bootstrap — `--sync`, `--reset --force`, `--gc`, `--eval`, `--check`, `--install-hook lmd`, `--import-from-lmd`. |
| `bl trigger` | Hook-driven case open. Today: LMD `post_scan_hook`. |
| `bl flush` | Drain durable outbox of queued memstore writes (cron-driven). |

Ten documented exit codes (`docs/exit-codes.md`); 1–63 reserved for POSIX
conventions, 64–72 for blacklight semantics.

---

## Why Managed Agents

The curator is an Anthropic Managed Agent — not a stateless API call wrapped
in a prompt. **The case IS the session.**

An operator runs `bl consult` Monday morning to open a case, collects more
evidence Tuesday afternoon via `bl observe`, calls `bl consult` again Friday
— the curator already holds the hypothesis, the evidence index, the pending
steps, and every prior revision. There is no re-prompt, no context
reconstruction, no "please remember what we discussed." Case state
accumulates across sim-days because it is stored in the `bl-case` memory
store and the running session, not in the operator's shell.

This is the architecture, not a feature flag:

1. **`bl setup` provisions the full Managed Agents primitive set** — Agent +
   Environment + Memory Store + Skills + Files — and persists every ID into
   a single `state.json` (M15). Subsequent invocations reuse them.
2. **Pre-flight validation runs in the agent's own sandbox.** `apachectl -t`
   runs against the agent's config tree before any rule is promoted to
   `pending/`. No external validator service. No cross-machine drift.
3. **Skills mount as platform-routed Skills.** Edits propagate to the next
   session without code deploy. A third-party hosting provider contributes a
   skill via PR; it ships as a Skills update.
4. **Hot-swap mid-investigation evidence.** Files attach to a running session
   via `sessions.resources.add`. The hypothesis state never tears.
5. **Workspace-scoped, commercially.** Per-tenant isolation is platform-native;
   blacklight does zero multi-tenant engineering.
6. **Self-bootstrap, in bash, against the public API.** `bl setup` is
   idempotent. CAS-versioned agent updates with HTTP 409 retry survive
   concurrent operators.

Live API surfaces verified against the `managed-agents-2026-04-01` beta
header in M15: `POST /v1/agents/<id>` (update), `POST /v1/agents/<id>/archive`
(retire), `sessions.create` body `{ agent: <id>, ... }`. The `packages` field
is **not** valid on env-create — the curator installs `apache2`,
`libapache2-mod-security2`, `modsecurity-crs`, `yara`, `jq`, `zstd`, `duckdb`,
`pandoc`, `weasyprint` per-session via the bash tool. See [`docs/managed-agents.md`](docs/managed-agents.md).

---

## Why Opus 4.7 + 1M context

Post-incident reconstruction requires cross-stream correlation — the webshell
URL in the access log, the double-extension filesystem path, and the injected
cron entry are only causally connected when the curator can see all three
streams simultaneously.

A realistic APSB25-94-shaped case routinely accumulates **250,000 to 400,000
tokens** of raw evidence (Apache transfer + error, ModSec audit, FS mtime,
crontabs, process snapshots, journalctl, maldet history) before the curator
has authored a single hypothesis. Chunking destroys the correlation that
distinguishes signal from noise: a retriever picking "top 5 evidence items"
will miss the one record that matters precisely because it does not look
relevant in isolation.

The 1M context window makes full-bundle correlation possible without a
retrieval layer. Opus 4.7 brings the forensic reasoning depth needed to
distinguish a staging artifact from a false positive by applying ModSecurity
grammar, Magento path conventions, and attacker TTPs simultaneously. A hot
mid-investigation case lives at ~85K–120K tokens — 8–12% of the window.
Prompt caching amortizes the stable portion (skills + history) across turns;
only the new evidence delta is uncached.

[`exhibits/fleet-01/large-corpus/`](exhibits/fleet-01/) ships a
deterministic, byte-identical, **~360k-token** APSB25-94 forensic bundle
reconstructed entirely from the public Adobe advisory — regenerable via
`scripts/dev/synth-corpus.sh --seed 42`.

---

## Three-tier model routing

| Surface | Model | Why |
|---|---|---|
| Curator (per-case session) | **`claude-opus-4-7`** | 1M context absorbs full case state without a retriever. Calibrated hypothesis revision is the trained behaviour. |
| `synthesize_defense` / `reconstruct_intent` | **`claude-opus-4-7`** | Multi-artifact consistency (rule + exception list + validation) and multi-layer deobfuscation (base64 → gzinflate → eval) are code-comprehension at depth. |
| `bl observe bundle` summary render | **`claude-sonnet-4-6`** | Pattern condensation at speed and cost. Falls back to deterministic helper on `--no-llm-summary` or `BL_DISABLE_LLM=1`. |
| FP-gate adjudication (sig append) | **`claude-haiku-4-5`** | Binary-scan-passed signatures spot-checked before LMD/ClamAV append. Cheap, fast, schema-output. |

The three-tier routing is not cosmetic. Curator calls are infrequent and
expensive **by design** — they carry the full evidence bundle. Step-execution
and FP-gating calls are frequent and cheap **by design** — they carry only the
step payload or the candidate signature. Same model everywhere would either
make investigations prohibitively expensive or leave the reasoning-intensive
curator step under-resourced.

`BL_DISABLE_LLM=1` short-circuits all LLM calls and forces deterministic
fallbacks — required for CI and operator dry-runs. The test suite never makes
a live API call; `tests/helpers/curator-mock.bash` shims `curl` against
`tests/fixtures/step-*.json`.

---

## Why bash

The bash 4.1 + curl + jq runtime IS the commercial moat against
Charlotte-class platforms — because Charlotte cannot deploy here either.

- **Portability floor: bash 4.1 from December 2009 (RHEL/CentOS 6 era).**
  Tens of millions of legacy hosting environments still run on or near this
  floor. The version guard at `src/bl.d/00-header.sh:48` is the explicit
  gate.
- **Pre-usr-merge handling.** CentOS 6 has coreutils at `/bin/`, modern
  distros at `/usr/bin/`. `bl` never hardcodes either — every coreutil call
  goes through the `command` builtin for portable PATH resolution. Verified
  in 24 of 26 source parts (the two exempt parts are pure-bash, no coreutils).
- **Zero runtime daemons, zero databases, zero service ports.** State lives
  in `/var/lib/bl/` on the host (operator-owned) and the Anthropic workspace
  (operator-owned). `bl` exits when its operation completes.
- **Single secret = `$ANTHROPIC_API_KEY`.** No service account, no long-lived
  token, no mTLS, no certificate management. Workspace boundary is the blast
  radius of a compromised credential.
- **Distro matrix:** distro Dockerfiles ship in-repo (`tests/Dockerfile`,
  `tests/Dockerfile.rocky9`, `tests/Dockerfile.centos6`); operator-run via
  `make -C tests test-all` against debian12, rocky9, centos7, rocky8,
  ubuntu2004, ubuntu2404. CentOS 6 floor verified via `Dockerfile.centos6`
  on demand.

---

## What blacklight is NOT

Explicit non-goals. Not in this version, not in any version, regardless of
roadmap pressure:

- **Not an EDR.** No kernel sensor, no endpoint telemetry agent, no platform
  to roll out fleetwide.
- **Not a SIEM.** No log-aggregation substrate; `bl observe` consumes
  existing logs in place.
- **Not a daemon or service.** `bl` is invoked once per operator thought
  and exits. State lives in `/var/lib/bl/` and the Anthropic-hosted session.
- **Not a fleet manager.** v0.5.0 is single-host. Fleet propagation rides
  the customer's existing Puppet/Ansible/Salt/Chef.
- **Not multi-tenant SaaS.** The Anthropic workspace is operator-provisioned
  and operator-owned. Per-tenant isolation is platform-native.
- **Not a replacement for ModSec/APF/LMD/ClamAV/YARA.** `bl` directs them.
  It does not replace them. The supercharge-not-rearchitect pitch is
  load-bearing.
- **Not Python.** Zero language runtime on the host. `bl` is bash; the
  agent runs in Anthropic's sandbox; we do not operate it.
- **Not a closed-core commercial product.** GPL v2 is permanent.

---

## Safety model — five tiers, eight mechanics

Every action is classified into one of five tiers; the wrapper enforces the
gate based on the tier the agent declared, not on trust from the agent alone.

| Tier | Examples | Gate |
|---|---|---|
| **read-only** | `observe.*`, `consult` | Auto-execute, ledger entry only. |
| **auto** (reversible, low-risk) | `defend.firewall <new-ip>`, `defend.sig` (FP-gate passed) | Auto-execute + notification + 15-min veto window. |
| **suggested** (reversible, high-impact) | `defend.modsec` (new rule) | Operator confirmation required; `--yes` permitted at this tier. |
| **destructive** | `clean.*`, `defend.modsec --remove`, `case.close` | Diff shown; `--unsafe` AND `--yes` both required. Backup or quarantine entry written before the operation runs. |
| **unknown** | Anything that does not map to a known verb | Deny by default. Exit 68 (`TIER_GATE_DENIED`). |

**Mechanical disciplines layered on top:**

1. **Schema validation.** Every `report_step` emission validates against
   `schemas/step.json` before persistence. Both the platform (`input_schema`)
   and the wrapper (defense-in-depth) reject malformed envelopes.
2. **Prompt-injection fence.** Evidence is wrapped in a session-unique fence
   token `sha256(case_id || payload || nonce)[:16]`. Schema-override
   injections route into `open-questions.md` as findings, never honoured as
   directives.
3. **Backup-before-apply.** Every `clean` operation snapshots the original
   under `/var/lib/bl/quarantine/<entry-id>/`. `--undo` and `--unquarantine`
   round-trip restore.
4. **Quarantine-not-delete.** `bl clean file` moves under quarantine; it does
   not unlink. Operators re-examine evidence after the fact.
5. **CDN-safelist-aware firewall.** `bl defend firewall` consults configured
   CDN ranges before adding a rule that would null-route Cloudflare/Fastly/
   Akamai upstreams.
6. **FP corpus gate.** Signature submissions pass two stages — a deterministic
   scan of the operator-provisioned corpus at `/var/lib/bl/fp-corpus/`, then
   a Haiku 4.5 spot-check on borderline hits. Both must pass.
7. **Append-only ledger under `flock` FD 200.** Every action appends a JSONL
   event to `/var/lib/bl/ledger/<case>.jsonl`. `bl case log --audit` produces
   per-kind summaries.
8. **Durable outbox.** Memory-store writes that fail (network, 429, 5xx) are
   enqueued under `/var/lib/bl/outbox/` and drained on next preflight or via
   `bl flush --outbox`. Age-gated to avoid drain-on-every-invocation thrash.

Full safety policy: [`docs/security-model.md`](docs/security-model.md),
[`docs/action-tiers.md`](docs/action-tiers.md).

---

## Skills bundle

Operator-voice knowledge is the moat. The bundle is grounded in twenty-five
years of Linux hosting security operations and authored from public sources
(Adobe security advisories, ModSecurity grammar, Magento developer docs,
Linux hosting-stack documentation, public YARA repositories) — never
operator-local data.

```
skills/                 23 subdirectories / 73 files (70 .md content + 3 description.txt routing metadata) — raw research substrate
  actor-attribution         agentic-minutes-playbook   apf-grammar
  apsb25-94                 bl-capabilities            cpanel-easyapache
  defense-synthesis         false-positives            hosting-stack
  ic-brief-format           ioc-aggregation            ir-playbook
  legacy-os-pitfalls        linux-forensics            lmd-triggers
  magento-attacks           modsec-grammar             obfuscation
  remediation               ride-the-substrate         shared-hosting-attack-shapes
  timeline                  webshell-families

routing-skills/         6 description-routed platform Skills (lazy-loaded per turn)
  authoring-incident-briefs   curating-cases   extracting-iocs
  gating-false-positives      prescribing-defensive-payloads   synthesizing-evidence

skills-corpus/          8 workspace corpora (mounted as Files at session create)
  foundations.md   substrate-context-corpus.md   <one-corpus-per-routing-skill>.md
```

**Routing model (M13 Path C):** the legacy `bl-skills` memory store is
**retired**. Skills are now description-routed Skills primitives — the
platform router selects per turn from the description, so per-turn token
load on routed Skills is bounded. Corpus Files mount at session create and
are always present.

**Authoring discipline (non-negotiable):** each operator-voice skill opens
with a scenario from lived experience, states a non-obvious rule, gives one
concrete example drawn from public APSB25-94 material, and names a failure
mode. If the only available draft would be generic IR/SOC boilerplate, the
gap is flagged and the file lands later. **Slop is not shipped.**

**Extensibility:** a defender running DirectAdmin, Virtualmin, or Plesk drops
their own `routing-skills/<name>/{description.txt, SKILL.md}` pair into the
repo and runs `bl setup --sync`. SHA-256 delta-check picks up the addition;
the curator reads it on next session wake. Skills are GPL v2 markdown.

---

## Bash SDK — 136 reusable `bl_*` primitives

`bl` is not just a CLI; it is a bash SDK. The assembled binary exposes
**136 `bl_*` functions across 14 families**. Source `bl` from any other bash
tool (`source bl || true`) and you get reusable primitives for Anthropic
Managed Agents, Files, Memory Stores, Skills, Messages API, prompt-injection
fencing, ledger writes, outbox rate-limiting, and operator notification — in
pure bash, with no Python or service runtime.

| Family | Source | Purpose |
|---|---|---|
| `bl_api_*` (incl. `bl_mem_*`, `bl_poll_*`, `bl_jq_*`) | `20-api.sh` | Managed Agents REST surface; backoff+retry; memory-store CRUD; schema check |
| `bl_messages_call` | `22-models.sh` | Messages API caller (Sonnet 4.6 / Haiku 4.5) |
| `bl_files_*` | `23-files.sh` | Anthropic Files API — upload, attach, GC orphans |
| `bl_skills_*` | `24-skills.sh` | Anthropic Skills API — upload, version-pin |
| `bl_ledger_*` | `25-ledger.sh` | Dual-write audit ledger (memory store + local JSONL) |
| `bl_fence_*` | `26-fence.sh` | Prompt-injection fence — session-unique tokens, untrusted-content wrap |
| `bl_outbox_*` | `27-outbox.sh` | Rate-limit queue with watermarks + age-gated drain |
| `bl_notify` | `28-notify.sh` | Multi-channel operator notification |
| `bl_trigger_*` | `29-trigger.sh` | Hook adapters (LMD `post_scan_hook` today) |
| `bl_preflight` + per-verb help | `30-preflight.sh` | Workspace + state validation, conf load |
| `bl_observe_*` | `40-42-observe-*.sh`, `45-cpanel.sh` | 10 evidence collectors + helpers + router |
| `bl_consult_*` / `bl_run_*` / `bl_case_*` | `50-70-*.sh` | Session lifecycle, step execution, case lifecycle |
| `bl_defend_*` / `bl_clean_*` | `82-83-*.sh` | Defensive payload apply, remediation with backup + diff + undo |
| `bl_setup_*` | `84-setup.sh` | Workspace bootstrap, idempotent skill upload, CAS update, archive |

The CLI dispatch in `90-main.sh` is one consumer of these primitives;
nothing prevents another. Full SDK reference: [`PRD.md`](PRD.md) §5.0.1.

---

## Proof

Behavioral verification is committed evidence, not a claim. Four artifacts:

- **348 BATS tests across 17 files**, fixture-driven (no live API calls in
  CI; `tests/helpers/curator-mock.bash` shims `curl` against
  `tests/fixtures/step-*.json`). `make -C tests test` (Debian 12 default)
  for local iteration; `make -C tests test-rocky9`; `make -C tests test-all`
  for the release matrix across debian12, rocky9, ubuntu2404, centos7,
  rocky8, ubuntu2004. **Pre-commit gate: debian12 + rocky9 must be green
  before every commit** (operator-discipline-enforced via `make`, not via
  hosted CI).
- **Live integration smoke** — [`tests/live/setup-live.bats`](tests/live/setup-live.bats)
  (`BL_LIVE`-gated) exercises the full provision path against the real
  Anthropic Managed Agents API: workspace setup, agent ensure/archive,
  environment ensure, memory-store CRUD, Files upload, Skills create/update
  with CAS, session create, wake event, polled step-emit consume. M15
  verified the live API surfaces (`POST /v1/agents/<id>` update, `/archive`
  retire, `sessions.create { agent: <id> }`) against the
  `managed-agents-2026-04-01` beta header. Trace runner + grader:
  [`tests/live/trace-runner.sh`](tests/live/trace-runner.sh) +
  [`tests/live/trace-grader.sh`](tests/live/trace-grader.sh).
- **Committed live trace** —
  [`tests/live/evidence/live-trace-20260425-2208.md`](tests/live/evidence/)
  is a recorded run from the M12 timeline: Scenes 0/1/2 (workspace setup,
  case allocation, observation substrate assembly) hermetic and green;
  Scene 3 hit a session-creation drift in the Managed Agents beta that M15
  closed in the source. Re-record locally with `make live-trace`.
- **Stress corpus** — [`exhibits/fleet-01/large-corpus/`](exhibits/fleet-01/)
  is a deterministic, byte-identical, ~360k-token APSB25-94 forensic bundle
  (apache + modsec + fs + cron + proc + journal + maldet) with attack needles
  buried in realistic noise. The cross-stream correlation (apache POST IP ↔
  cron curl IP ↔ fs mtime cluster ↔ modsec preceding cluster) is the only
  resolution path; no single stream resolves the case. Regenerate via
  `scripts/dev/synth-corpus.sh --seed 42`. Sources documented; zero
  operator-local data.

---

## Roadmap

The hackathon ships the foundational node. The roadmap extends it without
violating the supercharge-not-rearchitect pitch. New ideas go to
[`FUTURE.md`](FUTURE.md) during the current build window; thirty items
across eight strategic themes are scoped there.

**P1 — stabilization + community release.** Public release under `rfxn/blacklight`,
external operator beta, signed releases (GPG), `bl undo` universal action revert.

**P2 — detection breadth + ecosystem hooks.** Additional firewall backends,
notification channels (Slack/Telegram/Discord/email), source-side log compaction,
inline curator tool wiring, threat-intelligence enrichment, YARA-of-known-malware.

**P3 — fleet operation + sophisticated detection.** `bl observe --fleet`,
container/Kubernetes awareness, behavioral baselining, forensic capture
(memory, timeline, procnet), curator model strategy + air-gapped operation.

**P4 — presentation, extensibility, hardening.** Brief HTML/PDF/multi-language
rendering, skill marketplace, ARM64/Alpine/BSD parity, redaction + data
residency, ledger integrity hardening.

Multi-tenant SaaS variant tracked under T8; the OSS CLI stays GPL v2.

---

## Documentation

- **Architecture and command reference:** [`DESIGN.md`](DESIGN.md)
- **Executive frame, problem, users, competitive positioning:** [`PRD.md`](PRD.md)
- **Roadmap with item-level technical briefs:** [`FUTURE.md`](FUTURE.md)
- **Setup contract:** [`docs/setup-flow.md`](docs/setup-flow.md)
- **Action tiers:** [`docs/action-tiers.md`](docs/action-tiers.md)
- **Security model:** [`docs/security-model.md`](docs/security-model.md)
- **State schema:** [`docs/state-schema.md`](docs/state-schema.md)
- **Case layout:** [`docs/case-layout.md`](docs/case-layout.md)
- **Threat context:** [`docs/threat-context.md`](docs/threat-context.md)
- **Managed Agents API surface:** [`docs/managed-agents.md`](docs/managed-agents.md)
- **Exit codes:** [`docs/exit-codes.md`](docs/exit-codes.md)
- **Live integration smoke + trace evidence:** [`tests/live/`](tests/live/) — `setup-live.bats`, `trace-runner.sh`, `trace-grader.sh`, committed run at `evidence/live-trace-20260425-2208.md`
- **Command help:** `bl --help` and `bl <verb> --help`

---

## License

GNU GPL v2. See [`LICENSE`](LICENSE).

Part of the R-fx Networks defensive OSS portfolio — alongside
[LMD](https://github.com/rfxn/linux-malware-detect),
[APF](https://github.com/rfxn/advanced-policy-firewall),
[BFD](https://github.com/rfxn/brute-force-detection).

R-fx Networks `<proj@rfxn.com>` · Ryan MacDonald `<ryan@rfxn.com>`.

---

*Hackathon build — Opus 4.7 + Anthropic Managed Agents, Cerebral Valley
"Built with 4.7" April 2026.*
