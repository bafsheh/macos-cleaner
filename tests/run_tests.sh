#!/usr/bin/env bash
# =============================================================================
# tests/run_tests.sh  ·  Test runner for mac_cleaner.sh
#
#   Runs every test_* function defined in tests/test_*.sh. Each test runs the
#   real lib/ code in its own subshell, against a throwaway HOME and with stub
#   system tools first on PATH, so nothing on the machine running the tests is
#   touched: no real app is quit, no permission reset, no sudo.
#
#     bash tests/run_tests.sh              run everything   (CI runs this on macOS)
#     bash tests/run_tests.sh uninstall    only tests whose name contains "uninstall"
#     VERBOSE=1 bash tests/run_tests.sh    also print the output of passing tests
#
#   Test files
#     test_cleanup.sh     Trash · Docker · project build folders · clean helpers
#     test_uninstall.sh   app discovery · leftover matching · the delete guard
#                         · the full uninstall flow · packages
#     test_ui.sh          key parser · progress bar · picker · menus · logging
#     test_diskscan.sh    parallel folder scanner · disk usage report · disk map
#     test_long_runs.sh   screens that stay open do not run out of file descriptors
#
#   Writing a test: name it after what the user should see, build the scene
#   under $HOME / $TEST_TMP, run the real function, and `assert` the outcome.
#   A bug fix comes with a test that fails without the fix.
# =============================================================================
set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FILTER=${1:-}

declare -i PASSED=0 FAILED=0
FAILED_NAMES=()

# =============================================================================
# § run_test NAME
#
#   Runs one test function in a subshell with a fresh HOME ($TEST_TMP/home) and
#   an empty stub folder ($TEST_TMP/bin) at the front of PATH. stdin is
#   /dev/null: a test that needs input feeds its own.
# =============================================================================
run_test() {
    local name=$1 out rc
    local tmp base=${TMPDIR:-/tmp}
    tmp=$(mktemp -d "${base%/}/mc_test.XXXXXX")       # no "//": HOME must be a clean path
    mkdir -p "$tmp/home" "$tmp/bin"
    out=$( (
        export HOME="$tmp/home" TEST_TMP="$tmp" NO_COLOR=1
        export PATH="$tmp/bin:$PATH" MAC_CLEANER_LOG="$tmp/run.log"
        # The uninstaller must never reach the real system from a test.
        export UNINSTALL_NO_SUDO=1 UNINSTALL_SPOTLIGHT=0
        export UNINSTALL_APP_ROOTS="$tmp/home/Applications" UNINSTALL_LSREGISTER="$tmp/bin/lsregister"
        export LIB_DIR="$REPO/lib"          # mac_cleaner.sh sets this for the modules
        cd "$tmp" || exit 99
        # shellcheck source=/dev/null
        for f in colors core logging helpers ui; do source "$REPO/lib/$f.sh"; done
        # shellcheck source=/dev/null
        for f in "$REPO"/lib/actions/*.sh; do source "$f"; done
        # shellcheck source=/dev/null
        source "$REPO/lib/uninstaller.sh"
        # shellcheck source=/dev/null
        source "$REPO/lib/menu.sh"
        "$name"
    ) < /dev/null 2>&1 )
    rc=$?
    chflags -R nouchg "$tmp" 2>/dev/null; chmod -R u+w "$tmp" 2>/dev/null; rm -rf "$tmp"
    if (( rc == 0 )); then
        (( PASSED++ )); printf 'PASS  %s\n' "$name"
        [[ -n ${VERBOSE:-} ]] && printf '%s\n' "$out" | sed 's/^/      │ /'
    else
        (( FAILED++ )); FAILED_NAMES+=("$name")
        printf 'FAIL  %s\n' "$name"
        printf '%s\n' "$out" | sed 's/^/      │ /' | tail -40
    fi
}

# =============================================================================
# § assert MESSAGE COMMAND...
#
#   Fails the current test with MESSAGE unless COMMAND succeeds.
# =============================================================================
assert() {
    local msg=$1; shift
    "$@" || { printf 'assertion failed: %s\n' "$msg"; exit 1; }
}

# Fails the current test with MESSAGE if COMMAND succeeds.
refute() {
    local msg=$1; shift
    if "$@"; then printf 'assertion failed: %s\n' "$msg"; exit 1; fi
}

# =============================================================================
# § make_stub NAME [OUTPUT]
#
#   Writes a stand-in for a system tool to $TEST_TMP/bin. It appends its
#   arguments to $TEST_TMP/calls.log as "NAME ARG…", prints OUTPUT (if given),
#   and exits 0.
# =============================================================================
make_stub() {
    printf '#!/bin/bash\necho "%s $*" >> "$TEST_TMP/calls.log"\n%s\nexit 0\n' \
        "$1" "${2:+echo \"$2\"}" > "$TEST_TMP/bin/$1"
    chmod +x "$TEST_TMP/bin/$1"
}

# =============================================================================
# § run_on_terminal DELAY KEYS SNIPPET
#
#   Runs SNIPPET (bash, with the lib/ modules loaded) on a pseudo-terminal -
#   the widgets only draw and read keys on a terminal - and prints everything
#   the terminal received. KEYS are typed after DELAY seconds. The environment
#   of the test (HOME, PATH with the stubs, …) is passed on.
# =============================================================================
run_on_terminal() {
    local delay=$1 keys=$2 snippet=$3
    { sleep "$delay"; printf '%s' "$keys"; sleep 1; } | TERM=xterm-256color script -q /dev/null /bin/bash -c "
        for f in colors core logging helpers ui; do source '$REPO/lib/'\$f.sh; done
        for f in '$REPO'/lib/actions/*.sh; do source \"\$f\"; done
        $snippet" 2>&1
}

# ── load the test files ──────────────────────────────────────────────────────
for f in "$REPO"/tests/test_*.sh; do
    # shellcheck source=/dev/null
    source "$f"
done

for t in $(declare -F | awk '{print $3}' | grep '^test_'); do
    [[ -z $FILTER || $t == *"$FILTER"* ]] && run_test "$t"
done

printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
if (( FAILED > 0 )); then printf '  failed: %s\n' "${FAILED_NAMES[@]}"; fi
(( FAILED == 0 ))
