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
