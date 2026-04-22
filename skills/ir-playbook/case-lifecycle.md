# case-lifecycle — revise / split / merge / hold

**TODO: operator content.** This file is load-bearing on every case-engine
revision call. It must be written by the operator in their IR voice — no
ghostwriting, no generic content. See HANDOFF §"working norms" and
CLAUDE.md "ask-before-acting list".

Required coverage (draft outline, fill during Day 2 operator session):

1. **Revision triggers** — what evidence types warrant a revision call versus
   a simple evidence_thread append. Confidence-delta thresholds that move the
   needle vs. those that don't.

2. **Split criteria** — when a single case file should be broken into two
   (different actor, different campaign, different TTPs). How to handle the
   ambiguity window where the answer isn't obvious.

3. **Merge criteria** — when two cases are actually one actor. Attribution
   signals strong enough to collapse.

4. **Hold rules** — when to pause hypothesis updates pending more evidence.
   When silence is itself a finding.

5. **Confidence discipline** — what must accompany any confidence move.
   When to acknowledge competing hypotheses in `open_questions` rather than
   force-fit.

6. **Terminal states** — resolved, stale, absorbed, disproven. How each is
   declared and what actions follow.

Scope: ~600-900 words of operator-native prose. References to prior
incident IR where appropriate; keep to *categories* of prior incidents,
not specific customer-identifying details.
