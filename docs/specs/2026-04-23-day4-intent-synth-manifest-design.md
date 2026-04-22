# Design: Day 4 — Intent Reconstructor + Synthesizer + Manifest + bl-agent Stack-Profile Apply

**Authors:** Ryan MacDonald (operator) · Claude (drafting, Opus 4.7)
**Date:** 2026-04-23
**Status:** Proposed
**Gate:** Friday 2026-04-24 22:00 CT — HANDOFF.md:385
**Anchor docs:** HANDOFF.md:373-385 (Day 4 schedule) · HANDOFF.md:77-82 (model choice) · HANDOFF.md:197-210 (capability_map schema, already locked in `curator/case_schema.py:65-68`) · work-output/DAY3-COMPLETE.md (carry-overs) · `.rdf/governance/{architecture,constraints,anti-patterns,verification}.md`

---

## 1. Problem Statement

Day 3 shipped the case-file engine (hypothesis revision via Opus 4.7 + adaptive thinking; 57 pytest green; live smoke PASS; no V4 degrade). The curator can revise its own hypothesis on multi-host evidence and produces structured `RevisionResult` with `capability_map_updates` today. The reasoning layer is complete.

**Missing: the investigation-to-defense bridge.** Four components must land together to satisfy the Day-4 gate and the demo payoff frame:

