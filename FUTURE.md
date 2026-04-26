# FUTURE.md — blacklight roadmap

blacklight (`bl`) is a defensive forensics CLI that turns post-incident
investigation on web hosting infrastructure into a guided, auditable
workflow with an LLM curator (Managed Agent) at its center. This
document is the forward-looking roadmap: capabilities planned beyond
the current shipping release, organized by release phase.

The roadmap is capability-driven. Phase boundaries are defined by
delivered function, not calendar dates. Items move from this document
to the CHANGELOG when shipped.

---

## Roadmap

### Phase 1 — Operational hygiene and signing
- GPG-signed releases (item 8)
- Manifest rotation and agent retirement lifecycle (item 9)
- Interactive `bl shell` REPL (item 2)
- File-level cross-run evidence dedup (item 17, tier 0)

### Phase 2 — Detection breadth and source-side compression
- Additional trigger sources: `imunify`, `modsec-audit` (item 5)
- Additional firewall backends: `firewalld`, `fail2ban`, `nft jump` chains (item 5)
- False-positive corpus tooling (item 12)
- `bl setup --retire-queue` operator command (extends item 9)
- Source-side log compaction: exact dedup, path normalization, burst compaction (item 17, tiers 1+2+3)
- Inline curator tool wiring: `synthesize_defense`, `reconstruct_intent` (item 1)
- Session turn delta envelopes (item 7)
- `bl case note` annotation surface (item 11)
- Operator config tree expansion (items 13, 15)

### Phase 3 — Fleet operation and cross-source correlation
- Multi-host fan-out: `bl observe --fleet` (item 3)
- `callable_agents` integration for hunter dispatch — pending API stability (item 3)
- Live API end-to-end verification across the verb surface (item 14)
- Cross-source IP correlation in evidence stream (item 17, tier 4)

### Phase 4 — Skill extensibility and presentation
- Role-swappable substrate config (item 10)
- External skill directories with operator-local authoring (item 10)
- Brief HTML/PDF production-quality rendering (item 6)
- Portability and code quality hardening (item 16)

### Phase 5 — Commercial control plane
- Multi-tenant SaaS plane with hosted Managed Agents (item 4)
- Per-tenant case retention and audit trail (item 4)
- Web frontend for case review (item 4)
- Role-based access — operator, analyst, regulator (item 4)

### Phase gates

- **P1 → P2:** signed-release pipeline operational; cross-run evidence dedup deployed.
- **P2 → P3:** at least one additional trigger source shipped; source-side log compaction deployed with measured ≥10× compression on representative incident replay; live API verification covers the core verb surface (`observe`, `consult`, `run`, `case close`).
- **P3 → P4:** fleet fan-out operating across multi-host investigations; cross-source IP correlation in production; brief render confirmed against the live curator sandbox.
- **P4 → P5:** OSS feature set stable for a 1.0 release; no breaking changes in the `state.json` schema for an extended period; release-signing pipeline supports SaaS-tier auto-update.

---

## 1. Inline curator tool wiring — synthesize_defense and reconstruct_intent

The curator agent is provisioned with three custom tools — `report_step`, `synthesize_defense`, and `reconstruct_intent` — but only `report_step` is wired end-to-end. The remaining two are registered in the agent body (`src/bl.d/84-setup.sh`) and documented in the curator system prompt, but the wrapper does not consume their tool-use replies as first-class action surfaces.

Today the curator logs synthesis intent as a free-text `case-log-note` `report_step` and the operator manually invokes `bl defend modsec --from-action <act-id>` to consume the defense payload — an operator friction point and a forward-compatibility gap.

**Capabilities delivered:**
- `synthesize_defense` reply consumed from the pending step queue the same way `report_step` is today; the wrapper routes on `tool_name` rather than `verb`.
- `reconstruct_intent` reply consumed directly into the case attribution memstore key (`attribution.md`), retiring the case-log-note bridge.
- Per-turn synthesizer input shifts to a delta envelope (the diff since the last turn) rather than a full case YAML re-send, reducing per-turn token cost on long cases.

**Prerequisite:** Managed Agents tool-use result routing confirmed stable against the live API.

---

## 2. bl shell — interactive investigation REPL

