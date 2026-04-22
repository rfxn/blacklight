# case-lifecycle — revise / split / merge / hold

Loaded verbatim on every `case_engine.revise()` call. Complements `prompts/case-engine.md` — the prompt covers call shape and the seven reasoning rules; this file covers lifecycle states, confidence discipline, and the anti-patterns that recur across revision calls.

## Status transitions

`CaseFile.status` is one of four values. Transitions are write-time decisions — the revision call does not mutate status on its own, but its output must be coherent with a status the operator can justify.

**active** — the default. Evidence is still landing; hypothesis is still moving. A case stays active as long as new `EvidenceRow` entries are arriving or open questions remain unresolved.

**resolved** — hypothesis has stabilized, no open questions remain, and the last evidence arrival was `support_type=supports` with no confidence delta. An active case moves to resolved only after a deliberate operator decision — a `supports` revision does not auto-resolve.

**merged** — this case's evidence threads have been absorbed into another case. `merged_from` on the absorbing case names this one. A merged case is read-only — no further revision calls against it.

**split** — this case's evidence threads have been partitioned into two or more new cases. `split_into` names the successors. The original case is read-only.

Revision output does not emit `status=resolved|merged|split` — those are operator moves. The revision call signals split/merge intent through `support_type` + `open_questions_additions` (see §Case splits and merges).

## The five support types

Each `SupportType` defines the relationship between the new evidence batch and the prior `hypothesis.current`. Pick exactly one per call.

**supports** — new evidence corroborates the prior claim along an axis the prior hypothesis already named. Confidence may rise; magnitude governed by §Calibrated confidence. `new_hypothesis.reasoning` cites the new `EvidenceRow` ids and names the prior summary being reinforced.

**contradicts** — new evidence undermines a specific element of the prior reasoning. `revision_warranted` must be `true`. `new_hypothesis.reasoning` names the contradiction directly ("prior claimed X; new evidence shows Y"). Silent dismissal of contradicting evidence is the operator-integrity floor violation — never do it.

**extends** — new evidence adds a new host, a new capability rung, or a sharper detail without altering the core claim. `revision_warranted` is typically `true` and the summary becomes more precise. Confidence does not automatically move — `extends` is scope expansion, not confirmation.

**unrelated** — new evidence belongs to a different investigation. `revision_warranted=false`. Add an `open_questions_additions` entry noting a new case may be warranted. Do not try to force-fit the evidence.

**ambiguous** — insufficient signal to decide. `revision_warranted=false`. Add the specific question that would disambiguate to `open_questions_additions`. `ambiguous` is the correct answer when the answer isn't clear — it is not a failure mode.

## Calibrated confidence

Confidence is the model's own honest read, expressed as a float in `hypothesis.current.confidence`. The anchors below are rough calibration — reasoning about the evidence is mandatory, not the threshold.

- `0.3-0.4` — initial triage from a single host, single category of `EvidenceRow` (one hunter firing).
- `0.5-0.6` — cross-category corroboration on one host (two hunters converging on the same finding shape).
- `0.7` — cross-host corroboration on at least two hosts with a shared attribution signature (shared callback domain, matching payload structure, matching `observed_at` clustering).
- `0.8+` — same-host multi-vector plus at least three hosts matching, or a direct observation of the same capability exercising across the fleet.

Rules that bind every confidence move:

- **Cite what warrants the delta.** Every confidence change in `new_hypothesis.reasoning` names specific `EvidenceRow` ids.
- **Never raise confidence by more than 0.2 in a single revision.** A jump larger than that requires the operator to review — flag via `open_questions_additions`.
- **Confirmatory-only evidence does not justify crossing an anchor.** Three `supports` rows all of the same category stay at the same anchor — width of evidence, not depth, moves the needle.
- **Lowering confidence is a normal move.** A `contradicts` revision should usually lower confidence. A revision that only raises confidence is a tell the model isn't reasoning against the prior.

## Capability map discipline

`CapabilityMap` has three lists. Each list answers a different question. Do not conflate them.

**observed** — the capability has been exercised and that exercise is directly in evidence. Every entry cites `EvidenceRow` ids in its `evidence` list. Populate from evidence that shows the capability *firing*, not evidence that shows it *present*.

**inferred** — the capability is present in the artifact but has not been seen to fire. A webshell's decoded payload calling `curl` is an inferred outbound-callback capability until a log line shows the callback happened. Every entry cites a `basis` — the artifact or reasoning path that produced the inference.

