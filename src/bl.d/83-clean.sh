# shellcheck shell=bash
# ============================================================================
# M7 clean handlers — spec: DESIGN.md §5.5 + §11
# ----------------------------------------------------------------------------
# Region layout (top-down reading order = call depth):
#   1. Private helpers (_bl_clean_*) — backup, quarantine, dry-run gate
#   2. Verb handlers (bl_clean_*) — htaccess, cron, proc, file, undo, unquarantine
#   3. Top-level dispatcher (bl_clean) — replaces 80-stubs.sh stub
# ============================================================================

# === M7-HELPERS-BEGIN ===
# Phase 2 lands _bl_clean_* helpers here.
# === M7-HELPERS-END ===

# === M7-HANDLERS-BEGIN ===
# Phase 3 lands bl_clean_* handlers + dispatcher here.
# === M7-HANDLERS-END ===
