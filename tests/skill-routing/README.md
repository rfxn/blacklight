# tests/skill-routing/

Routing-Skills coverage tests and live promotion eval gate.

## Files

- `smoke.bats` — Structural tests. Runs in `make -C tests test-quick`. 12 tests
  covering: 6-Skill directory count, description.txt size cap (≤1024 bytes), SKILL.md
  body cap (≤500 lines, warn-only), 4-block description format, body-to-corpus path
  resolution, vocabulary purity (no `bl-skills/` refs), foundations.md presence check,
  skills-corpus drift guard, and two prompt-content regression assertions for
  curator-agent.md §3 / §9 (deferred from P9).

- `eval-runner.bats` — Live promotion eval (added in M13 P11). Gated on
  `BL_EVAL_LIVE=1`. 13 tests covering: fixture count, per-Skill precision,
  cross-Skill recall, distractor specificity, and final report emission.

- `eval-cases/` — 50 case fixtures (added in P11): 30 mainline / 15 distractor /
  5 ambiguous.

## Running the structural tests

```bash
# Dev-mode quick pass (includes skill-routing/smoke.bats):
make -C tests test-quick

# Direct bats run (local, without Docker):
bats tests/skill-routing/smoke.bats

# Standalone target:
make -C tests test-skill-routing-smoke
```

## Running the live eval

The eval runner exercises the live Anthropic Sessions API. It is never run in
default CI (`test` / `test-quick` / `test-rocky9`). Run it manually:

```bash
# Full 50-case eval (requires ANTHROPIC_API_KEY):
BL_EVAL_LIVE=1 ANTHROPIC_API_KEY=sk-ant-... make -C tests test-skill-routing-eval

# Direct bats invocation (local, without Docker):
BL_EVAL_LIVE=1 ANTHROPIC_API_KEY=sk-ant-... bats tests/skill-routing/eval-runner.bats

# Targeted subset — one Skill only:
BL_EVAL_LIVE=1 BL_EVAL_FILTER=synthesizing-evidence \
    ANTHROPIC_API_KEY=sk-ant-... bats tests/skill-routing/eval-runner.bats

# Via bl verb (reads metrics from BL_EVAL_REPORT_FILE after runner exits):
BL_EVAL_LIVE=1 ANTHROPIC_API_KEY=sk-ant-... bl setup --eval

# Eval + promote (gates --promote on promotion_pass: true):
BL_EVAL_LIVE=1 ANTHROPIC_API_KEY=sk-ant-... bl setup --eval --promote
```

When `BL_EVAL_LIVE` is unset (the default), every test in eval-runner.bats
skips cleanly and bats exits 0. This is the expected CI behaviour.

## Cost estimate

A full 50-case eval invokes one curator session per fixture. Each session
uses the Managed Agents API with Opus 4.7 (adaptive thinking). Rough estimate:

| Fixture type | Count | Avg turns | Cost/session |
|---|---|---|---|
| Mainline | 30 | 2-3 | ~$0.05-0.15 |
| Distractor | 15 | 1-2 | ~$0.03-0.08 |
| Ambiguous | 5 | 2-3 | ~$0.05-0.15 |

Total estimate: **$2–6 USD per full eval run** depending on evidence complexity
and adaptive-thinking token depth. Run targeted subsets (`BL_EVAL_FILTER=<skill>`)
during Skill iteration to reduce cost to ~$0.25-0.75 per Skill.

Wall-clock estimate: ~25-35 minutes for 50 fixtures at ~30-60s per session.
The `test-skill-routing-eval` target has no built-in timeout — run it in a
screen/tmux session for remote operator use.

## Fixture schema

### Mainline fixture (`eval-cases/mainline/<skill>-<n>.json`)

```json
{
    "case_id": "EVAL-mainline-synthesizing-1",
    "evidence_summary": "<concise prose: signals visible to curator on this turn>",
    "expected_skill": "synthesizing-evidence",
    "expected_resource_reads": ["/skills/synthesizing-evidence-corpus.md"],
    "min_correlation_streams": 2
}
```

Required: `case_id`, `evidence_summary`, `expected_skill`.
`expected_skill` must match one of the 6 routing Skill names exactly.

### Distractor fixture (`eval-cases/distractor/<slug>.json`)

```json
{
    "case_id": "EVAL-distractor-1",
    "evidence_summary": "<looks like Skill X but actually needs Skill Y>",
    "expected_no_skill": "synthesizing-evidence",
    "rationale": "evidence is single-stream; no correlation needed"
}
```

Required: `case_id`, `evidence_summary`, `expected_no_skill`.
`expected_no_skill` is the Skill that must NOT fire on this evidence.
`rationale` is required for human review but not validated by the runner.

### Ambiguous fixture (`eval-cases/ambiguous/<slug>.json`)

```json
{
    "case_id": "EVAL-ambiguous-1",
    "evidence_summary": "<could plausibly route to either A or B>",
    "candidate_skills": ["extracting-iocs", "synthesizing-evidence"],
    "rationale": "single-stream IOC list with weak correlation hints"
}
```

