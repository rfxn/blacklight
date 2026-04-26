# from-post-scan-hook — TSV-to-Kill-Chain Backwalk

**Scenario first.** A cPanel shared-hosting server runs LMD with post_scan_hook.
At 03:12 UTC the hook fires with `LMD_HITS=9`, `LMD_SCANID=scan.28a1f4`,
session-file at `/var/lib/maldetect/sessions/scan.28a1f4`. Nine file paths,
three distinct sigids, all nine mtimes within a 90-second window under
`/home/<user>/public_html/`. `bl trigger lmd` opens a case with fingerprint
`b4c2e91f3a0d5e87`. The curator's first turn question: is this a post-exploitation
batch drop from an APSB25-94-class compromise, or a false-positive cluster from
a plugin installation?

The kill-chain backwalk answers this question by working backward from the LMD
hit timestamps through the access log to find the delivery event.

**Public source grounding.** The backwalk discipline is grounded in the published
APSB25-94 advisory and associated public threat-intel reporting on Adobe Commerce /
Magento pre-auth RCE post-exploitation shape (see `skills/apsb25-94/exploit-chain.md`
for the specific drop→dispatch→callback sequence derived from the advisory).

---

## 1. TSV-to-JSONL normalization

Before backwalking, normalize the LMD session-file to JSONL using
`bl trigger lmd`'s built-in `_bl_trigger_lmd_read_session`:

```
Input TSV row (tab-separated):
  2026-03-15T03:11:47Z  hex:0b14e7f  /home/user/public_html/.cache/image-proc.php  sha256...  quarantine

Output JSONL record:
  {"ts":"2026-03-15T03:11:47Z","sig":"hex:0b14e7f","path":"/home/user/public_html/.cache/image-proc.php","hash":"sha256...","flags":"quarantine"}
```

The `sig` field carries the LMD signature ID (format: `hex:<pattern-id>`,
`md5:<hash>`, or a named rule like `php.dropper.obfu.generic`). Sort by `ts`
ascending for the drop timeline.

---

## 2. Establish the mtime cluster

With JSONL sorted by `ts`, look for the mtime cluster boundary:

- **Tight cluster (< 5 minutes total span):** consistent with a scripted
  batch-drop from an RCE payload. All files written in one execution context.
- **Wide spread (> 30 minutes between first and last):** plugin install, theme
  update, FTP upload session, or malware re-infection at different times. Treat
  as scattered, not a single kill chain.
- **Multi-wave (tight cluster + isolated later drop):** first cluster = initial
  compromise; later drop = persistence reinstall after partial cleanup.

Propose `observe.fs_mtime_cluster` to confirm mtime clustering against the
directory tree. LMD's TSV timestamps are scan-observation times, not necessarily
file mtimes — the `observe.fs_mtime_cluster` result is authoritative.

---

## 3. Backwalk to the delivery event

Once the mtime cluster is confirmed, walk backward in the Apache access log to find
the delivery event. The access log is the evidence chain link between the RCE
exploit (`POST` to `/rest/V1/` or `/index.php/rest/V1/`) and the file drop.

**Step sequence:**

1. Propose `observe.log_apache` with a time window bracketing T_first_drop - 5min
   to T_first_drop + 1min.

2. In the access log result, look for:
   - `POST /rest/V1/<endpoint>` or `POST /index.php/rest/V1/<endpoint>` from an
     unauthenticated source IP (no prior auth session), body length > 0, status
     200 or 500.
   - The first `GET` or `POST` to the dropped file path within 60 seconds of
     the RCE `POST` — this is the dispatch event.

3. If found: the delivery event is the `POST` to the REST endpoint. Record in
   `bl-case/<id>/evidence/evid-<N>.md` with `source_refs` pointing to the APSB25-94
   advisory and the advisory URL. Record the source IP as the initial-access indicator.

4. If not found in the access log window: extend the window. If still not found
   after a 30-minute pre-drop window: consider alternative delivery vectors
   (cron, FTP, another compromised vhost). The absence of an RCE `POST` does not
   rule out compromise — some deployments strip the REST path from access logs or
   use a front-end proxy that logs differently.

---

## 4. APSB25-94 worked example

