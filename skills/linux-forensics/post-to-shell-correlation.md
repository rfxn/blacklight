# POST-to-Shell Correlation

**Source authority:** RFC 7231 (HTTP/1.1 Semantics and Content)
<https://www.rfc-editor.org/rfc/rfc7231>
and OWASP Core Rule Set documentation
<https://coreruleset.org/docs/>. The curator invokes these verdict rules when `observe.log_apache` + `observe.file` evidence lands for a candidate shell path — a compromise call requires the status-distribution logic below, not a single 200.

---

## Four-status decision rule

Given a candidate shell path and a transfer-log line showing a non-idempotent request (POST/PUT/PATCH) to that path, the response status is the primary verdict signal:

| Status | Verdict | Reasoning |
|---|---|---|
| `200` | **Compromise confirmed.** | The shell accepted the request and returned content. Execution occurred. |
| `403` | **Mitigation holding.** | WAF / ModSec / webserver ACL blocked at the network boundary. The shell may still be on disk but cannot be reached over HTTP. |
| `404` | **Ambiguous — filesystem check non-optional.** | Could mean (a) the file never existed, (b) it was deleted between the initial drop and this request, or (c) the file exists but the webserver route is gone (e.g., `.htaccess` removed the handler). Status alone cannot distinguish; check the filesystem. |
| `302` | **Redirect in place — verify target.** | Commonly introduced by WAF remediation redirecting to a warning page; treat as mitigation holding. But if the redirect target is adversary-controlled (another host, another path on the same host with exec), that's a secondary compromise, not a mitigation. |

The rule is one-way: a 200 is strong evidence of compromise, but the absence of a 200 on a given day does not prove clean — the shell may have been touched yesterday and the log has rolled. Apply the rule across the full rotation window.

---

## Per-host evaluation procedure

Given a concrete shell path `P` on host `H`, enumerate all distinct `(client_ip, method, path)` triples in the transfer log for path `P`, then tabulate statuses. Example pipeline:

```bash
grep -E ' "[A-Z]+ [^"]*P[^"]*' /var/log/apache2/access.log \
  | awk '{print $1, $6, $7, $9}' \
  | sort | uniq -c | sort -rn | head -50
```

(`$1` = client IP, `$6` = method (after unquoting the request line), `$7` = path, `$9` = status — adjust for the site's exact log format.)

For each unique `(ip, method)` bucket on path `P`, record the status distribution. A bucket that is `200 × N` with no mixed 403s is unambiguous compromise. A bucket that is `403 × N` with no 200s is mitigation holding. Mixed `403` + `200` buckets are the interesting case: the adversary hit the shell, tripped a rule that caused a 403, tried again from a different IP or with different headers, and succeeded. That is compromise confirmed with a mitigation that leaks.

Write the per-host verdict as a compact summary (the curator stores this shape in the evidence row):

```
host=store.example.com path=/pub/media/custom_options/quote/xyz.gif
  verdict=compromise
  buckets: (203.0.113.10, POST)=200×4, (203.0.113.47, POST)=403×2, (203.0.113.47, POST)=200×1
```

---

## 502/504 ambiguity + retry analysis

Status 502 (Bad Gateway) and 504 (Gateway Timeout) are upstream infrastructure failures — the reverse proxy never received a clean response from the origin. They are **not** evidence of either compromise or mitigation.

The retry-analysis rule: if the adversary retries after a 5xx and the retry returns 200, compromise is confirmed — the shell was live, the infrastructure was slow, the retry succeeded. If the retry returns 403, the mitigation landed between attempts. If there is no retry, the 5xx is indeterminate.

Extract retry chains by grouping on `(client_ip, path)` and sorting by timestamp:

```bash
grep 'P' access.log | awk '{print $1, $4, $9}' | sort -k1,1 -k2,2
```

Walk the output — same IP + ascending timestamps + status transitions tell the story.

---

## Zero-byte 200 — the output-suppressed shell

**Non-obvious:** a `200` response with a `0`-byte body (e.g., `%O` shows a small header-only count, ~200 bytes for typical Apache response headers) on a POST to a suspected shell path is compromise, not noise. Many webshells are configured to redirect `system()` / `exec()` output to a file or to a side channel (DNS, out-of-band HTTP beacon), producing an HTTP response with no body. The operator discount reflex — "the body is empty, nothing happened" — is wrong here.

A single header-sized 200 on a `.php` or image-masquerading path under `pub/media/` should be treated exactly like a body-carrying 200: compromise confirmed, investigate the out-of-band channel.

---

## HTTP verb discipline — PUT is not a footnote

Some webshell families use PUT instead of, or alongside, POST. Reasons:

- REST-API-compliance masquerade — PUT is the "update a resource" verb, so it looks less anomalous to a rules engine tuned for POST floods.
- Apache/nginx configurations that disable body inspection for POST may forward PUT unexamined.
- Multipart-form detection heuristics commonly key on `multipart/form-data` under POST and miss PUT bodies.

**Never filter only POST** when enumerating webshell traffic. The verb set to enumerate is `{POST, PUT, PATCH, DELETE}` plus any non-standard verbs the site accepts (WebDAV sites carry `MOVE`, `COPY`, `PROPFIND`). Filter by "is-not-GET-or-HEAD" when in doubt.

---

## Audit-log vs transfer-log visibility gap

The audit log is silent on most 200s under stock CRS (`SecAuditLogRelevantStatus` filters to 5xx + most 4xx). An investigator asking "does the audit log show this successful POST?" and getting "no" must not conclude the request didn't happen — see `skills/linux-forensics/modsec-audit-format.md §Visibility gap #1` for the configuration details.

---

## Triage checklist

- [ ] Identify the candidate shell path(s) from filesystem survey or prior analysis
- [ ] Extract `(client_ip, method, path, status)` tuples from the transfer log for each candidate path
- [ ] Enumerate all non-GET/HEAD verbs — do not filter to POST only
- [ ] Tabulate status distribution per `(ip, method)` bucket
- [ ] Apply the four-status rule (200 / 403 / 404 / 302) per bucket to reach a per-host verdict
- [ ] On 502/504: look for retry chains from the same IP and classify on the retry outcome
- [ ] Flag any 200 response — including zero-body responses — as compromise confirmed
- [ ] Cross-reference to the audit log; absence of 200s there is expected, not exculpatory
- [ ] On 404: run filesystem check before concluding the file is gone

---

## See also

- [apache-transfer-log.md](apache-transfer-log.md) — format and field-level parsing of the transfer log that feeds this correlation step
- [modsec-audit-format.md](modsec-audit-format.md) — why the audit log is often silent on the requests that matter most
- [maldet-session-log.md](maldet-session-log.md) — the on-disk side of the verdict: is the file still there, was it quarantined, does the hash match a known family

<!-- adapted from beacon/skills/log-forensics/post-to-shell-correlation.md (2026-04-23) — v2-reconciled -->
