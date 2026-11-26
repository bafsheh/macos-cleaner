#!/usr/bin/env bash
# =============================================================================
# § lib/uninstall/apps.sh  ·  Find every app on this Mac
#
#   Single responsibility: discover the installed .app bundles and describe
#   them. Nothing here removes anything.
#
#     plist_get            read one value from a property list
#     app_identity         name · bundle ID · version of one bundle
#     app_is_listable      is this bundle one the user could uninstall?
#     apps_list_paths      every such bundle on the Mac
#     apps_scan_start      background scan that feeds the picker, live
#     apps_scan_poll       its progress, for ui_picker
#     apps_scan_stop       stop it
#
#   How the list fills in:
#     1. the app folders are listed (instant) - each app appears at once, its
#        size shown as "…"
#     2. a pool of workers measures the apps in parallel; each size replaces
#        its "…" as soon as it is known, and the progress bar counts them
#     3. meanwhile Spotlight is asked for apps kept elsewhere (Downloads,
#        Desktop …); any it finds join the list and are measured too
#
#   Apps in /System are left out: macOS seals them and they cannot be removed.
#
#   Env: UNINSTALL_APP_ROOTS   colon-separated folders to list instead of
#                              /Applications and ~/Applications
#        UNINSTALL_SPOTLIGHT   0 = do not ask Spotlight for apps elsewhere
#        UNINSTALL_JOBS        apps measured at the same time (default: CPU
#                              count, at most 6)
#
#   Requires (sourced earlier): core.sh, helpers.sh (run_timeout · path_size_kb
#                               · kill_tree)
# =============================================================================

APPS_SCAN_DIR=''        # working folder of the running scan
APPS_SCAN_PID=''        # its coordinator process

# Identity of the bundle last passed to app_identity.
APP_PATH='' APP_NAME='' APP_BUNDLE_NAME='' APP_BID='' APP_VERSION='' APP_EXEC=''

# =============================================================================
# § plist_get FILE KEY
#
#   Arguments:
#     FILE  a property list (XML or binary)
#     KEY   a top-level key, e.g. CFBundleIdentifier
#   Outputs:
#     The value; nothing when the key or the file is missing.
#   Returns:
#     0 when the key exists, non-zero otherwise
# =============================================================================
plist_get() { /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null; }

