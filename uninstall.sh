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
BL_CONF_DIR="${BL_PREFIX}/etc/blacklight"
BL_LMD_CONF="${BL_LMD_CONF_PATH:-/usr/local/maldetect/conf.maldet}"
MODE="interactive"

while (( $# > 0 )); do
    case "$1" in
        --yes) MODE="yes"; shift ;;
        --keep-state) MODE="keep"; shift ;;
        --prefix) BL_PREFIX="$2"; BL_BIN="${BL_PREFIX}/usr/local/bin/bl"; BL_STATE_DIR="${BL_PREFIX}/var/lib/bl"; BL_CONF_DIR="${BL_PREFIX}/etc/blacklight"; shift 2 ;;
        -h|--help) sed -n '2,/^set -euo/{/^set -euo/d;p}' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) printf 'uninstall.sh: unknown flag: %s\n' "$1" >&2; exit 1 ;;
    esac
done

_info() { printf '==> %s\n' "$*"; }
_warn() { printf 'uninstall.sh: %s\n' "$*" >&2; }

# For full remote cleanup (agent + routing Skills + workspace Files), run this before
# uninstalling:
#   bl setup --reset --force
# Without this, the Anthropic workspace retains the bl-curator agent + uploaded Files.
# uninstall.sh removes only the local binary and local state directory.

# --- Remove post_scan_hook wired by `bl setup --install-hook lmd` ---
if [[ -f "$BL_LMD_CONF" ]]; then
    if grep -qE '^post_scan_hook=.*bl-lmd-hook' "$BL_LMD_CONF" 2>/dev/null; then   # 2>/dev/null: grep chatter irrelevant; checking exit code only
        _info "removing post_scan_hook from $BL_LMD_CONF"
        command sed -i.bl-uninstall-bak -E '/^post_scan_hook=.*bl-lmd-hook/d' "$BL_LMD_CONF"
        command rm -f "$BL_LMD_CONF.bl-uninstall-bak"
        _info "post_scan_hook removed"
    fi
fi

# --- Binary removal ---
if [[ -f "$BL_BIN" ]]; then
    _info "removing $BL_BIN"
    command rm -f "$BL_BIN"
else
    _info "no binary at $BL_BIN — skipping"
fi

# --- /etc/blacklight/ removal prompt ---
if [[ -d "$BL_CONF_DIR" ]]; then
    conf_confirm="n"
    case "$MODE" in
        yes)
            conf_confirm="y"
            ;;
        keep)
            _info "preserving $BL_CONF_DIR (--keep-state)"
            ;;
        interactive)
            if [[ -t 0 ]]; then
                printf 'Remove blacklight config tree at %s (hooks, notify tokens)? [y/N] ' "$BL_CONF_DIR"
                read -r conf_confirm
            else
                _info "non-interactive invocation — preserving $BL_CONF_DIR"
                _info "re-run with --yes to remove, or --keep-state to silence this message"
            fi
            ;;
    esac
    case "$conf_confirm" in
        y|Y|yes|YES)
            _info "removing $BL_CONF_DIR"
            command rm -rf "$BL_CONF_DIR"
            ;;
        *)
            if [[ "$MODE" != "keep" ]]; then
                _info "config tree preserved at $BL_CONF_DIR"
            fi
            ;;
    esac
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
