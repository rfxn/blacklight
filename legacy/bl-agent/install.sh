#!/bin/bash
#
# bl-agent install — wire bl-pull/bl-apply/bl-report into the host.
#
# Installs binaries under /usr/local/sbin and the oneshot systemd unit.
# The hackathon demo invokes bl-pull/apply/report via `docker exec`; a
# systemd `.timer` for periodic pull-apply-report cycles is tracked as a
# roadmap item in FUTURE.md rather than shipped here.

set -euo pipefail

PREFIX="${PREFIX:-/usr/local}"
SBIN_DIR="${PREFIX}/sbin"
SYSTEMD_DIR="${SYSTEMD_DIR:-/etc/systemd/system}"
VAR_DIR="/var/bl-agent"

SOURCE_DIR="$(command dirname "$(command readlink -f "$0")")"
cd "$SOURCE_DIR" || { command printf 'bl-agent: cannot cd into %s\n' "$SOURCE_DIR" >&2; exit 1; }

command install -d -m 0755 "$SBIN_DIR" "$VAR_DIR" "$VAR_DIR/reports"
command install -m 0755 bl-pull   "$SBIN_DIR/bl-pull"
command install -m 0755 bl-apply  "$SBIN_DIR/bl-apply"
command install -m 0755 bl-report "$SBIN_DIR/bl-report"

if [[ -d "$SYSTEMD_DIR" ]]; then
    command install -m 0644 bl-agent.service "$SYSTEMD_DIR/bl-agent.service"
    # Periodic-pull `.timer` unit is roadmap (FUTURE.md) — demo drives
    # bl-pull/apply/report via `docker exec`.
fi

command printf 'bl-agent installed into %s.\n' "$SBIN_DIR"
