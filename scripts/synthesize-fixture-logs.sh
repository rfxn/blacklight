#!/usr/bin/env bash
#
# synthesize-fixture-logs.sh <host-label> <access.log> [<modsec.log> [<journal.json> [<lines>]]]
#
# Generates APSB25-94-shaped fixture logs (Apache combined CLF, ModSec
# A/B/F/H/Z sections, journalctl -o json) for exhibits/fleet-01/. Sources
# only public Adobe advisory IOC patterns + RFC 5737 documentation IP
# ranges — never any operator-local material. Deterministic per
# BL_FIXTURE_SEED (default 42); committed fixtures regenerate
# byte-identically. The committed files are pre-generated so test loads
# do not pay synthesis cost; this script is their source of truth.
#
# Copyright (C) 2026 R-fx Networks <proj@rfxn.com>
# Author: Ryan MacDonald <ryan@rfxn.com>
# License: GNU GPL v2

set -euo pipefail
export LC_ALL=C

if ! command -v gawk >/dev/null 2>&1; then  # gawk strftime() third-arg=1 needed for deterministic UTC
    printf 'synthesize-fixture-logs: gawk required (uses strftime third-arg UTC; mawk lacks it)\n' >&2
    exit 65
fi

HOST="${1:?host label required}"
ACCESS_LOG="${2:?access.log path required}"
MODSEC_LOG="${3:-}"
JOURNAL="${4:-}"
LINES="${5:-50000}"
SEED="${BL_FIXTURE_SEED:-42}"

# Public APSB25-94 IOC patterns (Adobe advisory + Sansec public reporting).
# All IPs are RFC 5737 documentation ranges (TEST-NET-1/2/3) — never routable.
ATTACKER_IPS=(203.0.113.42 198.51.100.7 198.51.100.77 192.0.2.99 203.0.113.180 198.51.100.213)
BENIGN_IPS=(192.0.2.10 192.0.2.11 192.0.2.12 192.0.2.13 192.0.2.14 192.0.2.15 192.0.2.20)
WEBSHELL_PATHS=(
    "/pub/media/catalog/product/.cache/a.php"
    "/pub/media/wysiwyg/.cache/upload.php"
    "/pub/media/captcha/.tmp/x.php"
)
POLYGLOT_EXTS=(.gif .jpg .png)
DISPATCH_PARAMS=(c cmd op x f h)
# 2026-03-22T12:00:00Z — fixed base epoch, deterministic across runs.
BASE_EPOCH=1774180800

# User-Agent strings carry embedded spaces; pass via TSV in a single -v arg so
# the awk side can split on \t without losing tokens. Same trick for any
# future multi-word fields.
UAS_TSV=$'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/123.0.0.0 Safari/537.36\tMozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/123.0.0.0 Safari/537.36\tMozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.3 Safari/605.1.15\tcurl/7.88.1'
BPATHS_TSV=$'/index.php\t/catalog/category/view/id/3/\t/catalog/product/view/id/42/\t/checkout/cart/\t/customer/account/\t/api/rest/V1/products\t/pub/static/frontend/Magento/luma/en_US/css/styles-m.css\t/pub/media/catalog/product/cache/1/image/800x/productmain.jpg'

command gawk -v seed="$SEED" -v lines="$LINES" -v base="$BASE_EPOCH" \
    -v atk="${ATTACKER_IPS[*]}" -v ben="${BENIGN_IPS[*]}" \
    -v ws="${WEBSHELL_PATHS[*]}" -v bp="$BPATHS_TSV" \
    -v exts="${POLYGLOT_EXTS[*]}" -v dps="${DISPATCH_PARAMS[*]}" \
    -v uas="$UAS_TSV" '
