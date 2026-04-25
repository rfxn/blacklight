# agentic-minutes-playbook — advisory-driven detection emit

Loaded when the curator session opens with `bl consult --sweep-mode --cve <id>` (DESIGN.md §5.2 retrospective posture) or `bl consult --new --trigger <advisory-pub-event>`. The bundle is the operator playbook for the inverted incident-response shape — read advisory, emit detection, gate-check, deploy ahead of any local fire.

---

## The shape this bundle is built for

APSB25-94 publishes 2025-10-14 at 10:00 EDT. By 12:45 EDT the curator has read the Adobe advisory, identified the IOC class (`POST` to `/rest/V1/<endpoint>` with the body shape Adobe describes), authored a ModSec rule against `defense-synthesis/modsec-patterns.md` grammar, run it through the FP-gate, paired it with a single-command rollback, and queued a `defend.modsec` step in `bl-case/CASE-<id>/actions/pending/`. T+0:00 to T+2:45. Operator reviews the diff and signs off.

The classic shape — wait for an alert, triage, draft, deploy — runs at log-grep speed. SOAR and SIEM both inherit that shape; their gate logic assumes a local fire as the trigger. The advisory-driven shape is structurally different: the trigger is a public publication, not a local match. The FP-gate is load-bearing here because no local true-positive exists yet.

---

## Routing within this bundle

```
IF session has --sweep-mode --cve <id>
   OR --new --trigger names a published advisory
  → load advisory-to-detection-flow.md
  AND pre-alert-deployment.md
```

The flow names the six stages; the gate names the refusal condition.

---

## Cross-references

- `advisory-to-detection-flow.md` — six-stage flow, IOC-class taxonomy, rollback envelope.
- `pre-alert-deployment.md` — four-axis gate (advisory-confidence × FP-gate × rollback × blast-radius).
- `apsb25-94/exploit-chain.md`, `apsb25-94/indicators.md` — worked example from the Adobe APSB25-94 page.
- `defense-synthesis/modsec-patterns.md`, `firewall-rules.md`, `sig-injection.md` — emit grammars.
- `ir-playbook/case-lifecycle.md` §Calibrated confidence and `false-positives/assessment-discipline.md` — parent disciplines.
- Bundle 1's `enumeration-before-action.md` — substrate-read that prevents the failure mode below.

---

## Failure mode

Curator authors a ModSec rule against APSB25-94's IOC class and queues a `defend.modsec` step against a host whose substrate is nginx — no ModSec to load the rule into. Substrate-read should have caught this at enumeration before the synthesis call ran. The flow file ties substrate check to routing decision.

<!-- public-source authored — extend with operator-specific addenda below -->
