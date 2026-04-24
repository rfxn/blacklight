# quarantine manifest — field documentation

Human-readable companion to `schemas/quarantine-manifest.json`. The JSON file is the validation wire format used by `tests/07-clean.bats`; this file carries the per-field documentation. Emitted by `_bl_clean_write_quarantine` (see `src/bl.d/83-clean.sh`) alongside every file moved under `/var/lib/bl/quarantine/<case_id>/`. Sidecar path: `/var/lib/bl/quarantine/<case_id>/<entry_id>.meta.json`.

## Field reference

### `entry_id` (string, required)
Basename of the quarantined file under `/var/lib/bl/quarantine/<case_id>/`. Format: `<sha256>-<basename>` where `<sha256>` is the full 64-hex sha256 of the file content and `<basename>` is the final path component of the original file with spaces replaced with `_`. The sha256 prefix allows the file to be identified by content alone, independent of the original path.

### `original_path` (string, required)
Absolute path of the source file before it was quarantined. Used by `bl clean --unquarantine` to restore the file to its original location.

### `sha256` (string, required)
Full 64-hex sha256 of the quarantined file content. Identical to the `entry_id` prefix — duplicated in the manifest for validation cross-check: `sha256sum /var/lib/bl/quarantine/<case_id>/<entry_id>` must match this value at `--unquarantine` time.

### `size_bytes` (integer, required)
File size in bytes at quarantine time.

### `uid` / `gid` (integer, required)
Numeric owner UID and GID of the source file at quarantine time. Restored by `--unquarantine` via `command chown`.

### `perms_octal` (string, required)
Permissions as a four-digit octal string (e.g. `"0644"`). Stored as string to preserve leading zero in JSON. Restored by `--unquarantine` via `command chmod`.

### `mtime_epoch` (integer, required)
Source file modification time in Unix epoch seconds, captured before the move. Informational — `--unquarantine` does not restore mtime to avoid masking the incident timestamp.

### `case_id` (string, required)
Active case-id at quarantine time (format `CASE-YYYY-NNNN`). Non-nullable: quarantine is always case-scoped because the quarantine path itself is `/var/lib/bl/quarantine/<case_id>/`. Handlers return `BL_EX_NOT_FOUND` (72) if no active case exists — no-case quarantine is a caller bug.

### `reason` (string-or-null, required)
Operator-supplied reason string passed via `--reason`. May be null: the CLI passes `""` when `--reason` is omitted, and `_bl_clean_write_quarantine` converts `""` to JSON null. Stored for audit trail purposes — not used by `--unquarantine` logic.

### `iso_ts` (string, required)
ISO-8601 UTC timestamp the file was quarantined (colons retained: `YYYY-MM-DDTHH:MM:SSZ`).

## Example

```json
{
  "entry_id": "a3f9c2d1e8b74f6a0d2e3c5b1a9f8e7d6c5b4a3f2e1d0c9b8a7f6e5d4c3b2a1-wp-cron.php",
  "original_path": "/home/site17/public_html/wp-cron.php",
  "sha256": "a3f9c2d1e8b74f6a0d2e3c5b1a9f8e7d6c5b4a3f2e1d0c9b8a7f6e5d4c3b2a1",
  "size_bytes": 4092,
  "uid": 1017,
  "gid": 1017,
  "perms_octal": "0644",
  "mtime_epoch": 1745469734,
  "case_id": "CASE-2026-0017",
  "reason": "polyglot PHP dropper matching apsb25-94 pattern",
  "iso_ts": "2026-04-24T04:27:15Z"
}
```
