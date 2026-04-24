# shellcheck shell=bash
# ----------------------------------------------------------------------------
# Handler stubs — remaining (bl_defend / bl_clean / bl_setup).
# Real implementations land in M6 (defend), M7 (clean), M8 (setup).
# Each stub is replaced in Wave 3 by a dedicated src/bl.d/8N-*.sh file; the
# stub here is removed in the same commit that adds the handler file.
# ----------------------------------------------------------------------------


# ---- bl_clean (M7 target: src/bl.d/83-clean.sh) ----------------------------
bl_clean()   { bl_error_envelope clean   "not yet implemented (M7)"; return "$BL_EX_USAGE"; }


# ---- bl_defend (M6 target: src/bl.d/82-defend.sh) --------------------------
bl_defend()  { bl_error_envelope defend  "not yet implemented (M6)"; return "$BL_EX_USAGE"; }


# ---- bl_setup (M8 target: src/bl.d/84-setup.sh) ----------------------------
bl_setup()   { bl_error_envelope setup   "not yet implemented (M8)"; return "$BL_EX_USAGE"; }
