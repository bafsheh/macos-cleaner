#!/usr/bin/env bash
# =============================================================================
# § lib/helpers/clean.sh  ·  Safe content deletion
#
#   Single responsibility: delete regenerable content, measure what was freed,
#   and say exactly what happened. Every helper keeps the folder it was given
#   and only removes what is inside.
#
#     clean_dir / clean_subdirs      empty one folder / several sub-folders
#     remove_files                   delete files matching a glob
#     sweep_caches                   many cache folders, one summary line
#     sweep_chromium_caches          every Chromium / Electron profile
#     stale_entries / purge_stale    temp items nothing has touched for days
#
#   Requires (sourced earlier): colors.sh, core.sh (counters/timeouts),
#                               logging.sh, helpers/measure.sh, helpers/exec.sh,
#                               helpers/macos.sh (is_tcc_blocked)
# =============================================================================

# =============================================================================
# § clean_dir TARGET LABEL [SUDO_PREFIX] [TIMEOUT_SECS]
#
#   Removes the *contents* of TARGET (preserves the directory itself).
#   • Logs size-before, item count, and size freed.
#   • Times the deletion and enforces DIR_TIMEOUT.
#
#   Arguments:
#     TARGET        folder to empty; a missing folder is simply skipped
#     LABEL         what it is, for the log and the summary
#     SUDO_PREFIX   "sudo" for a root-owned folder, else empty
#     TIMEOUT_SECS  limit for the delete (default DIR_TIMEOUT)
#   Globals:
#     writes TOTAL_FREED_KB and the TOTAL_* step counters; adds to the ledger
# =============================================================================
clean_dir() {
    local target="$1"
    local label="$2"
    local sudo_prefix="${3:-}"
    local -i timeout_sec=${4:-$DIR_TIMEOUT}

    step "[$label]"
    info "path    : $target"
    info "timeout : ${timeout_sec}s"

    if [[ ! -d $target ]]; then
        info "status  : not present - nothing to do"
        (( TOTAL_SKIPPED_MISSING++ ))
        echo
        return 0
    fi

    # User-owned targets only: for sudo targets an ordinary root-only permission
    # error would be misread as TCC.
    if [[ -z $sudo_prefix ]] && is_tcc_blocked "$target"; then
        warn "blocked by macOS privacy (needs Full Disk Access) ← $label"
        (( TOTAL_SKIPPED_PROTECTED++ )); (( TOTAL_TCC_BLOCKED++ ))
        echo
        return 0
    fi

    local -i size_before_kb items t0 t1 elapsed rc=0
    local    size_before_h
    size_before_kb=$(dir_size_kb "$target")
    size_before_h=$(human_size "$size_before_kb")
    # shellcheck disable=SC2086
    items=$( $sudo_prefix find "$target" -mindepth 1 2>/dev/null | wc -l | tr -d ' ' )
    info "size    : ${size_before_h}  (${items} items)"

    if (( size_before_kb == 0 && items == 0 )); then
        info "status  : already empty"
        echo
        return 0
    fi

    info "action  : deleting contents…"
    t0=$(date +%s)

    # shellcheck disable=SC2086
    run_timeout "$timeout_sec" $sudo_prefix find "$target" -mindepth 1 -delete 2>/dev/null \
        || rc=$?

    t1=$(date +%s)
    (( elapsed = t1 - t0 )) || true
    info "elapsed : ${elapsed}s   exit: ${rc}"

    if (( rc == 124 )); then
        (( TOTAL_TIMEDOUT++ )); (( TOTAL_SKIPPED_PROTECTED++ ))
        warn "TIMED OUT after ${timeout_sec}s - partial cleanup ← $label"
    elif (( rc == 0 )); then
        local -i size_after_kb freed_kb left
        size_after_kb=$(dir_size_kb "$target")
        (( freed_kb = size_before_kb - size_after_kb )) || true
        (( freed_kb < 0 )) && freed_kb=0
        (( TOTAL_FREED_KB += freed_kb ))
        ledger_add "$label" "$freed_kb"
        # find can exit 0 yet leave entries it could not unlink (read-only
        # parent folder, locked file) - never report those as fully cleaned.
        # shellcheck disable=SC2086
        left=$( $sudo_prefix find "$target" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ' )
        if (( left > 0 )); then
            (( TOTAL_SKIPPED_PROTECTED++ ))
            warn "freed $(human_size $freed_kb); ${left} item(s) could not be removed ← $label"
        else
            (( TOTAL_CLEANED++ ))
            ok "freed $(human_size $freed_kb) in ${elapsed}s ← $label"
        fi
    else
        (( TOTAL_SKIPPED_PROTECTED++ ))
        warn "partial (exit=${rc}, ${elapsed}s) - some items in use ← $label"
    fi
    echo
}

# =============================================================================
# § clean_subdirs BASE LABEL SUBDIR...
#
#   Empties several sub-folders of one app or tool folder - the usual shape of
#   an Electron app's caches. Each sub-folder is its own clean_dir step,
#   labelled "LABEL SUBDIR":
#
#       clean_subdirs "$HOME/Library/Application Support/Claude" "Claude" \
#           Cache "Code Cache" GPUCache logs
#
#   Arguments:
#     BASE       the folder the sub-folders live in
#     LABEL      the app or tool name
#     SUBDIR...  sub-folder names (may contain spaces or a nested path)
# =============================================================================
clean_subdirs() {
    local base=$1 label=$2 sub; shift 2
    for sub in "$@"; do clean_dir "$base/$sub" "$label $sub"; done
}

# =============================================================================
# § remove_files DIR GLOB LABEL
#
#   Deletes the regular files in DIR whose names match GLOB (no recursion,
#   directories never touched). Logs count and size freed, like clean_dir.
#
#   Arguments:
#     DIR    folder to look in
#     GLOB   file-name pattern, e.g. "*.gem"
#     LABEL  what the files are, for the log and the summary
# =============================================================================
remove_files() {
    local dir="$1" glob="$2" label="$3"
    step "[$label]"
    info "path    : $dir/$glob"

    local -a hits=()
    local f
    if [[ -d $dir ]]; then
        # shellcheck disable=SC2231  # GLOB is a pattern and must expand
        for f in "$dir"/$glob; do [[ -f $f ]] && hits+=("$f"); done
    fi
    if (( ${#hits[@]} == 0 )); then
        info "status  : not present - nothing to do"
        (( TOTAL_SKIPPED_MISSING++ ))
        echo
        return 0
    fi

    local -i freed_kb=0 removed=0 kb
    for f in "${hits[@]}"; do
        kb=$(du -sk "$f" 2>/dev/null | awk '{print $1+0}')
        if rm -f "$f" 2>/dev/null; then
            (( freed_kb += kb )); (( removed++ ))
            info "removed : ${f##*/}  ($(human_size "$kb"))"
        else
            warn "could not remove ${f##*/}"
        fi
    done

    (( TOTAL_FREED_KB += freed_kb ))
    ledger_add "$label" "$freed_kb"
    if (( removed == ${#hits[@]} )); then
        (( TOTAL_CLEANED++ ))
        ok "freed $(human_size "$freed_kb") (${removed} files) ← $label"
    else
        (( TOTAL_FAILED++ ))
        warn "removed ${removed}/${#hits[@]} files ← $label"
    fi
    echo
}

# =============================================================================
# § sweep_caches LABEL BASE PATH_PATTERN
#
#   Bulk-clears the *contents* of every cache directory under BASE whose full
#   path matches PATH_PATTERN (a find(1) -path glob, e.g. "*/Data/Library/Caches"
#   for app sandbox containers). Each match is treated as regenerable cache - the
#   directory itself is preserved, only its contents are removed.
#
#   Unlike clean_dir (one verbose block per path), this aggregates many matches
#   into a single compact summary, which matters when sweeping the dozens of app
#   containers that make up macOS "System Data". Per-directory deletes honour
#   DIR_TIMEOUT; the global counters are updated once for the whole sweep.
#
#   Uses find + `while read` (not shell globbing) so paths containing spaces -
#   e.g. "~/Library/Group Containers" - are handled correctly.
#
#   SAFETY: iCloud sync daemons stage *un-uploaded* user data under their own
#   container Caches (research-verified for com.apple.bird / CloudKit). Any
#   container whose path matches SWEEP_SKIP_RE is skipped and reported, never
#   wiped - losing those would lose data that has not yet reached iCloud.
# =============================================================================
# Matches any iCloud-sync staging container/cache that may hold un-uploaded user
# data: com.apple.bird (legacy iCloud Drive), cloudd/CloudKit, the Photos sync
# daemon, and the modern iCloud Drive file-provider (com.apple.CloudDocs.*). The
# bare CloudKit / iCloud tokens also catch ~/Library/Caches/CloudKit and any
# future iCloud* dir. Over-skipping a cache is harmless; under-skipping is not.
declare -r SWEEP_SKIP_RE='com\.apple\.(bird|cloudd|cloudphotosd|CloudPhotos|CloudDocs|protectedcloudstorage)|CloudKit|iCloud'

sweep_caches() {
    local label="$1" base="$2" pattern="$3"

    step "[$label]"
    info "scan    : $base  (match: $pattern)"

    if [[ ! -d $base ]]; then
        info "status  : not present - nothing to do"
        (( TOTAL_SKIPPED_MISSING++ ))
        echo; return 0
    fi

    # Enumerate matching cache dirs first (‑prune: don't descend into a match).
    local -a dirs=()
    local d
    local -i skipped=0
    while IFS= read -r d; do
        [[ -n $d ]] || continue
        # Never touch iCloud-sync staging caches (may hold un-uploaded data).
        if [[ $d =~ $SWEEP_SKIP_RE ]]; then
            (( skipped++ )); continue
        fi
        dirs+=("$d")
    done < <(find "$base" -maxdepth 5 -type d -path "$pattern" -prune 2>/dev/null)

    (( skipped > 0 )) && info "skipped : ${skipped} iCloud-sync cache(s) (may hold un-uploaded data)"

    _sweep_dirs "$label" ${dirs[@]+"${dirs[@]}"}
}

# =============================================================================
# § sweep_chromium_caches LABEL BASE
#
#   Clears the disposable caches of every Chromium / Electron profile under BASE
#   (normally ~/Library/Application Support): Chrome, Edge, Brave, Arc and Opera
#   profiles (all of them, not just Default) plus Electron apps such as Slack,
#   Discord, Notion, Figma, Teams, Postman, VS Code and its forks.
#
#   A folder is only treated as a Chromium profile when it holds a "Code Cache"
#   or "GPUCache" folder - names only Chromium uses - so a generic folder that
#   merely happens to be called "Cache" elsewhere is never touched. Cookies,
#   logins, local storage, IndexedDB and settings are left alone.
# =============================================================================
declare -ra CHROMIUM_CACHE_DIRS=(
    "Cache" "Code Cache" "GPUCache" "DawnCache" "DawnGraphiteCache"
    "DawnWebGPUCache" "GrShaderCache" "ShaderCache"
    "Service Worker/CacheStorage" "Service Worker/ScriptCache"
)

sweep_chromium_caches() {
    local label="$1" base="$2"

    step "[$label]"
    info "scan    : $base  (Chromium/Electron profiles)"

    if [[ ! -d $base ]]; then
        info "status  : not present - nothing to do"
        (( TOTAL_SKIPPED_MISSING++ ))
        echo; return 0
    fi

    local -a dirs=()
    local marker profile sub
    while IFS= read -r marker; do
        [[ -n $marker ]] || continue
        profile=${marker%/*}
        [[ $profile == "$base" || $profile =~ $SWEEP_SKIP_RE ]] && continue
        for sub in "${CHROMIUM_CACHE_DIRS[@]}"; do
            [[ -d "$profile/$sub" ]] && dirs+=("$profile/$sub")
        done
    done < <(find "$base" -maxdepth 6 -type d \( -name "Code Cache" -o -name "GPUCache" \) -prune 2>/dev/null)

    # A profile with both markers is listed twice - de-duplicate the targets.
    local -a uniq=()
    if (( ${#dirs[@]} > 0 )); then
        while IFS= read -r sub; do uniq+=("$sub"); done < <(printf '%s\n' "${dirs[@]}" | sort -u)
    fi

    _sweep_dirs "$label" ${uniq[@]+"${uniq[@]}"}
}

# =============================================================================
# § _sweep_dirs LABEL DIR...
#
#   Shared delete loop for the sweep_* helpers: clears the contents of each DIR,
#   keeps the directory, and prints one aggregate summary line.
# =============================================================================
_sweep_dirs() {
    local label="$1"; shift
    local -a dirs=("$@")
    local d

    if (( ${#dirs[@]} == 0 )); then
        info "status  : no matching cache directories"
        echo; return 0
    fi

    info "found   : ${#dirs[@]} cache director(ies)"

    local -i swept=0 freed_total=0 before after freed rc t0 t1
    t0=$(date +%s)
    for d in "${dirs[@]}"; do
        before=$(dir_size_kb "$d")
        (( before == 0 )) && continue
        rc=0
        run_timeout "$DIR_TIMEOUT" find "$d" -mindepth 1 -delete 2>/dev/null || rc=$?
        after=$(dir_size_kb "$d")
        (( freed = before - after )) || true
        (( freed < 0 )) && freed=0
        (( freed_total += freed ))
        (( freed > 0 )) && (( swept++ ))
    done
    t1=$(date +%s)

    (( TOTAL_FREED_KB += freed_total ))
    ledger_add "$label" "$freed_total"
    (( TOTAL_CLEANED++ ))
    ok "freed $(human_size $freed_total) across ${swept}/${#dirs[@]} cache dir(s) in $(( t1 - t0 ))s ← $label"
    echo
}

# =============================================================================
# § stale_entries BASE DEPTH [SUDO_PREFIX]
#
#   Prints (one per line) every entry exactly DEPTH levels below BASE that is
#   *entirely* stale: nothing inside it was modified or created in the last
#   TEMP_AGE_DAYS days and it holds no socket. Entries are judged as a whole,
#   so a folder is either removed completely or kept intact - never
#   half-emptied while an app still uses it.
#
#   Never listed, whatever their age:
#     • sockets and anything containing one (ssh-agent, tmux, VS Code, Docker)
#     • launchd / ssh / tmux / X11 session folders (TEMP_KEEP_RE) - these are
#       created at boot, so on a Mac that has been up for days they *look* old
#       but deleting them breaks ssh-agent and tmux until the next reboot
#     • items owned by someone else, unless SUDO_PREFIX is given
#     • anything find cannot fully read (can't verify it's stale → keep it)
# =============================================================================
declare -r TEMP_KEEP_RE='^(com\.apple\.launchd\.|tmux-|ssh-|launch-|\.X11-unix$|\.ICE-unix$|\.font-unix$|\.vbox-|powerlog$|mac_cleaner_)'

stale_entries() {
    local base="$1" sudo_prefix="${3:-}"
    local -i depth=$2
    [[ -d $base ]] || return 0

    local e hit
    local -i rc
    while IFS= read -r e; do
        [[ -n $e ]] || continue
        [[ ${e##*/} =~ $TEMP_KEEP_RE ]] && continue
        [[ -n $sudo_prefix || -O $e ]] || continue
        rc=0
        # shellcheck disable=SC2086
        hit=$($sudo_prefix find "$e" \( -type s -o -mtime "-$TEMP_AGE_DAYS" -o -ctime "-$TEMP_AGE_DAYS" \) \
                  -print -quit 2>/dev/null) || rc=$?
        [[ -z $hit ]] && (( rc == 0 )) && printf '%s\n' "$e"
    done < <($sudo_prefix find "$base" -mindepth "$depth" -maxdepth "$depth" 2>/dev/null)
}

# =============================================================================
# § purge_stale LABEL BASE DEPTH [SUDO_PREFIX]
#
#   Removes every entry stale_entries reports for BASE/DEPTH, logging what
#   went and how much space it freed. Safe on any tmp-like directory.
# =============================================================================
purge_stale() {
    local label="$1" base="$2" depth="$3" sudo_prefix="${4:-}"

    step "[$label  (untouched ${TEMP_AGE_DAYS}+ days)]"
    info "path    : $base"

    if [[ ! -d $base ]]; then
        info "status  : not present - nothing to do"
        (( TOTAL_SKIPPED_MISSING++ ))
        echo; return 0
    fi

    local -a stale=()
    local e
    while IFS= read -r e; do stale+=("$e"); done < <(stale_entries "$base" "$depth" "$sudo_prefix")

    if (( ${#stale[@]} == 0 )); then
        info "status  : nothing stale - recent and in-use items kept"
        echo; return 0
    fi
    info "found   : ${#stale[@]} stale item(s)"

    local -i kb freed=0 removed=0 failed=0
    for e in "${stale[@]}"; do
        # shellcheck disable=SC2086
        kb=$($sudo_prefix du -sk "$e" 2>/dev/null | awk '{print $1+0}')
        # shellcheck disable=SC2086
        run_timeout "$DIR_TIMEOUT" $sudo_prefix rm -rf "$e" 2>/dev/null
        if [[ ! -e $e && ! -L $e ]]; then
            (( removed++ )); (( freed += kb ))
            (( removed <= 8 )) && info "  removed : ${e##*/}  ($(human_size "$kb"))"
        else
            (( failed++ ))
        fi
    done
    (( removed > 8 )) && info "  … and $(( removed - 8 )) more"

    (( TOTAL_FREED_KB += freed ))
    ledger_add "$label" "$freed"
    if (( failed == 0 )); then
        (( TOTAL_CLEANED++ ))
        ok "freed $(human_size $freed) from ${removed} item(s) ← $label"
    else
        (( TOTAL_SKIPPED_PROTECTED++ ))
        warn "freed $(human_size $freed); ${failed} item(s) could not be removed ← $label"
    fi
    echo
}
