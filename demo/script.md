# blacklight — demo script

**Runtime: 3:00 hard cap.** Two variants ship, recorded back-to-back Saturday 18:00 CT. Sunday AM picks the winner.

- **Variant A (3-beat, default).** Sim-days 5 → 7 → 10. One clear arc, one apex at the anticipatory block. Stop the recording after the day-10 payoff beat.
- **Variant B (4-beat, optional).** All four beats: days 5 → 7 → 10 → 14. Plot twist at day-14 (mind-change / case split); raises Depth signal but risks diluting the apex.

Both variants run from the same compose stack and the same `time_compression.py` runner. Variant A = stop at day-10; Variant B = let all 4 beats run.

---

## Pre-flight (operator runs once, ≤60 minutes before recording)

```bash
# Confirm the Managed Agents session is bootstrapped
test -n "$BL_CURATOR_AGENT_ID" && test -n "$BL_CURATOR_ENV_ID" || \
    python -m curator.agent_setup --update | tee -a .secrets/env

# Verify sim tarballs are present (P37 fixtures)
tar tzf tests/fixtures/sim/host-4-day5.tar.gz   | head -3
tar tzf tests/fixtures/sim/host-7-day7.tar.gz   | head -3
tar tzf tests/fixtures/sim/host-1-day10.tar.gz  | head -3
tar tzf tests/fixtures/sim/host-5-day14.tar.gz  | head -3

# Rehearsal run — must exit 0; otherwise do NOT record
python -m demo.time_compression --mode=stub --fast
echo "exit $?"    # expect: exit 0

# Clean state
docker compose -f compose/docker-compose.yml down -v
rm -rf curator/storage/cases/* curator/storage/evidence.db curator/storage/manifest.yaml*

# Bring up the fleet (host-2 only in compose; time_compression reads tarballs)
. .secrets/env                                      # ANTHROPIC_API_KEY
docker compose -f compose/docker-compose.yml up -d --build

# Wait for health
docker exec bl-curator curl -fsS http://localhost:8080/health    # → {"ok": true}

# Confirm host-2 exhibit staged (only host in compose)
docker exec bl-host-2 ls /var/www/html/pub/media/catalog/product/.cache/
```

**Exit-code gate.** Stub-mode rehearsal must exit 0. If it exits non-zero, diagnose and fix before recording — do NOT record over a broken runner.

If any pre-flight fails, do NOT record. Reset and try again.

---

## The take

### 0:00 — cold open

**Visual.** Title card: `blacklight` + tagline. Cut to terminal, prompt at project root.

**Narration.**
> "A managed hosting provider runs ten thousand customer sites. One gets hit by Adobe APSB25-94. Today, figuring out what else was compromised takes five days. blacklight does it in ninety seconds — and the host that was never compromised blocks the next attack."

**Caption.** *"APSB25-94 · 10k sites · 5-day MTTR"*

---

### 0:15 — fleet up + sim start

**Operator runs:**
```bash
docker compose up -d --build          # or: docker compose -f compose/docker-compose.yml up -d --build
python -m demo.time_compression --mode=live --paced
```

**Visual.** Curator + host-2 come up. Sim begins. Three Sonnet 4.6 hunters fire in parallel (visible in curator log pane). CASE-2026-0007 materializes.

**Narration.**
> "Three Sonnet 4.6 hunters extract structured evidence. On host-4 at sim-day 5, we have two hosts with matching TTPs and a shared C2. The case engine revises."

---

### 0:35 — sim-day 5 caption lands

**Runner prints (verbatim; `[session sid=...]` prefix emitted by `time_compression.py` when `BL_CURATOR_SESSION_ID` is set):**
```
[session sid=sess_abc123de... · reasoning over prior turn]
[demo sim_day=5]  Two hosts, matching TTPs, shared C2. Revising to 'campaign'. Confidence 0.60.
```

**Caption.** *"Two hosts, matching TTPs, shared C2. Revising to 'campaign'. Confidence 0.60."*

**Narration.**
> "Opus 4.7 with adaptive thinking reads what it wrote on day 1 and contradicts itself. Same actor. Two hosts. Shared callback domain. Confidence goes to 0.60."

---

### 1:15 — sim-day 7 caption lands

**Runner prints (verbatim):**
```
[demo sim_day=7]  Three hosts, same C2 across all. Confidence 0.85. Predictive cred-harvest rule promoted.
```

**Caption.** *"Three hosts, same C2 across all. Confidence 0.85. Predictive cred-harvest rule promoted."*

**Narration.**
> "Day 7. A third host confirms the C2. Confidence 0.85. The synthesizer generates a predictive credential-harvest ModSec rule and ships it to every host."

---

### 1:55 — sim-day 10 caption lands — THE PAYOFF

**LINGER HERE FOR ≥4 SECONDS.** This is the one moment that has to land.

**Runner prints (verbatim):**
```
[demo sim_day=10] Anticipatory rule fired on a host that was never compromised. Hypothesis confirmed. Actor reached second-stage, was blocked.
```