**likely_next** — capabilities the model predicts will exercise based on the `observed` + `inferred` mix and the attribution signature. Every `LikelyNextAction` cites a `basis` tying back to an entry already in `observed` or `inferred`. A `likely_next` entry with no grounding is invented evidence — do not emit it.

Promotion rules:

- `inferred` → `observed` requires a distinct concrete `EvidenceRow` id that shows the capability firing. Changing the `basis` string is not promotion.
- `likely_next` never auto-promotes. If the prediction comes true, a new `EvidenceRow` lands, and the next revision call records `observed`.
- Do not duplicate: if a capability is already in `observed`, do not also emit it in `inferred`.

## Evidence threads are append-only

`evidence_threads[host]` is a per-host list of `EvidenceRow` ids. The list is append-only for the life of the case. A row is never removed — only superseded by a later row of higher confidence on the same category. Supersession is recorded in the new row's reasoning, not by editing the old row.

Cross-host attribution does not live in thread merging. Shared signature across hosts belongs in `CapabilityMap.observed[].evidence` (same capability id with evidence ids from multiple hosts) and in `hypothesis.current.summary` ("campaign pattern across host-2, host-4, host-7 sharing callback X"). Threads stay host-local.

`evidence_thread_additions` in the revision output may only reference ids present in the new-evidence batch — never invent ids, never re-add ids already in the thread.

## Evidence traceability

Every `EvidenceRow` in the batch carries an `id`, a `host`, a `hunter`, a `category`, a one-line `finding`, a `confidence`, a `source_refs` list, and an `observed_at` timestamp. The engine does not see `raw_evidence_excerpt` — that field is stripped before the summaries reach this prompt, on purpose.

Consequences:

- **Never reason about raw log content.** The prompt holds `finding` (one line, 200-char cap) and `source_refs` (paths + log line numbers). If the reasoning needs the raw excerpt, that's a signal the hunter's `finding` is underspecified — flag via `open_questions_additions`, do not hallucinate the excerpt.
- **`source_refs` is the citation lattice.** Entries look like `fs/var/www/html/a.php`, `logs/access.log#L4721`, or `cap/exec-via-include`. When `new_hypothesis.reasoning` ties a claim to an `EvidenceRow`, naming the id is sufficient; naming the `source_refs` entry is better when the claim is about a specific file or log line.
- **`observed_at` clustering is load-bearing.** Evidence rows from multiple hosts within a tight `observed_at` window are a strong attribution signal for campaign shape. Cite the window in `new_hypothesis.reasoning` when it's the basis for a split/merge or cross-host corroboration.

## Hypothesis history

Every revision that flips `revision_warranted=true` appends the prior `hypothesis.current` to `hypothesis.history` as a `HypothesisHistoryEntry` with a `trigger` string. The trigger names what caused the revision — typically the `EvidenceRow` id or a short label like `host-5-cross-correlation`. History is the record of what the model believed at each step and is grep-ready for demo walkthroughs.

Rules bound to history:

- **Never rewrite history.** A new revision call only appends. A prior summary that turned out to be wrong stays in history with its original confidence — the record of being wrong is how the case shows judgment.
- **Trigger must be specific.** `trigger="new evidence"` is useless. `trigger="CASE-2026-0007/host-5 timeline-hunter id-a7f3"` tells the operator which row broke the prior hypothesis.
- **If the current hypothesis stands, do not append.** `support_type=supports` with no summary change leaves history untouched.

## Open questions grammar

`open_questions_additions` is the channel for things the evidence raises but does not resolve. Every entry is one sentence, ending in a question mark, naming the specific disambiguating evidence the model would want next.

Good: "Does host-7's apache error log show the same callback pattern as host-2's, or is the shared signature coincidental?"

Bad: "Need more evidence." — a sentence, not a question. Bad: "Investigate host-7 further." — a directive, not a question.

`unrelated` and `ambiguous` verdicts must contribute at least one entry — they are the two `support_type` values where `revision_warranted=false` and the entry is the only signal the next call will have that this evidence was seen.

## Proposed actions

`proposed_actions` entries are structured — `{at, action, defense_id?, category?, reason}`. `at` is an ISO-8601 timestamp from the model's own clock; the engine validates and drops entries with non-parseable `at` values. `category` is one of `reactive`, `predictive`, `anticipatory` — leave null when the category isn't clear and let the operator classify.

Use sparingly. A proposed action is a request for an operator move — escalation, rule promotion, containment. Do not emit one for every revision. The bar: the evidence is concrete enough that a specific defensive action is warranted, and naming it in `proposed_actions` is more useful than leaving it implicit in the hypothesis summary.

## Case splits and merges

