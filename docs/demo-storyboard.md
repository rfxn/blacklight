# Demo Storyboard — agentic-minutes counter-clock

3:00 hard cap. Recorded on a CentOS 6 demo container. APSB25-94 PolyShell
exhibit at `exhibits/fleet-01/host-2-polyshell/` is the locked scenario.
Curator session driven by fixture playback (`tests/helpers/curator-mock.bash`
+ `tests/fixtures/step-*.json`) — operator-confirmed at planning time to
eliminate the timing-variance risk on T+1:00. Live take is held as a backup.

Pitch sentences each beat substantiates are quoted verbatim in the right-hand
column. The full pitch lives in `PIVOT-v2.md` and the README hero block.

## Beat sequence (locked, 3:00 exact)

| T+ | Duration | What's on screen | Operator narration (≤30 words) | Pitch sentence served |
|---|---:|---|---|---|
| 0:00 | 15s | Split screen: left = Adobe APSB25-94 advisory page in browser; right = blank `bash` prompt on `magento-prod-01.example.test`. OBS countdown overlay starts at 3:00 and ticks down. Window title: `centos6 — production magento store`. | "March 2026. Adobe drops APSB25-94. Critical Magento 2.4 RCE, pre-auth. The clock starts now." | Establishes the gap — *attackers in agentic-minutes vs defenders grepping logs*. |
| 0:15 | 15s | Right pane: `bl observe substrate` runs. JSONL streams 12 records. Last visible line summarizes: `kernel=el6 init=upstart web=httpd modsec_loaded=true firewall=iptables scanner=lmd cron=cron.d pkg=rpm integrity=rpm-V`. | "First fifteen seconds. Blacklight enumerates the substrate. Apache, mod_security, iptables, maldet — the tools this host already runs." | *"It turns the substrate your org already runs on into an agentic defense layer."* |
| 0:30 | 30s | `bl observe log apache --around /var/www/html/pub/media/catalog/product/.cache/a.php --window 6h`. JSONL streams URL-evasion records (`.php/*.gif`, `.php/*.png` GETs + command POSTs). Highlight `203.0.113.42` actor IP repeated. | "Thirty seconds in. Apache log triage finds the URL-evasion signature — GIF89a polyglot uploads at the cache path. Attacker IP identified." | *"Defenders are still grepping logs"* — except this defender isn't. |
| 1:00 | 30s | `bl consult --new --trigger /var/www/html/pub/media/catalog/product/.cache/a.php` → `case-id: CASE-2026-0042`. `bl observe bundle` uploads. Curator session response streams: `s-01 (auto-tier) iptables drop 203.0.113.42`, `s-02 (auto-tier) maldet hex sig append`, `s-03 (suggested-tier) modsec rule 920099`. | "One minute. The curator — Opus 4.7 in a Managed Agent, 1M context, mounted skills bundle — reads the bundle and emits three directives. Two read-only, one suggested." | *"agentic defense layer"* + Managed Agents persistence. |
| 1:30 | 45s | `bl run --list` shows the three steps. `bl run s-01 --yes` (firewall block) → applied. `bl run s-02 --yes` (sig append + maldet reload) → applied. `bl run s-03` shows diff of modsec rule, operator types `y`. `apachectl configtest` → `Syntax OK`. `apachectl graceful` → reloaded. | "One thirty. Three actions applied. Diff shown for the destructive one. apachectl green. Rollback envelopes prepared." | *"responding at attacker speed"* + *"no walled gardens"* (operator approves, not the agent). |
| 2:15 | 30s | `bl observe firewall --backend iptables` shows the new DROP rule with `bl-case CASE-2026-0042` tag. `bl observe sigs --scanner lmd` shows the new hex sig loaded. `bl case show` prints case state: 3 actions applied, 0 pending, hypothesis confidence 0.85. | "Two fifteen. Three substrate emitters firing. Firewall blocking, signature loaded, modsec rule active. The substrate is the defense layer." | *"Just the tools you already trust."* |
| 2:45 | 15s | `bl case close`. Brief renders. Closing line on screen: `case CASE-2026-0042 closed | brief at file_id=fXXXXX | T+30d retire-sweep scheduled`. Then `pgrep -a bl` runs and returns empty (no daemons). | "Two forty-five. Case closed. Brief permanent. Retire-sweep scheduled. Zero residual processes — no daemons, no agent sprawl. Clock stops." | Curator-as-Managed-Agent persistence + *"no agent sprawl"*. |

**Total runtime: 3:00 exact.** No slack. If a beat overruns by >5s, the next beat compresses to compensate.

## On-screen overlay plan

- **OBS overlay:**
  - Top-right: `T+M:SS` countdown timer. Operator presses OBS "start recording" + stopwatch "start" simultaneously at T+0:00.
  - Bottom-center banner (appears at T+2:45): `APSB25-94 → DEFENDED IN T+2:45`.
  - Highlight rectangle (red, 2px stroke): drawn in OBS over the actor IP `203.0.113.42` and the shell path `pub/media/catalog/product/.cache/a.php` at first visible mention.
