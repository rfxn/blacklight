# Linux Malware Detect — Session Log & `hits.hist`

**Source authority:** Linux Malware Detect project
<https://github.com/rfxn/linux-malware-detect>
(README, `conf/maldet.conf` commentary, and the `sess/hits.hist` layout established in the LMD source tree). The curator loads this skill when `observe.sigs` evidence lands — LMD hits are the primary filesystem-side signal for PolyShell-family intrusions.

---

## Location

| LMD version / install mode | Base path |
|---|---|
| Default install (all versions) | `/usr/local/maldetect/` |
| Sessions directory | `/usr/local/maldetect/sess/` |
| Alternate packaging on some distros (LMD 1.6.x+) | `/var/maldetect/sess/` |
| Quarantine directory | `/usr/local/maldetect/quarantine/` |
| Temp working area | `/usr/local/maldetect/tmp/` |

Artifacts under `sess/`:

- `hits.hist` — cumulative hit history across all scans on this host
- `session.<ID>` — one file per scan run, human-readable summary
- `lock.tmp`, `.scan.*.tmp` — runtime lockfiles and in-progress scan working files

---

## `hits.hist` format

Tab-separated, one record per detection, appended in scan order. Fields:

```
<timestamp>	<signature_name>	<file_hash>	<file_path>	<quarantine_status>	<scan_session_id>
```

Where:

1. `timestamp` — Unix epoch seconds or `YYYY-MM-DD HH:MM:SS` depending on LMD version; check `conf/maldet.conf` for the deployed format.
2. `signature_name` — e.g., `PHP.Backdoor.PolyShell.UNOFFICIAL`, `PHP.Shell.c99.UNOFFICIAL`.
3. `file_hash` — md5 or sha256 per deployed `hashing` config; md5 on stock, sha256 when the operator has hardened.
4. `file_path` — absolute path to the detected file at scan time.
5. `quarantine_status` — one of `Q` (quarantined), `C` (cleaned), `R` (reported-only; left in place), or `-` on older formats.
6. `scan_session_id` — joins to `sess/session.<ID>` for the scan-run context.

One-liner to list the hits for a session:

```bash
awk -F'\t' -v id="12345.98765" '$6 == id {print $2, $4}' /usr/local/maldetect/sess/hits.hist
```

---

## Per-session summary — `sess/session.<ID>`

Human-readable scan report. Representative content:

```
HOST:      store.example.com
SCAN ID:   12345.98765
TIME:      Apr 23 2026 14:02:17 -0000
PATH:      /home/store/public_html
TOTAL FILES: 184532
TOTAL HITS: 3
TOTAL CLEANED: 0
FILE HIT LIST:
  {HEX}php.polyshell.UNOFFICIAL : /home/store/public_html/pub/media/custom_options/quote/xyz.gif
  {HEX}php.cmdshell.accesson.UNOFFICIAL : /home/store/public_html/pub/media/accesson.php
  ...
===============================================
Linux Malware Detect v1.x
```

Fields to record during triage: `SCAN ID` (joins to `hits.hist`), `PATH` (scan scope — narrower than `/` means the scan missed anything outside this tree), `TOTAL HITS`, and the per-file list.

---

## Signature naming — the `.UNOFFICIAL` suffix

LMD signatures ship in two authorship classes:

- **Official** signatures from the LMD project team — no suffix (e.g., `PHP.Backdoor.Generic`).
- **Unofficial** signatures contributed by the community or derived from external sources — suffixed `.UNOFFICIAL` (e.g., `PHP.Backdoor.PolyShell.UNOFFICIAL`).

The suffix is a provenance marker, not a confidence rating — unofficial signatures are vetted before inclusion — but it does indicate the signature's origin. When citing a hit in the brief, reproduce the full signature name including `.UNOFFICIAL`; truncating the suffix drops provenance.

Operators reading community docs occasionally trip on this: a documented detection labeled `PHP.Backdoor.PolyShell` in blog prose is the same signature as `PHP.Backdoor.PolyShell.UNOFFICIAL` in LMD output.

---

## `QUARANTINE_HITS` mode semantics

LMD's central behavior switch for what happens to hit files:

