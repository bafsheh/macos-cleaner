#!/usr/bin/env bash
# =============================================================================
# § lib/uninstall/remove.sh  ·  Uninstall one app, completely
#
#   Single responsibility: take one app off the Mac and show exactly what was
#   done. The flow, each step logged as it happens:
#
#     1. identify   name · bundle ID · version · size · is it running?
#     2. search     every leftover location, in parallel (leftovers.sh)
#     3. review     what was found, grouped: "safe" and "needs review"
#     4. confirm    y = app + safe items · a = everything · c = choose · N
#     5. remove     quit the app → stop its background services → reset its
#                   privacy permissions → drop its login item → tell Homebrew
#                   and Launch Services → delete the bundle and each leftover
#     6. receipt    a summary card: removed, freed, failed, kept
#
#   Safety:
#     • every delete goes through un_safe_target - an allow-list of the
#       folders an uninstall may touch; anything else is refused
#     • the app that is running this session (your terminal or editor) is
#       never uninstalled
#     • nothing is removed without a yes; without a terminal that yes is
#       UNINSTALL_ASSUME_YES=1, and it covers the "safe" items only
#     • Keychain entries are left alone (they may be shared, and are secrets)
#
#   Env: UNINSTALL_ASSUME_YES=1  uninstall without asking (non-interactive)
#        UNINSTALL_NO_SUDO=1     never ask for admin rights; root-owned items
#                                are reported as not removed
#        UNINSTALL_LSREGISTER    path of lsregister (tests point it at a stub)
#
#   Requires (sourced earlier): colors.sh, core.sh, logging.sh, helpers.sh,
#                               ui.sh, uninstall/apps.sh, uninstall/leftovers.sh
#   Public entry: uninstall_app
# =============================================================================

declare -r _UN_LSREGISTER_DEFAULT='/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'

_UN_SUDO=unknown        # yes | no | unknown - asked at most once per session
UN_RM_NOTE=''           # how the last _un_rm went ("with admin rights", a reason)

# ── tallies of the uninstall in progress ─────────────────────────────────────
declare -i UN_REMOVED=0 UN_FAILED=0 UN_FREED_KB=0
UN_FAILED_PATHS=()
declare -i UN_PERMS_RESET=0         # bundle IDs whose privacy permissions were reset

# ── live-progress context shared with _un_rm ─────────────────────────────────
declare -i _UN_FRAME=0 _UN_CUR=0 _UN_TOT=0