# =============================================================================
# § app_identity BUNDLE
#
#   Reads who an app is from its Info.plist.
#
#   Arguments:
#     BUNDLE  path to a .app bundle
#   Globals:
#     writes APP_PATH         the bundle path, no trailing slash
#     writes APP_NAME         the name the user sees in Finder ("Visual Studio Code")
#     writes APP_BUNDLE_NAME  CFBundleName, often what support folders are
#                             called ("Code"); empty when it equals APP_NAME
#     writes APP_BID          bundle identifier ("com.microsoft.VSCode"); empty
#                             when missing or not a plain identifier
#     writes APP_VERSION      short version string, may be empty
#     writes APP_EXEC         main executable name, may be empty
# =============================================================================
# shellcheck disable=SC2034  # APP_* are the result, read by the callers
app_identity() {
    local plist wrapped
    APP_PATH=${1%/}
    APP_NAME=${APP_PATH##*/}; APP_NAME=${APP_NAME%.app}
    APP_BUNDLE_NAME='' APP_BID='' APP_VERSION='' APP_EXEC=''

    plist="$APP_PATH/Contents/Info.plist"
    if [[ ! -f $plist ]]; then
        # iPhone / iPad apps on Apple silicon keep the real bundle in Wrapper/.
        for wrapped in "$APP_PATH"/Wrapper/*.app/Info.plist; do
            [[ -f $wrapped ]] && { plist=$wrapped; break; }
        done
    fi
    [[ -f $plist ]] || return 0

    APP_BID=$(plist_get "$plist" CFBundleIdentifier)
    # The ID ends up in commands and AppleScript: accept plain identifiers only.
    [[ $APP_BID =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || APP_BID=''
    APP_VERSION=$(plist_get "$plist" CFBundleShortVersionString) \
        || APP_VERSION=$(plist_get "$plist" CFBundleVersion)
    APP_VERSION=${APP_VERSION//[^A-Za-z0-9._ -]/}
    APP_EXEC=$(plist_get "$plist" CFBundleExecutable)
    APP_BUNDLE_NAME=$(plist_get "$plist" CFBundleName)
    [[ $APP_BUNDLE_NAME == "$APP_NAME" ]] && APP_BUNDLE_NAME=''
    return 0
}

# =============================================================================
# § _app_roots
#
#   Globals:
#     reads  UNINSTALL_APP_ROOTS (colon-separated override)
#     writes APP_ROOTS  the folders that hold installed apps
#   (An array rather than printed lines: the callers run once per app, and
#   reading lines back would need a subshell or a process substitution each
#   time - see lib/core.sh.)
# =============================================================================
APP_ROOTS=()
_app_roots() {
    if [[ -n ${UNINSTALL_APP_ROOTS:-} ]]; then
        IFS=: read -ra APP_ROOTS <<< "$UNINSTALL_APP_ROOTS"
    else
        APP_ROOTS=(/Applications "$HOME/Applications")
    fi
}

# =============================================================================
# § app_is_listable PATH
#
#   Decides whether a bundle belongs in the uninstall list.
#
#   Listed:      anything in the app folders (see _app_roots), and apps kept
#                elsewhere in the home folder (Downloads, Desktop …).
#   Not listed:  helper apps nested inside another bundle; anything in
#                ~/Library, the Trash or a hidden folder; build output and
#                dependency trees (node_modules, build, DerivedData …); and
#                everything outside the home folder - /System, /Library,
#                other volumes - which the user cannot or should not remove.
#
#   Arguments:
#     PATH  absolute path ending in .app
#   Returns:
#     0 to list it, 1 to leave it out
# =============================================================================
app_is_listable() {
    local p=$1 root
    [[ $p == /*.app ]] || return 1
    [[ $p == *.app/* ]] && return 1                 # nested inside another bundle

    _app_roots
    for root in "${APP_ROOTS[@]}"; do
        [[ -n $root && $p == "${root%/}"/* ]] && return 0
    done

    [[ $p == "$HOME"/* ]] || return 1
    case ${p#"$HOME"/} in
        Library/*|.*|*/.*)                                              return 1 ;;
        node_modules/*|*/node_modules/*|*/Pods/*)                       return 1 ;;
        */build/*|*/Build/*|*/DerivedData/*|*/target/*|*/dist/*|*/out/*) return 1 ;;
    esac
    return 0
}

# =============================================================================
# § apps_list_paths [SOURCE]
#
#   Arguments:
#     SOURCE  "folders" = only the app folders (instant)
#             "spotlight" = only what Spotlight knows about (a second or two)
#             omitted = both
#   Outputs:
#     Paths of the listable app bundles, one per line. A path can repeat
#     across the two sources; the caller de-duplicates.
# =============================================================================
apps_list_paths() {
    local src=${1:-all} p root
    local -a roots=()
    _app_roots
    for root in "${APP_ROOTS[@]}"; do [[ -d $root ]] && roots+=("$root"); done

    {
        if [[ $src != spotlight ]] && (( ${#roots[@]} > 0 )); then
            # -prune: list a bundle, never look inside it
            find "${roots[@]}" -maxdepth 3 -name '*.app' -prune 2>/dev/null
        fi
        if [[ $src != folders && ${UNINSTALL_SPOTLIGHT:-1} == 1 ]] && command -v mdfind &>/dev/null; then
            run_timeout 15 mdfind "kMDItemContentType == 'com.apple.application-bundle'" 2>/dev/null
        fi
    } | while IFS= read -r p; do
        app_is_listable "$p" && [[ -d $p ]] && printf '%s\n' "$p"
    done
    return 0
}

# =============================================================================
# § _apps_scan_add DIR SLOTS PATH
#
#   Announces one app: a picker row with its size still unknown, a line in the
#   bundle-ID index, and a place in a measuring queue.
#
#   Globals:
#     reads/writes _APPS_SEEN (newline-wrapped paths already announced),
#                  _APPS_COUNT
# =============================================================================
_apps_scan_add() {
    local dir=$1 path=$3 loc detail
    local -i slots=$2
    [[ $_APPS_SEEN == *$'\n'"$path"$'\n'* ]] && return 0
    _APPS_SEEN+="$path"$'\n'

    app_identity "$path"
    loc=${path%/*}; [[ $loc == "$HOME"* ]] && loc="~${loc#"$HOME"}"
    detail="${APP_VERSION:+v$APP_VERSION · }$loc"
    printf '%s\t%s\t%s\t-1\n' "$path" "$APP_NAME" "$detail"   >> "$dir/rows.tsv"
    printf '%s\t%s\n'         "$path" "${APP_BID:--}"         >> "$dir/meta.tsv"
    printf '%s\t%s\t%s\n'     "$path" "$APP_NAME" "$detail"   >> "$dir/queue.$(( _APPS_COUNT % slots ))"
    (( _APPS_COUNT++ ))
    printf '%d\n' "$_APPS_COUNT" > "$dir/total"
}

# =============================================================================
# § _apps_measure_worker DIR QUEUE
#
#   Measures every app in QUEUE and republishes its row with the real size.
#   One line is appended to DIR/done per app - the progress count.
# =============================================================================
_apps_measure_worker() {
    local dir=$1 queue=$2 path name detail
    local -i kb
    while IFS=$'\t' read -r path name detail; do
        printf 'measuring %s' "$name" > "$dir/note"
        kb=$(path_size_kb "$path")
        printf '%s\t%s\t%s\t%d\n' "$path" "$name" "$detail" "$kb" >> "$dir/rows.tsv"
        printf '.\n' >> "$dir/done"
    done < "$queue"
}

# =============================================================================
# § _apps_measure_all DIR SLOTS
#
#   Runs one worker per queue file and waits for them, then clears the queues
#   so a second round only measures what was added since.
# =============================================================================
_apps_measure_all() {
    local dir=$1 q
    local -i slots=$2 k
    local -a pids=()
    for (( k=0; k<slots; k++ )); do
        q="$dir/queue.$k"
        [[ -s $q ]] || continue
        mv "$q" "$q.run"
        _apps_measure_worker "$dir" "$q.run" &
        pids+=($!)
    done
    # Wait for the workers only - the Spotlight search may still be running.
    (( ${#pids[@]} > 0 )) && wait "${pids[@]}"
    rm -f "$dir"/queue.*.run
}

# =============================================================================
# § _apps_scan DIR
#
#   The scan itself; runs in the background (see apps_scan_start).
#
#   Files it keeps in DIR:
#     rows.tsv   picker rows (path · name · detail · size KB or -1)
#     meta.tsv   path <TAB> bundle ID ("-" when unknown) for every app
#     total      apps found so far        done      one line per app measured
#     note       the app being measured   finished  exists once all is done
# =============================================================================
_apps_scan() {
    local dir=$1 p
    local -i slots=0
    [[ ${UNINSTALL_JOBS:-} =~ ^[0-9]+$ ]] && slots=$UNINSTALL_JOBS
    (( slots >= 1 )) || slots=$(sysctl -n hw.ncpu 2>/dev/null || echo 4)
    (( slots > 6 )) && slots=6
    (( slots < 1 )) && slots=1
    _APPS_SEEN=$'\n' _APPS_COUNT=0

    printf 'looking in the app folders' > "$dir/note"
    apps_list_paths folders > "$dir/first"
    while IFS= read -r p; do _apps_scan_add "$dir" "$slots" "$p"; done < "$dir/first"

    # Spotlight is slow to answer, so it searches while the first apps are
    # being measured; whatever it adds is measured in a second round.
    apps_list_paths spotlight > "$dir/extra" 2>/dev/null &
    local -i spot=$!
    _apps_measure_all "$dir" "$slots"
    printf 'asking Spotlight for apps kept elsewhere' > "$dir/note"
    wait "$spot" 2>/dev/null
    while IFS= read -r p; do _apps_scan_add "$dir" "$slots" "$p"; done < "$dir/extra"
    _apps_measure_all "$dir" "$slots"

    : > "$dir/finished"
}

# =============================================================================
# § apps_scan_start DIR
#
#   Starts the scan in the background and returns at once.
#
#   Arguments:
#     DIR  an empty working folder
#   Globals:
#     writes APPS_SCAN_DIR, APPS_SCAN_PID
# =============================================================================
apps_scan_start() {
    APPS_SCAN_DIR=$1
    : > "$APPS_SCAN_DIR/rows.tsv"; : > "$APPS_SCAN_DIR/meta.tsv"; : > "$APPS_SCAN_DIR/done"
    printf '0\n' > "$APPS_SCAN_DIR/total"
    ( _apps_scan "$APPS_SCAN_DIR" ) < /dev/null > /dev/null 2>&1 &
    APPS_SCAN_PID=$!
}

# =============================================================================
# § apps_scan_stop
#
#   Stops the scan and its workers (a `du` over a huge app can run for a while).
# =============================================================================
apps_scan_stop() {
    [[ -n $APPS_SCAN_PID ]] && kill -0 "$APPS_SCAN_PID" 2>/dev/null && kill_tree "$APPS_SCAN_PID"
    APPS_SCAN_PID=''
    return 0
}

# =============================================================================
# § apps_scan_poll
#
#   Progress callback for ui_picker (PICKER_POLL_FN).
#
#   Globals:
#     reads  APPS_SCAN_DIR
#     writes PICKER_BUSY, PICKER_DONE, PICKER_TOTAL, PICKER_NOTE
# =============================================================================
# shellcheck disable=SC2034  # PICKER_* are read by ui_picker
apps_scan_poll() {
    local dir=$APPS_SCAN_DIR t=''
    [[ -f $dir/total ]] && read -r t < "$dir/total"
    [[ $t =~ ^[0-9]+$ ]] && PICKER_TOTAL=$t
    PICKER_DONE=$(( $(wc -l < "$dir/done" 2>/dev/null) + 0 ))
    if [[ -e $dir/finished ]]; then
        PICKER_BUSY=0
        PICKER_NOTE='macOS system apps are not listed - they cannot be removed'
    else
        PICKER_BUSY=1
        t=''; [[ -f $dir/note ]] && read -r t < "$dir/note"
        PICKER_NOTE=$t
    fi
    return 0
}
