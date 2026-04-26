#!/usr/bin/env bats
# tests/10-install-paths.bats — M10 install/uninstall roundtrip coverage
# Maps to PLAN.md §M10 install/uninstall deliverables.

setup() {
    BL_REPO_ROOT="${BL_REPO_ROOT:-$BATS_TEST_DIRNAME/..}"
    INSTALL_SH="$BL_REPO_ROOT/install.sh"
    UNINSTALL_SH="$BL_REPO_ROOT/uninstall.sh"
    BL_STUB="$BL_REPO_ROOT/tests/fixtures/install-bl-stub"
    TEST_PREFIX="$(mktemp -d)"
    export BL_PREFIX="$TEST_PREFIX"
    export BL_SRC="$BL_STUB"
    export BL_CONF_SRC="$BL_REPO_ROOT/files/etc/blacklight.conf.default"
    export BL_HOOK_SRC="$BL_REPO_ROOT/files/hooks/bl-lmd-hook"
}

teardown() {
    [[ -d "$TEST_PREFIX" ]] && rm -rf "$TEST_PREFIX"
}

@test "install.sh --local places bl at prefix + mode 0755" {
    run bash "$INSTALL_SH" --local
    [ "$status" -eq 0 ]
    [ -x "$TEST_PREFIX/usr/local/bin/bl" ]
    mode=$(stat -c '%a' "$TEST_PREFIX/usr/local/bin/bl")
    [ "$mode" = "755" ]
}

@test "installed bl --version returns 0.1.0" {
    bash "$INSTALL_SH" --local
    run "$TEST_PREFIX/usr/local/bin/bl" --version
    [ "$status" -eq 0 ]
    [[ "$output" == "bl 0.1.0" ]]
}

@test "install.sh --local is idempotent (second run overwrites cleanly)" {
    bash "$INSTALL_SH" --local
    run bash "$INSTALL_SH" --local
    [ "$status" -eq 0 ]
    [ -x "$TEST_PREFIX/usr/local/bin/bl" ]
}

@test "install.sh --local missing BL_SRC rejects with exit 1" {
    BL_SRC="$BL_REPO_ROOT/tests/fixtures/does-not-exist" \
        run bash "$INSTALL_SH" --local
    [ "$status" -eq 1 ]
    [[ "$output" == *"local bl not found"* ]]
}

@test "install.sh --local creates /etc/blacklight/ directory tree" {
    run bash "$INSTALL_SH" --local
    [ "$status" -eq 0 ]
    [ -d "$TEST_PREFIX/etc/blacklight" ]
    [ -d "$TEST_PREFIX/etc/blacklight/notify.d" ]
    [ -d "$TEST_PREFIX/etc/blacklight/hooks" ]
}

@test "install.sh --local copies blacklight.conf.default" {
    run bash "$INSTALL_SH" --local
    [ "$status" -eq 0 ]
    [ -f "$TEST_PREFIX/etc/blacklight/blacklight.conf.default" ]
}

@test "install.sh --local cp -n semantic: second run preserves existing conf" {
    bash "$INSTALL_SH" --local
    echo "operator_custom=1" > "$TEST_PREFIX/etc/blacklight/blacklight.conf.default"
    run bash "$INSTALL_SH" --local
    [ "$status" -eq 0 ]
    grep -q "operator_custom=1" "$TEST_PREFIX/etc/blacklight/blacklight.conf.default"
}

@test "install.sh --local installs bl-lmd-hook +x into hooks/" {
    run bash "$INSTALL_SH" --local
    [ "$status" -eq 0 ]
    [ -x "$TEST_PREFIX/etc/blacklight/hooks/bl-lmd-hook" ]
    mode=$(stat -c '%a' "$TEST_PREFIX/etc/blacklight/hooks/bl-lmd-hook")
    [ "$mode" = "755" ]
}

