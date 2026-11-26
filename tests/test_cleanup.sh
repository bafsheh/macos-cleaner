#!/usr/bin/env bash
# =============================================================================
# tests/test_cleanup.sh  ·  Regression tests for the cleanup actions
#
#   Sourced by tests/run_tests.sh, which runs every test_* function in a
#   subshell with a throwaway HOME (see the harness for the helpers).
#
#   2026-11-22 · user report: "Trash and Docker cleanup don't work well".
#     Trash  - with Full Disk Access, `find -delete` could not remove read-only
#              folders (trashed node_modules, Go module caches, app bundles) or
#              locked files, so the Trash was only partly emptied.
#     Docker - "already empty" skipped a build cache with no images left; an
#              image with two tags made `docker rmi` fail; a hung daemon froze
#              the run (no timeout on `docker info`).
# =============================================================================

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

# Destructive actions must never run unattended without their *_ASSUME_YES.
test_project_clean_without_terminal_or_opt_in_deletes_nothing() {
    local app="$TEST_TMP/code/app"
    make_quiet_repo "$app"
    echo node_modules/ > "$app/.gitignore"
    mkdir -p "$app/node_modules/q"; echo q > "$app/node_modules/q/i.js"
    export PROJECT_SCAN_ROOTS="$TEST_TMP/code"
    unset PROJECT_CLEAN_ASSUME_YES
    project_clean
    assert "nothing is deleted without confirmation" test -e "$app/node_modules/q/i.js"
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

# ── Shared cleaning helpers ─────────────────────────────────────────────────

# clean_subdirs empties each named sub-folder and keeps the folders themselves.
test_clean_subdirs_empties_each_folder_and_keeps_it() {
    local base="$HOME/Library/Application Support/Demo"
    mkdir -p "$base/Cache" "$base/Code Cache/js" "$base/Settings"
    echo x > "$base/Cache/a"; echo x > "$base/Code Cache/js/b"; echo keep > "$base/Settings/prefs"

    clean_subdirs "$base" "Demo" Cache "Code Cache" Missing

    assert "Cache is emptied"            test -z "$(ls -A "$base/Cache")"
    assert "Code Cache is emptied"       test -z "$(ls -A "$base/Code Cache")"
    assert "the folders themselves stay" test -d "$base/Cache" -a -d "$base/Code Cache"
    assert "a folder not named is kept"  test -f "$base/Settings/prefs"
}

# The summary's "biggest wins" come from the ledger every clean step feeds.
test_ledger_reports_the_biggest_wins_first() {
    ledger_reset
    mkdir -p "$HOME/small" "$HOME/big"
    dd if=/dev/zero of="$HOME/small/f" bs=1024 count=64 2>/dev/null
    dd if=/dev/zero of="$HOME/big/f"   bs=1024 count=512 2>/dev/null
    clean_dir "$HOME/small" "Small thing"
    clean_dir "$HOME/big"   "Big thing"
    clean_dir "$HOME/none"  "Missing thing"

    local top; top=$(ledger_top 5)
    assert "the largest entry comes first: $top" test "$(printf '%s\n' "$top" | head -1 | cut -f2)" = "Big thing"
    assert "a step that freed nothing is not listed" test "$(printf '%s\n' "$top" | wc -l | tr -d ' ')" -eq 2
}
