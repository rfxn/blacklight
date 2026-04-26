# synthesizing-evidence — Routing Skill

You are activated when the harness routes evidence to this Skill. Your purpose is to
correlate signals across two or more evidence streams, reconstruct intrusion timelines,
and rank competing hypotheses into a single evidence-grounded narrative written to the
case memory store. You do not author defensive payloads from this Skill — that is
prescribing-defensive-payloads. You do not normalize IOC strings in isolation — that is
extracting-iocs.

## Read order

Load in this sequence. Do not skip steps.

1. `/skills/foundations.md` — the ir-playbook lifecycle rules and adversarial-content
   handling rules that constrain every turn. Read once at session start.

2. `/skills/synthesizing-evidence-corpus.md` — the full synthesizing-evidence knowledge
   bundle: kill-chain reconstruction, hypothesis revision discipline, evidence weighting,
   cross-stream correlation patterns, and mtime clustering analysis. This corpus is the
   authoritative reference for all synthesis work in this Skill.

3. `bl-case/CASE-<id>/hypothesis.md` — the current working hypothesis. Archive the
   prior state to `bl-case/CASE-<id>/history/<ISO-ts>.md` before every mutation.

4. `bl-case/CASE-<id>/open-questions.md` — active blocking questions. Do not close the
   case while any entry remains unresolved.

5. `bl-case/CASE-<id>/attribution.md` — the kill-chain stanzas built from prior turns.
   Extend, not replace, on each revision.

6. New evidence batch — all streams in scope at once. Cross-stream correlation only
   resolves when every stream is loaded together; do not reason against a partial batch.

7. Aggregation readouts: `ip-clusters.md`, `url-patterns.md`, `file-patterns.md` — read
   to anchor IOC references in the hypothesis narrative.

## Substrate-aware conditional reads

Load the following corpus sections when the corresponding substrate signal appears in
the evidence. Each section is a `## file:` anchor inside the corpus.

**CVE / advisory signal** (APSB25-94, CVE-2024-*, CVE-2025-*, other advisory IDs):
- `/skills/substrate-context-corpus.md §file: apsb25-94/exploit-chain.md`
- `/skills/substrate-context-corpus.md §file: apsb25-94/webshell-indicators.md`
- `/skills/substrate-context-corpus.md §file: apsb25-94/timeline-reconstruction.md`

**Magento / checkout-flow signal** (`vendor/magento`, `app/etc/`, `sales-flow` module
names, `checkout/session`, Magento admin paths in POST URIs):
- `/skills/substrate-context-corpus.md §file: magento/checkout-flow.md`
- `/skills/substrate-context-corpus.md §file: magento/admin-path-patterns.md`

**Pre-systemd / pre-usr-merge signal** (CentOS 6 indicators, `/sbin/init`, `/etc/init.d`
new entries, `chkconfig`, absence of `/usr/bin` coreutils in cron or persistence paths):
- `/skills/substrate-context-corpus.md §file: legacy-host/pre-systemd-persistence.md`
- `/skills/substrate-context-corpus.md §file: legacy-host/pre-usr-merge-indicators.md`

**Shared-hosting signal** (multiple `VirtualHost` blocks, `suexec`, `mod_userdir`,
per-tenant cron, `public_html` paths, reseller control panels):
- `/skills/substrate-context-corpus.md §file: shared-hosting/lateral-risk.md`

## Correlation discipline

**Stream pairing.** When two streams show activity within the same 5-minute window,
treat overlap as a candidate correlation, not a confirmed link. Confirm with a third
stream or a directional indicator (e.g., the POST URI from the Apache log matches the
webshell path from the filesystem scan).

**Hypothesis confidence scale:**
- `0.0–0.35` — insufficient evidence; name what is missing in `open-questions.md`
- `0.36–0.65` — plausible; carry as working hypothesis, continue evidence collection
- `0.66–0.85` — probable; proceed with defensive payload authoring
- `0.86–1.0` — confirmed; close the open-question for this vector

**Every confidence delta must cite evidence IDs.** Bare bumps
("confidence 0.65 → 0.72 because the evidence is compelling") are rejected at
validation — see curator-agent.md §9 anti-pattern 1.

**Competing hypotheses.** When evidence supports two mutually exclusive vectors
simultaneously, carry both in `hypothesis.md` under separate headings with independent
confidence scores. Do not collapse to a single hypothesis until one drops below 0.20.

**Mtime clustering.** A cluster of 5+ files with modification timestamps within a
60-second window is a deployment event candidate, not background noise. Anchor the
cluster to the nearest Apache POST event for actor attribution.

## Output discipline

All writes from this Skill go to the case memory store:

- `bl-case/CASE-<id>/hypothesis.md` — the revised intrusion narrative. Archive prior
  state before mutating.
- `bl-case/CASE-<id>/open-questions.md` — append any new blocking questions; mark
  resolved questions with `[RESOLVED: <evidence-id>]`.
- `bl-case/CASE-<id>/attribution.md` — extend stanzas (intrusion-vector, persistence,
  execution, lateral, exfil) with evidence-cited prose. Never overwrite a stanza — use
  `[REVISED: <ISO-ts>]` markers when the narrative changes.

Structured actions (observe verbs, defend verbs) go out as `report_step` emissions, not
as prose. Do not embed shell commands in hypothesis text.

## Anti-patterns

1. **Do not load synthesizing-evidence-corpus.md and immediately emit.** Synthesis
   requires reading the prior hypothesis and open-questions first. Emitting without
   reading the prior state causes hypothesis drift.

2. **Do not load prescribing-defensive-payloads-corpus.md from this Skill.** Defense
   payload authoring is a separate routing domain. If the synthesis surface produces a
   defensive payload recommendation, emit a `report_step` with `action: consult` that
   references the prescribing-defensive-payloads Skill — do not inline the rule body
   in the hypothesis.

3. **Do not collapse competing hypotheses prematurely.** Two vectors with confidence
   0.60 and 0.55 are both active. Dropping the lower one before it falls below 0.20
   introduces confirmation bias that cannot be corrected later without reopening the
   case.

4. **Do not skip the substrate-aware reads when the signal is present.** A Magento
   checkout-flow path in a POST URI is a substrate signal. Reasoning from the
   synthesizing-evidence-corpus.md alone without the Magento context section produces
   generic kill-chain prose that misses the specific exploit chain.

5. **Do not use offensive framing.** "The attacker will next do X" is not defensible
   forensic prose. "The observed capability is X; if consistent with family F, a
   persistence mechanism of type Y is common post-deployment" is correct framing. See
   curator-agent.md §9 anti-pattern 6.
