#!/usr/bin/env bash
# =============================================================================
# § lib/menu.sh  ·  Main menu, action registry, and queue runner
#
#   Wires the UI widgets to the action functions. Holds the single source of
#   truth for which maintenance actions exist and the order they run in.
#
#   Open/closed principle: to add a new maintenance action, append one entry to
#   each of the three parallel registry arrays below and drop a function file in
#   lib/actions/ - nothing else in this file (or the queue runner) changes. The
#   "Shut down when done" toggle and the "Back" row are always appended after
#   the action rows, so new actions slot in above them automatically.
#
#   Requires (sourced earlier): colors.sh, logging.sh, helpers.sh, ui.sh,
#                               every lib/actions/*.sh, uninstaller.sh
#   Public entry: show_main_menu
# =============================================================================

# ── action registry (parallel arrays - bash 3.2 has no ordered assoc arrays) ──
#   ACTION_LABELS[i] is "label<TAB>description": the label is shown in the
#                    checkbox list and in the queue banner, the description
#                    beside it in a quieter colour (red when it starts with ⚠).
#   ACTION_FNS[i]    is the function invoked when that row is selected.
#   Execution order is the array order (= the list order the user sees).
# shellcheck disable=SC2034  # ACTION_KEYS documents the registry order
declare -ra ACTION_KEYS=(clean trash temp mem dns ports apps worktrees projects docker colima ollama)
declare -ra ACTION_LABELS=(
    $'Clean up\tcaches · logs · package stores · Microsoft · Trash'
    $'Empty Trash\tall volumes · works without Full Disk Access'
    $'Clean temp files\tstale /tmp · TMPDIR · old Claude Code sessions'
    $'Free up memory\trelease inactive & cached RAM'
    $'Flush DNS cache\tfixes stale website addresses'
    $'Free common dev ports\tstops whatever holds 3000 · 5173 · 8080 …'
    $'Kill all open apps\tspares terminals and the app running this session'
    $'Stale git worktrees\tclean · pushed · idle 7+ days · branches kept'
    $'Project build dirs\tnode_modules · .venv · target · Git-ignored'
    $'Docker\t⚠ removes ALL containers & images'
    $'Colima\t⚠ deletes its VMs & their Docker data'
    $'Ollama / llama\t⚠ removes ALL models & caches'
)
declare -ra ACTION_FNS=(run_clean _trash_action clean_temp free_memory flush_dns free_ports kill_apps worktree_clean project_clean docker_clean colima_clean ollama_clean)

# Standalone "Empty Trash" row: empty_trash plus its own heading.
_trash_action() {
    section "TRASH"
    empty_trash
}