**Caption.** *"Anticipatory rule fired on a host that was never compromised. Hypothesis confirmed. Actor reached second-stage, was blocked."*

**Narration.**
> "Host-1 was never compromised. Nothing in its own logs ever suggested it would be. But the curator attributed earlier activity on other hosts to a coherent actor — and generated the rule three sim-days ago. And now host-1 just blocked the attack the curator predicted from somewhere else."

**Visual cue.** Split screen: attacker POST on left, `403 BLOCKED` on right. Hold for 4+ seconds before advancing.

> **Variant A — stop the recording here.** The take is complete at 1:55. Proceed to close.

---

### 2:25 — sim-day 14 caption lands (Variant B only)

**Runner prints (verbatim — live mode, allocator id may vary):**
```
[demo sim_day=14] Revising. host-5 is a separate actor, skimmer campaign. Splitting to CASE-2026-0008.
```

**Caption.** *"Revising. host-5 is a separate actor, skimmer campaign. Splitting to CASE-2026-0008."*

**Narration.**
> "Day 14. Host-5 reports what looks like the same campaign. The intent reconstructor reads the artifacts — but the family markers don't line up. Different loader, different callback pattern. Curator splits the case. Pattern matching would have merged these. Judgment didn't."

Note: stub mode self-injects `BL_STUB_FINDINGS=1` + `BL_STUB_UNRELATED_HOST=host-5`, so the rehearsal path produces the same 4-beat arc as live and prints `CASE-2026-0008` on Day 14. If the allocator state differs at recording time (prior cases open in `BL_STORAGE`), the id may shift — clear storage before pre-flight.

---

### 2:50 — artifact + model choice

**Visual.** Cut to case file YAML in a pager. `hypothesis.history[]` scrolls past — revisions with prior summary cited and reasoning for each change. Then architecture diagram from README — Sonnet vs Opus split highlighted.

**Narration.**
> "Every revision is auditable. Every defense ties back to the evidence that warranted it. Sonnet 4.6 for the hunters — pattern at speed. Opus 4.7 for the case engine and synthesizer — judgment that revises itself. Model choice is part of the system design."

**Caption.** *"Managed Agent · persistent case · IC brief · Why these models §README"*

---

### 3:00 — close

**Visual.** Back to terminal.

**Narration.**
> "blacklight. Twenty-five years of hosting security, thinking continuously."

**Caption.** *"github.com/rfxn/blacklight · GPL v2"*

---

## Recovery (recording fails)

If the live run fails mid-recording:

1. Kill the runner (`Ctrl-C`).
2. Degrade to stub mode for a clean rehearsal pass: `python -m demo.time_compression --mode=stub --fast`; confirm exit 0 before proceeding.
3. Reset state: `docker compose down -v && rm -rf curator/storage/cases/* curator/storage/evidence.db curator/storage/manifest.yaml*`
4. Re-run pre-flight from the top.
5. If two live-mode failures on the same issue: degrade to `--mode=stub` for the recording itself. Stub output is visually identical to live output; the live calls happen off-camera.
6. Reshoot Sunday AM. Edit budget: 1 hour between final take and submission.

---

## Recording technical notes

- **Pre-record shell output where possible.** Live typing eats time. Pre-render the `time_compression.py` runs to a fixed-pace screencast; cut in reveals.
- **Captions are non-negotiable.** Judges may scan with audio off. The 1:55 anticipatory-block caption must read as a complete payoff without narration.
- **Frame the curator log pane large enough to read.** Keep terminal at ≥14pt for the recording resolution. The `thinking` summary blocks need to be legible on first read.
- **No `Co-Authored-By` in any visible commit on screen.** No Claude/Anthropic attribution outside the explicit "Why these models" beat.
- **Audio level uniform.** Compressor on the narration track; no live ambient noise.
- **`time_compression.py` reads from tarballs, not live host containers.** Only host-2 is in compose; hosts 1/4/5/7 are served from `tests/fixtures/sim/*.tar.gz`. No `docker exec` health probes for those hosts.

---

## A/B decision rule

The day-10 payoff at 1:55 is the only moment that has to land. Evaluation criteria:

- If Variant A's recording lingers convincingly on the host-1 block and the narration reads as a complete arc → ship A.
- If A feels thin or the apex doesn't read as a payoff to a non-security viewer → shoot B and let the day-14 split add Depth signal.

Ship the take that lands the apex. Tradeoff: 4-beat earns Depth (judges see split + revision + anticipatory block) but risks blurring the 1:55 apex by adding a second dramatic moment.

---

## Take inventory

| Take | Variant | Notes |
|---|---|---|
| 1 | A | Saturday 18:00 CT — the gate take. |
| 2 | B | Saturday 19:00 CT — record immediately if take 1 was clean; otherwise re-do A. |
| 3 (optional) | A or B | Sunday AM if either Saturday take had pacing issues. |

Edit budget: 1 hour Sunday between final take and submission.