**Setup.** Magento 2.4.7-p2 on a cPanel EA4 host. LMD reports 7 hits under
`/home/shopowner/public_html/`, all with sigid `hex:0b14e7f` (polyshell loader
family), mtime window 03:11:47–03:12:54 UTC.

**Step 1 — normalize and cluster.** TSV → JSONL. All 7 paths confirmed tight
cluster by `observe.fs_mtime_cluster`. Parent directory:
`/home/shopowner/public_html/vendor/magento/framework/.cache/`. Consistent with
writable-path drop per `skills/magento-attacks/writable-paths.md`.

**Step 2 — access log backwalk.** Propose `observe.log_apache` window
03:06:47–03:12:47 UTC. Result shows:
```
03:11:42  POST /rest/V1/integration/customer/token  200  body=847  src=198.51.100.42
03:11:44  GET /vendor/magento/framework/.cache/image-proc.php  200  src=198.51.100.42
```

The `POST /rest/V1/integration/customer/token` at 03:11:42 is the initial-access
event — pre-auth REST endpoint targeted per APSB25-94 (exploit-chain.md §Initial
access vector). The `GET` at 03:11:44 (2-second gap) is the dispatch event
confirming the drop succeeded.

**Step 3 — record evidence.** Write `evid-001.md` citing:
- `source_refs`: Adobe APSB25-94 advisory URL + public post-advisory research
- `observed.initial-access-source-ip`: 198.51.100.42
- `observed.initial-access-vector`: "APSB25-94-class: pre-auth POST /rest/V1/integration/customer/token"

**Step 4 — hypothesis.** Update hypothesis: "APSB25-94-class pre-auth RCE;
initial access via /rest/V1/; PolyShell-family loader dropped in vendor/.cache/;
7-file batch drop at 03:11:47; dispatch confirmed 03:11:44; confidence 0.82."

---

## 5. Named failure modes

**FP cluster from plugin install.** A Magento plugin install via composer or admin
uploads can create dozens of `.php` files in a tight mtime window, all under
`vendor/`. LMD's `php.dropper.obfu.generic` rule fires on PHP files containing
`eval()` or `base64_decode()` — common in legitimate minified JS loaders and
plugin bootstraps. Discriminating signal: no corresponding `POST /rest/V1/`
before the drop; mtime cluster spans a full console session duration (2–15 min
rather than < 90 sec); files are in named plugin dirs, not `.cache/` or
`.tmp/` leaf dirs.

**Race: hook fires before TSV write.** LMD fires the hook on scan completion but
writes the session-file asynchronously. If `bl trigger lmd` reads an empty TSV
immediately after hook invocation, it opens a degraded stub case. The curator
should wait for a `bl case log` entry showing the full hit set before proposing
the backwalk. The degraded path is documented in `lmd-triggers/SKILL.md §2`.

**Proxy-stripped access log.** If the cPanel server sits behind Cloudflare or a
reverse proxy, the access log source IP will be the proxy IP, not the attacker
IP. The `X-Forwarded-For` header carries the real IP but requires the access log
format to include it (CustomLog combined). Check `observe.log_apache` output for
`CF-Connecting-IP` or `X-Real-IP` fields before attributing the source IP.

**Multi-user lateral spread.** If LMD hits span more than one user's docroot on
the same cPanel server, the backwalk applies per-user — the drop timestamps and
access-log source IP may differ if the attacker hit multiple accounts. Check
`ip-clusters.md` for source IP overlap across vhosts before declaring a single
kill chain.

---

## Pointers

- `skills/apsb25-94/exploit-chain.md` — exploit sequence from public APSB25-94 advisory
- `skills/apsb25-94/indicators.md` — APSB25-94 indicator types and sources
- `skills/webshell-families/polyshell.md` — PolyShell loader family signature
- `skills/magento-attacks/writable-paths.md` — Magento writable drop targets
- `skills/lmd-triggers/quarantine-vs-cleanup.md` — LMD quarantine vs. bl clean discipline
- `skills/cpanel-easyapache/SKILL.md` — substrate router for cPanel EA4 defend path
- `/skills/synthesizing-evidence-corpus.md` — kill-chain reconstruction and mtime analysis