An interactive `bl shell` subcommand that loops over the pending step queue, presents each step with diff and reasoning, and accepts `y / N / explain / skip / abort` keystrokes without re-invoking `bl run` for each step. Aimed at multi-step incident flows where the operator is at the terminal watching the curator work through a case.

**Capabilities delivered:**
- `bl shell [<case-id>]` subcommand in the verb dispatcher.
- New `src/bl.d/95-shell.sh` (or extension of `60-run.sh` as `bl_run_shell`).
- Per-verb help surface: `bl shell --help`.

The unattended path (`bl_is_unattended`) already handles the no-TTY case; `bl shell` is the TTY-present, operator-led counterpart.

---

## 3. Multi-host fan-out — bl observe --fleet

`bl observe --fleet <hostfile>` fans out the observe verbs to N hosts over SSH, collects per-host evidence bundles locally, and merges them into a single multi-host case for the curator. The curator session receives a combined bundle with per-host labeled evidence streams; its 1M context window correlates cross-host signals without summarization loss.

**Architecture decision pending:** the original design named this as the callsite for Sonnet 4.6 hunters dispatched as Managed Agents `callable_agents`. That primitive was unavailable when the design was written. Revisit whether fleet dispatch is more cleanly a stateless SSH fan-out plus local merge (no new API surface) or Managed Agents orchestration once `callable_agents` is stable.

**Explicitly cut:** no fleet daemon, no persistent fleet agent, no heartbeat/health-check protocol. Each host runs `bl` as a stateless CLI; the orchestration layer is the operator's SSH access plus a merge script.

---

## 4. SaaS control plane and multi-tenancy

A hosted plane with per-tenant Managed Agents, per-tenant case retention and audit trail, web frontend for case review, and role-based access (operator / analyst / regulator). This is a commercial product build above the OSS `bl` CLI, not a CLI extension.

**OSS-side prerequisites:**
- Stable `state.json` schema version with no breaking changes during the period.
- Signed releases (item 8) so the SaaS plane can pin `bl` versions and verify binary integrity before tenant provisioning.
- `BL_REPO_URL` env override (already present) lets the SaaS plane point hosts at tenant-specific skill bundles or frozen releases.

---

## 5. Additional defensive backends and trigger sources

The current backend matrix covers APF, CSF, nftables, and iptables, auto-detected by priority in `_bl_defend_firewall_detect_backend` (`src/bl.d/82-defend.sh`).

**Backends to add:**
- `firewalld` — common on RHEL 8+ / Rocky 9 where `firewall-cmd` is the expected interface; detection slots above `nft` in priority.
- `fail2ban` — `defend firewall --backend fail2ban` writes a jail action rather than a raw IP rule, well-suited to brute-force cases where a duration-bound ban is more appropriate than a permanent block.
- `nft jump` chains — a named bl-managed chain with jump from the base chain, cleaner for rule listing and retirement than the current raw `inet filter input` insert.

**Trigger sources to add:**
- `bl trigger imunify` — paralleling the existing `bl trigger lmd` flow, sourced from the Imunify scanner output stream.
- `bl trigger modsec-audit` — driven from ModSec audit events as triggers for defensive case-opening.

---

## 6. Incident brief — HTML and PDF rendering

The `bl_case_close_stage2_render` function (`src/bl.d/70-case.sh`) is written: it POSTs a wake event to the curator session requesting HTML and PDF render of the brief Markdown, then polls `/v1/files?scope_id=<session_id>` for up to 60 seconds. The curator sandbox environment declares `pandoc` and `weasyprint` as `packages.apt` in `bl_setup_compose_env_body` (`src/bl.d/84-setup.sh`).

**To validate against the live curator sandbox:**
- Confirm `pandoc` and `weasyprint` are actually installed at the declared versions.
- The stage-2 render path is gated by `BL_BRIEF_MIMES=text/markdown,text/html,application/pdf`; the path is mock-tested but not yet live-tested.

**Validation:** `tests/live/brief-render-live.bats` exercises `bl case close` against a real session and confirms `brief-CASE-*.{html,pdf}` appear in the Files API response.

---

## 7. Session turn delta envelopes

Each curator session turn currently re-sends the full case YAML as the user-message content. Long-running cases inflate per-turn token cost and approach the practical re-send ceiling before session renewal is needed.