# =============================================================================
# § _run_action_queue ACTION_INDEX...
#
#   Runs the given action indices (into the registry) in the order supplied,
#   with a progress bar + heading between steps, then prints a recap: one line
#   per action with the space it freed, how long it took, and whether any of
#   its steps failed. Only selected actions run.
#
#   Globals:
#     reads  ACTION_LABELS, ACTION_FNS
#     reads/writes TOTAL_FREED_KB, TOTAL_FAILED (through the actions)
# =============================================================================
_run_action_queue() {
    local -a sel=("$@") recap=()
    local -i total=${#sel[@]} idx=0 i t0 q0=$SECONDS freed0 failed0 freed failed
    local -i all_freed0=$TOTAL_FREED_KB
    local label took line

    ui_banner "Running ${total} selected action(s)" "in list order"

    for i in "${sel[@]}"; do
        (( idx++ ))
        label=${ACTION_LABELS[i]%%$'\t'*}
        printf '\n'
        progress_bar "$(( idx-1 ))" "$total"
        printf "   ${DIM}step %d of %d${NC}\n" "$idx" "$total"
        printf "  ${BOLD}${BCYN}▶ %s${NC}\n" "$label"

        t0=$SECONDS freed0=$TOTAL_FREED_KB failed0=$TOTAL_FAILED
        "${ACTION_FNS[i]}"
        (( freed = TOTAL_FREED_KB - freed0, failed = TOTAL_FAILED - failed0 ))

        human_duration "$(( SECONDS - t0 ))"; took=$REPLY
        line="${label} · ${took}"
        (( freed > 0 )) && line="${label} · $(human_size "$freed") freed · ${took}"
        if (( failed > 0 )); then recap+=("warn:${line} · ${failed} step(s) failed")
        else                      recap+=("ok:${line}"); fi
    done

    printf '\n'
    progress_bar "$total" "$total"
    printf "   ${BGRN}${BOLD}all steps complete${NC}\n"

    human_duration "$(( SECONDS - q0 ))"
    recap+=("dim:Total: $(human_size $(( TOTAL_FREED_KB - all_freed0 ))) freed in ${REPLY} · disk now $(disk_free)")
    summary_card "What happened" "${recap[@]}"
    info "Full log: ${LOG_FILE}"
}

# =============================================================================
# § run_cleanup_menu
#
#   Presents the multi-select checkbox list of maintenance actions, then runs
#   the selected ones as an ordered queue. Two trailing control rows sit below
#   the actions and are NOT affected by "Select all":
#       • "Shut down Mac when all actions finish"  - second-to-last toggle
#       • "Back - return to main menu"             - always the last row
#   Returns to the caller when done (or immediately if Back is chosen).
# =============================================================================
run_cleanup_menu() {
    local -a items=("Select all")
    local lbl
    for lbl in "${ACTION_LABELS[@]}"; do items+=("$lbl"); done

    # Trailing control rows. Their result indices follow the action rows:
    #   shutdown → ${#ACTION_LABELS[@]}   (one past the last action index)
    local -i shutdown_idx=${#ACTION_LABELS[@]}
    items+=($'Shut down Mac when done\tcancellable countdown')
    items+=("Back - return to main menu")

    # Tell the widget the last 2 rows are controls (excluded from Select-all)
    # and which row acts as Back (activating it returns to the main menu).
    # shellcheck disable=SC2034  # options read by interactive_multiselect
    MS_TAIL_CONTROLS=2 MS_BACK_ROW=$(( ${#items[@]} - 1 ))

    interactive_multiselect "Cleanup & maintenance - choose actions to run" "${items[@]}"

    # Back row activated → straight back to the main menu, no noise.
    if (( MULTISELECT_BACK == 1 )); then
        return
    fi
    if (( MULTISELECT_CANCELLED == 1 )); then
        printf '\n'; say "Cancelled - back to menu."; printf '\n'
        return
    fi
    if [[ -z $MULTISELECT_RESULT ]]; then
        printf '\n'; say "No actions selected - nothing run."; printf '\n'
        return
    fi

    # Enforce list order: actions always run top-to-bottom as shown, regardless
    # of the order the user toggled/typed them. sort -nu also de-duplicates.
    local -a sorted_sel=()
    local sorted
    # shellcheck disable=SC2086  # word-splitting the index list is intended
    sorted=$(printf '%s\n' $MULTISELECT_RESULT | sort -nu | tr '\n' ' ')
    read -ra sorted_sel <<< "$sorted"

    # Split the shutdown toggle out; keep only valid action indices (defensive:
    # ignore anything out of range, e.g. a stray Back index). The length guard
    # keeps the loop safe under `set -u` even if sorted_sel ends up empty.
    local -a chosen=()
    local -i shutdown_after=0 x
    (( ${#sorted_sel[@]} > 0 )) && for x in "${sorted_sel[@]}"; do
        if (( x == shutdown_idx )); then
            shutdown_after=1
        elif (( x >= 0 && x < ${#ACTION_LABELS[@]} )); then
            chosen+=("$x")
        fi
    done

    if (( ${#chosen[@]} == 0 )); then
        printf '\n'; say "No actions selected - nothing run."; printf '\n'
        return
    fi

    _run_action_queue "${chosen[@]}"

    if (( shutdown_after == 1 )); then
        _shutdown_system
    else
        ui_pause      # keep the recap on screen until a key, then clear it
    fi
}

# =============================================================================
# § _shutdown_system
#
#   Gracefully powers off the Mac after a short, cancellable countdown. Backs
#   the "Shut down Mac when all actions finish" cleanup toggle. Press any key
#   during the countdown to abort. Delay is tunable via SHUTDOWN_DELAY (seconds).
# =============================================================================
_shutdown_system() {
    # Sanitise the user-supplied delay first: assigning a non-numeric value to an
    # integer (`local -i`) aborts the whole run under `set -u` (it is evaluated
    # as an arithmetic expression → unbound variable). Fall back to 15 on junk.
    local secs_raw=${SHUTDOWN_DELAY:-15}
    [[ $secs_raw =~ ^[0-9]+$ ]] || secs_raw=15
    local -i secs=$secs_raw total=$secs_raw

    ui_banner "Shutdown scheduled" "Mac will power off when the countdown ends"

    if [[ -t 0 ]]; then
        printf "  ${YLW}Press any key to CANCEL.${NC}\n\n"
        local key
        while (( secs > 0 )); do
            ui_bar "$secs" "$total" 20 "$RED"
            printf "\r  %s  ${BOLD}${BRED}Shutting down in %2ds…${NC}  \033[K" "$REPLY" "$secs"
            if IFS= read -rsn1 -t 1 key; then
                printf '\r\033[K'
                say "Shutdown cancelled - staying on."; printf '\n'
                return 0
            fi
            (( secs-- ))
        done
        printf '\r\033[K'
    else
        # No TTY → no way to read a cancel keypress. Powering the Mac off with no
        # abort affordance would violate the safety model the other destructive
        # actions follow, so require an explicit opt-in (mirrors *_ASSUME_YES).
        if [[ ${SHUTDOWN_ASSUME_YES:-0} != 1 ]]; then
            warn "non-interactive - shutdown skipped (set SHUTDOWN_ASSUME_YES=1 to allow)"
            printf '\n'; return 0
        fi
        info "non-interactive - SHUTDOWN_ASSUME_YES=1, powering off in ${secs}s"
        sleep "$secs"
    fi

    say "Shutting down now…"
    # Graceful: lets apps save and logs out cleanly; no sudo needed.
    osascript -e 'tell application "System Events" to shut down' 2>/dev/null \
        || shutdown -h now 2>/dev/null \
        || sudo shutdown -h now
}

# =============================================================================
# § _menu_header
#
#   The title card above the main menu: name, version, and a gauge of how full
#   the disk is (green, amber from 75 %, red from 90 %).
# =============================================================================
_menu_header() {
    local -i pct width=54 pad
    local colour rule line plain
    pct=$(disk_used_pct)
    if   (( pct >= 90 )); then colour=$RED
    elif (( pct >= 75 )); then colour=$YLW
    else                       colour=$GRN
    fi
    ui_bar "$pct" 100 24 "$colour"

    printf -v rule '%*s' "$width" ''; rule=${rule// /─}
    printf '\n'
    printf "  ${ACCENT}╭%s╮${NC}\n" "$rule"
    for line in \
        "$(printf '%s%s%s%*s%sv%s%s' "$WHT" "macOS Cleaner" "$NC" "$(( width - 18 - ${#MC_VERSION} ))" '' "$DIM" "$MC_VERSION" "$NC")" \
        "${DIM}Safe disk-space cleaner + maintenance${NC}" \
        "" \
        "${DIM}Disk${NC}  ${REPLY}  ${BOLD}${pct}%${NC} ${DIM}used${NC}" \
        "      ${DIM}$(disk_free)${NC}"
    do
        strip_ansi "$line"; plain=$REPLY
        (( pad = width - 4 - ${#plain} )); (( pad < 0 )) && pad=0
        printf "  ${ACCENT}│${NC}  %s%*s  ${ACCENT}│${NC}\n" "$line" "$pad" ''
    done
    printf "  ${ACCENT}╰%s╯${NC}\n" "$rule"
}

# =============================================================================
# § show_main_menu
#
#   One round of the top-level menu: draws it, waits for a choice, and runs
#   the cleanup multi-select flow, the disk map, the uninstaller, or exits.
#
#   It deliberately does NOT loop. mac_cleaner.sh calls it in a loop at the
#   top level of the script, because only there does bash 3.2 release the
#   file descriptors of the process substitutions used during an action (see
#   lib/core.sh). With scripted input the loop ends by itself: when the input
#   runs out, the menu's fallback picks Exit.
# =============================================================================
show_main_menu() {
    local -a items=(
        $'Cleanup & maintenance\tfree space · tidy caches · quick fixes'
        $'Disk map\tsee what is using your space'
        $'Uninstall\tapps with all their leftovers · packages'
        "Exit"
    )

    clear 2>/dev/null || true
    _menu_header

    MENU_RESULT=3
    interactive_menu "What would you like to do?" "${items[@]}"

    printf '\n'
    case $MENU_RESULT in
        0) run_cleanup_menu ;;
        1) run_disk_map ;;
        2) run_uninstaller ;;
        *) say "Bye."; printf '\n'; exit 0 ;;
    esac
}
