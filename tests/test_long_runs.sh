#!/usr/bin/env bash
# shellcheck disable=SC2034  # the globals set here are read by the functions under test
# =============================================================================
# tests/test_long_runs.sh  ·  Screens that stay open must not run out of files
#
#   Sourced by tests/run_tests.sh.
#
#   2026-11-26 · user report: the disk map printed
#       lib/ui/term.sh: line 158: read: read error: 0: Bad file descriptor
#     over and over and could not be stopped.
#     Root cause: bash 3.2 (the macOS system bash) does not close the file
#     descriptor of a process substitution `< <(cmd)` while it is inside a
#     shell function - only when control is back at the top level of the
#     script, which never happened because the main menu was a function that
#     loops. The disk map's progress check used one ten times a second, so
#     after ~25 s of scanning it reached the 256 open files a Terminal window
#     allows. The next redirection could not save the keyboard's descriptor
#     ("cannot duplicate fd: Too many open files"), stdin was lost, and every
#     key poll after that failed - forever, because the loop never ends on
#     its own. The same leak sat in the cleanup's live panel (two per
#     redraw), the picker (one per reload) and the app list (one per app).
#     Fix: nothing that runs repeatedly uses process substitution any more,
#     the main menu loop runs at the top level of mac_cleaner.sh (so the few
#     one-off ones are released after every menu action), and the scan loops
#     end instead of spinning if the keyboard ever does go away.
#
#   Every test here runs the real function a few hundred times - as often as
#   a minute or two on screen - under the 256-file limit of a Terminal
#   window, and checks that the number of open files did not grow.
# =============================================================================

# Number of file descriptors open in this shell (plus a constant few for the
# listing itself - only the difference between two calls matters).
open_fds() { local n; n=$(ls /dev/fd | wc -l); printf '%d' "$n"; }

# assert_no_fd_growth BEFORE WHAT → fails when more than a handful of
# descriptors were left open since BEFORE.
assert_no_fd_growth() {
    local -i before=$1 now; now=$(open_fds)
    assert "$2 left $(( now - before )) file descriptors open" test $(( now - before )) -lt 8
}

# User saw: "read error: 0: Bad file descriptor", endlessly, during a scan.
test_disk_map_keeps_reading_keys_through_a_long_scan() {
    ulimit -n 256
    local work="$TEST_TMP/scan" i
    DM_DIR="$TEST_TMP/dm"; mkdir -p "$work/out" "$DM_DIR/recs.d"
    printf 'a\nb\nc\n' > "$work/fin"; printf '1\ta\n1\tb\n1\tc\n1\td\n' > "$work/queue"
    printf '512\t%s/Library\n' "$HOME" > "$work/latest"
    printf '7\n2\nline one\nline two\n' > "$work/frame"
    DM_RECS_READY=0 DM_RECS_DONE=0 DM_RECS_TOTAL=20 DM_COLS=120

    local -i before; before=$(open_fds)
    local seq txt
    for (( i = 0; i < 400; i++ )); do          # 400 polls = 40 s of scanning
        du_scan_progress "$work"
        _dm_scan_status "$i" 12 > /dev/null
        IFS= read -r seq < "$work/frame"
        IFS= read -r -d '' txt < "$work/frame"
        _dm_recs_poll
    done
    assert_no_fd_growth "$before" "400 polls of a running scan"

    # …and the things the loop depends on still work at the end.
    printf 'd\ne\n' >> "$work/fin"
    du_scan_progress "$work"
    assert "progress is still read correctly: $DU_SCAN_DONE/$DU_SCAN_TOTAL" test "$DU_SCAN_DONE" -eq 5 -a "$DU_SCAN_TOTAL" -eq 4
    local typed=''; read -r typed <<< "still here"
    assert "input can still be read" test "$typed" = "still here"
}

