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
  `BL_EVAL_LIVE=1`. 50 case fixtures covering per-Skill precision, cross-Skill recall,
  and distractor specificity.

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

## Promotion bar (per spec §11 G11)

| Metric | Bar |
|--------|-----|
| Per-Skill precision | ≥0.85 |
| Cross-Skill recall | ≥0.75 |
| Distractor specificity | ≥0.95 |

The promotion bar applies to the live eval (`eval-runner.bats`, P11). The structural
tests in `smoke.bats` have no precision metric — they are pass/fail structural checks.

## Adding a case fixture (P11+)

1. Author a JSON envelope under `eval-cases/{mainline,distractor,ambiguous}/<slug>.json`
2. Required fields: `case_id`, `evidence_summary`, `expected_skill` (or
   `expected_no_skill` for distractor cases)
3. Run `bl setup --eval` locally with `BL_EVAL_LIVE=1` to verify the fixture parses
4. Include at least one cross-Skill disambiguation case per new fixture pair — a
   distractor that shares surface features with the Skill it is not attributed to

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