**Split** — one case's evidence resolves into two or more distinct investigations. Triggers: evidence shows two attribution signatures that were previously conflated (different callback infrastructure, different payload family, different `observed_at` cadence); or a new host's evidence shares no signature with the existing thread population. A split is a `revision_warranted=true` event; `new_hypothesis.reasoning` names what the prior summary was claiming and why the evidence no longer fits a single-case frame. The operator then allocates the successor case ids and writes `split_into`.

**Merge** — two active cases on different hosts share enough signature to treat as one investigation. Triggers: shared callback domain, shared payload hash or payload family match, shared deployment cadence (mtime cluster within minutes across hosts). A merge proposal is also `revision_warranted=true`; `new_hypothesis.reasoning` names which other case id is implicated and what specific `EvidenceRow` ids establish the shared signature. The operator confirms and writes `merged_from` on the absorbing case.

Neither split nor merge is an automatic move — both surface via reasoning and `open_questions_additions`, and the operator executes the case-id bookkeeping.

## Reasoning shape for `new_hypothesis.reasoning`

The prompt requires that `reasoning` names the prior summary and cites specific `EvidenceRow` ids. A usable shape for the string:

- **Sentence 1** — name the prior claim. "Prior hypothesis summary described host-2 as a single-host Magento compromise with local PolyShell deployment."
- **Sentence 2** — name the evidence delta. "New evidence row `evt-a7f3` on host-7 shows the same callback domain as host-2's exhibit, and row `evt-b910` on host-4 shows matching payload structure within the same mtime cluster."
- **Sentence 3** — name the revision. "Revising to a campaign pattern across host-2, host-4, host-7 with shared attribution signature; confidence raised from 0.5 to 0.65 on cross-host corroboration per §Calibrated confidence."

Three sentences is a floor, not a ceiling. Longer reasoning is fine when the evidence is complex. Shorter reasoning is a tell the model is skipping the discipline.

## Anti-patterns — do not

1. Raise confidence by more than 0.2 in a single revision without flagging for operator review.
2. Emit a `likely_next` action with no `basis` tying back to an `observed` or `inferred` entry.
3. Summarize evidence back using raw log content — the engine is handed summaries, not raw lines, on purpose. A `new_hypothesis.reasoning` field that quotes raw log text is the model hallucinating the excerpt.
4. Frame findings using offensive-security vocabulary — "attack", "exploit", "breach severity", "TTP", "kill chain". Use "observed capability", "evidence pattern", "attribution signature", "deployment cadence". This is post-incident forensics, not red-team narration.
5. Silently dismiss `contradicts` evidence — a `supports` verdict on evidence that cuts against the prior hypothesis is the integrity failure the revision call exists to prevent.
6. Force-fit `unrelated` evidence into the current case because the alternative is "no update". `unrelated` + `revision_warranted=false` is the correct move.
7. Paraphrase the prior `hypothesis.current.summary` in `new_hypothesis.reasoning` as if it were your own observation — cite it as the prior claim being revised.
8. Emit `support_type=supports` on a revision where confidence also drops — a drop implies at least partial contradiction; the type should reflect that.

## Operator-specific layers — deferred

Three blocks below are read by the engine but are placeholders. The engine treats them as lifecycle context the operator will fill in. Keep revision output schema-coherent regardless of whether the operator content has landed.

<!-- OPERATOR TODO — escalation routing -->
When a case reaches `hypothesis.current.confidence >= 0.7` or shows cross-host campaign signature, the playbook calls for escalation. The routing rules — on-call owner, named responders, incident-channel conventions, paging thresholds — are operator-specific and not yet authored. Until they land, escalation intent surfaces via `proposed_actions` with `category=null` and a reason string naming the trigger.
<!-- END TODO -->

<!-- OPERATOR TODO — historical false-positive catalog -->
Operators accumulate a catalog of recurring false-positive patterns — backup tooling that resembles webshell staging, legitimate admin actions that trip hunter heuristics, shared-hosting artifacts mistaken for persistence. The catalog sharpens revision by letting the model recognize a pattern it should discount. Until the catalog lands, treat every hunter finding as load-bearing and rely on `ambiguous` when the signal is thin.
<!-- END TODO -->

<!-- OPERATOR TODO — IC brief handoff format -->
A case that reaches a stable hypothesis with operator-defined severity triggers a formal IC brief. The brief format — required sections, IOC inventory shape, remediation grammar — is operator-specific and not yet authored. Until it lands, the case file itself is the handoff artifact. Keep `hypothesis.current.reasoning` tight enough that a brief can be generated from it directly.
<!-- END TODO -->
