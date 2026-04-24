# Event Extraction From Heterogeneous Logs

**Source authority:**
Apache `mod_log_config` combined-format reference
<https://httpd.apache.org/docs/current/logs.html>.
ModSecurity audit-log format reference (v2.x Reference Manual)
<https://github.com/owasp-modsecurity/ModSecurity/wiki/Reference-Manual-(v2.x)#audit-log-format>.
R-fx Networks Linux Malware Detect (LMD) project page
<https://rfxn.com/projects/linux-malware-detect/>.
plaso / log2timeline multi-source log parser
<https://plaso.readthedocs.io/en/latest/sources/user/Using-log2timeline.html>.

The curator loads this skill when multiple `observe.log_*` evidence batches are compounding and a unified timeline is needed before the interval segmentation step. Extraction runs to completion before segmentation — a segmentation pass on an incomplete stream places phase boundaries in the wrong intervals.

---

## The unified event schema

Each extracted event maps to the following fields. Downstream interval segmentation and IR brief rendering consume this schema.

| Field | Type | Description |
|---|---|---|
| `ts` | ISO-8601 UTC string | Timestamp normalized to UTC (`2026-03-10T14:23:01Z`). Never store local-time timestamps in this field. |
| `host_id` | string | Logical host identifier (e.g., `host-A`). Populated by the caller; not derived from log content. |
| `actor_id` | string | IP address or actor token extracted from the log line. Use `"-"` when not present. |
| `type` | enum string | One of: `http_request`, `modsec_alert`, `malware_detection`, `syslog_event`, `db_query`. Extend as needed. |
| `summary` | string | One-line human-readable summary of the event (`POST /rest/V1/guest-carts → 201`). |
| `source_artifact_id` | string | Canonical path of the source log file or artifact (`/var/log/apache2/access.log`). Used for dedup tuple construction. |

---

## Per-format parsing rules

| Source | Canonical Path | Key Fields | Timestamp Token | Notes |
|---|---|---|---|---|
| Apache combined | `/var/log/apache2/access.log`, `/var/log/httpd/access_log` | `%h` (actor_id), `%t` (ts), `%r` (summary) | `[10/Mar/2026:14:23:01 +0000]` | Field count varies with custom `LogFormat`; do not assume fixed column positions |
| ModSec audit | `/var/log/modsec_audit.log`, path from `SecAuditLog` | Part A header (client IP, timestamp), Part H (rule IDs) | RFC-3339 or server-local — see §Timestamp Normalization | Parts B–F only present when `SecAuditLogParts` includes them; Part H absent by default |
| maldet hits.hist | `/usr/local/maldetect/sess/hits.hist.*` | `DATE`, `FILE`, `RULE` columns | epoch-seconds integer in column 1 | One row per detection event; multiple rows per scan session |
| syslog (RFC 5424) | `/var/log/syslog`, `/var/log/messages` | HOSTNAME, APPNAME, MSG | `<PRI>1 2026-03-10T14:23:01Z hostname` | Kernel messages may carry relative (since-boot) timestamps; discard unless wall-clock correlatable |

---

## Timestamp normalization

All events must carry a UTC timestamp before entering the unified stream. Format-specific gotchas:

**Apache combined** — timestamp includes timezone offset (`[10/Mar/2026:14:23:01 +0000]`). Servers behind a load balancer with `X-Forwarded-For` may also inject a second timestamp in a custom field. Apply the offset before storing. The `%t` token records request-start time, not completion; for long-running uploads, request start is the forensically relevant moment.

**ModSec audit** — default configuration writes timestamps in server-local time without an explicit offset (`20260310-142301`). The server's timezone is not recorded in the audit log itself. If the server is not confirmed UTC, correlate with a concurrent Apache log line to derive the offset. ModSec v3.x (libmodsecurity) switched to RFC-3339 with explicit offset — check the audit log header format before assuming either convention.

**maldet hits.hist** — timestamps are POSIX epoch-seconds. Convert with `date -d @EPOCH -u +%Y-%m-%dT%H:%M:%SZ`. Epoch 0 in the file indicates a scan with no timestamp record — discard that row.

**syslog (RFC 5424 §6.2.3)** — RFC 5424 mandates ISO-8601 with timezone. RFC 3164 (legacy BSD syslog) uses `Mmm DD HH:MM:SS` with no year and no timezone — assume current year and correlate TZ from server config. Mixed RFC 3164 / RFC 5424 sources in a single file (common on upgraded systems) require two-pass parsing.

---

## Deduplication heuristics

A single adversary action frequently produces log entries across multiple sources simultaneously. Naively merging all sources generates duplicate events that distort phase boundaries during segmentation.

**Primary dedup tuple:** `(host_id, ts ± 2s, actor_id, summary-fingerprint)`

The summary fingerprint is a normalized form of the event summary: lowercase, stripped of query-string values, path components beyond depth-3 replaced with `…`. Example: `POST /rest/V1/guest-carts/abc123/items` → fingerprint `post /rest/v1/guest-carts/…/items`.

**When to merge:** if two events share the same tuple, merge them into a single event and record both `source_artifact_id` values in a `sources` list. Prefer the Apache event as canonical for HTTP events (higher field fidelity).

