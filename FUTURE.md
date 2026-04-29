# FUTURE.md — blacklight roadmap

## Vision

blacklight (`bl`) transforms post-incident defensive forensics on web hosting infrastructure from a tribal-knowledge bash session into a guided, auditable workflow with an LLM curator (Managed Agent) at its center. The 1.0 vision: any operator at a hosting provider, MSP, or in-house security team can drive a forensically sound investigation against a compromised host, applying tier-gated defenses and producing a publication-quality incident brief — without touching offensive tooling, without leaking customer data, and without depending on the operator's prior compromise-investigation experience.

## How to read this document

- **Strategic themes** describe long-term direction. Each capability item belongs to one theme.
- **Phased delivery** shows when capabilities ship. Phase boundaries are capability-driven, not calendar-bound.
- **Phase gates** are capability deliverables — the criteria for moving from one phase to the next.
- **Item detail** is the per-capability technical brief, organized by theme. Item numbers are stable cross-references; numbering reflects discovery order, not priority.
- **Out of scope** consolidates explicit anti-features so the decision is durable across future planning passes.
- **Open architectural questions** lists decisions pending input or research.

Items move from this document to the CHANGELOG when shipped.

---

## Strategic themes

**T1 — Detection and evidence.** Expand the surface of what `bl` can see and the quality of what it sees: more log sources, semantic compression, threat-intelligence enrichment, behavioral baselines, forensic capture of volatile state. The further the curator can reason from raw signal toward grounded conclusion, the higher the operator's leverage.

**T2 — Curator efficiency and model strategy.** Reduce per-turn token cost and per-case cost; route work to the right model tier; support sovereign and air-gapped deployments. The curator is the most expensive component on every dimension (latency, cost, complexity), so efficiency compounds.

**T3 — Operator UX and trust.** Make the operator's path through a case faster and more reversible. The most important UX feature in a tool that drives system changes is the ability to undo confidently.

**T4 — Integration and ecosystem.** Connect `bl` to the rest of the security stack: notifications to the channels operators live in, evidence forwarding to SIEM, threat intel feeds in, IOC publication out, fleet-wide operation across hosts, runtime awareness for containerized workloads.

**T5 — Lifecycle and release engineering.** Signed releases, agent version pinning, retire-queue processing, per-case cost telemetry, live verification of API contracts. The infrastructure that makes everything else trustworthy at scale.

**T6 — Trust model and compliance.** Privacy controls, evidence redaction, tamper-evident ledger, privilege drops, data residency. What `bl` needs to be deployable in regulated environments and to produce evidence with chain-of-custody.

**T7 — Platform and extensibility.** Skills marketplace, plugin SDK, distribution parity (ARM64, Alpine, BSD), benchmark and replay infrastructure. The substrate that lets the ecosystem grow beyond what the core team ships.

**T8 — Commercial control plane.** Multi-tenant SaaS variant built atop the OSS CLI; per-tenant case retention, audit trail, and access model.

---

## Phased delivery

### Phase 1 — Operational hygiene and operator trust foundation
- Item 8 — GPG-signed releases
- Item 9 — Manifest rotation, agent retirement, workspace drift reconciliation
- Item 2 — Interactive `bl shell` REPL
- Item 17 (tier 0) — File-level cross-run evidence dedup
- Item 18 — Notification channels and event surface
- Item 22 — `bl undo` universal action revert

### Phase 2 — Detection breadth, source-side compression, ecosystem hooks
- Item 5 — Additional firewall backends and trigger sources
- Item 12 — False-positive corpus tooling
- Item 9 (continued) — `bl setup --retire-queue` operator command
- Item 17 (tiers 1+2+3) — Source-side log compaction (exact dedup, normalization, burst compaction)
- Item 1 — Inline curator tool wiring (`synthesize_defense`, `reconstruct_intent`)
- Item 7 — Session turn delta envelopes
- Item 11 — `bl case note` annotation surface
- Item 13 — Per-source dedup window configuration
- Item 15 — Operator config tree expansion
- Item 19 — Detection coverage expansion (mail, FTP, panel, PHP error, DB, DNS, SSH-auth)
- Item 20 — Threat-intelligence enrichment layer
- Item 21 — Yara integration for known-malware detection
- Item 23 — Case export and handoff formats
- Item 24 — Cost telemetry and operations metrics
- Item 33 — Curator sandbox-as-reasoning-aid prompt discipline
- Item 34 — Environment provisioning — persistent image / `setup_script` probe

### Phase 3 — Fleet operation, sophisticated detection, model strategy
- Item 3 — Multi-host fan-out (`bl observe --fleet`)
- Item 14 — Live API verification across the verb surface
- Item 17 (tier 4) — Cross-source IP correlation in evidence stream
- Item 25 — Container and Kubernetes awareness
- Item 26 — Behavioral baselining
- Item 27 — Curator model strategy and air-gapped operation
- Item 28 — Forensic capture (memory, timeline, procnet)

### Phase 4 — Presentation, extensibility, hardening
- Item 6 — Brief HTML/PDF/multi-language rendering
- Item 10 — Skill extensibility, marketplace, signed skills
- Item 16 — Portability and code quality hardening
- Item 29 — Privacy, redaction, and data residency
- Item 30 — `bl` hardening (privilege drops, ledger integrity, key management)
- Item 31 — Distribution and runtime parity (ARM64, Alpine, BSD)
- Item 32 — Quality engineering infrastructure

### Phase 5 — Commercial control plane
- Item 4 — Multi-tenant SaaS plane with hosted Managed Agents

### Phase gates

- **P1 → P2:** signed-release pipeline operational; cross-run evidence dedup deployed; first notification channel integrated end-to-end; `bl undo` lands at least one action-type inverse (firewall) for operator-trust validation; workspace drift reconciliation operating on `bl setup --reset`.
- **P2 → P3:** at least three new detection collectors shipped (item 19); source-side log compaction deployed with measured ≥10× compression on representative incident replay; threat-intel enrichment operating against at least one external provider; case export validated against at least one external party (vendor abuse, regulator, peer host); per-case cost telemetry visible.
- **P3 → P4:** fleet fan-out operating across multi-host investigations; cross-source IP correlation in production; brief render confirmed against the live curator sandbox; model-tier routing live for cost-sensitive deployments; at least one air-gapped operator deployment validated.
- **P4 → P5:** OSS feature set stable for a 1.0 release; no breaking changes in the `state.json` schema for an extended period; release-signing pipeline supports SaaS-tier auto-update; tamper-evident ledger and operator privilege drops in production; skill marketplace operating with signed-skill verification.

---

## Item detail — by theme

### T1 — Detection and evidence

#### 5. Additional defensive backends and trigger sources

The current backend matrix covers APF, CSF, nftables, and iptables, auto-detected by priority in `_bl_defend_firewall_detect_backend` (`src/bl.d/82-defend.sh`).

**Backends to add:**
- `firewalld` — common on RHEL 8+ / Rocky 9 where `firewall-cmd` is the expected interface; detection slots above `nft` in priority.
- `fail2ban` — `defend firewall --backend fail2ban` writes a jail action rather than a raw IP rule, well-suited to brute-force cases where a duration-bound ban is more appropriate than a permanent block.
- `nft jump` chains — a named bl-managed chain with jump from the base chain, cleaner for rule listing and retirement than the current raw `inet filter input` insert.
- Cloud firewalls — AWS Security Groups, GCP firewall rules, Azure NSGs, Cloudflare WAF — for hosts where the cloud provider's network policy is the enforcement point rather than the host firewall.
- BSD `pf` — for FreeBSD/OpenBSD parity (item 31).

