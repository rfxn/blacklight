# blacklight — demo script

**Runtime: 3:00 hard cap.** Two variants ship, recorded back-to-back Saturday 18:00 CT. Sunday AM picks the winner.

- **Variant A (3-beat, default).** host-2 → host-4 → host-1 anticipatory block. One clear arc, one apex at 1:15.
- **Variant B (4-beat, optional).** Variant A + host-5 mind-change at 1:55. Plot twist; raises Depth signal but risks diluting the apex.

Both variants run from the same compose stack and the same `time_compression.py` runner, distinguished by `--fleet` profile.

---

## Pre-flight (operator runs once, ≤60 minutes before recording)

```bash
# Clean state
docker-compose -f compose/docker-compose.yml down -v
rm -rf curator/storage/cases/* curator/storage/evidence.db curator/storage/manifest.yaml*

# Bring up the fleet
. .secrets/env                                      # ANTHROPIC_API_KEY + agent IDs
docker-compose -f compose/docker-compose.yml up -d --build

# Wait for health
docker exec bl-curator curl -fsS http://localhost:8080/health    # → {"ok": true}

# Confirm exhibits staged on each host (smoke)
docker exec bl-host-2 ls /var/www/html/pub/media/catalog/product/.cache/
docker exec bl-host-4 ls /var/www/html/pub/media/wysiwyg/.system/
# host-1: no compromise file expected — confirm clean
docker exec bl-host-1 find /var/www/html -name '*.php' -newer /tmp 2>/dev/null
```

If any pre-flight fails, do NOT record. Reset and try again.

---

## Variant A — 3-beat (default, ~2:50 of 3:00)

### Beat 0 — cold open (0:00 – 0:15)

**Visual.** Title card: `blacklight` + tagline. Cut to terminal, prompt sitting at the project root.

**Narration.**
> "A managed hosting provider runs ten thousand customer sites. One gets hit by Adobe APSB25-94. Today, figuring out what else was compromised takes five days. blacklight does it in ninety seconds — and the host that was never compromised blocks the next attack."

**Caption.** *"APSB25-94 · 10k sites · 5-day MTTR"*

### Beat 1 — fleet up + first investigation (0:15 – 0:50)

**Visual.** Operator runs:
```bash
docker-compose -f compose/docker-compose.yml up -d --build
python demo/time_compression.py --fleet fleet-01-3beat --speed 20x
```
Curator + 4 hosts come up. Sim-day 1: host-2 reports. Three Sonnet 4.6 hunters fire in parallel (visible in curator log pane). CASE-2026-0007 materializes at confidence 0.4.

**Narration.**
> "Three Sonnet 4.6 hunters extract structured evidence from each host. On host-2, we find a PolyShell webshell. A case opens at confidence 0.4 — single host, multi-vector PolyShell variant."

**Caption.** *"Sonnet 4.6 · parallel hunters · CASE-2026-0007"*

### Beat 2 — case grows, defenses ship (0:50 – 1:15)

**Visual.** Sim-day 2: host-4 reports. Case engine reads its own prior case file; `hypothesis.history[]` appends a revision. Confidence 0.4 → 0.7. Cut to the synthesized ModSec rule streaming into `curator/storage/manifest.yaml`. `apachectl configtest` PASS shown in green. bl-pull on every host fetches the manifest + SHA-256 sidecar.

**Narration.**
> "Sim-day 2. Host-4's evidence lands. Opus 4.7 with adaptive thinking reads what it wrote yesterday — and revises. Same actor, two hosts, shared callback domain. The synthesizer generates a ModSec rule. The rule passes `apachectl configtest`. The manifest goes out to every host in the fleet."

**Caption.** *"Opus 4.7 · adaptive thinking · history[] appended · rule validated"*

### Beat 3 — THE PAYOFF (1:15 – 1:55)

**LINGER ON THIS BEAT FOR ≥4 SECONDS.** This is the one moment that has to land.

**Visual.** Split screen.
- LEFT: simulated attacker POSTs a credential-harvest payload to `bl-host-1/admin/auth`.
- RIGHT: Apache audit log on host-1 shows `id=9700` (anticipatory rule) firing. **403 BLOCKED** flash.
- Then cut to the case file's `proposed_actions` entry from sim-day 2 — three sim-days ago — predicting this exact next step.

**Narration.**
> "Host-1 was never compromised. Nothing in its own logs ever suggested it would be. But the curator attributed earlier activity on hosts 2 and 4 to a coherent actor — APSB25-94, with credential harvest as the inferred next move. It generated the rule three sim-days ago. And now host-1 just blocked the attack the curator predicted from somewhere else."

