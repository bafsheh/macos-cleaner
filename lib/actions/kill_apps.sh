#!/usr/bin/env bash
# =============================================================================
# § lib/actions/kill_apps.sh  ·  Force-quit open GUI applications
#
#   Quits every visible (foreground) GUI app, EXCEPT:
#     • terminal emulators        - so the running session is never killed
#     • the script's own ancestry - whatever launched us (e.g. VS Code's
#                                   integrated terminal) is spared dynamically,
#                                   so the script never kills itself, without
#                                   hardcoding editors into the spare list.
#   Everything else (editors, IDEs, Finder, browsers, …) IS closed.
#   Background/menu-bar agents are excluded automatically: we only enumerate
#   processes where "background only is false".
#
#   Each app is asked to quit gracefully first (bounded by a timeout to avoid
#   hanging on save dialogs); if it is still alive afterwards we escalate
#   SIGTERM → SIGKILL against its PID until the process is actually gone.
#   Success is verified by the PID disappearing, never by osascript's exit code
#   (AppleScript "quit" is asynchronous and returns 0 before the app dies).
#
#   The user must confirm (y/N) before anything is quit (interactive only).
#
#   Requires (sourced earlier): colors.sh, logging.sh, helpers.sh (run_timeout)
#   Public entry: kill_apps
# =============================================================================

# Exact lowercase app names that are always spared: terminal emulators only,
# so the session running this script is never killed. Editors/IDEs (VS Code,
# Cursor, JetBrains, Xcode, …) are intentionally NOT here - they get closed.
declare -ra SPARE_EXACT=(
    "terminal" "iterm" "iterm2" "warp" "ghostty" "alacritty" "kitty"
    "hyper" "wezterm" "tabby" "rio"
)

# Lowercase substrings that mark a terminal emulator whose reported name varies.
declare -ra SPARE_SUBSTR=(
    "iterm" "terminal"
)

# ── _kapps_is_spared NAME → 0 (spare) / 1 (killable) ─────────────────────────
_kapps_is_spared() {
    local lc; lc=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
    local s
    for s in "${SPARE_EXACT[@]}";  do [[ $lc == "$s" ]]   && return 0; done
    for s in "${SPARE_SUBSTR[@]}"; do [[ $lc == *"$s"* ]] && return 0; done
    return 1
}

# ── _kapps_ancestor_pids → prints the PID chain from this process up to pid 1 ──
#   Whatever launched us (login shell, terminal, or an editor's integrated
#   terminal) appears in this chain. Sparing these PIDs means the script never
#   force-kills its own host, so we can safely close editors like VS Code when
#   the script is run from a real terminal, yet leave the host intact when it
#   is run from the editor's own terminal.
_kapps_ancestor_pids() {
    local pid=$$
    while (( pid > 1 )); do
        printf '%s\n' "$pid"
        pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
        [[ -z $pid ]] && break
    done
}

# ── _kapps_wait_dead PID TIMEOUT → 0 (process gone) / 1 (still alive) ─────────
#   Polls `kill -0` (send no signal, just probe existence) up to TIMEOUT
#   seconds. This is what turns "quit" from fire-and-forget into a verified
#   outcome.
_kapps_wait_dead() {
    local pid=$1 timeout=$2
    local -i waited=0
    while (( waited < timeout * 5 )); do          # poll every 200ms
        kill -0 "$pid" 2>/dev/null || return 0    # gone
        sleep 0.2
        (( waited++ ))
    done
    kill -0 "$pid" 2>/dev/null && return 1        # still alive
    return 0
}

kill_apps() {
    section "KILL OPEN APPS"

    if ! command -v osascript &>/dev/null; then
        warn "osascript not found - cannot enumerate apps"
        echo; return 0
    fi

    say "Scanning for open GUI applications"
    info "spared  : terminals + the app hosting this session"

    # ── enumerate visible (non-background) processes as "name<TAB>pid" ───────
    #   The PID (unix id) is what makes force-kill reliable: the display name
    #   reported here often differs from the Unix process name, so pkill by name
    #   is unreliable. We escalate against the PID instead.
    local raw
    raw=$(osascript <<'OSA' 2>/dev/null
tell application "System Events"
    set out to ""
    repeat with p in (every process whose background only is false)
        set out to out & (name of p) & tab & (unix id of p) & linefeed
    end repeat
end tell
return out
OSA
)

    #   Never target our own process ancestry (the shell running this script and
    #   whatever launched it - terminal, or an editor's integrated terminal),
    #   regardless of app name. This is what lets us close editors like VS Code
    #   safely without risking the host session. Kept as a space-padded string
    #   (not an associative array) for bash 3.2 compatibility.
    local spare_pids=" "
    local apid
    while IFS= read -r apid; do
        [[ -n $apid ]] && spare_pids+="$apid "
    done < <(_kapps_ancestor_pids)

    local -a targets=() target_pids=()
    local name pid
    while IFS=$'\t' read -r name pid; do
        [[ -z $name || -z $pid ]] && continue
        _kapps_is_spared "$name" && continue
        [[ $spare_pids == *" $pid "* ]] && continue
        targets+=("$name")
        target_pids+=("$pid")
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

    # ── quit each: graceful (bounded) first, then escalate against the PID ───
    #   AppleScript "quit" is asynchronous — osascript returns 0 immediately.
    #   So we ignore its exit code and instead poll the PID: only when the
    #   process is truly gone do we count success. If it lingers, escalate
    #   SIGTERM, then SIGKILL, verifying after each step.
    local -i quit=0 forced=0 failed=0
    local -i i
    for i in "${!targets[@]}"; do
        name=${targets[$i]}
        pid=${target_pids[$i]}
        step "[$name] (pid $pid)"

        # 1) ask nicely and give it a moment to shut down cleanly.
        run_timeout 8 osascript -e "tell application \"${name}\" to quit" &>/dev/null
        if _kapps_wait_dead "$pid" 8; then
            (( quit++ )); ok "quit gracefully ← $name"
            continue
        fi

        # 2) still alive → SIGTERM the PID, wait briefly.
        kill -TERM "$pid" 2>/dev/null
        if _kapps_wait_dead "$pid" 4; then
            (( forced++ )); warn "force-killed (SIGTERM) ← $name"
            continue
        fi

        # 3) last resort → SIGKILL, cannot be ignored.
        kill -KILL "$pid" 2>/dev/null
        if _kapps_wait_dead "$pid" 3; then
            (( forced++ )); warn "force-killed (SIGKILL) ← $name"
        else
            (( failed++ )); fail "could not quit ← $name (pid $pid still alive)"
        fi
    done

    echo
    say "Done - graceful: ${quit}   forced: ${forced}   failed: ${failed}"
    echo
}
