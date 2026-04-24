# M1 — `bl` skeleton design

*Authored 2026-04-24. Spec for blacklight v2 motion M1 per `PLAN.md`. Companion to `DESIGN.md §5.8` (dispatcher sketch) and `DESIGN.md §8.1` (preflight sketch). This file is the implementation contract; `/r-plan` decomposes it into phases without re-reading source.*

---

## 1. Problem Statement

blacklight v2 has no runtime entrypoint on `main`. M0 (commit `4ec1c23`) landed the shared contracts — `schemas/step.json`, `schemas/evidence-envelope.md`, `docs/action-tiers.md`, `docs/setup-flow.md`, `docs/case-layout.md`, `docs/exit-codes.md` — but no operator-facing bash script. Evidence:

| Artifact | Status | Line count |
|---|---|---|
| `bl` (v2 dispatcher) | **does not exist** | 0 |
| `bl-ctl` (v1 stub) | present but stale — references `curator/storage/cases` deleted at `694b0cf` and `http://localhost:8080` curator server deleted at `694b0cf` | 68 |
| `tests/` directory | **does not exist** | 0 |
| `schemas/step.json` | present (M0) | 77 (JSON) |
| `docs/*.md` | present (M0) | 6 files, ~700 KB aggregate |

Every motion after M0 depends on `bl` existing:

- **M4 (`bl observe`)** — adds handler functions that plug into a dispatcher.
- **M5 (`bl consult` / `bl run` / `bl case`)** — consumes `bl_poll_pending`, `bl_api_call`, `bl_case_current`.
- **M6 (`bl defend`)** — consumes `bl_init_workdir` for `/var/lib/bl/fp-corpus/`, `bl_api_call`.
- **M7 (`bl clean`)** — consumes `bl_init_workdir` for `/var/lib/bl/backups/`, `/var/lib/bl/quarantine/`.
- **M8 (`bl setup`)** — consumes `bl_preflight`, `bl_api_call`, workspace idempotency logic.
- **M9 (hardening)** — adds `apachectl -t` preflight and FP-gate to `bl defend`; depends on skeleton surface being stable.

Without M1, no downstream motion can start. `bl-ctl` cannot serve as a bridge — it points to deleted architecture (v1 Python Flask curator).

## 2. Goals

Numbered, measurable. Each goal has ≥1 verification command in §10b and ≥1 test in §10a.

1. **G1:** Single file `bl` at repo root, lint-clean.
   - `bash -n bl` returns 0.
   - `shellcheck bl` returns 0 (respecting blacklight Shell Standards directives).

2. **G2:** `bl --help` / `bl help` / `bl -h` each print a usage block listing all 7 namespaces and return exit 0.

3. **G3:** `bl --version` / `bl -v` each print `bl <BL_VERSION>` (where `BL_VERSION=0.1.0`) and return exit 0.

4. **G4:** Each of the 7 verb namespaces (`setup`, `observe`, `consult`, `run`, `defend`, `clean`, `case`) dispatches to a named handler function (`bl_setup`, `bl_observe`, …). Each handler prints `blacklight: <namespace> not yet implemented (M<N>)` to stderr and returns exit 64 (`USAGE` per `docs/exit-codes.md §1`).