**Trigger sources to add:**
- `bl trigger imunify` — paralleling the existing `bl trigger lmd` flow, sourced from the Imunify scanner output stream.
- `bl trigger modsec-audit` — driven from ModSec audit events as triggers for defensive case-opening.
- `bl trigger falco` — Falco runtime-security events as triggers (relevant for container-aware operation, item 25).

#### 12. False-positive corpus tooling

`_bl_defend_sig_fp_gate` (`src/bl.d/82-defend.sh`) checks `$BL_DEFEND_FP_CORPUS` (default `/var/lib/bl/fp-corpus`) and logs a warning then bypasses the gate when the directory is missing. The corpus is never populated by `bl setup`.

**Capabilities delivered:**
- `bl setup --sync` populates `/var/lib/bl/fp-corpus/` with a baseline set of clean-file samples (vendor PHP trees, common WordPress core files, cPanel-standard scripts) sourced from the `false-positives/` skill subdirectory.
- `bl setup --gc` prunes corpus entries older than 90 days.
- `false-positives/backup-artifact-patterns.md` and `false-positives/encoded-vendor-bundles.md` are the authoring surface for the seed list.

#### 17. Source-side log compaction and normalization

`_bl_obs_emit_jsonl` (`src/bl.d/40-observe-helpers.sh`) writes every parsed record unconditionally. Attack patterns dominated by template-shaped repetition (brute-force, scanner sweeps, ModSec rule storms) produce evidence files 10–100× larger than their information content warrants. The curator reads those files mounted at `/case/<id>/raw/<source>.jsonl` directly — dense noise costs as much as dense signal.

Today's only volume guards are mechanical: journal head-truncated at `BL_OBS_JOURNAL_MAX=10000`, file triage 64 MB hard cap, bundle 100 MB warning / 500 MB hard fail (`41-observe-collectors.sh`, `42-observe-router.sh`). None operate on content semantics.

**Tiered rollout** (build order = dependency order):

**Tier 0 — File-level cross-run dedup.** In `bl_observe_evidence_rotate` (`40-observe-helpers.sh`), SHA-256 the new JSONL stream and skip upload+attach when it matches `prev_sha256` in `<source>.upload.json`. Trivial, zero false-positive risk, immediate win on repeat `bl observe` calls within the same case. No schema change.

**Tier 1+2 — Exact dedup plus path normalization.** A new `_bl_obs_compact_stream` awk pass between the window-filter awk and `_bl_obs_emit_jsonl` in `bl_observe_log_apache` and `bl_observe_log_modsec` (`41-observe-collectors.sh`). Group key is the normalized template (`ip+method+path_norm+status+ua` for apache; `rule_id+normalized_uri+action` for modsec). Normalization rules in awk `gsub`: query-string values → `*`, numeric path segments → `<N>`, hex segments ≥8 chars → `<hash>`, UUIDs → `<uuid>`. Output schema additive: existing fields plus `count`, `first_ts`, `last_ts`, `ip_set[]`, `sample_raw[0..2]`. Forensic anchor preserved via the three raw samples.

**Tier 3 — Burst compaction.** Within a template group, runs of records with `ts_delta < burst_gap` (default 5s) collapse to one burst record with `burst_count`, `burst_start`, `burst_end`. Streaming awk, O(1) memory per in-flight burst. Structurally symmetric to existing `bl_observe_fs_mtime_cluster` output — cross-source curator correlation gets simpler.

**Tier 4 — Cross-source IP correlation.** Case-scoped `$BL_VAR_DIR/cases/<id>/ip-seen.tsv` updated by all collectors under flock. `_bl_obs_emit_jsonl` enriches each record with `correlated_sources[]` listing other sources that observed the same IP. Defers to phase 3: requires a new case-scoped state file and cross-collector coordination.

**Compression expectations** (typical APSB25-94-class incident):

| Source | Raw records | After tiers 1+2+3 |
|---|---|---|
| Apache brute-force burst | 5,000 | 8–20 |
| ModSec rule storm | 800 | 5–12 |
| Journal | 10,000 (capped) | 50–200 |

Couples with item 7 (delta envelopes): item 17 compacts what's in Files (the curator's read-side); item 7 compacts what's in per-turn user messages (the curator's wake-side). Different layers, same goal — both should land before fleet fan-out (item 3) since per-host evidence volume aggregates linearly with host count.

**Schema impact:** additive only. No break to `schemas/evidence-envelope.md`; new fields are optional.

#### 19. Detection coverage expansion

The current observe surface (apache, modsec, journal, fs, file, htaccess, cron, proc, firewall, sigs, substrate) covers the HTTP attack chain well. Hosting compromises commonly start outside that surface.

**New collectors:**

- **Mail (`bl observe mail`)** — postfix / exim queue inspection plus log parsing. Detects mass-spam relay (the most common post-compromise behavior on shared hosting), credential theft via SMTP AUTH brute-force, unusual outbound mail volume per cpuser. Reads from `/var/log/mail.log`, `/var/log/exim_mainlog`, `/var/spool/postfix/`, `/var/spool/exim/`.

- **FTP (`bl observe ftp`)** — vsftpd / pure-ftpd / proftpd auth and transfer logs. Still a top credential-theft vector on shared hosting. Reads from `/var/log/vsftpd.log`, `/var/log/xferlog`, syslog for proftpd.

- **Panel (`bl observe panel`)** — cPanel / Plesk / DirectAdmin / Webmin auth and action logs. Admin-account compromise vector. cPanel: `/usr/local/cpanel/logs/access_log`, `/usr/local/cpanel/logs/login_log`. Plesk: `/var/log/plesk/access_log.processed`. DirectAdmin: `/var/log/directadmin/login.log`.

- **PHP error log (`bl observe php-error`)** — runtime exploit indicators not captured by access logs (memory limit hits during exploitation, fatal errors from injected payloads, deprecated function warnings during shell execution). Reads from common locations including per-vhost error logs and php-fpm pool error logs.

- **Database (`bl observe db`)** — MySQL audit / general / slow log; PostgreSQL `log_statement` output. Data exfiltration indicators via large query results, schema enumeration patterns, suspicious user creation. Reads from `/var/log/mysql/`, `/var/lib/mysql/<host>.log`, PostgreSQL `log_directory`.

- **DNS query (`bl observe dns`)** — outbound DNS query logs from local resolver (named, unbound, dnsmasq). C2 beaconing, DGA domains, suspicious TLD frequency. Optional integration with Pi-hole / AdGuard logs where present.

- **SSH auth (`bl observe ssh-auth`)** — dedicated handler over what `bl observe journal -g sshd` produces today, with brute-force pattern grouping (count per source IP, success-after-N-failures detection) and key-fingerprint vs password-auth distinction.

Each collector follows the existing observe pattern: window-filtered awk pass → `_bl_obs_emit_jsonl` → evidence rotate. Schema additions land in `schemas/evidence-envelope.md`.

