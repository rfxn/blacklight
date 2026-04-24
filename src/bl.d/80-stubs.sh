# shellcheck shell=bash
# ----------------------------------------------------------------------------
# Handler stubs — remaining (bl_defend).
# Real implementation lands in M6 (defend). M7 (clean) lives in
# src/bl.d/83-clean.sh; M8 (setup) lives in src/bl.d/84-setup.sh.
# Each stub is replaced in Wave 3 by a dedicated src/bl.d/8N-*.sh file; the
# stub here is removed in the same commit that adds the handler file.
# ----------------------------------------------------------------------------


# ---- bl_defend (M6 target: src/bl.d/82-defend.sh) --------------------------
# shellcheck disable=SC2317  # stub overridden by 82-defend.sh in assembled bl; unreachable-in-shellcheck is expected
bl_defend()  { bl_error_envelope defend  "not yet implemented (M6)"; return "$BL_EX_USAGE"; }
