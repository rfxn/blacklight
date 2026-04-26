# state.json — schema v1

`$BL_STATE_DIR/state.json` is the single consolidated state file for a blacklight
workspace. It replaces the previous per-key files (`agent-id`, `env-id`,
`memstore-skills-id`, `memstore-case-id`, `case-id-counter`, `case.current`,
`session-<id>` files). First-run migration is performed automatically by
`bl_setup_load_state` on the first call after upgrade.

**Authoritative implementations:** `src/bl.d/84-setup.sh`
- `bl_setup_load_state` — read + first-run migration (line range: search for
  `^bl_setup_load_state`)
- `bl_setup_save_state` — atomic write via tmp + mv (line range: search for
  `^bl_setup_save_state`)

---

## Atomic-write convention

All writes to `state.json` follow this pattern to prevent partial-write corruption:

```
jq -n ... > "$state_file.tmp.$$"
command mv "$tmp_state" "$state_file"
```

The `$$`-suffixed temp file is process-local. `mv` is atomic on POSIX-compliant
filesystems (same-device rename). `bl_setup_load_state` validates the existing file
with `jq -e '.schema_version == 1'` before reading — a truncated or corrupt file
fails the check and returns `BL_EX_PREFLIGHT_FAIL` (65) with an operator hint.

---

## Schema (v1)

```json
{
  "schema_version": 1,
  "agent": {
    "id": "agent_01ABCFIXTUREAGT",
    "version": 0,
    "skill_versions": {
      "adobe/apsb25-94-polyshell.md": "abc123def456"
    }
  },
  "env_id": "env_01ABCFIXTUREENV",
  "skills": {
    "adobe/apsb25-94-polyshell.md": "abc123def456"
  },
  "files": {
    "uploads/case-brief-CASE-2025-0001.pdf": "file_01ABCFIXTUREFILE"
  },
  "files_pending_deletion": [
    "file_01ABCFIXTURE_OLD"
  ],
  "case_memstores": {
    "_legacy": "memstore_01ABCFIXTURECASE"
  },
  "case_files": {
    "CASE-2025-0001": "file_01ABCFIXTUREFILE"
  },
  "case_id_counter": {},
  "case_current": "",
  "session_ids": {
    "CASE-2025-0001": "session_01ABCFIXTURE"
  },
  "last_sync": "2025-04-24T10:00:00Z"
}
```

---

## Field reference

| Field | Type | Written by | Purpose |
|-------|------|-----------|---------|
| `schema_version` | integer | `bl_setup_save_state` | Schema migration guard. Always 1 in this release. |
| `agent.id` | string | `bl_setup_save_state` | Managed Agents agent ID (`agent_...`). |
| `agent.version` | integer | `bl_setup_save_state` | Curator model version index. 0 = unknown/pre-Path-C. Bumped by `bl setup --sync` after model probe. |
| `agent.skill_versions` | object | Phase 6 `bl setup --sync` | Per-skill sha256 shard; keyed by relative path under `skills/`. |
| `env_id` | string | `bl_setup_save_state` | Managed Agents environment ID (`env_...`). |
| `skills` | object | Phase 6 `bl setup --sync` | Same shape as `agent.skill_versions`; canonical per-skill sha256 used by sync diff. |
| `files` | object | Phase 6+ | Files API upload tracking; key = logical name, value = file ID. |
| `files_pending_deletion` | array | Phase 6+ | File IDs queued for deletion on next `bl setup --gc`. |
| `case_memstores` | object | `bl_setup_save_state` (migration path) | Case memstore IDs. `_legacy` key used during migration from old `memstore-case-id` file. Phase 6 renames to per-case keys. |
| `case_files` | object | Phase 6+ | Per-case file ID mapping; key = `CASE-YYYY-NNNN`. |
| `case_id_counter` | object or integer | Migration path | Migrated from `case-id-counter` per-key file. Managed by `bl case` in Phase 6+. |
| `case_current` | string | Migration path | Migrated from `case.current` per-key file. Active case handle for `bl case --resume`. |
| `session_ids` | object | Phase 6+ | Per-case session ID map; key = `CASE-YYYY-NNNN`, value = session ID. |
| `last_sync` | string | `bl_setup_save_state` | ISO-8601 UTC timestamp of last successful `bl_setup_save_state` call. Empty string if never saved. |

---

## Shell variables populated by `bl_setup_load_state`

After a successful call to `bl_setup_load_state`, these globals are set:

| Variable | Source field |
|----------|-------------|
| `BL_STATE_AGENT_ID` | `.agent.id` |
| `BL_STATE_AGENT_VERSION` | `.agent.version` |
| `BL_STATE_ENV_ID` | `.env_id` |
| `BL_STATE_MEMSTORE_CASE_ID` | `.case_memstores | to_entries[0].value` |
| `BL_STATE_LAST_SYNC` | `.last_sync` |

Phase 6 callers consume these after `bl_setup_load_state` returns 0.

---

## First-run migration

On the first call to `bl_setup_load_state` after upgrading from a pre-Path-C
workspace (one that has `agent-id`, `env-id`, etc. but no `state.json`):

1. Per-key files are read: `agent-id`, `env-id`, `memstore-skills-id`,
   `memstore-case-id`, `case-id-counter`, `case.current`.
2. `state.json` is written atomically (via tmp + mv) with all values consolidated.
3. Old per-key files are deleted: `agent-id`, `env-id`, `memstore-skills-id`,
   `memstore-case-id`, `case-id-counter`, `case.current`.
4. The `memstore-skills-id` value is **intentionally orphaned** in state.json (the
   `bl-skills` memstore is retired in Path C — skills now live in the agent's
   built-in memory). The value is dropped after migration; it is not preserved in
   any `state.json` field.

If all four identity files are absent, the workspace is treated as a fresh install:
`state.json` is created with empty identity fields, ready for `bl setup` to
provision.

---

## Error handling

| Condition | Exit code | Operator hint |
|-----------|-----------|--------------|
| `state.json` present but `schema_version != 1` or invalid JSON | 65 (`BL_EX_PREFLIGHT_FAIL`) | `"state.json malformed or schema_version != 1: <path>"` → run `bl setup --reset --force` then `--sync` |
| `$BL_STATE_DIR` not writable | 65 (`BL_EX_PREFLIGHT_FAIL`) | `"$BL_VAR_DIR not writable"` |
