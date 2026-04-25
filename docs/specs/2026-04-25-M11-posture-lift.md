# M11 — Posture lift spec input

Lifts the audit-bar from "M10 ship-ready" to "judging-floor green" by closing fourteen gaps the M10 P11 + post-merge audit identified. Spec input — the executable plan is `PLAN-M11.md`. This file frames the goals, non-goals, and the gap table the operator dialogue produced; it is the source of truth the plan flows from.

---

## 1. Problem statement

M10 shipped the v0.1.0 release: install/uninstall roundtrip green on all four target distros, 228 BATS green, RPM + DEB packages validated, skills bundle 65 files / 20 subdirectories. The post-M10 audit surfaced fourteen distinct gaps between (a) what `bl` actually does at runtime, (b) what the docs (README, DESIGN.md, PIVOT-v2.md) claim, and (c) the gates the M10 closeout review left open for "follow-up". Two of the fourteen are doc-only drift; the other twelve are real engineering gaps — Messages API foundation missing, `bl_poll_pending` is a single-cycle skeleton, only one model (Opus 4.7) is wired despite the README's three-tier claim, the test base is 70% smoke and 30% negative, and the demo fixture `host-2-polyshell/` is too small to exercise the 1M-context curator under realistic correlation pressure.

M11 is the posture lift — close all fourteen so the v0.2.0 release can be cut without any "we'll fix this in M12" caveats. M12 is reserved for the demo recording and submission package.

---

## 2. Goals

1. **G1 — Doc parity with code.** README skills count, walkthrough flag spelling, and adaptive-thinking caveat match what `bl` actually does. DESIGN.md §4 polling cadence and §11 brief-render render the shipping mechanism truthfully. PIVOT-v2.md §6.1 demotes hunter dispatch from "available" to "Phase P3 roadmap" — `callable_agents` is the path, not a separate Sonnet 4.6 session.

2. **G2 — Messages API foundation.** `bl_messages_call` (analogue of `bl_api_call` for `POST /v1/messages`) lands in `src/bl.d/22-models.sh` with the same 4-retry exponential-backoff envelope. Sonnet 4.6 (bundle summary) + Haiku 4.5 (FP-gate adjudication) call sites route through it.

3. **G3 — Real poll loop.** `bl_poll_pending` becomes a continuous GET-loop with seen-set dedup, `--timeout` / `--interval` flags, and `end_turn` proxy via N empty cycles. Replaces the M1 single-cycle skeleton.

4. **G4 — Negative-test coverage.** Five highest-leverage negative tests land across 4 existing `.bats` files, lifting the 70%-smoke / 30%-negative ratio to the audit-recommended ≥50% negative for the surface that ships behind a confirm prompt.

5. **G5 — Realistic demo fixture.** `exhibits/fleet-01/host-2-polyshell/` lifts to ~100K tokens (50K Apache CLF + 3K ModSec + 500 journalctl records), deterministic seed, public Adobe advisory IOC patterns + RFC 5737 IPs only — exercises the 1M-context curator under realistic correlation pressure, not toy 50-line samples.

---

## 3. Non-goals

- **No demo work.** Recording, narration, storyboard polish, video editing — all M12.
- **No scope expansion.** No new motions, no new memstore schemas beyond what M10 shipped, no new skills bundles. Posture lift, not feature add.
- **No M9-style hardening reopens.** Fence-tokens, ledger schema, prompt-injection coverage are M9 closed; M11 does not touch them.
- **No `callable_agents` implementation.** PIVOT-v2.md §6.1 demotes hunter dispatch to P3 roadmap; the `callable_agents` wiring lands when M12 ships, not in M11.
- **No CLI surface change.** `bl <verb>` shape is frozen post-M10. Flag additions to existing verbs (e.g., `bl_poll_pending --timeout`) are permitted; new verbs are not.

---

## 4. Gap table

The fourteen gaps the operator dialogue surfaced. P# columns map to phases in `PLAN-M11.md`.

| # | Gap | Surface | Phase |
|---|-----|---------|-------|
| 1 | README skills count drift (48/13 → actual 65/20) | README.md "Skills architecture" | P1 |
| 2 | README "Try it" walkthrough uses non-existent flags (`--path` / `--since` on `bl observe apache`) | README.md §"Try it" Step 1 | P1 |
| 3 | README adaptive-thinking caveat missing — operator-configurable `thinking` rejected by `managed-agents-2026-04-01` | README.md "Why Opus 4.7 + 1M" | P1 |
| 4 | DESIGN.md §4 polling cadence claims "every 2-3s" but ships two modes (loop + on-demand) | DESIGN.md §4 | P1 |
| 5 | DESIGN.md §11 brief-render mechanism not documented (HTML/PDF best-effort, MD canonical) | DESIGN.md §11 | P1 |
| 6 | PIVOT-v2.md §6.1 names hunter dispatch "available" — not implemented; deferred to P3 roadmap | PIVOT-v2.md §6.1 | P1 |
| 7 | CHANGELOG.RELEASE M10 P11 typo — skill count 46 → 64 (off-by-one; actual 65 with INDEX.md) | CHANGELOG.RELEASE | P1 |
| 8 | `bl_messages_call` foundation missing — Sonnet 4.6 + Haiku 4.5 routing has no API primitive | src/bl.d/22-models.sh (new) | P2 |
| 9 | `bl_poll_pending` is a single-cycle skeleton — no real loop, no dedup, no timeout | src/bl.d/20-api.sh | P6 |
| 10 | Sonnet 4.6 call site (bundle summary) not wired through Messages API | src/bl.d/?? (TBD) | P3-5 |
| 11 | Haiku 4.5 FP-gate not wired through Messages API | src/bl.d/82-defend.sh | P3-5 |
| 12 | Negative-test coverage gap — 70% smoke, audit recommends ≥50% negative on confirm-gated paths | tests/02/05/06/07/08*.bats | P9 |
| 13 | Demo fixture too small — host-2-polyshell/ ~5K tokens, target ≥100K to exercise 1M context | exhibits/fleet-01/host-2-polyshell/ | P11 |
| 14 | `bl run --list` on-demand fetch not surfaced in DESIGN.md §4 (covered by gap #4 reconcile) | DESIGN.md §4 | P1 |

---

## 5. Verification

Doc-parity gaps (P1) verify via grep:

```bash
grep -c '48 files' README.md                # expect 0
grep -c '65 files' README.md                # expect 1
grep -c '13 subdirectories' README.md       # expect 0
grep -c '20 subdirectories' README.md       # expect 1
grep -c -- '--around' README.md             # expect 1
grep -c -- '--mtime-since' README.md        # expect 1
grep -c 'Hunter (Phase P3 roadmap)' PIVOT-v2.md   # expect 1
grep -c '11.6 Brief rendering' DESIGN.md    # expect 1
grep -c 'continuous poll loop' DESIGN.md    # expect 1
```

Code gaps (P2/P6/P9/P11) verify via the BATS suite — see `PLAN-M11.md` per-phase Accept criteria. Pre-commit floor: debian12 + rocky9 green; release floor: full six-OS matrix.

---

## 6. Sequencing

`PLAN-M11.md` orders the phases:

1. **P1** — doc reconciliation (this spec authors and lands as Step 1 of P1)
2. **P2** — `bl_messages_call` foundation
3. **P3-5** — Sonnet 4.6 + Haiku 4.5 call-site wiring
4. **P6** — `bl_poll_pending` real loop
5. **P9** — five negative tests
6. **P11** — demo fixture beef-up

P1 lands first because the spec input file (this document) must exist before downstream phases reference it.
