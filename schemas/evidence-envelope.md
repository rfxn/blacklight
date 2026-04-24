# evidence-envelope — JSONL record contract

Authoritative contract for evidence records produced by `bl observe`, consumed by the curator (via memory-store reads + Files attachments), and reproduced by demo-fixture fabrication (see `docs/demo-fixture-spec.md`). Companion to `schemas/step.json` (step envelope) and `DESIGN.md §10` (bundle shape).

Every evidence record is one line of JSONL. Every record has the **preamble** fields below plus a `record` payload whose fields are governed by the declared `source`. No record is free-form; every field is typed. Operator-local identifiers (customer tokens, internal hostnames, cpanel usernames) MUST NOT appear in any envelope — the wrapper scrubs at emit time.

---

## 1. Preamble (every record)

```json
{"ts": "<ISO-8601>", "host": "<label>", "case": "<case-id|null>", "obs": "<obs-id>", "source": "<taxonomy>", "record": { /* source-specific */ }}
```

| Field | Type | Rule |
|---|---|---|
| `ts` | string | ISO-8601 UTC with `Z` suffix. Millisecond precision permitted. Wall-clock of the emit, not the source event (source event time lives in `record.*_at` if meaningful). |
| `host` | string | Short label, no FQDN, no customer tenant name. Default is `hostname -s` but the operator can override via `$BL_HOST_LABEL`. Demo fixtures use `fleet-01-host-N` shape. |
| `case` | string \| null | `CASE-YYYY-NNNN` when a case is active (`bl consult --attach` set the current case); `null` when the emit is outside a case context (e.g. ad-hoc `bl observe`). |
| `obs` | string | Stable observation id, format `obs-NNNN`. One per emit. Referenced by agent reasoning (`step.reasoning` cites `obs-NNNN`). |
| `source` | string | Closed taxonomy, see §2. Dotted form: `<domain>.<kind>`. |
| `record` | object | Source-specific payload. Fields declared per `source` in §3. `additionalProperties: false` in contract — unknown fields are an emit-time bug, not an extension point. |

### Preamble invariants

- **No PII / tenant identifiers.** The wrapper runs a scrub pass before emit: strip cPanel usernames, customer account tokens, internal DNS names. See `DESIGN.md §13.2` for the untrusted-content fence.
- **`ts` monotonicity is not guaranteed.** Multiple sources emit concurrently; sort at consumer if ordering matters.
- **`obs` is process-scoped.** A single `bl observe <verb>` invocation may emit many records sharing one `obs` id. Cross-invocation correlation uses `case` + `record.*_at`.
- **One JSON object per line.** No arrays at the top level. No pretty-print. `\n`-terminated. `jq -c` safe.

---

## 2. Source taxonomy

Closed list. Every record's `source` MUST be one of these values. New sources require adding them here AND to the wrapper's emit path AND to any consuming skill that groups by source.