- **Terminal title:** `centos6 — production magento store` for beats 1–6, then `centos6 — case closed` at T+2:45.
- **Subtitles:** none. The narration is the audio track.

## Wall-clock overlay recipe

Three paths, ranked by preference. Operator confirms tooling by Sat 14:00 CT.

### Path 1 — recommended: asciinema + OBS

1. `asciinema rec /tmp/bl-demo-take-N.cast` on the demo host. Operator runs the beat sequence. Stop with Ctrl-D at exactly 3:00.
2. `asciinema cat /tmp/bl-demo-take-N.cast > /tmp/bl-demo-take-N.txt` for narration timing reference.
3. OBS sources: (a) window capture of asciinema playback (or live terminal); (b) browser source for the APSB25-94 advisory page; (c) stopwatch overlay (use [obs-stopwatch] or a simple HTML/JS local file).
4. Output: `/tmp/blacklight-demo-take-N.mp4` per take.

### Path 2 — fallback: live terminal + OBS

OBS captures the terminal directly. Higher fidelity but harder to retake without re-running the host.

### Path 3 — last-resort: hard-baked timing markers

`scripts/demo-driver.sh` (authored only if Path 1+2 misbehave on Sat morning) prints `[T+M:SS]` markers at each beat boundary using `command date +%H:%M:%S` deltas from a stored start epoch. Visible in the terminal recording itself; no overlay needed. Backup if OBS misbehaves.

## CentOS 6 demo container

- **Image:** `blacklight-test-centos6` (built by A2 deliverables in this same M10 wedge — `tests/Dockerfile.centos6` + `BATSMAN_OS_DEEP := centos6` lane).
- **Start command:**
  ```bash
  docker run -it --name bl-demo \
    --hostname magento-prod-01 \
    -e ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" \
    -v /tmp/bl-demo-volume:/var/lib/bl \
    blacklight-test-centos6 bash
  ```
- **Network posture:** default bridge is fine for fixture playback (no live API). For a backup live take, `--network host` so the curator session reaches `api.anthropic.com` directly.
- **Pre-stage:** copy exhibit fixture into the container at `/var/www/html/pub/media/catalog/product/.cache/a.php` and apache log at `/var/log/httpd/access_log` BEFORE recording. Done via `docker cp` from `exhibits/fleet-01/host-2-polyshell/`.

## Fixture-playback wiring (operator-locked path)

The Saturday recording uses fixture playback for the `bl consult` / `bl run` / `bl defend` beats — eliminates timing variance on T+1:00 (curator response can otherwise drift 5–25s and break the 30-second beat budget).

- `tests/helpers/curator-mock.bash` shims `curl` against `tests/fixtures/step-*.json` for the curator session response.
- The fixture `step-*.json` files for the demo are the same ones BATS uses; they need no edits.
- Operator runs the demo with `BL_MOCK_RESPONSE=populated` and `PATH=$BL_MOCK_BIN:$PATH` exported before each `bl consult` call.
- A live-API take is recorded as a backup AFTER the fixture take (no time pressure on the live one).

## "No walled gardens / no agent sprawl" beat

T+2:45 is the load-bearing one. `pgrep -a bl` returning empty visually proves zero residual processes after a full IR cycle. Backup if `pgrep` is too quiet on screen: `ps aux | grep -E 'bl|black' | grep -v grep` (also empty on a clean exit).

## Reshoot triggers (Sunday AM, 09:00–11:00 CT, hard cap)

A reshoot is required if ANY of these is true after the Saturday take:

- Total runtime > 3:05 OR < 2:50 (3min hard cap, 5s tolerance over; under 2:50 means a beat was rushed).
- Wall-clock overlay drifts more than 2s from actual command execution time at any beat boundary.
- Narration mumble / fluff / um-rate > 1 per beat.
- Curator response (T+1:00) takes >25s — looks slow on screen, breaks the agentic-minutes claim. Mitigation: fixture playback (locked path).
- T+2:45 `pgrep -a bl` returns non-empty — contradicts "no agent sprawl" beat.

Zero triggers → Sunday AM is reserved for buffer / submission packaging.
1–2 triggers → single reshoot Sunday 09:00–11:00 CT.
≥3 triggers → content problem, not a recording problem; operator escalates and reshapes the storyboard before re-recording. Hard cap on reshoot effort: 3 hours Sunday.

## Summary script (100–200 words, authored last)

Authored AFTER final video lock per `CLAUDE.md`. The post-lock author has these guardrails:

The 100–200 word summary MUST contain these three phrases verbatim:
1. *"the substrate your org already runs on"*
2. *"agentic-minutes"*
3. *"compatible from CentOS 6"*

It MUST avoid:
- The word "AI"
- "Claude" / "Anthropic" attribution beyond a single mention of "Opus 4.7" / "Managed Agents"
- Any operator-local hostname, customer reference, or non-public IOC
- Any Liquid Web reference

Word target: 150 ± 25.
