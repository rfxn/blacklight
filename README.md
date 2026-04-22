# blacklight

*A fleet-scoped Linux security investigator that thinks continuously, revises its conclusions as evidence arrives, and turns forensic reasoning into deployable defenses.*

Every security tool gives you alerts. None of them give you an investigation. blacklight runs a living case file across hosts and days — it reads its own prior reasoning, contradicts itself when evidence demands, attributes activity to a coherent actor, and translates what it learned into a deployable ModSec rule. The payoff frame the rest of this repo is optimized for: *a host that was never compromised blocks an attack because the curator attributed earlier activity on other hosts to a coherent actor with a predicted next move.*

Built for managed hosting providers and MSPs who live with the class of incident blacklight is demonstrated against — Adobe Commerce / Magento PolyShell exploitation (APSB25-94) across a multi-host fleet.

## Try it

```bash
git clone https://github.com/rfxn/blacklight.git
cd blacklight
cp .secrets/env.example .secrets/env    # add your ANTHROPIC_API_KEY
. .secrets/env
docker-compose -f compose/docker-compose.yml up -d --build
```

The fleet comes up as three containers: `bl-curator` (the investigator, Managed Agent), `bl-host-2` (Apache + ModSec + staged PolyShell from public APSB25-94 advisory), and `bl-host-3` (clean Nginx). Feed a report to the curator:

```bash
docker exec bl-host-2 /opt/bl-agent/bl-report /tmp/host-2.tar
docker cp bl-host-2:/tmp/host-2.tar bl-curator:/app/inbox/
docker exec bl-curator python -m curator.orchestrator /app/inbox/host-2.tar
docker exec bl-curator cat /app/curator/storage/cases/CASE-2026-0007.yaml
```

---

## Why these models

Model choice is part of the system design, not a sponsorship.

**Sonnet 4.6 runs the hunters.** Filesystem anomaly detection, log-cadence analysis, and timeline correlation are structured pattern-matching at volume. Three hunters run in parallel against every report. Sonnet 4.6 is fast enough that a three-host report finishes in under thirty seconds and cheap enough that running them continuously across a fleet is economically sane.

**Opus 4.7 runs the intent reconstructor.** Deobfuscating a multi-layer PolyShell (base64 → gzinflate → eval, with mangled variables and capability markers hidden in commented dead code) is sustained code comprehension, not pattern matching. This is where 4.7's frontier code reasoning measurably beats 4.6. Extended thinking is enabled on this call.

**Opus 4.7 runs the case-file engine.** Hypothesis revision with calibrated uncertainty — reading the investigator's own prior reasoning, deciding whether new evidence *supports*, *contradicts*, or *extends* it, and writing a new hypothesis with honest confidence — is where Opus 4.7's calibration earns its cost. Extended thinking is enabled here as well. This is the load-bearing capability of the entire system.

**Opus 4.7 runs the synthesizer.** Generating a ModSec rule that catches the observed attack, an exception list that preserves legitimate traffic, and a validation test that proves both is multi-artifact coherent generation — the shape of work where 4.7's depth matters and a single-shot call to a smaller model would miss a variant.

**The curator is a Managed Agent.** Not a cosmetic wrapper — the curator's state (case files, hypothesis history, evidence threads, capability maps) persists across simulated days and across reports from different hosts. That persistence is what lets the demo close with an uncompromised host blocking an attack because the curator remembered what it learned yesterday from somewhere else.

---

## Status

Hackathon build started **2026-04-21 19:48 CT**. Submission target **2026-04-26 16:00 EDT**.
Built for the *Built with Opus 4.7* Claude Code hackathon, hosted by Cerebral Valley — [event page](https://cerebralvalley.ai/e/built-with-4-7-hackathon).

Clean-room build. Zero pre-existing code. License: **GPL v2** — matches the operator's existing defensive OSS (LMD / APF / BFD).

Full architecture, skills bundle, demo walkthrough, and roadmap land by submission day.