#### 20. Threat-intelligence enrichment layer

The curator decides on raw IPs and file hashes with no pre-context. Pre-enrichment dramatically improves decision quality at low cost.

**Enrichment dimensions:**
- **IP reputation** — AbuseIPDB / Spamhaus / OTX / Talos / Cloudflare Radar lookup at observe time. Tagged onto evidence as `enrich.ip_rep: {provider, score, categories[], last_seen}`.
- **ASN / GeoIP / WHOIS** — context for IPs (cloud-provider IPs vs residential vs Tor exits behave very differently in defense decisions). Local MaxMind / Team Cymru lookup; no API call required.
- **Hash reputation** — VirusTotal / Malshare / Hybrid Analysis lookup on the SHA-256 already computed in `bl_observe_file`. Tagged as `enrich.hash_rep: {provider, malicious_count, family[], first_seen}`.
- **Domain / TLD reputation** — for outbound connection investigation (cheap-TLD heuristic plus active-takedown lists).

**Architecture:**
- New `src/bl.d/35-enrich.sh` layer between observe and per-record emit.
- `_bl_enrich_dispatch <field-name> <value>` reads provider config from `/etc/blacklight/enrich.conf`, returns enrichment JSON for inclusion via `_bl_obs_emit_jsonl`.
- Cache layer at `$BL_VAR_DIR/enrich-cache/<provider>/<key>.json` with operator-configurable TTL (default 24h) eliminates repeat lookups across cases.
- BYOK (operator brings their own keys); no vendor lock-in. New providers added as drop-in adapter scripts.
- Fail-open: enrichment failures (rate limit, network down) log a warning and emit the record without enrichment; no observe verb fails on enrichment failure.

**Schema impact:** additive `enrich` field on the evidence envelope.

#### 21. Yara integration — known-malware detection

The FP corpus (item 12) addresses *known-good*. The complement — *known-bad* — is missing. Yara is the industry standard.

**Capabilities delivered:**
- **`bl observe yara <path>`** — scan a path with operator-supplied or shipped rules; emit one evidence record per matched rule with `rule_name`, `tags[]`, `meta{}`, `match_strings[]`, `target_file`.
- **`bl defend yara-block`** — auto-quarantine on match (gated by tier, like other defenses). Wraps existing `bl_clean_quarantine` flow keyed by yara match.
- **Shipped rule library** scoped to webshells (Neo, b374k, c99, WSO, FilesMan), cryptominers (XMRig variants, Coinhive remnants), credential stealers (PHP mailer kits, SMTP spam scripts), backdoors (`eval(base64)` variants, b374k forks).
- **Rule update channel** uses the same delivery mechanism as skills — `bl setup --sync` pulls updated rules from the repo or `BL_REPO_URL`.
- **Operator-local rule directory** at `/etc/blacklight/yara.d/` for proprietary rules that don't ship in the repo.

**Insertion points:**
- New `src/bl.d/43-observe-yara.sh` collector.
- Yara rules stored under `skills/yara/` in the repo.
- Defense path extends existing `82-defend.sh` / `83-clean.sh`.

**Dependency:** yara binary present on host. Detection via `command -v yara`; warning + skip if missing (consistent with `nft` / `apf` handling today).

#### 26. Behavioral baselining

Hosting environments are unusually predictable per-user; baselines from `/proc` snapshots over days build a high-precision anomaly signal at near-zero cost. "User `johndoe` typically runs PHP-FPM and cron; flag when bash + curl + nc appear under that uid."

**Capabilities delivered:**
- **`bl baseline build <user> [--days 7]`** — collect process / network / file-mtime profile over N days. Stored at `$BL_VAR_DIR/baselines/<user>.json`.
- **`bl observe proc --vs-baseline`** — emit anomaly records keyed against the baseline. Each record carries `baseline.process_seen_before: bool`, `baseline.frequency_per_hour`, `baseline.last_seen_days_ago`.
- **Auto-baseline mode** — `bl baseline auto-update` cron job rebuilds baselines on a rolling window (default 14 days).
- **Per-substrate baselines** — different baseline profiles for cPanel / DirectAdmin / Plesk users (different normal process sets).

**Curator integration:** baseline anomaly is a pre-computed signal for the curator, reducing the number of cases where the curator has to discover what's normal from scratch.

