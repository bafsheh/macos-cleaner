#!/usr/bin/env bash
# =============================================================================
# tests/test_diskscan.sh  ·  Tests for the folder scanner and what is built on it
#
#   Sourced by tests/run_tests.sh. Covers lib/helpers/duscan.sh (the parallel
#   scanner), the cleanup's disk usage report, and the disk map.
#
#   2026-11-25 · user report (screenshot): "Clean up" sat at
#       ▸ [Home directory (~) - top 30 by size]
#           path    : /Users/…  (depth 1)
#     for minutes "without any reason and not showing anything".
#     Root cause: the report ran one `du -hd 1 ~` in the foreground. It prints
#     nothing until it has walked the whole home folder on a single core, had
#     no progress display, no time limit and no way to skip it. On that Mac
#     one tree of git worktrees five levels down took 72 s on its own.
#     The same single slow tree also set the pace of the disk map.
#     Fix: both now use a scanner that splits a folder that takes too long over
#     all workers; the report shows live progress, can be skipped with `s`,
#     and stops after REPORT_TIMEOUT.
# =============================================================================

# A small tree with known content: two levels of folders, files at each level,
# a folder that is pre-split by name (Library), and a deeper tree.
make_tree() {
    local r=$1
    mkdir -p "$r/alpha/sub1" "$r/alpha/sub2/deep/deeper" "$r/beta" "$r/Library/Caches/x" "$r/Library/Logs" "$r/empty"
    dd if=/dev/zero of="$r/top.bin"                          bs=1024 count=20  2>/dev/null
    dd if=/dev/zero of="$r/alpha/a.bin"                      bs=1024 count=100 2>/dev/null
    dd if=/dev/zero of="$r/alpha/sub1/b.bin"                 bs=1024 count=200 2>/dev/null
    dd if=/dev/zero of="$r/alpha/sub2/deep/deeper/c.bin"     bs=1024 count=300 2>/dev/null
    dd if=/dev/zero of="$r/beta/d.bin"                       bs=1024 count=50  2>/dev/null
    dd if=/dev/zero of="$r/Library/loose.bin"                bs=1024 count=10  2>/dev/null
    dd if=/dev/zero of="$r/Library/Caches/x/e.bin"           bs=1024 count=400 2>/dev/null
}

# Scans ROOT to the end and writes the listing to $TEST_TMP/listing.
scan_to_the_end() {
    local root=$1 work="$TEST_TMP/scanwork"
    rm -rf "$work"; mkdir -p "$work"
    du_scan_start "$root" "$work"
    while du_scan_running; do sleep 0.1; done
    du_scan_progress "$work"
    du_scan_merge "$root" "$work" "$(du_loose_kb "$root")" > "$TEST_TMP/listing"
}

# KB the listing gives for PATH ('' when it is not listed).
listed_kb() { awk -F'\t' -v p="$1" '$2 == p { print $1 }' "$TEST_TMP/listing"; }
# KB plain du gives for PATH.
du_kb() { /usr/bin/du -sk "$1" | cut -f1; }

# ── the scanner ─────────────────────────────────────────────────────────────

test_scan_reports_the_same_sizes_as_du() {
    local r="$TEST_TMP/tree" p
    make_tree "$r"
    scan_to_the_end "$r"

    for p in "$r" "$r/alpha" "$r/alpha/sub1" "$r/alpha/sub2" "$r/beta" "$r/Library" "$r/Library/Caches"; do
        assert "size of ${p#"$TEST_TMP"/}: scan $(listed_kb "$p") KB, du $(du_kb "$p") KB" \
            test "$(listed_kb "$p")" = "$(du_kb "$p")"
    done
    assert "every job finished ($DU_SCAN_DONE of $DU_SCAN_TOTAL)" test "$DU_SCAN_DONE" -eq "$DU_SCAN_TOTAL"
    assert "nothing is marked as still growing" test -z "$(awk -F'\t' '$3 == 1' "$TEST_TMP/listing")"
    assert "folders three levels down are not listed" test -z "$(listed_kb "$r/alpha/sub2/deep")"
}

# Splitting a folder over several jobs must not change what it adds up to.
test_scan_split_into_pieces_adds_up_to_the_same_sizes() {
    local r="$TEST_TMP/tree" p
    make_tree "$r"
    export DU_SPLIT_SECS=0            # split every folder, as deep as allowed
    scan_to_the_end "$r"

    assert "the folders really were split into more jobs ($DU_SCAN_TOTAL)" test "$DU_SCAN_TOTAL" -gt 6
    for p in "$r" "$r/alpha" "$r/alpha/sub1" "$r/alpha/sub2" "$r/beta" "$r/Library" "$r/Library/Caches"; do
        assert "size of ${p#"$TEST_TMP"/}: scan $(listed_kb "$p") KB, du $(du_kb "$p") KB" \
            test "$(listed_kb "$p")" = "$(du_kb "$p")"
    done
}

