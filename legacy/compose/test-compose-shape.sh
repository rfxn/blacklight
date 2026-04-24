#!/bin/bash
# compose-shape sanity test (no docker daemon required for parse-only check)
set -euo pipefail
cd "$(command dirname "$0")" || exit 1
# Prefer docker compose (v2 plugin) when available; fall back to docker-compose (v1).
if docker compose version >/dev/null 2>&1; then  # probe-only; exit code is the signal
    dc() { docker compose "$@"; }
elif command -v docker-compose >/dev/null 2>&1; then  # probe-only; exit code is the signal
    dc() { docker-compose "$@"; }
else
    command echo "neither 'docker compose' nor 'docker-compose' found — skipping" >&2
    exit 0
fi
dc -f docker-compose.yml config --quiet
services=$(dc -f docker-compose.yml config --services | command sort)
expected=$(command printf '%s\n' curator host-1 host-2 host-3 host-4 host-5 host-7 | command sort)
if [[ "$services" != "$expected" ]]; then
    command echo "service mismatch:" >&2
    command echo "expected: $expected" >&2
    command echo "got:      $services" >&2
    exit 1
fi
command echo "compose shape OK: $(command echo "$services" | command tr '\n' ' ')"
