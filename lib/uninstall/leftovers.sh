#!/usr/bin/env bash
# =============================================================================
# § lib/uninstall/leftovers.sh  ·  Find everything an app left on the Mac
#
#   Single responsibility: given one app, find the files and folders that
#   belong to it outside its bundle - settings, caches, containers, saved
#   state, logs, crash reports, background services, install receipts.
#   Nothing here removes anything.
#
#     un_set_identity      who the app is, and which other apps share its IDs
#     un_match_bid         does this name belong to the app's bundle ID?
#     un_match_group       …the same, for group-container naming
#     un_match_name        …or carry the app's name?
#     un_locations         every place that is searched
#     un_search            run the search (parallel, with live progress)
#
#   The matching is deliberately strict, because a wrong match deletes another
#   app's data:
#     • by bundle ID  - the name is the ID itself or starts with "ID."
#                       (com.foo.app, com.foo.app.plist, com.foo.app.helper)
#     • by app name   - the name is exactly the app's name (optionally followed
#                       by a version number), never a substring: uninstalling
#                       "Code" must not match "Xcode"
#     • never a name that another installed app also answers to (Chrome must
#       not take Chrome Canary's data with it), and never the shared data of
#       a second copy of the same app
#     • generic names (Electron, Helper, Google …) are not matched by name
#
#   Each hit is either "safe" (matched by bundle ID or exact name inside a
#   Library folder - removed by default) or "review" (a dotfolder in the home
#   folder, a Spotlight hit elsewhere - only removed when the user says so).
#
#   Requires (sourced earlier): core.sh, logging.sh, helpers.sh, ui.sh,
#                               uninstall/apps.sh
# =============================================================================

# ── identity of the app being uninstalled (set by un_set_identity) ───────────
UN_BUNDLE=''            # bundle path
UN_NAME=''              # name in Finder
UN_BID=''               # bundle identifier ('' = unknown: name matching only)
UN_EXEC=''              # main executable name
UN_VERSION=''
UN_NAMES=()             # the names leftovers may be filed under
UN_SIBLINGS=()          # bundle IDs of OTHER installed apps that extend UN_BID
UN_TWIN=''              # path of another installed copy with the same ID

# ── search results (parallel arrays, set by un_search) ───────────────────────
UN_HIT_PATH=(); UN_HIT_CAT=(); UN_HIT_KB=(); UN_HIT_CONF=()
UN_SEARCHED=0           # locations searched
UN_BLOCKED=()           # locations macOS privacy would not let us list

# Names too generic to search for: a folder called this is shared by many apps.
declare -r UN_GENERIC_NAMES=" electron helper app application launcher update updater \
installer uninstaller setup agent daemon service java python ruby node wine qt \
test demo example untitled main data cache caches logs temp tmp google microsoft \
apple adobe mozilla jetbrains library preferences support "

