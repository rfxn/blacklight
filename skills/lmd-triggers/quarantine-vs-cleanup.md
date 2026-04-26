# quarantine-vs-cleanup — LMD Already Quarantined

**The critical rule:** when a case is opened by `bl trigger lmd`, LMD has already
quarantined the flagged files before the hook fires. Do NOT propose `bl clean file`
or `bl clean htaccess` on paths that LMD has isolated — the files are already moved
to LMD's quarantine directory. Proposing a second clean on a quarantined path will
fail (file not at original path) and produce a confusing ledger entry. The curator's
job is to investigate the infection scope and apply defensive artifacts — not to
quarantine again.

---

## 1. What LMD does before the hook fires

LMD's scan-and-quarantine sequence, in order:

1. Scan completes; hits written to session-file TSV.
2. Quarantine action: each flagged file moved to
   `/usr/local/maldetect/quarantine/<sha256>` (or the configured quarantine path).
3. `post_scan_hook` fires with `LMD_SESSION_FILE`, `LMD_SCANID`, `LMD_HITS`.

By the time `bl trigger lmd` runs, the files in the TSV are already quarantined.
The paths in the TSV are the **original paths** — those files no longer exist at
those locations.

---

## 2. What bl clean does

`bl clean file` removes a file from its current path after showing a diff or
confirming the path is non-empty. It writes a `clean_apply` ledger entry with
the original path and a backup under `/var/lib/bl/backups/`.

If the file is already quarantined (not at original path), `bl clean file` will:
- Find no file at the original path (the LMD TSV path).
- Return `BL_EX_NOT_FOUND` (exit 72).
- Write a `preflight_fail` ledger entry — confusing for operators reviewing the
  case log.

The curator must not propose `bl clean file <path>` for paths appearing in a
hook-triggered case's TSV unless evidence confirms the file was NOT quarantined
by LMD (e.g., degraded path where LMD failed to quarantine).

---

## 3. What the curator should propose instead

For hook-triggered cases where LMD quarantine is confirmed:

| Goal | Correct action |
|---|---|
| Confirm file is isolated | `observe.file <path>` — result will show absence; record absence as positive evidence of successful quarantine |
| Understand what was dropped | Inspect quarantine directory via `observe.file /usr/local/maldetect/quarantine/<sha256>` — non-destructive read of quarantined content |
| Apply defensive rule to block future drops | `defend.modsec` or `defend.sig` — proactive, not reactive |
| Check for reinfection (LMD missed a variant) | `observe.fs_mtime_since` on writable dirs with T_cluster as the since boundary |
| Operator wants to unquarantine a FP | This is an LMD operation, not a bl operation. Direct operator to `maldet --restore <sha256>`. bl does not have an unquarantine verb for LMD quarantine. |

---

## 4. Identifying the quarantine state in the ledger

The `lmd_hook_received` ledger event carries the `LMD_HITS` count and scanid.
LMD's own quarantine log is outside the bl ledger — bl does not have direct
visibility into whether LMD succeeded in quarantining each file.

To determine quarantine state within a bl case turn:

1. Propose `observe.file <path>` on one hit path from the TSV.
2. If the file is absent at the original path: LMD quarantine succeeded.
3. If the file is present at the original path: one of:
   - LMD quarantine failed (check LMD logs: `/usr/local/maldetect/log/event_log`).
   - The file was replaced by re-infection after LMD quarantined the first copy.
   - The TSV path is a symlink target that survived quarantine of the symlink.

For case 3 (file present after expected quarantine): `bl clean file` is now
appropriate — the file exists and has not been isolated.

---

## 5. Degraded path

The degraded path applies when `bl trigger lmd` opens a stub case because the
session-file was empty or unreadable at hook time. In the degraded path:

- LMD quarantine may or may not have succeeded (unknown state).
- The TSV is unavailable, so there are no known paths.
- The curator should propose `observe.log_apache` and `observe.fs_mtime_since`
  to reconstruct what was dropped, then inspect each discovered path with
  `observe.file` before proposing any clean.

---

## 6. Reinfection vs. fresh drop

After a hook-triggered case is open and the initial quarantine is confirmed,
check for reinfection before closing:

1. Propose `observe.fs_mtime_since` on the same directory tree with timestamp
   = T_last_quarantine + 60 seconds.
2. If new files appear: reinfection or a surviving dropper re-launched. Open a
   new round of `observe.file` on each new path.
3. If no new files: quarantine held. Proceed to defend.modsec or defend.sig to
   prevent future drop.

Reinfection within minutes of quarantine signals a persistence mechanism (cron,
`.htaccess` Auto_Prepend_File, or a second dropped loader) that LMD did not
catch. The follow-on investigation uses `observe.cron` and `observe.htaccess`
before concluding the case.

---

## Pointers

- `skills/lmd-triggers/SKILL.md` — hook router and first-turn checklist
- `skills/lmd-triggers/from-post-scan-hook.md` — TSV-to-kill-chain backwalk
- `/skills/foundations.md` — case lifecycle and adversarial-content handling
- `/skills/synthesizing-evidence-corpus.md` — mtime clustering and timeline reconstruction
