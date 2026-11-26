#!/usr/bin/env bash
# =============================================================================
# tests/test_ui.sh  ·  Tests for the UI layer, logging and the menu registry
#
#   Sourced by tests/run_tests.sh. The widgets are driven the way a script
#   drives them - no terminal - so these cover the logic (key parsing, row
#   loading, fallbacks, formatting), not the drawing.
#
#   2026-11-25 · the run log was unreadable in an editor: every line carried
#     raw colour codes, because the log was a copy of the terminal output.
#     Log lines are now written as plain text (test_log_file_is_plain_text…).
# =============================================================================

# ── keyboard ────────────────────────────────────────────────────────────────

test_key_parser_names_arrows_and_splits_a_burst_of_keys() {
    _ui_keys_parse $'\033[A'
    assert "Up arrow, got: ${UI_KEYS[*]}" test "${UI_KEYS[*]}" = "UP"

    # key repeat delivers several presses in one read
    _ui_keys_parse $'\033[B\033[B\033[6~ a\n'
    assert "a burst is split in order, got: ${UI_KEYS[*]}" \
        test "${UI_KEYS[*]}" = "DOWN DOWN PGDN SPACE a ENTER"

    _ui_keys_parse $'\033'
    assert "a lone Escape, got: ${UI_KEYS[*]}" test "${UI_KEYS[*]}" = "ESC"

    _ui_keys_parse $'\177x'
    assert "Backspace then a letter, got: ${UI_KEYS[*]}" test "${UI_KEYS[*]}" = "BACKSPACE x"

    _ui_keys_parse $'\033[38;5;1mq'
    assert "an unknown sequence is skipped, got: ${UI_KEYS[*]}" test "${UI_KEYS[*]}" = "q"
}

# ── progress bar ────────────────────────────────────────────────────────────

test_progress_bar_fills_in_proportion_and_never_overflows() {
    ui_bar 0 10 10;   assert "empty at 0: [$REPLY]"      test "$REPLY" = "----------"
    ui_bar 5 10 10;   assert "half at 5/10: [$REPLY]"    test "$REPLY" = "#####-----"
    ui_bar 10 10 10;  assert "full at 10/10: [$REPLY]"   test "$REPLY" = "##########"
    ui_bar 99 10 10;  assert "capped past the end: [$REPLY]" test "$REPLY" = "##########"
    ui_bar 3 0 10;    assert "a zero total does not divide by zero: [$REPLY]" test "${#REPLY}" -eq 10
    assert "progress_bar prints the percentage" test "$(progress_bar 1 4 8)" = "  [##------]  25%"
}

# ── picker ──────────────────────────────────────────────────────────────────

# Rows as a producer writes them: listed first without a size, then measured.
make_rows() {
    printf '%s\t%s\t%s\t%s\n' \
        /a/Zed.app   "Zed"    "v1 · /Applications" -1 \
        /a/Alpha.app "Alpha"  "v2 · /Applications" -1 \
        /a/Big.app   "Big"    "v3 · /Applications" -1 \
        /a/Alpha.app "Alpha"  "v2 · /Applications" 2048 \
        /a/Big.app   "Big"    "v3 · /Applications" 4194304 \
        /a/Zed.app   "Zed"    "v1 · /Applications" 10 > "$TEST_TMP/rows.tsv"
}

test_picker_shows_each_row_once_with_its_latest_size() {
    make_rows
    _picker_load "$TEST_TMP/rows.tsv" '' name
    assert "one row per app, got ${#_PK_ID[@]}"      test "${#_PK_ID[@]}" -eq 3
    assert "sorted by name: ${_PK_LABEL[*]}"         test "${_PK_LABEL[*]}" = "Alpha Big Zed"
    assert "the measured size replaced the placeholder: ${_PK_SIZE[*]}" \
        test "${_PK_SIZE[0]}" = "2.0 MB" -a "${_PK_SIZE[1]}" = "4.00 GB" -a "${_PK_SIZE[2]}" = "10 KB"

    _picker_load "$TEST_TMP/rows.tsv" '' size
    assert "sorted by size, largest first: ${_PK_LABEL[*]}" test "${_PK_LABEL[*]}" = "Big Alpha Zed"

    _picker_load "$TEST_TMP/rows.tsv" 'ALP' name
    assert "the filter ignores case: ${_PK_LABEL[*]:-none}" test "${_PK_LABEL[*]:-}" = "Alpha"
    assert "totals still cover every row" test "${#_PK_ALL_ID[@]}" -eq 3
}

test_picker_shows_an_unmeasured_row_as_pending() {
    printf '/a/New.app\tNew\tv1\t-1\n' > "$TEST_TMP/rows.tsv"
    _picker_load "$TEST_TMP/rows.tsv" '' name
    assert "a size still being measured shows as …, got [${_PK_SIZE[0]}]" test "${_PK_SIZE[0]}" = "…"
}

test_picker_without_a_terminal_reads_numbers_from_input() {
    make_rows
    ui_picker "Pick" "$TEST_TMP/rows.tsv" <<< "1 3" > /dev/null
    assert "rows 1 and 3 by name are returned: ${PICKER_RESULT[*]:-}" \
        test "${PICKER_RESULT[*]:-}" = "/a/Alpha.app /a/Zed.app"
    assert "not cancelled" test "$PICKER_CANCELLED" -eq 0

    ui_picker "Pick" "$TEST_TMP/rows.tsv" <<< "" > /dev/null
    assert "a blank answer cancels" test "$PICKER_CANCELLED" -eq 1

    ui_picker "Pick" "$TEST_TMP/rows.tsv" <<< "9 x 0" > /dev/null
    assert "numbers out of range are ignored" test "$PICKER_CANCELLED" -eq 1
}