**Capabilities delivered:**
- Per-turn user message body carries only the diff since the last wake event, not the full case YAML. Full case state remains in the `bl-case/<id>/` memstore (always current).
- Session-wake event body carries `since_event_id` (or equivalent anchor) so the curator can correlate deltas against its in-context case model.
- The case-log-note bridge (item 1) retires in the same pass — both items concern the shape of the turn boundary.

---

## 8. Signed releases (GPG)

`bl setup --resolve-source` already has a priority order (`BL_REPO_ROOT` → cwd → `BL_REPO_URL` → GitHub clone, `bl_setup_resolve_source` in `src/bl.d/84-setup.sh`). Signing extends this:

- `make release` signs the assembled `bl` artifact with the project release key, emitting `bl.sig`.
- `install.sh` verifies the signature before placing the binary.
- The `BL_REPO_URL` curl-pipe-bash path carries `bl.sig` as a sidecar and verifies before `exec`.

Required prerequisite for the SaaS control plane (item 4) — tenant hosts cannot safely auto-update `bl` without operator re-approval of each version unless the binary is signed and verified.

---

## 9. Manifest rotation and agent retirement lifecycle

`bl setup --gc` deletes `files_pending_deletion` entries when no live sessions reference them. `bl setup --reset` tears down the agent and Files. Two gaps remain:

**Agent version pinning.** When `bl setup --eval --promote` bumps the agent, sessions referencing the previous version are not invalidated or migrated. After this lands, `state.json` tracks `agent.version` (CAS field); on `--promote`, sessions on the previous version receive a deprecation notice in the outbox.

**Retire-queue processing.** `bl_case_close_schedule_retire` (`src/bl.d/70-case.sh`) appends entries to `retire-queue.jsonl` for applied actions (firewall rules, modsec configs, signature appends) with a `retire_hint` duration. After this lands, `bl setup --retire-queue` reads the queue, presents expired entries (past their retire hint), and asks the operator whether to revoke each.

**Workspace drift reconciliation.** `bl_files_list_workspace` (`src/bl.d/23-files.sh`) — `GET /v1/files[?path_prefix=]` — is defined but unwired. `bl setup --reset` and `--gc` currently treat `state.json` as authoritative source-of-truth for the workspace; any drift (interrupted reset, out-of-band API ops, lost/stale `state.json`, two operators sharing one workspace) leaks orphan Files indefinitely. The M13 spec (archived at `.rdf/archive/docs-specs/2026-04-25-skills-primitive-realignment.md:447,516,517`) called for three consumers — none landed. Pickup order:

1. `bl setup --reset` — highest value. After the state-driven delete pass, list the live workspace and delete file_ids not in `state.json`. Reset is the operator's "I've lost confidence in local state" verb; it's the case where ignoring the live workspace is most wrong.
2. `bl setup --check` — new diagnostic verb. Prints workspace-vs-`state.json` drift without mutating; closes the G5 verifier gap.
3. `bl setup --gc` — extend to enumerate workspace files not represented in `.files{}` and queue them into `files_pending_deletion`. Lowest priority — drift orphans here are storage cost, not correctness.

---

## 10. Role-swappable substrate and third-party skill extensibility

The routing Skills bundle ships routing Skills plus a corpus of doctrine markdown. Third-party extensibility is supported in principle: drop a `SKILL.md` plus `description.txt` into a new directory under `skills/`, run `make bl`, run `bl setup --sync`. Three gaps remain:

- **External skill directories.** `bl setup --sync` only reads from `BL_REPO_ROOT/skills/`. An operator with a proprietary WAF grammar or vendor-specific runbook has no `--skill-dir` flag for an external path.
- **Skill authorship validation.** `bl_setup_seed_skills` checks the 1024-char description.txt cap but does not validate `SKILL.md` structure or warn on bodies that exceed the effective context window share.
- **Substrate role config.** The `ride-the-substrate` skill family covers apache/nginx/litespeed log path discovery, but the curator cannot be configured to assume a substrate at case-open time (e.g. `bl consult --new --substrate nginx`). After this lands, the substrate flag lets the curator skip discovery and go directly to the relevant log paths.

---

## 11. bl case note — manual annotation surface

