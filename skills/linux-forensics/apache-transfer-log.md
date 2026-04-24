# Apache Transfer-Log Interpretation

**Source authority:** Apache `mod_log_config` documentation
<https://httpd.apache.org/docs/2.4/mod/mod_log_config.html>.
nginx follows the same field conventions for its default `combined` format; the format tokens below are Apache but the line shapes match. The curator consumes this skill when reasoning about `observe.log_apache` evidence — the `finding` strings reference these field positions, and a wrong field parse leads to wrong attribution.

---

## Combined log format — field by field

Default format directive:

```
LogFormat "%h %l %u %t \"%r\" %>s %O \"%{Referer}i\" \"%{User-Agent}i\"" combined
```

Canonical line:

```
203.0.113.10 - - [23/Apr/2026:14:02:17 +0000] "POST /custom_options/quote/ HTTP/1.1" 200 1423 "-" "python-requests/2.31.0"
```

| Token | Directive | Meaning |
|---|---|---|
| `203.0.113.10` | `%h` | Remote host (client IP; reverse-DNS only if `HostnameLookups On` — rare) |
| `-` | `%l` | Remote logname (RFC 1413 identd; always `-` in practice) |
| `-` | `%u` | Authenticated remote user (present only under HTTP auth) |
| `[23/Apr/2026:14:02:17 +0000]` | `%t` | Request start time with timezone offset |
| `POST /custom_options/quote/ HTTP/1.1` | `%r` | Request line (method + URI + protocol), inside double quotes |
| `200` | `%>s` | Final response status (after internal redirects) |
| `1423` | `%O` | Bytes sent to client including headers (request body size is not in this line) |
| `-` | `%{Referer}i` | Referer header (quoted; `-` when absent) |
| `python-requests/2.31.0` | `%{User-Agent}i` | User-Agent header (quoted) |

---

## Custom fields that break naive parsers

Production Apache configs routinely extend `combined` with more fields. A parser that assumes nine tokens or a fixed field count fails silently on lines that don't conform — and those are exactly the lines that often carry the forensic signal.

- `%{Host}i` — captures the `Host:` header. Shows up as an extra quoted field, often placed between `%O` (bytes) and `%{Referer}i`.
- `%D` — request duration in microseconds. Unquoted integer, typically appended at the end.
- `%{VARNAME}e` — arbitrary environment variable (commonly `X-Forwarded-For`, `SSL_CLIENT_CERT`, session IDs). Quoted when extracted from headers, unquoted when taken from request env.
- `%I` / `%O` paired — bytes in + bytes out, common on reverse-proxy frontends.
- `%v` / `%V` — server name / canonical server name for virtualhost disambiguation on shared hosts.

**Non-obvious:** count quoted-string tokens, not all tokens, when validating shape — a Host-header-capture variant adds a quoted field between size and referer and breaks 9-token-assumption parsers. Seven quoted strings means combined + Host-capture; six means stock combined; five means the size field got dropped and the line is probably truncated. Always detect the format by quote count first, then parse.

---

## Webshell-interaction request shapes

Three shape classes on the transfer log that correlate with webshell activity. This file handles *detection* (where to find these in the log); the verdict logic (what the status means) lives in `post-to-shell-correlation.md §Four-status decision rule`.

1. **Upload-drop shape** — `POST` to an upload endpoint with a response size consistent with a REST acknowledgement (typically 100–2000 bytes). Example: `POST /custom_options/` is the PolyShell-family drop signal; classify status per `post-to-shell-correlation.md`.
2. **Payload-in-query shape** — `GET` on a `.php` path with a query string longer than ~256 bytes. Legitimate GET queries are short; long base64 or URL-encoded blobs in a `.php` query are usually payload delivery.
3. **Abnormal-body-on-static shape** — `POST` with a body size (visible as `%I` on extended configs, or inferred from `%O` when an echo-back shell responds proportionally) above ~100KB to a path that is nominally a static asset (`.png`, `.css`, `.js`). Static paths do not accept bodies; this is either a misconfigured route to PHP or a path-rewrite executing PHP under a non-`.php` extension.