# =============================================================================
# § un_set_identity BUNDLE [META_FILE]
#
#   Arguments:
#     BUNDLE     path of the app to uninstall
#     META_FILE  "path<TAB>bundle-id" for every installed app (written by the
#                app scan). Used to protect other apps; optional.
#   Globals:
#     writes UN_BUNDLE UN_NAME UN_BID UN_EXEC UN_VERSION UN_NAMES
#            UN_SIBLINGS UN_TWIN
# =============================================================================
# shellcheck disable=SC2034  # UN_* are the result, read by uninstall/remove.sh
un_set_identity() {
    local meta=${2:-} path bid nm cand
    app_identity "$1"
    UN_BUNDLE=$APP_PATH UN_NAME=$APP_NAME UN_BID=$APP_BID
    UN_EXEC=$APP_EXEC UN_VERSION=$APP_VERSION
    UN_NAMES=() UN_SIBLINGS=() UN_TWIN=''

    # Names to look for: the Finder name, the bundle name, and each without
    # spaces - minus anything too short or too generic to be safe.
    for nm in "$APP_NAME" "$APP_BUNDLE_NAME"; do
        [[ -n $nm ]] || continue
        for cand in "$nm" "${nm// /}"; do
            (( ${#cand} >= 3 )) || continue
            _un_is_generic "$cand" && continue
            _un_has_name "$cand" && continue
            UN_NAMES+=("$cand")
        done
    done
    _un_is_generic "$UN_EXEC" && UN_EXEC=''

    [[ -n $meta && -f $meta && -n $UN_BID ]] || return 0
    shopt -s nocasematch
    while IFS=$'\t' read -r path bid; do
        [[ $path == "$UN_BUNDLE" || $bid == - || -z $bid ]] && continue
        [[ -d $path ]] || continue
        if   [[ $bid == "$UN_BID" ]];   then UN_TWIN=$path
        elif [[ $bid == "$UN_BID".* ]]; then UN_SIBLINGS+=("$bid")
        fi
    done < "$meta"
    shopt -u nocasematch
    return 0
}

# =============================================================================
# § _un_is_generic NAME
#
#   Returns:
#     0 when NAME is empty or a word many apps share (see UN_GENERIC_NAMES)
# =============================================================================
_un_is_generic() {
    local lc
    [[ -n $1 ]] || return 0
    lc=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
    [[ $UN_GENERIC_NAMES == *" $lc "* ]]
}

# True when NAME is already in UN_NAMES (exact, case-sensitive).
_un_has_name() {
    local n
    for n in ${UN_NAMES[@]+"${UN_NAMES[@]}"}; do [[ $n == "$1" ]] && return 0; done
    return 1
}

# =============================================================================
# § _un_is_sibling ENTRY
#
#   Returns:
#     0 when ENTRY belongs to another installed app whose bundle ID extends
#     ours (com.google.Chrome.canary while uninstalling com.google.Chrome)
#   Note: the caller has nocasematch switched on.
# =============================================================================
_un_is_sibling() {
    local sib
    for sib in ${UN_SIBLINGS[@]+"${UN_SIBLINGS[@]}"}; do
        [[ $1 == "$sib" || $1 == "$sib".* || $1 == *."$sib" || $1 == *."$sib".* ]] && return 0
    done
    return 1
}

# =============================================================================
# § un_match_bid ENTRY
#
#   Arguments:
#     ENTRY  a file or folder name (no path)
#   Returns:
#     0 when ENTRY is the app's bundle ID or starts with "ID." - and does not
#     belong to a sibling app. Case-insensitive, like the macOS file system.
# =============================================================================
un_match_bid() {
    local -i rc=1
    [[ -n $UN_BID ]] || return 1
    shopt -s nocasematch
    if [[ $1 == "$UN_BID" || $1 == "$UN_BID".* ]]; then
        _un_is_sibling "$1" || rc=0
    fi
    shopt -u nocasematch
    return $rc
}

# =============================================================================
# § un_match_group ENTRY
#
#   Group containers and shared scripts put a prefix in front of the ID:
#   "group.com.foo.app", "ABCDE12345.com.foo.app".
#
#   Returns:
#     0 when ENTRY is the ID, starts with "ID.", ends with ".ID" or contains
#     ".ID." - and does not belong to a sibling app
# =============================================================================
un_match_group() {
    local -i rc=1
    [[ -n $UN_BID ]] || return 1
    shopt -s nocasematch
    if [[ $1 == "$UN_BID" || $1 == "$UN_BID".* || $1 == *."$UN_BID" || $1 == *."$UN_BID".* ]]; then
        _un_is_sibling "$1" || rc=0
    fi
    shopt -u nocasematch
    return $rc
}

# =============================================================================
# § un_match_name ENTRY
#
#   Returns:
#     0 when ENTRY is exactly one of the app's names, or that name followed by
#     a version ("WebStorm2024.3", "Foo 2", "foo-1.4"). Never a substring.
# =============================================================================
un_match_name() {
    local nm rest version_re='^[ _-]?[0-9][0-9.]*$'
    local -i rc=1
    shopt -s nocasematch
    for nm in ${UN_NAMES[@]+"${UN_NAMES[@]}"}; do
        [[ ${1:0:${#nm}} == "$nm" ]] || continue
        rest=${1:${#nm}}
        if [[ -z $rest || $rest =~ $version_re ]]; then rc=0; break; fi
    done
    shopt -u nocasematch
    return $rc
}

# =============================================================================
# § un_locations
#
#   Outputs:
#     Every place searched, one per line:  CATEGORY|FOLDER|RULE|CONFIDENCE
#
#       RULE        bid    names matched by un_match_bid
#                   group  names matched by un_match_group
#                   name   names matched by un_match_name
#                   both   bid + name (+ "Vendor/Product" one level down)
#                   crash  crash reports: "<name>-<date>…", "<name>_<id>…"
#                   dot    a dotfolder: ".<name>" in lower case
#                   spot   Spotlight: items elsewhere named after the bundle ID
#       CONFIDENCE  safe | review
# =============================================================================
un_locations() {
    local L="$HOME/Library" ucache utemp
    ucache=$(getconf DARWIN_USER_CACHE_DIR 2>/dev/null); ucache=${ucache%/}
    utemp=$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null);   utemp=${utemp%/}

    cat <<LOCATIONS
App data|$L/Application Support|both|safe
Caches|$L/Caches|both|safe
Preferences|$L/Preferences|bid|safe
Preferences|$L/Preferences/ByHost|bid|safe
Saved window state|$L/Saved Application State|bid|safe
Sandbox container|$L/Containers|bid|safe
Group container|$L/Group Containers|group|safe
App scripts|$L/Application Scripts|group|safe
Web data|$L/HTTPStorages|bid|safe
Web data|$L/WebKit|bid|safe
Cookies|$L/Cookies|bid|safe
Logs|$L/Logs|both|safe
Crash reports|$L/Logs/DiagnosticReports|crash|safe
Crash reports|$L/Application Support/CrashReporter|crash|safe
Background service|$L/LaunchAgents|bid|safe
Background service|/Library/LaunchAgents|bid|safe
Background service|/Library/LaunchDaemons|bid|safe
Privileged helper|/Library/PrivilegedHelperTools|bid|safe
App data (all users)|/Library/Application Support|both|safe
Preferences (all users)|/Library/Preferences|bid|safe
Caches (all users)|/Library/Caches|both|safe
Logs (all users)|/Library/Logs|both|safe
Install receipt|/private/var/db/receipts|bid|safe
Temporary cache|$ucache|bid|safe
Temporary files|$utemp|bid|safe
Settings folder|$HOME/.config|name|review
Data folder|$HOME/.local/share|name|review
Cache folder|$HOME/.cache|name|review
Hidden folder|$HOME|dot|review
Elsewhere|spotlight|spot|review
LOCATIONS
}

# =============================================================================
# § _un_probe FOLDER RULE
#
#   Lists what RULE matches in FOLDER. Runs inside a background job, so the
#   shell options it switches on never reach the rest of the program.
#
#   Outputs:
#     Matching paths, one per line.
# =============================================================================
_un_probe() {
    local dir=$1 rule=$2 p nm rest lc vendor product stamp_re='^[0-9A-Fa-f]{4}'
    shopt -s nocaseglob nullglob

    if [[ $rule == bid || $rule == both ]] && [[ -n $UN_BID ]]; then
        for p in "$dir"/"$UN_BID"*; do un_match_bid "${p##*/}" && printf '%s\n' "$p"; done
    fi
    if [[ $rule == group && -n $UN_BID ]]; then
        for p in "$dir"/*"$UN_BID"*; do un_match_group "${p##*/}" && printf '%s\n' "$p"; done
    fi
    if [[ $rule == name || $rule == both ]]; then
        for nm in ${UN_NAMES[@]+"${UN_NAMES[@]}"}; do
            for p in "$dir"/"$nm"*; do un_match_name "${p##*/}" && printf '%s\n' "$p"; done
            # "Google Chrome" keeps its data in Google/Chrome
            if [[ $rule == both && $nm == *' '* ]]; then
                vendor=${nm%% *}; product=${nm#* }
                _un_is_generic "$product" && continue
                p="$dir/$vendor/$product"; [[ -e $p ]] && printf '%s\n' "$p"
            fi
        done
    fi
    if [[ $rule == crash ]]; then
        for nm in ${UN_EXEC:+"$UN_EXEC"} ${UN_NAMES[@]+"${UN_NAMES[@]}"}; do
            for p in "$dir"/"$nm"[-_]*; do
                rest=${p##*/}; rest=${rest:${#nm}+1}
                [[ $rest =~ $stamp_re ]] && printf '%s\n' "$p"
            done
        done
    fi
    if [[ $rule == dot ]]; then
        for nm in ${UN_NAMES[@]+"${UN_NAMES[@]}"}; do
            [[ $nm == *' '* ]] && continue
            lc=$(printf '%s' "$nm" | tr '[:upper:]' '[:lower:]')
            p="$dir/.$lc"; [[ -e $p ]] && printf '%s\n' "$p"
        done
    fi
    if [[ $rule == spot && -n $UN_BID && ${UNINSTALL_SPOTLIGHT:-1} == 1 ]] && command -v mdfind &>/dev/null; then
        # Only outside ~/Library (searched above) and outside the bundle itself.
        run_timeout 15 mdfind -name "$UN_BID" 2>/dev/null | while IFS= read -r p; do
            case $p in
                "$UN_BUNDLE"|"$UN_BUNDLE"/*|"$HOME"/Library/*) continue ;;
                "$HOME"/*|/Users/Shared/*) ;;
                *) continue ;;
            esac
            un_match_group "${p##*/}" && printf '%s\n' "$p"
        done
    fi
    return 0
}

# =============================================================================
# § _un_probe_job INDEX OUT_DIR CATEGORY FOLDER RULE CONFIDENCE
#
#   One background search job. Writes its hits, measured, to OUT_DIR/hits.N as
#   "CONFIDENCE<TAB>CATEGORY<TAB>KB<TAB>PATH", a "blocked.N" marker when macOS
#   privacy hides the folder, and "done.N" last - even when nothing matched.
# =============================================================================
_un_probe_job() {
    local -i idx=$1 kb
    local out=$2 cat=$3 dir=$4 rule=$5 conf=$6 p
    if [[ $rule != spot ]]; then
        if [[ ! -d $dir ]]; then : > "$out/done.$idx"; return 0; fi
        if is_tcc_blocked "$dir"; then
            printf '%s\n' "$dir" > "$out/blocked.$idx"; : > "$out/done.$idx"; return 0
        fi
    fi
    _un_probe "$dir" "$rule" | LC_ALL=C sort -u | while IFS= read -r p; do
        [[ -e $p || -L $p ]] || continue
        kb=$(path_size_kb "$p")
        printf '%s\t%s\t%d\t%s\n' "$conf" "$cat" "$kb" "$p"
    done > "$out/hits.$idx"
    : > "$out/done.$idx"
}

# =============================================================================
# § un_search
#
#   Searches every location (un_locations) for the app set by un_set_identity.
#   All searches run at the same time as background jobs; a live line shows
#   how many have finished. Each location and what it held goes to the log.
#
#   Globals:
#     reads  UN_* identity, SCAN_TIMEOUT, MC_RUN_DIR
#     writes UN_HIT_PATH / UN_HIT_CAT / UN_HIT_KB / UN_HIT_CONF - the hits,
#            "safe" ones first, largest first; a hit inside another hit is
#            dropped (removing the outer one covers it)
#     writes UN_SEARCHED, UN_BLOCKED
#   Returns:
#     0 always (an empty result is not an error)
# =============================================================================
un_search() {
    local out cat dir rule conf line p last=''
    local -a cats=() dirs=() pids=()
    local -i n=0 i fin=0 frame=0 t0=$SECONDS kb cnt timed_out=0

    UN_HIT_PATH=(); UN_HIT_CAT=(); UN_HIT_KB=(); UN_HIT_CONF=()
    UN_SEARCHED=0; UN_BLOCKED=()

    out=$(mktemp -d "${MC_RUN_DIR:-${TMPDIR:-/tmp}}/leftovers.XXXXXX") || { warn "could not create a work folder"; return 0; }

    # ── launch one job per location ──────────────────────────────────────────
    while IFS='|' read -r cat dir rule conf; do
        [[ -n $dir ]] || continue
        cats+=("$cat"); dirs+=("$dir")
        ( _un_probe_job "$n" "$out" "$cat" "$dir" "$rule" "$conf" ) < /dev/null > /dev/null 2>&1 &
        pids+=($!)
        (( n++ ))
    done <<< "$(un_locations)"
    # shellcheck disable=SC2034  # result global, read by uninstall/remove.sh
    UN_SEARCHED=$n

    # ── wait, showing progress ───────────────────────────────────────────────
    ui_term_size; ui_cursor_hide
    while (( fin < n )); do
        fin=0
        for (( i=0; i<n; i++ )); do
            if [[ -e $out/done.$i ]]; then (( fin++ )); else last=${dirs[i]}; fi
        done
        (( fin == n )) && break
        [[ $last == "$HOME"* ]] && last="~${last#"$HOME"}"
        ui_status "$frame" "$fin" "$n" "searching $last"
        (( frame++ ))
        if (( SECONDS - t0 > SCAN_TIMEOUT )); then timed_out=1; break; fi
        sleep 0.1
    done
    ui_status_clear; ui_cursor_show
    if (( timed_out )); then
        for p in "${pids[@]}"; do kill -0 "$p" 2>/dev/null && kill_tree "$p"; done
        warn "search stopped after ${SCAN_TIMEOUT}s - $(( n - fin )) location(s) not finished"
    fi
    wait "${pids[@]}" 2>/dev/null

    # ── log every location; collect privacy blocks ───────────────────────────
    for (( i=0; i<n; i++ )); do
        cnt=0; [[ -s $out/hits.$i ]] && cnt=$(( $(wc -l < "$out/hits.$i") + 0 ))
        last=${dirs[i]}; [[ $last == "$HOME"* ]] && last="~${last#"$HOME"}"
        if [[ -e $out/blocked.$i ]]; then
            UN_BLOCKED+=("${dirs[i]}")
            log_only "    searched ${last}  (${cats[i]})  → blocked by macOS privacy"
        else
            log_only "    searched ${last}  (${cats[i]})  → ${cnt} match(es)"
        fi
    done

    # ── merge: safe first, then largest first; drop hits nested in a hit ─────
    local kept=$'\n'
    while IFS=$'\t' read -r conf cat kb p; do
        [[ -n $p ]] || continue
        [[ $p == "$UN_BUNDLE" || $p == "$UN_BUNDLE"/* ]] && continue
        line=$p
        while [[ $line == */* && -n ${line%/*} ]]; do
            line=${line%/*}
            [[ $kept == *$'\n'"$line"$'\n'* ]] && continue 2
        done
        [[ $kept == *$'\n'"$p"$'\n'* ]] && continue
        kept+="$p"$'\n'
        UN_HIT_PATH+=("$p"); UN_HIT_CAT+=("$cat"); UN_HIT_KB+=("$kb"); UN_HIT_CONF+=("$conf")
    done <<< "$(cat "$out"/hits.* 2>/dev/null | LC_ALL=C sort -t $'\t' -k4,4 | awk -F'\t' '!seen[$4]++' \
             | awk -F'\t' '{ printf "%d\t%s\n", length($4), $0 }' | LC_ALL=C sort -t $'\t' -k1,1n \
             | cut -f2- )"
    rm -rf "$out"
    _un_sort_hits
    return 0
}

# =============================================================================
# § _un_sort_hits
#
#   Orders the hit arrays for display: "safe" before "review", then by size,
#   largest first.
# =============================================================================
_un_sort_hits() {
    local -i i n=${#UN_HIT_PATH[@]}
    local conf cat kb p
    (( n > 1 )) || return 0
    local -a path=() ca=() k=() co=()
    while IFS=$'\t' read -r conf cat kb p; do
        [[ -n $p ]] || continue
        path+=("$p"); ca+=("$cat"); k+=("$kb"); co+=("$conf")
    done <<< "$(for (( i=0; i<n; i++ )); do
                 printf '%s\t%s\t%s\t%s\n' "${UN_HIT_CONF[i]}" "${UN_HIT_CAT[i]}" "${UN_HIT_KB[i]}" "${UN_HIT_PATH[i]}"
             done | LC_ALL=C sort -t $'\t' -k1,1r -k3,3nr)"
    UN_HIT_PATH=("${path[@]}"); UN_HIT_CAT=("${ca[@]}"); UN_HIT_KB=("${k[@]}"); UN_HIT_CONF=("${co[@]}")
}
