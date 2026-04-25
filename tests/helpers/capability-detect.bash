#!/usr/bin/env bash
# tests/helpers/capability-detect.bash — skip-guard probes for optional
# binaries / kernel features that are absent on some test images.
#
# Pattern (APF-derived): probe the actual capability, not the OS string.
# Tests stay identical across lanes; the probe gates the assertion.
#
# Usage:
#   load 'helpers/capability-detect.bash'
#   <probe>_available || skip "<tool> unavailable on this image"
#
# Adding a probe: do real work (run --version, create a probe object), not
# just `command -v`. A binary present but broken is the same as absent.

# ShellCheck — vault has no usable build for CentOS 6; lint runs on
# debian12 / rocky9 lanes per tests/Dockerfile.centos6 header note.
shellcheck_available() {
    command -v shellcheck >/dev/null 2>&1
}

# nft — kernel 3.13+; CentOS 6 ships kernel 2.6/3.10 and has no usable nft
# package on vault. Defend firewall lane uses --backend iptables to bypass.
nft_available() {
    command -v nft >/dev/null 2>&1 || return 1
    nft list ruleset >/dev/null 2>&1
}

# yara — EPEL6 dropped years ago; defend sig lane uses LMD/clamscan shims
# instead of real yara on c6.
yara_available() {
    command -v yara >/dev/null 2>&1
}

# mod_security — EPEL6 build unavailable; defend modsec subgroup degrades
# when absent (per tests/Dockerfile.centos6 note).
modsec_available() {
    [[ -f /etc/httpd/conf.d/mod_security.conf ]] \
        || [[ -f /etc/apache2/mods-available/security2.load ]] \
        || command -v modsecurity-pcre >/dev/null 2>&1
}

# zstd — observe codec auto-degrades to gz when zstd is missing
# (40-observe-helpers.sh:74-98); explicit probe for tests asserting on zstd.
zstd_available() {
    command -v zstd >/dev/null 2>&1
}
