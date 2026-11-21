#!/usr/bin/env bash
# =============================================================================
# tests/run_tests.sh  ·  Regression tests for mac_cleaner.sh
#
#   Each test runs the real lib/ code against a throwaway HOME and, for Docker,
#   a stub `docker` on PATH, so nothing on the machine running the tests is
#   touched. Run:  bash tests/run_tests.sh      (CI runs it on macOS)
#   VERBOSE=1 also prints the output of passing tests.
#
#   2026-11-22 · user report: "Trash and Docker cleanup don't work well".
#     Trash  - with Full Disk Access, `find -delete` could not remove read-only
#              folders (trashed node_modules, Go module caches, app bundles) or
#              locked files, so the Trash was only partly emptied.
#     Docker - "already empty" skipped a build cache with no images left; an
#              image with two tags made `docker rmi` fail; a hung daemon froze
#              the run (no timeout on `docker info`).
# =============================================================================
set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

declare -i PASSED=0 FAILED=0
FAILED_NAMES=()

# Runs one test function in a subshell with a fresh HOME and stub dir.
run_test() {
    local name=$1 out rc
    local tmp; tmp=$(mktemp -d "${TMPDIR:-/tmp}/mc_test.XXXXXX")
    mkdir -p "$tmp/home" "$tmp/bin"
    out=$( (
        export HOME="$tmp/home" TEST_TMP="$tmp" NO_COLOR=1
        export PATH="$tmp/bin:$PATH"
        cd "$tmp" || exit 99
        # shellcheck source=/dev/null
        source "$REPO/lib/colors.sh"
        # shellcheck source=/dev/null
        source "$REPO/lib/core.sh"
        # shellcheck source=/dev/null
        source "$REPO/lib/logging.sh"
        # shellcheck source=/dev/null
        source "$REPO/lib/helpers.sh"
        # shellcheck source=/dev/null
        for f in "$REPO"/lib/actions/*.sh; do source "$f"; done
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

assert() {   # MESSAGE COMMAND...
    local msg=$1; shift
    "$@" || { printf 'assertion failed: %s\n' "$msg"; exit 1; }
}

# Writes a stub `docker` to $TEST_TMP/bin. It logs every call to
# $TEST_TMP/docker.calls and answers from these env vars:
#   STUB_IMAGES   newline-separated output of `docker images -aq`
#   STUB_CACHE    "1" = `docker system df` reports build cache
#   STUB_HANG     "1" = `docker info` never returns
make_docker_stub() {
    cat > "$TEST_TMP/bin/docker" <<'STUB'
#!/bin/bash
echo "$*" >> "$TEST_TMP/docker.calls"
case "$1 ${2:-}" in
    "info "*)   [[ ${STUB_HANG:-0} == 1 ]] && sleep 60; echo ok ;;
    "ps "*)     : ;;
    "images "*) [[ -n ${STUB_IMAGES:-} ]] && printf '%s\n' "$STUB_IMAGES" ;;
    "volume ls") : ;;
    "system df")
        echo "TYPE        TOTAL  ACTIVE  SIZE   RECLAIMABLE"
        if [[ ${STUB_CACHE:-0} == 1 ]]; then
            echo "Build Cache 12     0       4.2GB  4.2GB"
        else
            echo "Build Cache 0      0       0B     0B"
        fi ;;
    "rmi "*)
        # Like the daemon: an ID given twice fails the second time.
        shift; seen=" "
        [[ $1 == -f ]] && shift
        for id in "$@"; do
            [[ $seen == *" $id "* ]] && { echo "Error: No such image: $id" >&2; exit 1; }
            seen+="$id "
        done ;;
    *) : ;;
esac
exit 0
STUB
    chmod +x "$TEST_TMP/bin/docker"
}

# ── Trash ───────────────────────────────────────────────────────────────────

# User saw: Trash left half full after "Empty Trash" (Full Disk Access on).
test_trash_empties_read_only_folders_and_locked_files() {
    local t="$HOME/.Trash"
    mkdir -p "$t/node_modules/pkg" "$t/gomod/mod@v1"
    echo x > "$t/node_modules/pkg/index.js"
    echo x > "$t/gomod/mod@v1/go.mod"
    chmod 0555 "$t/node_modules/pkg" "$t/gomod/mod@v1" "$t/gomod"
    echo x > "$t/locked.txt"; chflags uchg "$t/locked.txt"
    echo x > "$t/plain.txt"

    empty_trash

    local left; left=$(ls -A "$t" | wc -l | tr -d ' ')
    assert "Trash should be empty, ${left} item(s) left: $(ls -A "$t" | tr '\n' ' ')" \
        test "$left" -eq 0
    assert "the Trash folder itself is kept" test -d "$t"
}

# ── Docker ──────────────────────────────────────────────────────────────────

# User saw: Docker cleanup said "already empty" while build cache used GBs.
test_docker_prunes_build_cache_when_no_images_left() {
    make_docker_stub
    export STUB_CACHE=1 DOCKER_CLEAN_ASSUME_YES=1
    docker_clean
    assert "docker builder/system prune should run when only build cache is left" \
        grep -qE '^(builder|system) prune' "$TEST_TMP/docker.calls"
}

# User saw: "remove all images" FAILED when an image had two tags.
test_docker_removes_image_with_two_tags_without_failing() {
    make_docker_stub
    export STUB_IMAGES=$'aaa111\naaa111\nbbb222' DOCKER_CLEAN_ASSUME_YES=1
    docker_clean
    assert "no step should fail (TOTAL_FAILED=$TOTAL_FAILED)" test "$TOTAL_FAILED" -eq 0
}

# User saw: the menu froze on Docker while Docker Desktop was starting.
test_docker_does_not_hang_when_daemon_is_unresponsive() {
    make_docker_stub
    export STUB_HANG=1 DOCKER_CLEAN_ASSUME_YES=1 DOCKER_INFO_TIMEOUT=2
    local -i t0=$SECONDS
    docker_clean
    assert "docker_clean should give up quickly, took $(( SECONDS - t0 ))s" \
        test $(( SECONDS - t0 )) -lt 20
}

# ── Project build folders (plonge rules) ────────────────────────────────────

# Makes a Git repo at $1 whose last Git activity is 2 days old.
make_quiet_repo() {
    git init -q "$1" && git -C "$1" -c user.email=t@t -c user.name=t \
        commit -q --allow-empty -m init
    touch -t "$(date -v-2d +%Y%m%d%H%M)" "$1/.git/logs/HEAD" "$1/.git/HEAD"
}

test_project_clean_deletes_only_git_ignored_rebuildable_folders() {
    local root="$TEST_TMP/code" app="$TEST_TMP/code/app"
    make_quiet_repo "$app"
    printf 'node_modules/\ntarget/\ndist/\n' > "$app/.gitignore"
    mkdir -p "$app/node_modules/x" "$app/target/debug" "$app/dist" "$app/vendor-src"
    echo x > "$app/node_modules/x/i.js"; echo x > "$app/target/debug/b"
    echo x > "$app/dist/out.js"; touch "$app/Cargo.toml"        # dist: no package.json
    mkdir -p "$app/build"; echo x > "$app/build/keep.txt"        # tracked, not ignored
    touch "$app/build.gradle"
    git -C "$app" add build build.gradle
    git -C "$app" -c user.email=t@t -c user.name=t commit -q -m files
    touch -t "$(date -v-2d +%Y%m%d%H%M)" "$app/.git/logs/HEAD" "$app/.git/HEAD"

    local plain="$TEST_TMP/code/notgit"
    mkdir -p "$plain/node_modules/y"; echo y > "$plain/node_modules/y/i.js"

    export PROJECT_SCAN_ROOTS="$root" PROJECT_CLEAN_ASSUME_YES=1
    project_clean

    assert "ignored node_modules is deleted"            test ! -e "$app/node_modules"
    assert "ignored target beside Cargo.toml is deleted" test ! -e "$app/target"
    assert "dist with no package.json is kept"           test -e "$app/dist/out.js"
    assert "tracked build folder is kept"                test -e "$app/build/keep.txt"
    assert "node_modules outside Git is kept"            test -e "$plain/node_modules/y/i.js"
}

test_project_clean_skips_repo_with_recent_git_activity() {
    local app="$TEST_TMP/code/busy"
    git init -q "$app"
    git -C "$app" -c user.email=t@t -c user.name=t commit -q --allow-empty -m now
    echo node_modules/ > "$app/.gitignore"
    mkdir -p "$app/node_modules/z"; echo z > "$app/node_modules/z/i.js"
    export PROJECT_SCAN_ROOTS="$TEST_TMP/code" PROJECT_CLEAN_ASSUME_YES=1
    project_clean
    assert "node_modules in a repo used today is kept" test -e "$app/node_modules/z/i.js"
}

for t in $(declare -F | awk '{print $3}' | grep '^test_'); do run_test "$t"; done

printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
(( FAILED == 0 ))
