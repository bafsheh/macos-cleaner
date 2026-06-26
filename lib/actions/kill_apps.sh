#!/usr/bin/env bash
# =============================================================================
# § lib/actions/kill_apps.sh  ·  Force-quit open GUI applications
#
#   Quits every visible (foreground) GUI app, EXCEPT a protected set:
#     • terminal emulators  - so the running session is never killed
#     • code editors / IDEs - so the editor the script may be launched from survives
#     • Finder              - core system UI
#   Background/menu-bar agents are excluded automatically: we only enumerate
#   processes where "background only is false".
#
#   Each app is asked to quit gracefully first (bounded by a timeout to avoid
#   hanging on save dialogs); a force kill is the fallback.
#
#   The user must confirm (y/N) before anything is quit (interactive only).
#
#   Requires (sourced earlier): colors.sh, logging.sh, helpers.sh (run_timeout)
#   Public entry: kill_apps
# =============================================================================

# Exact lowercase app names that are always spared.
declare -ra SPARE_EXACT=(
    # terminal emulators
    "terminal" "iterm" "iterm2" "warp" "ghostty" "alacritty" "kitty"
    "hyper" "wezterm" "tabby" "rio"
    # editors / IDEs
    "code" "code - insiders" "cursor" "windsurf" "zed" "sublime text"
    "nova" "electron"
    # system UI
    "finder"
)

# Lowercase substrings that mark an editor/IDE worth sparing (covers the many
# JetBrains products and editor variants whose process names differ).
declare -ra SPARE_SUBSTR=(
    "jetbrains" "intellij" "pycharm" "webstorm" "goland" "rubymine" "clion"
    "phpstorm" "datagrip" "rider" "appcode" "android studio" "visual studio"
    "xcode" "cursor" "windsurf"
)

# ── _kapps_is_spared NAME → 0 (spare) / 1 (killable) ─────────────────────────
_kapps_is_spared() {
    local lc; lc=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
    local s
    for s in "${SPARE_EXACT[@]}";  do [[ $lc == "$s" ]]   && return 0; done
    for s in "${SPARE_SUBSTR[@]}"; do [[ $lc == *"$s"* ]] && return 0; done
    return 1
}

kill_apps() {
    section "KILL OPEN APPS"

    if ! command -v osascript &>/dev/null; then
        warn "osascript not found - cannot enumerate apps"
        echo; return 0
    fi

    say "Scanning for open GUI applications"
    info "spared  : terminals · editors/IDEs · Finder"

    # ── enumerate visible (non-background) processes, one name per line ──────
    local raw
    raw=$(osascript <<'OSA' 2>/dev/null
tell application "System Events"
    set out to ""
    repeat with p in (every process whose background only is false)
        set out to out & (name of p) & linefeed
    end repeat
end tell
return out
OSA
)

    local -a targets=()
    local name
    while IFS= read -r name; do
        [[ -z $name ]] && continue
        _kapps_is_spared "$name" && continue
        targets+=("$name")
    done <<< "$raw"

    if (( ${#targets[@]} == 0 )); then
        info "no killable foreground apps found - nothing to do"
        echo; return 0
    fi

    # ── show what will be quit ────────────────────────────────────────────────
    say "${#targets[@]} app(s) will be force-quit:"
    for name in "${targets[@]}"; do info "  • $name"; done
    echo

    # ── confirm before quitting ──────────────────────────────────────────────
    #   Destructive action → confirmation is required. When stdin is not a TTY
    #   we cannot prompt, so the safe default is to SKIP. Automation can opt in
    #   explicitly with KILL_APPS_ASSUME_YES=1.
    if [[ -t 0 ]]; then
        printf "  ${YLW}Quit these ${#targets[@]} app(s)? [y/N]: ${NC}"
        local answer; read -r answer
        if [[ $answer != [yY] ]]; then
            info "Cancelled - no apps were quit."
            echo; return 0
        fi
    elif [[ ${KILL_APPS_ASSUME_YES:-0} == 1 ]]; then
        info "non-interactive - KILL_APPS_ASSUME_YES=1, proceeding"
    else
        warn "non-interactive and no confirmation possible - skipping (set KILL_APPS_ASSUME_YES=1 to override)"
        echo; return 0
    fi
    echo

    # ── quit each: graceful (bounded) first, force kill as fallback ──────────
    local -i quit=0 forced=0 failed=0
    for name in "${targets[@]}"; do
        step "[$name]"
        if run_timeout 8 osascript -e "tell application \"${name}\" to quit" &>/dev/null; then
            (( quit++ )); ok "quit gracefully ← $name"
        elif pkill -x "$name" 2>/dev/null; then
            (( forced++ )); warn "force-killed ← $name"
        else
            (( failed++ )); fail "could not quit ← $name"
        fi
    done

    echo
    say "Done - graceful: ${quit}   forced: ${forced}   failed: ${failed}"
    echo
}