| `source` | Emitted by | Meaning |
|---|---|---|
| `apache.transfer` | `bl observe log apache` | One Apache access-log record (combined-log parse). |
| `apache.error` | `bl observe log apache` | One Apache error-log record (where separately collected). |
| `modsec.audit` | `bl observe log modsec` | One ModSec audit-log transaction (A/B/F/H sections folded into one record). |
| `journal.entry` | `bl observe log journal` | One journalctl line. |
| `cron.entry` | `bl observe cron` | One crontab entry for the scanned user / system subtree. Output of `crontab -u <u> -l \| cat -v` (one record per non-empty, non-comment line). |
| `proc.snapshot` | `bl observe proc` | One process snapshot: ps row + `/proc/<pid>/exe` basename comparison for argv-spoof detection. |
| `htaccess.directive` | `bl observe htaccess` | One flagged directive from an `.htaccess` walk. Clean directives are NOT emitted — only those the walker judged injected or suspicious. |
| `fs.mtime_cluster` | `bl observe fs --mtime-cluster` | One file belonging to an mtime-cluster group. Cluster cohesion carried in `record.cluster_id`. |
| `fs.mtime_since` | `bl observe fs --mtime-since` | One file from a retrospective mtime sweep (e.g. "since CVE disclosure"). |
| `firewall.rule` | `bl observe firewall` | One active deny rule as seen by the auto-detected backend (APF / CSF / iptables / nftables). |
| `sig.loaded` | `bl observe sigs` | One loaded signature (with hit count from the scanner's local history where available). |
| `file.triage` | `bl observe file` | Aggregate triage output for one target path: stat + magic + strings + sha256 folded into one record. |
| `observe.summary` | Any `bl observe` | Emit-boundary summary record: counts by classification, top-N buckets, time span, invariant checks. Exactly one per `obs-NNNN` when the verb opts into summarization. |

**Non-sources.** Wrapper and session metadata (case opened, step accepted, defense applied) are NOT evidence — they live in `bl-case/<case>/actions/*` and `/var/lib/bl/ledger/`, not in JSONL evidence. If a signal belongs to the action ledger, it does not belong here.

---

## 3. Per-source `record` fields

Declared field sets per `source`. The wrapper emits exactly these fields (no more, no less); the curator and any downstream duckdb query plans against this contract.

### 3.1 `apache.transfer`

```json
{"client_ip":"203.0.113.51","method":"GET","path":"/pub/media/.../a.php/banner.jpg","status":404,"bytes":218,"ua":"Mozilla/5.0 ...","referer":"-","site":"example.tld","ts_source":"2026-04-23T14:22:07Z","path_class":"double_ext_jpg","is_post_to_php":false,"status_bucket":"4xx"}
```

Derived fields (`path_class`, `is_post_to_php`, `status_bucket`) are pre-computed at parse time — the curator does not re-derive from raw path/method/status.

### 3.2 `apache.error`

```json
{"level":"error","client_ip":"203.0.113.51","message":"...","module":"core","ts_source":"2026-04-23T14:22:07Z"}
```

### 3.3 `modsec.audit`

```json
{"txn_id":"YjH9aUCoAAA","client_ip":"203.0.113.51","uri":"/pub/media/.../a.php","method":"POST","rule_id":"920450","msg":"...","action":"deny","phase":2,"ts_source":"2026-04-23T14:22:07Z"}
```

Fields fold the A (header), B (request), F (response header), H (action) sections into the canonical correlation-useful keys. Raw sections are available in the source log on the host; this envelope carries the parsed projection.

### 3.4 `journal.entry`

```json
{"unit":"cron.service","pid":1843,"message":"...","priority":"info","ts_source":"2026-04-23T04:17:01Z"}
```

### 3.5 `cron.entry`

```json
{"user":"www-data","system":false,"schedule":"*/5 * * * *","command":"/home/www-data/.config/htop/.u","raw_line":"*/5 * * * * /home/www-data/.config/htop/.u","ansi_obscured":true,"cat_v_output":"*/5 * * * * /home/www-data/.config/htop/.u^[[2J"}
```

`cat_v_output` is the raw `cat -v` rendering — preserves the ANSI ESC[2J obscuration pattern that `crontab -l` alone hides. `ansi_obscured: true` fires when `cat -v` output contains any `^[` marker the bare command omits.

### 3.6 `proc.snapshot`

```json
{"pid":4711,"user":"www-data","argv0":"mariadbd","exe_basename":"httpd","argv_spoof":true,"cmdline":"mariadbd --datadir=/tmp/.x","cwd":"/tmp/.x","start_time_ts":"2026-04-23T14:22:07Z"}
```

`argv_spoof` fires when `exe_basename` (from `/proc/<pid>/exe`) differs from `argv0` — the gsocket-class signal.

### 3.7 `htaccess.directive`

```json
{"file":"/var/www/html/.htaccess","line":42,"directive":"AddHandler","argument":"application/x-httpd-php .jpg","injected":true,"reason":"AddHandler re-maps image ext to PHP — classic polyshell staging"}
```

Clean directives are not emitted. `reason` is a short, closed-vocabulary classifier output (not the agent's free-text reasoning — that lives in `step.reasoning`).

### 3.8 `fs.mtime_cluster`

```json
{"path":"/var/www/html/pub/media/catalog/product/.cache/a.php","size":2451,"mtime":"2026-04-23T14:22:07Z","sha256":"...","owner":"www-data","perms":"0644","cluster_id":"c-0003","cluster_size":7,"cluster_span_secs":4}
```

Records belonging to the same mtime-cluster share `cluster_id`. `cluster_size` and `cluster_span_secs` are denormalized onto every member record for direct filtering without re-aggregation.

### 3.9 `fs.mtime_since`

```json
{"path":"/var/www/html/...","size":2451,"mtime":"2026-04-23T14:22:07Z","sha256":"...","owner":"www-data","perms":"0644","sweep_since":"2026-04-14T00:00:00Z","under":"/var/www/html"}
```

### 3.10 `firewall.rule`

```json
{"backend":"iptables","chain":"INPUT","rule_index":27,"action":"DROP","source":"203.0.113.51","dest":"0.0.0.0/0","proto":"tcp","dport":null,"comment":"bl-case CASE-2026-0007 — polyshell-c2","bl_case_tag":"CASE-2026-0007"}
```

`bl_case_tag` is populated when the rule's comment carries a case-id blacklight wrote at apply time. Third-party rules leave `bl_case_tag: null`.

### 3.11 `sig.loaded`

```json
{"scanner":"maldet","sig_id":"{MD6}WSX.polyshell.v1auth.UNOFFICIAL","sig_kind":"md6","hit_count_30d":14,"last_hit_ts":"2026-04-22T19:04:18Z"}
```

### 3.12 `file.triage`

```json
{"path":"/var/www/html/pub/media/.../a.php","size":2451,"mode":"0644","owner":"www-data","mtime":"2026-04-23T14:22:07Z","sha256":"...","magic":"PHP script, ASCII text","strings_sample":["BL-STAGE","chr(","base64_decode","gzinflate"],"strings_total":128}
```

`strings_sample` is capped at the top-N printable ≥6-char strings (wrapper caps N=32); `strings_total` is the full count.

### 3.13 `observe.summary`

```json
{"verb":"observe.log_apache","span":{"from":"2026-04-23T08:00:00Z","to":"2026-04-23T14:00:00Z"},"counts":{"records_in":148210,"records_emitted":148210,"filtered":0},"top_ips_200":[{"ip":"203.0.113.51","count":8412}],"top_paths_200":[{"path":"/pub/media/.../a.php","count":8412}],"status_histogram":{"200":140018,"404":7812,"500":380},"backend_meta":{"firewall_backend":"iptables","firewall_detect":"ok","sig_scanners_present":["maldet","yara"],"sig_scanners_missing":["clamav"]},"attention":["double_ext_jpg paths account for 5.7% of 200s — unusual"]}
```

Summary is emitted once per observation; it is the record the curator reads first (highest-signal). Full detail lives in the prior records sharing the same `obs` id.

`backend_meta` populates on `observe.firewall` (carries the auto-detected backend name and whether detection succeeded) and `observe.sigs` (lists which scanners are installed and which are absent). This spares the curator from proposing a `defend.firewall` against an unknown backend or a `defend.sig --scanner clamav` on a host without ClamAV — the summary record lets the curator reason over backend availability before emitting a defense step. Other observe verbs leave `backend_meta` absent.

---

## 4. Untrusted-content fence

Every `record` is passed to the curator wrapped in an explicit fence:

```
<untrusted source=apache.transfer obs=obs-0041 case=CASE-2026-0007>
{...one JSONL record...}
</untrusted>
```

Fence tokens are session-unique and derived from `sha256(case || obs || payload)[:16]` — 64 bits of preimage resistance. Forgery requires an attacker to find a log-line payload that produces a specific target prefix (2^64 work per target, computationally infeasible even with observable cleartext fences), not a collision (which a birthday attack could find in 2^32 but does not help an attacker who needs a SPECIFIC end-token, not any matching pair). The curator's system prompt includes an explicit taxonomy of injection attempts (role reassignment, schema override, verdict flip) and routes any fence-escape string to a `reasoning` evidence field rather than acting on it. See `DESIGN.md §13.2`.

---

## 5. Producer / consumer compliance

- **Wrapper (`bl observe`)** MUST emit conforming JSONL and MUST scrub operator-local identifiers before emit.
- **Demo fixture fabricators** (`docs/demo-fixture-spec.md`) MUST produce records that pass a schema check against this contract. Drift is a demo-fixture bug, not a curator bug.
- **Curator** MAY assume every record conforms; a record that fails validation is dropped with a `reasoning` note, never acted on.
- **Third-party skills** that want new source classes (e.g. `plesk.logs`, `directadmin.cron`) MUST PR a new `source` enum entry and a §3 payload spec. Skills do not get to silently introduce new sources — that breaks duckdb query plans and the untrusted-content fence's hash inputs.

---

## 6. Versioning

This envelope is v1. Backwards-incompatible changes bump the top-level preamble with an explicit `envelope_version: 2` field (absent = v1). The **wrapper** enforces version compatibility at emit time (scrub pass refuses to emit records under an envelope version the installed `bl` binary was not built for) and at case-open time (refuses to attach to a case whose earliest record's `envelope_version` is newer than the wrapper's own). The curator is stateless with respect to version-check — it reads whatever the wrapper emits; the skills corpus in `bl-skills/ir-playbook/evidence-envelope.md` documents the envelope shape the curator expects to see, but the curator does not enforce versions. Version skew is a case-opening block at the wrapper boundary; no silent migration.
