#!/bin/bash
#
# install.sh — blacklight one-shot installer (curl-pipe-bash safe)
#
# Copyright (C) 2026 R-fx Networks <proj@rfxn.com>
# Author: Ryan MacDonald <ryan@rfxn.com>
# License: GNU GPL v2
#
# Usage (remote):  curl -fsSL https://raw.githubusercontent.com/rfxn/blacklight/main/install.sh | bash
# Usage (local):   ./install.sh --local
# Usage (custom):  BL_PREFIX=/opt ./install.sh        # installs to /opt/usr/local/bin/bl
# Usage (upgrade): BL_REPO_URL=https://... ./install.sh
#
# Spec: PLAN.md §M10 · DESIGN.md §8.3

set -euo pipefail

BL_REPO_URL="${BL_REPO_URL:-https://raw.githubusercontent.com/rfxn/blacklight/main}"
BL_PREFIX="${BL_PREFIX:-}"
BL_BIN_DIR="${BL_PREFIX}/usr/local/bin"
BL_BIN="${BL_BIN_DIR}/bl"
BL_CONF_DIR="${BL_PREFIX}/etc/blacklight"
BL_HOOKS_DIR="${BL_CONF_DIR}/hooks"
BL_SRC="${BL_SRC:-}"
BL_HOOK_SRC="${BL_HOOK_SRC:-}"
MODE="remote"

while (( $# > 0 )); do
    case "$1" in
        --local) MODE="local"; shift ;;
        --prefix) BL_PREFIX="$2"; BL_BIN_DIR="${BL_PREFIX}/usr/local/bin"; BL_BIN="${BL_BIN_DIR}/bl"; BL_CONF_DIR="${BL_PREFIX}/etc/blacklight"; BL_HOOKS_DIR="${BL_CONF_DIR}/hooks"; shift 2 ;;
        -h|--help)
            sed -n '2,/^set -euo/{/^set -euo/d;p}' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) printf 'install.sh: unknown flag: %s\n' "$1" >&2; exit 1 ;;
    esac
done

_err() { printf 'install.sh: %s\n' "$*" >&2; exit 1; }
_info() { printf '==> %s\n' "$*"; }

# --- Preflight: bash >= 4.1 ---
if (( BASH_VERSINFO[0] < 4 )) || { (( BASH_VERSINFO[0] == 4 )) && (( BASH_VERSINFO[1] < 1 )); }; then
    _err "bash >= 4.1 required (have ${BASH_VERSION})"
fi

# --- Preflight: curl + jq ---
command -v curl >/dev/null 2>&1 || _err "curl not found — install it first (apt/dnf/yum install curl)"   # existence check only; output discarded
command -v jq   >/dev/null 2>&1 || _err "jq not found — install it first (apt/dnf/yum install jq)"          # existence check only; output discarded

# --- Preflight: writable target dir (if BL_PREFIX unset, require root) ---
if [[ -z "$BL_PREFIX" ]] && [[ "$(id -u)" != "0" ]]; then
    _err "must run as root for default /usr/local/bin install — set BL_PREFIX=/some/path for non-root"
fi

command mkdir -p "$BL_BIN_DIR" || _err "cannot create $BL_BIN_DIR"

# --- Provision /etc/blacklight/ directory tree ---
_info "provisioning $BL_CONF_DIR"
command mkdir -p "$BL_CONF_DIR" "$BL_CONF_DIR/notify.d" "$BL_HOOKS_DIR" \
    || _err "cannot create $BL_CONF_DIR"
command chmod 0750 "$BL_CONF_DIR" "$BL_CONF_DIR/notify.d" "$BL_HOOKS_DIR"

# Copy blacklight.conf.default — cp -n preserves operator's customized conf
if [[ "$MODE" == "local" ]]; then
    conf_src="${BL_CONF_SRC:-./files/etc/blacklight.conf.default}"
    if [[ -f "$conf_src" ]]; then
        command cp -n "$conf_src" "$BL_CONF_DIR/blacklight.conf.default" || true  # cp -n exits non-zero when dest already exists; preserving existing conf is correct
        _info "installed blacklight.conf.default (existing preserved)"
    fi
else
    if curl -fsSL --retry 3 --retry-delay 2 \
            "$BL_REPO_URL/files/etc/blacklight.conf.default" \
            -o "$BL_CONF_DIR/blacklight.conf.default.new"; then
        command mv "$BL_CONF_DIR/blacklight.conf.default.new" "$BL_CONF_DIR/blacklight.conf.default"
    else
        _info "blacklight.conf.default fetch skipped (non-fatal)"
    fi
fi

# Copy bl-lmd-hook into hooks/ with executable bit (operator runs `bl setup
# --install-hook lmd` to wire it into LMD conf.maldet)
if [[ "$MODE" == "local" ]]; then
    hook_src="${BL_HOOK_SRC:-./files/hooks/bl-lmd-hook}"
    if [[ -f "$hook_src" ]]; then
        command cp "$hook_src" "$BL_HOOKS_DIR/bl-lmd-hook"
        command chmod 0755 "$BL_HOOKS_DIR/bl-lmd-hook"
        _info "installed bl-lmd-hook → $BL_HOOKS_DIR/bl-lmd-hook"
    fi
else
    if curl -fsSL --retry 3 --retry-delay 2 \
            "$BL_REPO_URL/files/hooks/bl-lmd-hook" \
            -o "$BL_HOOKS_DIR/bl-lmd-hook.new"; then
        command mv "$BL_HOOKS_DIR/bl-lmd-hook.new" "$BL_HOOKS_DIR/bl-lmd-hook"
        command chmod 0755 "$BL_HOOKS_DIR/bl-lmd-hook"
    else
        _info "bl-lmd-hook fetch skipped (non-fatal)"
    fi
fi

# --- Fetch or copy bl ---
if [[ "$MODE" == "local" ]]; then
    BL_SRC="${BL_SRC:-./bl}"
    [[ -f "$BL_SRC" ]] || _err "local bl not found at $BL_SRC — run 'make bl' first"
    _info "installing bl from local source: $BL_SRC"
    command cp "$BL_SRC" "$BL_BIN"
else
    _info "fetching bl from $BL_REPO_URL/bl"
    curl -fsSL --retry 3 --retry-delay 2 "$BL_REPO_URL/bl" -o "$BL_BIN" \
        || _err "failed to fetch $BL_REPO_URL/bl"
fi
command chmod 0755 "$BL_BIN"

# --- Post-install self-test ---
ver_out=$("$BL_BIN" --version 2>&1) || _err "$BL_BIN --version failed: $ver_out"
_info "installed: $ver_out → $BL_BIN"

# --- Next-step prompt ---
cat <<'NEXT'

blacklight installed. Next steps:

  1. Set your workspace key:
       export ANTHROPIC_API_KEY="sk-ant-..."

  2. Provision the managed agent + routing Skills + corpus Files (one-time per workspace):
       bl setup

  3. Start an investigation:
       bl observe --help
       bl consult "<case description>"

Uninstall:    curl -fsSL https://raw.githubusercontent.com/rfxn/blacklight/main/uninstall.sh | bash
Documentation: https://github.com/rfxn/blacklight
NEXT