BEGIN {
    srand(seed)
    n_atk = split(atk, A, " "); n_ben = split(ben, B, " ")
    n_ws  = split(ws,  W, " "); n_bp  = split(bp, P, "\t")
    n_exts = split(exts, E, " "); n_dps = split(dps, D, " ")
    n_uas = split(uas, U, "\t")
    for (i=0; i<lines; i++) {
        ts = base + i*2 + int(rand()*5)
        if (rand() < 0.05) {  # 5% attacker traffic
            ip = A[1 + int(rand()*n_atk)]
            r = rand()
            if (r < 0.55) {
                # URL-evasion polyglot GET — APSB25-94 signature
                path = W[1 + int(rand()*n_ws)] "/" sprintf("img-%d", int(rand()*9999)) E[1 + int(rand()*n_exts)] "?" D[1 + int(rand()*n_dps)] "=" sprintf("%x", int(rand()*1048576))
                meth = "GET"
                bytes = 1024 + int(rand()*4096)
                status = 200
            } else if (r < 0.85) {
                # Webshell command POST
                path = W[1 + int(rand()*n_ws)]
                meth = "POST"
                bytes = 200 + int(rand()*1500)
                status = 200
            } else {
                # Pre-auth REST exploit probe
                path = "/rest/V1/guest-carts/" sprintf("test-%d", int(rand()*9999))
                meth = "POST"
                bytes = 800 + int(rand()*2000)
                status = (rand() < 0.7) ? 200 : 500
            }
            ua = "curl/7.88.1"
        } else {
            ip = B[1 + int(rand()*n_ben)]
            path = P[1 + int(rand()*n_bp)]
            meth = (rand() < 0.92) ? "GET" : "POST"
            bytes = 5000 + int(rand()*20000)
            status = (rand() < 0.95) ? 200 : 404
            ua = U[1 + int(rand()*n_uas)]
        }
        tstr = strftime("%d/%b/%Y:%H:%M:%S +0000", ts, 1)
        printf "%s - - [%s] \"%s %s HTTP/1.1\" %d %d \"-\" \"%s\"\n", ip, tstr, meth, path, status, bytes, ua
    }
}
' > "$ACCESS_LOG"

printf 'synthesize-fixture-logs: %s lines -> %s\n' "$LINES" "$ACCESS_LOG" >&2

if [[ -n "$MODSEC_LOG" ]]; then
    # 333 transactions × 9 lines each = 2997 lines (~3K target).
    command gawk -v seed="$SEED" -v base="$BASE_EPOCH" -v host="$HOST" '
BEGIN {
    srand(seed + 1)
    for (i=0; i<333; i++) {
        ts = base + i*270
        tstr = strftime("%Y-%m-%dT%H:%M:%SZ", ts, 1)
        txn = sprintf("txn-%06d-%04x", i, int(rand()*65536))
        printf "--%s-A--\n", txn
        printf "[%s] [client 203.0.113.42] %s ModSecurity-Audit\n", tstr, host
        printf "--%s-B--\n", txn
        printf "GET /pub/media/catalog/product/.cache/a.php/banner-%d.jpg?c=%x HTTP/1.1\n", i, int(rand()*1048576)
        printf "--%s-F--\n", txn
        printf "HTTP/1.1 200 OK Content-Length: %d\n", 256 + int(rand()*4096)
        printf "--%s-H--\n", txn
        printf "Message: Pattern match \"\\\\.php/[^/]+\\\\.(jpg|png|gif)$\" at REQUEST_FILENAME [id \"941999\"] [msg \"APSB25-94 polyglot URL evasion\"] [severity \"CRITICAL\"] [tag \"application-multi\"]\n"
        printf "--%s-Z--\n", txn
    }
}
' > "$MODSEC_LOG"
    printf 'synthesize-fixture-logs: 333 modsec transactions (~3K lines) -> %s\n' "$MODSEC_LOG" >&2
fi

if [[ -n "$JOURNAL" ]]; then
    command gawk -v seed="$SEED" -v base="$BASE_EPOCH" -v host="$HOST" '
BEGIN {
    srand(seed + 2)
    msgs[0] = "AVC denied { execute } for path=\\\"/var/www/html/pub/media/catalog/product/.cache/a.php\\\""
    msgs[1] = "audit: SYSCALL=execve key=\\\"php-exec-from-media\\\" comm=\\\"php-fpm\\\""
    msgs[2] = "kernel: TCP: out-of-order segment from 203.0.113.42 to gateway"
    msgs[3] = "modsecurity: rule 941999 matched (URL-evasion polyglot)"
    msgs[4] = "audit: PATH name=\\\"/var/www/html/pub/media/wysiwyg/.cache/upload.php\\\" inode=8675309"
    n = 5
    for (i=0; i<500; i++) {
        ts = base + i*180
        rt = ts * 1000000
        m = msgs[i % n]
        printf "{\"__REALTIME_TIMESTAMP\":\"%d\",\"_HOSTNAME\":\"%s\",\"_SYSTEMD_UNIT\":\"apache2.service\",\"PRIORITY\":\"%d\",\"MESSAGE\":\"%s pid=%d\"}\n", rt, host, 3 + (i % 4), m, 1000 + i
    }
}
' > "$JOURNAL"
    printf 'synthesize-fixture-logs: 500 journal records -> %s\n' "$JOURNAL" >&2
fi
