# Fleet-01 Expected Findings (Ground Truth)

Grading rubric for blacklight hunter output. Each host section enumerates what the hunters should surface during the live smoke and during the demo. Used for Day 2 checkpoint verification and Day 3+ regression sanity.

Source: reconstructed from public APSB25-94 advisory content; matches `exhibits/fleet-01/*-polyshell/` staged artifacts.

---

## host-2

Staged compromise: PolyShell variant at `pub/media/catalog/.cache/a.php`. Compose image: Apache + mod_security + Magento 2.4.x.

### fs_hunter should find

- **Category:** `unusual_php_path`
  **Finding shape:** a PHP file under a media/cache path, outside `vendor/` and `app/code/`
  **Source ref:** `fs/var/www/html/pub/media/catalog/.cache/a.php`
  **confidence:** 0.7 or higher

- **Category:** `mtime_cluster` (if multiple staged artifacts)
  **Finding shape:** a cluster of recently-modified PHP files within a tight window
  **Source refs:** staged PHP path(s)

### log_hunter should find

- **Category:** `url_evasion`
  **Finding shape:** GET requests targeting `.php/*.jpg` or `.php/*.png` or `.php/*.gif` — the APSB25-94 URL-evasion signature
  **Source refs:** log line numbers from `logs/var/log/apache2/access.log`
  **confidence:** 0.8 or higher

- **Category:** `url_evasion` (POST variant)
  **Finding shape:** POST requests to the shell path without double-extension — command-execution calls
  **Source refs:** log line numbers

### timeline_hunter should find

- **Category:** `causal_adjacency`
  **Finding shape:** fs finding on `a.php` + log finding on same path within seconds
  **Source refs:** fs finding id + log finding id
  **confidence:** 0.8 or higher

### Initial hypothesis (opened by orchestrator, Day 2 deterministic template)

- `case_id`: `CASE-2026-0007`
- `status`: `active`
- `hypothesis.current.summary`: contains "host-2" and one of {`unusual_php_path`, `url_evasion`, `causal_adjacency`}
- `hypothesis.current.confidence`: **exactly 0.4** (cap)
- `hypothesis.current.reasoning`: non-empty; cites at least 3 evidence IDs
- `hypothesis.history`: **empty list** (Day 3 populates)
- `evidence_threads.host-2`: non-empty list of UUIDs matching rows in evidence.db

### Negative assertions

- No findings against paths under `vendor/` or `pub/static/` (false-positive guard)
- No `case_engine.revise()` call made — Day 3 scope

---

## host-3 (clean, Nginx)

Clean host present in Compose. Day 2 does not dispatch hunters against host-3. No expected findings. Phase covered Day 4.

---

## host-4, host-5, host-7 (Day 3+ and Day 4+ scope)

Not staged in Day 2. See HANDOFF.md §"Day 3" / §"Day 4" / §"Day 5" / §"EXHIBITS.md §Build order" for staging plan.

---

## How this file is used

- **Day 2 live smoke (Phase 9):** operator reads the host-2 section before running the orchestrator; after running, compares `sqlite3 curator/storage/evidence.db 'SELECT hunter, category, finding FROM evidence'` against the expected shapes.
- **Day 3 revision test:** the hypothesis-revision unit test fixtures reference categories from this file. Drift here means fixture drift there.
- **Demo script:** the 0:35 beat ("Case opens: CASE-2026-0007, confidence 0.4...") echoes the initial-hypothesis shape above verbatim.
