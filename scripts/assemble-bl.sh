#!/bin/bash
#
# assemble-bl.sh — concatenate src/bl.d/NN-*.sh parts into a single bl on stdout.
#
# Called by `make bl` (writes output to ./bl) and `make bl-check` (pipes to
# diff against the committed bl). Deterministic: numeric-sort, dedup shebangs
# from part files, inject a GENERATED banner so anyone opening bl sees the
# source-of-truth rule without reading CLAUDE.md.
#
# Copyright (C) 2026 R-fx Networks <proj@rfxn.com>
# Author: Ryan MacDonald <ryan@rfxn.com>
# License: GNU GPL v2

set -euo pipefail

shopt -s nullglob
parts=( src/bl.d/[0-9]*.sh )
shopt -u nullglob

if (( ${#parts[@]} == 0 )); then
    printf 'assemble-bl: no parts found in src/bl.d/ (run from repo root; pre-M5.5 this is expected)\n' >&2
    exit 1
fi

# Numeric-sort by filename prefix — wildcard expansion + shell sort-order
# happens to match for NN- prefixes, but make it explicit for safety.
IFS=$'\n' read -r -d '' -a sorted < <(printf '%s\n' "${parts[@]}" | LC_ALL=C sort && printf '\0')

printf '%s\n' '#!/bin/bash'
printf '%s\n' '# GENERATED FILE — edit src/bl.d/NN-*.sh and run "make bl"'
printf '%s\n' '# Source of truth: src/bl.d/ — see CLAUDE.md "bl source layout" rule.'
printf '%s\n' '# Do not edit bl directly; make bl-check will fail in CI.'

for p in "${sorted[@]}"; do
    printf '\n# --- %s ---\n' "$p"
    # Strip a leading shebang OR a line-1 `# shellcheck shell=bash` directive
    # from each part. Only the top-level shebang (and any load-bearing
    # shellcheck disables on subsequent lines, like 00-header.sh:2) survive
    # in assembled bl. The per-part shell=bash directive is satisfied in
    # source to silence SC2148, but redundant once parts are concatenated
    # under the top-level #!/bin/bash.
    sed -e '1{/^#!/d; /^# shellcheck shell=bash/d;}' "$p"
done