@test "uninstall.sh --yes removes binary + backs up state" {
    bash "$INSTALL_SH" --local
    mkdir -p "$TEST_PREFIX/var/lib/bl"
    echo seed > "$TEST_PREFIX/var/lib/bl/marker"
    run bash "$UNINSTALL_SH" --yes
    [ "$status" -eq 0 ]
    [ ! -e "$TEST_PREFIX/usr/local/bin/bl" ]
    bks=( "$TEST_PREFIX"/var/lib/bl.bk.* )
    [ "${#bks[@]}" -eq 1 ]
    [ -f "${bks[0]}/marker" ]
}

@test "uninstall.sh --keep-state preserves state dir" {
    bash "$INSTALL_SH" --local
    mkdir -p "$TEST_PREFIX/var/lib/bl"
    echo seed > "$TEST_PREFIX/var/lib/bl/marker"
    run bash "$UNINSTALL_SH" --keep-state
    [ "$status" -eq 0 ]
    [ ! -e "$TEST_PREFIX/usr/local/bin/bl" ]
    [ -f "$TEST_PREFIX/var/lib/bl/marker" ]
    ! compgen -G "$TEST_PREFIX/var/lib/bl.bk.*" > /dev/null
}

@test "uninstall.sh on fresh prefix exits 0 (no binary, no state)" {
    run bash "$UNINSTALL_SH" --yes
    [ "$status" -eq 0 ]
}

@test "uninstall.sh non-interactive without --yes preserves state" {
    bash "$INSTALL_SH" --local
    mkdir -p "$TEST_PREFIX/var/lib/bl"
    echo seed > "$TEST_PREFIX/var/lib/bl/marker"
    run bash "$UNINSTALL_SH"
    [ "$status" -eq 0 ]
    [ -f "$TEST_PREFIX/var/lib/bl/marker" ]
    [ ! -e "$TEST_PREFIX/usr/local/bin/bl" ]
}

@test "uninstall.sh --yes removes post_scan_hook from LMD conf" {
    bash "$INSTALL_SH" --local
    lmd_conf="$(mktemp)"
    printf 'email_alert=1\npost_scan_hook="/etc/blacklight/hooks/bl-lmd-hook"\nemail_addr="root"\n' > "$lmd_conf"
    BL_LMD_CONF_PATH="$lmd_conf" run bash "$UNINSTALL_SH" --yes
    [ "$status" -eq 0 ]
    # post_scan_hook line referencing bl-lmd-hook must be gone
    ! grep -qE '^post_scan_hook=.*bl-lmd-hook' "$lmd_conf"
    # other LMD conf lines must remain intact
    grep -q 'email_alert=1' "$lmd_conf"
    rm -f "$lmd_conf"
}

@test "uninstall.sh --yes leaves post_scan_hook alone when not bl-lmd-hook" {
    bash "$INSTALL_SH" --local
    lmd_conf="$(mktemp)"
    printf 'post_scan_hook="/usr/local/custom-hook"\nemail_alert=1\n' > "$lmd_conf"
    BL_LMD_CONF_PATH="$lmd_conf" run bash "$UNINSTALL_SH" --yes
    [ "$status" -eq 0 ]
    # unrelated post_scan_hook must be preserved
    grep -q 'post_scan_hook="/usr/local/custom-hook"' "$lmd_conf"
    rm -f "$lmd_conf"
}

@test "uninstall.sh --yes removes /etc/blacklight/ config tree" {
    bash "$INSTALL_SH" --local
    BL_LMD_CONF_PATH="/dev/null" run bash "$UNINSTALL_SH" --yes
    [ "$status" -eq 0 ]
    [ ! -d "$TEST_PREFIX/etc/blacklight" ]
}

@test "uninstall.sh --keep-state preserves /etc/blacklight/ config tree" {
    bash "$INSTALL_SH" --local
    BL_LMD_CONF_PATH="/dev/null" run bash "$UNINSTALL_SH" --keep-state
    [ "$status" -eq 0 ]
    [ -d "$TEST_PREFIX/etc/blacklight" ]
}