# A stand-in for du that makes some folders slow:
#   w1, w2 …   take 1 s each
#   a folder that CONTAINS w* folders takes SLOW_SECS (default 30) - like one
#              `du` over a huge tree; splitting it up is the way out
#   stuck*     takes SLOW_SECS and has nothing to split - only a time limit
#              or the user can end the wait
make_slow_du() {
    cat > "$TEST_TMP/bin/du" <<'STUB'
#!/bin/bash
for last; do :; done                                   # the path is the last argument
trap 'kill $nap 2>/dev/null; exit 143' TERM
case ${last##*/} in
    w[0-9]*) sleep 1 & nap=$!; wait $nap ;;
    stuck*)  sleep "${SLOW_SECS:-30}" & nap=$!; wait $nap ;;
    *) if [[ -n $(find "$last" -type d -name 'w[0-9]*' -print -quit 2>/dev/null) ]]; then
           sleep "${SLOW_SECS:-30}" & nap=$!; wait $nap
       fi ;;
esac
exec /usr/bin/du "$@"
STUB
    chmod +x "$TEST_TMP/bin/du"
}

# User saw: the scan waited on one deep folder while every other worker idled.
test_scan_spreads_one_slow_deep_folder_over_all_workers() {
    local r="$TEST_TMP/home2" i
    mkdir -p "$r/small"; echo x > "$r/small/f"
    for i in 1 2 3 4 5 6 7 8; do
        mkdir -p "$r/work/client/trees/w$i"; echo x > "$r/work/client/trees/w$i/f"
    done
    make_slow_du
    export DM_JOBS=8

    local -i t0=$SECONDS
    scan_to_the_end "$r"
    local -i took=$(( SECONDS - t0 ))

    # One du over "work" would take 30 s. Split level by level (1 s each) and
    # then measured side by side (1 s), it is a handful of seconds.
    assert "the scan took ${took}s - the slow tree was not split up" test "$took" -lt 15
    assert "the slow tree is still measured in full" test -n "$(listed_kb "$r/work")"
    assert "and so is its sub-folder" test -n "$(listed_kb "$r/work/client")"
}

test_scan_can_be_stopped_and_keeps_what_it_measured() {
    local r="$TEST_TMP/home3" work="$TEST_TMP/scanwork"
    mkdir -p "$r/quick" "$r/stuck" "$work"
    dd if=/dev/zero of="$r/quick/f" bs=1024 count=64 2>/dev/null
    make_slow_du

    du_scan_start "$r" "$work"
    sleep 2
    local -i t0=$SECONDS
    du_scan_stop "$work"
    refute "no worker is left running" du_scan_running
    assert "stopping is quick ($(( SECONDS - t0 ))s)" test $(( SECONDS - t0 )) -lt 5
    du_scan_merge "$r" "$work" 0 > "$TEST_TMP/listing"
    assert "what was measured before the stop is kept" test "$(listed_kb "$r/quick")" = "$(du_kb "$r/quick")"
}

# ── the cleanup's disk usage report ─────────────────────────────────────────

# User saw: the report line appeared and then nothing, for minutes.
test_disk_report_does_not_freeze_on_a_slow_folder() {
    local r="$HOME/data" out
    mkdir -p "$r/photos" "$r/stuck"
    dd if=/dev/zero of="$r/photos/p" bs=1024 count=2048 2>/dev/null
    make_slow_du
    export REPORT_TIMEOUT=2

    local -i t0=$SECONDS
    out=$(report_largest_dirs "$r" "Data folder" 10)
    local -i took=$(( SECONDS - t0 ))

    assert "the report came back after ${took}s instead of waiting 30s for the slow folder" test "$took" -lt 12
    assert "the folders that were measured are listed: $out" grep -q "2.0 MB  ~/data/photos" <<< "$out"
    assert "it says the measuring was cut short"            grep -q "stopped after 2s" <<< "$out"
}

test_disk_report_shows_progress_and_can_be_skipped() {
    local r="$HOME/data" out
    mkdir -p "$r/photos" "$r/stuck"
    dd if=/dev/zero of="$r/photos/p" bs=1024 count=2048 2>/dev/null
    make_slow_du

    local -i t0=$SECONDS
    out=$(run_on_terminal 2 s "report_largest_dirs '$r' 'Data folder' 10")
    local -i took=$(( SECONDS - t0 ))

    assert "a progress line is shown while it measures" grep -q "folders measured" <<< "$out"
    assert "the progress line says how to skip"          grep -q "s to skip" <<< "$out"
    assert "pressing s ends the wait (took ${took}s)"    test "$took" -lt 12
    assert "the report says it was skipped"              grep -q "skipped" <<< "$out"
    assert "what was measured is still listed"           grep -q "photos" <<< "$out"
}

