#!/usr/bin/env bash
# =============================================================================
# § lib/menu.sh  ·  Main menu, action registry, and queue runner
#
#   Wires the UI widgets to the action functions. Holds the single source of
#   truth for which maintenance actions exist and the order they run in.
#
#   Open/closed principle: to add a new maintenance action, append one entry to
#   each of the three parallel registry arrays below and drop a function file in
#   lib/actions/ — nothing else in this file (or the queue runner) changes. The
#   "Shut down when done" toggle and the "Back" row are always appended after
#   the action rows, so new actions slot in above them automatically.
#
#   Requires (sourced earlier): colors.sh, logging.sh, helpers.sh, ui.sh,
#                               every lib/actions/*.sh, uninstaller.sh
#   Public entry: show_main_menu
# =============================================================================

# ── action registry (parallel arrays — bash 3.2 has no ordered assoc arrays) ──
#   ACTION_LABELS[i] is shown in the checkbox list AND in the queue banner.
#   ACTION_FNS[i]    is the function invoked when that row is selected.
#   Execution order is the array order (= the list order the user sees).
declare -ra ACTION_KEYS=(clean mem dns ports apps docker ollama)
declare -ra ACTION_LABELS=(
    "Clean up             (caches · logs · package stores · Microsoft · Trash)"
    "Free up memory       (release inactive & cached RAM)"
    "Flush DNS cache"
    "Free common dev ports"
    "Kill all open apps   (spares terminals · IDEs · Finder)"
    "Docker — remove ALL containers & images      ⚠ destructive"
    "Ollama / llama — remove ALL models & caches  ⚠ destructive"
)
declare -ra ACTION_FNS=(run_clean free_memory flush_dns free_ports kill_apps docker_clean ollama_clean)