# ── menus ───────────────────────────────────────────────────────────────────

test_menu_without_a_terminal_falls_back_to_a_numbered_prompt() {
    local out
    out=$(interactive_menu "Title" $'First\tdoes one thing' "Second" "Exit" <<< "2"; echo "result=$MENU_RESULT")
    assert "the description is printed beside the label" grep -q "1.  First  - does one thing" <<< "$out"
    assert "choice 2 selects index 1"                    grep -q "result=1" <<< "$out"

    out=$(interactive_menu "Title" "First" "Exit" <<< "junk"; echo "result=$MENU_RESULT")
    assert "junk input falls back to the last item (Exit)" grep -q "result=1" <<< "$out"
}

test_every_menu_action_has_a_label_and_a_function() {
    local -i i
    assert "labels and functions line up" test "${#ACTION_LABELS[@]}" -eq "${#ACTION_FNS[@]}"
    assert "keys and functions line up"   test "${#ACTION_KEYS[@]}" -eq "${#ACTION_FNS[@]}"
    for (( i=0; i<${#ACTION_FNS[@]}; i++ )); do
        assert "action ${ACTION_KEYS[i]} → ${ACTION_FNS[i]} is a defined function" \
            declare -F "${ACTION_FNS[i]}"
        assert "action ${ACTION_KEYS[i]} has a description" test "${ACTION_LABELS[i]}" != "${ACTION_LABELS[i]%%$'\t'*}"
    done > /dev/null
}

# ── logging ─────────────────────────────────────────────────────────────────

# User saw: a log file full of "^[[1;92m" codes.
test_log_file_is_plain_text_even_when_the_terminal_is_coloured() {
    local esc=$'\033'
    # Same lines the helpers emit when colour is on.
    _log "${esc}[1;38;5;84m✓${esc}[0m freed ${esc}[1m120 MB${esc}[0m ← Xcode"
    ok "all good"; warn "careful"; fail "broken"; kv path "/tmp/x"

    refute "no escape byte reaches the log file" grep -q "$esc" "$LOG_FILE"
    assert "the text itself is kept"              grep -q "✓ freed 120 MB ← Xcode" "$LOG_FILE"
    assert "each line carries the elapsed time"   grep -Eq '^\[\+[0-9]{2}:[0-9]{2}\]   ✓ all good$' "$LOG_FILE"
}

test_strip_ansi_removes_colour_and_cursor_codes_only() {
    strip_ansi $'\033[1;31mred\033[0m and \033[2Kplain [not a code] 100%'
    assert "got [$REPLY]" test "$REPLY" = "red and plain [not a code] 100%"
}

test_summary_card_keeps_its_border_whatever_the_line_length() {
    local out line
    local -i width=0
    out=$(summary_card "Recap" "ok:short" "warn:$(printf 'x%.0s' {1..150})" "dim:detail")
    while IFS= read -r line; do
        [[ -z $line ]] && continue
        (( width == 0 )) && width=${#line}
        assert "every line of the card is $width wide: [$line]" test "${#line}" -eq "$width"
    done <<< "$out"
    assert "the long line was cut, not wrapped" grep -q "…" <<< "$out"
}

test_durations_and_sizes_read_naturally() {
    human_duration 42;   assert "seconds: $REPLY" test "$REPLY" = "42s"
    human_duration 185;  assert "minutes: $REPLY" test "$REPLY" = "3m 05s"
    human_duration 4320; assert "hours: $REPLY"   test "$REPLY" = "1h 12m"
    assert "KB" test "$(human_size 12)" = "12 KB"
    assert "MB" test "$(human_size 2048)" = "2.0 MB"
    assert "GB" test "$(human_size 1572864)" = "1.50 GB"
}

# ── the "finished" prompt ───────────────────────────────────────────────────
#
#   2026-11-25 · user report: at the end of an app uninstall the line
#     "Press any key to go back to the menu…" was not clear, and after the key
#     the old output stayed on screen with the menu drawn underneath it.
#     Root cause: ui_pause printed one dim line that did not say what the key
#     does, and on a keypress erased only that line (\r ESC[K) instead of the
#     screen.

# ui_pause between two marker lines, on a terminal, with one key pressed
# after a moment.
pause_on_a_terminal() {
    run_on_terminal 1 x "printf 'UNINSTALL SUMMARY\n'; ui_pause; printf 'NEXT MENU\n'"
}

test_finished_prompt_says_what_a_key_does_and_then_clears_the_screen() {
    local out after clear_screen=$'\033[2J'
    out=$(pause_on_a_terminal)

    assert "the prompt says a key clears the screen: $(strip_ansi "$out"; printf '%s' "$REPLY" | tr -d '\r')" \
        grep -qi "press any key to clear the screen" <<< "$out"
    assert "the prompt says where you land next" grep -qi "return to the menu" <<< "$out"

    # what the terminal received once the key was pressed
    after=${out#*UNINSTALL SUMMARY}
    assert "the screen is cleared after the key" test "${after#*"$clear_screen"}" != "$after"
    after=${after#*"$clear_screen"}
    assert "the next menu is drawn after the clear, on an empty screen" grep -q "NEXT MENU" <<< "$after"
    refute "the old summary is not printed again" grep -q "UNINSTALL SUMMARY" <<< "$after"
}

test_finished_prompt_is_skipped_when_there_is_no_terminal() {
    local out; out=$(printf 'A\n'; ui_pause; printf 'B\n')
    assert "nothing is printed and nothing is cleared: [$out]" test "$out" = $'A\nB'
}