test_scan_workers_can_split_hundreds_of_folders() {
    ulimit -n 256
    local work="$TEST_TMP/scan" r="$TEST_TMP/tree" i
    mkdir -p "$work/out" "$r/a/one" "$r/a/two" "$r/a/.hidden"; echo x > "$r/a/file"
    : > "$work/queue"; : > "$work/out/w1"

    local -i before; before=$(open_fds)
    for (( i = 0; i < 300; i++ )); do _du_scan_split "$work" 1 1 "$r/a"; done
    assert_no_fd_growth "$before" "300 folder splits"

    assert "each split queued the three sub-folders, hidden one included" \
        test "$(wc -l < "$work/queue" | tr -d ' ')" -eq 900
    assert "sub-folders are queued one level deeper" grep -q "^2	$r/a/.hidden$" "$work/queue"
    refute "the folder's own files are not queued as jobs" grep -q "/a/file$" "$work/queue"
}

test_cleanup_progress_panel_can_redraw_for_minutes() {
    ulimit -n 256
    _PAR_DIR="$TEST_TMP/par"; mkdir -p "$_PAR_DIR"
    printf '┏━━ 7 · HOMEBREW\n  ▸ [brew cleanup]\n    cmd     : brew cleanup\n' > "$_PAR_DIR/0.out"
    printf '┏━━ 9 · PYTHON\n  ▸ [pip cache purge]\n' > "$_PAR_DIR/1.out"
    _PAR_PIDS=($$ $$); _PAR_STARTS=(0 0); _PAR_PANEL_H=0
    local -a fns=(_clean_s6 _clean_s9)
    local i out

    local -i before; before=$(open_fds)
    for (( i = 0; i < 300; i++ )); do _par_panel "$i" 3 26 40 0 1 > /dev/null; done   # 300 redraws = 1 minute
    assert_no_fd_growth "$before" "300 redraws of the cleanup panel"

    out=$(_par_panel 1 3 26 40 0 1)
    assert "the panel still shows each job's section and step" \
        grep -q "HOMEBREW.*brew cleanup" <<< "$out"
    assert "…for every job" grep -q "PYTHON.*pip cache purge" <<< "$out"
}

test_app_list_can_reload_hundreds_of_times() {
    ulimit -n 256
    local rows="$TEST_TMP/rows.tsv" i
    printf '/a/B.app\tBeta\tv1\t2048\n/a/A.app\tAlpha\tv2\t-1\n' > "$rows"

    local -i before; before=$(open_fds)
    for (( i = 0; i < 300; i++ )); do _picker_load "$rows" '' name; done
    assert_no_fd_growth "$before" "300 reloads of the app list"
    assert "the rows are still loaded and sorted: ${_PK_LABEL[*]:-none}" test "${_PK_LABEL[*]:-}" = "Alpha Beta"
}

# One Mac had 383 app bundles for the scan to judge; each used to cost a descriptor.
test_app_scan_can_judge_hundreds_of_apps() {
    ulimit -n 256
    local i
    local -i before; before=$(open_fds)
    for (( i = 0; i < 400; i++ )); do
        app_is_listable "$HOME/Applications/App $i.app" || { echo "assertion failed: app $i not listable"; exit 1; }
        un_safe_target "$HOME/Applications/App $i.app"  || { echo "assertion failed: app $i not removable"; exit 1; }
    done
    assert_no_fd_growth "$before" "judging 400 apps"
    refute "a system app is still refused after all that" app_is_listable "/System/Applications/Mail.app"
}

# The safety net: if the keyboard does go away, a waiting loop must end.
test_key_polling_gives_up_when_the_keyboard_is_gone() {
    local -i i polls=0
    for (( i = 0; i < 60; i++ )); do
        ui_keys_poll <&- 2>/dev/null          # stdin closed, as after the bug
        (( polls++ ))
        ui_keys_lost && break
    done
    assert "the loss is noticed after a few failed reads, not never (polls: $polls)" test "$polls" -lt 20
}