# =============================================================================
# § _run_action_queue ACTION_INDEX...
#
#   Runs the given action indices (into the registry) in the order supplied,
#   with a progress bar + banner between steps. Only selected actions run.
# =============================================================================
_run_action_queue() {
    local -a sel=("$@")
    local -i total=${#sel[@]} idx=0 i

    ui_banner "Running ${total} selected action(s)" "in list order"

    for i in "${sel[@]}"; do
        (( idx++ ))
        printf '\n'
        progress_bar "$(( idx-1 ))" "$total"
        printf "   ${DIM}step %d of %d${NC}\n" "$idx" "$total"
        printf "  ${BOLD}${BCYN}▶ %s${NC}\n" "${ACTION_LABELS[i]}"
        "${ACTION_FNS[i]}"
    done

    printf '\n'
    progress_bar "$total" "$total"
    printf "   ${BGRN}${BOLD}all steps complete${NC}\n\n"
}

# =============================================================================
# § run_cleanup_menu
#
#   Presents the multi-select checkbox list of maintenance actions, then runs
#   the selected ones as an ordered queue. Two trailing control rows sit below
#   the actions and are NOT affected by "Select all":
#       • "Shut down Mac when all actions finish"  — second-to-last toggle
#       • "Back — return to main menu"             — always the last row
#   Returns to the caller when done (or immediately if Back is chosen).
# =============================================================================
run_cleanup_menu() {
    local -a items=("Select all")
    local lbl
    for lbl in "${ACTION_LABELS[@]}"; do items+=("$lbl"); done

    # Trailing control rows. Their result indices follow the action rows:
    #   shutdown → ${#ACTION_LABELS[@]}   (one past the last action index)
    local -i shutdown_idx=${#ACTION_LABELS[@]}
    items+=("Shut down Mac when all actions finish")
    items+=("Back — return to main menu")

    # Tell the widget the last 2 rows are controls (excluded from Select-all)
    # and which row acts as Back (activating it returns to the main menu).
    MS_TAIL_CONTROLS=2
    MS_BACK_ROW=$(( ${#items[@]} - 1 ))

    interactive_multiselect "Cleanup & maintenance — choose actions to run" "${items[@]}"

    # Back row activated → straight back to the main menu, no noise.
    if (( MULTISELECT_BACK == 1 )); then
        return
    fi
    if (( MULTISELECT_CANCELLED == 1 )); then
        printf '\n'; say "Cancelled — back to menu."; printf '\n'
        return
    fi
    if [[ -z $MULTISELECT_RESULT ]]; then
        printf '\n'; say "No actions selected — nothing run."; printf '\n'
        return
    fi

    # Enforce list order: actions always run top-to-bottom as shown, regardless
    # of the order the user toggled/typed them. sort -nu also de-duplicates.
    local -a sorted_sel=()
    local sorted
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
        printf '\n'; say "No actions selected — nothing run."; printf '\n'
        return
    fi

    _run_action_queue "${chosen[@]}"

    (( shutdown_after == 1 )) && _shutdown_system
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
    local -i secs=$secs_raw

    ui_banner "Shutdown scheduled" "Mac will power off when the countdown ends"

    if [[ -t 0 ]]; then
        printf "  ${YLW}Press any key to CANCEL.${NC}\n\n"
        local key
        while (( secs > 0 )); do
            printf "\r  ${BOLD}${BRED}Shutting down in %2ds…${NC}  " "$secs"
            if IFS= read -rsn1 -t 1 key; then
                printf '\r'; tput el 2>/dev/null
                say "Shutdown cancelled — staying on."; printf '\n'
                return 0
            fi
            (( secs-- ))
        done
        printf '\r'; tput el 2>/dev/null
    else
        # No TTY → no way to read a cancel keypress. Powering the Mac off with no
        # abort affordance would violate the safety model the other destructive
        # actions follow, so require an explicit opt-in (mirrors *_ASSUME_YES).
        if [[ ${SHUTDOWN_ASSUME_YES:-0} != 1 ]]; then
            warn "non-interactive — shutdown skipped (set SHUTDOWN_ASSUME_YES=1 to allow)"
            printf '\n'; return 0
        fi
        info "non-interactive — SHUTDOWN_ASSUME_YES=1, powering off in ${secs}s"
        sleep "$secs"
    fi

    say "Shutting down now…"
    # Graceful: lets apps save and logs out cleanly; no sudo needed.
    osascript -e 'tell application "System Events" to shut down' 2>/dev/null \
        || shutdown -h now 2>/dev/null \
        || sudo shutdown -h now
}

# =============================================================================
# § show_main_menu
#
#   Top-level menu. Dispatches to the cleanup multi-select flow, the
#   uninstaller, or exit. Loops back after each action so the user can chain
#   multiple operations in one session.
# =============================================================================
show_main_menu() {
    clear 2>/dev/null || true

    local rule; rule=$(printf '═%.0s' {1..54})
    printf '\n'
    printf "  ${ACCENT}${BOLD}╔%s╗${NC}\n" "$rule"
    printf "  ${ACCENT}${BOLD}║${NC}  ${WHT}${BOLD}%-50s${NC}  ${ACCENT}${BOLD}║${NC}\n" "macOS Cleaner    -    v1.3.0"
    printf "  ${ACCENT}${BOLD}╠%s╣${NC}\n" "$rule"
    printf "  ${ACCENT}${BOLD}║${NC}  ${DIM}%-50s${NC}  ${ACCENT}${BOLD}║${NC}\n" "Safe disk-space cleaner + maintenance"
    printf "  ${ACCENT}${BOLD}║${NC}  ${DIM}%-50s${NC}  ${ACCENT}${BOLD}║${NC}\n" "Disk: $(disk_free)"
    printf "  ${ACCENT}${BOLD}╚%s╝${NC}\n" "$rule"

    local -a items=(
        "Cleanup & maintenance"
        "Uninstall an app or package"
        "Exit"
    )

    MENU_RESULT=2
    interactive_menu "What would you like to do?" "${items[@]}"

    printf '\n'
    case $MENU_RESULT in
        0) run_cleanup_menu;  show_main_menu ;;
        1) run_uninstaller;   show_main_menu ;;
        *) say "Bye."; printf '\n'; exit 0 ;;
    esac
}