**Caption.** *"host-1 blocked — never compromised · attribution from other hosts · rule deployed three sim-days ago"*

### Beat 4 — the artifact (1:55 – 2:25)

**Visual.** Cut to the rendered case file YAML in a pager. `hypothesis.history[]` scrolls past — three revisions, confidence 0.4 → 0.7 → 0.85, each with the prior summary cited and the reasoning for the change. Pause on the final entry. Then cut to the rendered HTML incident brief (`curator/storage/cases/CASE-2026-0007.brief.html`) — confidence curve as SVG, attribution graph, rule lineage from evidence row IDs to the deployed rule.

**Narration.**
> "Every revision is auditable. Every defense ties back to the evidence that warranted it. This is why the curator is a Managed Agent, not a tool loop — it holds case state across days, contradicts itself when evidence demands, and ships a defensible artifact at the end."

**Caption.** *"Managed Agent · persistent case · IC brief takeaway"*

### Beat 5 — model choice as design (2:25 – 2:50)

**Visual.** Architecture diagram from README. Sonnet vs Opus split highlighted.

**Narration.**
> "Sonnet 4.6 for the hunters — pattern at speed. Opus 4.7 for the case engine, intent reconstructor, and synthesizer — judgment that revises itself with adaptive thinking. Model choice is part of the system design."

**Caption.** *"Why these models · §README"*

### Close (2:50 – 3:00)

**Visual.** Back to terminal.

**Narration.**
> "blacklight. Twenty-five years of hosting security, thinking continuously."

**Caption.** *"github.com/rfxn/blacklight · GPL v2"*

---

## Variant B — 4-beat (optional, ~3:00 of 3:00)

Identical to Variant A through Beat 3. Insert Beat 3.5 between the payoff and the artifact.

### Beat 3.5 — the mind-change (1:55 – 2:25, replaces Variant A Beat 4)

**Visual.** Sim-day 14: host-5 reports. Initial appearance is the same campaign — Magento, recent compromise, similar timeframe. Hunters fire. Intent reconstructor runs. **Family markers don't match** — different loader axis, different callback TLD pattern, no APSB25-94 dispatch table. Curator splits the case to CASE-2026-0008. On-screen: `case_engine.split_case()` invocation; new case YAML appears alongside the original.

**Narration.**
> "Sim-day 14. Host-5 reports what looks like the same campaign. The intent reconstructor reads the artifacts — but the family markers don't line up. Different loader, different callback domain pattern, different drop convention. Curator splits the case. Pattern matching would have merged these. Judgment didn't."

**Caption.** *"Splitting CASE-2026-0008 · family-marker divergence · Opus 4.7 judgment"*

### Beat 4 (Variant B) — collapsed artifact + close (2:25 – 3:00)

Compress Variant A's Beat 4 + Beat 5 + Close into the remaining 35 seconds. Cut to the case file briefly (5s on `history[]`); then architecture/model-choice card (15s); then close (10s).

**Tradeoff to manage.** The 4-beat variant earns Depth signal (judges see split + revision + anticipatory block) but risks blurring the 1:15 apex by adding a second dramatic moment. Decision rule: if Variant A's recording lingers convincingly on the host-1 block, ship A. If A feels thin or the apex doesn't read as a payoff to a non-security viewer, ship B.

---

## Recording technical notes

- **Pre-record shell output where possible.** Live typing eats time and adds suspense the demo can't afford. Pre-render the `time_compression.py` runs to a fixed-pace screencast; cut in reveals.
- **Captions are non-negotiable.** Judges may scan with audio off. The 1:15 caption must read as a complete payoff without narration.
- **Frame the curator log pane large enough to read.** Keep terminal at ≥14pt for the recording resolution. The `thinking` summary blocks need to be legible on first read.
- **No `Co-Authored-By` in any visible commit on screen.** No Claude/Anthropic attribution outside the explicit "Why these models" beat.
- **Audio level uniform.** Compressor on the narration track; no live ambient noise.

---

## Take inventory

| Take | Variant | Notes |
|---|---|---|
| 1 | A | Saturday 18:00 CT — the gate take. |
| 2 | B | Saturday 19:00 CT — record immediately if take 1 was clean; otherwise re-do A. |
| 3 (optional) | A or B | Sunday AM if either Saturday take had pacing issues. |

Ship the take that lands the apex. Edit budget: 1 hour Sunday between final take and submission.