# =============================================================================
# § _un_tilde PATH
#
#   Globals:
#     writes REPLY   PATH with the home folder shortened to "~"
# =============================================================================
_un_tilde() {
    if [[ $1 == "$HOME"/* ]]; then REPLY="~${1#"$HOME"}"; else REPLY=$1; fi
}

# =============================================================================
# § un_safe_target PATH
#
#   The allow-list every deletion must pass. An uninstall may only remove:
#
#     • an app bundle (*.app) in an app folder, or anywhere below the visible
#       folders of the home folder (~/Downloads/Foo.app)
#     • an entry INSIDE a ~/Library category        (~/Library/Caches/com.foo)
#     • an entry inside one of the /Library folders apps install into
#     • an entry inside ~/.config, ~/.local/share or ~/.cache
#     • a single hidden folder directly in the home folder     (~/.fooapp)
#     • an install receipt, a per-user cache / temp entry, /Users/Shared/…
#
#   It refuses everything else - in particular the home folder, ~/Library and
#   its categories themselves, iCloud Drive, Keychains, Mail, Messages and
#   Photos data, ~/Documents and friends, /System, /usr, and any path that is
#   relative or contains "..", "//" or a line break.
#
#   Arguments:
#     PATH  the path about to be deleted
#   Returns:
#     0 when deleting PATH is allowed, 1 when it must be refused
# =============================================================================
un_safe_target() {
    local p=${1%/} root rel
    [[ $p == /* ]] || return 1
    case $p in *//*|*/../*|*/..|*/./*|*/.|*$'\n'*) return 1 ;; esac

    if [[ $p == *.app ]]; then
        _app_roots
        for root in "${APP_ROOTS[@]}"; do
            [[ -n $root && $p == "${root%/}"/?* ]] && return 0
        done
    fi

    # ── inside the home folder: only the places apps keep their own data ─────
    case $p in
        "$HOME/Library/Mobile Documents"*|"$HOME"/Library/CloudStorage*) return 1 ;;   # iCloud / cloud drives
        "$HOME"/Library/Keychains*|"$HOME"/Library/Mail*)               return 1 ;;
        "$HOME"/Library/Messages*|"$HOME"/Library/Photos*)              return 1 ;;
        "$HOME"/Library/?*/?*)                                          return 0 ;;
        "$HOME"/Library|"$HOME"/Library/*)                              return 1 ;;
        "$HOME"/.config/?*|"$HOME"/.local/share/?*|"$HOME"/.cache/?*)   return 0 ;;
        "$HOME"/.Trash*|"$HOME"/.ssh*|"$HOME"/.gnupg*)                  return 1 ;;
        "$HOME"/.config|"$HOME"/.local|"$HOME"/.local/*|"$HOME"/.cache) return 1 ;;
        "$HOME"/.?*)        rel=${p#"$HOME"/}; [[ $rel != */* ]];       return $? ;;
        "$HOME"/?*/?*)                                                  return 0 ;;
        "$HOME"/?*.app)                                                 return 0 ;;
        "$HOME"|"$HOME"/*)                                              return 1 ;;   # anything else at home
    esac

    # ── outside it: only the system folders apps install into ────────────────
    case $p in
        "/Library/Application Support"/?*|/Library/Caches/?*)           return 0 ;;
        /Library/Preferences/?*|/Library/Logs/?*)                       return 0 ;;
        /Library/LaunchAgents/?*|/Library/LaunchDaemons/?*)             return 0 ;;
        /Library/PrivilegedHelperTools/?*)                              return 0 ;;
        /private/var/db/receipts/?*)                                    return 0 ;;
        /private/var/folders/?*/?*/?*/?*|/var/folders/?*/?*/?*/?*)      return 0 ;;   # per-user cache / temp
        /Users/Shared/?*)                                               return 0 ;;
    esac
    return 1
}

# =============================================================================
# § un_hosts_session
#
#   Returns:
#     0 when the app being uninstalled is running this very session - the
#     terminal, or the editor whose built-in terminal started the script.
#     Quitting it would kill the uninstall half-way.
# =============================================================================
un_hosts_session() {
    local mine=$'\n' pid
    while IFS= read -r pid; do mine+="$pid"$'\n'; done <<< "$(proc_ancestor_pids)"
    while IFS= read -r pid; do
        [[ -n $pid && $mine == *$'\n'"$pid"$'\n'* ]] && return 0
    done <<< "$(proc_pids_under "$UN_BUNDLE")"
    return 1
}

# =============================================================================
# § _un_sudo_ok
#
#   Admin rights, asked for at most once: an earlier yes is reused while it is
#   still valid, an earlier no is remembered.
#
#   Returns:
#     0 when `sudo` can be used right now
# =============================================================================
_un_sudo_ok() {
    [[ ${UNINSTALL_NO_SUDO:-0} == 1 ]] && return 1
    sudo -n true 2>/dev/null && { _UN_SUDO=yes; return 0; }
    [[ $_UN_SUDO == no ]] && return 1
    [[ -t 0 ]] || { _UN_SUDO=no; return 1; }
    ui_status_clear; ui_cursor_show
    info "some items belong to the system (root) - your Mac password is needed to remove them"
    if sudo -v; then _UN_SUDO=yes; else _UN_SUDO=no; fi
    (( _UN_CUR > 0 )) && ui_cursor_hide      # back to the progress display
    [[ $_UN_SUDO == yes ]]
}