| `QUARANTINE_HITS` setting | Behavior |
|---|---|
| `1` | Move hit files to `quarantine/` (chmod 0, rename) — host is "cleaned" of the files |
| `0` | Record hit to `hits.hist`, leave files in place — host has detections but no mitigation |

**Critical to know which mode ran.** An investigator reading a `hits.hist` with no quarantined files cannot tell from the log alone whether (a) the scanner ran with `QUARANTINE_HITS=0` and the files are still live on disk, or (b) the scanner ran with `QUARANTINE_HITS=1` but an earlier run already moved them. Verify:

- `QUARANTINE_HITS` value in `conf/maldet.conf`
- `quarantine_status` column in `hits.hist` (column 5; `Q` = moved, `R` = reported-only)
- Filesystem check — does the path from column 4 still exist?

Never conclude "host clean" without confirming one of these three. In curator terms: an `observe.sigs` finding without the mode confirmation is a candidate for an `open-questions.md` entry, not a hypothesis-raise.

---

## Join keys for cross-artifact correlation

`hits.hist` joins to other forensic sources via two pairs of keys:

- `{file_hash, file_path}` → joins to Apache/nginx transfer-log lines (on path substring after URL canonicalization) and to the curator's `file-patterns.md` fleet-wide aggregation.
- `{timestamp, scan_session_id}` → joins to ModSec audit log transactions within the scan window, via the audit log's section A timestamp.

The path join is the common case during initial triage; the hash join matters when correlating across hosts in a fleet — the same file hash on two hosts implies the same adversary dropped both, modulo hash-preserving droppers.

---

## Signature-family disambiguation

**Non-obvious rule:** do not rely on the signature name alone for family attribution. A GIF-container PolyShell variant may match a generic `PHP.Backdoor.Eval.Base64.UNOFFICIAL` signature because the scanner saw `eval(base64_decode(...))` before it saw the GIF magic. The hit is real; the family label is just the first signature that fired, not necessarily the most specific.

Procedure when the signature family matters:

1. Extract the file from the path (or from `quarantine/` if moved).
2. Re-check against the content patterns documented in `../webshell-families/` — file magic first, then wrapper functions, then auth stanza, then exec layer.
3. Attribute by content, not by signature name.

A brief that says "two PolyShell variants detected" based on identical signature names may actually be two unrelated shells — or one PolyShell and one c99 clone — when the content-based check is run. Always ground the family claim in content, not in LMD's first-match signature label.

---

## Hit-rate-over-time analysis

When triaging a fleet-wide incident, the onset date of the intrusion wave is often the most informative single fact. Derive it from `hits.hist` directly:

```bash
awk -F'\t' '{print $1}' /usr/local/maldetect/sess/hits.hist \
  | cut -d' ' -f1 \
  | sort \
  | uniq -c
```

Output is `<count> <date>` pairs. A flat low-count baseline followed by a sudden spike is the wave onset. Cross-reference to the CVE/bulletin publication date — if the spike precedes public disclosure, the site was hit during the zero-day window; if it follows, it's part of the post-disclosure mass-exploitation phase.

For epoch timestamps, convert first:

```bash
awk -F'\t' '{print strftime("%Y-%m-%d", $1)}' /usr/local/maldetect/sess/hits.hist \
  | sort | uniq -c
```

---

## Triage checklist

- [ ] Locate `sess/hits.hist` (check both `/usr/local/maldetect/` and `/var/maldetect/` paths)
- [ ] Read `conf/maldet.conf` to confirm `QUARANTINE_HITS` mode and hash algorithm
- [ ] Tabulate hits by date (awk hit-rate-over-time pipeline)
- [ ] For each hit: confirm path still exists on disk; note `Q`/`R` quarantine state
- [ ] Extract file hashes for cross-fleet correlation
- [ ] Re-check family attribution against `webshell-families/` content patterns — do not trust signature name alone
- [ ] Correlate scan session IDs to ModSec audit and Apache transfer logs via timestamp

---

## See also

- [../webshell-families/polyshell.md](../webshell-families/polyshell.md) — content-based family attribution that overrides signature-name first-match
- [post-to-shell-correlation.md](post-to-shell-correlation.md) — once a hit path is known, the status-code rules determine whether execution occurred

<!-- adapted from beacon/skills/log-forensics/maldet-session-log.md (2026-04-23) — v2-reconciled -->
