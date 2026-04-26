# lmd-triggers — LMD Hook Router

**Scenario.** It is 02:47. A cPanel shared-hosting server runs LMD 1.6.4 with
`post_scan_hook` configured. LMD completes a scan, writes a 12-row TSV to
`/var/lib/maldetect/sessions/<scanid>`, and fires the hook. The
`/etc/blacklight/hooks/bl-lmd-hook` adapter runs `bl trigger lmd` with
`--scanid`, `--session-file`, and `--unattended`. Within 8 seconds a new
`bl-case` case is open with the cluster fingerprint in the ledger. The
curator is awake with LMD's evidence pre-loaded.

The non-obvious rule: LMD hits from the same scan always share a scanid —
the fingerprint deduplication is scanid-keyed. Two hooks from the same scan
(e.g., a partial-rescan after a timeout) produce `trigger_dedup_attached`
and do not open a duplicate case. Two hooks from *different* scans with the
same hit files will have different scanids and therefore different fingerprints
— they open new cases even if the malware is identical. The curator must not
conflate "same malware" with "same case" — case identity comes from the
fingerprint contract, not the hit-file content.

Reference: `src/bl.d/29-trigger.sh`, `files/hooks/bl-lmd-hook`.

---

## 1. Hook adapter flow

`/etc/blacklight/hooks/bl-lmd-hook` is a thin adapter installed by
`bl setup --install-hook lmd`. It reads four LMD environment variables:

| Env var | Source | Used as |
|---|---|---|
| `LMD_SCANID` | LMD scan context | `--scanid` argument |
| `LMD_SESSION_FILE` | LMD session path | `--session-file` argument |
| `LMD_HITS` | Integer hit count from LMD | Diagnostic; not used in fingerprint |
| `LMD_DOMAIN` | Triggering domain/user | Passed as `--source-conf` context |

The adapter calls:
```
bl trigger lmd --scanid "$LMD_SCANID" --session-file "$LMD_SESSION_FILE" --unattended
```

`--unattended` sets `BL_UNATTENDED_FLAG=1`, which governs tier-gate behavior
for all steps prescribed in the resulting case. Destructive and suggested steps
are queued, not executed — the operator must run `bl run <step-id> --yes`
after reviewing.

---

## 2. TSV session-file format

LMD writes a tab-separated session file at `$LMD_SESSION_FILE` after a positive
scan. The relevant columns for `bl trigger lmd` are:

```
<ts>\t<sigid|signame>\t<path>\t<hash>\t<flags>
```

`_bl_trigger_lmd_read_session` in `29-trigger.sh` parses this TSV to JSONL:
```json
{"ts":"<ISO>","sig":"<sigid>","path":"<abs-path>","hash":"<sha256>","flags":"<flags>"}
```

**Named failure mode — empty TSV with non-zero LMD_HITS.** LMD occasionally
writes the session-file after the hook fires, producing an empty TSV at hook
time. `bl trigger lmd` detects `LMD_HITS > 0` but empty session-file and opens
a degraded stub case: fingerprint = `sha256(scanid)[:16]`, ledger event
`lmd_hit_degraded`, case opened with notes "lmd hook degraded: empty/unreadable
TSV". The operator must manually attach evidence after LMD finishes writing.

---

## 3. Cluster fingerprint contract

The fingerprint is a 16-hex SHA-256 digest:
```
sha256("<scanid>|<sorted-sigs>|<sorted-paths>")[:16]
```

- `<sorted-sigs>`: unique sigid values from JSONL, sorted, pipe-delimited
- `<sorted-paths>`: unique file paths from JSONL, sorted, pipe-delimited

The fingerprint is stable across multiple calls within the dedup window if:
1. `scanid` is identical (same LMD scan run)
2. The hit set (sigs + paths) is identical

If LMD issues a second hook with a partial rescan that produces additional hits,
the second scanid will differ — a new case opens, not an attachment.

---

## 4. Dedup window semantics

Default dedup window: `BL_LMD_TRIGGER_DEDUP_WINDOW_HOURS` from `blacklight.conf`,
fallback 24 hours.

Within the window: `bl_consult_new --fingerprint <hex16> --dedup yes` checks the
case INDEX for an open case with matching fingerprint. If found, it emits
`trigger_dedup_attached` in the ledger and returns the existing `case_id`.

The curator should treat `trigger_dedup_attached` cases as continuations, not
new investigations. The prior hypothesis and evidence already exist.

---

## 5. First-turn investigation checklist

When the curator's first turn is for an LMD-triggered case, run this sequence:

1. **Confirm cluster scope.** Read the case ledger's `lmd_hook_received` payload
   for hit count and scanid. Determine: is this a cluster (multiple paths) or a
   single-file hit?

2. **Cluster vs. single-hit routing:**
   - **Cluster (≥2 paths):** propose `observe.fs_mtime_cluster` to reconstruct
     the drop timeline. Cluster hits almost always indicate post-exploitation
     batch drop — see `from-post-scan-hook.md §TSV-to-kill-chain backwalk`.
   - **Single hit:** propose `observe.file` on the flagged path first. Single
     LMD hits are frequently FP candidates before a cluster is confirmed.

3. **Check LMD quarantine state.** LMD may have already quarantined flagged files.
   Do NOT propose `bl clean file` on paths that LMD has quarantined — they are
   already isolated. See `quarantine-vs-cleanup.md` for the discipline.

4. **Substrate check.** If the substrate is cPanel EA4 (check
   `/usr/local/cpanel/` presence), load
   `skills/cpanel-easyapache/SKILL.md` before proposing any
   `defend.modsec` steps.

5. **Emit first proposed step.** Read-only steps (observe) execute immediately
   in unattended mode. The first evidence round should be `observe.*` only.

---

## 6. Cluster vs. scattered hit triage

| Signal | Interpretation | First step |
|---|---|---|
| ≥2 paths, same directory subtree, mtime ∆ < 5 min | Likely post-exploitation batch drop | `observe.fs_mtime_cluster` on parent dir |
| ≥2 paths, scattered dirs, mtime ∆ > 1 hour | Potentially old malware or FP cluster | `observe.file` on highest-confidence hit first |
| Single path, sigid = known obfuscation sig | Single known-malware drop | `observe.file` then propose `clean.file` if confirmed |
| All paths under one user's docroot | Shared-hosting scope: single vhost | Consider cPanel substrate path for defend.modsec |
| Paths span multiple vhost docroots | Shared-hosting scope: multi-vhost | Lateral scope; consider `observe.htaccess` per vhost |

---

## §5 Pointers

- `/skills/foundations.md` — ir-playbook lifecycle rules (read before any case turn)
- `/skills/synthesizing-evidence-corpus.md` — kill-chain reconstruction + mtime clustering
- `/skills/substrate-context-corpus.md` — shared-hosting attack shapes
- `skills/lmd-triggers/from-post-scan-hook.md` — TSV-to-kill-chain backwalk
- `skills/lmd-triggers/quarantine-vs-cleanup.md` — LMD quarantine discipline
- `skills/cpanel-easyapache/SKILL.md` — cPanel EA4 substrate router