`bl case note "..."` is listed in `bl_help_case` but is not routed in the `bl_case` dispatcher (`src/bl.d/70-case.sh`). The operator currently has no first-class CLI surface for appending freeform annotations to the active case ledger without invoking `bl consult --attach`.

**Capabilities delivered:**
- `note` subcommand in the `bl_case` verb dispatch.
- `case_note` ledger event kind added to `schemas/ledger-event.json` (or reuse of `step_manual`).

---

## 12. False-positive corpus tooling

`_bl_defend_sig_fp_gate` (`src/bl.d/82-defend.sh`) checks `$BL_DEFEND_FP_CORPUS` (default `/var/lib/bl/fp-corpus`) and logs a warning then bypasses the gate when the directory is missing. The corpus is never populated by `bl setup`.

**Capabilities delivered:**
- `bl setup --sync` populates `/var/lib/bl/fp-corpus/` with a baseline set of clean-file samples (vendor PHP trees, common WordPress core files, cPanel-standard scripts) sourced from the `false-positives/` skill subdirectory.
- `bl setup --gc` prunes corpus entries older than 90 days.
- `false-positives/backup-artifact-patterns.md` and `false-positives/encoded-vendor-bundles.md` are the authoring surface for the seed list.

---

## 13. Per-source dedup window configuration

`bl trigger lmd` reads `BL_LMD_TRIGGER_DEDUP_WINDOW_HOURS` (default 24h) from `blacklight.conf`. When `bl trigger imunify` and `bl trigger modsec-audit` land (item 5), each needs its own dedup window config key. The `_bl_load_blacklight_conf` allowlist (`src/bl.d/30-preflight.sh`) extends to cover them.

---

## 14. Live API verification across the verb surface

`tests/live/setup-live.bats` runs `bl setup` against the real Anthropic API. Live tests do not yet exist for:
- `bl observe apache` → real log lines → real Sonnet 4.6 summary render
- `bl consult --new` → real session creation → real pending step poll
- `bl run` → real step execution → real result POST
- `bl case close` → real brief render (stage-2 HTML/PDF poll)
- `bl defend modsec` → real `apachectl -t` configtest (requires a host with Apache)

These are the only ground-truth proof that the API shapes documented during development are correct end-to-end.

---

## 15. Operator config tree expansion

`/etc/blacklight/blacklight.conf` currently allowlists: `unattended_mode`, `notify_channels_enabled`, `notify_severity_floor`, `lmd_trigger_dedup_window_hours`, `lmd_conf_path`, `cpanel_lockin`, `cpanel_lockin_timeout_seconds`.

**Pending keys:**
- `fp_corpus_dir` — override for `/var/lib/bl/fp-corpus`
- `defend_fw_allow_broad_ip` — site-level override for the CIDR /16 floor (currently env-var-only via `BL_DEFEND_FW_ALLOW_BROAD_IP`)
- `brief_mimes` — site-level override for `BL_BRIEF_MIMES`
- `skill_dir` — external skill directory path (item 10)
- `outbox_age_warn_secs` — preflight outbox drain threshold override

---

## 16. Portability and code quality hardening

**`mv -T` portability** (`src/bl.d/83-clean.sh`). `mv -T` is a GNU coreutils extension; BSD `mv` does not support it. On BSD-derived systems, the final rename in `bl_clean_unquarantine` falls back to a non-atomic `mv`. The TOCTOU window remains narrow (the staged inode is in the same parent) but is not closed on BSD. Mitigation: a small `rename(2)` C helper, or document the BSD caveat explicitly.

**`local var=$(...)` exit-code masking.** Several older functions predate the `local var; var=$(...)` split required by the coding convention. Shell exit-code capture is masked when `local` and assignment land on the same line. A `shellcheck SC2155` sweep surfaces remaining instances.

---

## 17. Source-side log compaction and normalization

`_bl_obs_emit_jsonl` (`src/bl.d/40-observe-helpers.sh`) writes every parsed record unconditionally. Attack patterns dominated by template-shaped repetition (brute-force, scanner sweeps, ModSec rule storms) produce evidence files 10–100× larger than their information content warrants. The curator reads those files mounted at `/case/<id>/raw/<source>.jsonl` directly — dense noise costs as much as dense signal.