test_disk_report_measures_the_home_folder_once_for_both_lists() {
    make_tree "$HOME"
    report_reset
    report_largest_dirs "$HOME" "Home" 10 > "$TEST_TMP/first.out"
    # A second scan would call du again: let it fail loudly if that happens.
    printf '#!/bin/bash\necho "du was called again: $*" >> "%s/again"\nexec /usr/bin/du "$@"\n' "$TEST_TMP" > "$TEST_TMP/bin/du"
    chmod +x "$TEST_TMP/bin/du"
    local out; out=$(report_largest_dirs "$HOME/Library" "Library" 10)

    assert "the Library list comes from the first measurement" test ! -e "$TEST_TMP/again"
    assert "it lists the folders inside Library: $out" grep -q "Library/Caches" <<< "$out"
    assert "largest first"  test "$(grep -n 'alpha' "$TEST_TMP/first.out" | cut -d: -f1)" -lt "$(grep -n 'beta' "$TEST_TMP/first.out" | cut -d: -f1)"
}

# ── the disk map ────────────────────────────────────────────────────────────

test_disk_map_recommendations_arrive_one_by_one_and_then_report_ready() {
    export TMPDIR="$TEST_TMP/tmp"; mkdir -p "$TMPDIR"
    DM_DIR="$TEST_TMP/dm"; mkdir -p "$DM_DIR"
    mkdir -p "$HOME/.npm/_cacache" "$HOME/.gradle/caches"
    dd if=/dev/zero of="$HOME/.npm/_cacache/big" bs=1024 count=3072 2>/dev/null
    echo tiny > "$HOME/.gradle/caches/small"          # under 1 MB: no row

    # Half-way: two rows are in, the measurement is not complete.
    mkdir -p "$DM_DIR/recs.d"
    DM_RECS_READY=0 DM_RECS_DONE=0 DM_RECS_TOTAL=20
    printf 'trash\tsafe\t2048\tTrash\t~/.Trash\n' > "$DM_DIR/recs.d/00.row"
    : > "$DM_DIR/recs.d/01.row"
    assert "new rows are noticed" _dm_recs_poll
    assert "one row is shown, two are counted as checked" test "${#REC_KEY[@]}" -eq 1 -a "$DM_RECS_DONE" -eq 2
    assert "not ready yet" test "$DM_RECS_READY" -eq 0
    refute "nothing new: no redraw needed" _dm_recs_poll

    # The real thing, to the end.
    _dm_recs_start
    local -i waited=0
    until [[ -e $DM_DIR/recs.d/complete ]] || (( waited++ > 300 )); do sleep 0.1; done
    assert "the measurement finishes" test -e "$DM_DIR/recs.d/complete"
    _dm_recs_poll
    assert "ready once everything is in" test "$DM_RECS_READY" -eq 1
    assert "every recommendation was checked ($DM_RECS_DONE/$DM_RECS_TOTAL)" test "$DM_RECS_DONE" -eq "$DM_RECS_TOTAL"
    local keys=" ${REC_KEY[*]:-} "
    assert "the npm cache (3 MB) is recommended:$keys"  test "${keys/ npm /}" != "$keys"
    assert "a folder under 1 MB gets no row:$keys"      test "${keys/ gradle /}" = "$keys"
    _dm_stop_all
}

test_disk_map_draws_the_home_folder_without_a_terminal() {
    export TMPDIR="$TEST_TMP/tmp"; mkdir -p "$TMPDIR"
    make_tree "$HOME"
    local out; out=$(run_disk_map)
    assert "the map has its title: $out"      grep -q "Disk map" <<< "$out"
    assert "the biggest folder is on the map" grep -q "Library" <<< "$out"
    assert "the header is filled in"          grep -q "Safe to remove" <<< "$out"
    assert "nothing is left running"          test -z "$(pgrep -f "$TEST_TMP" || true)"
}

test_status_line_sizes_match_the_slower_formatter() {
    local kb
    for kb in 0 512 1023 1024 5000 1048575 1048576 3500000 104857599 104857600 500000000; do
        _dm_fmt_r "$kb"
        assert "size text for $kb KB: fast [$REPLY], reference [$(_dm_fmt "$kb")]" test "$REPLY" = "$(_dm_fmt "$kb")"
    done
}
