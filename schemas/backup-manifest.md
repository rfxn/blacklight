# backup manifest — field documentation

Human-readable companion to `schemas/backup-manifest.json`. The JSON file is the validation wire format used by `tests/07-clean.bats`; this file carries the per-field documentation. Emitted by `_bl_clean_write_backup` (see `src/bl.d/83-clean.sh`) alongside every file written under `/var/lib/bl/backups/`. Sidecar path: `/var/lib/bl/backups/<backup_id>.meta.json`.

## Field reference

### `backup_id` (string, required)
Filename of the backup file relative to `/var/lib/bl/backups/`. Format: `<ISO-ts>.<hash>.<basename>` where `<ISO-ts>` is `YYYY-MM-DDTHH-MM-SSZ` (colons replaced with hyphens for filesystem safety), `<hash>` is the first 8 hex chars of `sha256(original_path)`, and `<basename>` is the final path component of the source file (spaces replaced with `_`).

### `original_path` (string, required)
Absolute path of the source file at backup time. Used by `bl clean --undo` to restore.

### `sha256_pre` (string, required)
`sha256sum` of the source file content BEFORE the edit. Used by `tests/07-clean.bats` to assert backup integrity (sha256 of backup file on disk must equal this value at undo time — proves the backup has not been tampered with).

### `size_bytes` (integer, required)
Source file size in bytes, captured at backup time. Restored by `--undo` as part of the integrity assertion.

### `uid` / `gid` (integer, required)
Numeric owner UID and GID of the source file at backup time.

### `perms_octal` (string, required)
Permissions as a four-digit octal string (e.g. `"0644"`). Stored as string to preserve leading zero in JSON.

### `mtime_epoch` (integer, required)
Source file modification time in Unix epoch seconds.

### `case_id` (string-or-null, required)
Active case-id at backup time (format `CASE-YYYY-NNNN`), or null if no case was active. A null case_id is valid for `--undo` since the operator may run `bl clean htaccess --dry-run` outside any case for exploration; but `bl clean` live-apply in the default path rejects null case_id with exit 72.

### `verb` (string, required, enum)
One of `clean.htaccess` or `clean.cron`. Ties the backup to its originating verb for audit trails.

### `iso_ts` (string, required)
ISO-8601 UTC timestamp the backup was written (colons retained: `YYYY-MM-DDTHH:MM:SSZ`). The filename's `<ISO-ts>` field has colons replaced with hyphens for filesystem safety; this field preserves the canonical form.

## Example

```json
{
  "backup_id": "2026-04-24T04-27-15Z.d3a19f4c..htaccess",
  "original_path": "/home/site17/public_html/.htaccess",
  "sha256_pre": "9c3d8a1b2f4e...",
  "size_bytes": 1283,
  "uid": 1017,
  "gid": 1017,
  "perms_octal": "0644",
  "mtime_epoch": 1745469734,
  "case_id": "CASE-2026-0017",
  "verb": "clean.htaccess",
  "iso_ts": "2026-04-24T04:27:15Z"
}
```
