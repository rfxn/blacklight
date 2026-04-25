#!/bin/bash
#
# uninstall.sh — remove blacklight binary; offer state purge with confirm
#
# Copyright (C) 2026 R-fx Networks <proj@rfxn.com>
# Author: Ryan MacDonald <ryan@rfxn.com>
# License: GNU GPL v2
#
# Usage:  ./uninstall.sh                   # interactive — prompts before state purge
# Usage:  ./uninstall.sh --yes             # non-interactive — purges state with backup
# Usage:  ./uninstall.sh --keep-state      # remove binary only, leave state intact
# Usage:  BL_PREFIX=/opt ./uninstall.sh    # match install.sh prefix
#
# Spec: PLAN.md §M10

set -euo pipefail

BL_PREFIX="${BL_PREFIX:-}"
BL_BIN="${BL_PREFIX}/usr/local/bin/bl"
BL_STATE_DIR="${BL_PREFIX}/var/lib/bl"
MODE="interactive"

while (( $# > 0 )); do
    case "$1" in
        --yes) MODE="yes"; shift ;;
        --keep-state) MODE="keep"; shift ;;
        --prefix) BL_PREFIX="$2"; BL_BIN="${BL_PREFIX}/usr/local/bin/bl"; BL_STATE_DIR="${BL_PREFIX}/var/lib/bl"; shift 2 ;;
        -h|--help) sed -n '2,/^set -euo/{/^set -euo/d;p}' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) printf 'uninstall.sh: unknown flag: %s\n' "$1" >&2; exit 1 ;;
    esac
done

_info() { printf '==> %s\n' "$*"; }
_warn() { printf 'uninstall.sh: %s\n' "$*" >&2; }

# --- Binary removal ---
if [[ -f "$BL_BIN" ]]; then
    _info "removing $BL_BIN"
    command rm -f "$BL_BIN"
else
    _info "no binary at $BL_BIN — skipping"
fi

# --- State handling ---
if [[ ! -d "$BL_STATE_DIR" ]]; then
    _info "no state directory at $BL_STATE_DIR — uninstall complete"
    exit 0
fi

case "$MODE" in
    keep)
        _info "preserving state at $BL_STATE_DIR (--keep-state)"
        exit 0
        ;;
    yes)
        confirm="yes"
        ;;
    interactive)
        if [[ ! -t 0 ]]; then
            _info "non-interactive invocation — preserving state at $BL_STATE_DIR"
            _info "re-run with --yes to purge, or --keep-state to silence this message"
            exit 0
        fi
        printf 'Remove blacklight state at %s (case records, ledger, outbox)? [y/N] ' "$BL_STATE_DIR"
        read -r confirm
        ;;
esac

case "$confirm" in
    y|Y|yes|YES)
        ts=$(date +%Y%m%d-%H%M%S)
        bk="${BL_PREFIX}/var/lib/bl.bk.${ts}"
        _info "backing up state to $bk"
        command mv "$BL_STATE_DIR" "$bk"
        _info "state preserved — remove manually with: rm -rf '$bk'"
        ;;
    *)
        _info "state preserved at $BL_STATE_DIR"
        ;;
esac

_info "uninstall complete"