**Privacy note:** baselines are operator-local (operator's filesystem); no baseline data ships to the curator unless the operator explicitly attaches the baseline to a case. Default is anomaly summaries only, not raw baseline content.

#### 28. Forensic capture — memory, timeline, procnet

Today `bl` reads disk artifacts. Real forensics needs preservation of volatile state before it changes.

**Capabilities delivered:**

- **`bl capture --memory <pid>`** — `gcore` wrapper that preserves live process memory before the process terminates or self-modifies. Output stored at `$BL_VAR_DIR/cases/<id>/captures/proc-<pid>-<ts>.core` with manifest. Critical for in-memory webshell investigation where the disk shows nothing.

- **`bl capture --path <path>`** — `cp -a` with metadata preservation plus `mtree`-format manifest for chain-of-custody. Used pre-clean to preserve the artifact before `bl clean` modifies it.

- **`bl observe procnet`** — `/proc/net/tcp` + `/proc/net/tcp6` + `/proc/<pid>/net/tcp` parsing for listener and outbound-connection forensics. Identifies live C2 connections and listening backdoors not visible via `ss` / `netstat` (PID hidden via LD_PRELOAD).

- **`bl observe timeline <path>`** — multi-file mtime / ctime / atime correlation across the case scope. Produces an attack chronology evidence record showing the order of file-system events. Heuristic: files modified within 5 seconds of each other are clustered as a single event; clusters are timeline rows.

**Insertion points:**
- New `src/bl.d/85-capture.sh` for capture verbs.
- Existing `41-observe-collectors.sh` extended with `bl_observe_procnet` and `bl_observe_timeline`.

---

### T2 — Curator efficiency and model strategy

#### 1. Inline curator tool wiring — synthesize_defense and reconstruct_intent

The curator agent is provisioned with three custom tools — `report_step`, `synthesize_defense`, and `reconstruct_intent` — but only `report_step` is wired end-to-end. The remaining two are registered in the agent body (`src/bl.d/84-setup.sh`) and documented in the curator system prompt, but the wrapper does not consume their tool-use replies as first-class action surfaces.

Today the curator logs synthesis intent as a free-text `case-log-note` `report_step` and the operator manually invokes `bl defend modsec --from-action <act-id>` to consume the defense payload — an operator friction point and a forward-compatibility gap.

**Capabilities delivered:**
- `synthesize_defense` reply consumed from the pending step queue the same way `report_step` is today; the wrapper routes on `tool_name` rather than `verb`.
- `reconstruct_intent` reply consumed directly into the case attribution memstore key (`attribution.md`), retiring the case-log-note bridge.
- Per-turn synthesizer input shifts to a delta envelope (the diff since the last turn) rather than a full case YAML re-send, reducing per-turn token cost on long cases.

**Prerequisite:** Managed Agents tool-use result routing confirmed stable against the live API.

#### 7. Session turn delta envelopes

Each curator session turn currently re-sends the full case YAML as the user-message content. Long-running cases inflate per-turn token cost and approach the practical re-send ceiling before session renewal is needed.

**Capabilities delivered:**
- Per-turn user message body carries only the diff since the last wake event, not the full case YAML. Full case state remains in the `bl-case/<id>/` memstore (always current).
- Session-wake event body carries `since_event_id` (or equivalent anchor) so the curator can correlate deltas against its in-context case model.
- The case-log-note bridge (item 1) retires in the same pass — both items concern the shape of the turn boundary.

#### 27. Curator model strategy and air-gapped operation

Today the model is hard-coded per verb (Sonnet 4.6 for summaries, Opus for case-state). Three expansions:

**Model tier routing.** Cost-tier routing per case complexity: simple cases → Haiku, complex cases → Opus, default Sonnet. Complexity heuristic from signal count, evidence volume, action tier mix. New `bl_curator_select_model` function in `22-models.sh`.

**Region-pinned inference.** AWS Bedrock / Google Vertex regional Claude endpoints for EU data residency and similar regulatory constraints. The Managed Agents API surface is the same; the client-side endpoint differs. New env var `BL_CURATOR_ENDPOINT` overrides the default.

**Air-gapped / sovereign mode.** Llama / Qwen / Mistral via Ollama or vLLM as a curator backend. Required for classified, regulated, or data-residency environments where Anthropic API access isn't permitted. Quality drops; capability remains. Implemented as an alternate `bl_api_call` path keyed off a config flag; the curator's tool-use protocol is replicated in the open-model path via OpenAI-compatible function-calling.

**Model evaluation harness.** A/B test curator behaviors across model versions on a frozen benchmark suite of representative cases. Captures regression signal before promoting a new model in production. Stored at `tests/eval/cases/` with scoring rubrics.

#### 33. Curator sandbox-as-reasoning-aid prompt discipline

`agent_toolset_20260401` (the platform-provided bash + code-execution tool) is mounted on every `bl-curator` session and used today only for FP-gate validation (`apachectl configtest` for ModSec, benign-corpus scan for sigs, CDN-safelist verify) inside `synthesize_defense`. The same sandbox is available mid-turn for ad-hoc curator reasoning aids: compute mtime cluster centroids over an evidence batch, dry-run a proposed YARA rule against a single attached sample, verify a regex against a substring set, deobfuscate a base64 chain in-context, validate a SecRule's `@rx` with a benchmark string. Today's `prompts/curator-agent.md` does not articulate the in-sandbox-vs-emit-step decision rule, so the curator reaches for the bash tool inconsistently — sometimes emitting an `observe.*` step that could have been a sandbox one-liner, sometimes the reverse.

**Capabilities delivered:**
- A new section in `prompts/curator-agent.md` naming the decision rule: in-sandbox use is curator-private reasoning that does not touch the host and does not warrant an audit-ledger entry; emit-step is anything that touches the host, mutates state, or warrants the operator's gate. The list of canonical in-sandbox uses is enumerated (cluster math, regex verification, dry-run validation, in-context deobfuscation).
- A complementary anti-pattern in §9 of the curator prompt: do not use the sandbox to perform actions that should be wrapper-emitted (no editing host config, no shell-out to ssh, no calls to live external services that bypass the wrapper). The sandbox is a calculator and a parser, not a remote-exec channel.
- A test-suite check (BATS): the curator-mock fixture exercises both branches — at least one fixture step shows curator using the sandbox for a reasoning aid, at least one shows emit-step for a host-touching action. The mock asserts the right branch was taken.

**Why this matters:** the bash tool is the highest-leverage Managed Agents primitive that's currently underused. Articulating the decision rule unlocks the agent for ad-hoc verification mid-investigation without re-introducing the host-mutation surface that the wrapper protects against. The visible curator depth comes from using the full primitive surface — sandbox math + regex verification + dry-run validation alongside the FP-gate path — not from emitting more steps.

#### 34. Environment provisioning — persistent image / `setup_script` probe

`bl-curator-env` is created with `{name, config:{type:"cloud", networking:{type:"unrestricted"}}}` only — `packages` was rejected at env-create on the 2026-04-26 probe (`bl_setup_compose_env_body` in `84-setup.sh:967-984`). Per-session installs of `apache2`, `libapache2-mod-security2`, `modsecurity-crs`, `yara`, `jq`, `zstd`, `duckdb`, `pandoc`, `weasyprint` happen via the bash tool every cold session. This is wasted minutes and tokens on every fresh case.

**Capabilities delivered:**
- Re-probe the `POST /v1/environments` schema for `setup_script`, `image`, or `packages` field acceptance on the latest `managed-agents-2026-04-XX` beta. Probe lives in `tests/integration/probes/env-create-shape.sh` so it re-runs on demand.
- If `setup_script` is accepted: bake the package install into the env body and remove the per-session install fallback from the curator prompt. The session opens with packages already present.
- If only `image` is accepted: ship a tagged base image (`blacklight/curator-env:<version>`) with the package set baked in; reference by image name in env-create.
- If neither is accepted: harden the curator prompt's per-session install path with idempotency (`apt list --installed | grep -q "<pkg>" || apt-get install -y "<pkg>"`) and a single batched install command rather than the current sequential install pattern. Document the gap in `prompts/curator-agent.md` with a re-probe date.

**Why this matters:** every cold session today pays a multi-minute apt-install tax before any reasoning happens. On an MSP running thousands of investigations a month (item 4), this is structural cost. The fix is a probe + a one-line env body change if the surface accepts it.

---

### T3 — Operator UX and trust

#### 2. bl shell — interactive investigation REPL

An interactive `bl shell` subcommand that loops over the pending step queue, presents each step with diff and reasoning, and accepts `y / N / explain / skip / abort` keystrokes without re-invoking `bl run` for each step. Aimed at multi-step incident flows where the operator is at the terminal watching the curator work through a case.

**Capabilities delivered:**
- `bl shell [<case-id>]` subcommand in the verb dispatcher.
- New `src/bl.d/95-shell.sh` (or extension of `60-run.sh` as `bl_run_shell`).
- Per-verb help surface: `bl shell --help`.

The unattended path (`bl_is_unattended`) already handles the no-TTY case; `bl shell` is the TTY-present, operator-led counterpart.

#### 6. Incident brief — HTML, PDF, multi-language

The `bl_case_close_stage2_render` function (`src/bl.d/70-case.sh`) is written: it POSTs a wake event to the curator session requesting HTML and PDF render of the brief Markdown, then polls `/v1/files?scope_id=<session_id>` for up to 60 seconds. The curator sandbox environment declares `pandoc` and `weasyprint` as `packages.apt` in `bl_setup_compose_env_body` (`src/bl.d/84-setup.sh`).

**Capabilities delivered:**
- HTML and PDF rendering operating against the live curator sandbox; live-tested via `tests/live/brief-render-live.bats`.
- Additional formats: DOCX and ODT for downstream tools (legal teams, regulators using office suites).
- Brand-customizable template — per-MSP / per-tenant logos and color schemes via a template directory at `/etc/blacklight/brief-templates/<profile>/`.
- Multi-language brief output — French, German, Spanish, Portuguese, Japanese for international hosting markets. Curator system prompt extension instructs the brief render in the requested language; the template is language-agnostic.

#### 11. bl case note — manual annotation surface

`bl case note "..."` is listed in `bl_help_case` but is not routed in the `bl_case` dispatcher (`src/bl.d/70-case.sh`). The operator currently has no first-class CLI surface for appending freeform annotations to the active case ledger without invoking `bl consult --attach`.

**Capabilities delivered:**
- `note` subcommand in the `bl_case` verb dispatch.
- `case_note` ledger event kind added to `schemas/ledger-event.json` (or reuse of `step_manual`).

#### 22. `bl undo` — universal action revert

Today defenses retire on a timer (retire-queue, item 9). Operators need an immediate revert path: "I was wrong about this firewall block, revert it now." Currently they manually run the inverse command per-backend.

**Capabilities delivered:**
- **`bl undo <action-id>`** — looks up the action mirror in case ledger, dispatches the inverse based on action type. Updates ledger with `action_reverted` event.
- **`bl undo --all-since <timestamp>`** — bulk revert of all defenses applied after a given point. Use case: operator realizes the trigger event was a false positive and wants to revert the case's actions wholesale.
- **`bl history [<case-id>]`** — show applied actions across all cases (or one case) with `action_id`, `type`, `target`, `applied_at`, `retire_hint`, `status`. Selection input for `bl undo`.
- **Per-action-type inverse functions** — `_bl_undo_firewall`, `_bl_undo_modsec`, `_bl_undo_clean`, `_bl_undo_sigs`. Each reads the action mirror and reverses the original change.

**Failure modes handled:**
- Action mirror missing → operator-facing error, no silent failure.
- Reverse change conflicts with new state (firewall rule was already manually removed) → surface the conflict, do not corrupt ledger.
- Reverse not idempotent (quarantined file was overwritten) → ledger records `action_revert_failed` with diagnostic.

**Why this matters:** the ability to safely undo is what makes operators willing to let the curator drive defenses in the first place. Today the implicit answer is "wait for retire timer or manually fix it." A first-class undo flips that.

#### 23. Case export and handoff formats

Hosting providers routinely hand incident data to external parties: vendor abuse teams (registrar, upstream provider), law enforcement, regulators (PCI-DSS forensic, GDPR breach notification, HIPAA breach), and the affected customer. The current case directory is operator-internal; external handoff is ad-hoc.

**Capabilities delivered:**
- **`bl case export <case-id> --format stix2.1`** — STIX 2.1 bundle of IOCs (indicator + observed-data + sighting + identity SDOs). Lingua franca of TI sharing platforms (MISP, OpenCTI, ThreatConnect).
- **`bl case export <case-id> --format json`** — full structured case ledger for analyst tooling. Schema documented in `schemas/case-export-v1.json`.
- **`bl case export <case-id> --format csv`** — flattened evidence rows for spreadsheet analysis (audit teams, regulators).
- **`bl case export <case-id> --format archive`** — self-contained `.tgz` with case directory + manifest + signature for chain-of-custody. Operator-signed via the GPG signing key (item 8).
- **`bl case export <case-id> --redact`** — apply redaction rules from `/etc/blacklight/redact.conf` (regex + field-list); produces a redacted variant safe to share externally.
- **`bl case import <archive>`** — round-trip import on a peer host. Use case: case originates on customer's box, gets exported, analyzed centrally on operator's box.
- **`bl case diff <case-A> <case-B>`** — repeat-offender / campaign correlation; emits a structured diff highlighting shared IPs, shared file hashes, shared rule hits.

**Insertion points:**
- New `src/bl.d/72-case-export.sh`.
- Schema at `schemas/case-export-v1.json` (versioned to allow forward evolution).

---

### T4 — Integration and ecosystem

#### 3. Multi-host fan-out — bl observe --fleet

`bl observe --fleet <hostfile>` fans out the observe verbs to N hosts over SSH, collects per-host evidence bundles locally, and merges them into a single multi-host case for the curator. The curator session receives a combined bundle with per-host labeled evidence streams; its 1M context window correlates cross-host signals without summarization loss.

**Architecture decision pending:** the original design named this as the callsite for Sonnet 4.6 hunters dispatched as Managed Agents `callable_agents`. That primitive was unavailable when the design was written. Revisit whether fleet dispatch is more cleanly a stateless SSH fan-out plus local merge (no new API surface) or Managed Agents orchestration once `callable_agents` is stable.

**Explicitly cut:** no fleet daemon, no persistent fleet agent, no heartbeat/health-check protocol. Each host runs `bl` as a stateless CLI; the orchestration layer is the operator's SSH access plus a merge script.

#### 18. Notification channels and event surface

`bl` is operated at the terminal today. Hosting NOCs operate from chat, paging, and SIEM consoles. The `notify_channels_enabled` config exists but no concrete channel implementations follow it — the surface is asymmetric.

This item delivers the outbound integration surface as a uniform event bus with multiple channel adapters.

**Capabilities delivered:**
- **Standard channels:** Slack, Discord, Mattermost, Microsoft Teams, PagerDuty, OpsGenie, email (SMTP).
- **Generic webhook channel:** HTTPS POST with HMAC-signed body for downstream automation (Splunk HEC, Elastic, custom workflow engines).
- **SIEM forwarders:** STIX 2.1 export of case ledger; CEF / LEEF for Splunk / QRadar; Elastic Common Schema for ELK; JSON for Datadog.
- **Threat-intel publication:** push case IOCs to MISP / OpenCTI / TAXII servers as a complement to consumption (item 20).
- **Event taxonomy:** `case.opened`, `case.closed`, `defense.applied`, `defense.reverted`, `brief.ready`, `step.failed`, `outbox.stale`. Each event carries a stable JSON schema in `schemas/notify-event.json`.
- **Per-channel severity floors:** a noisy channel gets only `case.opened` / `case.closed`; a paging channel gets only severity-high events.
- **Channel config** in `/etc/blacklight/notify.conf` with operator-managed credentials referenced via env-var indirection (no plaintext secrets in config).

**Insertion points:**
- Existing `src/bl.d/28-notify.sh` extended with channel-specific senders.
- `_bl_notify_dispatch <event-kind> <payload-file>` called from case-state-transition functions in `70-case.sh` and `60-run.sh`.

#### 25. Container and Kubernetes awareness

Modern hosting is mixed: LXC for shared, Docker for VPS, K8s for managed app platforms. `bl observe` today reads host paths. Container workloads have their own filesystem namespaces, log streams, and process trees.

**Capabilities delivered:**
- **`bl observe --container <id>`** — observe evidence inside a running container via `docker exec` / `nsenter` / `kubectl exec`, depending on detected runtime.
- **Runtime detection** — `_bl_observe_detect_container_runtime` priority: `docker` → `podman` → `nerdctl` → `kubectl`. Cached in case state.
- **Per-container evidence scope** — case attribute `container_id` / `container_runtime` / `pod_namespace` populated; evidence records tagged for cross-container correlation.
- **`bl trigger docker`** — accept Docker / Podman / Falco events as case triggers.
- **K8s namespace awareness** — `bl consult --new --namespace <ns>` opens a case scoped to a namespace; observe verbs default to that namespace.

**Insertion points:**
- New `src/bl.d/44-observe-container.sh` for runtime detection and evidence scoping.
- `_bl_obs_open_stream` extended to thread container scope into evidence path.

**Explicitly NOT taken:** running `bl` itself inside a container as a sidecar / DaemonSet pattern. The hosting-provider model is that operators run `bl` from the bastion host or a control-plane node and observe into target containers — not deploy `bl` to every workload.

---

### T5 — Lifecycle and release engineering

#### 8. Signed releases (GPG)

`bl setup --resolve-source` already has a priority order (`BL_REPO_ROOT` → cwd → `BL_REPO_URL` → GitHub clone, `bl_setup_resolve_source` in `src/bl.d/84-setup.sh`). Signing extends this:

- `make release` signs the assembled `bl` artifact with the project release key, emitting `bl.sig`.
- `install.sh` verifies the signature before placing the binary.
- The `BL_REPO_URL` curl-pipe-bash path carries `bl.sig` as a sidecar and verifies before `exec`.

Required prerequisite for the SaaS control plane (item 4) — tenant hosts cannot safely auto-update `bl` without operator re-approval of each version unless the binary is signed and verified. Also a prerequisite for the case archive signing path in item 23.

#### 9. Manifest rotation, agent retirement, workspace drift reconciliation

`bl setup --gc` deletes `files_pending_deletion` entries when no live sessions reference them. `bl setup --reset` tears down the agent and Files. Three gaps remain:

**Agent version pinning.** When `bl setup --eval --promote` bumps the agent, sessions referencing the previous version are not invalidated or migrated. After this lands, `state.json` tracks `agent.version` (CAS field); on `--promote`, sessions on the previous version receive a deprecation notice in the outbox.

**Retire-queue processing.** `bl_case_close_schedule_retire` (`src/bl.d/70-case.sh`) appends entries to `retire-queue.jsonl` for applied actions (firewall rules, modsec configs, signature appends) with a `retire_hint` duration. After this lands, `bl setup --retire-queue` reads the queue, presents expired entries (past their retire hint), and asks the operator whether to revoke each.

**Workspace drift reconciliation.** `bl_files_list_workspace` (`src/bl.d/23-files.sh`) — `GET /v1/files[?path_prefix=]` — is defined but unwired. `bl setup --reset` and `--gc` currently treat `state.json` as authoritative source-of-truth for the workspace; any drift (interrupted reset, out-of-band API ops, lost/stale `state.json`, two operators sharing one workspace) leaks orphan Files indefinitely. Three consumers were identified during planning but none landed. Pickup order:

1. `bl setup --reset` — highest value. After the state-driven delete pass, list the live workspace and delete file_ids not in `state.json`. Reset is the operator's "I've lost confidence in local state" verb; it's the case where ignoring the live workspace is most wrong.
2. `bl setup --check` — new diagnostic verb. Prints workspace-vs-`state.json` drift without mutating; closes the verifier gap.
3. `bl setup --gc` — extend to enumerate workspace files not represented in `.files{}` and queue them into `files_pending_deletion`. Lowest priority — drift orphans here are storage cost, not correctness.

#### 13. Per-source dedup window configuration

`bl trigger lmd` reads `BL_LMD_TRIGGER_DEDUP_WINDOW_HOURS` (default 24h) from `blacklight.conf`. When `bl trigger imunify` and `bl trigger modsec-audit` land (item 5), each needs its own dedup window config key. The `_bl_load_blacklight_conf` allowlist (`src/bl.d/30-preflight.sh`) extends to cover them.

#### 14. Live API verification across the verb surface

`tests/live/setup-live.bats` runs `bl setup` against the real Anthropic API. Live tests do not yet exist for:
- `bl observe apache` → real log lines → real Sonnet 4.6 summary render
- `bl consult --new` → real session creation → real pending step poll
- `bl run` → real step execution → real result POST
- `bl case close` → real brief render (stage-2 HTML/PDF poll)
- `bl defend modsec` → real `apachectl -t` configtest (requires a host with Apache)

These are the only ground-truth proof that the API shapes documented during development are correct end-to-end.

#### 15. Operator config tree expansion

`/etc/blacklight/blacklight.conf` currently allowlists: `unattended_mode`, `notify_channels_enabled`, `notify_severity_floor`, `lmd_trigger_dedup_window_hours`, `lmd_conf_path`, `cpanel_lockin`, `cpanel_lockin_timeout_seconds`.

**Pending keys:**
- `fp_corpus_dir` — override for `/var/lib/bl/fp-corpus`
- `defend_fw_allow_broad_ip` — site-level override for the CIDR /16 floor (currently env-var-only via `BL_DEFEND_FW_ALLOW_BROAD_IP`)
- `brief_mimes` — site-level override for `BL_BRIEF_MIMES`
- `skill_dir` — external skill directory path (item 10)
- `outbox_age_warn_secs` — preflight outbox drain threshold override
- `enrich_provider_*` — per-provider TI enrichment config (item 20)
- `cost_alert_per_case_usd` — cost-anomaly threshold (item 24)

#### 24. Cost telemetry and operations metrics

Operators running hundreds or thousands of investigations need cost attribution per case, per tenant, per case-template. The Managed Agents API exposes token counts on session events; today nothing surfaces them.

**Capabilities delivered:**
- **Per-case cost sidecar** at `$BL_VAR_DIR/cases/<id>/cost.json` updated at every session-event poll. Tracks `input_tokens`, `output_tokens`, `cache_read_tokens`, `cache_creation_tokens`, `model`, computed `cost_usd_estimate`.
- **`bl case cost <case-id>`** — show cost summary for a case.
- **`bl status --metrics`** — operator dashboard view: cases-opened-today, mean-time-to-close, defenses-applied, top-cost cases, model usage breakdown.
- **Prometheus / OpenMetrics export** at `/var/run/blacklight/metrics` (text-format file scraped by node_exporter or a sidecar) for fleet-wide observability.
- **Operator alerts on cost anomalies** — configurable threshold (`cost_alert_per_case_usd` in blacklight.conf) emits a notification (item 18) when crossed.

**Why this matters:** cost-blind operation is fine for a single-incident exercise and unworkable for an MSP running thousands of investigations a month. Per-case cost attribution makes `bl` deployable at scale.

---

### T6 — Trust model and compliance

#### 16. Portability and code quality hardening

**`mv -T` portability** (`src/bl.d/83-clean.sh`). `mv -T` is a GNU coreutils extension; BSD `mv` does not support it. On BSD-derived systems, the final rename in `bl_clean_unquarantine` falls back to a non-atomic `mv`. The TOCTOU window remains narrow (the staged inode is in the same parent) but is not closed on BSD. Mitigation: a small `rename(2)` C helper, or document the BSD caveat explicitly.

**`local var=$(...)` exit-code masking.** Several older functions predate the `local var; var=$(...)` split required by the coding convention. Shell exit-code capture is masked when `local` and assignment land on the same line. A `shellcheck SC2155` sweep surfaces remaining instances.

#### 29. Privacy, redaction, and data residency controls

The current `_bl_obs_emit_jsonl` scrub handles a small set of internal-domain patterns. Real privacy controls for regulated deployment need broader coverage and operator-configurable rules.

**Capabilities delivered:**

- **Secrets-in-evidence redaction** — pre-upload scrub of API keys, JWT tokens, credit-card patterns, AWS access keys, SSH private keys, basic-auth headers, OAuth bearer tokens. New `_bl_obs_secret_scrub` function called from `_bl_obs_emit_jsonl`. Patterns in `prompts/secret-patterns.txt` (operator-extensible).

- **Operator-side encryption before Files upload** — symmetric encryption of evidence files with operator-managed key (`age` or `gpg --symmetric`). Curator's view is unaffected (decryption happens in the curator sandbox via a per-case key delivered as an attached file). Use case: hosts where customer-data sensitivity prevents plaintext upload to Anthropic Files even with TLS.

- **GDPR / CCPA retention controls** — `bl case archive <case-id>` moves a case to compressed cold storage after operator-defined retention; `bl case purge <case-id>` permanently removes it. Per-tenant retention overrides via blacklight.conf.

- **PII detection in briefs** — pre-publication scan of brief content against PII patterns (email, phone, full names from a configurable list); flags for operator review before publication.

- **Right-to-erasure compliance** — `bl case purge --pii-of <identifier>` removes all evidence records mentioning the identifier from the case ledger and re-renders the brief without them. Required for GDPR Article 17 compliance.

#### 30. `bl` hardening — privilege drops, ledger integrity, key management

Operational hardening of `bl` itself for high-trust deployments.

**Capabilities delivered:**

- **Tamper-evident case ledger** — append-only with cryptographic chaining. Each ledger event includes `prev_hash` (sha256 of prior event); the case directory carries a `LEDGER.sig` signed by the operator's GPG key on case-close. Required for chain-of-custody in legal proceedings. Verification via `bl case verify <case-id>` re-walks the chain and validates the signature.

- **Privilege drops** — `bl` running as non-root with file capabilities. CAP_NET_ADMIN only acquired transiently when defending firewall; CAP_DAC_READ_SEARCH only when reading restricted logs (root-owned with non-readable mode). Reduces blast radius if `bl` itself becomes a target. Implemented via `setcap` on the binary plus per-verb capability acquisition.

- **Multi-key / per-tenant API-key support** — beyond a single `ANTHROPIC_API_KEY` env var. Per-tenant or per-case key selection via `BL_KEY_PROFILE=<profile>`. Profiles defined in `/etc/blacklight/keys.conf` with per-profile key, model defaults, retention policy.

- **Outbox tamper detection** — outbox events HMAC-tagged with a per-case symmetric key; a tampered outbox event is detected at drain time and emits an alert rather than silently executing.

- **Audit log of bl-operator actions** — every `bl` invocation logged to `/var/log/blacklight/audit.log` with operator uid, command, args, exit status. For multi-operator environments where accountability matters.

---

### T7 — Platform and extensibility

#### 10. Skill extensibility, marketplace, signed skills

The routing Skills bundle ships routing Skills plus a corpus of doctrine markdown. Third-party extensibility is supported in principle: drop a `SKILL.md` plus `description.txt` into a new directory under `skills/`, run `make bl`, run `bl setup --sync`. Several gaps remain:

- **External skill directories.** `bl setup --sync` only reads from `BL_REPO_ROOT/skills/`. An operator with a proprietary WAF grammar or vendor-specific runbook has no `--skill-dir` flag for an external path.
- **Skill authorship validation.** `bl_setup_seed_skills` checks the 1024-char description.txt cap but does not validate `SKILL.md` structure or warn on bodies that exceed the effective context window share.
- **Substrate role config.** The `ride-the-substrate` skill family covers apache/nginx/litespeed log path discovery, but the curator cannot be configured to assume a substrate at case-open time (e.g. `bl consult --new --substrate nginx`). After this lands, the substrate flag lets the curator skip discovery and go directly to the relevant log paths.
- **Public skill marketplace / community runbooks.** Community-contributed skill bundles published via a registry (`bl setup --add-bundle <url>`). Use case: vendor-specific runbooks (Magento / WordPress / Joomla / cPanel / Plesk) authored by domain experts beyond the core team.
- **Signed skills.** Each marketplace skill carries a signature; `bl setup --sync` rejects bundles that fail signature verification. Builds on item 8's signing infrastructure.

#### 31. Distribution and runtime parity

Current target matrix: CentOS 6, CentOS 7, Rocky 8, Rocky 9, Ubuntu 20.04, Ubuntu 24.04, Debian 12, Gentoo, Slackware, FreeBSD (partial). Several runtime gaps reduce reach.

**Capabilities delivered:**
- **ARM64 build matrix** — CI matrix extended to include `linux/arm64` for Raspberry Pi / AWS Graviton / Apple Silicon hosts. Most of `bl` is bash + jq + awk so portability is high; the test matrix needs to confirm.
- **Alpine / musl libc compatibility** — Alpine is the dominant container distro; running `bl` from an Alpine sidecar requires musl-compatible binary dependencies. Validation pass on coreutils variants (busybox vs GNU).
- **Full FreeBSD parity** — current state is "partial". Identify the gaps (BSD `find -newermt`, BSD `stat`, BSD `mv -T` from item 16) and close them. Bring FreeBSD into the standard test matrix.
- **OpenBSD support** — `pf` firewall backend, OpenBSD-specific log paths, OpenBSD's `ksh` vs bash compatibility surface. Niche but real for security-focused deployments.
- **Rocky / Alma 10 readiness** — once those distros ship, validate the matrix rolls forward without regression.

#### 32. Quality engineering infrastructure

Cross-cutting infrastructure that improves quality across all other items.

**Capabilities delivered:**

- **Performance benchmark suite** — track curator round-trip time, observe-bundle build time, evidence compaction ratio, end-to-end case-time across releases. Stored at `tests/perf/` with results regression-tracked in CI.

- **Replay / record harness** — re-run a stored case against a new model version to catch regressions. Cases are recorded with full session-event stream during a real run; replay re-executes against a target model and diffs the curator decisions. Stored at `tests/replay/cases/`.

- **Chaos testing** — controlled fault injection (network blips during curator session, partial Files API failures, slow-poll responses). Validates that `bl` handles real-world API misbehavior gracefully. New `tests/chaos/` directory with bats tests under fault-injection mocks.

- **Training mode (`bl train`)** — operator runs against synthetic incidents to learn the workflow without touching production hosts. Synthetic case fixtures shipped as a training corpus.

- **Plugin SDK** — formalized contract for third-party verbs (`bl defend <vendor-tool>`, `bl observe <vendor-source>`). Documented at `docs/plugin-sdk.md`. Plugins drop into `~/.config/bl/plugins/` and register via a manifest.

---

### T8 — Commercial control plane

#### 4. SaaS control plane and multi-tenancy

A hosted plane with per-tenant Managed Agents, per-tenant case retention and audit trail, web frontend for case review, and role-based access (operator / analyst / regulator). This is a commercial product build above the OSS `bl` CLI, not a CLI extension.

**OSS-side prerequisites:**
- Stable `state.json` schema version with no breaking changes during the period.
- Signed releases (item 8) so the SaaS plane can pin `bl` versions and verify binary integrity before tenant provisioning.
- `BL_REPO_URL` env override (already present) lets the SaaS plane point hosts at tenant-specific skill bundles or frozen releases.
- Tamper-evident ledger (item 30) for audit-trail integrity guarantees the SaaS tier exposes to tenants.
- Per-tenant key isolation (item 30) for cost and data-flow attribution.
- Privacy and residency controls (item 29) for regulated-tier variants (HIPAA-eligible, PCI-eligible, FedRAMP-eligible planes).

**SaaS-tier dimensions to design:**
- Tenant isolation model — hard process separation vs scoped namespacing within a shared agent pool.
- Regulated-tier variants — separate planes for HIPAA / PCI / FedRAMP with different inference-region, retention, and access-log requirements.
- Audit-trail format — standardized export to tenant-side SIEM via item 18's webhook surface.
- Billing model — per-case, per-host, per-defense-applied, or hybrid. Driven by item 24's cost telemetry.

---

## Out of scope

Day 1 Explicit anti-features. Listed here so the decision is durable across future planning passes.

- **Drain3-style tree-based template mining in awk.** The Python implementation produces a parse tree approximating a token-position lattice; porting to awk yields subtly wrong merge behavior on non-web log formats. Item 17 tier 2's normalization captures most of Drain's benefit on web/audit logs at zero correctness risk. Revisit only when an external `bl-helper` binary becomes acceptable scope.
- **Bloom-filter cross-run dedup in pure bash.** Item 17 tier 0's content-hash file comparison is the simpler exact equivalent.
- **Persistent fleet daemon / heartbeat protocol.** Item 3 fleet operation is stateless SSH fan-out. A daemon on each host adds attack surface and operational complexity for marginal benefit.
- **`bl` as DaemonSet sidecar / per-workload deploy.** Item 25 container awareness is operated from the bastion or control-plane node observing into target containers, not deployed to every workload.
- **Offensive security tooling integration.** `bl` is defensive forensics. No exploitation, no penetration testing, no attack simulation. Framing rule, not a roadmap negotiation.
- **Unsupervised auto-defense without operator review.** The tier model (auto / suggested / destructive) exists for a reason. Even at SaaS scale, there is no "fully autonomous" mode. Unattended mode (`bl_is_unattended`) auto-applies *only* tier-0/auto-tier defenses; everything else queues for operator review.
- **Unsigned skill marketplace contributions.** Item 10's marketplace requires signature verification (item 8 + signed skills). No anonymous-contribution path.
- **Customer data retention by default.** Item 29 retention controls default to operator-configurable purge windows. There is no "keep forever" default — that is a deliberate operator choice.

---

## Open architectural questions

Decisions pending input, research, or convergence with upstream API surface.

- **Fleet dispatch primitive (item 3).** SSH fan-out plus local merge vs Managed Agents `callable_agents` orchestration. Decision pending `callable_agents` API stability and a side-by-side cost/latency comparison on a multi-host investigation.
- **Local-model fallback quality floor (item 27).** At what point does open-model curator output drop below the framing's "trustworthy curator" bar? Threshold is operator-defined per deployment; the question is whether to ship an opinionated default or leave it as a config knob.
- **Per-action-type undo dispatch (item 22).** Action mirror as canonical inverse vs per-backend inverse logic. Trade-off: action-mirror is more declarative but requires every defense path to write a complete inverse-instruction record at apply time; per-backend is more code but doesn't change the apply path.
- **Cross-tenant skill isolation in SaaS (items 4, 10).** Hard separation (per-tenant skill bundle namespaces with no cross-flow) vs scoped namespacing (shared bundle with per-tenant ACLs). Hard separation is simpler and safer; scoped namespacing reduces operator overhead for shared community skills.
- **Tamper-evident ledger format (item 30).** Hash-chain (simple, verifiable) vs Merkle tree (parallelizable verification, more complex) vs append-only signed log (e.g. `signify` / `minisign`). Decision driven by the chain-of-custody requirements of the legal jurisdictions operators ship to.
- **Memstore encryption boundary (item 29).** Encrypt at evidence-emit time (operator side) vs encrypt at Files-upload time (transport side). The former is stronger but requires curator-sandbox decryption; the latter is simpler but doesn't protect against Anthropic-side data exposure scenarios that some regulated tenants care about.
- **Cost-tier routing heuristic (item 27).** Static rule (signal count above threshold → Opus) vs adaptive (curator self-evaluates and requests escalation). Adaptive is more powerful but adds a meta-model loop that complicates the cost story.

---

## M17 sentinel carry-forwards (2026-04-28)

Advisories surfaced during the M17 end-of-plan sentinel review (`m17` branch, post-Phase-8). Captured here so the knowledge survives squash-merge.

- **`bl_setup_skills_gc` first-page-only listing.** `src/bl.d/84-setup.sh:686-744` consumes only `.data[]` from the first response of `GET /v1/skills` and `GET /v1/files`; no `has_more`/`next_cursor`/`after_id` handling. Benign today (orphan set is bounded: 3 v1 titles + 6 routing-skill names) but if a workspace ever crosses page-size boundary the GC silently retains orphans on subsequent pages. Mitigation: pagination loop, OR document first-page-only behavior in `bl setup --gc --help`.
- **Foundations-corpus / curator-prompt drift.** `bl_setup_seed_corpus` (~`src/bl.d/84-setup.sh:506`) still uploads `foundations.md` as a workspace File and `bl_setup_attach_session_resources` still attaches it, but P5's curator-prompt rewrite removed the `/skills/foundations.md` read-first instruction. Either restore the read step in `prompts/curator-agent.md` §3.2 or stop uploading/attaching the foundations corpus File. Q3 (a) bundles a per-skill `foundations.md` inside each routing-skill bundle — that path is the canonical reference; the workspace-File copy is now ambiguous.
- **Skill-version drift coupling under Q1 `version: "latest"`.** `bl_setup_ensure_agent` drift detection (`src/bl.d/84-setup.sh:850`) compares only `state.skills[$n].id` against `state.agent.skill_versions[$n]`. Skill-version bumps with stable `skill_id` never trigger a CAS update. Correct under M17's `version: "latest"` choice (agent picks up new versions on session-create automatically) but if the operator ever pins to specific version values, the drift detector goes silent for version-bumps. Document the coupling, OR add a sha-based drift signal that fires regardless of pinning mode.
- **DEV MODE escalation: new shell-out dependency.** P4's `bl_setup_seed_skills_native` introduced `zip` as a new shell-out tool used in `src/bl.d/84-setup.sh`; the test container images lacked it; `make -C tests test-quick` (smoke + CLI surface) didn't link against zip; the gap surfaced only during P5's full-matrix run. The DEV MODE banner in `CLAUDE.md` does not list "added a new shell-out dependency" as a heavy-test escalation trigger. Add to the trigger list, OR extend the workspace CLAUDE.md verification grep block with a non-coreutil shell-out catch (e.g., `grep -rEn '^\s*(zip|unzip|tar|gzip|sha256sum|base64) ' src/bl.d/`).
- **Pre-existing test-name drift in `tests/08-setup.bats`.** Test names like *"pre-seeded state → no-op summary, zero create calls"* and *"sha-match → skip seed_skills"* describe assertions that were never actually checked (the test bodies don't count API POSTs). The schema-drift sweep migrated all sites to the canonical `sha256:` key, but the test bodies still don't honor the names. A future sweep should add the missing API-call-count assertions; or rename the tests to match what they actually verify.

These are all advisory; M17's load-bearing claims (env packages, native Skills attachment, agent.skills:[] with `version: "latest"`, v1-orphan cleanup, beta-header centralization) are realized and tested.

