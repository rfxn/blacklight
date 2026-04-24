#!/bin/bash
# shellcheck disable=SC2094  # M4: loop read-file and cleanup-rm-file appear in same pipeline scope but reference different files; false positive
#
# bl — blacklight operator CLI
#
# Copyright (C) 2026 R-fx Networks <proj@rfxn.com>
# Author: Ryan MacDonald <ryan@rfxn.com>
# License: GNU GPL v2
#
# Part of the blacklight project — defensive post-incident Linux forensics
# on the substrate the defender already owns. See DESIGN.md for architecture,
# PIVOT-v2.md for strategy, README.md for operator-facing overview.
#
# This is a single-file bash wrapper. It is curl-pipeable per DESIGN.md §8.3
# and must not `source` external helpers.

set -euo pipefail

# ----------------------------------------------------------------------------
# Version + exit-code constants (from docs/exit-codes.md §1)
# ----------------------------------------------------------------------------

readonly BL_VERSION="0.1.0"

readonly BL_EX_OK=0
readonly BL_EX_USAGE=64
readonly BL_EX_PREFLIGHT_FAIL=65
readonly BL_EX_WORKSPACE_NOT_SEEDED=66
# shellcheck disable=SC2034  # consumed by M4+
readonly BL_EX_SCHEMA_VALIDATION_FAIL=67
# shellcheck disable=SC2034  # consumed by M4+
readonly BL_EX_TIER_GATE_DENIED=68
readonly BL_EX_UPSTREAM_ERROR=69   # used by bl_api_call on exhausted 5xx retries
readonly BL_EX_RATE_LIMITED=70     # used by bl_api_call on exhausted 429 retries
# shellcheck disable=SC2034  # consumed by M8
readonly BL_EX_CONFLICT=71
# shellcheck disable=SC2034  # consumed by M5+
readonly BL_EX_NOT_FOUND=72

# ----------------------------------------------------------------------------
# Bash 4.1+ floor check — TOP-LEVEL; must fire before any function definition
# so `bl --help` and `bl --version` also trip on bash <4.1. See spec G11.
# ----------------------------------------------------------------------------

if (( BASH_VERSINFO[0] * 100 + BASH_VERSINFO[1] < 401 )); then
    printf 'blacklight: bash 4.1+ required (got %s.%s)\n' \
        "${BASH_VERSINFO[0]}" "${BASH_VERSINFO[1]}" >&2
    exit "$BL_EX_PREFLIGHT_FAIL"
fi

# ----------------------------------------------------------------------------
# Path constants — BL_VAR_DIR is operator-overridable for test isolation
# ----------------------------------------------------------------------------

readonly BL_VAR_DIR="${BL_VAR_DIR:-/var/lib/bl}"
readonly BL_STATE_DIR="$BL_VAR_DIR/state"
readonly BL_AGENT_ID_FILE="$BL_STATE_DIR/agent-id"
readonly BL_CASE_CURRENT_FILE="$BL_STATE_DIR/case.current"

# ----------------------------------------------------------------------------
# Named FDs (in-process serialization — flock targets):
#   200 = /var/lib/bl/ledger/<case>.jsonl  (25-ledger.sh bl_ledger_append)
#   201 = /var/lib/bl/state/case-id-counter (50-consult.sh bl_consult_allocate_case_id)
#   202 = /var/lib/bl/outbox/.counter      (27-outbox.sh bl_outbox_enqueue)
# New FD users must allocate >=203 and update this registry.
# ----------------------------------------------------------------------------

# ----------------------------------------------------------------------------
# Logging helpers — stderr, per-level, $BL_LOG_LEVEL-filtered
# Order: debug < info < warn < error. Default: info.
# ----------------------------------------------------------------------------

