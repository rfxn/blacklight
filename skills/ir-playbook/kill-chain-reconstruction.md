# Kill-Chain Reconstruction

The kill chain is how the curator narrates an intrusion to the operator — five stages from initial exploitation to persistent access, each anchored to an ATT&CK technique and a public artifact. When the curator is revising `attribution.md` after a new evidence batch lands, this is the skeleton the narrative hangs on.

**Source authority:**

- <https://attack.mitre.org/techniques/T1190/> — Exploit Public-Facing Application
- <https://attack.mitre.org/techniques/T1505/003/> — Server Software Component: Web Shell
- <https://attack.mitre.org/techniques/T1027/> — Obfuscated Files or Information
- <https://attack.mitre.org/techniques/T1071/001/> — Application Layer Protocol: Web Protocols
- <https://attack.mitre.org/techniques/T1053/003/> — Scheduled Task/Job: Cron
- <https://attack.mitre.org/techniques/T1059/004/> — Command and Scripting Interpreter: Unix Shell
- <https://www.lockheedmartin.com/en-us/capabilities/cyber/cyber-kill-chain.html> — Lockheed Martin Cyber Kill Chain
- <https://helpx.adobe.com/security/products/magento/apsb25-94.html> — Adobe Security Bulletin APSB25-94
- <https://sansec.io/research/magento-polyshell> — Sansec PolyShell research (public)
- <https://attack.mitre.org/resources/working-with-attack/> — ATT&CK versioning, STIX, Navigator

---

## Canonical chain

Five kill-chain stages cover the full intrusion arc. Each stage maps to an ATT&CK technique and a corresponding Cyber Kill Chain phase. The curator writes this shape into `bl-case/CASE-<id>/attribution.md`.

| Stage | ATT&CK ID | Name | Kill Chain Phase | Description |
|-------|-----------|------|------------------|-------------|
| 1 | T1190 | Exploit Public-Facing Application | Exploitation | Adversary sends a crafted request to an unauthenticated endpoint; server processes it without authentication check |
| 2 | T1505.003 | Server Software Component: Web Shell | Installation | Exploit causes a server-executable file (PHP, JSP, ASPX) to be written to a web-accessible path |
| 3 | T1027 | Obfuscated Files or Information | Weaponization | Shell file uses magic-byte spoofing, multi-layer encoding, or string concatenation to evade signature detection |
| 4 | T1071.001 | Application Layer Protocol: Web Protocols | Command & Control | Adversary issues commands via HTTP/HTTPS requests to the dropped shell; responses carry command output |
| 5 | T1053.003 | Scheduled Task/Job: Cron | Actions on Objectives | Second-stage payload (if deployed) writes a cron entry for persistence across reboots |

Stage 5 is conditional. Its absence is a positive finding — record "no persistence observed" explicitly rather than leaving the field blank.

---

## Stage-by-stage evidence requirements

### Stage 1 — T1190 (Exploit)

Required evidence to anchor T1190:

- HTTP request log entry for the exploited endpoint (method, path, response code, payload fragment)
- Correlation with a public vulnerability advisory (advisory ID, not inferred)
- Timestamp within the known exploitation window for the vulnerability

Insufficient on its own: unusual POST traffic without endpoint correlation; error log spikes without request log match.

### Stage 2 — T1505.003 (Web Shell Dropped)

Required evidence to anchor T1505.003 (sub-technique preferred over parent T1505):

- File path of the dropped shell (web-accessible directory, not a code deployment path)
- File content confirmed as server-executable (PHP opening tag, eval pattern, or signature match)
- File creation or modification timestamp overlapping Stage 1 window

Insufficient on its own: file found in a code deployment path (may be legitimate); file timestamp does not overlap Stage 1.

### Stage 3 — T1027 (Obfuscation)

Required evidence to anchor T1027:

- Static analysis of the dropped file revealing encoding layers (base64, gzip, hex) or magic-byte spoofing
- Tool or manual decode confirming inner payload is distinct from outer file type
- Obfuscation pattern matches a known variant (polyglot, triple-base64, eval-chain)

Insufficient on its own: file has unusual extension (extension alone does not confirm obfuscation); file is binary (binary != obfuscated).

### Stage 4 — T1071.001 (C2 via Web Protocol)

Required evidence to anchor T1071.001:

- HTTP access log entries hitting the shell path after Stage 2 timestamp
- Request parameters or cookie values carrying encoded payloads
- Response body containing command output (directory listing, process list, file content)

Insufficient on its own: requests to the shell path that return 404 (shell may have been removed before C2); requests with empty response bodies (see `linux-forensics/post-to-shell-correlation.md` for the zero-byte-200 trap).

### Stage 5 — T1053.003 (Cron Persistence)