5. **G5:** `bl_preflight()` on an unseeded workspace prints the bootstrap heredoc (per `DESIGN.md §8.1` lines 440–454) to stderr and returns exit 66 (`WORKSPACE_NOT_SEEDED`). **Note:** DESIGN.md §8.1 line 455 currently reads `return 64` — this is stale per `docs/exit-codes.md §1` which names `bl_preflight()` as the emitter of 66 for the unseeded path. M1 fixes DESIGN.md §8.1 `return 64` → `return 66` and §5.8 `bl_preflight || return 64` → `bl_preflight || return $?` (propagate preflight's code rather than clobber to 64) in the same commit.

6. **G6:** `bl_preflight()` exits 65 (`PREFLIGHT_FAIL`) when `ANTHROPIC_API_KEY` is unset, `curl` is unavailable, or `jq` is unavailable. Each failure prints a distinct diagnostic to stderr. Each failure has a dedicated `@test` in `tests/02-preflight.bats`.

7. **G7:** `/var/lib/bl/{backups,quarantine,fp-corpus,outbox,ledger}` are created idempotently by `bl_init_workdir` when a handler (M4–M8) calls it. `bl_preflight` creates only `state/` directly via `command mkdir -p "$BL_STATE_DIR"` per DESIGN.md §8.1 — **not** via `bl_init_workdir`. This decoupling keeps flag-bypass paths (help/version/setup) from paying the 5-subdir mkdir cost and keeps preflight's dependency surface minimal.

8. **G8:** `bl-ctl` removed from tree (`git rm bl-ctl`) — references deleted v1 architecture.

9. **G9:** `tests/` scaffold lands:
   - `tests/infra/` — batsman submodule at `v1.4.2`.
   - `tests/Makefile`, `tests/run-tests.sh`, `tests/Dockerfile` — consume batsman per its `BATSMAN_PROJECT := blacklight` contract.
   - `tests/00-smoke.bats` — asserts `bash -n bl` + `bl --version` exit 0.
   - `tests/01-cli-surface.bats` — asserts G1, G2, G3, G4 (10 `@test` entries).
   - `tests/02-preflight.bats` — asserts G5, G6, G7, G11 (9 `@test` entries, consumes `tests/helpers/bl-preflight-mock.bash`).

10. **G10:** `make -C tests test` (debian12) and `make -C tests test-rocky9` (rocky9) both pass.

11. **G11:** `bl` enforces a bash 4.1+ floor at **top-level** (as a standalone statement immediately after the `readonly BL_EX_*` constant block, before any function definitions or `main` invocation — **NOT** inside `bl_preflight`). Check: `BASH_VERSINFO[0] * 100 + BASH_VERSINFO[1] < 401` exits 65 with `blacklight: bash 4.1+ required`. Placement at top-level ensures `bl --help` and `bl --version` also trip the floor on bash <4.1 (flag-sniff runs after floor check). Behavioral coverage is a best-effort test in `tests/02-preflight.bats` using `bash -c 'BASH_VERSINFO=([0]=3 [1]=2); source ./bl'` (the source-under-patched-versinfo pattern); full cross-bash-version coverage is deferred to M10's platform matrix.

12. **G12:** Every `exit <N>` in `bl` cites a code from `docs/exit-codes.md §1` (via a symbolic constant, not a numeric literal at the call site).

## 3. Non-Goals

This spec and M1 implementation explicitly do not:

- **NG1.** Implement any handler logic beyond the stub-return-64 pattern. `bl_observe`, `bl_defend`, `bl_clean`, `bl_consult`, `bl_run`, `bl_case`, `bl_setup` are empty-with-message; their real implementations are M4, M6, M7, M5, M5, M5, M8 respectively.
- **NG2.** Implement `bl_api_call` payload construction beyond the `curl -sS -H ...` + retry/backoff wrapper shape. No endpoint-specific request bodies in M1.
- **NG3.** Make live Anthropic API calls during tests. A minimal preflight-only curl shim `tests/helpers/bl-preflight-mock.bash` lands with M1 to support G5/G6 BATS coverage — it serves a configurable `GET /v1/agents?name=bl-curator` response (empty list → 66 path; populated list → success path; 401 → 65 path). The full `tests/helpers/curator-mock.bash` (serving pending-steps poll + wake events) lands with M5 when `bl run` is implemented. M1 tests hit zero network.
- **NG4.** Land any skills (`skills/`), prompts, or case templates (`case-templates/`). M2 (case templates) and M3 (skills bundle) are separate motions.
- **NG5.** Package `bl` for RPM/DEB/install.sh. Packaging is M10.
- **NG6.** Change any of: `schemas/step.json`, `schemas/step.md`, `schemas/evidence-envelope.md`, `docs/exit-codes.md`, `docs/setup-flow.md`, `docs/action-tiers.md`, `docs/case-layout.md`. M1 reads these as authoritative; drift in any of them is a bug in M1 (not in the upstream doc). **Exception:** `DESIGN.md §5.8` and `DESIGN.md §8.1` receive minimal one-line edits in M1's commit to align the preflight return-code sketch with `docs/exit-codes.md §1` (see G5). No other DESIGN.md sections are touched by M1.
- **NG7.** Implement `--dry-run` semantics for `bl clean`. M7 consumes.
- **NG8.** Implement operator-veto window for `auto` tier actions. M6 consumes.
- **NG9.** Wire `bl-skills` or `bl-case` memory stores. M8 (`bl setup`) consumes.
- **NG10.** Implement `bl_log_level` parsing beyond `$BL_LOG_LEVEL in {debug,info,warn,error}`. No `--verbose`/`--quiet` CLI flags in M1.

## 4. Architecture

### 4.1 File Map

| File | Status | Est. lines | Purpose |
|---|---|---|---|
| `bl` | **new** | ~450 | Single-file bash dispatcher. Entry point, preflight, helpers, 7 namespaced handler stubs. |
| `bl-ctl` | **delete** | — | v1 stale, broken references. |
| `DESIGN.md` | **modify (2 lines)** | — | §8.1 line 455 `return 64` → `return 66` (align with exit-codes.md §1); §5.8 `bl_preflight \|\| return 64` → `bl_preflight \|\| return $?` (propagate preflight's exact code). |
| `tests/Makefile` | **new** | ~15 | Consumes `tests/infra/include/Makefile.tests`; sets `BATSMAN_PROJECT := blacklight` + OS matrix. |
| `tests/run-tests.sh` | **new** | ~25 | Thin batsman wrapper (pattern from `advanced-policy-firewall/tests/run-tests.sh`). No `--privileged` flag (blacklight is unprivileged). |
| `tests/Dockerfile` | **new** | ~15 | Layers `bash curl jq awk sed tar gzip zstd coreutils` on `batsman`'s debian12/rocky9 base. |
| `tests/00-smoke.bats` | **new** | ~30 | `bash -n bl` + `bl --version` smoke. |
| `tests/01-cli-surface.bats` | **new** | ~90 | 10 `@test` entries: lint, help surfaces, version surfaces, 7 namespaces, unknown-verb rejection. |
| `tests/02-preflight.bats` | **new** | ~100 | 7 `@test` entries: unseeded → 66, seeded → 0, API-key missing → 65, API-key empty → 65, curl-missing → 65, jq-missing → 65, bash-floor best-effort. Consumes `tests/helpers/bl-preflight-mock.bash`. |
| `tests/helpers/bl-preflight-mock.bash` | **new** | ~40 | Minimal curl-shim for `GET /v1/agents?name=bl-curator` — supports empty-list (unseeded), populated-list (seeded), 401 (bad key). Full `curator-mock.bash` lands M5. |
| `tests/.gitignore` | **new** | ~5 | Ignores BATS `.bats-tmp/` artifacts. |
| `tests/infra/` | **new (submodule)** | — | `batsman` at `v1.4.2`. |
| `.gitmodules` | **new** | ~3 | `tests/infra` → `https://github.com/rfxn/batsman.git` branch `main` path `tests/infra`. |

Size comparison:

| State | Shell file count | Shell LOC | Tests | Tests LOC |
|---|---|---|---|---|
| Before M1 (HEAD = `694b0cf`) | 1 (`bl-ctl`) | 68 | 0 | 0 |
| After M1 | 3 (`bl`, `tests/run-tests.sh`, `tests/helpers/bl-preflight-mock.bash`) | ~515 | 3 `.bats` files | ~220 |

Net: +~665 LOC shell + tests, +batsman submodule dependency, +2 lines in DESIGN.md.

### 4.2 Dependency Tree

```
bl  (single file, top-to-bottom read order)
│
├── 1. Header + shebang + strict mode
│     #!/bin/bash
│     set -euo pipefail
│
├── 2. Version + exit-code constants (from docs/exit-codes.md §1)
│     readonly BL_VERSION="0.1.0"
│     readonly BL_EX_OK=0  BL_EX_USAGE=64  BL_EX_PREFLIGHT_FAIL=65
│     readonly BL_EX_WORKSPACE_NOT_SEEDED=66  …  (all 10 codes declared)
│
├── 3. Bash 4.1+ floor check  (TOP-LEVEL statement, NOT in bl_preflight)
│     if (( BASH_VERSINFO[0]*100 + BASH_VERSINFO[1] < 401 )); then
│         printf 'blacklight: bash 4.1+ required\n' >&2
│         exit "$BL_EX_PREFLIGHT_FAIL"
│     fi
│
├── 4. Path constants
│     readonly BL_VAR_DIR="${BL_VAR_DIR:-/var/lib/bl}"
│     readonly BL_STATE_DIR="$BL_VAR_DIR/state"
│     readonly BL_AGENT_ID_FILE="$BL_STATE_DIR/agent-id"
│     readonly BL_CASE_CURRENT_FILE="$BL_STATE_DIR/case.current"
│
├── 5. Logging helpers (above all callers)
│     bl_info / bl_warn / bl_error / bl_debug  — stderr, level-filtered
│     bl_error_envelope  — formats `blacklight: <phase>: <problem>` + optional remediation
│
├── 6. Workdir helpers
│     bl_init_workdir  — idempotent mkdir -p of 5 subdirs (backups/quarantine/
│                        fp-corpus/outbox/ledger/; state/ is preflight's job).
│                        NOT called by bl_preflight. Consumed by M4–M8 handlers.
│     bl_case_current  — reads $BL_CASE_CURRENT_FILE, prints empty on miss, returns 0
│
├── 7. API helpers
│     bl_api_call <method> <url-suffix> [body-file]  — curl + jq + retry/backoff
│     bl_poll_pending <case-id>  — 2s sleep-loop probe of bl-case/<case>/pending/ (skeleton)
│
├── 8. Preflight
│     bl_preflight  — key + curl/jq + `command mkdir -p "$BL_STATE_DIR"` directly
│                     + cached agent-id read, else GET /v1/agents?name=bl-curator
│                     → cache or bootstrap-heredoc + return 66.
│                     Deps: bl_api_call, bl_error_envelope.
│                     NOT deps: bl_init_workdir (intentionally direct mkdir).
│
├── 9. Usage / version surfaces
│     bl_usage  — prints usage block (all 7 namespaces)
│     bl_version  — prints "bl $BL_VERSION"
│
├── 10. Handler stubs (one per namespace, alphabetical for grep)
│     bl_case     bl_clean    bl_consult  bl_defend
│     bl_observe  bl_run      bl_setup
│     All: print "<ns> not yet implemented (M<N>)" to stderr, return 64
│
└── 11. Main dispatcher
      main "$@"  — flag-sniff first (help/version/setup), else preflight → verb-case
```

### 4.3 Key Changes

- **New dispatcher `bl`**: matches DESIGN.md §5.8 shape but with pre-case flag sniff (help/version/setup bypass preflight), per-level logging helpers above handlers, and explicit exit-code constants.
- **Bash 4.1+ floor check at script entry**: top-level statement immediately after the `readonly BL_EX_*` block — NOT inside `bl_preflight`. This ensures help/version/setup (which bypass preflight) still trip the floor on bash <4.1.
- **Preflight creates `state/` directly, not via `bl_init_workdir`**: decouples the preflight hot-path from the 5-subdir lazy-init helper. M4–M8 handlers call `bl_init_workdir` when they need write paths; preflight does only what DESIGN.md §8.1 mandates.
- **`bl-ctl` removed**: not moved, not renamed — `git rm bl-ctl` in the same commit that lands `bl`. Verified stale: greps for `CURATOR_URL` and `CASES_DIR` against current tree return `bl-ctl` only.
- **DESIGN.md §5.8 and §8.1 receive one-line fixes**: §8.1 `return 64` → `return 66` (align with exit-codes.md §1); §5.8 `bl_preflight || return 64` → `bl_preflight || return $?` (propagate preflight's actual return code rather than clobber to 64). These are minimal corrections to stale sketches, not architectural changes.
- **`tests/` scaffold**: batsman submodule consumed (NOT copied); blacklight is a consumer of the shared test library per CLAUDE.md §Shared Libraries. `tests/helpers/bl-preflight-mock.bash` ships with M1 to support G5/G6 coverage without live API calls.

### 4.4 Dependency Rules

- **`bl` is single-file.** No `source` of external helpers. All code lives in `bl`. Size budget: ≤ 600 LOC for M1 (skeleton). Final v2 ceiling ~1000 LOC per DESIGN.md §3.
- **Helpers before handlers.** Top-to-bottom reading order matches call depth (logging → workdir → API → preflight → handlers → main).
- **Exit codes always symbolic.** Every `return $BL_EX_<NAME>` / `exit $BL_EX_<NAME>` cites a constant declared near top of file. Numeric literals in `exit`/`return` are prohibited (grep-verifiable in §10b).
- **Preflight fence.** `bl_preflight` is called by `main` exactly once, before the verb-dispatch case. Handlers never invoke `bl_preflight` directly — state they require (e.g. `$BL_AGENT_ID`) is a post-preflight invariant.
- **No `source` in runtime.** `bl` must be curl-pipeable per `DESIGN.md §8.3` install path 3.

## 5. File Contents

### 5.1 `bl` — function inventory

| Function | Signature | Purpose | Dependencies |
|---|---|---|---|
| `bl_info` | `(msg)` → stderr, return 0 | Level-info log helper. Prints `[bl] INFO: $msg` to stderr when `$BL_LOG_LEVEL` ∈ {debug, info}. | `printf`, `$BL_LOG_LEVEL` |
| `bl_warn` | `(msg)` → stderr, return 0 | Level-warn log helper. Prints `[bl] WARN: $msg` to stderr when `$BL_LOG_LEVEL` ∈ {debug, info, warn}. | `printf`, `$BL_LOG_LEVEL` |
| `bl_error` | `(msg)` → stderr, return 0 | Level-error log helper. Always prints `[bl] ERROR: $msg` to stderr. | `printf` |
| `bl_debug` | `(msg)` → stderr, return 0 | Level-debug log helper. No-op unless `$BL_LOG_LEVEL=debug`. | `printf`, `$BL_LOG_LEVEL` |
| `bl_error_envelope` | `(phase, problem, [remediation])` → stderr, return 0 | Formats `blacklight: <phase>: <problem>\n<remediation?>` to stderr. Matches DESIGN.md §8.1 heredoc shape. | `printf` |
| `bl_init_workdir` | `()` → return 0 or 65 | Idempotent `mkdir -p` of 5 subdirs under `$BL_VAR_DIR` (`backups/`, `quarantine/`, `fp-corpus/`, `outbox/`, `ledger/`). `state/` is preflight's responsibility, not this helper. Tests writability via `command touch "$BL_VAR_DIR/.wtest" 2>/dev/null`; on permission-denied returns 65 with envelope. **Called by M4–M8 handlers, NOT by `bl_preflight`.** Unreferenced in M1 (declared for downstream consumers). | `command mkdir`, `command touch`, `command rm`, `bl_debug`, `bl_error_envelope`, `$BL_VAR_DIR` |
| `bl_case_current` | `()` → stdout, return 0 | Reads `$BL_CASE_CURRENT_FILE`. Prints empty string if file missing (not an error). | `command cat`, `$BL_CASE_CURRENT_FILE` |
| `bl_api_call` | `(method, url-suffix, [body-file])` → stdout, return {0, 65, 69, 70} | Executes `curl -sS --max-time 30` against `https://api.anthropic.com$url_suffix` with canonical headers (x-api-key, anthropic-version, anthropic-beta, content-type). Captures HTTP status. Retries 3 times on 5xx with 2s/5s/10s/30s backoff. On 4xx: 401/403 → exit 65, 429 → exit 70, other 4xx → exit 65 with body logged to `bl_debug`. Body from file if passed. | `curl`, `jq`, `$ANTHROPIC_API_KEY`, `bl_error_envelope`, `bl_debug` |
| `bl_poll_pending` | `(case-id)` → loop, return 0 | Skeleton: 2s sleep loop probing `bl-case/<case-id>/pending/` existence via `bl_api_call` placeholder. Exits loop on empty-pending-N-cycles or `end_turn` sentinel. M5 drops in real read/write. No consumer in M1. | `sleep`, `bl_api_call` (stubbed), `bl_debug` |
| `bl_preflight` | `()` → return {0, 65, 66} | Verifies `$ANTHROPIC_API_KEY` set and non-empty, `command -v curl`, `command -v jq`. Calls `command mkdir -p "$BL_STATE_DIR"` **directly** (not via `bl_init_workdir`). Reads cached agent-id from `$BL_AGENT_ID_FILE`; if non-empty, sets `$BL_AGENT_ID` and returns 0. Else probes `GET /v1/agents?name=bl-curator` via `bl_api_call`; populated list → cache + return 0; empty list → heredoc bootstrap message + return 66. Bash 4.1+ floor check is **NOT** in this function — it runs at script top-level before any function is defined. | `command -v`, `command mkdir`, `command cat`, `command printf`, `bl_api_call`, `bl_error_envelope` |
| `bl_usage` | `()` → stdout, return 0 | Prints usage block with all 7 namespaces + common options. | `cat <<EOF` heredoc |
| `bl_version` | `()` → stdout, return 0 | Prints `bl $BL_VERSION`. | `printf`, `$BL_VERSION` |
| `bl_case` | `(args…)` → return 64 | Handler stub. Prints `blacklight: case not yet implemented (M5)` to stderr. | `bl_error_envelope` |
| `bl_clean` | `(args…)` → return 64 | Handler stub. Prints `blacklight: clean not yet implemented (M7)` to stderr. | `bl_error_envelope` |
| `bl_consult` | `(args…)` → return 64 | Handler stub. Prints `blacklight: consult not yet implemented (M5)` to stderr. | `bl_error_envelope` |
| `bl_defend` | `(args…)` → return 64 | Handler stub. Prints `blacklight: defend not yet implemented (M6)` to stderr. | `bl_error_envelope` |
| `bl_observe` | `(args…)` → return 64 | Handler stub. Prints `blacklight: observe not yet implemented (M4)` to stderr. | `bl_error_envelope` |
| `bl_run` | `(args…)` → return 64 | Handler stub. Prints `blacklight: run not yet implemented (M5)` to stderr. | `bl_error_envelope` |
| `bl_setup` | `(args…)` → return 64 | Handler stub. Prints `blacklight: setup not yet implemented (M8)` to stderr. | `bl_error_envelope` |
| `main` | `("$@")` → exits with dispatcher return | Flag-sniff (help/version bypass preflight) → `bl_preflight` → verb-case → handler. | all of the above |

### 5.2 `tests/Makefile` — shape

```makefile
BATSMAN_PROJECT        := blacklight
BATSMAN_OS_MODERN      := debian12 rocky9 ubuntu2404
BATSMAN_OS_LEGACY      := centos7 rocky8 ubuntu2004
BATSMAN_OS_EXTRA       := rocky10
BATSMAN_OS_ALL         := $(BATSMAN_OS_MODERN) $(BATSMAN_OS_LEGACY) $(BATSMAN_OS_EXTRA)
BATSMAN_RUN_TESTS      := ./run-tests.sh
PARALLEL_JOBS          := 3

include infra/include/Makefile.tests
```

No `BATSMAN_OS_DEEP` entry (`centos6`, `ubuntu1204`). Rationale: `bash 4.1+` floor (CentOS 6 era) holds but CentOS 6 Docker build time is 3× other distros; deep-legacy slot is reserved for M10 release matrix, not per-motion CI.

### 5.3 `tests/run-tests.sh` — shape

```bash
#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BATSMAN_PROJECT="blacklight"
BATSMAN_PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BATSMAN_TESTS_DIR="$SCRIPT_DIR"
BATSMAN_INFRA_DIR="$SCRIPT_DIR/infra"
BATSMAN_DOCKER_FLAGS=""          # blacklight is unprivileged — no --privileged
BATSMAN_DEFAULT_OS="debian12"
BATSMAN_CONTAINER_TEST_PATH="/opt/tests"
BATSMAN_SUPPORTED_OS="debian12 rocky9 ubuntu2404 centos7 rocky8 ubuntu2004 rocky10"
BATSMAN_TEST_TIMEOUT="${BATSMAN_TEST_TIMEOUT:-120}"

source "$BATSMAN_INFRA_DIR/lib/run-tests-core.sh"
batsman_run "$@"
```

### 5.4 `tests/Dockerfile` — shape

```dockerfile
ARG BASE_IMAGE=blacklight-base-debian12
FROM ${BASE_IMAGE}

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash curl jq awk sed tar gzip zstd coreutils \
    && rm -rf /var/lib/apt/lists/*

COPY . /opt/blacklight-src
```

For non-apt OS families (rocky, centos), the batsman `Makefile.tests` pattern handles distro-specific package manager adaptation via `BATSMAN_SUPPORTED_OS` expansion.

### 5.5 `tests/00-smoke.bats` — test inventory

| Test | Purpose |
|---|---|
| `bl parses clean with bash -n` | `bash -n $BL_SOURCE` returns 0. |
| `bl --version prints expected format` | Output matches regex `^bl [0-9]+\.[0-9]+\.[0-9]+$`; exit 0. |

### 5.6 `tests/01-cli-surface.bats` — test inventory

| Test | Goal covered |
|---|---|
| `shellcheck is clean` | G1 |
| `bl --help exits 0 and lists all 7 namespaces` | G2 |
| `bl help exits 0 (positional form)` | G2 |
| `bl -h exits 0 (short form)` | G2 |
| `bl --version exits 0 and prints version` | G3 |
| `bl -v exits 0 (short form)` | G3 |
| `bl setup dispatches to stub and exits 64 (and bypasses preflight)` | G4 |
| `bl observe / consult / run / defend / clean / case each dispatch to stub and exit 64 (parameterised)` | G4 |
| `bl <unknown-verb> exits 64 with usage hint` | G4 edge case 10 |
| `bl (no args) exits 64 with usage hint` | edge case 9 |

10 total `@test` entries (7 namespaces parameterised into one `@test` per namespace → 7 tests, plus 3 surface tests). Each is a named, grep-verifiable identity. Preflight-path tests live in `tests/02-preflight.bats` (§5.7).

### 5.7 `tests/02-preflight.bats` — test inventory

Consumes `tests/helpers/bl-preflight-mock.bash` to stub `curl` against the Anthropic API. Each `@test` sets `PATH` to prepend a mock-curl directory, configures the mock's response via env vars, then invokes `bl observe` (which triggers preflight).

| Test | Goal covered |
|---|---|
| `bl_preflight on unseeded workspace returns 66 and prints bootstrap heredoc` | G5 |
| `bl_preflight with cached agent-id returns 0 (skip API probe)` | G5 happy-path |
| `bl_preflight on seeded workspace (API returns 1+ agent) caches agent-id and returns 0` | G5 cache-populate path |
| `bl_preflight without ANTHROPIC_API_KEY exits 65 with distinct diagnostic` | G6 |
| `bl_preflight with empty ANTHROPIC_API_KEY exits 65 with distinct diagnostic` | G6 edge case 4 |
| `bl_preflight without curl in PATH exits 65` | G6 |
| `bl_preflight without jq in PATH exits 65` | G6 |
| `bl with corrupted (empty) agent-id file re-probes and treats as unseeded` | edge case 6 |
| `bl on bash <4.1 exits 65 with "bash 4.1+ required" (best-effort source-under-patched-VERSINFO)` | G11 behavioral |

9 `@test` entries. Test #9 (bash-floor) uses `bash -c 'BASH_VERSINFO=([0]=3 [1]=2); source ./bl'` and accepts the test as best-effort — if the surrogate VERSINFO assignment doesn't propagate into the sourced script on all bash versions, the test is skipped with `skip "bash floor test requires bash >=4 with VERSINFO assignable"` rather than failing. Full floor coverage is M10's platform matrix.

Total BATS tests landed by M1: 2 (smoke) + 10 (cli-surface) + 9 (preflight) = **21 `@test` entries**.

## 5b. Examples

### Example 1: `bl --version` on any host

```
$ bl --version
bl 0.1.0
$ echo $?
0
```

### Example 2: `bl --help` on any host

```
$ bl --help
bl — blacklight operator CLI

Usage: bl <command> [options]

Commands:
  observe   Read-only evidence extraction (logs, fs, crons, htaccess)  [M4]
  consult   Open / attach to an investigation case                      [M5]
  run       Execute an agent-prescribed step                            [M5]
  case      Inspect, log, close, reopen cases                           [M5]
  defend    Apply agent-authored defensive payload (ModSec, FW, sig)    [M6]
  clean     Apply agent-prescribed remediation (diff-confirmed)         [M7]
  setup     Provision or sync the Anthropic workspace                   [M8]

Options:
  -h, --help       show this message
  -v, --version    show bl version

Environment:
  ANTHROPIC_API_KEY  (required)  your Anthropic workspace API key
  BL_LOG_LEVEL       (optional)  one of {debug,info,warn,error} — default info
  BL_REPO_URL        (optional)  alternate git repo for skill content

Exit codes: docs/exit-codes.md
Design spec: DESIGN.md
$ echo $?
0
```

### Example 3: `bl observe` on unseeded workspace (no `$ANTHROPIC_API_KEY`)

```
$ unset ANTHROPIC_API_KEY
$ bl observe
blacklight: preflight: ANTHROPIC_API_KEY not set
$ echo $?
65
```

### Example 4: `bl observe` with key set but workspace unseeded

```
$ export ANTHROPIC_API_KEY="sk-ant-..."
$ bl observe
blacklight: this Anthropic workspace has not been seeded.

Run one of the following (one-time per workspace):

  # Local clone:
  bl setup

  # Direct from OSS repo:
  curl -fsSL https://raw.githubusercontent.com/rfxn/blacklight/main/bl | bash -s setup

After setup completes the first host's worth of provisioning,
every subsequent host running 'bl' against the same API key
finds the workspace pre-seeded and skips this step.
$ echo $?
66
```

### Example 5: `bl observe` with workspace seeded (agent-id cached) — handler stub hit

```
$ echo "agent_abc123" > /var/lib/bl/state/agent-id   # simulated seeded state
$ bl observe
blacklight: observe not yet implemented (M4)
$ echo $?
64
```

### Example 6: `bl unknown-verb`

```
$ bl fnord
blacklight: usage: unknown command: fnord
(use `bl --help` for a list of commands)
$ echo $?
64
```

## 6. Conventions

### 6.1 File header

```bash
#!/bin/bash
#
# bl — blacklight operator CLI
#
# Copyright (C) 2026 R-fx Networks <proj@rfxn.com>
# Author: Ryan MacDonald <ryan@rfxn.com>
# License: GNU GPL v2
#
# Part of the blacklight project — defensive post-incident Linux forensics
# on the substrate the defender already owns. See DESIGN.md for architecture,
# PIVOT-v2.md for strategy, README.md for operator-facing overview.
#
# This is a single-file bash wrapper. It is curl-pipeable per DESIGN.md §8.3
# and must not `source` external helpers.

set -euo pipefail
```

### 6.2 Strict mode

Top of `bl`:

```bash
set -euo pipefail
```

Rationale: rfxn-standard strict mode; unbound variables are bugs; pipefail surfaces `curl | jq` failures that would otherwise mask on curl exit.

### 6.3 Exit-code constants

Every exit code is a `readonly` constant, not a literal:

```bash
readonly BL_EX_OK=0
readonly BL_EX_USAGE=64
readonly BL_EX_PREFLIGHT_FAIL=65
readonly BL_EX_WORKSPACE_NOT_SEEDED=66
readonly BL_EX_SCHEMA_VALIDATION_FAIL=67    # M4+ uses; M1 declares
readonly BL_EX_TIER_GATE_DENIED=68           # M4+ uses; M1 declares
readonly BL_EX_UPSTREAM_ERROR=69
readonly BL_EX_RATE_LIMITED=70
readonly BL_EX_CONFLICT=71                   # M8 uses; M1 declares
readonly BL_EX_NOT_FOUND=72                  # M5+ uses; M1 declares
```

All 10 declared in M1 so handlers in M4–M8 don't re-declare. Unused-in-M1 constants are not a lint failure (shellcheck's SC2034 disable directive applied at declaration site with same-line comment: `# shellcheck disable=SC2034  # consumed by later motions`).

### 6.4 Coreutils prefix

All coreutils in `bl` use `command` prefix per workspace CLAUDE.md §Shell Standards §command prefix:

```bash
command mkdir -p "$BL_STATE_DIR"
command cat "$BL_CASE_CURRENT_FILE"
```

Exception: `printf` and `echo` are bash builtins — used bare. `[` / `[[` are builtins. `$()` arithmetic uses bash-native `$(())` / `(( ))`.

### 6.5 `cd` guard

Every `cd` must have an explicit `|| exit <code>` guard. Exit code is context-dependent:

- **Inside `bl_preflight` or other pre-dispatch setup**: `exit "$BL_EX_PREFLIGHT_FAIL"` (65).
- **Inside handler functions (M4–M8), for operator-supplied paths**: `exit "$BL_EX_USAGE"` (64).
- **Inside handler functions, for expected-to-exist paths that are missing**: `exit "$BL_EX_NOT_FOUND"` (72).

Template (preflight context):
```bash
cd "$target" || { bl_error_envelope preflight "cannot cd to $target"; exit "$BL_EX_PREFLIGHT_FAIL"; }
```

M1 source has no `cd` calls in handler stubs (they return 64 immediately), so only the preflight-context rule exercises in M1. The broader convention is documented here so M4–M8 authors don't default to `PREFLIGHT_FAIL` by rote.

### 6.6 Error envelope format

`bl_error_envelope <phase> <problem> [remediation]`:

```
blacklight: <phase>: <problem>
<remediation?>
```

Examples of phase strings (M1 scope): `preflight`, `usage`. M4+ adds: `observe`, `consult`, `run`, `defend`, `clean`, `setup`, `case`, `schema`.

### 6.7 Logging prefix

`bl_info` / `bl_warn` / `bl_error` / `bl_debug`:

```
[bl] INFO: <msg>
[bl] WARN: <msg>
[bl] ERROR: <msg>
[bl] DEBUG: <msg>
```

All to stderr. `$BL_LOG_LEVEL` default: `info`. Order: `debug < info < warn < error`. Debug is no-op at default level.

## 7. Interface Contracts

### 7.1 CLI surface

Introduced by M1:

- `bl --help` / `bl -h` / `bl help` — usage block, exit 0.
- `bl --version` / `bl -v` — version string, exit 0.
- `bl <namespace> [args...]` — dispatches to `bl_<namespace>`; M1 stubs return 64.

All flag short forms: `-h`, `-v`. No `--verbose`, `--quiet`, `--log-level` CLI flags (env-var only in M1).

### 7.2 Environment contract

| Variable | Required | Default | Purpose |
|---|---|---|---|
| `ANTHROPIC_API_KEY` | yes | — | Workspace auth. Preflight exits 65 if unset. |
| `BL_VAR_DIR` | no | `/var/lib/bl` | Local state root. Override for test isolation. |
| `BL_LOG_LEVEL` | no | `info` | One of `debug`, `info`, `warn`, `error`. |
| `BL_REPO_URL` | no | — | Alt git URL for setup skill-source discovery (M8 consumer; M1 declares the slot only). |
| `BL_HOST_LABEL` | no | `hostname -s` | Observation-envelope `host` field (M4 consumer; not referenced in M1). |
| `BL_SLACK_WEBHOOK` | no | — | `auto` tier notification target (M6 consumer; M1 declares slot). |

### 7.3 File contract (local state)

Created by M1:

- `/var/lib/bl/state/agent-id` — first-line plain-text agent id. Created on successful preflight probe.

Declared-but-not-created by M1 (paths reserved for M4–M8):

- `/var/lib/bl/state/case.current`
- `/var/lib/bl/{backups,quarantine,fp-corpus,outbox,ledger}/`

### 7.4 Exit-code contract (M1 subset)

Used by M1: `0`, `64`, `65`, `66`. Declared as constants but not emitted in M1: `67`, `68`, `69`, `70`, `71`, `72`.

### 7.5 Wire contract (API)

`bl_api_call` issues HTTPS requests against `https://api.anthropic.com` with headers:

```
x-api-key: $ANTHROPIC_API_KEY
anthropic-version: 2023-06-01
anthropic-beta: managed-agents-2026-04-01
content-type: application/json
```

Per `docs/setup-flow.md §4` preamble. Only endpoint called in M1 is `GET /v1/agents?name=bl-curator` (via `bl_preflight`).

## 8. Migration Safety

### 8.1 Install path

M1 does not add a packaging entry — `bl` is runnable from the repo root as `./bl` and curl-pipeable per `DESIGN.md §8.3`. Packaging is M10.

### 8.2 Upgrade path

N/A. No prior tracked `bl` exists on `main`. `bl-ctl` is removed in the same commit; operators running the v1 Flask curator are on the `legacy-pre-pivot` tag and will not experience a break.

### 8.3 Rollback

`git revert <bl-landing-commit>` restores `bl-ctl` and removes `bl` + `tests/`. The tag `legacy-pre-pivot` remains the durable v1 recovery point.

### 8.4 Backward compatibility

N/A. `bl` is greenfield. `bl-ctl` removal is intentional; the operator command surface is documented exclusively by `bl --help` going forward.

### 8.5 Uninstall

`rm /path/to/bl` + `rm -rf /var/lib/bl`. No daemons, no services, no symlinks outside the repo.

## 9. Dead Code and Cleanup

Removed in the same commit that lands `bl`:

| File | Reason |
|---|---|
| `bl-ctl` | References deleted `curator/storage/cases/` path and `http://localhost:8080` curator server. Both deleted at commit `694b0cf` (legacy-drop). |

No other dead code identified. Governance-layer files (`.rdf/governance/*.md`) reference `bl-ctl` — they are working files (in `.git/info/exclude`) and will be updated in the same session as part of `/r-refresh` post-M1, not in M1's commit.

## 10a. Test Strategy

`tests/infra/` is the batsman submodule at `v1.4.2`. Tests under `tests/*.bats` consume batsman via `tests/run-tests.sh` + `tests/Makefile` + `tests/Dockerfile`. `tests/helpers/bl-preflight-mock.bash` stubs the Anthropic API for preflight tests — zero network in CI.

| Goal | Test file | Test description |
|---|---|---|
| G1 (bash -n) | `tests/00-smoke.bats` | `@test "bl parses clean with bash -n"` |
| G1 (shellcheck) | `tests/01-cli-surface.bats` | `@test "shellcheck is clean"` |
| G2 (help surfaces) | `tests/01-cli-surface.bats` | 3 `@test`: `bl --help`, `bl help`, `bl -h` |
| G3 (version surfaces) | `tests/00-smoke.bats` + `tests/01-cli-surface.bats` | `@test "bl --version prints expected format"` + `@test "bl -v exits 0"` |
| G4 (7 namespace dispatch + unknown-verb) | `tests/01-cli-surface.bats` | 1 parameterised + 2 surface `@test` entries (7 namespaces iterated + unknown-verb + no-args) |
| G5 (preflight bootstrap paths) | `tests/02-preflight.bats` | 3 `@test`: unseeded→66, cached→0, seeded→cache+0 |
| G6 (preflight fail paths, distinct diagnostics) | `tests/02-preflight.bats` | 4 `@test`: no-key, empty-key, no-curl, no-jq |
| G7 (workdir init — state/ only by preflight) | `tests/02-preflight.bats` | implicit in G5 cached path + §10b verification |
| G8 (bl-ctl removed) | N/A (tree-state) — see §10b grep | — |
| G9 (tests/ scaffold) | N/A (meta: if tests run, scaffold exists) + §10b verification | — |
| G10 (matrix green) | `make -C tests test` + `make -C tests test-rocky9` (runs 00+01+02) | — |
| G11 (bash 4.1+ floor) | `tests/02-preflight.bats` | `@test "bl on bash <4.1 exits 65 (best-effort)"` — uses `bash -c 'BASH_VERSINFO=...; source ./bl'`; skips if VERSINFO override doesn't propagate. Full cross-bash coverage is M10 platform matrix. |
| G12 (no numeric exit literals) | N/A (source-level) — see §10b grep | — |

Total `@test` entries: 2 (smoke) + 10 (cli-surface) + 9 (preflight) = **21**.

## 10b. Verification Commands

Every command below has expected output. Run from repo root unless noted.

**G1 — lint clean:**
```bash
bash -n bl
# expect: (no output, exit 0)

shellcheck bl
# expect: (no output, exit 0)
```

**G2 — help surfaces:**
```bash
bl --help | grep -c '^  observe\|^  consult\|^  run\|^  case\|^  defend\|^  clean\|^  setup'
# expect: 7

bl help >/dev/null && echo OK
# expect: OK

bl -h >/dev/null && echo OK
# expect: OK
```

**G3 — version surfaces:**
```bash
bl --version
# expect: bl 0.1.0

bl -v
# expect: bl 0.1.0
```

**G4 — namespace dispatch (pre-seed agent-id to pass preflight):**
```bash
export BL_VAR_DIR=$(mktemp -d)
command mkdir -p "$BL_VAR_DIR/state"
printf '%s' "agent_test_stub" > "$BL_VAR_DIR/state/agent-id"
export ANTHROPIC_API_KEY="sk-ant-test"
for ns in setup observe consult run defend clean case; do
    bl "$ns" > /dev/null 2>&1
    rc=$?
    [[ "$rc" -eq 64 ]] || echo "FAIL: $ns returned $rc"
done
command rm -rf "$BL_VAR_DIR"
# expect: (no output — all 7 namespaces return 64)
```

Note: `bl setup` bypasses preflight (same class as help/version per §4.3), so the pre-seed above is ignored for setup — but setup's stub still returns 64. Preflight IS exercised for the other 6.

**G5 — unseeded preflight (uses preflight mock to avoid live API):**
```bash
export BL_VAR_DIR=$(mktemp -d)
export ANTHROPIC_API_KEY="sk-ant-test"
# Load the preflight mock, configure empty-agent-list response
source tests/helpers/bl-preflight-mock.bash
bl_mock_set_response empty
out=$(bl observe 2>&1)
rc=$?
printf '%s\n' "$out" | head -1
# expect: blacklight: this Anthropic workspace has not been seeded.
echo "rc=$rc"
# expect: rc=66
command rm -rf "$BL_VAR_DIR"
```

Capturing `rc` from a non-piped invocation; `head -1` is applied to the captured output, not to `bl`'s live stream. This avoids the `$?` after pipeline discarding the real exit code.

**G6 — preflight fail paths (each distinct diagnostic):**
```bash
# Case A: ANTHROPIC_API_KEY unset
unset ANTHROPIC_API_KEY
out=$(bl observe 2>&1)
rc=$?
printf '%s\n' "$out"
# expect: blacklight: preflight: ANTHROPIC_API_KEY not set
echo "rc=$rc"
# expect: rc=65

# Case B: ANTHROPIC_API_KEY empty
export ANTHROPIC_API_KEY=""
out=$(bl observe 2>&1)
rc=$?
printf '%s\n' "$out"
# expect: blacklight: preflight: ANTHROPIC_API_KEY empty
echo "rc=$rc"
# expect: rc=65

# Case C: curl missing (PATH stripped)
export ANTHROPIC_API_KEY="sk-ant-test"
out=$(PATH="/bin:/usr/bin" bl observe 2>&1)   # adjust PATH to exclude curl
# expect first line: blacklight: preflight: curl not found (required for API calls)
# expect rc: 65 (see case A/B pattern above for the rc=$? pattern)
```

**G7 — workdir init (preflight creates state/ only):**
```bash
export BL_VAR_DIR=$(mktemp -d)
bl --version >/dev/null   # flag-bypass: does NOT touch workdir
ls -A "$BL_VAR_DIR"
# expect: (empty output)

export ANTHROPIC_API_KEY="sk-ant-test"
bl observe 2>/dev/null   # preflight fires, creates state/
# (expect exit 65 or 66; we're verifying the mkdir side-effect not the exit)
ls -A "$BL_VAR_DIR"
# expect: state

# G7 also requires bl_init_workdir to NOT fire on preflight path:
ls -A "$BL_VAR_DIR/state/"
# expect: (empty — or agent-id if API was reachable; crucially, no backups/ quarantine/ etc.)
[[ ! -d "$BL_VAR_DIR/backups" ]] && echo OK
# expect: OK
[[ ! -d "$BL_VAR_DIR/quarantine" ]] && echo OK
# expect: OK
command rm -rf "$BL_VAR_DIR"
```

**G8 — bl-ctl removed:**
```bash
git ls-files bl-ctl
# expect: (no output)

[[ ! -f bl-ctl ]] && echo OK
# expect: OK
```

**G9 — tests/ scaffold (note: `.gitignore` is a dotfile, hidden by plain `ls`):**
```bash
ls -A tests/
# expect (one per line; order may differ): .gitignore 00-smoke.bats 01-cli-surface.bats 02-preflight.bats Dockerfile Makefile helpers infra run-tests.sh

ls tests/helpers/
# expect: bl-preflight-mock.bash

git config --file .gitmodules submodule.tests/infra.url
# expect: https://github.com/rfxn/batsman.git

git -C tests/infra describe --tags --exact-match HEAD
# expect: v1.4.2

[[ -f tests/infra/include/Makefile.tests ]] && echo OK
# expect: OK
```

**G10 — test matrix (run on anvil, not freedom, per CLAUDE.md §Testing):**
```bash
DOCKER_HOST=tcp://192.168.2.189:2376 DOCKER_TLS_VERIFY=1 DOCKER_CERT_PATH=~/.docker/tls \
    make -C tests test 2>&1 | tail -5
# expect: last line shows "ok" or "# tests <N>" with no "not ok"

DOCKER_HOST=tcp://192.168.2.189:2376 DOCKER_TLS_VERIFY=1 DOCKER_CERT_PATH=~/.docker/tls \
    make -C tests test-rocky9 2>&1 | tail -5
# expect: same shape, no "not ok"
```

**G11 — bash 4.1+ floor (source-level presence check + placement check):**
```bash
# Presence:
grep -nE 'BASH_VERSINFO\[0\].*\*.*100.*\+.*BASH_VERSINFO\[1\]' bl
# expect: at least one match line (top-level floor check)

# Placement: floor check must be above any function definition.
# Extract line number of floor check and of first function def; floor must come first.
floor_line=$(grep -nE 'BASH_VERSINFO\[0\].*\*.*100' bl | head -1 | cut -d: -f1)
first_fn_line=$(grep -nE '^[a-z_]+\(\)\s*\{' bl | head -1 | cut -d: -f1)
[[ "$floor_line" -lt "$first_fn_line" ]] && echo OK
# expect: OK
```

**G12 — no numeric exit literals:**
```bash
grep -nE '\b(exit|return)\s+[0-9]+\b' bl | grep -vE 'BL_EX_|return 0'
# expect: (no output — every non-zero exit/return cites a BL_EX_* constant, return 0 is permitted sentinel)
```

## 11. Risks

1. **Risk: batsman submodule breakage.** Batsman v1.4.2 is a remote submodule — network-fetch failure or repository rename breaks `make -C tests test`.
   **Mitigation:** Submodule pinned to a release tag (not branch HEAD); `tests/infra/` commit is recorded in `.gitmodules` + `tests/infra` gitlink. Recovery: `git submodule update --init tests/infra`.

2. **Risk: shellcheck disables create cover for real issues.** `SC2034` is disabled on unused exit-code constants.
   **Mitigation:** Each disable directive carries a same-line comment citing the consumer motion (`# shellcheck disable=SC2034 # consumed by M<N>`). Post-M8, grep for `SC2034` disables where the consumer motion has landed — they should be gone.

3. **Risk: DESIGN.md §8.1 preflight sketch drift from implementation.** The heredoc in M1's `bl_preflight` may diverge from `DESIGN.md §8.1` line 440.
   **Mitigation:** M1 implementation copies the heredoc text verbatim from DESIGN.md §8.1; `tests/01-cli-surface.bats` asserts the message begins with `blacklight: this Anthropic workspace has not been seeded.` — any edit to DESIGN.md §8.1 requires a matching M1 change in the same commit.

4. **Risk: `BL_VAR_DIR` override race in tests.** BATS `setup()` sets `BL_VAR_DIR=$(mktemp -d)`; parallel BATS runs may collide on `/var/lib/bl` if an env leak occurs.
   **Mitigation:** Every `@test` sets `BL_VAR_DIR` explicitly in `setup()`; `teardown()` `rm -rf "$BL_VAR_DIR"`. `bl` itself reads `$BL_VAR_DIR` with `${BL_VAR_DIR:-/var/lib/bl}` so unset env falls through safely; test leak caught by trap.

5. **Risk: `bl_api_call` retry loop infinite-loops on malformed responses.** A `jq` failure inside retry logic could cause silent hang.
   **Mitigation:** Retry count is capped at 3; each iteration logs via `bl_debug`; timeout per curl call is 30s via `curl --max-time 30`. `jq` failure → `bl_error_envelope` + exit 69. No bare `while true` loops.

6. **Risk: bash 4.1+ floor check fires on bash 3.x before check runs.** The floor-check uses `BASH_VERSINFO` which is a 3.0+ feature; if someone runs on bash 3.2 (macOS default), the check works, but bash 2.x (historical Solaris, AIX) has no `BASH_VERSINFO` and would syntax-fail on `readonly` or `local -A`.
   **Mitigation:** Bash 2.x is out of platform scope per `DESIGN.md §14.1` (CentOS 6 floor). `bl` does not attempt to run on bash <4.1 cleanly — it either trips the floor check (≥3.0) or syntax-fails at parse time (<3.0). Both are acceptable failure modes; the target platforms all ship bash ≥ 4.1.

7. **Risk: curl-pipeable install path breaks if `bl` ever grows a `source` directive.** `curl -fsSL .../bl | bash -s setup` assumes self-contained.
   **Mitigation:** File-map section prohibits `source`. Verification: `grep -n '^source\|^\. ' bl` returns 0 in §10b. Future motions (M4–M10) inherit the constraint.

8. **Risk: DESIGN.md §5.8 + §8.1 one-line edits land in the wrong commit.** If M1's main commit lands without the DESIGN.md fixes, readers of DESIGN.md §8.1 will see stale `return 64` and assume it's authoritative; this creates a spec-code contradiction even after M1 merges.
   **Mitigation:** §4.1 file map lists `DESIGN.md` with **modify (2 lines)** status. `/r-plan` will schedule the DESIGN.md edit as part of the same phase that lands `bl`. Verification: `git log -p --format= DESIGN.md | grep -c 'return 6[46]'` in the M1 commit delta must show both the `-return 64` removal and the `+return 66` addition.

9. **Risk: `tests/helpers/bl-preflight-mock.bash` mock shape diverges from actual Anthropic API response.** If the mock returns a synthetic `{"data":[{"id":"agent_test"}]}` shape but the real API's `GET /v1/agents` response differs (e.g., wraps the list differently, uses camelCase, etc.), `bl_preflight`'s jq filter passes in tests but fails in production.
   **Mitigation:** Mock shape is authored from `docs/setup-flow.md §8 provenance notes` which records the verbatim 2026-04-24 HTTP transcript. Verification: `tests/helpers/bl-preflight-mock.bash` header comment cites the source-of-truth line in setup-flow.md §8. A post-M1 commit in M8 (`bl setup`) reverifies the mock against a live probe; any drift is caught then.

10. **Risk: bash 4.1+ floor check at top-level means `readonly` declarations are parsed on old bash before the check fires.** `readonly` is a bash 2.0+ builtin so this is fine; but if M9 ever adds `declare -A` at top-level, bash 3.x parses and fails before reaching the floor-check arithmetic.
    **Mitigation:** M1 top-level has only `readonly` + arithmetic `(( ))` + `printf` + `exit` — all bash 3.0+ safe. No `declare -A`, no associative arrays, no `mapfile -d`. Future motions inherit this constraint: anything added above the floor check must be 3.0-safe. Risk reopens only if this rule is violated in M9+.

## 11b. Edge Cases

| # | Scenario | Expected behavior | Handling |
|---|---|---|---|
| 1 | `$BL_LOG_LEVEL` set to invalid value (`"spam"`) | Treat as `info` (default); emit `bl_warn` once at entry | `bl_info`/`bl_warn` fallthrough: comparator `case "$BL_LOG_LEVEL"` default branch sets internal level to `info` |
| 2 | `/var/lib/bl` exists but is read-only (mounted RO, permission denied) | Exit 65 with `blacklight: preflight: /var/lib/bl not writable` | `bl_init_workdir` tests writability via `command touch "$BL_VAR_DIR/.wtest" 2>/dev/null` before other mkdir work; `bl_preflight` likewise probes `$BL_VAR_DIR` writability before its `mkdir -p "$BL_STATE_DIR"` |
| 3 | `jq` missing but `curl` present | Exit 65 with `blacklight: preflight: jq not found (required for JSON parsing)` | `bl_preflight` tests `command -v jq` explicitly after `command -v curl` |
| 4 | `$ANTHROPIC_API_KEY` set to empty string | Exit 65 with `blacklight: preflight: ANTHROPIC_API_KEY empty` | Preflight tests `[[ -n "$ANTHROPIC_API_KEY" ]]` not just `-v` |
| 5 | `bl setup` invoked with valid key, unseeded workspace | `bl_setup` stub returns 64 (`setup not yet implemented (M8)`) — the heredoc bootstrap message does NOT fire because `bl_setup` is a verb, not preflight | Dispatcher: preflight only runs for non-setup verbs; `setup` is a pre-case bypass just like help/version. |
| 6 | Cached agent-id file exists but is empty | Treat as unseeded (cache miss); re-probe API; if API returns empty, bootstrap-heredoc + 66 | `bl_preflight` reads `$BL_AGENT_ID_FILE` and tests `[[ -n "$BL_AGENT_ID" ]]` |
| 7 | Cached agent-id file exists with stale UUID (workspace rotated) | Preflight succeeds based on cache, first real handler call (M4+) hits 4xx; M1 handlers are stubs so this never exercises. M5+ bl_api_call traps 401 → 65 + hint to rm cache | M1 declares `bl_api_call` shape; M5 consumes and adds the 401-handling path. M1 test does not cover this scenario. |
| 8 | `bl` run as non-root user without `/var/lib/bl` permission | `bl_init_workdir` exits 65 with writability diagnostic | Same path as edge 2 |
| 9 | `bl` invoked with no arguments | Print short usage hint to stderr, exit 64 | `main` with empty `$#` → `bl_error_envelope usage "no command (use \`bl --help\` for a list)"` + `exit "$BL_EX_USAGE"` |
| 10 | `bl` invoked with valid namespace but unknown sub-verb (e.g. `bl observe fnord`) | Dispatch reaches `bl_observe`, which is a stub and returns 64 with generic `observe not yet implemented` message — it does not attempt to parse sub-verbs | M1 handler stubs do not parse args; M4 adds sub-verb parsing for `observe` |
| 11 | Long-running `bl_poll_pending` interrupted with Ctrl-C (SIGINT) | Shell exits 130 (128+2); no partial state left in `$BL_VAR_DIR` | No trap handlers in M1; `set -e` + default signal handling is sufficient. M5 adds case-level trap for cleanup. |
| 12 | `bl` invoked via `bash -s` (curl pipe) with `set -euo pipefail` inheritance from parent shell | Parent shell state has no effect; `bl` sets its own strict mode at top | `set -euo pipefail` near top of `bl`, before any `readonly` declarations |

## 12. Open Questions

None. Directional approval per vpe-progress.md covers all load-bearing decisions (Q1–Q10 in `.rdf/work-output/spec-progress.md`).

---

*End of M1 bl-skeleton design spec. Handoff to `/r-plan` for decomposition into phases.*