Required: `case_id`, `evidence_summary`, `candidate_skills` (array, ≥2 entries).
Ambiguous fixtures are tracked but never fail the eval — they are informational.

## Promotion bar (per spec §11 G11)

| Metric | Bar |
|--------|-----|
| Per-Skill precision | ≥0.85 (85%) |
| Cross-Skill recall | ≥0.75 (75%) |
| Distractor specificity | ≥0.95 (95%) |

All three bars must be met for `promotion_pass: true` in the report JSON.

### Bar-pass worked example

Assume results after a 50-case eval:

| Metric | Result | Bar | Pass? |
|---|---|---|---|
| synthesizing-evidence precision | 5/5 = 100% | ≥85% | yes |
| prescribing-defensive-payloads precision | 4/5 = 80% | ≥85% | **no** |
| curating-cases precision | 5/5 = 100% | ≥85% | yes |
| gating-false-positives precision | 5/5 = 100% | ≥85% | yes |
| extracting-iocs precision | 4/5 = 80% | ≥85% | **no** |
| authoring-incident-briefs precision | 5/5 = 100% | ≥85% | yes |
| cross-Skill recall | 28/30 = 93% | ≥75% | yes |
| distractor specificity | 14/15 = 93% | ≥95% | **no** |

Result: `promotion_pass: false`. `below_bar` would contain:
- `per_skill_precision[prescribing-defensive-payloads]=80% (bar 85%)`
- `per_skill_precision[extracting-iocs]=80% (bar 85%)`
- `distractor_specificity=93% (bar 95%)`

The report JSON (`BL_EVAL_REPORT_FILE`) is written by the final test in
eval-runner.bats and read by `bl_setup_eval` after bats exits.

## Adding a case fixture

1. Author a JSON envelope under `eval-cases/{mainline,distractor,ambiguous}/<slug>.json`
2. Use the schema above. Required fields: `case_id`, `evidence_summary`, and
   `expected_skill` (mainline) or `expected_no_skill` (distractor) or
   `candidate_skills` (ambiguous).
3. For mainline: name the file `<skill>-<n>.json` where `<skill>` matches the
   Skill directory name exactly (e.g., `synthesizing-evidence-6.json`).
4. Validate the fixture parses: `jq -e '.case_id' eval-cases/mainline/<file>.json`
5. Run locally to verify before committing:
   `BL_EVAL_LIVE=1 BL_EVAL_FILTER=<skill> ANTHROPIC_API_KEY=... bats tests/skill-routing/eval-runner.bats`
6. Include at least one cross-Skill disambiguation case per new fixture pair — a
   distractor that shares surface features with the Skill it is not attributed to.

Data-source rule: fixtures must reconstruct cleanly from the public APSB25-94 advisory.
No customer hostnames, internal paths, or non-public IOCs. Operator-local material
(`/home/sigforge/var/ioc/polyshell_out/`) is shape-check only — never copy into fixtures.

## Skill identity (Path C vocabulary)

The 6 routing Skills are:

| Skill | Trigger | Corpus |
|-------|---------|--------|
| `synthesizing-evidence` | Cross-stream correlation, timeline reconstruction | `skills-corpus/synthesizing-evidence-corpus.md` |
| `prescribing-defensive-payloads` | Rule/signature authoring | `skills-corpus/prescribing-defensive-payloads-corpus.md` |
| `curating-cases` | Case lifecycle, INDEX, agentic-minutes | `skills-corpus/curating-cases-corpus.md` |
| `gating-false-positives` | Alert adjudication, FP suppression | `skills-corpus/gating-false-positives-corpus.md` |
| `extracting-iocs` | IOC normalization, clustering | `skills-corpus/extracting-iocs-corpus.md` |
| `authoring-incident-briefs` | Close-out brief, tenant communication | `skills-corpus/authoring-incident-briefs-corpus.md` |

All Skills cite `/skills/foundations.md` in their read order. The `synthesizing-evidence`
and `prescribing-defensive-payloads` Skills additionally cite
`/skills/substrate-context-corpus.md` for CVE/Magento/pre-systemd conditional reads.

## Operator workflow: post-eval Skill iteration

When a Skill falls below the precision bar:

1. Review the misses in the runner output (test 9 logs each miss with the
   fixture filename and the Skill that fired instead).
2. Update the Skill's `description.txt` to sharpen the trigger conditions.
3. Update the Skill's `SKILL.md` to improve disambiguation guidance if needed.
4. Run `make skills-corpus` to rebuild `skills-corpus/`.
5. Run `bl setup --sync` to upload the updated corpus and version-bump the Skill.
6. Re-run targeted eval: `BL_EVAL_LIVE=1 BL_EVAL_FILTER=<skill> ... bats eval-runner.bats`
7. Once all Skill bars are met, run full eval and promote:
   `BL_EVAL_LIVE=1 ... bl setup --eval --promote`