Required evidence to anchor T1053.003:

- Modified cron file (`/etc/cron*`, `/var/spool/cron/`, or user crontab) with modification timestamp post-Stage 2
- Cron entry content referencing the adversary's payload path or remote URL
- Process tree showing web-server user executing `crontab` or writing to cron directories via Stage 4

When absent: record `"no persistence observed"` in `attribution.md`. Do not omit the field — absence is analytically significant (adversary may have operated without persistence or cleaned up).

---

## PolyShell worked example

This example uses only publicly disclosed facts from the Adobe APSB25-94 advisory and Sansec PolyShell research. No victim-specific data is included.

**Stage 1 — T1190 (Exploit): Unauthenticated Cart Endpoint Abuse**

Source: Adobe security bulletin APSB25-94 (<https://helpx.adobe.com/security/products/magento/apsb25-94.html>)

The vulnerable endpoint accepts a `POST /rest/V1/guest-carts/{cartId}/items` request with a `file_info` parameter in the custom options payload. The endpoint does not require authentication. A crafted request places a filename with a `.php` extension into `file_info`. The Magento core processes the file metadata and writes the file to the media storage path without validating the file type.

Evidence to collect: the POST request in the web server access log, including the full URL path, the `file_info` payload fragment, and the HTTP response code (typically 200 OK or 201 Created).

**Stage 2 — T1505.003 (Web Shell): PHP File Landed in Media Directory**

Source: Sansec PolyShell research (<https://sansec.io/research/magento-polyshell>)

The Magento custom-options file handler writes the uploaded file to a path under `pub/media/custom_options/quote/{a}/{b}/{filename}.php`. This path is web-accessible and the Magento configuration (prior to the patch) does not disable PHP execution in the `pub/media/` subtree by default on all hosting configurations.

Evidence to collect: the file path of the dropped `.php` file, the file's SHA-256 hash (for cross-incident correlation), and the file creation timestamp relative to the Stage 1 request.

**Stage 3 — T1027 (Obfuscation): GIF89a Polyglot with Triple-Base64**

Source: Sansec PolyShell research (<https://sansec.io/research/magento-polyshell>)

The PolyShell variant opens with the GIF89a magic bytes, causing file-type scanners that rely on magic-byte inspection to classify the file as an image. The PHP content follows the magic bytes. The inner PHP payload uses triple-nested base64 encoding (`eval(base64_decode(base64_decode(base64_decode(...))))`) to evade string-match signatures. See `webshell-families/polyshell.md` for the static decode procedure.

Evidence to collect: the raw file hex dump (first 16 bytes to confirm GIF89a header), output of a PHP static decoder applied to the file, and classification output from the signature engine.

**Stage 4 — T1071.001 (C2): HTTP Requests to the Shell Path**

Subsequent requests to `pub/media/custom_options/quote/{a}/{b}/shell.php` carry commands in GET parameters (e.g., `?cmd=id`) or in cookie values. The HTTP response body contains the command output. Access log entries for these requests are typically distinguishable from normal media access by: unusual user agents, low request volume (not crawl-like), and response sizes inconsistent with image files (a directory listing or `id` output is 40–200 bytes, not kilobytes).

Evidence to collect: access log entries hitting the shell path with non-image request parameters, the HTTP response size (to distinguish C2 from normal image serving), and any observable command output captured via response logging.

**Stage 5 — T1053.003 (Cron): Conditional Persistence**

When a second-stage payload is deployed via Stage 4, it may write a cron entry to establish persistence. The entry typically calls a remote URL or executes a local script written to a temp path. When Stage 5 is absent, record "no persistence observed" — this is a positive analytical conclusion, not a data gap.

Evidence to collect: cron directory modification timestamps post-Stage 2; cron entry content (if present); file integrity monitoring alerts for cron paths.

---

## ATT&CK technique reference

The curator records technique IDs in `attribution.md` as a list of objects. Each entry has exactly three fields:

- `id` — canonical dotted form (e.g., `T1505.003`). Sub-technique preferred when evidence is specific.
- `confidence` — one of `high`, `medium`, `low`. No numeric scores, no percentages.
- `evidence` — ≤200 chars; cites the specific artifact or log line that anchors the ID.

### Technique ID syntax

The canonical form is `TNNNN` for techniques and `TNNNN.NNN` for sub-techniques.

| Form | Example | Status |
|------|---------|--------|
| Canonical technique | `T1505` | Valid — use when sub-technique is uncertain |
| Canonical sub-technique | `T1505.003` | Valid — preferred when evidence is specific |
| URL path form | `T1505/003` | Invalid — this is the ATT&CK website URL fragment, not the ID |
| Legacy underscore | `T1505_003` | Invalid — not used in any ATT&CK release |
| Lowercase | `t1505.003` | Invalid — IDs are always uppercase |

### Most-used technique IDs in web-shell intrusions

| ID | Name | Tactic | Intrusion Stage | Typical Evidence |
|----|------|--------|-----------------|-----------------|
| T1190 | Exploit Public-Facing Application | Initial Access | Entry — adversary reaches the server | Anomalous POST to an unauthenticated endpoint; vulnerability advisory match; error-log spike correlating with public PoC release |
| T1505.003 | Server Software Component: Web Shell | Persistence | Implant — server-executable file dropped | PHP/JSP/ASPX file in a non-code directory; file timestamp near the exploitation window; file content matches web-shell signatures |
| T1027 | Obfuscated Files or Information | Defense Evasion | Concealment — shell evades detection | Multi-layer base64; polyglot magic bytes (GIF89a + PHP); string-split concatenation; eval(gzinflate()) patterns |
| T1071.001 | Application Layer Protocol: Web Protocols | Command and Control | C2 — adversary issues commands | GET/POST to the dropped shell path; response contains command output; cookie or parameter carries encoded payload |
| T1059.004 | Command and Scripting Interpreter: Unix Shell | Execution | Execution — OS commands run | Shell command output in HTTP response; process tree spawned by web-server user; `id`, `whoami`, `uname` in response body |
| T1053.003 | Scheduled Task/Job: Cron | Persistence | Persistence — adversary survives reboot | Modified `/etc/cron*` or user crontab; second-stage payload written by web-shell command |

### Confidence calibration

| Band | Criteria | Example |
|------|----------|---------|
| **high** | Direct forensic artifact confirms the technique (file present, log line captured, command output visible) | `pub/media/shell.php` found on disk; content matches T1505.003 |
| **medium** | Strong circumstantial indicators; artifact may have been removed or logging incomplete | File timestamp and error log spike align; no file recovered from backup |
| **low** | Technique is consistent with observed behavior but no direct artifact; inference from surrounding events only | No cron entry found, but a 4 AM periodic callback pattern is visible in access logs |

**Do not assign without evidence.** If a stage is suspected but no supporting artifact or log line exists, record the technique as absent or omit it from `attribution.md`. An unanchored technique ID introduces false confidence and corrupts downstream correlation.

### Disambiguation between similar techniques

**T1190 vs T1133 (External Remote Services)**

| Question | T1190 | T1133 |
|----------|-------|-------|
| Does the adversary exploit a vulnerability? | Yes — T1190 | No |
| Is access gained via a legitimate service with stolen credentials? | No | Yes — T1133 |
| Ruling heuristic | Exploit or unauthenticated endpoint abuse → T1190 | VPN/RDP with valid credentials → T1133 |

**T1505.003 vs T1059.004 (Unix Shell)**

| Question | T1505.003 | T1059.004 |
|----------|-----------|-----------|
| Was a persistent file dropped on the server? | Yes — T1505.003 | No |
| Was a command executed directly via an exploit (no dropped file)? | No | Yes — T1059.004 |
| Ruling heuristic | File on disk + HTTP access to that file → T1505.003 | Direct command execution via exploit, no server-side script → T1059.004 |

**T1027 vs T1140 (Deobfuscate/Decode Files or Information)**

| Question | T1027 | T1140 |
|----------|-------|-------|
| Is the obfuscation applied by the adversary to hide the payload? | Yes — T1027 | No |
| Does the victim system decode the payload as part of execution? | Incidental | Yes — T1140 |
| Ruling heuristic | Layers applied before delivery → T1027; system decodes as part of execution → T1140. Both can apply simultaneously. |

### Sub-technique inheritance

When a parent technique is confirmed but the specific sub-technique cannot be determined, record the parent at medium confidence:

```
- id: T1505      # parent; sub-type uncertain
  confidence: medium
  evidence: "PHP file dropped in media directory; content not recovered for sub-type determination"
```

Do not invent sub-technique specificity. If `T1505.003` requires a server-side script confirmed by file content inspection, and the file was deleted before recovery, use the parent `T1505` at medium.

### ATT&CK versioning

ATT&CK techniques are renamed and reorganized across major releases. A technique ID assigned under ATT&CK v14 may have a different name under v16. When referencing ATT&CK pages, link to the stable path form (`/techniques/TNNNN/NNN/`) — these redirect to the current version. Do not link to Navigator snapshots, which are version-pinned and become stale. Record the ATT&CK version in use at the time of the investigation in the case metadata.

---

## Variant chains

When the canonical chain does not fit, use one of these variants. Do not force-fit evidence into the canonical chain.

**Deserialization Variant (T1559)**

Applicable when the intrusion vector is a PHP deserialization gadget chain rather than a file-upload endpoint:

`T1190 → T1559 (Inter-Process Communication) → T1027 → T1071.001`

The Stage 2 artifact is an in-memory RCE rather than a dropped file. T1505.003 does not apply unless a shell file is subsequently written. CVE-2025-54236 (SessionReaper) follows this pattern.

**Direct-RCE Variant (T1059.004)**

Applicable when the intrusion achieves direct OS command execution without dropping a persistent file:

`T1190 → T1059.004 (Unix Shell) → T1071.001`

T1505.003 does not apply. The distinguishing evidence is absence of a dropped file combined with presence of command output in the HTTP response at Stage 1/2 timing.

---

## Chain-break defense map

Each stage can be interrupted by a defensive control. Recording where the chain broke is analytically valuable — it identifies which control was effective. The curator captures this in `defense-hits.md`.

| Stage Interrupted | Defense That Works | Analytical Note |
|------------------|-------------------|-----------------|
| Stage 1 | WAF rule blocks the malformed `file_info` parameter | Chain terminates at entry; no file dropped |
| Stage 2 | PHP execution disabled in `pub/media/` (`php_flag engine off` in `.htaccess` or server config) | File may still be written but cannot execute; Stage 3+ cannot proceed |
| Stage 3 | AV/EDR signature matches the polyglot on write | File dropped but quarantined before Stage 4 proceeds |
| Stage 4 | C2 blocklist or outbound HTTP filter blocks the adversary's source IP | Shell is present but the adversary cannot reach it |
| Stage 5 | File integrity monitoring on cron paths detects and reverts the entry | Persistence established briefly but removed before reboot |

---

## Failure modes

| Failure Mode | Why It Fails | Correction |
|--------------|--------------|------------|
| Assigning T1053.003 without a confirmed cron artifact | Persistence assumed rather than observed | Record "no persistence observed"; assign T1053.003 only with a cron file modification |
| Listing Stage 4 without access log evidence | C2 inferred from "the shell would have been used" reasoning | Require at least one access log entry hitting the shell path post-drop |
| Using T1505.003 when only a non-PHP file was dropped | T1505.003 is specifically a server-side executable script | Use T1027 (concealment) or T1105 (Ingress Tool Transfer) for non-executable uploads |
| Treating Stage 5 absence as a data gap | Absence of cron persistence is analytically meaningful | Record it as a positive finding |
| Recording `confidence: high` for techniques inferred from log gaps | Absence of log evidence is not positive evidence of a technique | Downgrade to `low` or omit; document the log gap explicitly in `open-questions.md` |
| Citing the ATT&CK webpage URL as the evidence field value | Evidence must cite artifact, not reference material | Replace with the artifact path, log line, or timestamp |
| Listing all possible techniques without evidence | Produces noise and dilutes true-positive signal | Only include techniques supported by at least low-confidence evidence |

---

## Triage checklist

The curator walks this list before closing an `attribution.md` revision:

- [ ] Stage 1 evidence: access log entry for the exploit request, advisory correlation
- [ ] Stage 2 evidence: file path, SHA-256 hash, creation timestamp
- [ ] Stage 3 evidence: static decode output, magic-byte dump, obfuscation variant identified
- [ ] Stage 4 evidence: access log entries to shell path post-drop, at least one request with payload/response
- [ ] Stage 5 evidence: cron directories inspected; result recorded (entry found OR "no persistence observed")
- [ ] Chain breaks documented in `defense-hits.md`: which stage was interrupted by which control, if any
- [ ] Variant applied if canonical does not fit (deserialization or direct-RCE variants)
- [ ] Each technique ID in canonical dotted form (no URL form, no underscore form)
- [ ] Each entry cites a specific artifact or log line; no evidence field exceeds 200 characters
- [ ] Confidence bands applied per the three-band calibration (no numeric scores)
- [ ] Disambiguated confusing pairs (T1190 vs T1133; T1505.003 vs T1059.004; T1027 vs T1140)
- [ ] Parent technique used when sub-type cannot be confirmed from available artifacts

---

## See also

- [../webshell-families/polyshell.md](../webshell-families/polyshell.md)
- [../apsb25-94/exploit-chain.md](../apsb25-94/exploit-chain.md)
- [../apsb25-94/indicators.md](../apsb25-94/indicators.md)
- [../actor-attribution/role-taxonomy.md](../actor-attribution/role-taxonomy.md)
- [../timeline/interval-segmentation.md](../timeline/interval-segmentation.md)

<!-- adapted from beacon/skills/kill-chain/web-shell-chain.md + beacon/skills/kill-chain/mitre-attack-mapping.md (2026-04-23) — v2-reconciled, merged -->
