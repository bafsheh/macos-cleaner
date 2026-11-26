#!/usr/bin/env bash
# =============================================================================
# § lib/uninstaller.sh  ·  Uninstall menu
#
#   Entry point of the "Uninstall" main-menu item. Two flows:
#
#     Apps       a live list of every app on the Mac. It appears at once and
#                fills in while a background scan measures each app; a progress
#                bar covers the whole list. Tick one or more apps, and each is
#                uninstalled completely: the app, its leftovers anywhere on the
#                system, its privacy permissions, its background services.
#     Packages   Homebrew / npm / pip / Cargo / RubyGems / loose binaries,
#                searched by name.
#
#   The work is done by the modules in lib/uninstall/:
#
#     apps.sh        find and measure every app (background scan)
#     leftovers.sh   find what one app left behind (parallel search)
#     remove.sh      uninstall one app, with a full receipt
#     packages.sh    packages and command-line tools
#
#   Requires (sourced earlier): colors.sh, core.sh, logging.sh, helpers.sh, ui.sh
#   Public entry: run_uninstaller
# =============================================================================
_UNINSTALL_DIR="${BASH_SOURCE[0]%/*}/uninstall"

# shellcheck source=lib/uninstall/apps.sh
source "$_UNINSTALL_DIR/apps.sh"
# shellcheck source=lib/uninstall/leftovers.sh
source "$_UNINSTALL_DIR/leftovers.sh"
# shellcheck source=lib/uninstall/remove.sh
source "$_UNINSTALL_DIR/remove.sh"
# shellcheck source=lib/uninstall/packages.sh
source "$_UNINSTALL_DIR/packages.sh"

# =============================================================================
# § uninstall_apps
#
#   Shows the live app list, then uninstalls each ticked app in turn. Every
#   app gets its own search, its own review and its own confirmation.
#
#   Globals:
#     reads  MC_RUN_DIR, UNINSTALL_ASSUME_YES
#     writes TOTAL_* counters (through uninstall_app)
# =============================================================================
uninstall_apps() {
    local dir bundle
    local -a chosen=()
    local -i kb done_n=0 idx=0 freed_before=$TOTAL_FREED_KB t0

    dir=$(mktemp -d "${MC_RUN_DIR:-${TMPDIR:-/tmp}}/apps.XXXXXX") || { fail "could not create a work folder"; return 1; }

    # The list opens straight away; the scan fills it in from the background.
    apps_scan_start "$dir"
    trap 'apps_scan_stop; _ui_term_restore; exit 130' INT     # Ctrl-C must stop the scan too
    ui_picker --hint 'every app on this Mac · sizes fill in as they are measured' \
              --verb uninstall --unit apps --poll apps_scan_poll \
              "Uninstall apps" "$dir/rows.tsv"
    apps_scan_stop
    trap '_ui_term_restore; exit 130' INT

    if (( PICKER_CANCELLED )); then
        rm -rf "$dir"; return 0
    fi
    chosen=("${PICKER_RESULT[@]}")      # uninstall_app opens pickers of its own

    t0=$SECONDS
    for bundle in "${chosen[@]}"; do
        (( idx++ ))
        if (( ${#chosen[@]} > 1 )); then
            printf '\n'; progress_bar "$(( idx - 1 ))" "${#chosen[@]}"
            printf "   ${DIM}app %d of %d${NC}\n" "$idx" "${#chosen[@]}"
        fi
        # size from the scan, when the scan got that far (-1 = measure again)
        kb=$(awk -F'\t' -v p="$bundle" '$1 == p && $4 >= 0 { kb = $4 } END { print (kb == "" ? -1 : kb) }' "$dir/rows.tsv")
        uninstall_app "$bundle" "$dir/meta.tsv" "$kb" && (( done_n++ ))
    done
    rm -rf "$dir"

    if (( ${#chosen[@]} > 1 )); then
        human_duration "$(( SECONDS - t0 ))"
        summary_card "All done" \
            "ok:${done_n} of ${#chosen[@]} app(s) uninstalled" \
            "ok:$(human_size $(( TOTAL_FREED_KB - freed_before ))) freed in ${REPLY}" \
            "dim:Disk now: $(disk_free)"
    fi
    ui_pause
}

# =============================================================================
# § run_uninstaller  (main-menu entry)
#
#   The uninstall sub-menu. Loops so several things can be removed in one
#   visit; returns to the main menu on Back.
# =============================================================================
run_uninstaller() {
    while true; do
        MENU_RESULT=2
        interactive_menu "Uninstall - what do you want to remove?" \
            $'Apps\tpick from every app on this Mac · leftovers and permissions go too' \
            $'Packages & command-line tools\tHomebrew · npm · pip · Cargo · RubyGems · binaries' \
            "Back"
        printf '\n'
        case $MENU_RESULT in
            0) uninstall_apps ;;
            1) uninstall_packages; ui_pause ;;
            *) return 0 ;;
        esac
    done
}
