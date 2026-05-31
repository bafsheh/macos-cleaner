#!/usr/bin/env bash
# =============================================================================
# § lib/menu.sh  ·  Main menu, action registry, and queue runner
#
#   Wires the UI widgets to the action functions. Holds the single source of
#   truth for which maintenance actions exist and the order they run in.
#
#   Open/closed principle: to add a new maintenance action, append one entry to
#   each of the three parallel registry arrays below and drop a function file in
#   lib/actions/ — nothing else in this file (or the queue runner) changes.
#
#   Requires (sourced earlier): colors.sh, logging.sh, helpers.sh, ui.sh,
#                               every lib/actions/*.sh, uninstaller.sh
#   Public entry: show_main_menu
# =============================================================================

# ── action registry (parallel arrays — bash 3.2 has no ordered assoc arrays) ──
#   ACTION_LABELS[i] is shown in the checkbox list AND in the queue banner.
#   ACTION_FNS[i]    is the function invoked when that row is selected.
#   Execution order is the array order (= the list order the user sees).
declare -ra ACTION_KEYS=(clean dns ports apps)
declare -ra ACTION_LABELS=(
    "Clean up           (caches · logs · package stores · Trash)"
    "Flush DNS cache"
    "Free common dev ports"
    "Kill all open apps (spares terminals · IDE · Finder)"
)
declare -ra ACTION_FNS=(run_clean flush_dns free_ports kill_apps)

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
        printf "  ${BOLD}${CYN}▶ %s${NC}\n" "${ACTION_LABELS[i]}"
        "${ACTION_FNS[i]}"
    done

    printf '\n'
    progress_bar "$total" "$total"
    printf "   ${GRN}${BOLD}all steps complete${NC}\n\n"
}

# =============================================================================
# § run_cleanup_menu
#
#   Presents the multi-select checkbox list of maintenance actions, then runs
#   the selected ones as an ordered queue. Returns to the caller when done.
# =============================================================================
run_cleanup_menu() {
    local -a items=("Select all")
    local lbl
    for lbl in "${ACTION_LABELS[@]}"; do items+=("$lbl"); done

    interactive_multiselect "Cleanup & maintenance — choose actions to run" "${items[@]}"

    if (( MULTISELECT_CANCELLED == 1 )); then
        printf '\n'; say "Cancelled — nothing run."; printf '\n'
        return
    fi

    if [[ -z $MULTISELECT_RESULT ]]; then
        printf '\n'; say "No actions selected — nothing run."; printf '\n'
        return
    fi

    # Enforce list order: actions always run top-to-bottom as shown, regardless
    # of the order the user toggled/typed them. sort -nu also de-duplicates.
    local -a chosen=()
    local sorted
    sorted=$(printf '%s\n' $MULTISELECT_RESULT | sort -nu | tr '\n' ' ')
    read -ra chosen <<< "$sorted"
    _run_action_queue "${chosen[@]}"
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

    printf '\n'
    printf "  ${BLU}╔══════════════════════════════════════════════════════╗${NC}\n"
    printf "  ${BLU}║   ${BOLD}${WHT}macOS Cleaner${NC}${BLU}  ·  v1.1.0                          ║${NC}\n"
    printf "  ${BLU}╠══════════════════════════════════════════════════════╣${NC}\n"
    printf "  ${BLU}║   Safe disk-space cleaner for developers             ║${NC}\n"
    printf "  ${BLU}║   Disk: %-44s║${NC}\n" "$(disk_free)"
    printf "  ${BLU}╚══════════════════════════════════════════════════════╝${NC}\n"

    local -a items=(
        "Cleanup & maintenance   (clean · DNS · ports · kill apps)"
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
