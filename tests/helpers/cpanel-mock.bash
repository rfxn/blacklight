# tests/helpers/cpanel-mock.bash — cPanel script stubs (programmable pass/fail)
#
# Sets up a temp directory hierarchy mimicking /usr/local/cpanel/scripts/ so
# that _bl_cpanel_present and _bl_cpanel_lockin_* operate without root or a
# real cPanel install. Controlled via BL_CPANEL_SCRIPT_DIR + BL_CPANEL_DIR env
# hatches in 45-cpanel.sh.

_cpanel_mock_setup() {
    BL_CPANEL_MOCK_DIR="$(mktemp -d)"
    export BL_CPANEL_MOCK_DIR
    mkdir -p "$BL_CPANEL_MOCK_DIR/usr/local/cpanel/scripts"

    cat > "$BL_CPANEL_MOCK_DIR/usr/local/cpanel/scripts/restartsrv_httpd" <<'EOF'
#!/bin/bash
# Stub: respect $BL_TEST_RESTARTSRV_RC env (default 0)
rc="${BL_TEST_RESTARTSRV_RC:-0}"
case "$1" in
    --restart) printf 'restartsrv_httpd: stub restart rc=%s\n' "$rc" ;;
    *) printf 'restartsrv_httpd: unknown arg: %s\n' "$1" >&2; exit 64 ;;
esac
exit "$rc"
EOF

    cat > "$BL_CPANEL_MOCK_DIR/usr/local/cpanel/scripts/ensure_vhost_includes" <<'EOF'
#!/bin/bash
# Stub: respect $BL_TEST_ENSURE_VHOST_RC env (default 0)
rc="${BL_TEST_ENSURE_VHOST_RC:-0}"
exit "$rc"
EOF

    chmod 0755 "$BL_CPANEL_MOCK_DIR/usr/local/cpanel/scripts/restartsrv_httpd"
    chmod 0755 "$BL_CPANEL_MOCK_DIR/usr/local/cpanel/scripts/ensure_vhost_includes"

    # Set env hatches so 45-cpanel.sh uses mock paths instead of /usr/local/cpanel
    export BL_CPANEL_DIR="$BL_CPANEL_MOCK_DIR/usr/local/cpanel"
    export BL_CPANEL_SCRIPT_DIR="$BL_CPANEL_MOCK_DIR/usr/local/cpanel/scripts"
}

_cpanel_mock_teardown() {
    rm -rf "$BL_CPANEL_MOCK_DIR"
    unset BL_CPANEL_MOCK_DIR BL_CPANEL_DIR BL_CPANEL_SCRIPT_DIR \
          BL_TEST_RESTARTSRV_RC BL_TEST_ENSURE_VHOST_RC
}
