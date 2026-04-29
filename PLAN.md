# PLAN — M17 Managed Agents primitive correction

**Plan Version:** 3.0.6
**Source:** `PLAN-M17.md` (operator-local design doc, 2026-04-28)
**Predecessor:** v0.6.1 (`a425104` — post-hackathon collateral cleanup)
**Branch:** `m17` (feature branch; squash-merge to `main` on M17 close)
**Target:** v0.6.1 → v0.7.0 on M17 close (minor bump — primitive-architecture correction)
**Probe baseline:** 2026-04-28 API re-probe (`/tmp/bl-reprobe-1777405920.log`,
`/tmp/bl-reprobe2-*.log`, `/tmp/bl-skills-reprobe-*.log`); docs cross-check against
`platform.claude.com/docs/en/managed-agents/*`.

## Operator-confirmed decisions (2026-04-28)

- **Q1 — Skill version pinning:** `version: "latest"` in agent body (auto-pickup of
  skill version-bumps from P4). Deliberate trade against pin-explicit; operator
  accepts auto-rollout risk.
- **Q2 — Networking:** stays `unrestricted` for M17. Lockdown to `limited` is a
  separate hardening milestone (FUTURE #29 / #30).
- **Q3 — `foundations.md` handling:** option (a) — bundle a per-skill
  `foundations.md` Level-3 reference (each routing skill self-contained).
- **Q4 — `bl_setup_seed_skills_as_files` removal:** P8 (after live-API integration
  validates the native path); keep safety net through M17.
- **Q5 — Branch strategy:** feature branch `m17`, force-push permitted during
  active rebase; squash-merge to `main` on close.

## Phase Dependencies

- Phase 1: none
- Phase 2: [1]
- Phase 3: none
- Phase 4: [1, 3]
- Phase 5: [4]
- Phase 6: [5]
- Phase 7: [1, 6]
- Phase 8: [7]

---

### Phase 1: Beta-header centralization

**Status:** complete

**Mode:** serial-context

**Files:**
- Modify: `src/bl.d/20-api.sh`
- Modify: `src/bl.d/23-files.sh`
- Modify: `src/bl.d/84-setup.sh`
- Modify: `bl`

**Accept:**
- `BL_API_BETA_MA="managed-agents-2026-04-01"`,
  `BL_API_BETA_FILES="files-api-2025-04-14"`, and
  `BL_API_BETA_SKILLS="skills-2025-10-02,code-execution-2025-08-25,files-api-2025-04-14"`
  declared near top of `src/bl.d/20-api.sh`.
- `bl_api_call` accepts optional fourth arg `beta_header`; default
  `${4:-$BL_API_BETA_MA}`.
- `src/bl.d/23-files.sh:31` literal replaced with `"$BL_API_BETA_FILES,$BL_API_BETA_MA"`.
- `src/bl.d/84-setup.sh:392` (probe curl in `bl_setup_resolve_source`) replaced
  with `$BL_API_BETA_MA`.
- `grep -rn '"anthropic-beta:' src/bl.d/` returns zero hits.
- `make bl` regenerates without drift; `make bl-check` clean.

**Test:**
- `bash -n src/bl.d/20-api.sh src/bl.d/23-files.sh src/bl.d/84-setup.sh`
- `shellcheck src/bl.d/20-api.sh src/bl.d/23-files.sh src/bl.d/84-setup.sh`
- `make -C tests test-quick`
- Existing `tests/03-models.bats` and `tests/08-setup.bats` pass unchanged.

**Edge cases:**
- `bl_api_call` callers omitting the optional 4th arg fall back to
  `$BL_API_BETA_MA` (default preserved).

**Regression-case:** N/A — refactor — pure plumbing centralization with no
observable behavior change; existing `tests/03-models.bats` and
`tests/08-setup.bats` cover the affected `bl_api_call` surface.

---

### Phase 2: config.packages adoption + env recreation

**Status:** complete

**Mode:** serial-agent

**Files:**
- Modify: `src/bl.d/84-setup.sh`
- Modify: `prompts/curator-agent.md` (only if Phase 2.0 audit finds explicit
  deb-install prose; else no-op recorded in commit message)
- Modify: `tests/08-setup.bats`
- Modify: `bl`

**Accept:**
- Phase 2.0 audit completed: grep for `apt-get install`, `apt install`,
  `pip install`, `npm install` across `prompts/curator-agent.md`,
  `routing-skills/*/SKILL.md`, `skills/*/SKILL.md`, `skills-corpus/*.md`.
  Findings recorded inline in the commit message.
- `bl_setup_compose_env_body` emits `config.packages.apt` containing the
  canonical 9 packages: `apache2`, `libapache2-mod-security2`, `modsecurity-crs`,
  `yara`, `jq`, `zstd`, `duckdb`, `pandoc`, `weasyprint`. Names finalized after
  Phase 2.0 audit.
- `bl_setup_ensure_env` detects packages drift via jq-sorted set equality on
  `config.packages.apt`; on mismatch, creates a new env (renaming old to
  `bl-curator-env-archive-<id>` first) and updates `state.env_id`.
- `src/bl.d/84-setup.sh:974-982` comment block stating *"packages is NOT a valid
  field"* deleted.
- Networking remains `unrestricted` (Q2).
- `grep -n bl_setup_ensure_env src/bl.d/84-setup.sh` shows packages-drift branch
  present.

**Test:**
- `tests/08-setup.bats` extended with env-create-with-packages fixture; asserts
  request body shape includes `config.packages.apt` with canonical 9 names.
- `bash -n src/bl.d/84-setup.sh` and shellcheck clean.
- `make -C tests test-quick`.

**Edge cases:**
- Existing env's packages match canonical → reuse, no recreation.
- Existing env's packages drift → create new, archive old, update `state.env_id`.
- First-run no env → create new env organically (no archive step).
- Env name collision on archive rename → fall back to
  `bl-curator-env-pkgs` for the new env name.
- Old env has running sessions → archive is read-only per docs; sessions continue;
  new sessions land on new env.

**Regression-case:** `tests/08-setup.bats::@test "env body emits config.packages.apt with canonical list"`

---

### Phase 3: Routing-skills frontmatter + foundations bundle

**Status:** complete

**Mode:** serial-agent

**Files:**
- Modify: `routing-skills/synthesizing-evidence/SKILL.md`
- Modify: `routing-skills/prescribing-defensive-payloads/SKILL.md`
- Modify: `routing-skills/curating-cases/SKILL.md`
- Modify: `routing-skills/gating-false-positives/SKILL.md`
- Modify: `routing-skills/extracting-iocs/SKILL.md`
- Modify: `routing-skills/authoring-incident-briefs/SKILL.md`
- Create: `routing-skills/synthesizing-evidence/foundations.md`
- Create: `routing-skills/prescribing-defensive-payloads/foundations.md`
- Create: `routing-skills/curating-cases/foundations.md`
- Create: `routing-skills/gating-false-positives/foundations.md`
- Create: `routing-skills/extracting-iocs/foundations.md`
- Create: `routing-skills/authoring-incident-briefs/foundations.md`
- Modify: `tests/08-setup.bats`

**Accept:**
- Each `SKILL.md` has YAML frontmatter at top:
  - `name` matches the directory name (gerund form; ≤64 chars; lowercase + digits
    + hyphens; no `anthropic`/`claude` reserved substrings).
  - `description` ≤1024 chars; non-empty; no XML tags; leads with action verb;
    closes with "Use when …" trigger.
- The 6 descriptions follow the drafts in `PLAN-M17.md §3 P3.1` (re-typed in
  this commit; do not externally reference the operator-local plan).
- `# <name> — Routing Skill` heading line removed; foundations reference
  rewritten to use option (a) — `See [foundations.md](foundations.md) for IR-playbook
  lifecycle rules`.
- Each `routing-skills/<name>/foundations.md` exists; content is a copy of the
  shared IR-playbook foundations material adapted per skill.
- Body ≤500 lines per file (`wc -l routing-skills/*/SKILL.md` confirms).
- Pairwise distinctiveness: manual review confirms 6 descriptions are not
  paraphrases of each other.

**Test:**
- `awk 'NR==1,/^---$/' routing-skills/*/SKILL.md` extracts 6 valid frontmatter
  blocks.
- `python3 -c 'import yaml,sys; [yaml.safe_load(open(f).read().split("---")[1]) for f in sys.argv[1:]]' routing-skills/*/SKILL.md`
  parses each frontmatter cleanly.
- `tests/08-setup.bats` extended with frontmatter-validation test asserting
  shape per file.
- `make -C tests test-quick`.

**Edge cases:**
- `description` >1024 chars caught by the test.
- Reserved substring (`anthropic`/`claude`) in `name` caught.
- Missing frontmatter caught.

**Regression-case:** `tests/08-setup.bats::@test "routing-skills SKILL.md files have valid YAML frontmatter"`

---

### Phase 4: bl_setup_seed_skills_native + multipart helper

**Status:** complete

**Mode:** serial-agent

**Files:**
- Modify: `src/bl.d/20-api.sh`
- Modify: `src/bl.d/84-setup.sh`
- Create: `tests/16-skills-native.bats`
- Create: `tests/helpers/skills-mock.bash`
- Create: `tests/fixtures/skills-create-success.json`
- Create: `tests/fixtures/skills-version-bump-success.json`
- Create: `tests/fixtures/skills-list-empty.json`
- Modify: `bl`

**Accept:**
- New `bl_api_call_multipart <method> <url-suffix> <files-array> [beta-header]`
  in `src/bl.d/20-api.sh`. Single curl invocation; 1 retry on 5xx; otherwise
  surfaces error. Accepts array entries of form `<field>=@<file>` or
  `<field>=@<file>;filename=<override>`.
- `bl_api_call_multipart` keeps `bl_api_call` JSON-only — no signature change to
  the existing function beyond P1's optional 4th arg.
- New `bl_setup_seed_skills_native(<mode>, <rs-dir>)` in `src/bl.d/84-setup.sh`.
- `bl_setup_seed_skills` dispatcher routed to call `_native` (the `_as_files`
  branch retained but unreachable; removed in P8).
- For each `routing-skills/<name>/`:
  - Compute `sha256` of `SKILL.md + bundled files` (sorted by path).
  - If `state.skills.<name>.sha256` matches → skip ("no change").
  - If `state.skills.<name>.id` set → `POST /v1/skills/<id>/versions` with
    multipart zipped bundle; parse `version`; update
    `state.skills.<name>.{version, sha256}`.
  - Else → `POST /v1/skills` with multipart zipped bundle; parse
    `{id, latest_version}`; set `state.skills.<name>.{id, version, sha256}`.
- Zip construction under `BL_TMP_DIR` via `zip -r`; root entry is `<name>/SKILL.md`.
- `mode = dry-run` logs intent without API calls.
- State.json key shape: `state.skills.<name>.{id, version, sha256}`.

**Test:**
- `tests/16-skills-native.bats` covers: happy-path create, sha256 idempotency,
  version-bump on content change, missing-id branch, existing-id branch,
  dry-run mode.
- `tests/helpers/skills-mock.bash` shims `curl` against
  `tests/fixtures/skills-*.json` (extends existing curator-mock pattern; no
  parallel mock infra).
- `bash -n` and shellcheck clean on `src/bl.d/20-api.sh` and
  `src/bl.d/84-setup.sh`.
- `make -C tests test-quick`.

**Edge cases:**
- `state.skills.<name>` null/missing on first run → create-new path (explicit
  `[[ -z "$existing_id" ]]` check).
- `sha256` unchanged across re-run → skip.
- Skills API 5xx during version-bump → 1 retry, then surface to operator with
  `bl setup --apply` retry guidance.
- Multipart upload interrupted mid-upload → orphan version cleanable via P6 gc.

**Regression-case:** `tests/16-skills-native.bats::@test "bl_setup_seed_skills_native: idempotent re-run produces no API writes"`

---

### Phase 5: agent.skills:[] + pdf attach + curator-agent.md prose trim

**Status:** complete

**Mode:** serial-agent

**Files:**
- Modify: `src/bl.d/84-setup.sh`
- Modify: `prompts/curator-agent.md`
- Modify: `tests/08-setup.bats`
- Modify: `bl`

**Accept:**
- `bl_setup_compose_agent_body` emits a `skills:[]` array containing the 6
  custom routing-skill entries plus `{type:"anthropic", skill_id:"pdf"}`. Each
  custom entry uses `version: "latest"` (Q1 — auto-pickup of P4 version bumps).
- Agent body no longer carries `resources:[]` referencing the old workspace
  skill files.
- `bl_setup_ensure_agent` compares `state.agent.skill_versions` to the live
  agent's skills array; on drift, CAS-bumps agent version using the existing
  pattern.
- `prompts/curator-agent.md`: path-naming routing prose stripped. Replaced with
  a single line — *"Six routing skills are mounted on this agent
  (synthesizing-evidence, prescribing-defensive-payloads, curating-cases,
  gating-false-positives, extracting-iocs, authoring-incident-briefs) plus the
  pdf rendering skill. Anthropic's harness will route the relevant skill based
  on case context."* — followed by a 1-line under-routing fallback: *"If no
  skill is routed for a case action, follow the case's hypothesis state
  directly."*
- `wc -l prompts/curator-agent.md` decreases by 30-60 lines vs. baseline
  (recorded in commit message).

**Test:**
- `tests/08-setup.bats` extended: agent-body fixture asserts `skills:[]` shape
  contains 6 custom entries (each with `version: "latest"`) plus pdf, and no
  `resources:[]` referencing old skill files.
- `bash -n` and shellcheck clean on `src/bl.d/84-setup.sh`.
- `make -C tests test-quick`.

**Edge cases:**
- `state.skills.<name>.id` missing on first compose (P4 not yet run) → block
  with operator message instructing to run P4 (`bl setup --apply`) first.
- Agent already exists with different skill set → CAS-bump path.
- A bad skill upload propagates immediately to all sessions via `version:
  "latest"` (operator-accepted Q1 trade).

**Regression-case:** `tests/08-setup.bats::@test "agent body emits skills:[] array with 6 routing skills + pdf"`

---

### Phase 6: skills-gc — orphan archive + old workspace files

**Status:** complete

**Mode:** serial-agent

**Files:**
- Modify: `src/bl.d/84-setup.sh`
- Modify: `tests/08-setup.bats`
- Modify: `bl`

**Accept:**
- New `bl_setup_skills_gc(<mode>)` (mode: `dry-run` | `apply`):
  - `GET /v1/skills`; filter `display_title` ∈ {`case-lifecycle`, `polyshell`,
    `modsec-patterns`} (the 3 v1 orphans from 2026-04-23).
  - For each match: list versions → `DELETE /v1/skills/<id>/versions/<v>` per
    version → `DELETE /v1/skills/<id>`.
  - `GET /v1/files` filtered by `scope.type == "workspace"` AND filename
    matching `<routing-skill-name>-skill.md` for any of the 6 routing-skill
    names; `DELETE /v1/files/<id>` per match.
- Wired into `bl setup --gc` verb dispatch only — NOT auto-run during
  `bl setup --sync` or `--apply`.
- `dry-run` logs the planned delete sequence without executing.

**Test:**
- `tests/08-setup.bats` extended: gc mocks for list-skills and list-files;
  asserts the exact delete sequence (versions before skills; files before
  exit).
- `bash -n` and shellcheck clean on `src/bl.d/84-setup.sh`.
- `make -C tests test-quick`.

**Edge cases:**
- No orphans found → no-op clean exit.
- Version-delete fails on one orphan → surface error, do not skip its skill-delete
  (cascade order is mandatory per the 2026-04-28 probe: skill-delete with
  versions present returns 400).
- Workspace file referenced by some still-attached agent → out of scope; P6
  only removes files matching the routing-skill-name pattern (operator owns
  any non-matching cleanup).

**Regression-case:** `tests/08-setup.bats::@test "bl_setup_skills_gc cascades version-delete then skill-delete on v1 orphans"`

---

### Phase 7: cross-cutting test parity + Dockerfile zip sanity

**Status:** complete

**Mode:** serial-agent

**Files:**
- Modify: `tests/01-cli-surface.bats`
- Modify: `tests/03-models.bats`
- Modify: `tests/Dockerfile`
- Modify: `tests/Dockerfile.rocky9`

**Accept:**
- `tests/01-cli-surface.bats` asserts `bl setup --gc` verb dispatches without
  help-text drift (P6 added the verb).
- `tests/03-models.bats` adds beta-header centralization sanity assertion
  (P1's `BL_API_BETA_*` constants exist; no hardcoded `anthropic-beta:` literal
  remains).
- `tests/Dockerfile` and `tests/Dockerfile.rocky9` carry an explicit
  `command -v zip` sanity assertion (P4 depends on `zip` being available in
  the test container).

**Test:**
- `make -C tests test-quick`.
- `make -C tests test` (Debian 12).
- `make -C tests test-rocky9`.

**Tests-may-touch:** `tests/fixtures/*.json`, `tests/helpers/*.bash`

**Edge cases:**
- `zip` unavailable in the container caught by sanity assertion before P4
  tests run.

**Regression-case:** N/A — refactor — phase adds cross-cutting test parity with
no production source change; per-phase regression tests already covered in P2-P6.

---

### Phase 8: live-mode integration + ANTHROPIC-API-NOTES rewrite + Path C dead-code removal

**Status:** complete

**Mode:** serial-agent

**Files:**
- Modify: `tests/live/setup-live.bats`
- Modify: `ANTHROPIC-API-NOTES.md`
- Modify: `src/bl.d/84-setup.sh`
- Modify: `bl`

**Accept:**
- `tests/live/setup-live.bats` extended (gated by `BL_LIVE=1` +
  `ANTHROPIC_API_KEY`, existing pattern):
  - Asserts the live env has `config.packages` populated and matches the
    canonical 9-name list.
  - Asserts the live agent has `skills:[]` with 6 custom routing-skill IDs +
    pdf.
  - Asserts each routing-skill `display_title` matches the expected name.
  - Runs a fixture case through the curator; asserts skill-invocation events
    in `BL_CURL_TRACE_LOG` match the expected verb→skill mapping (6 case
    prompts, one per routing skill).
- `ANTHROPIC-API-NOTES.md` rewrite, preserving historical record:
  - §1 (Environments — packages): RESOLVED 2026-04-28 with canonical accepted
    shape; "Re-probe 2026-04-28" subsection added.
  - §2 (Skills allowlist): rewritten. Original 404 attributed to wrong
    beta-header self-inflicted gap, NOT Anthropic-side allowlist. Document
    canonical beta-header trio
    (`skills-2025-10-02,code-execution-2025-08-25,files-api-2025-04-14`).
    Original `OPTIONS Allow: POST` retained as historical record.
  - §6 (`?name=` filter): re-probe note — Anthropic now returns 400 with
    `unexpected query parameter: name` (improved diagnostic).
  - New §11: research-preview-only features blacklight does NOT yet leverage
    (cache_control, thinking — Messages-API-only per current docs; not exposed
    via Managed Agents).
- `bl_setup_seed_skills_as_files` function deleted entirely from
  `src/bl.d/84-setup.sh` (now-dead after P5).
- `grep -n bl_setup_seed_skills_as_files src/bl.d/` returns zero hits.
- `make bl` regenerates without drift.

**Test:**
- `BL_LIVE=1 make -C tests test-live` passes.
- `make -C tests test` (Debian 12) and `make -C tests test-rocky9` pass.
- `bash -n src/bl.d/84-setup.sh` and shellcheck clean.

**Edge cases:**
- Live API 5xx during one of the 6 verb-class case prompts → test surfaces the
  failed verb (does not bail on first failure).
- Description-router under-routes one verb → test surfaces the miss; mitigation
  is to tighten that skill's description in a follow-on commit (not blocking
  for M17 merge, but logged as MUST-FIX before v0.7.0 tag).
- Live test cost is real (~$-cents per run) → scenario count capped at 5;
  gated by `BL_LIVE=1`.

**Regression-case:** `tests/live/setup-live.bats::@test "M17 live integration: env packages + agent skills + verb routing"`

---

## Outcome on M17 close

- `bl-curator-env` has 9 deb packages baked in; no per-session `apt-get install`
  latency.
- 6 routing skills are first-class Skills resources in the org workspace;
  queryable, versionable, auditable.
- Curator agent has `skills:[…7 items…]` (6 custom + pdf) with
  `version: "latest"` (Q1).
- `prompts/curator-agent.md` is 30-60 lines shorter; selection is platform-routed.
- `ANTHROPIC-API-NOTES.md §1, §2, §6` updated; §11 added.
- Workspace listings show 6 routing skills + 4 Anthropic pre-built; zero v1
  orphans.
- Beta-header strings centralized; future re-probes mutate one constant per
  beta family.
- `bl_setup_seed_skills_as_files` removed (Path C dead-code gone).
- Single VERSION bump on M17 close: `0.6.1` → `0.7.0` (squash-merge from `m17`
  to `main`).