Today's only volume guards are mechanical: journal head-truncated at `BL_OBS_JOURNAL_MAX=10000`, file triage 64 MB hard cap, bundle 100 MB warning / 500 MB hard fail (`41-observe-collectors.sh`, `42-observe-router.sh`). None operate on content semantics. A 10k-record Apache log with three template families ships all 10k records.

**Tiered rollout** (build order = dependency order):

**Tier 0 — File-level cross-run dedup.** In `bl_observe_evidence_rotate` (`40-observe-helpers.sh`), SHA-256 the new JSONL stream and skip upload+attach when it matches `prev_sha256` in `<source>.upload.json`. Trivial, zero false-positive risk, immediate win on repeat `bl observe` calls within the same case. Lands first — no schema change.

**Tier 1+2 — Exact dedup plus path normalization.** A new `_bl_obs_compact_stream` awk pass between the window-filter awk and `_bl_obs_emit_jsonl` in `bl_observe_log_apache` and `bl_observe_log_modsec` (`41-observe-collectors.sh`). Group key is the normalized template (`ip+method+path_norm+status+ua` for apache; `rule_id+normalized_uri+action` for modsec). Normalization rules in awk `gsub`: query-string values → `*`, numeric path segments → `<N>`, hex segments ≥8 chars → `<hash>`, UUIDs → `<uuid>`. Output schema is additive: existing fields plus `count`, `first_ts`, `last_ts`, `ip_set[]`, `sample_raw[0..2]`. Forensic anchor preserved via the three raw samples.

**Tier 3 — Burst compaction.** Within a template group, runs of records with `ts_delta < burst_gap` (default 5s) collapse to one burst record with `burst_count`, `burst_start`, `burst_end`. Streaming awk, O(1) memory per in-flight burst. Structurally symmetric to existing `bl_observe_fs_mtime_cluster` output — cross-source curator correlation gets simpler.

**Tier 4 — Cross-source IP correlation.** Case-scoped `$BL_VAR_DIR/cases/<id>/ip-seen.tsv` updated by all collectors under flock. `_bl_obs_emit_jsonl` enriches each record with `correlated_sources[]` listing other sources that observed the same IP. Defers to phase 3: requires a new case-scoped state file and cross-collector coordination — not blocking on tiers 0–3.

**Explicitly NOT taken:**
- Drain3-style tree-based template mining. The Python implementation produces a parse tree approximating a token-position lattice; porting to awk yields subtly wrong merge behavior on non-web log formats. Tier 2's normalization captures most of Drain's benefit on web/audit logs at zero correctness risk. Revisit only when an external `bl-helper` binary becomes acceptable scope.
- Bloom-filter cross-run dedup in pure bash. Tier 0's content-hash file comparison is the simpler exact equivalent at this scope.

**Compression expectations** (typical APSB25-94-class incident):

| Source | Raw records | After tiers 1+2+3 |
|---|---|---|
| Apache brute-force burst | 5,000 | 8–20 |
| ModSec rule storm | 800 | 5–12 |
| Journal | 10,000 (capped) | 50–200 |

**Why this is high-leverage.** Moves `bl` from "warns at 100 MB bundles" to viable on real hosting-provider log volumes. Denser evidence files yield cleaner case-brief narrative output. Reduces curator per-turn token cost and enables full-case reasoning that today exceeds practical context budget.

Couples with item 7 (delta envelopes): item 17 compacts what's in Files (the curator's read-side); item 7 compacts what's in per-turn user messages (the curator's wake-side). Different layers, same goal — both should land before fleet fan-out (item 3) since per-host evidence volume aggregates linearly with host count.

**Schema impact:** additive only. No break to `schemas/evidence-envelope.md`; new fields are optional.

**Insertion points:**
- Tier 0: `bl_observe_evidence_rotate` (`40-observe-helpers.sh`) — sha256 comparison vs `prev_sha256` in `<source>.upload.json` before upload.
- Tiers 1+2+3: new `_bl_obs_compact_stream` helper in `40-observe-helpers.sh`, called from `bl_observe_log_apache` and `bl_observe_log_modsec` (`41-observe-collectors.sh`) between the window-filter awk and per-record `_bl_obs_emit_jsonl`.
- Tier 4: new `_bl_obs_correlate_ips` post-processing pass in `_bl_obs_close_stream` (`40-observe-helpers.sh`); reads/updates `ip-seen.tsv` under flock.