1. **Intent reconstruction.** The curator cannot yet deobfuscate a staged webshell artifact (`exhibits/fleet-01/host-2-polyshell/a.php`) into a `CapabilityMap` (observed RCE/C2, inferred credential-harvest, likely-next lateral movement). Today, `capability_map` is populated only as a side effect of `case_engine.revise` — which sees evidence summaries, never raw artifacts. The summary-vs-raw-artifact boundary (architecture.md:51, anti-patterns.md #1) requires a separate code path that reads raw content.

2. **Defense synthesis.** The curator cannot convert a `CapabilityMap` into ModSec rules + exceptions + validation. HANDOFF.md:378 specifies `apachectl configtest` gating and a high-confidence/low-confidence split (`rules[]` vs `suggested_rules[]`, no auto-apply for low-conf).

3. **Manifest publishing.** `curator/server.py:44` serves a hardcoded empty manifest today (`"version: 0\ndefenses: []\n"`). There is no writer, no versioning, no SHA-256, no hash sidecar. bl-pull at `bl-agent/bl-pull:38-39` carries a `TODO(day-4): verify SHA-256`. No integrity path exists.

4. **Stack-profile apply.** `bl-agent/bl-apply:46-50` has the `detect_stack()` function implemented already (returns `apache-modsec`/`apache`/`nginx`/`unknown`) but carries `TODO(day-4): parse manifest.yaml (yq), iterate defenses[], match .applies_to against $stack, write applicable rules`. No rule gets written. Host-3 (Nginx clean) exists in compose but has no way to demonstrate the skip beat.

Without this Day-4 pipeline, the demo at 0:35-1:15 (rule-promotion + "3 Magento hosts apply it; Nginx host skips") has no substrate. The demo has a reasoning spine but no deployable-defense payoff — which is the **primary** hackathon judging narrative.

**Additional carry-over:** Day-3 sentinel noted (work-output/DAY3-COMPLETE.md:116) that `proposed_actions.at` routinely receives non-ISO strings from Opus 4.7 (host names, `'estate-wide'`). `curator/case_engine.py:324-337` silently drops malformed entries. The prompt at `prompts/case-engine.md` does not constrain the `at` field — update it.

---

## 2. Goals

1. **G1 — Intent module.** `curator/intent.py` provides `reconstruct(artifact_path, case_context) -> CapabilityMap` using Opus 4.7 + adaptive thinking, flat JSON-schema (same `output_config.format` pattern as `case_engine._build_revision_schema`). BL_SKIP_LIVE=1 short-circuits to a deterministic stub. Returns `case_schema.CapabilityMap` exactly — no schema drift.
2. **G2 — Synthesizer module.** `curator/synthesizer.py` provides `synthesize(capability_map, case_context) -> SynthesisResult` using Opus 4.7, plus `validate_rule(rule_text) -> (bool, str)` that shells out to `apachectl -t`. High-confidence rules (conf ≥ 0.7) go to `manifest.rules[]`; lower to `manifest.suggested_rules[]`.
3. **G3 — Manifest module.** `curator/manifest.py` provides `publish(synth_result) -> int` (returns new version) that writes `curator/storage/manifest.yaml` + `curator/storage/manifest.yaml.sha256` (pinned `yaml.safe_dump` for determinism). Flask serves both at `/manifest.yaml` and `/manifest.yaml.sha256`.
4. **G4 — Synthesize CLI.** `python -m curator.synthesize <case_id>` loads a case, invokes intent (if not cached) + synthesizer + manifest publish in one shot. Demo-scriptable; operator-triggered.
5. **G5 — bl-pull SHA-256 verify.** `bl-agent/bl-pull` fetches `manifest.yaml` + `manifest.yaml.sha256`, runs `sha256sum -c`, stores on success, exits nonzero on mismatch.
6. **G6 — bl-apply stack-filter + install.** `bl-agent/bl-apply` reuses existing `detect_stack()`, parses manifest via `yq`, writes Apache-profile rules to `/etc/apache2/conf-available/bl-rules-{version}.conf`, symlinks `/etc/apache2/conf-enabled/bl-rules.conf → bl-rules-{version}.conf`, runs `apachectl -t`, logs PASS/FAIL. No reload. Nginx profile logs skip and exits 0.
7. **G7 — curator Dockerfile gains apache2 + mod_security.** `compose/curator.Dockerfile` installs `apache2 apache2-utils libapache2-mod-security2` so `apachectl -t` is available in-process.
8. **G8 — host-nginx Dockerfile.** `compose/host-nginx.Dockerfile` extends `nginx:1.27-alpine` with `apk add --no-cache curl bash`; `compose/docker-compose.yml` host-3 references it. Replaces the raw `image: nginx:1.27-alpine` line.
9. **G9 — Orchestrator intent wiring.** `process_report` calls `intent.reconstruct()` on extracted `.php` artifacts when fs-hunter returns `category="webshell_candidate"` rows. Result merged via new `case_engine.merge_capability_map(case, cap_map)` helper. Existing revise path untouched.
10. **G10 — prompts/case-engine.md at-field fix.** Prompt guidance: `proposed_actions[].at` must be ISO-8601 UTC (`YYYY-MM-DDTHH:MM:SSZ`) and reference the *evidence report timestamp being acted on*, not a host name or scope string.
11. **G11 — pytest green.** Full suite (existing 57 + new): `tests/test_intent.py`, `tests/test_synthesizer.py`, `tests/test_manifest.py`, `tests/test_orchestrator_smoke.py` (expanded), `tests/test_bl_apply.bats`-equivalent-via-subprocess. BL_SKIP_LIVE=1 green. 0 skipped.
12. **G12 — Day-1 schema lock intact.** `git diff 9edbced -- curator/case_schema.py` returns empty on the final Day-4 commit.

---

## 3. Non-Goals

- **Manifest rotation / retirement** — roadmap only (constraints.md:52). Manifest version is monotonic; no entries are ever removed.
- **Role-swappable substrate** — roadmap only.
- **GPG signing** — SHA-256 sidecar is sufficient per HANDOFF.md:88, constraints.md:54.
- **Web frontend** — terminal + manifest HTTP only.
- **Net-hunter (4th hunter)** — pre-cut (constraints.md:56).
- **A/B harness vs Sonnet** — cut (constraints.md:57).
- **Full `bl-ctl` CLI** — stays at `cat` + grep wrappers (constraints.md:58).
- **Mind-change moment / host-5 split-campaign** — Day 5 scope.
- **Host-1 anticipatory block staging** — Day 5 scope. Day 4 makes the rule available; Day 5 simulator stages the block.
- **Operator-content skill authorship** — `polyshell.md`, `modsec-patterns.md`, `false-positives/*`, `hosting-stack/*`, `ic-brief-format/*` stay as stubs until operator authorship (constraints.md:95-100). `case-lifecycle.md` already has mature content as of d00ddd1 and is not re-touched by this spec.
- **`curator/case_schema.py` edits** — Day-1 lock (constraints.md:85, anti-patterns.md #5).
- **Apache graceful reload in bl-apply** — Day-5 simulator handles one-time reload for the enforcement beat (Q5 design decision). bl-apply installs the rule; it does not restart Apache.
- **Magento on host-3** — Apache-vs-Nginx is the entire Day-4 stack-profile beat. No Magento on host-3 (Q6 revised).
- **Intent reconstruction on every report** — only fires when fs-hunter emits `category="webshell_candidate"` AND the report tar contains ≥1 `.php` artifact (Q1 gate).
- **Automatic synthesizer trigger on every revision** — synthesizer is operator-CLI-triggered (Q2 decision). Time-compression simulator (Day 5) scripts the trigger for autonomous demo playback.

---

## 4. Architecture

### 4.1 Codebase Inventory (files read during design)

| File | Lines | Key Functions | Dependencies | Test File |
|---|---|---|---|---|
| `curator/case_schema.py` | 137 | `CapabilityMap`, `CaseFile`, `RevisionResult`, `load_case`, `dump_case` | pydantic v2, yaml | `tests/test_revision.py` |
| `curator/case_engine.py` | 450 | `revise`, `apply_revision`, `_build_revision_schema`, `_merge_capability_maps`, `_render_evidence_summaries`, `_clamp_confidences` | anthropic, case_schema, evidence | `tests/test_revision.py` |
| `curator/orchestrator.py` | 288 | `process_report`, `_run_hunters`, `_extract_tar`, `_build_initial_hypothesis`, `_existing_case_path` | case_engine, hunters, evidence, report_envelope | `tests/test_orchestrator_smoke.py` |
| `curator/server.py` | 64 | Flask routes `/health`, `/manifest.yaml`, `/reports` | flask | (none direct) |
| `curator/evidence.py` | 111 | `EvidenceRow`, `init_db`, `insert_evidence`, `fetch_by_case`, `fetch_by_report` | sqlite3, pydantic | `tests/test_evidence.py` |
| `curator/hunters/base.py` | 168 | `run_sonnet_hunter`, `load_prompt`, `build_tool_schema`, `HunterInput`, `HunterOutput`, `Finding` | anthropic | `tests/test_hunters_base.py` |
| `curator/report_envelope.py` | 64 | `ReportEnvelope`, `parse_envelope`, `validate_tar_safety` | tarfile, pydantic | `tests/test_report_envelope.py` |
| `curator/managed_agents.py` | 199 | `create_curator_agent`, `MODEL_CURATOR`, `MODEL_HUNTER` | anthropic | n/a |
| `bl-agent/bl-pull` | 46 | `main`, `require` | curl, sha256sum | none (shell) |
| `bl-agent/bl-apply` | 53 | `main`, `detect_stack` (✅ already complete) | — | none (shell) |
| `bl-agent/bl-report` | 115 | `main`, `require` | curl, tar, du | none (shell) |
| `compose/curator.Dockerfile` | 23 | FROM python:3.12-slim + curl | — | — |
| `compose/host-apache.Dockerfile` | 17 | FROM php:8.3-apache (no Magento today) | — | — |
| `compose/docker-compose.yml` | 103 | curator + host-2 + host-3 (nginx:1.27-alpine image) | — | — |
| `prompts/case-engine.md` | 49 | Opus 4.7 case-engine system prompt | — | — |

**Key finding from inventory (Q6 correction):** Neither `compose/host-apache.Dockerfile` nor the existing `nginx:1.27-alpine` host-3 has Magento. The "Magento on all 6 hosts" framing in the demo script refers to the *realistic hosting stack* narrative, not the image composition today. Magento layering is scoped outside Day 4 — the Apache-vs-Nginx distinction is what drives the Day-4 gate.

**Key finding from inventory (bl-apply):** `detect_stack()` in `bl-agent/bl-apply:18-34` is already implemented and correct. Day 4 only needs the manifest-parse + write-rule + configtest path. No re-implementation of stack detection.

### 4.2 New Files

| File | Est. Lines | Purpose | Test File |
|---|---|---|---|
| `curator/intent.py` | ~220 | Opus 4.7 + adaptive thinking call; reconstruct artifact → CapabilityMap | `tests/test_intent.py` |
| `curator/synthesizer.py` | ~280 | Opus 4.7 call; synthesize rules + apachectl validate; split high/low conf | `tests/test_synthesizer.py` |
| `curator/manifest.py` | ~120 | Versioned YAML + SHA-256 sidecar; publish(SynthesisResult) | `tests/test_manifest.py` |
| `curator/synthesize.py` | ~70 | CLI entry: `python -m curator.synthesize <case_id>` | `tests/test_synthesize_cli.py` |
| `prompts/intent.md` | ~60 | Opus 4.7 intent-reconstruction system prompt | N/A (docs) |
| `prompts/synthesizer.md` | ~70 | Opus 4.7 synthesizer system prompt | N/A (docs) |
| `compose/host-nginx.Dockerfile` | ~12 | Extends nginx:1.27-alpine + bash + curl | N/A (infra) |
| `tests/test_intent.py` | ~80 | Schema-valid stub + mocked-Opus cases | self |
| `tests/test_synthesizer.py` | ~100 | Stub + mock + validate_rule real-apache-call | self |
| `tests/test_manifest.py` | ~60 | Canonical bytes deterministic; sha256 matches; load/publish round-trip | self |
| `tests/test_synthesize_cli.py` | ~70 | CLI happy path with BL_SKIP_LIVE=1 | self |
| `tests/test_merge_capability_map.py` | ~40 | merge_capability_map unit tests (hypothesis untouched, last_updated_at bump, dedupe delegation) | self |
| `tests/fixtures/capability_maps/observed_rce_c2.yaml` | ~25 | Fixture: fleshed CapabilityMap for synth tests | consumed |
| `tests/fixtures/manifest/v1_pinned.yaml` | ~35 | Expected canonical-form manifest bytes | consumed |
| `tests/fixtures/apachectl_pass.conf` | ~5 | ModSec rule known to pass configtest | consumed |
| `tests/fixtures/apachectl_fail.conf` | ~3 | ModSec rule known to fail configtest | consumed |

### 4.3 Modified Files

| File | Changes | Test File |
|---|---|---|
| `curator/orchestrator.py` | +45 LOC: `_maybe_reconstruct_intent(rows, work_root, envelope)` helper; wire call after hunters; merge result via `case_engine.merge_capability_map` | `tests/test_orchestrator_smoke.py` (new scenario) |
| `curator/case_engine.py` | +22 LOC: expose `merge_capability_map(case, cap_map) -> CaseFile` wrapping the existing `_merge_capability_maps` (case-update returning new CaseFile with bumped `last_updated_at` / `updated_by`); no changes to revise() / apply_revision() | `tests/test_merge_capability_map.py` (new, ~40 LOC) |
| `curator/server.py` | +20 LOC: new route `GET /manifest.yaml.sha256` (serves sidecar, 404 if absent); existing `/manifest.yaml` route reads `manifest.yaml` bytes unchanged | covered by `tests/test_manifest.py` + live smoke |
| `compose/curator.Dockerfile` | +2 LOC: add `apache2 apache2-utils libapache2-mod-security2` to apt-get install | n/a (image rebuild verifies) |
| `compose/docker-compose.yml` | host-3 now `build: ../ dockerfile: compose/host-nginx.Dockerfile`, replacing `image: nginx:1.27-alpine`; no other service changes | n/a (compose up verifies) |
| `bl-agent/bl-pull` | +25 LOC: fetch `manifest.yaml.sha256`, run `sha256sum -c manifest.yaml.sha256`, atomically replace local manifest on PASS | shell smoke script `tests/fixtures/smoke/test-bl-pull.sh` |
| `bl-agent/bl-apply` | +50 LOC: parse manifest via `yq`, iterate `rules[]`, match `applies_to` against `detect_stack()` output, write Apache rules to `/etc/apache2/conf-available/bl-rules-{version}.conf`, symlink enabled, `apachectl -t`, log result | shell smoke script `tests/fixtures/smoke/test-bl-apply.sh` |
| `prompts/case-engine.md` | +8 LOC: new bullet under "Reasoning rules" specifying `proposed_actions[].at` must be ISO-8601 UTC referencing report timestamp | n/a (prompt change) |
| `requirements.txt` | No changes — all Day-4 code uses existing stdlib + `anthropic` + `pydantic` + `yaml` + `flask` | — |
| `tests/test_orchestrator_smoke.py` | +60 LOC: new `test_intent_merge_via_orchestrator` scenario (BL_SKIP_LIVE=1, fs-hunter returns `webshell_candidate`, asserts capability_map.observed populated) | self |

### 4.4 Deleted Files

None.

### 4.5 Files that MUST NOT be touched

- `curator/case_schema.py` — Day-1 lock (constraints.md:85). Merge-helper work reuses existing models.
- `curator/hunters/**` — Day-2 stable. Intent is a curator-level concern, not a hunter.
- `curator/evidence.py` — Day-2 stable; synthesizer + intent call `fetch_by_case` as read-only consumers.
- `curator/report_envelope.py` — Day-2 stable.
- `skills/**` — all operator-content (stubs stay stubs).
- `exhibits/fleet-01/host-2-polyshell/a.php` — Day-2 exhibit stable; intent reads it as-is.
- `bl-agent/bl-report` — Day-2 stable.

### 4.6 Dependency Tree

```
compose/docker-compose.yml
 ├─ curator (build: compose/curator.Dockerfile [MODIFIED: +apache2])
 │    ├─ curator.server (MODIFIED: +/manifest.yaml.sha256 route)
 │    ├─ curator.synthesize (NEW CLI)
 │    │    ├─ curator.case_engine.load_case
 │    │    ├─ curator.intent.reconstruct (NEW)
 │    │    │    └─ curator.hunters.base.load_prompt (reused)
 │    │    │    └─ prompts/intent.md (NEW)
 │    │    ├─ curator.synthesizer.synthesize (NEW)
 │    │    │    └─ curator.synthesizer.validate_rule (NEW, shells to apachectl)
 │    │    │    └─ prompts/synthesizer.md (NEW)
 │    │    ├─ curator.case_engine.merge_capability_map (NEW wrapper)
 │    │    │    └─ curator.case_engine._merge_capability_maps (reused)
 │    │    └─ curator.manifest.publish (NEW)
 │    └─ curator.orchestrator.process_report (MODIFIED: +_maybe_reconstruct_intent)
 │         └─ curator.intent.reconstruct (NEW)
 │         └─ curator.case_engine.merge_capability_map (NEW)
 ├─ host-2 (Apache) — build: compose/host-apache.Dockerfile (UNCHANGED)
 │    └─ /opt/bl-agent/{bl-pull, bl-apply} [MODIFIED]
 └─ host-3 (Nginx) — build: compose/host-nginx.Dockerfile (NEW)
      └─ /opt/bl-agent/{bl-pull, bl-apply} [MODIFIED]
           └─ bl-pull: curl + sha256sum -c manifest.yaml.sha256 [G5]
           └─ bl-apply: detect_stack() + yq parse + apachectl -t [G6]
```

### 4.7 Key Changes

1. **Intent as separate orchestrator step, not a hunter.** Preserves the summary-vs-raw-artifact boundary.
2. **Synthesizer operator-CLI-triggered, not automatic.** Demo-visible rule-promotion beat; cost-controlled.
3. **apachectl gate local to curator.** No Docker socket, no sidecar. apache2 + libapache2-mod-security2 installed in curator image.
4. **Manifest is YAML + SHA-256 sidecar, not embedded hash.** `sha256sum -c` verifiable in pure Bash.
5. **bl-apply writes + symlinks + configtest; no reload.** Day-5 simulator handles reload for enforcement beat.
6. **host-3 is minimal Nginx (no Magento).** Aligns with existing compose state; Apache-vs-Nginx is the gate.

### 4.8 Dependency Rules

- Intent never calls the case engine; case engine never calls intent. Merge-helper is the one-way junction.
- Synthesizer never reads `curator/storage/manifest.yaml` — only writes via `manifest.publish()`. Reads are server-side only.
- Manifest publish is idempotent at a given version number; re-publish at v=N overwrites content but rejects rollback to v<N (monotonic).
- apachectl validation is synchronous per rule. Failures are captured, not raised — the rule routes to `suggested_rules[]` with `validation_error` field.
- bl-pull never mutates `$MANIFEST_LOCAL` on hash mismatch; stage-and-rename pattern already established at `bl-agent/bl-pull:41-42`.

---

## 5. File Contents

### 5.1 `curator/intent.py` (~220 LOC)

| Function | Signature | Purpose | Dependencies |
|---|---|---|---|
| `InterpreterParseError` | class(RuntimeError) | Raised on unparseable Opus 4.7 response | — |
| `_build_intent_schema` | `() -> dict` | Flat JSON-schema for CapabilityMap output; reuses shape from `case_engine._build_revision_schema:117-126` | — |
| `_read_artifact` | `(path: Path, max_bytes: int = 64000) -> str` | Read raw webshell bytes, decode utf-8 with `errors='replace'`, truncate | — |
| `_load_prompt` | `() -> str` | Load `prompts/intent.md` via `hunters.base.load_prompt` | `hunters.base` |
| `_render_case_context` | `(case: CaseFile) -> dict` | Project case file to `{summary, confidence, hosts_seen, observed_caps}` dict — hypothesis-only projection (no raw evidence) | `case_schema` |
| `_stub_result` | `() -> CapabilityMap` | BL_SKIP_LIVE stub: observed=[{cap: "rce_via_webshell", evidence: [], confidence: 1.0}], inferred=[], likely_next=[] | `case_schema` |
| `_extract_json_text` | `(response) -> str` | Same pattern as `case_engine._extract_json_text:242-257` | — |
| `reconstruct` | `(artifact_path: Path, case_context: CaseFile, *, client=None) -> CapabilityMap` | Opus 4.7 + adaptive thinking call; returns a CapabilityMap. BL_SKIP_LIVE short-circuits | `anthropic`, `case_schema`, `managed_agents.MODEL_CURATOR` |

**Call shape (verbatim Day-3-proven):**
```python
response = client.messages.create(
    model=MODEL_CURATOR,                                          # claude-opus-4-7
    max_tokens=16000,
    thinking={"type": "adaptive", "display": "summarized"},
    output_config={
        "effort": "high",
        "format": {"type": "json_schema", "schema": _build_intent_schema()},
    },
    system=_load_prompt(),
    messages=[{"role": "user", "content": user_content}],
)
```

**User content shape:**
```
CASE CONTEXT (hypothesis-only projection):
{current_summary, current_confidence, hosts_seen, observed_caps_so_far}

RAW ARTIFACT ({path}, {n_bytes} bytes):
{artifact_bytes_utf8_replace}
```

**Post-parse normalization (same constraints as Day-3):**
- No `oneOf`/`anyOf`/`allOf` — schema is flat.
- No number `minimum`/`maximum` on `confidence` fields; clamp via `_clamp_confidences` (import from `case_engine`).
- `capability_map` schema reuses the exact dict literal from `case_engine._build_revision_schema:117-126` — helper-extract to `case_schema.build_capability_map_schema() -> dict` if reviewer flags duplication; otherwise inline.

### 5.2 `curator/synthesizer.py` (~280 LOC)

| Function | Signature | Purpose | Dependencies |
|---|---|---|---|
| `SynthesisResult` | Pydantic v2 model | `rules: list[Rule]`, `suggested_rules: list[Rule]`, `exceptions: list[Exception]`, `validation_test: str` | pydantic |
| `Rule` | Pydantic v2 model | `rule_id: str`, `body: str`, `applies_to: list[str]` (stack profiles), `capability_ref: str`, `confidence: float`, `validation_error: Optional[str]` | pydantic |
| `ExceptionEntry` | Pydantic v2 model | `rule_id_ref: str`, `path_glob: str`, `reason: str` | pydantic |
| `SynthesisParseError` | class(RuntimeError) | Unparseable response | — |
| `_build_synthesis_schema` | `() -> dict` | Flat JSON-schema; Rule body is string (ModSec directive text) | — |
| `_load_prompt` | `() -> str` | Load `prompts/synthesizer.md` | `hunters.base` |
| `synthesize` | `(capability_map: CapabilityMap, case_context: CaseFile, *, client=None) -> SynthesisResult` | Opus 4.7 call returning pre-validated SynthesisResult | `anthropic`, `case_schema` |
| `validate_rule` | `(rule_text: str) -> tuple[bool, str]` | Write rule to temp file, wrap in minimal apache2 + mod_security2 conf, invoke `subprocess.run(["apachectl", "-t", "-f", wrapper_conf], capture_output=True, timeout=10)`, return (exit==0, stderr) | subprocess, tempfile |
| `_split_by_confidence` | `(result: SynthesisResult, threshold: float = 0.7) -> SynthesisResult` | Move rules below threshold to suggested_rules | — |
| `_validate_and_partition` | `(result: SynthesisResult) -> SynthesisResult` | Validate every rule via `validate_rule`; failures → suggested_rules with `validation_error` | — |
| `_stub_result` | `(cap_map: CapabilityMap) -> SynthesisResult` | BL_SKIP_LIVE deterministic stub; contains 1 dummy suggested_rule | — |

**Rule shape (as ModSec directive string):**
```
SecRule REQUEST_URI "@rx \\.php$" \\
    "id:900001,\\
     phase:2,\\
     deny,\\
     status:403,\\
     msg:'blacklight: PolyShell suspect path',\\
     logdata:'%{MATCHED_VAR}',\\
     tag:'blacklight/rce',\\
     tag:'blacklight/v${manifest_version}'"
```

**validate_rule wrapper conf template:**
```apache
# /tmp/bl-validate-{uuid}.conf
ServerRoot /etc/apache2
Mutex file:/tmp
PidFile /tmp/validate.pid
ErrorLog /dev/null
Listen 127.0.0.1:65535
LoadModule security2_module /usr/lib/apache2/modules/mod_security2.so
LoadModule unique_id_module /usr/lib/apache2/modules/mod_unique_id.so
<IfModule security2_module>
    SecRuleEngine DetectionOnly
    Include {rule_file}
</IfModule>
```

Running `apachectl -t -f /tmp/bl-validate-{uuid}.conf` exercises syntax + ModSec parsing. Timeout 10s.

### 5.3 `curator/manifest.py` (~120 LOC)

| Function | Signature | Purpose | Dependencies |
|---|---|---|---|
| `Manifest` | Pydantic v2 model | `version: int`, `generated_at: str`, `rules: list[dict]`, `suggested_rules: list[dict]`, `exceptions: list[dict]` | pydantic |
| `_canonical_bytes` | `(manifest: Manifest) -> bytes` | `yaml.safe_dump(manifest.model_dump(mode="json"), sort_keys=True, default_flow_style=False, allow_unicode=False, width=120).encode("utf-8")` | yaml |
| `_load_current_version` | `(storage_dir: Path) -> int` | Read `manifest.yaml`, extract `version`, return int; 0 if absent | yaml |
| `publish` | `(synth_result: SynthesisResult, *, storage_dir: Path = None) -> int` | Bump version, compose Manifest, write `manifest.yaml` + `manifest.yaml.sha256` atomically (stage + rename), return new version. Refuses rollback. | hashlib, yaml |
| `load` | `(storage_dir: Path = None) -> Manifest` | Parse manifest.yaml → Manifest (for tests + demo inspection) | yaml |

**Sidecar format** (sha256sum compatible):
```
{hex_64}  manifest.yaml
```
(Exactly two spaces between hash and filename — `sha256sum -c` grammar.)

**Atomic write pattern:**
```python
stage = storage_dir / "manifest.yaml.stage"
sha_stage = storage_dir / "manifest.yaml.sha256.stage"
stage.write_bytes(canonical)
sha_stage.write_text(f"{sha256}  manifest.yaml\n")
stage.rename(storage_dir / "manifest.yaml")           # atomic on POSIX
sha_stage.rename(storage_dir / "manifest.yaml.sha256")
```

### 5.4 `curator/synthesize.py` (~70 LOC)

CLI entrypoint. Mirrors `curator/orchestrator.py:257-284` (main + precondition + error handling).

| Function | Signature | Purpose |
|---|---|---|
| `_check_preconditions` | `() -> None` | Same pattern as `orchestrator._check_preconditions`: require `ANTHROPIC_API_KEY` unless `BL_SKIP_LIVE=1` |
| `_load_case_or_exit` | `(case_id: str, cases_dir: Path) -> CaseFile` | Load by path or sys.exit(2) with message |
| `main` | `() -> None` | argparse: `case_id` positional; default `BL_STORAGE=curator/storage`; invoke intent (optional — if case has webshell artifact path hinted) + synthesizer + publish; print new manifest version |

CLI contract:
```
python -m curator.synthesize CASE-2026-0007
# exit 0 + prints "manifest v{N}" on success
# exit 1 on network/API error
# exit 2 on case-not-found or malformed case
```

### 5.5 `curator/orchestrator.py` Modifications

| Function | Current | New | Lines |
|---|---|---|---|
| `process_report` | Runs hunters → revise (if existing case) | After `insert_evidence` and before the `_existing_case_path` branch, call `_maybe_reconstruct_intent(rows, work_root, envelope, case_path)` which returns a CapabilityMap or None; if non-None, merge via `case_engine.merge_capability_map(case, cap_map)` after the initial-open or post-revise path | existing 180-254 + new helper |
| `_maybe_reconstruct_intent` | *new* | `(rows, work_root, envelope, case) -> CaseFile` — gate: any row with `category == "webshell_candidate"`; find largest `.php` file under `work_root/fs`; call `intent.reconstruct(path, case)`; merge result; return updated case | ~40 LOC |

**Webshell-candidate gate logic:**
```python
webshell_rows = [r for r in rows if r.category == "webshell_candidate"]
if not webshell_rows:
    return case  # no-op, return unchanged
php_files = sorted(
    (p for p in (work_root / "fs").rglob("*.php") if p.is_file()),
    key=lambda p: p.stat().st_size, reverse=True,
)
if not php_files:
    log.warning("webshell_candidate hit but no .php in tar — skipping intent")
    return case
artifact = php_files[0]
cap_map = await asyncio.to_thread(intent.reconstruct, artifact, case)
return case_engine.merge_capability_map(case, cap_map)
```

### 5.6 `curator/case_engine.py` Modifications

| Function | Current | New | Lines |
|---|---|---|---|
| `_merge_capability_maps` | existing private, line 416-450 | unchanged | — |
| `merge_capability_map` | *new* | `(case: CaseFile, cap_map: CapabilityMap, *, updated_by: str = "intent_reconstructor", clock: Optional[Callable] = None) -> CaseFile` — wraps `_merge_capability_maps`, bumps `last_updated_at` + `updated_by`, does NOT touch hypothesis (that's revise's domain) | ~18 LOC |

Signature:
```python
def merge_capability_map(
    case: CaseFile,
    cap_map: CapabilityMap,
    *,
    updated_by: str = "intent_reconstructor",
    clock: Optional[Callable[[], datetime]] = None,
) -> CaseFile:
    now = (clock or (lambda: datetime.now(timezone.utc)))()
    updated = case.model_copy(deep=True)
    updated.last_updated_at = now
    updated.updated_by = updated_by
    updated.capability_map = _merge_capability_maps(updated.capability_map, cap_map)
    return updated
```

### 5.7 `curator/server.py` Modifications

| Route | Current | New |
|---|---|---|
| `GET /manifest.yaml` | serves file or empty fallback | unchanged |
| `GET /manifest.yaml.sha256` | *new* | `send_file(storage_dir / "manifest.yaml.sha256", mimetype="text/plain")`; 404 if file absent |

### 5.8 `bl-agent/bl-pull` Modifications

Replace the existing manifest-fetch block (current lines 32-39) with a **sidecar-first** fetch order — sidecar hash is fetched before the manifest body, so a mid-publish race cannot cause the sidecar to describe a stale body (the sidecar is written second in `manifest.publish`'s stage-then-rename pattern; fetching it first means any manifest we subsequently fetch is at least as new as the sidecar describes). Re-fetch manifest on hash mismatch is handled by the systemd timer retry loop, not inline.

```bash
log "fetching sidecar hash from $CURATOR_URL"
if ! curl -fsS -o "$tmpdir/manifest.yaml.sha256" "$CURATOR_URL/manifest.yaml.sha256"; then
    log "manifest.yaml.sha256 fetch failed (curator may not have published yet)"
    exit 1
fi

log "fetching manifest body"
if ! curl -fsS -o "$tmpdir/manifest.yaml" "$CURATOR_URL/manifest.yaml"; then
    log "manifest fetch failed"
    exit 1
fi

# Verify hash. sha256sum -c expects the filename referenced in the sidecar
# to exist in CWD — cd into tmpdir for the verification.
( cd "$tmpdir" && sha256sum -c manifest.yaml.sha256 >/dev/null ) || {  # sha256sum emits FAILED on mismatch
    log "SHA-256 mismatch — refusing to install (transient: race with in-flight publish; systemd timer will retry)"
    exit 1
}
log "hash verified"
```

Then the existing atomic-install block (current lines 41-43) runs unchanged:

```bash
command install -D -m 0644 "$tmpdir/manifest.yaml" "$MANIFEST_STAGE"
command mv "$MANIFEST_STAGE" "$MANIFEST_LOCAL"
```

Also stage the sidecar alongside the manifest so consumers can re-verify locally:

```bash
command install -D -m 0644 "$tmpdir/manifest.yaml.sha256" "${MANIFEST_LOCAL}.sha256.stage"
command mv "${MANIFEST_LOCAL}.sha256.stage" "${MANIFEST_LOCAL}.sha256"
```

All additions use `command` prefix on coreutils (`command install`, `command mv`, `command rm`) where shell operators are not used; `sha256sum -c` runs in a subshell via `( cd ... && ... )`. `cd` guard via `||` on the subshell exit code. `curl`, `sha256sum` are not coreutils; invoked bare.

### 5.9 `bl-agent/bl-apply` Modifications

Current lines 46-50 carry `TODO(day-4)`. Replace with a new `apply_rules` function:

```bash
apply_rules() {
    local stack="$1"
    local manifest="$MANIFEST_LOCAL"
    local version
    version=$(yq '.version' "$manifest")

    if [[ "$stack" == "nginx" ]]; then
        log "stack profile 'nginx' — skipping Apache ruleset (manifest v${version})"
        return 0
    fi
    if [[ "$stack" != "apache" && "$stack" != "apache-modsec" ]]; then
        log "stack profile '$stack' unknown — skipping"
        return 0
    fi

    require yq apachectl

    local rule_count
    rule_count=$(yq '.rules | length' "$manifest")
    log "manifest v${version} carries ${rule_count} rule(s) for Apache profile"

    local rules_conf="/etc/apache2/conf-available/bl-rules-${version}.conf"
    local rules_enabled="/etc/apache2/conf-enabled/bl-rules.conf"
    local tmpdir
    tmpdir=$(command mktemp -d -t bl-apply.XXXXXX)
    # shellcheck disable=SC2064  # expand $tmpdir at trap-set time
    trap "command rm -rf '$tmpdir'" RETURN

    local idx
    : > "$tmpdir/rules.conf"
    for (( idx=0; idx < rule_count; idx++ )); do
        local applies
        applies=$(yq ".rules[$idx].applies_to[]" "$manifest" | command tr -d '"' | command paste -sd, -)
        case ",$applies," in
            *,apache,*|*,apache-modsec,*) ;;
            *) continue ;;
        esac
        yq ".rules[$idx].body" "$manifest" >> "$tmpdir/rules.conf"
        command printf '\n' >> "$tmpdir/rules.conf"
    done

    command install -D -m 0644 "$tmpdir/rules.conf" "$rules_conf"
    command ln -sf "$rules_conf" "$rules_enabled"

    if apachectl -t 2>"$tmpdir/configtest.err"; then
        log "apachectl -t PASS for manifest v${version}"
    else
        log "apachectl -t FAIL for manifest v${version}: $(command cat "$tmpdir/configtest.err")"
        return 3
    fi
}

main() {
    if [[ ! -r "$MANIFEST_LOCAL" ]]; then
        log "manifest not found at $MANIFEST_LOCAL — run bl-pull first"
        exit 1
    fi
    local stack
    stack=$(detect_stack)
    log "detected stack profile: $stack"
    apply_rules "$stack"
}
```

Every coreutil uses `command` prefix. `apachectl` is NOT coreutils — invoked bare (not shipped with base system; provided by apache2 package on Apache hosts). `yq` likewise (third-party binary from `install.sh`).

### 5.10 `compose/host-nginx.Dockerfile` (~12 LOC)

```dockerfile
# blacklight fleet host — Nginx minimal (stack-profile-skip demo target).
# Day 4 scope: add bash + curl + sha256sum so bl-pull/bl-apply run via docker exec.
# No Magento, no PHP — host-3's role is strictly the bl-apply skip beat.
FROM nginx:1.27-alpine

RUN apk add --no-cache bash curl

# bl-agent scripts mount in via compose volume (/opt/bl-agent).
RUN command mkdir -p /opt/bl-agent /var/bl-agent/reports

EXPOSE 80
```

Note: `command` prefix would be bash-only; the RUN directive runs in `/bin/sh` (BusyBox ash) by default on alpine. Remove `command` prefix for the RUN line — Alpine RUN is not bash-context. Documentation per conventions.md:14 applies to bl-agent scripts, not Dockerfile RUN directives which are ash.

Correction — remove `command` on the `mkdir` in the RUN line since the shell is ash, not bash:
```dockerfile
RUN mkdir -p /opt/bl-agent /var/bl-agent/reports
```

### 5.11 `compose/curator.Dockerfile` Modifications

Append to existing `apt-get install` line (line 10):

```dockerfile
RUN pip install --no-cache-dir -r /app/requirements.txt \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      curl \
      apache2 apache2-utils libapache2-mod-security2 \
 && rm -rf /var/lib/apt/lists/*
```

No `a2enmod security2` — we don't need Apache running; we only need `apachectl -t -f` to parse a config file. ~80MB image addition.

### 5.12 `compose/docker-compose.yml` Modifications

Replace host-3 service block (current lines 84-94):

```yaml
  host-3:
    build:
      context: ..
      dockerfile: compose/host-nginx.Dockerfile
    image: blacklight/host-nginx:dev
    container_name: bl-host-3
    hostname: host-3
    volumes:
      - ../exhibits/fleet-01/host-3-nginx-clean:/usr/share/nginx/html/exhibits:ro
      - ../bl-agent:/opt/bl-agent:ro
    networks:
      - fleet
    depends_on:
      - curator
```

### 5.13 `prompts/case-engine.md` Modifications

Append to "Reasoning rules" list (new rule 8, between current rules 7 and 8):

```markdown
8. **`proposed_actions[].at` format.** The `at` field MUST be a ISO-8601 UTC timestamp (`YYYY-MM-DDTHH:MM:SSZ`), and MUST reference the evidence report timestamp being acted on — NOT a host name, NOT a scope descriptor (`'estate-wide'`, `'host-4'`). If no specific evidence timestamp applies, use the current revision time. Non-ISO strings will be silently dropped by the curator.
```

Carry-over fix from Day-3 sentinel (DAY3-COMPLETE.md:113-116). Zero behavioral change in `case_engine.py` — the defensive parse at `case_engine.py:324-337` already handles drops; this just lowers the drop rate by better prompting.

### 5.14 `prompts/intent.md` (~60 LOC, NEW)

Opus 4.7 system prompt. Structure mirrors `prompts/case-engine.md`:

```markdown
# intent-reconstruction system prompt — blacklight curator, Opus 4.7

You are blacklight's intent reconstructor. You receive a raw webshell or suspected-compromise artifact (PHP, shell script, or executable payload) and reconstruct the capabilities it enables: what the defender should expect this artifact to do, what family-pattern it belongs to, and what the next logical action is if the actor is unblocked.

You output a `CapabilityMap` as structured JSON matching the schema the caller passed in `output_config.format`. Do not narrate outside the JSON.

## Fields in the JSON schema

- `observed`: list of `{cap, evidence, confidence=1.0}` — capabilities grounded in literal artifact content. `evidence` is a list of short excerpts (≤200 chars each) from the artifact text that warrant this capability. Confidence is always 1.0 for observed (the artifact literally does the thing).
- `inferred`: list of `{cap, basis, confidence}` — capabilities that the family-pattern implies but this artifact does not literally contain. `basis` cites the family pattern (e.g. "PolyShell APSB25-94 variants commonly include credential harvest"). Confidence: 0.3-0.8 based on family-pattern strength.
- `likely_next`: list of `{action, basis, confidence, ranked}` — what the actor's next step is likely to be if unblocked. `ranked` is 1..N. Keep ≤5 entries. Confidence: 0.2-0.7 (these are predictions, not observations).

## Reasoning rules (ALL mandatory)

1. **Decode before claiming.** If the artifact is obfuscated (base64, gzinflate, str_rot13, etc.), mentally decode through every layer before asserting capabilities.
2. **Evidence for observed.** Every `observed` entry MUST cite a specific artifact excerpt in its `evidence` field.
3. **Basis for inferred.** Every `inferred` entry MUST have a non-empty `basis` — what family pattern / CVE / industry reference warrants the inference.
4. **Bounded speculation.** `likely_next` entries must be plausible, not exhaustive. 3-5 well-calibrated predictions beat 20 low-confidence ones.
5. **Defensive framing.** Never "attacker would next...". Use "if consistent with family, deployment pattern suggests...". Never second person.
6. **No capability invention.** If the artifact shows only RCE, you do not list "credential harvest" under `observed` — only under `inferred` with a basis.

## What the caller passes

- Case context (hypothesis-only projection): current summary, confidence, hosts seen so far, caps previously observed.
- The raw artifact bytes (utf-8 decoded with replacement, ≤64KB — caller truncates).

## Defensive framing

This is post-incident forensic reasoning. The artifact is static evidence from an already-contained compromise. Your job is to describe what it would do, not advise how to deploy it.

## Output

Exactly one JSON object matching the schema. No prose. No code fences.
```

### 5.15 `prompts/synthesizer.md` (~70 LOC, NEW)

Opus 4.7 system prompt for rule synthesis. Structure:

```markdown
# synthesizer system prompt — blacklight curator, Opus 4.7

You are blacklight's defense synthesizer. You receive a CapabilityMap describing an actor's capabilities (observed, inferred, likely-next) and the case context, and you produce ModSec rules + exceptions + a validation test per capability category.

You output a `SynthesisResult` as structured JSON matching the schema the caller passed in `output_config.format`. Do not narrate outside the JSON.

## Fields in the JSON schema

- `rules`: list of `{rule_id, body, applies_to, capability_ref, confidence, validation_error}`.
  - `rule_id`: `BL-{capability_ref_kebab}-{3digit_seq}` (e.g. `BL-rce-via-webshell-001`).
  - `body`: complete ModSec SecRule directive text including `id:`, `phase:`, action, `msg:`, `tag:`. Must parse under apachectl -t.
  - `applies_to`: `["apache", "apache-modsec"]` or `["apache"]`. Nginx profiles are never in `applies_to` for this synthesizer (ModSec is Apache-only for blacklight v1).
  - `capability_ref`: the `observed.cap` or `inferred.cap` string this rule defends.
  - `confidence`: 0.0-1.0. Use 0.7+ for observed-capability rules (grounded), 0.4-0.7 for inferred-capability rules, 0.2-0.4 for likely-next (predictive).
  - `validation_error`: always null from the model; the curator populates on configtest failure.

- `suggested_rules`: same shape as `rules[]`; the model can route a rule here directly if it lacks confidence. The curator will additionally demote any rule that fails `apachectl configtest`.

- `exceptions`: list of `{rule_id_ref, path_glob, reason}` — false-positive carve-outs. For Magento, the common FP is `vendor/**` (framework-legitimate PHP). Synthesize at least one exception per rule that touches `REQUEST_URI` patterns.

- `validation_test`: a single HTTP request line (e.g. `GET /pub/media/catalog/product/.cache/a.php?cmd=id HTTP/1.1`) that should trip the rule in `DetectionOnly` mode. One test per synthesis batch.

## ModSec rule discipline (ALL mandatory)

1. **ID range.** Use `id:` in the 900000-999999 range (operator-custom range per OWASP CRS reservation).
2. **Phase.** Use `phase:2` for request-body/URI matching. Use `phase:1` only for header-only rules.
3. **Actions.** Every rule must include `msg:` (with `blacklight: ` prefix) and at least one `tag:` starting with `blacklight/`.
4. **Escape discipline.** Double backslash before regex metacharacters inside ModSec strings (`@rx \\.php$` not `@rx \.php$`). The curator writes this directive text directly to a file.
5. **No `deny` without `status:`.** Always `deny,status:403` paired.
6. **No `SecRuleEngine On` in rule body.** Engine mode is set at Apache config level, not per-rule.

## What the caller passes

Case context (hypothesis summary + observed caps + open questions) and the CapabilityMap. You synthesize rules primarily from `observed` (high confidence) and `inferred` (medium). `likely_next` may inspire predictive rules but route those to `suggested_rules[]` with confidence ≤0.4.

## Defensive framing

These rules deploy to live production hosting fleet mod_security layers. Every rule is a defensive control. False positives cost real operators real pages. Synthesize conservatively.

## Output

Exactly one JSON object matching the schema. No prose. No code fences.
```

---

## 5b. Examples

### 5b.1 Synthesize CLI happy path

```bash
$ ANTHROPIC_API_KEY=sk-ant-... python -m curator.synthesize CASE-2026-0007
[synthesize] loading case from curator/storage/cases/CASE-2026-0007.yaml
[synthesize] capability_map: observed=2, inferred=1, likely_next=0
[synthesize] invoking synthesizer (Opus 4.7)...
[synthesize] synthesizer returned 3 rules, 0 suggested, 1 exception, 1 validation_test
[synthesize] validating rules via apachectl -t...
[synthesize]   BL-rce-via-webshell-001: PASS
[synthesize]   BL-c2-callback-outbound-001: PASS
[synthesize]   BL-credential-harvest-001: FAIL (demoted to suggested_rules)
[synthesize] publishing manifest...
manifest v1
$ echo $?
0
```

### 5b.2 bl-pull happy path on host-2 (Apache)

```bash
host-2:/# /opt/bl-agent/bl-pull
[bl-pull 2026-04-23T22:15:03Z] pulling manifest from http://bl-curator:8080
[bl-pull 2026-04-23T22:15:03Z] fetching sidecar hash
[bl-pull 2026-04-23T22:15:03Z] hash verified
[bl-pull 2026-04-23T22:15:03Z] manifest written to /var/bl-agent/manifest.yaml
host-2:/# echo $?
0
```

### 5b.3 bl-apply apply path on host-2 (Apache+ModSec)

```bash
host-2:/# /opt/bl-agent/bl-apply
[bl-apply 2026-04-23T22:15:30Z] detected stack profile: apache-modsec
[bl-apply 2026-04-23T22:15:30Z] manifest v1 carries 2 rule(s) for Apache profile
[bl-apply 2026-04-23T22:15:31Z] apachectl -t PASS for manifest v1
host-2:/# ls /etc/apache2/conf-enabled/bl-rules.conf
lrwxrwxrwx 1 root root 50 Apr 23 22:15 /etc/apache2/conf-enabled/bl-rules.conf -> /etc/apache2/conf-available/bl-rules-1.conf
host-2:/# echo $?
0
```

### 5b.4 bl-apply skip path on host-3 (Nginx)

```bash
host-3:/# /opt/bl-agent/bl-apply
[bl-apply 2026-04-23T22:15:45Z] detected stack profile: nginx
[bl-apply 2026-04-23T22:15:45Z] stack profile 'nginx' — skipping Apache ruleset (manifest v1)
host-3:/# echo $?
0
```

### 5b.5 Manifest served content

```bash
$ curl -s http://bl-curator:8080/manifest.yaml
exceptions:
  - path_glob: vendor/**
    reason: Magento framework-legitimate PHP
    rule_id_ref: BL-rce-via-webshell-001
generated_at: '2026-04-23T22:15:03Z'
rules:
  - applies_to:
      - apache
      - apache-modsec
    body: 'SecRule REQUEST_URI "@rx \\.php$" "id:900001,phase:2,deny,status:403,msg:''blacklight: PolyShell suspect path'',logdata:''%{MATCHED_VAR}'',tag:''blacklight/rce'',tag:''blacklight/v1''"'
    capability_ref: rce_via_webshell
    confidence: 0.85
    rule_id: BL-rce-via-webshell-001
    validation_error: null
  - applies_to:
      - apache
      - apache-modsec
    body: 'SecRule REQUEST_HEADERS:User-Agent "@rx (vagqea4wrlkdg\\.top)" "id:900002,phase:1,deny,status:403,msg:''blacklight: known C2 callback host'',tag:''blacklight/c2''"'
    capability_ref: c2_callback_outbound
    confidence: 0.92
    rule_id: BL-c2-callback-outbound-001
    validation_error: null
suggested_rules:
  - applies_to:
      - apache
      - apache-modsec
    body: '[invalid directive body for this example]'
    capability_ref: credential_harvest
    confidence: 0.45
    rule_id: BL-credential-harvest-001
    validation_error: "AH00526: Syntax error on line 3 of /tmp/bl-validate-...conf: Invalid command ..."
validation_test: 'GET /pub/media/catalog/product/.cache/a.php?cmd=id HTTP/1.1'
version: 1

$ curl -s http://bl-curator:8080/manifest.yaml.sha256
4f9c0b8a3d2e1f7b6a5d4c3e2f1a0b9c8d7e6f5a4b3c2d1e0f9a8b7c6d5e4f3a  manifest.yaml
```

### 5b.6 SHA-256 mismatch rejection

```bash
host-2:/# /opt/bl-agent/bl-pull
[bl-pull 2026-04-23T22:16:00Z] pulling manifest from http://bl-curator:8080
[bl-pull 2026-04-23T22:16:00Z] fetching sidecar hash
manifest.yaml: FAILED
sha256sum: WARNING: 1 computed checksum did NOT match
[bl-pull 2026-04-23T22:16:00Z] SHA-256 mismatch — refusing to install
host-2:/# echo $?
1
host-2:/# ls -la /var/bl-agent/manifest.yaml  # unchanged
-rw-r--r-- 1 root root 842 Apr 23 22:15 /var/bl-agent/manifest.yaml
```

---

## 6. Conventions

### 6.1 Python module header

Every new Python module starts with:

```python
"""{one-line module purpose}.

{one or two sentences of context tying to spec section or HANDOFF anchor}.
"""

from __future__ import annotations
```

No multi-paragraph docstrings. No `Arguments:` / `Returns:` blocks above typed signatures (global CLAUDE.md anti-pattern #13).

### 6.2 Pydantic v2

- `model_config = ConfigDict(extra="forbid", populate_by_name=True)`.
- No v1 `class Config` syntax.
- `model.model_dump(mode="json")` for serialization.

### 6.3 Anthropic call — intent + synthesizer

Identical call shape to `case_engine.revise` (Day-3 proven, 36863d6):

- Client: `anthropic.Anthropic()` (sync).
- `model=MODEL_CURATOR` (= `"claude-opus-4-7"`).
- `thinking={"type": "adaptive", "display": "summarized"}` — required on intent; optional on synthesizer (keep enabled for consistency; synthesizer needs moderate reasoning about rule + exception coherence).
- `output_config={"effort": "high", "format": {"type": "json_schema", "schema": ...}}`.
- `max_tokens=16000`.
- **No `tool_choice`** (Opus 4.7 rejects with thinking on — HTTP 400).
- **No `budget_tokens`** (removed on Opus 4.7).
- Flat schema: no `oneOf`/`anyOf`/`allOf`, no number `minimum`/`maximum`, `additionalProperties: false` on every object, Dict[str,T] maps as array-of-pair objects + post-parse normalize.

### 6.4 BL_SKIP_LIVE contract

- `intent.reconstruct()` returns deterministic stub CapabilityMap (1 observed entry, 0 inferred, 0 likely_next).
- `synthesizer.synthesize()` returns deterministic stub SynthesisResult (0 rules, 1 suggested_rule with `validation_error: "BL_SKIP_LIVE stub"`).
- `synthesizer.validate_rule()` is NOT gated by BL_SKIP_LIVE — it's a local subprocess call, and integration tests verify apachectl behavior. Tests that exercise `validate_rule()` directly (`test_validate_rule_passing`, `test_validate_rule_failing`, `test_validate_and_partition_demotes_failing`) must guard with `@pytest.mark.skipif(shutil.which("apachectl") is None, reason="requires apachectl — run inside curator container or install apache2-utils locally")`. Full-suite runs inside the curator Docker image exercise these; local dev runs without apache2 degrade gracefully without masking other failures.
- Orchestrator-level BL_SKIP_LIVE short-circuits remain unchanged.

### 6.5 Bash — bl-agent scripts

Per workspace CLAUDE.md §"Shell Standards":
- Shebang: `#!/bin/bash` (existing convention for blacklight bl-agent).
- `set -euo pipefail` at script head.
- `command` prefix on all coreutils (`command cp`, `command mv`, `command install`, `command mkdir`, `command cat`, `command printf`, `command date`).
- `apachectl`, `yq`, `curl`, `sha256sum` are NOT coreutils; invoke bare.
- `$()` not backticks. `$(( ))` not `$[]`. `local` for function-scoped vars.
- Double-quote all variable references in command context.
- `cd "$dir"` → `|| exit 1` / `|| return 1` guard. `( cd X && ... )` subshell also needs `|| exit 1` on the subshell if the `cd` could fail.
- `|| true` / `2>/dev/null` need inline same-line comment.
- `grep -E` not `egrep`. `command -v` not `which`.

### 6.6 Commit format

LMD-style: `[Type] description` subject with `[New]` / `[Change]` / `[Fix]` body tags. Stage files by name. No `Co-Authored-By`. No Anthropic attribution.

Example:
```
[New] curator/intent.py + prompts/intent.md — Opus 4.7 artifact reconstruction (G1)

[New] curator/intent.py — reconstruct(artifact_path, case_context) → CapabilityMap via Opus 4.7 + adaptive thinking.
[New] prompts/intent.md — system prompt with family-pattern reasoning rules.
[New] tests/test_intent.py — BL_SKIP_LIVE stub + schema-valid mocked response.
```

### 6.7 CRITICAL constraints

- **NEVER edit `curator/case_schema.py`** — Day-1 lock (constraints.md:85).
- **NEVER author operator-content skill files** — stubs stay stubs (constraints.md:95-100).
- **NEVER `git add -A` or `git add .`** — stage files by name (workspace CLAUDE.md).
- **Defensive framing only** — "investigation", "forensics", "capability inference" — never "exploit"/"attack"/"offensive". Applies to code comments, prompt text, commit messages, README.
- **Evidence summarization boundary** — intent.py reads raw artifact content; synthesizer.py reads CapabilityMap (structured, no raw bytes); case_engine reads evidence summaries only (unchanged).

---

## 7. Interface Contracts

### 7.1 Python function signatures (public API)

```python
# curator/intent.py
def reconstruct(
    artifact_path: Path,
    case_context: CaseFile,
    *,
    client: Optional[anthropic.Anthropic] = None,
) -> CapabilityMap: ...

# curator/synthesizer.py
def synthesize(
    capability_map: CapabilityMap,
    case_context: CaseFile,
    *,
    client: Optional[anthropic.Anthropic] = None,
) -> SynthesisResult: ...

def validate_rule(rule_text: str) -> tuple[bool, str]: ...

# curator/manifest.py
def publish(
    synth_result: SynthesisResult,
    *,
    storage_dir: Optional[Path] = None,
) -> int: ...  # returns new manifest version

def load(storage_dir: Optional[Path] = None) -> Manifest: ...

# curator/case_engine.py (new)
def merge_capability_map(
    case: CaseFile,
    cap_map: CapabilityMap,
    *,
    updated_by: str = "intent_reconstructor",
    clock: Optional[Callable[[], datetime]] = None,
) -> CaseFile: ...
```

### 7.2 CLI contracts

```
python -m curator.synthesize <case_id>
    exit 0 → "manifest v{N}" on stdout
    exit 1 → network/API error (message on stderr)
    exit 2 → case not found or malformed

bl-agent/bl-pull
    exit 0 → manifest + sidecar fetched, hash verified, manifest installed
    exit 1 → fetch failed OR hash mismatch (manifest NOT installed)
    exit 2 → missing dependency (curl, sha256sum)

bl-agent/bl-apply
    exit 0 → skip path (nginx/unknown) OR apply-success + configtest PASS
    exit 1 → manifest not readable (run bl-pull first)
    exit 2 → missing dependency (yq, apachectl)
    exit 3 → configtest FAIL (rule file written but disabled in log)
```

### 7.3 HTTP contracts

```
GET /manifest.yaml
    200 → application/x-yaml body
    (Day-1 fallback: "version: 0\ndefenses: []\n" — preserved unchanged)

GET /manifest.yaml.sha256   (NEW)
    200 → text/plain, format "{hex_64}  manifest.yaml\n"
    404 → manifest sidecar not yet written (consistent with 200-empty-manifest behavior; bl-pull must handle)

POST /reports
    unchanged from Day 2.

GET /health
    unchanged.
```

**Note on 404 behavior for sidecar:** When the curator has never published a manifest, `manifest.yaml.sha256` does not exist. bl-pull's fetch will fail with curl's 404 → bl-pull exits 1 with "sidecar fetch failed". This is acceptable (no silent fallback to unverified manifest); the default manifest from `curator/server.py:29` is the Day-1 placeholder, not intended for real apply.

### 7.4 Manifest YAML schema (served body)

```yaml
version: <int>                      # monotonic; bumped by manifest.publish
generated_at: <ISO-8601 UTC>        # from synthesizer run time
rules:
  - rule_id: <str>                  # BL-{capability_ref_kebab}-{seq}
    body: <str>                     # complete ModSec directive text
    applies_to: [<str>, ...]        # ["apache", "apache-modsec"]
    capability_ref: <str>           # observed.cap or inferred.cap
    confidence: <float>             # 0.0-1.0
    validation_error: <str|null>    # null on pass, apachectl stderr on fail (fail-only appears in suggested_rules, never rules)
suggested_rules:                    # same shape; apply-path skips these
  - ...
exceptions:
  - rule_id_ref: <str>
    path_glob: <str>
    reason: <str>
validation_test: <str>              # sample HTTP request line
```

**Stable YAML ordering:** `yaml.safe_dump(sort_keys=True)` — alphabetical by key at every nesting level. Preserves deterministic hash.

---

## 8. Migration Safety

### 8.1 Test suite impact

| Test file | Before | After |
|---|---|---|
| `tests/test_revision.py` | 6 tests PASS | 6 tests PASS (unchanged) |
| `tests/test_hunters_base.py` | N tests PASS | N tests PASS (unchanged) |
| `tests/test_orchestrator_smoke.py` | K tests PASS | K+2 tests PASS (new: test_intent_merge_via_orchestrator, test_intent_skipped_without_webshell_candidate) |
| `tests/test_evidence.py` | PASS | PASS (unchanged) |
| `tests/test_report_envelope.py` | PASS | PASS (unchanged) |
| `tests/test_fs_hunter.py` | PASS | PASS (unchanged) |
| `tests/test_log_hunter.py` | PASS | PASS (unchanged) |
| `tests/test_timeline_hunter.py` | PASS | PASS (unchanged) |
| `tests/test_intent.py` | N/A | ~6 tests PASS |
| `tests/test_synthesizer.py` | N/A | ~8 tests PASS |
| `tests/test_manifest.py` | N/A | ~4 tests PASS |
| `tests/test_synthesize_cli.py` | N/A | ~3 tests PASS |
| `tests/test_merge_capability_map.py` | N/A | ~3 tests PASS |

Net: 57 existing tests remain green; new tests land across the five new files listed above. Exact final count is derived from §10a at implementation time (advisory: ~30 new named tests). **Hard contract: 0 skipped in both default and BL_SKIP_LIVE=1 modes.**

### 8.2 Data-file compatibility

- **Existing case YAMLs:** unchanged. `capability_map` field is optional in Day-1 schema; existing cases without it parse fine.
- **Existing evidence.db:** unchanged. No schema migration.
- **New storage file `manifest.yaml.sha256`:** new file; absent on Day-3-state repos; bl-pull handles 404 by exiting 1 (correct).
- **Canonical-form manifest compatibility:** any manifest written by Day 4 `manifest.publish()` is hash-compatible with `sha256sum -c`. Old manifest.yaml from Day 1 (`version: 0\ndefenses: []\n`) has no sidecar and is not verifiable — but bl-pull refuses rather than falling back.

### 8.3 Docker image rebuild

- `compose/curator.Dockerfile` change adds ~80MB (apache2 + mod_security2). Rebuild required on any anvil/freedom host.
- `compose/host-nginx.Dockerfile` is new; requires first build (~5MB total).
- `compose/host-apache.Dockerfile` unchanged; no rebuild triggered.
- `docker compose up --build` handles both.

### 8.4 Upgrade path (Day 3 → Day 4)

1. `git pull` (or merge branch).
2. `docker compose down` (optional; running containers keep old images).
3. `docker compose build curator host-3` (rebuild changed images).
4. `docker compose up -d`.
5. First `bl-pull` on any host: fetches Day-4 manifest (if published) or 404s on sidecar until `python -m curator.synthesize` runs. Behavior is graceful.

### 8.5 Rollback

- Revert Day-4 commits.
- `docker compose build --no-cache` to strip apache2 + mod_security2 from curator.
- Existing Day-3 state (case YAMLs, evidence.db) preserved.
- `bl-pull`/`bl-apply` revert to Day-3 scaffold (TODO-marker) behavior.

---

## 9. Dead Code and Cleanup

- `curator/server.py:47` — the inline `EMPTY_MANIFEST = "version: 0\ndefenses: []\n"` constant. After Day 4, `publish()` writes a real manifest. Keep the fallback for dev-first-run ergonomics (curator comes up before any synth has run). Not dead.
- `bl-agent/bl-apply:13` — `MODSEC_DROPIN` variable with shellcheck disable comment (SC2034, "consumed Day 4 when rule-write path is populated"). Day 4 write-path uses `$rules_conf`/`$rules_enabled` instead of `$MODSEC_DROPIN`. **Remove `MODSEC_DROPIN` + its disable comment** — now genuinely unused and the comment was a Day-1-future-promise that the Day-4 design does not honor.
- `bl-agent/bl-pull:38-39` — `TODO(day-4)` comment. Replace with actual implementation (G5).
- `bl-agent/bl-apply:46-50` — `TODO(day-4)` comment. Replace with actual implementation (G6).
- `curator/case_engine.py:324-337` — defensive drop of non-ISO `proposed_actions[].at`. Prompt fix (G10) reduces drop rate but does NOT replace the guard. Keep both (defense in depth).

---

## 10a. Test Strategy

| Goal | Test file | Test description |
|---|---|---|
| G1 | tests/test_intent.py | `test_intent_stub_returns_valid_capability_map` — BL_SKIP_LIVE=1 returns a schema-valid CapabilityMap |
| G1 | tests/test_intent.py | `test_intent_mocked_opus_returns_observed_rce` — patch `anthropic.Anthropic`, fixture response, assert observed[0].cap=="rce_via_webshell" |
| G1 | tests/test_intent.py | `test_intent_mocked_malformed_response_raises` — patch returns non-JSON text, assert `IntentParseError` |
| G1 | tests/test_intent.py | `test_intent_mocked_confidence_out_of_range_clamped` — model returns conf=1.5, after clamp stored as 1.0 |
| G1 | tests/test_intent.py | `test_intent_reads_truncated_artifact` — 128KB file, verify only first 64KB reaches user_content |
| G1 | tests/test_intent.py | `test_intent_case_context_excludes_raw_evidence` — CaseFile with raw_evidence_excerpt field NOT surfaced in model input |
| G2 | tests/test_synthesizer.py | `test_synthesize_stub_returns_valid_result` — BL_SKIP_LIVE=1 returns schema-valid SynthesisResult |
| G2 | tests/test_synthesizer.py | `test_synthesize_mocked_returns_3_rules` — mock response, assert rule count + rule_id formatting |
| G2 | tests/test_synthesizer.py | `test_synthesize_high_conf_stays_in_rules` — conf=0.85 rule not demoted |
| G2 | tests/test_synthesizer.py | `test_synthesize_low_conf_moves_to_suggested` — conf=0.5 rule moved by `_split_by_confidence` |
| G2 | tests/test_synthesizer.py | `test_validate_rule_passing` — fixture apachectl_pass.conf body → (True, "") |
| G2 | tests/test_synthesizer.py | `test_validate_rule_failing` — fixture apachectl_fail.conf body → (False, stderr containing "syntax error") |
| G2 | tests/test_synthesizer.py | `test_validate_and_partition_demotes_failing` — 3 rules, 1 fails configtest → moves to suggested_rules with validation_error populated |
| G2 | tests/test_synthesizer.py | `test_synthesize_rule_id_sequence_deterministic` — same CapabilityMap → same rule_ids |
| G3 | tests/test_manifest.py | `test_canonical_bytes_deterministic` — same SynthesisResult → same bytes twice |
| G3 | tests/test_manifest.py | `test_publish_monotonic_version` — publish twice, version=1 then version=2 |
| G3 | tests/test_manifest.py | `test_publish_rejects_rollback` — attempt to publish version=1 after version=2 → refuses |
| G3 | tests/test_manifest.py | `test_publish_sha256_sidecar_matches_main_bytes` — `sha256sum manifest.yaml` matches sidecar content |
| G4 | tests/test_synthesize_cli.py | `test_cli_happy_path_skip_live` — BL_SKIP_LIVE=1, exits 0, publishes v1 |
| G4 | tests/test_synthesize_cli.py | `test_cli_case_not_found_exits_2` — wrong case_id, exit 2 |
| G4 | tests/test_synthesize_cli.py | `test_cli_missing_api_key_exits_1` — no API key + no BL_SKIP_LIVE, exit 1 |
| G5 | tests/fixtures/smoke/test-bl-pull.sh | `test_bl_pull_verify_pass` — real server + real sidecar, install succeeds |
| G5 | tests/fixtures/smoke/test-bl-pull.sh | `test_bl_pull_hash_mismatch_rejects` — corrupt sidecar, bl-pull exits 1, local manifest unchanged |
| G5 | tests/fixtures/smoke/test-bl-pull.sh | `test_bl_pull_missing_sidecar_rejects` — sidecar 404, exit 1 |
| G6 | tests/fixtures/smoke/test-bl-apply.sh | `test_bl_apply_nginx_skips` — fake nginx stack, exit 0 with skip log |
| G6 | tests/fixtures/smoke/test-bl-apply.sh | `test_bl_apply_apache_installs_and_passes_configtest` — real apachectl on curator container (since apache2 is installed there), rule file written, configtest PASS |
| G6 | tests/fixtures/smoke/test-bl-apply.sh | `test_bl_apply_apache_configtest_fail_nonzero_exit` — staged invalid rule, exit 3 |
| G7 | verify in CI | `docker run blacklight/curator:dev apachectl -V` — apache2 present + mod_security2 module loads |
| G8 | verify in CI | `docker compose up -d host-3 && docker exec bl-host-3 which bash curl` — both present |
| G9 | tests/test_orchestrator_smoke.py | `test_intent_merge_via_orchestrator` — BL_SKIP_LIVE=1, fs-hunter returns `webshell_candidate`, assert case.capability_map.observed populated |
| G9 | tests/test_orchestrator_smoke.py | `test_intent_skipped_without_webshell_candidate` — fs-hunter returns only `log_anomaly`, assert intent NOT called |
| G9 | tests/test_orchestrator_smoke.py | `test_intent_skipped_when_no_php_in_tar` — webshell_candidate row but no .php file in extracted tar, assert warn-log + no-op |
| G9 | tests/test_merge_capability_map.py | `test_merge_updates_last_updated_at_and_updated_by` |
| G9 | tests/test_merge_capability_map.py | `test_merge_does_not_touch_hypothesis` — hypothesis unchanged |
| G9 | tests/test_merge_capability_map.py | `test_merge_dedupes_observed_by_cap` — delegates to existing `_merge_capability_maps` |
| G10 | live smoke (operator) | run synthesize CLI with Opus 4.7 live; inspect 5 recent `proposed_actions` → all `at` fields parse as ISO-8601 |
| G11 | CI / pre-commit | `pytest -v tests/ && BL_SKIP_LIVE=1 pytest -v tests/` both green |
| G12 | pre-commit | `git diff 9edbced -- curator/case_schema.py` empty |

**Test infra pattern:** Unit tests mirror `tests/test_revision.py` structure (pytest + `unittest.mock.patch` on `anthropic.Anthropic`). Shell smoke tests are subprocess-invoked from a wrapper pytest file so the CI gate is a single `pytest` invocation.

---

## 10b. Verification Commands

```bash
# G1 — Intent module exists + imports cleanly
python -c "from curator.intent import reconstruct, IntentParseError"
# expect: (no output, exit 0)

# G2 — Synthesizer module exists + imports cleanly
python -c "from curator.synthesizer import synthesize, validate_rule, SynthesisResult"
# expect: (no output, exit 0)

# G3 — Manifest module exists + imports
python -c "from curator.manifest import Manifest, publish, load"
# expect: (no output, exit 0)

# G4 — Synthesize CLI reachable
BL_SKIP_LIVE=1 python -m curator.synthesize --help
# expect: usage line mentioning "case_id"

# G5 — bl-pull has hash verification
grep -q 'sha256sum -c' bl-agent/bl-pull
# expect: exit 0 (match found)

# G6 — bl-apply parses manifest with yq
grep -q 'yq.*\.rules' bl-agent/bl-apply
# expect: exit 0

# G7 — curator Dockerfile installs apache2 + mod_security2
grep -q 'apache2.*libapache2-mod-security2' compose/curator.Dockerfile
# expect: exit 0

# G8 — host-nginx Dockerfile exists + references nginx base
test -f compose/host-nginx.Dockerfile && grep -q 'FROM nginx' compose/host-nginx.Dockerfile
# expect: exit 0

# G9 — orchestrator calls intent + merge_capability_map
grep -q '_maybe_reconstruct_intent' curator/orchestrator.py && grep -q 'merge_capability_map' curator/case_engine.py
# expect: exit 0

# G10 — prompt guidance for proposed_actions.at
grep -q 'proposed_actions.*at.*ISO-8601' prompts/case-engine.md
# expect: exit 0

# G11 — full pytest green, 0 skipped
pytest -v tests/ 2>&1 | tail -3 | grep -E '[0-9]+ passed.*0 skipped'
# expect: matches

BL_SKIP_LIVE=1 pytest -v tests/ 2>&1 | tail -3 | grep -E '[0-9]+ passed.*0 skipped'
# expect: matches

# G12 — Day-1 schema lock intact
git diff 9edbced -- curator/case_schema.py | wc -l
# expect: 0

# Framing discipline
grep -rEi 'offensive|exploit surface|attacker.*perspective' curator/ prompts/
# expect: (no output, exit 1 from grep)

# Bash verification suite (workspace CLAUDE.md)
bash -n bl-agent/bl-pull bl-agent/bl-apply bl-agent/bl-report bl-agent/install.sh
shellcheck bl-agent/bl-pull bl-agent/bl-apply bl-agent/bl-report bl-agent/install.sh
# expect: exit 0 on all

# Coreutils discipline
grep -rn '^\s*cp \|^\s*mv \|^\s*rm ' bl-agent/
grep -rn '^\s*chmod \|^\s*mkdir \|^\s*touch \|^\s*ln ' bl-agent/
# expect: (no output — all coreutils command-prefixed)

# Live smoke (Day-4 gate, operator-run)
docker compose up -d --build
sleep 5
ANTHROPIC_API_KEY=sk-... python -m curator.synthesize CASE-2026-0007
# expect: stdout "manifest v1", exit 0
curl -fsS http://localhost:8080/manifest.yaml.sha256
# expect: 64-hex + "  manifest.yaml"
docker exec bl-host-2 /opt/bl-agent/bl-pull
# expect: exit 0, "hash verified"
docker exec bl-host-2 /opt/bl-agent/bl-apply
# expect: exit 0, "apachectl -t PASS"
docker exec bl-host-3 /opt/bl-agent/bl-apply
# expect: exit 0, "stack profile 'nginx' — skipping Apache ruleset"

# Remaining operator-content stubs still stubs.
# skills/ir-playbook/case-lifecycle.md has mature content as of d00ddd1 — excluded.
for f in skills/webshell-families/polyshell.md skills/defense-synthesis/modsec-patterns.md; do
    grep -q 'TODO: operator content' "$f" || echo "STUB VIOLATED: $f"
done
# expect: (no output)
```

---

## 11. Risks

1. **apachectl + mod_security2 image bloat causes Docker-compose rebuild time to exceed anvil cache miss tolerance.** Rebuilds that used to be 2-5 minutes become 7-10 minutes. **Mitigation:** BUILDKIT layer cache preserves the apt-get layer once built; only invalidated when apt sources or the RUN line changes. Pin dependency list (don't add packages one at a time across commits). Cold rebuild on freedom/anvil validated once during P7.

2. **Opus 4.7 synthesizer produces rules that parse syntactically but logically over-block (false positives).** Demo-time: a rule blocks a legitimate Magento request, ModSec error log fills, host becomes unreachable. **Mitigation:** every rule synthesis includes at least one `exception` targeting `vendor/**`. Validation test line in the SynthesisResult serves as a positive-match canary; at demo recording time the operator runs the validation test against host-2 to confirm the rule fires on the bad traffic, not the good.

3. **Intent reconstructor artifact reading exceeds `max_bytes` on a multi-layer obfuscated PolyShell (gzinflate-wrapped base64 chain).** Truncated artifact missing the outer wrapper, model reports `observed=[]`. **Mitigation:** `max_bytes=64000` is well above the staged `a.php` size (~10KB). If a real-world artifact exceeds 64KB, operator sets `BL_INTENT_MAX_BYTES` env override; documented in `curator/intent.py` module docstring.

4. **yq not installed on host-3 Nginx image.** Alpine's `apk add curl bash` adds bash + curl but not yq. bl-apply fails on host-3 when it tries to parse the manifest (even though host-3 skips rules — the yq call happens before the `detect_stack` check logically). **Mitigation:** reorder bl-apply logic so `detect_stack()` runs before `require yq`. If stack is nginx/unknown, skip before requiring yq. Add `apk add --no-cache yq` to `host-nginx.Dockerfile` as defense-in-depth (even though the skip-first logic should make it unnecessary).

5. **Docker rebuild on host-3 forces compose re-up of host-2 + curator via container name collision.** Existing `bl-host-2` + `bl-curator` must be taken down before `bl-host-3` rebuilds (since `docker compose build host-3` + `docker compose up -d host-3` tries to recreate network attachments). **Mitigation:** `docker compose down && docker compose up -d --build` — full cycle. Operator runbook step in P7 smoke runbook.

6. **`manifest.yaml.sha256` race condition: bl-pull fetches manifest.yaml, curator publishes v2, bl-pull fetches stale v1 sha256, hash mismatch, bl-pull exits 1 → transient false alarm.** **Mitigation:** curator writes sidecar before manifest via atomic rename of both; sidecar reflects OLD hash during write window. Accept: bl-pull re-runs on systemd timer (Day 4 install.sh wires 30s interval), next run succeeds. Alternatively: fetch sidecar FIRST, then manifest, verify. Adopt fetch-order: sidecar-then-manifest in bl-pull.

7. **Synthesizer times out (>30s) on Opus 4.7 with adaptive thinking on a rich CapabilityMap.** `anthropic` SDK default timeout is 600s; actual `apachectl` validation per rule runs sequentially. **Mitigation:** enforce `timeout=60` on `subprocess.run(apachectl)`. Overall synth call is operator-triggered, not on hot path — operator waits.

8. **Rule validation produces false PASS on syntactically-valid but semantically-broken rule.** `apachectl -t` does not detect rules that always match (causing universal block) or never match. **Mitigation:** INFORMATIONAL — Day-5 time-compression simulator is the semantic validator (does the rule block the bad request? does the vendor/** exception let the good request through?). Documented in Day-5 scope; NOT a Day-4 gate item.

9. **Operator-triggered synthesizer CLI lacks demo-time integration test — nobody runs it end-to-end until Saturday recording.** Spec smoke test (G11 live smoke) requires operator action. **Mitigation:** P7 checkpoint includes a **mandatory live run** of `python -m curator.synthesize` end-to-end with real API key before the Day-4 gate is claimed. Operator runbook artifact in `work-output/runbook-day4-smoke.md`.

10. **apachectl path differences across Debian image versions.** `apache2` package on Debian 12 slim provides `/usr/sbin/apache2ctl` with `apachectl` as a symlink. Image rebuild on different base may vary. **Mitigation:** invoke `apachectl` via PATH (`subprocess.run(["apachectl", ...])`); pin base image `python:3.12-slim` (already pinned in curator.Dockerfile:3).

---

## 11b. Edge Cases

| # | Scenario | Expected behavior | Handling |
|---|---|---|---|
| 1 | fs-hunter returns webshell_candidate but no .php in tar | intent skipped, WARN logged | `_maybe_reconstruct_intent` early-returns unchanged case after warn |
| 2 | Intent returns CapabilityMap with observed.confidence > 1.0 | Clamp to 1.0, WARN logged | `_clamp_confidences` (imported from case_engine) runs on payload before model_validate |
| 3 | Synthesizer returns a rule with identical rule_id to a previously-published rule | Manifest republish overwrites rule at that id | Determined: rule_id is deterministic given same input, so identical cases produce identical manifests; re-publish is monotonic-safe |
| 4 | apachectl -t segfaults or OOMs on a pathological rule | subprocess.TimeoutExpired (10s) → rule demoted to suggested_rules with `validation_error="apachectl timeout"` | timeout=10 on subprocess.run |
| 5 | Manifest canonical-bytes generated with unicode in rule body (e.g. "msg:'blacklight — suspect'") | Fails `allow_unicode=False` guard | yaml.safe_dump with allow_unicode=False raises UnicodeEncodeError; synthesizer rejects body with non-ASCII characters (explicit check in `_validate_and_partition`), demotes to suggested_rules with `validation_error="non-ASCII in rule body"` |
| 6 | bl-pull fetches manifest.yaml successfully but sidecar 404s (curator has never synthesized) | bl-pull exits 1 with "sidecar fetch failed" | Existing local manifest preserved; systemd timer retries |
| 7 | bl-apply on unknown stack (neither apache nor nginx; e.g. bare Debian without either) | Skip with log "stack profile 'unknown' — skipping", exit 0 | Explicit branch in `apply_rules` |
| 8 | bl-apply run twice on the same manifest version | Idempotent: symlink already exists, rule file bytes identical, configtest still PASS | `ln -sf` replaces existing symlink; `install -D` overwrites rule file with identical bytes |
| 9 | Manifest has 0 rules (synthesizer returned only suggested_rules) | bl-apply writes empty `/etc/apache2/conf-available/bl-rules-{version}.conf`, configtest PASS | Explicit handling: if rule_count == 0, write empty file (not skip), so apachectl Include still points at a real file |
| 10 | Synthesize CLI invoked before any hunter run (case has empty capability_map) | Exit 0 with log "capability_map empty; 0 rules published", manifest v bumped with rules=[] | Explicit guard: `if not cap_map.observed and not cap_map.inferred: log + publish-empty` |
| 11 | Intent call fails with network error mid-reconstruct | `anthropic.APIError` propagates; orchestrator logs, keeps case untouched | Exception boundary in `_maybe_reconstruct_intent` catches `anthropic.APIError`, logs, returns unchanged case; the revision-path (case_engine) runs independently |
| 12 | Opus 4.7 returns a CapabilityMap with `likely_next[].ranked` duplicates | Last entry wins at given rank; not an error | CapabilityMap schema does not enforce unique ranks — accept as-is; synthesizer downstream is rank-agnostic |
| 13 | Curator Dockerfile apt install fails (Debian mirror blip) | Docker build fails at apt-get install line | Transient; retry build. Operator runbook: `docker compose build --no-cache curator` |

---

## 12. Open Questions

None — all design decisions locked in Phase 2 brainstorm (Q1-Q6).

---

## Appendix A — Decision cross-reference

| Decision | Section | Anchor |
|---|---|---|
| Q1: Intent as separate orchestrator step | §4.7, §5.1, §5.5 | .rdf/work-output/spec-progress.md Q1 |
| Q2: Synthesizer CLI-triggered | §4.7, §5.4 | spec-progress.md Q2 |
| Q3: apachectl in curator image | §5.11, §6 | spec-progress.md Q3 |
| Q4: YAML + SHA-256 sidecar | §5.3, §7.4 | spec-progress.md Q4 |
| Q5: bl-apply write+symlink+configtest, no reload | §5.9 | spec-progress.md Q5 |
| Q6: Minimal Nginx host-3 (REVISED) | §5.10, §5.12 | spec-progress.md Q6 |

## Appendix B — Plan phase decomposition (advisory; /r-plan consumes this)

Advisory phases for the planner:

- P20: `prompts/case-engine.md` `proposed_actions.at` fix (G10) — tiny, parallelizable
- P21: `curator/manifest.py` + `tests/test_manifest.py` (G3, dependency-free)
- P22: `curator/intent.py` + `prompts/intent.md` + `tests/test_intent.py` (G1)
- P23: `curator/synthesizer.py` + `prompts/synthesizer.md` + `tests/test_synthesizer.py` (G2) — depends on P21 (Manifest import)
- P24: `curator/case_engine.merge_capability_map` + `tests/test_merge_capability_map.py` (G9-helper)
- P25: `curator/orchestrator.py` intent wiring + test expansion (G9) — depends on P22, P24
- P26: `curator/synthesize.py` CLI + `tests/test_synthesize_cli.py` (G4) — depends on P22, P23, P21
- P27: `curator/server.py` sidecar route (G3-continuation) — can parallelize with P26
- P28: `compose/curator.Dockerfile` + `compose/host-nginx.Dockerfile` + `compose/docker-compose.yml` (G7, G8)
- P29: `bl-agent/bl-pull` SHA-256 verify + shell smoke (G5) — depends on P27 **and** §5.8 sidecar-first fetch-order contract
- P30: `bl-agent/bl-apply` parse+install+configtest + shell smoke (G6) — depends on P29 for integration test
- P31: Day-4 live smoke + 22:00 CT GATE
- P32: Sentinel review + fix commits

~12 phases. Parallelism opportunities: {P20, P21, P22, P24} in batch 1; {P23, P25, P27} in batch 2; {P26, P28} in batch 3; P29 → P30 serial; P31 → P32 serial.