Grep skeleton for the upload-drop shape (any HTTP method of three-plus uppercase characters catches `POST`, `PUT`, `OPTIONS`):

```bash
grep -E '[A-Z]{3,}\s\S+/custom_options/' access.log
```

Feed the output into `post-to-shell-correlation.md §Four-status decision rule` for per-bucket verdicts.

---

## User-Agent anti-fingerprinting

The following UAs are not diagnostic alone:

- `python-requests/2.*`
- `curl/*`
- empty UA (`"-"` in the log)
- `Mozilla/5.0 (compatible; bot)` and related generic bot strings

All four are shared by commercial scanners (Censys, Shodan, Sucuri probes). A host that logs a thousand `python-requests/2.31.0` hits per day is almost certainly being scanned, not exploited. UA becomes diagnostic only when paired with a suspicious path (`/custom_options/`, `/admin/...`) or a referer chain that doesn't route through the site's own checkout flow.

Conversely, an adversary forging `Mozilla/5.0 (Windows NT 10.0)` can completely defeat UA-based scanner filtering. Never whitelist on UA; use it as one signal among several.

---

## Log-rotation gotchas

Apache rotates the transfer log at midnight server-local by default (via `logrotate`, not by Apache itself on most distros). A multi-hour intrusion commonly splits across the rotation boundary:

- `access.log` — today so far
- `access.log.1` — previous 24h
- `access.log.2.gz` — day before, compressed

Before timeline reconstruction, concatenate the rotated segments covering the window of interest:

```bash
zcat -f access.log.*.gz access.log.1 access.log 2>/dev/null > /tmp/merged.log
```

The `-f` flag lets `zcat` pass uncompressed files through, so the same command handles both `.gz` and plain files in one pipeline.

Rotation timezone mismatch is a second trap: if Apache logs in UTC but the host's `logrotate` runs in server-local, the rotation boundary inside the log is not midnight UTC. Always verify the timestamp offset in `%t` against the rotation filename date.

---

## Malformed-line policy

In production logs, 1–5 lines per million are malformed. Causes:

- Socket truncation during client disconnect mid-request
- Rotation race — Apache writes a line while `logrotate` is renaming the file
- Disk-full truncation
- Character-encoding glitches in exotic URLs or referers

A parser handling forensic logs must **skip and warn, never raise**. Raising on a malformed line means one bad byte in a million loses the entire log file for the investigation. Log the line number and the reason, continue. The curator's `observe.log_apache` handler is expected to preserve this invariant — if the wrapper crashes on a single bad line, the evidence batch is incomplete.

---

## Triage checklist

- [ ] Identify the log format (count quoted-string tokens: 5, 6, 7, 8...)
- [ ] Verify the timezone offset in `%t` and convert to UTC for cross-log correlation
- [ ] Concatenate rotated segments covering the incident window
- [ ] Scan for the three webshell-interaction shapes (upload-drop, payload-in-query, abnormal-body-on-static)
- [ ] Extract candidate `(client_ip, method, path)` triples and their status counts
- [ ] Cross-reference candidate paths against the filesystem (is the file there? what does it look like?)
- [ ] Resist UA-based whitelisting — treat UA as one signal among several

---

## See also

- [../actor-attribution/ip-clustering-by-behavior.md](../actor-attribution/) — behavioral IP clustering using the triples extracted here
- [post-to-shell-correlation.md](post-to-shell-correlation.md) — status-code decision rules on a candidate shell path
- [modsec-audit-format.md](modsec-audit-format.md) — when the transfer log alone is ambiguous, the ModSec audit log adds rule-match context

<!-- adapted from beacon/skills/log-forensics/apache-transfer-log.md (2026-04-23) — v2-reconciled -->
