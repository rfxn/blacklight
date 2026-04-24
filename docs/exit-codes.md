# `bl` exit code taxonomy

`bl` fails loud. Every `exit <N>` in a dispatcher or handler function must pick a code from this doc; drift requires a spec update. Ten named codes now; reserved ranges documented below.

This file is the single source of truth. `DESIGN.md` cites it from §8.1 (preflight), §13 (security model), and §11 (remediation). The wrapper's runtime guarantees the codes in column one are the only values `bl` emits on its own behalf.

---

## 1. Table

| Code | Name | Condition | Emitter |
|------|------|-----------|---------|
| `0` | `OK` | Successful operation | any handler on success |
| `64` | `USAGE` | Invalid CLI args, unknown flag, or missing required positional | dispatcher + any handler's argparse |
| `65` | `PREFLIGHT_FAIL` | `ANTHROPIC_API_KEY` unset, curl/jq missing, or `/var/lib/bl/` not writable | `bl_preflight()` |
| `66` | `WORKSPACE_NOT_SEEDED` | Preflight `GET /v1/agents?name=bl-curator` returns 0 matches | `bl_preflight()` |
| `67` | `SCHEMA_VALIDATION_FAIL` | A `report_step` payload failed wrapper-side defense-in-depth validation | `bl run` |
| `68` | `TIER_GATE_DENIED` | Operator declined a `suggested`/`destructive` step; or tier is `unknown` without `--unsafe --yes`; or preflight for a tiered action failed (ModSec `apachectl -t` fail, sig FP-gate fail) | `bl run` |
| `69` | `UPSTREAM_ERROR` | HTTP 5xx from Anthropic API after backoff+retry exhausted | any API-calling handler |
| `70` | `RATE_LIMITED` | HTTP 429 after backoff exhausted; caller should queue via `/var/lib/bl/outbox/` | any API-calling handler |
| `71` | `CONFLICT` | Resource already exists where uniqueness is required; or optimistic-lock clash on case-id allocation | `bl setup`, `bl case --new` |
| `72` | `NOT_FOUND` | Referenced case-id, step-id, or action-id does not exist | `bl case`, `bl run`, `bl defend --remove` |

---

## 2. Reserved ranges

Blacklight does NOT emit codes in these ranges:

- **1–63** — POSIX/shell conventional (tool-specific test failures, shell builtins). `bl` does not encounter these in its own code path; if a code in this range bubbles up it is from a child process (e.g., `grep` returning 1 for "no match") and blacklight treats it as operational noise, not a failure to act on.
- **73–79** — Future blacklight expansion. Unassigned. Any addition requires this doc + the emitting handler updated in one commit (see §5 change control).
- **80–127** — **NEVER used by blacklight.** Reserved to leave operator mental-model room for sysexits.h conventions (77 EX_NOPERM, 78 EX_CONFIG, etc. — which `bl` intentionally does NOT adopt because its semantics diverge from classical sysexits).
- **128+** — shell signal-based exits (128 + signal number). Examples: 130 = SIGINT (Ctrl-C), 137 = SIGKILL (OOM), 143 = SIGTERM (operator `kill <pid>`). These are emitted by the shell, not by `bl` code. Operators seeing 128+ codes should read them as "terminated externally" not "bl ran its exit path".

Specifically **127 (command not found)** is left uncovered. If `bl <subcommand>` somehow resolves to `/usr/bin/nope` and exec fails, the shell emits 127 — blacklight cannot intercept that. The dispatcher's verb-class lookup is designed to fail earlier (exit 64 `USAGE` for unknown verbs) so 127 is vanishingly rare, but it can happen during `bl` install-state drift.

---

## 3. Dispatch discipline

Every `exit <N>` in `bl` source MUST cite a code from §1. Additions: doc + handler + grep of every dispatch site, one commit. Removals: only after verifying no emitter references the code (grep `\bexit \([0-9]\+\)\b` across `bl` + `install.sh`).

**Prohibited patterns:**

- `exit 1` — too broad; pick a named code.
- `exit 2` — associated with "misuse of shell builtin" in many conventions; confusing.
- `return 1` as a substitute for `exit 1` — same objection; pick a named code, return it up the stack.

**Permitted patterns inside handler functions:**

- `return 0` — success sentinel for function-level flow control; the dispatcher translates the top-level return to `exit 0`.
- `return <N>` where `<N>` is a named code from §1 — the dispatcher passes through.

**Tests** (BATS, landing in M9+): `@test "bl foo --bad-flag exits 64"` with `[ "$status" -eq 64 ]` — exact code match, never `[ "$status" -ne 0 ]`. Regression against any exit-code silently becoming a different code is the test suite's job; this file is the expected-value authority.

---

## 4. Operator-facing example

```
$ bl run s-9999
blacklight: step s-9999 not found in bl-case/CASE-2026-0007/pending/
$ echo $?
72
```

```
$ bl defend modsec /path/to/rule.conf
blacklight: preflight — apachectl -t failed:
  Syntax error on line 1 of /etc/modsec/rule.conf: Unexpected token
blacklight: step rejected (tier=suggested, preflight failed)
$ echo $?
68
```

```
$ BL_REPO_URL= bl setup
blacklight: this Anthropic workspace has not been seeded.

Run one of the following (one-time per workspace):
  bl setup
  curl -fsSL https://raw.githubusercontent.com/rfxn/blacklight/main/bl | bash -s setup
$ echo $?
66
```

---

## 5. Change control

Adding a code:
1. Pick the next code in the `73–79` range (or, if all assigned, open a meta-question about widening the taxonomy before proceeding).
2. Add a row to §1 with `Code`, `Name`, `Condition`, `Emitter`.
3. Update the emitting handler to reference the code by symbolic name (`BL_EX_NEW_CASE=73`) rather than numeric literal in call sites.
4. Update `schemas/step.json` or setup-flow.md if the code is surfaceable over the wire (e.g., `SCHEMA_VALIDATION_FAIL` is mentioned in `docs/setup-flow.md §6`).
5. Grep every dispatch site: `grep -rn '\bexit \([0-9]\+\)\b' files/bl`.
6. Commit as `[Change] docs/exit-codes.md + [Change] bl + [Change] <doc> — add <NAME> exit code`.

Removing a code:
1. Confirm no emitter exists: `grep -rn '\bBL_EX_<NAME>\b' files/bl install.sh` returns 0 lines.
2. Confirm no BATS test references: `grep -rn 'status.*-eq <code>' tests/` returns 0 lines.
3. Remove §1 row + §2 reserved-range update + any doc references.
4. Commit as `[Change] docs/exit-codes.md — drop unused <NAME> exit code`.

Renaming a code: requires the full add+remove pair (new code assigned, old code deprecated in one commit, emitters migrated, old code removed in a follow-up commit one release later). Do not reuse numeric values across releases.