**When NOT to merge:** ModSec alert events and Apache access-log events for the same request are distinct event types even when they share a tuple — they carry different `type` values and different forensic content. Keep them separate; they do not count as duplicates.

**2-second window rationale:** NTP-disciplined servers typically agree within 100 ms; the 2-second window accommodates misconfigured clocks without creating false merges across distinct requests.

---

## Ordering for downstream consumption

After deduplication, sort the event list ascending by `ts`. For events with identical `ts` values, apply a secondary sort by `source_artifact_id` (lexicographic ascending). This ensures deterministic ordering — a stable sort is required so repeated extraction runs produce identical output.

The sorted stream is the direct input to `interval-segmentation.md`. Never pass an unordered stream to segmentation; phase-boundary detection assumes monotonically increasing timestamps.

---

## A worked example: a single upload-to-execution sequence

A Magento REST API webshell upload produces the following sequence across three log sources. This example uses the Sansec PolyShell public research timeline and anonymized request paths.

**Raw events before dedup (5 rows):**

| # | Source | ts (UTC) | actor_id | Raw summary |
|---|---|---|---|---|
| 1 | Apache | 2026-03-10T14:23:01Z | 203.0.113.10 | POST /rest/V1/guest-carts → 201 |
| 2 | ModSec | 2026-03-10T14:23:01Z | 203.0.113.10 | Alert id=942100 — SQL injection pattern in body |
| 3 | Apache | 2026-03-10T14:23:09Z | 203.0.113.10 | POST /rest/V1/guest-carts/c8f3a1/items → 201 |
| 4 | Apache | 2026-03-10T14:23:09Z | 203.0.113.10 | POST /rest/V1/guest-carts/c8f3a1/items → 201 (duplicate from load-balancer log) |
| 5 | Apache | 2026-03-10T14:28:42Z | 203.0.113.10 | GET /pub/media/wysiwyg/shell.php → 200 |

**Dedup applied:**
- Row 1 and Row 2: different `type` values (`http_request` vs `modsec_alert`) → keep both, no merge
- Row 3 and Row 4: identical tuple (same host, same ts, same actor, same fingerprint `post /rest/v1/guest-carts/…/items`) → merge; canonical is Row 3 (single Apache source is sufficient when both are from Apache logs)

**Unified stream (4 events, chronological):**

| seq | ts (UTC) | actor_id | type | summary |
|---|---|---|---|---|
| 1 | 2026-03-10T14:23:01Z | 203.0.113.10 | http_request | POST /rest/V1/guest-carts → 201 |
| 2 | 2026-03-10T14:23:01Z | 203.0.113.10 | modsec_alert | Alert id=942100 — SQL injection pattern in body |
| 3 | 2026-03-10T14:23:09Z | 203.0.113.10 | http_request | POST /rest/V1/guest-carts/c8f3a1/items → 201 |
| 4 | 2026-03-10T14:28:42Z | 203.0.113.10 | http_request | GET /pub/media/wysiwyg/shell.php → 200 |

Events 1–3 would fall in the **landing** interval; event 4 marks the start of the **escalation** interval. These assignments are made by interval segmentation, not by event extraction.

---

## Failure modes

| Failure mode | Consequence | Correction |
|---|---|---|
| Storing local-time timestamps in `ts` without UTC conversion | Phase boundaries shift by the server's UTC offset; cross-host correlation is wrong | Always apply the offset before storing; document TZ assumption when offset is inferred |
| Assuming fixed column counts in Apache log parsing | Custom `LogFormat` directives add fields; parser silently reads wrong columns | Read the active `LogFormat` directive from the vhost config before parsing |
| Merging ModSec alert and Apache access-log rows as duplicates | Loses the rule-ID signal that identifies the intrusion vector | Different `type` → different events; merge only within the same type |
| Skipping the dedup pass and relying on downstream uniqueness | Inflated event counts distort phase-boundary detection in segmentation | Always dedup before handing off the stream |
| Using maldet hits.hist epoch-0 rows | Epoch 0 is a sentinel for "no timestamp" — not the Unix epoch | Drop rows where epoch == 0 before conversion |

---

## Triage checklist

- [ ] Identify all log sources present on the host: Apache, ModSec, maldet, syslog
- [ ] Confirm each source's timezone setting (or infer from cross-source correlation)
- [ ] Confirm ModSec audit log version (v2 vs v3) and which Parts are enabled
- [ ] Run extraction per-format; collect raw event rows
- [ ] Apply dedup: build tuple `(host_id, ts±2s, actor_id, summary-fingerprint)` per event
- [ ] Sort ascending by `ts`, secondary by `source_artifact_id`
- [ ] Verify output row count is plausible (large reduction from dedup is expected; zero events is not)
- [ ] Hand stream to `interval-segmentation.md`

## See also

- [../linux-forensics/apache-transfer-log.md](../linux-forensics/apache-transfer-log.md)
- [../linux-forensics/modsec-audit-format.md](../linux-forensics/modsec-audit-format.md)
- [../linux-forensics/maldet-session-log.md](../linux-forensics/maldet-session-log.md)
- [interval-segmentation.md](interval-segmentation.md)

<!-- adapted from beacon/skills/timeline/event-extraction.md (2026-04-23) — v2-reconciled -->