# True when PATH cannot be removed as the current user.
_un_needs_admin() {
    [[ -e $1 || -L $1 ]] || return 1
    [[ ! -w ${1%/*} || ! -O $1 ]]
}

# =============================================================================
# § _un_rm PATH
#
#   Deletes one file or folder and verifies that it is gone. Escalates only as
#   far as needed: a plain delete; then again after clearing the "locked" flag
#   and read-only permissions; then with admin rights.
#
#   Arguments:
#     PATH  what to delete (a symlink is removed, never followed)
#   Globals:
#     reads  _UN_FRAME _UN_CUR _UN_TOT (live progress), DIR_TIMEOUT
#     writes UN_RM_NOTE  '' · "already gone" · "with admin rights" · or why
#                        it could not be removed
#   Returns:
#     0 when PATH no longer exists, 1 when it is still there
# =============================================================================
_un_rm() {
    local p=$1 shown
    local -i pid
    UN_RM_NOTE=''
    if ! un_safe_target "$p"; then
        UN_RM_NOTE='refused - outside the folders an uninstall may touch'
        return 1
    fi
    [[ -e $p || -L $p ]] || { UN_RM_NOTE='already gone'; return 0; }

    # The first attempt runs in the background so the progress line keeps
    # moving while a large bundle is being deleted.
    _un_tilde "$p"; shown=$REPLY
    run_timeout "$DIR_TIMEOUT" rm -rf "$p" 2>/dev/null &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        ui_status "$_UN_FRAME" "$_UN_CUR" "$_UN_TOT" "removing $shown"
        (( _UN_FRAME++ )); sleep 0.1
    done
    wait "$pid" 2>/dev/null

    if [[ -e $p || -L $p ]]; then          # locked or read-only content
        chflags -R nouchg "$p" 2>/dev/null
        chmod -R u+w "$p" 2>/dev/null
        run_timeout "$DIR_TIMEOUT" rm -rf "$p" 2>/dev/null
    fi
    if [[ -e $p || -L $p ]] && _un_sudo_ok; then
        run_timeout "$DIR_TIMEOUT" sudo rm -rf "$p" 2>/dev/null
        UN_RM_NOTE='with admin rights'
    fi
    if [[ -e $p || -L $p ]]; then
        if [[ $p == "$HOME"/Library/Containers/* || $p == "$HOME/Library/Group Containers"/* ]]; then
            UN_RM_NOTE='macOS protects app containers - give your terminal Full Disk Access'
        elif _un_needs_admin "$p"; then
            UN_RM_NOTE='needs admin rights'
        else
            UN_RM_NOTE='in use or protected'
        fi
        return 1
    fi
    return 0
}

# =============================================================================
# § _un_wait_pids SECONDS PID...
#
#   Returns:
#     0 once none of the PIDs is alive, 1 if any still is after SECONDS
# =============================================================================
_un_wait_pids() {
    local -i ticks=$(( $1 * 5 )) alive
    local pid; shift
    while :; do
        alive=0
        for pid in "$@"; do kill -0 "$pid" 2>/dev/null && { alive=1; break; }; done
        (( alive )) || return 0
        (( ticks-- > 0 )) || return 1
        sleep 0.2
    done
}

# =============================================================================
# § _un_quit_app
#
#   Makes sure the app is not running: asks it to quit (so it can save), then
#   SIGTERM, then SIGKILL - checking after each that its processes are gone.
#
#   Returns:
#     0 when no process of the app is left, 1 when one survived
# =============================================================================
_un_quit_app() {
    local -a pids=()
    local pid
    while IFS= read -r pid; do [[ -n $pid ]] && pids+=("$pid"); done <<< "$(proc_pids_under "$UN_BUNDLE")"
    if (( ${#pids[@]} == 0 )); then
        ok "not running - nothing to quit"
        return 0
    fi

    kv quit "asking ${UN_NAME} to quit (${#pids[@]} process(es))"
    if [[ -n $UN_BID ]]; then
        run_timeout 8 osascript -e 'on run argv' -e 'tell application id (item 1 of argv) to quit' \
            -e 'end run' "$UN_BID" &>/dev/null
    fi
    if _un_wait_pids 8 "${pids[@]}"; then ok "quit ${UN_NAME}"; return 0; fi

    kill -TERM "${pids[@]}" 2>/dev/null
    if _un_wait_pids 4 "${pids[@]}"; then warn "${UN_NAME} did not quit on its own - stopped it (SIGTERM)"; return 0; fi

    kill -KILL "${pids[@]}" 2>/dev/null
    if _un_wait_pids 3 "${pids[@]}"; then warn "${UN_NAME} did not respond - force-stopped it (SIGKILL)"; return 0; fi

    fail "could not stop ${UN_NAME} - some files may stay in use"
    return 1
}

# =============================================================================
# § _un_embedded_ids
#
#   Helper apps, extensions and XPC services inside the bundle hold privacy
#   permissions under their own IDs. Must run before the bundle is deleted.
#
#   Outputs:
#     Bundle IDs inside the app that extend the app's own ID, one per line.
# =============================================================================
_un_embedded_ids() {
    local inner id
    [[ -n $UN_BID ]] || return 0
    find "$UN_BUNDLE/Contents" -maxdepth 6 \( -name '*.app' -o -name '*.appex' -o -name '*.xpc' \) -prune 2>/dev/null \
        | head -40 | while IFS= read -r inner; do
            id=$(plist_get "$inner/Contents/Info.plist" CFBundleIdentifier) || continue
            [[ $id =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && $id == "$UN_BID".* ]] && printf '%s\n' "$id"
        done | LC_ALL=C sort -u
}

# =============================================================================
# § _un_reset_permissions ID...
#
#   Removes every privacy permission (Camera, Microphone, Files, Accessibility,
#   Full Disk Access, Automation …) granted to the given bundle IDs, so nothing
#   stays listed under System Settings ▸ Privacy & Security.
#
#   Globals:
#     writes UN_PERMS_RESET  how many IDs were reset
# =============================================================================
_un_reset_permissions() {
    local id out
    local -i done_n=0
    UN_PERMS_RESET=0
    if (( $# == 0 )); then
        warn "no bundle ID - privacy permissions cannot be reset"
        return 0
    fi
    if ! command -v tccutil &>/dev/null; then
        warn "tccutil not found - privacy permissions left as they are"
        return 0
    fi
    for id in "$@"; do
        if out=$(run_timeout 15 tccutil reset All "$id" 2>&1); then
            (( done_n++ ))
            kv tccutil "reset All $id"
        else
            kv tccutil "reset All $id - ${out:-failed}"
        fi
    done
    UN_PERMS_RESET=$done_n
    (( done_n > 0 )) && ok "privacy permissions reset for ${done_n} ID(s)" \
                     || warn "privacy permissions could not be reset"
    return 0
}

# =============================================================================
# § _un_stop_services PLIST...
#
#   Unloads the app's launchd jobs so nothing restarts it while its files are
#   being deleted. User agents are unloaded from the GUI session, system
#   daemons with admin rights. "Not loaded" is not an error.
# =============================================================================
_un_stop_services() {
    local plist
    for plist in "$@"; do
        _un_tilde "$plist"
        if [[ $plist == /Library/LaunchDaemons/* ]]; then
            if _un_sudo_ok; then
                sudo launchctl bootout system "$plist" &>/dev/null
                kv launchd "stopped system service $REPLY"
            else
                kv launchd "skipped $REPLY (needs admin rights)"
            fi
        else
            launchctl bootout "gui/$UID" "$plist" &>/dev/null
            kv launchd "stopped background agent $REPLY"
        fi
    done
    ok "background services stopped (${#})"
}

# =============================================================================
# § _un_remove_login_item
#
#   Deletes the "open at login" entry that points at the app, if there is one.
#   Needs permission to control System Events; when macOS says no, the step
#   is skipped (modern macOS drops the entry by itself once the app is gone).
# =============================================================================
_un_remove_login_item() {
    local out
    command -v osascript &>/dev/null || return 0
    out=$(run_timeout 10 osascript \
        -e 'on run argv' \
        -e '  tell application "System Events"' \
        -e '    set n to count of (every login item whose path is (item 1 of argv))' \
        -e '    if n > 0 then delete (every login item whose path is (item 1 of argv))' \
        -e '    return n' \
        -e '  end tell' \
        -e 'end run' "$UN_BUNDLE" 2>&1) || { kv login "skipped - could not ask System Events"; return 0; }
    if [[ $out =~ ^[0-9]+$ ]] && (( out > 0 )); then
        ok "removed ${out} login item(s)"
    else
        kv login "no login item registered"
    fi
}

# =============================================================================
# § _un_cask_token
#
#   Outputs:
#     The Homebrew cask that installed the app, when there is one.
# =============================================================================
_un_cask_token() {
    local room entry
    for room in "${HOMEBREW_PREFIX:-/opt/homebrew}/Caskroom" /usr/local/Caskroom; do
        [[ -d $room ]] || continue
        for entry in "$room"/*/*/"${UN_BUNDLE##*/}"; do
            [[ -e $entry || -L $entry ]] || continue
            entry=${entry#"$room"/}
            printf '%s' "${entry%%/*}"
            return 0
        done
    done
    return 1
}

# =============================================================================
# § _un_forget_cask TOKEN
#
#   Lets Homebrew run the cask's own uninstall steps and forget the cask, so
#   `brew list` stays true. The files it leaves are handled by the next steps.
#
#   Homebrew may call sudo. It gets no terminal to ask on (stdin is /dev/null
#   and the askpass helper always fails), so it can only use admin rights that
#   were already granted in this run - it never hangs on a password prompt.
# =============================================================================
_un_forget_cask() {
    local token=$1 line
    command -v brew &>/dev/null || return 0
    kv brew "uninstall --cask --force $token"
    if HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1 SUDO_ASKPASS=/usr/bin/false \
        run_timeout "$(( CMD_TIMEOUT * 3 ))" brew uninstall --cask --force "$token" \
        < /dev/null > "$MC_RUN_DIR/brew.out" 2>&1; then
        ok "Homebrew cask \"$token\" uninstalled"
    else
        warn "Homebrew could not uninstall cask \"$token\" - removing the files directly"
    fi
    while IFS= read -r line; do log_only "      │ $line"; done < "$MC_RUN_DIR/brew.out"
    rm -f "$MC_RUN_DIR/brew.out"
}

# =============================================================================
# § _un_plan_show BUNDLE_KB
#
#   Prints what the search found, grouped: the "safe" items that are removed
#   by default, then the "review" items that are only removed on request.
#
#   Globals:
#     reads UN_HIT_* arrays
#     writes REPLY  "SAFE_COUNT SAFE_KB REVIEW_COUNT REVIEW_KB"
# =============================================================================
_un_plan_show() {
    local -i i n=${#UN_HIT_PATH[@]} safe_n=0 safe_kb=0 rev_n=0 rev_kb=0
    local shown

    for (( i=0; i<n; i++ )); do
        if [[ ${UN_HIT_CONF[i]} == safe ]]; then (( safe_n++, safe_kb += UN_HIT_KB[i] ))
        else (( rev_n++, rev_kb += UN_HIT_KB[i] )); fi
    done

    if (( n == 0 )); then
        info "no leftovers found - the app kept everything inside its bundle"
        REPLY="0 0 0 0"; return 0
    fi

    if (( safe_n > 0 )); then
        _log "    ${BGRN}●${NC} ${BOLD}Belongs to ${UN_NAME}${NC} ${DIM}- ${safe_n} item(s), $(human_size "$safe_kb")${NC}"
        for (( i=0; i<n; i++ )); do
            [[ ${UN_HIT_CONF[i]} == safe ]] || continue
            _un_tilde "${UN_HIT_PATH[i]}"; shown=$REPLY
            _log "$(printf '      %s%-24s%s %9s  %s' "$DIM" "${UN_HIT_CAT[i]}" "$NC" "$(human_size "${UN_HIT_KB[i]}")" "$shown")"
        done
    fi
    if (( rev_n > 0 )); then
        _log "    ${ORG}●${NC} ${BOLD}Needs your review${NC} ${DIM}- ${rev_n} item(s), $(human_size "$rev_kb") · kept unless you choose them${NC}"
        for (( i=0; i<n; i++ )); do
            [[ ${UN_HIT_CONF[i]} == review ]] || continue
            _un_tilde "${UN_HIT_PATH[i]}"; shown=$REPLY
            _log "$(printf '      %s%-24s%s %9s  %s' "$DIM" "${UN_HIT_CAT[i]}" "$NC" "$(human_size "${UN_HIT_KB[i]}")" "$shown")"
        done
    fi
    REPLY="$safe_n $safe_kb $rev_n $rev_kb"
}

# =============================================================================
# § _un_choose SAFE_COUNT REVIEW_COUNT TOTAL_KB
#
#   Asks what to remove.
#
#   Globals:
#     reads  UN_HIT_* arrays, UNINSTALL_ASSUME_YES
#     writes UN_SELECTED  indices into UN_HIT_* of the leftovers to remove
#   Returns:
#     0 to go ahead (the app itself is always removed), 1 when cancelled
# =============================================================================
_un_choose() {
    local -i safe_n=$1 rev_n=$2 total_kb=$3 i n=${#UN_HIT_PATH[@]}
    local answer rows id
    UN_SELECTED=()
    for (( i=0; i<n; i++ )); do [[ ${UN_HIT_CONF[i]} == safe ]] && UN_SELECTED+=("$i"); done

    # ── no terminal: only an explicit opt-in may uninstall ───────────────────
    if [[ ! -t 0 ]]; then
        if [[ ${UNINSTALL_ASSUME_YES:-0} == 1 ]]; then
            info "non-interactive - UNINSTALL_ASSUME_YES=1, removing the app and the safe items"
            return 0
        fi
        warn "non-interactive and no confirmation possible - skipping (set UNINSTALL_ASSUME_YES=1)"
        return 1
    fi

    printf '\n'
    printf "  ${YLW}Uninstall ${BOLD}%s${NC}${YLW} and remove %d leftover item(s) - %s?${NC}\n" \
        "$UN_NAME" "$safe_n" "$(human_size "$total_kb")"
    printf "    ${BOLD}y${NC} yes, remove them"
    (( rev_n > 0 )) && printf "     ${BOLD}a${NC} also the %d review item(s)" "$rev_n"
    (( n > 0 ))     && printf "     ${BOLD}c${NC} choose item by item"
    printf "     ${BOLD}N${NC} cancel\n"
    printf "  ${YLW}Your choice:${NC} "
    read -r answer || answer=''

    case $answer in
        y|Y) return 0 ;;
        a|A) UN_SELECTED=(); for (( i=0; i<n; i++ )); do UN_SELECTED+=("$i"); done; return 0 ;;
        c|C) (( n > 0 )) || return 0 ;;
        *)   info "Cancelled - nothing changed."; return 1 ;;
    esac

    # ── choose item by item ──────────────────────────────────────────────────
    rows=$(mktemp "${MC_RUN_DIR:-${TMPDIR:-/tmp}}/choose.XXXXXX") || return 1
    for (( i=0; i<n; i++ )); do
        _un_tilde "${UN_HIT_PATH[i]}"
        printf '%s\t%s\t%s\t%s\t%s\n' "$i" "${UN_HIT_CAT[i]}" "$REPLY" "${UN_HIT_KB[i]}" \
            "$([[ ${UN_HIT_CONF[i]} == review ]] && echo review)" >> "$rows"
    done
    ui_picker --hint "untick anything you want to keep" --verb 'remove the ticked items' \
              --unit leftovers --preselect all --sort size \
              "Leftovers of ${UN_NAME}" "$rows"
    rm -f "$rows"
    if (( PICKER_CANCELLED )); then info "Cancelled - nothing changed."; return 1; fi
    UN_SELECTED=()
    for id in ${PICKER_RESULT[@]+"${PICKER_RESULT[@]}"}; do UN_SELECTED+=("$id"); done
    confirm_action "Uninstall ${UN_NAME} and remove the ${#UN_SELECTED[@]} chosen item(s)?" UNINSTALL_ASSUME_YES
}

# =============================================================================
# § _un_delete LABEL KB PATH
#
#   Deletes one item, prints its outcome line, and updates the tallies.
# =============================================================================
_un_delete() {
    local label=$1 path=$3 shown
    local -i kb=$2
    (( _UN_CUR++ ))
    _un_tilde "$path"; shown=$REPLY
    if _un_rm "$path"; then
        ui_status_clear
        (( UN_REMOVED++ )); (( UN_FREED_KB += kb ))
        ok "$(printf 'removed %9s  %s%-20s%s %s' "$(human_size "$kb")" "$DIM" "$label" "$NC" "$shown")${UN_RM_NOTE:+ ${DIM}(${UN_RM_NOTE})${NC}}"
    else
        ui_status_clear
        (( UN_FAILED++ )); UN_FAILED_PATHS+=("$shown - $UN_RM_NOTE")
        fail "$(printf 'not removed        %-20s %s' "$label" "$shown") - ${UN_RM_NOTE}"
    fi
}

# =============================================================================
# § uninstall_app BUNDLE [META_FILE] [BUNDLE_KB]
#
#   Uninstalls one app: identify → search → review → confirm → remove →
#   receipt (see the file header).
#
#   Arguments:
#     BUNDLE     path of the .app bundle
#     META_FILE  "path<TAB>bundle-id" of every installed app (protects the
#                data of sibling apps and second copies); optional
#     BUNDLE_KB  the bundle's size if already measured; measured when omitted
#   Globals:
#     writes TOTAL_FREED_KB / TOTAL_CLEANED / TOTAL_FAILED and the UN_* tallies
#   Returns:
#     0 when the app was removed, 1 when it was skipped, cancelled or its
#     bundle could not be deleted
# =============================================================================
uninstall_app() {
    local bundle=${1%/} meta=${2:-} shown token='' id
    local -i bundle_kb=${3:--1} i t0=$SECONDS safe_n safe_kb rev_n rev_kb
    local -a ids=() services=()

    un_set_identity "$bundle" "$meta"
    section "UNINSTALL · ${UN_NAME}"

    if [[ ! -d $UN_BUNDLE ]]; then
        fail "not found: $UN_BUNDLE"; echo; return 1
    fi
    if ! un_safe_target "$UN_BUNDLE"; then
        fail "refusing to uninstall - not an app in an app folder: $UN_BUNDLE"; echo; return 1
    fi
    if un_hosts_session; then
        warn "${UN_NAME} is running this session (your terminal or editor) - not uninstalled."
        info "run the cleaner from a different terminal app to uninstall it"
        echo; return 1
    fi

    # ── 1. identify ──────────────────────────────────────────────────────────
    step "[App]"
    _un_tilde "$UN_BUNDLE"
    kv bundle  "$REPLY"
    kv id      "${UN_BID:-unknown - leftovers are matched by name only}"
    [[ -n $UN_VERSION ]] && kv version "$UN_VERSION"
    if (( bundle_kb < 0 )); then
        ui_term_size; ui_status 0 0 0 "measuring ${UN_NAME}"
        bundle_kb=$(path_size_kb "$UN_BUNDLE")
        ui_status_clear
    fi
    kv size "$(human_size "$bundle_kb")"
    if [[ -n $(proc_pids_under "$UN_BUNDLE") ]]; then kv running "yes - it will be asked to quit"; else kv running "no"; fi
    if [[ -n $UN_TWIN ]]; then
        _un_tilde "$UN_TWIN"
        warn "another copy of this app is installed at $REPLY - shared data is kept, only this copy is removed"
    fi
    echo

    # ── 2. search ────────────────────────────────────────────────────────────
    if [[ -z $UN_TWIN ]]; then
        step "[Searching for leftovers]"
        un_search
        ok "${UN_SEARCHED} locations searched in $(( SECONDS - t0 ))s · ${#UN_HIT_PATH[@]} item(s) found"
        if (( ${#UN_BLOCKED[@]} > 0 )); then
            warn "${#UN_BLOCKED[@]} folder(s) hidden by macOS privacy were not searched"
            fda_hint
        fi
        echo
    else
        UN_HIT_PATH=(); UN_HIT_CAT=(); UN_HIT_KB=(); UN_HIT_CONF=()
    fi

    # ── 3. review + 4. confirm ───────────────────────────────────────────────
    step "[Found]"
    _un_plan_show
    read -r safe_n safe_kb rev_n rev_kb <<< "$REPLY"
    _un_choose "$safe_n" "$rev_n" "$(( bundle_kb + safe_kb ))" || { echo; return 1; }
    echo

    # ── 5. remove ────────────────────────────────────────────────────────────
    UN_REMOVED=0 UN_FAILED=0 UN_FREED_KB=0 UN_FAILED_PATHS=()
    _UN_FRAME=0 _UN_CUR=0 _UN_TOT=$(( 1 + ${#UN_SELECTED[@]} ))
    t0=$SECONDS
    ui_term_size

    # Ask for admin rights now, before the progress starts, when it is certain
    # they are needed - not in the middle of the list.
    if _un_needs_admin "$UN_BUNDLE"; then _un_sudo_ok || true; fi

    step "[Preparing]"
    [[ -n $UN_BID ]] && ids+=("$UN_BID")
    while IFS= read -r id; do [[ -n $id ]] && ids+=("$id"); done <<< "$(_un_embedded_ids)"
    _un_quit_app

    for i in ${UN_SELECTED[@]+"${UN_SELECTED[@]}"}; do
        [[ ${UN_HIT_CAT[i]} == "Background service" ]] && services+=("${UN_HIT_PATH[i]}")
    done
    (( ${#services[@]} > 0 )) && _un_stop_services "${services[@]}"

    _un_reset_permissions ${ids[@]+"${ids[@]}"}
    _un_remove_login_item
    token=$(_un_cask_token) && _un_forget_cask "$token"
    if [[ -x ${UNINSTALL_LSREGISTER:-$_UN_LSREGISTER_DEFAULT} ]]; then
        "${UNINSTALL_LSREGISTER:-$_UN_LSREGISTER_DEFAULT}" -u "$UN_BUNDLE" &>/dev/null
        kv launch "unregistered from Launch Services (\"Open With\" menus)"
    fi
    echo

    step "[Removing]"
    ui_cursor_hide
    _un_delete "App" "$bundle_kb" "$UN_BUNDLE"
    local -i bundle_gone=1; [[ -e $UN_BUNDLE ]] && bundle_gone=0
    for i in ${UN_SELECTED[@]+"${UN_SELECTED[@]}"}; do
        _un_delete "${UN_HIT_CAT[i]}" "${UN_HIT_KB[i]}" "${UN_HIT_PATH[i]}"
    done
    ui_status_clear; ui_cursor_show

    # ── 6. receipt ───────────────────────────────────────────────────────────
    (( TOTAL_FREED_KB += UN_FREED_KB ))
    ledger_add "Uninstalled ${UN_NAME}" "$UN_FREED_KB"
    local -a card=()
    if (( bundle_gone )); then
        (( TOTAL_CLEANED++ ))
        card+=("ok:${UN_NAME} uninstalled")
    else
        (( TOTAL_FAILED++ ))
        card+=("fail:${UN_NAME} could not be removed")
    fi
    card+=("ok:${UN_REMOVED} of ${_UN_TOT} item(s) removed · $(human_size "$UN_FREED_KB") freed · $(( SECONDS - t0 ))s")
    if (( UN_PERMS_RESET > 0 )); then
        card+=("ok:privacy permissions reset for ${UN_PERMS_RESET} bundle ID(s)")
    else
        card+=("warn:privacy permissions were not reset (see above)")
    fi
    if (( UN_FAILED > 0 )); then
        card+=("fail:${UN_FAILED} item(s) could not be removed:")
        for shown in "${UN_FAILED_PATHS[@]}"; do card+=("dim:  ${shown:0:54}"); done
    fi
    local -i kept=$(( ${#UN_HIT_PATH[@]} - ${#UN_SELECTED[@]} ))
    (( kept > 0 )) && card+=("warn:${kept} item(s) kept - listed above, remove by hand if unwanted")
    card+=("dim:Keychain entries are never touched")
    summary_card "Uninstall summary" "${card[@]}"
    info "Full log: ${LOG_FILE}"
    echo

    (( bundle_gone ))
}
