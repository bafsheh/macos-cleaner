#!/usr/bin/env bash
# ┌─────────────────────────────────────────────────────────────────────────────┐
# │  mac_cleaner.sh  ·  Safe macOS disk-space cleaner                          │
# │                                                                             │
# │  Clears caches, logs, package-manager stores, and Trash.                   │
# │  Never touches personal files (Documents, Desktop, Pictures, …).           │
# │                                                                             │
# │  Requires : bash 4.3+  (macOS ships bash 3.2 — install: brew install bash) │
# │  Sudo     : system-cache and ASL-log steps will prompt for a password.     │
# │                                                                             │
# │  Usage                                                                      │
# │    chmod +x mac_cleaner.sh && ./mac_cleaner.sh                             │
# │                                                                             │
# │  Env overrides                                                              │
# │    CMD_TIMEOUT=60    per-command timeout in seconds     (default 60)       │
# │    DIR_TIMEOUT=120   per-directory delete timeout       (default 120)      │
# │    SCAN_TIMEOUT=60   project-scan find timeout          (default 60)       │
# │    PY_SCAN_ROOTS     space-separated roots for Python project scan         │
# │    JS_SCAN_ROOTS     space-separated roots for JS project scan             │
# └─────────────────────────────────────────────────────────────────────────────┘

# =============================================================================
# § RUNTIME FLAGS
# -u          : abort on unset variable reference
# -o pipefail : pipeline exit-code = first failure
# (no -e: we want the script to continue even when individual steps fail)
# =============================================================================
set -uo pipefail

# =============================================================================
# § BASH VERSION NOTE
#   The script targets bash 3.2+ (the version shipped with macOS).
#   No external bash installation is required.
# =============================================================================

# =============================================================================
# § macOS GUARD
# =============================================================================
if [[ $(uname) != Darwin ]]; then
    printf 'ERROR: This script is macOS-only.\n' >&2
    exit 1
fi

# =============================================================================
# § COLOURS
# =============================================================================
declare -r RED='\033[0;31m'
declare -r GRN='\033[0;32m'
declare -r YLW='\033[1;33m'
declare -r BLU='\033[0;34m'
declare -r CYN='\033[0;36m'
declare -r DIM='\033[2m'
declare -r NC='\033[0m'

# =============================================================================
# § LOG FILE
# =============================================================================
LOG_FILE="${TMPDIR:-/tmp}/mac_cleaner_$(date +%Y%m%d_%H%M%S).log"
: > "$LOG_FILE"   # create / truncate immediately

# =============================================================================
# § COUNTERS  (declare -i → bash treats as integer; arithmetic is always safe)
# =============================================================================
declare -i TOTAL_FREED_KB=0
declare -i TOTAL_CLEANED=0
declare -i TOTAL_SKIPPED_MISSING=0
declare -i TOTAL_SKIPPED_PROTECTED=0
declare -i TOTAL_FAILED=0
declare -i TOTAL_TIMEDOUT=0
declare -r START_TIME=$(date +%s)

# =============================================================================
# § TUNABLE TIMEOUTS  (seconds — override via environment)
# =============================================================================
declare -i CMD_TIMEOUT=${CMD_TIMEOUT:-60}
declare -i DIR_TIMEOUT=${DIR_TIMEOUT:-120}
declare -i SCAN_TIMEOUT=${SCAN_TIMEOUT:-60}

# =============================================================================
# § LOGGING PRIMITIVES
# =============================================================================
_log()    { printf '%b\n' "$*" | tee -a "$LOG_FILE"; }
say()     { _log "${BLU}==>${NC} $*"; }
step()    { _log "${CYN}  →${NC} $*"; }
info()    { _log "${DIM}    $*${NC}"; }
ok()      { _log "${GRN}  ✓${NC} $*"; }
warn()    { _log "${YLW}  !${NC} $*"; }
fail()    { _log "${RED}  ✗${NC} $*"; }

# GitHub-style section banner ─ renders as a visible heading in the log
section() {
    local title="$1"
    local rule; rule=$(printf '─%.0s' {1..76})
    _log ""
    _log "${BLU}# ${rule}${NC}"
    _log "${BLU}# § ${title}${NC}"
    _log "${BLU}# ${rule}${NC}"
    _log ""
}

# =============================================================================
# § UTILITY: disk / size helpers
# =============================================================================
disk_free() { df -h / | awk 'NR==2 {print $4 " free of " $2}'; }

human_size() {
    local -i kb=$1
    if   (( kb >= 1048576 )); then awk -v k="$kb" 'BEGIN{printf "%.2f GB", k/1048576}'
    elif (( kb >= 1024 ));    then awk -v k="$kb" 'BEGIN{printf "%.1f MB", k/1024}'
    else                           printf '%d KB' "$kb"
    fi
}

dir_size_kb() {
    local p="$1"
    [[ -d $p ]] || { printf '0'; return; }
    du -sk "$p" 2>/dev/null | awk '{print $1+0}'
}

# =============================================================================
# § TIMEOUT WRAPPER
#
#   Preference order:
#     1. gtimeout  (brew install coreutils)   — most reliable on macOS
#     2. timeout   (available on macOS 12+)
#     3. pure-bash watchdog fallback
#
#   Exit code 124 = timed out  (POSIX timeout convention)
# =============================================================================
_TIMEOUT_BIN=''
if   command -v gtimeout &>/dev/null; then _TIMEOUT_BIN='gtimeout'
elif command -v timeout  &>/dev/null; then _TIMEOUT_BIN='timeout'
fi

run_timeout() {
    local -i secs=$1; shift

    if [[ -n $_TIMEOUT_BIN ]]; then
        "$_TIMEOUT_BIN" --kill-after=5 "$secs" "$@"
        return $?
    fi

    # ── pure-bash fallback ──────────────────────────────────────────────────
    "$@" &
    local -i child=$! waited=0
    while (( waited < secs )); do
        sleep 1; (( waited++ ))
        kill -0 "$child" 2>/dev/null || { wait "$child"; return $?; }
    done
    kill -TERM "$child" 2>/dev/null
    sleep 2
    kill -KILL "$child" 2>/dev/null
    wait "$child" 2>/dev/null
    return 124
}

# =============================================================================
# § run_step LABEL COMMAND_STRING
#
#   Executes COMMAND_STRING (via bash -c) with CMD_TIMEOUT.
#   • Captures and logs every line of stdout and stderr verbosely.
#   • Records exit code, elapsed time, and timeout state.
#   • Never aborts the outer script on failure.
# =============================================================================
run_step() {
    local label="$1"
    local cmd="$2"

    local stdout_f stderr_f
    stdout_f=$(mktemp)
    stderr_f=$(mktemp)

    step  "[$label]"
    info  "cmd     : $cmd"
    info  "timeout : ${CMD_TIMEOUT}s"

    local -i t0 t1 elapsed rc=0
    t0=$(date +%s)

    run_timeout "$CMD_TIMEOUT" bash -c "$cmd" >"$stdout_f" 2>"$stderr_f" || rc=$?

    t1=$(date +%s)
    (( elapsed = t1 - t0 )) || true

    # ── verbose stdout ──────────────────────────────────────────────────────
    if [[ -s $stdout_f ]]; then
        info "stdout  :"
        while IFS= read -r line; do
            info "  │ $line"
        done < "$stdout_f"
    fi

    # ── verbose stderr ──────────────────────────────────────────────────────
    if [[ -s $stderr_f ]]; then
        info "stderr  :"
        while IFS= read -r line; do
            info "  │ $line"
        done < "$stderr_f"
    fi

    rm -f "$stdout_f" "$stderr_f"
    info "exit    : ${rc}   elapsed: ${elapsed}s"

    if   (( rc == 124 )); then
        (( TOTAL_TIMEDOUT++ )); (( TOTAL_FAILED++ ))
        warn "TIMED OUT after ${CMD_TIMEOUT}s ← $label"
    elif (( rc == 0 )); then
        (( TOTAL_CLEANED++ ))
        ok   "done (${elapsed}s) ← $label"
    else
        (( TOTAL_FAILED++ ))
        warn "FAILED exit=${rc} (${elapsed}s) ← $label"
    fi
    echo
}

# =============================================================================
# § clean_dir TARGET LABEL [SUDO_PREFIX] [TIMEOUT_SECS]
#
#   Removes the *contents* of TARGET (preserves the directory itself).
#   • Logs size-before, item count, and size freed.
#   • Times the deletion and enforces DIR_TIMEOUT.
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
        info "status  : not present — nothing to do"
        (( TOTAL_SKIPPED_MISSING++ ))
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
        warn "TIMED OUT after ${timeout_sec}s — partial cleanup ← $label"
    elif (( rc == 0 )); then
        local -i size_after_kb freed_kb
        size_after_kb=$(dir_size_kb "$target")
        (( freed_kb = size_before_kb - size_after_kb )) || true
        (( freed_kb < 0 )) && freed_kb=0
        (( TOTAL_FREED_KB += freed_kb ))
        (( TOTAL_CLEANED++ ))
        ok "freed $(human_size $freed_kb) in ${elapsed}s ← $label"
    else
        (( TOTAL_SKIPPED_PROTECTED++ ))
        warn "partial (exit=${rc}, ${elapsed}s) — some items in use ← $label"
    fi
    echo
}

# =============================================================================
# § skip_missing LABEL
#
#   Prints a uniform "not installed — skipping" notice.
#   Use wherever a tool is absent and no action can be taken.
# =============================================================================
skip_missing() {
    step "[$1]"
    info "status  : not installed — skipping"
    echo
}

# =============================================================================
# § clean_old_tmp LABEL PATH [SUDO_PREFIX]
#
#   Removes items inside PATH that have not been modified in >3 days.
#   Safe to call on any tmp-like directory.
# =============================================================================
clean_old_tmp() {
    local label="$1"
    local path="$2"
    local sudo_prefix="${3:-}"

    step "[$label  (mtime >3 days)]"
    info "path    : $path"

    if [[ ! -d $path ]]; then
        info "status  : not present — nothing to do"
        echo; return 0
    fi

    local -i cnt=0 rc=0
    # shellcheck disable=SC2086
    cnt=$( $sudo_prefix find "$path" -mindepth 1 -mtime +3 2>/dev/null \
           | wc -l | tr -d ' ' )
    info "found   : $cnt old items"

    if (( cnt > 0 )); then
        # shellcheck disable=SC2086
        $sudo_prefix find "$path" -mindepth 1 -mtime +3 -delete 2>/dev/null || rc=$?
        if (( rc == 0 )); then
            (( TOTAL_CLEANED++ ))
            ok "removed $cnt items ← $label"
        else
            (( TOTAL_FAILED++ ))
            warn "partial removal (exit=${rc}) ← $label"
        fi
    else
        info "status  : nothing to clean"
    fi
    echo
}

# =============================================================================
# § clean_tm_snapshots
#
#   Lists and deletes all Time Machine local snapshots on the boot volume.
#   Local snapshots are temporary backups stored on-disk; deleting them is
#   safe — they have no effect on your remote Time Machine backup.
#   Requires sudo for deletion.
# =============================================================================
clean_tm_snapshots() {
    step "[Time Machine local snapshots]"

    if ! command -v tmutil &>/dev/null; then
        info "status  : tmutil not found — skipping"
        echo; return 0
    fi

    # listlocalsnapshotdates returns bare date strings: "2024-06-01-120000"
    local -a dates=()
    local d
    while IFS= read -r d; do
        [[ -n $d ]] && dates+=("$d")
    done < <(tmutil listlocalsnapshotdates / 2>/dev/null)

    info "found   : ${#dates[@]} local snapshot(s)"

    if (( ${#dates[@]} == 0 )); then
        info "status  : no local snapshots — nothing to do"
        echo; return 0
    fi

    for d in "${dates[@]}"; do
        info "  snapshot: $d"
    done

    local -i deleted=0 failed=0
    for d in "${dates[@]}"; do
        if sudo tmutil deletelocalsnapshots "$d" &>/dev/null; then
            (( deleted++ ))
            info "  deleted : $d"
        else
            (( failed++ ))
            warn "  failed  : $d"
        fi
    done

    if (( failed == 0 )); then
        (( TOTAL_CLEANED++ ))
        ok "deleted ${deleted} local snapshot(s)"
    else
        warn "deleted ${deleted}/${#dates[@]} (${failed} failed — may need sudo or newer macOS)"
    fi
    echo
}

# =============================================================================
# § report_largest_dirs PATH LABEL [DEPTH] [COUNT]
#
#   Prints a ranked list of the largest subdirectories under PATH.
#   Purely informational — nothing is deleted.
#   DEPTH defaults to 1; COUNT defaults to 20.
# =============================================================================
report_largest_dirs() {
    local path="$1"
    local label="$2"
    local -i depth=${3:-1}
    local -i count=${4:-20}

    step "[$label — top ${count} by size]"
    info "path    : $path  (depth ${depth})"

    if [[ ! -d $path ]]; then
        info "status  : directory not present"
        echo; return 0
    fi

    local results
    results=$(du -hd "$depth" "$path" 2>/dev/null | sort -hr | head -"$count")

    if [[ -n $results ]]; then
        while IFS= read -r line; do
            info "  $line"
        done <<< "$results"
    else
        info "status  : no data returned"
    fi
    echo
}

# =============================================================================
# § _scan_and_delete  LABEL ENVVAR DESCRIPTION FIND_PREDICATES...
#
#   Finds and removes directories/files matching FIND_PREDICATES inside
#   common dev-folder roots.  ENVVAR can supply a custom root list.
#   • Heartbeat every 2s; aborts at SCAN_TIMEOUT.
#   • Logs found count, deleted count, and any partial-timeout notice.
# =============================================================================
_scan_and_delete() {
    local label="$1"
    local envvar="$2"
    local desc="$3"
    shift 3
    local -a preds=("$@")    # raw find predicates passed through unchanged

    step "[$label]"
    info "timeout : ${SCAN_TIMEOUT}s"
    info "looking : $desc"

    # ── build root list ─────────────────────────────────────────────────────
    local -a roots=()
    if [[ -n ${!envvar:-} ]]; then
        read -ra roots <<< "${!envvar}"
    else
        local d
        for d in \
            "$HOME/Documents" "$HOME/Developer" "$HOME/Projects" "$HOME/projects" \
            "$HOME/Code"      "$HOME/code"      "$HOME/dev"      "$HOME/Dev"     \
            "$HOME/repos"     "$HOME/Repos"     "$HOME/src"      "$HOME/workspace" \
            "$HOME/Workspace" "$HOME/Sites"     "$HOME/work"     "$HOME/Work"; do
            [[ -d $d ]] && roots+=("$d")
        done
    fi

    if (( ${#roots[@]} == 0 )); then
        info "status  : no dev folders found"
        info "tip     : export ${envvar}=/your/code to override"
        echo; return 0
    fi

    info "roots   :"
    local r; for r in "${roots[@]}"; do info "  - $r"; done
    info "(heartbeat active — Ctrl+C to skip this scan)"

    local hit_list; hit_list=$(mktemp)

    (
        find "${roots[@]}" \
            -maxdepth 6 \
            \( -path '*/node_modules' -o -path '*/.git'   -o -path '*/Library' \
               -o -path '*/.Trash'    -o -path '*/.venv'  -o -path '*/venv'    \
               -o -path '*/.tox' \) -prune -o \
            "${preds[@]}" -print 2>/dev/null
    ) > "$hit_list" &
    local -i fpid=$! waited=0 scan_ok=1

    while kill -0 "$fpid" 2>/dev/null; do
        sleep 2; (( waited += 2 ))
        local -i cur; cur=$(wc -l < "$hit_list" 2>/dev/null | tr -d ' ')
        printf "${DIM}    …%ds  %d found${NC}\r" "$waited" "${cur:-0}"
        if (( waited >= SCAN_TIMEOUT )); then
            kill "$fpid" 2>/dev/null; wait "$fpid" 2>/dev/null
            printf '\n'
            warn "scan timed out (${SCAN_TIMEOUT}s) — set ${envvar}= for a narrower scope"
            scan_ok=0; break
        fi
    done
    wait "$fpid" 2>/dev/null; printf '\n'

    local -i found=0 deleted=0
    found=$(wc -l < "$hit_list" | tr -d ' ')
    info "found   : ${found} entries"

    if (( found > 0 )); then
        local entry
        while IFS= read -r entry; do
            rm -rf "$entry" 2>/dev/null && (( deleted++ )) || true
            if (( deleted % 25 == 0 && deleted > 0 )); then
                printf "${DIM}    deleted %d / %d${NC}\r" "$deleted" "$found"
            fi
        done < "$hit_list"
        printf '\n'
        (( TOTAL_CLEANED++ ))
        ok "deleted ${deleted}/${found} entries ← $label"
    else
        info "status  : nothing to clean"
    fi

    rm -f "$hit_list"
    echo
}

# =============================================================================
# § interactive_menu TITLE ITEM...
#
#   Arrow-key navigable full-screen menu.
#   Sets global MENU_RESULT to the 0-based index of the chosen item.
#   Falls back to a plain numbered prompt when stdin is not a terminal.
# =============================================================================
interactive_menu() {
    local title="$1"; shift
    local -a items=("$@")
    local -i n=${#items[@]} sel=0 i

    # ── non-interactive fallback ─────────────────────────────────────────────
    if [[ ! -t 0 ]]; then
        printf '\n%s\n' "$title"
        for (( i=0; i<n; i++ )); do
            printf '  %d.  %s\n' "$(( i+1 ))" "${items[i]}"
        done
        printf 'Enter choice [1-%d]: ' "$n"
        local ans; read -r ans
        MENU_RESULT=$(( ans - 1 ))
        (( MENU_RESULT < 0 || MENU_RESULT >= n )) && MENU_RESULT=$(( n-1 ))
        return
    fi

    tput civis 2>/dev/null       # hide cursor while navigating

    printf '\n'
    printf "  ${BLU}%s${NC}\n" "$title"
    printf "  ${DIM}↑ ↓ arrows  ·  Enter to select  ·  q to quit${NC}\n\n"

    # ── initial render ───────────────────────────────────────────────────────
    for (( i=0; i<n; i++ )); do
        if (( i == sel )); then
            printf "  ${CYN}❯  %s${NC}\n" "${items[i]}"
        else
            printf "  ${DIM}   %s${NC}\n" "${items[i]}"
        fi
    done

    # ── input loop ───────────────────────────────────────────────────────────
    local key seq
    while true; do
        IFS= read -rsn1 key

        if [[ $key == $'\x1b' ]]; then
            IFS= read -rsn2 -t 1 seq 2>/dev/null || seq=''
            key="${key}${seq}"
        fi

        case $key in
            $'\x1b[A') (( sel > 0   )) && (( sel-- )) ;;   # ↑
            $'\x1b[B') (( sel < n-1 )) && (( sel++ )) ;;   # ↓
            $'\x1b[H') sel=0 ;;                             # Home
            $'\x1b[F') (( sel = n-1 )) ;;                  # End
            '') break ;;                                    # Enter
            q|Q) (( sel = n-1 )); break ;;                 # q → last item
        esac

        # ── redraw ───────────────────────────────────────────────────────────
        tput cuu "$n" 2>/dev/null
        for (( i=0; i<n; i++ )); do
            printf '\r'; tput el 2>/dev/null
            if (( i == sel )); then
                printf "  ${CYN}❯  %s${NC}\n" "${items[i]}"
            else
                printf "  ${DIM}   %s${NC}\n" "${items[i]}"
            fi
        done
    done

    tput cnorm 2>/dev/null       # restore cursor
    MENU_RESULT=$sel
}

# =============================================================================
# § run_uninstaller
#
#   Prompts for an app/package name, searches every known install location,
#   displays findings with type, path, and size, then removes confirmed items.
#
#   Search locations
#     /Applications · ~/Applications — .app bundles
#     Homebrew formula + cask
#     CLI binary dirs (/opt/homebrew/bin, /usr/local/bin, …)
#     npm global packages
#     pip / pip3 packages
#     Cargo binaries (~/.cargo/bin)
#     RubyGems
#     ~/Library/Application Support + /Library/Application Support
#     ~/Library/Preferences + /Library/Preferences
#     ~/Library/Caches + /Library/Caches
#     ~/Library/LaunchAgents + /Library/LaunchAgents + /Library/LaunchDaemons
#     ~/Library/Containers
#     ~/Library/Logs + /Library/Logs
# =============================================================================
run_uninstaller() {
    printf '\n'
    printf "  ${BLU}┌─────────────────────────────────────────────────┐${NC}\n"
    printf "  ${BLU}│  Uninstaller                                    │${NC}\n"
    printf "  ${BLU}└─────────────────────────────────────────────────┘${NC}\n\n"
    printf "  ${CYN}App or package name to search (case-insensitive): ${NC}"

    local search_name
    read -r search_name
    # trim surrounding whitespace
    search_name="${search_name#"${search_name%%[! ]*}"}"
    search_name="${search_name%"${search_name##*[! ]}"}"

    if [[ -z $search_name ]]; then
        warn "No name entered — returning to menu."
        echo; return
    fi

    say "Searching for: \"$search_name\""
    echo

    # ── result arrays + dedup set ────────────────────────────────────────────
    local -a _paths=() _types=() _cmds=()
    local -a _seen=()   # tracks recorded paths to avoid duplicates

    _record() {   # type  path  remove_cmd
        local _t="$1" _p="$2" _c="$3"
        local _s; for _s in "${_seen[@]:-}"; do [[ "$_s" == "$_p" ]] && return; done
        _seen+=("$_p"); _types+=("$_t"); _paths+=("$_p"); _cmds+=("$_c")
    }

    # ── safe single-quote escape for paths used inside eval strings ──────────
    _sq() { printf '%s' "${1//\'/\'\\\'\'}"; }   # foo'bar → foo'\''bar

    # ── collect extra search terms from discovered .app bundles ─────────────
    # Populated during step 1; used in steps 8-13 so support files named by
    # bundle-ID (e.g. com.logi.optionsplus) are found when the user searches
    # by display name (e.g. "Logi Options+").
    local -a _extra_terms=()

    # ── 1. .app bundles ──────────────────────────────────────────────────────
    # Search by BOTH filesystem name (find) and Spotlight display name (mdfind)
    # so apps whose bundle folder name differs from their Finder name are found.
    step "[.app bundles]"
    local p

    _process_app_bundle() {
        local bundle="$1"
        [[ -d $bundle ]] || return
        local info="${bundle}/Contents/Info.plist"
        local bid exec_name
        bid=$(defaults  read "${bundle}/Contents/Info" CFBundleIdentifier 2>/dev/null || true)
        exec_name=$(defaults read "${bundle}/Contents/Info" CFBundleExecutable  2>/dev/null \
                    || basename "$bundle" .app)

        local sq_bundle; sq_bundle=$(_sq "$bundle")
        local sq_exec;   sq_exec=$(_sq "$exec_name")

        # Kill running processes, then delete the bundle
        _record "macOS App" "$bundle" \
            "pkill -xi '$sq_exec' 2>/dev/null; pkill -f '$sq_bundle' 2>/dev/null; sudo rm -rf '$sq_bundle'"

        # Stash bundle-ID and filesystem name so steps 8-13 can search by them.
        # We intentionally do NOT add the vendor prefix (e.g. "google", "apple")
        # because it is far too broad and would surface unrelated apps.
        if [[ -n $bid ]]; then
            _extra_terms+=("$bid")
        fi
        local fs_name; fs_name=$(basename "$bundle" .app)
        [[ -n $fs_name ]] && _extra_terms+=("$fs_name")
    }

    # filesystem name search
    while IFS= read -r p; do
        [[ -n $p ]] && _process_app_bundle "$p"
    done < <(find /Applications ~/Applications /System/Applications \
        -maxdepth 3 -iname "*${search_name}*" -name "*.app" -type d 2>/dev/null)

    # Spotlight display-name search (catches apps like "Logi Options+"
    # whose folder on disk is logioptionsplus.app)
    if command -v mdfind &>/dev/null; then
        while IFS= read -r p; do
            [[ -n $p && -d $p ]] && _process_app_bundle "$p"
        done < <(mdfind \
            "kMDItemContentType == 'com.apple.application-bundle' \
             && kMDItemDisplayName == '*${search_name}*'cd" 2>/dev/null)
    fi

    unset -f _process_app_bundle

    # ── 2. Homebrew ──────────────────────────────────────────────────────────
    step "[Homebrew formulae and casks]"
    if command -v brew &>/dev/null; then
        local f
        while IFS= read -r f; do
            [[ -n $f ]] && _record "Homebrew formula" "$f" "brew uninstall '$(_sq "$f")'"
        done < <(brew list --formula 2>/dev/null | grep -i "$search_name")
        while IFS= read -r f; do
            [[ -n $f ]] && _record "Homebrew cask" "$f" "brew uninstall --cask '$(_sq "$f")'"
        done < <(brew list --cask 2>/dev/null | grep -i "$search_name")
    fi

    # ── 3. CLI binaries ──────────────────────────────────────────────────────
    step "[CLI binaries]"
    local bin_dir
    for bin_dir in /opt/homebrew/bin /opt/homebrew/sbin \
                   /usr/local/bin /usr/local/sbin \
                   "$HOME/.local/bin" "$HOME/bin"; do
        [[ -d $bin_dir ]] || continue
        while IFS= read -r p; do
            [[ -n $p ]] && _record "Binary" "$p" "rm -f '$(_sq "$p")'"
        done < <(find "$bin_dir" -maxdepth 1 -iname "*${search_name}*" 2>/dev/null)
    done

    # ── 4. npm global packages ───────────────────────────────────────────────
    step "[npm global packages]"
    if command -v npm &>/dev/null; then
        local pkg
        while IFS= read -r pkg; do
            [[ -n $pkg ]] && _record "npm global" "$pkg" "npm uninstall -g '$(_sq "$pkg")'"
        done < <(npm list -g --depth=0 2>/dev/null \
            | grep -i "$search_name" | awk -F@ '{print $1}' | awk '{print $NF}')
    fi

    # ── 5. pip packages ──────────────────────────────────────────────────────
    step "[pip packages]"
    local pip_cmd
    for pip_cmd in pip3 pip; do
        command -v "$pip_cmd" &>/dev/null || continue
        if $pip_cmd show "$search_name" &>/dev/null; then
            _record "Python ($pip_cmd)" "$search_name" \
                    "$pip_cmd uninstall -y '$(_sq "$search_name")'"
            break
        fi
    done

    # ── 6. Cargo binaries ────────────────────────────────────────────────────
    step "[Cargo binaries]"
    if [[ -d $HOME/.cargo/bin ]]; then
        while IFS= read -r p; do
            [[ -n $p ]] && _record "Cargo binary" "$p" \
                "cargo uninstall '$(_sq "$(basename "$p")")'"
        done < <(find "$HOME/.cargo/bin" -maxdepth 1 \
            -iname "*${search_name}*" 2>/dev/null)
    fi

    # ── 7. RubyGems ──────────────────────────────────────────────────────────
    step "[RubyGems]"
    if command -v gem &>/dev/null; then
        local gem_name
        while IFS= read -r gem_name; do
            [[ -n $gem_name ]] && _record "RubyGem" "$gem_name" \
                "gem uninstall -a '$(_sq "$gem_name")'"
        done < <(gem list 2>/dev/null | grep -i "$search_name" | awk '{print $1}')
    fi

    # ── Helper: search a set of directories for a term ───────────────────────
    # _search_dirs TYPE RM_CMD MAXDEPTH TERM DIR...
    _search_dirs() {
        local _type="$1" _rm="$2" _depth="$3" _term="$4"; shift 4
        local _d _q
        for _d in "$@"; do
            [[ -d $_d ]] || continue
            while IFS= read -r p; do
                [[ -n $p ]] || continue
                _q=$(_sq "$p")
                _record "$_type" "$p" "${_rm//__PATH__/$_q}"
            done < <(find "$_d" -maxdepth "$_depth" -iname "*${_term}*" 2>/dev/null)
        done
    }

    # ── Build full term list: user query + bundle IDs found in step 1 ────────
    local -a _all_terms=("$search_name")
    local _t; for _t in "${_extra_terms[@]:-}"; do _all_terms+=("$_t"); done

    # ── 8. Application Support ───────────────────────────────────────────────
    step "[Application Support]"
    for _t in "${_all_terms[@]}"; do
        _search_dirs "App Support" "rm -rf '__PATH__'" 1 "$_t" \
            "$HOME/Library/Application Support" "/Library/Application Support"
    done

    # ── 9. Preferences ───────────────────────────────────────────────────────
    step "[Preferences]"
    for _t in "${_all_terms[@]}"; do
        _search_dirs "Preference" "rm -f '__PATH__'" 1 "$_t" \
            "$HOME/Library/Preferences" "/Library/Preferences"
    done

    # ── 10. Caches ───────────────────────────────────────────────────────────
    step "[Caches]"
    for _t in "${_all_terms[@]}"; do
        _search_dirs "Cache" "rm -rf '__PATH__'" 1 "$_t" \
            "$HOME/Library/Caches" "/Library/Caches"
    done

    # ── 11. LaunchAgents / LaunchDaemons ─────────────────────────────────────
    step "[LaunchAgents / LaunchDaemons]"
    for _t in "${_all_terms[@]}"; do
        _search_dirs "Launch plist" \
            "sudo launchctl unload '__PATH__' 2>/dev/null; sudo rm -f '__PATH__'" \
            1 "$_t" \
            "$HOME/Library/LaunchAgents" "/Library/LaunchAgents" "/Library/LaunchDaemons"
    done

    # ── 12. Containers ───────────────────────────────────────────────────────
    step "[Containers]"
    for _t in "${_all_terms[@]}"; do
        _search_dirs "Container" "rm -rf '__PATH__'" 1 "$_t" \
            "$HOME/Library/Containers"
    done

    # ── 13. Logs ─────────────────────────────────────────────────────────────
    step "[Logs]"
    for _t in "${_all_terms[@]}"; do
        _search_dirs "Log dir" "rm -rf '__PATH__'" 1 "$_t" \
            "$HOME/Library/Logs" "/Library/Logs"
    done

    unset -f _search_dirs _sq

    # ── Display results ───────────────────────────────────────────────────────
    echo
    local -i total=${#_paths[@]}

    if (( total == 0 )); then
        warn "Nothing found for \"$search_name\"."
        echo; return
    fi

    say "Found ${total} item(s) matching \"${search_name}\":"
    echo
    printf "  ${DIM}  #   %-20s  %-8s  %s${NC}\n" "TYPE" "SIZE" "PATH"
    printf "  ${DIM}  ─   ────────────────────  ────────  $(printf '─%.0s' {1..50})${NC}\n"

    local -i i
    local sz
    for (( i=0; i<total; i++ )); do
        sz=''
        [[ -e ${_paths[i]} ]] && sz=$(du -sh "${_paths[i]}" 2>/dev/null | awk '{print $1}')
        printf "  ${CYN}[%2d]${NC}  %-20s  ${DIM}%-8s${NC}  %s\n" \
            "$(( i+1 ))" "${_types[i]}" "${sz:----}" "${_paths[i]}"
    done

    echo
    printf "  ${YLW}Remove all ${total} items? [y/N]  or enter numbers e.g. \"1 3 5\": ${NC}"
    local answer
    read -r answer

    # ── determine which indices to act on ────────────────────────────────────
    local -a to_remove=()
    if [[ $answer == [yY] ]]; then
        for (( i=0; i<total; i++ )); do to_remove+=("$i"); done
    elif [[ -n $answer ]]; then
        local num
        for num in $answer; do
            if [[ $num =~ ^[0-9]+$ ]] && (( num >= 1 && num <= total )); then
                to_remove+=("$(( num-1 ))")
            fi
        done
    fi

    if (( ${#to_remove[@]} == 0 )); then
        info "Nothing removed — returning to menu."
        echo; return
    fi

    echo
    say "Removing ${#to_remove[@]} item(s)…"
    echo

    local -i removed=0 failed=0 rc
    for i in "${to_remove[@]}"; do
        step "[${_types[i]}]  ${_paths[i]}"
        info "cmd : ${_cmds[i]}"
        rc=0
        eval "${_cmds[i]}" >/dev/null 2>&1 || rc=$?
        if (( rc == 0 )); then
            (( removed++ ))
            ok "removed ← ${_paths[i]}"
        else
            (( failed++ ))
            warn "failed (exit=${rc}) ← ${_paths[i]}"
        fi
        echo
    done

    say "Done — removed: ${removed}   failed: ${failed}"
    echo

    # unset local helper so it doesn't leak into global scope
    unset -f _record
}

# =============================================================================
# § show_main_menu
#
#   Entry point for the script. Shows the three-item main menu and dispatches
#   to run_clean, run_uninstaller, or exit based on user selection.
#   After run_uninstaller completes, the menu is shown again so the user can
#   uninstall multiple items or switch to another action.
# =============================================================================
show_main_menu() {
    clear 2>/dev/null || true

    printf '\n'
    printf "  ${BLU}╔══════════════════════════════════════════════════════╗${NC}\n"
    printf "  ${BLU}║   macOS Cleaner  ·  v1.0.0                          ║${NC}\n"
    printf "  ${BLU}╠══════════════════════════════════════════════════════╣${NC}\n"
    printf "  ${BLU}║   Safe disk-space cleaner for developers             ║${NC}\n"
    printf "  ${BLU}║   Disk: %-44s║${NC}\n" "$(disk_free)"
    printf "  ${BLU}╚══════════════════════════════════════════════════════╝${NC}\n"

    local -a items=(
        "Run full cleanup   (caches · logs · package stores · Trash)"
        "Uninstall an app or package"
        "Exit"
    )

    MENU_RESULT=2
    interactive_menu "What would you like to do?" "${items[@]}"

    printf '\n'
    case $MENU_RESULT in
        0) run_clean ;;
        1) run_uninstaller; show_main_menu ;;
        *) say "Bye."; printf '\n'; exit 0 ;;
    esac
}

# =============================================================================
# § run_clean
#
#   Full cleanup flow — all 28 sections.
#   Called from show_main_menu when the user selects option 1.
# =============================================================================
run_clean() {

# =============================================================================
# § STARTUP BANNER
# =============================================================================
echo
say "macOS cleaner starting…"
info "user      : $USER"
info "host      : $(hostname)"
info "date      : $(date '+%Y-%m-%d %H:%M:%S %Z')"
info "bash      : $BASH_VERSION"
info "log       : $LOG_FILE"
info "timeouts  : cmd=${CMD_TIMEOUT}s  dir=${DIR_TIMEOUT}s  scan=${SCAN_TIMEOUT}s"
[[ -n $_TIMEOUT_BIN ]] && info "timeout bin: $_TIMEOUT_BIN" \
                       || info "timeout bin: pure-bash fallback"
say "Disk before: $(disk_free)"

# =============================================================================
# § 0 · PRE-RUN DISK USAGE REPORT  (informational — nothing deleted)
# =============================================================================
section "0 · PRE-RUN DISK USAGE REPORT"

say "Largest directories before cleanup (use these to guide manual cleanup)"
report_largest_dirs "$HOME"            "Home directory (~)"            1 30
report_largest_dirs "$HOME/Library"    "~/Library subdirectories"      1 20

# =============================================================================
# § 1 · TRASH
# =============================================================================
section "1 · TRASH"

say "Emptying Trash"
clean_dir "$HOME/.Trash" "User Trash"
for vol in /Volumes/*; do
    [[ -d "$vol/.Trashes" ]] && clean_dir "$vol/.Trashes" "Trash on $(basename "$vol")" "sudo"
done

# =============================================================================
# § 2 · USER CACHES & LOGS
# =============================================================================
section "2 · USER CACHES & LOGS"

say "User Library caches and logs"
clean_dir "$HOME/Library/Caches"                              "User Library Caches"
clean_dir "$HOME/Library/Logs"                                "User Logs"
clean_dir "$HOME/Library/Application Support/CrashReporter"  "User Crash Reports"
clean_dir "$HOME/Library/Saved Application State"             "Saved Application State"

# =============================================================================
# § 3 · BROWSER CACHES
# =============================================================================
section "3 · BROWSER CACHES"

say "Browser caches (Safari, Chrome, Firefox, Brave, Arc)"

# Safari
clean_dir "$HOME/Library/Caches/com.apple.Safari"           "Safari cache"
clean_dir "$HOME/Library/Safari/LocalStorage"                "Safari LocalStorage"

# Google Chrome
clean_dir "$HOME/Library/Caches/Google/Chrome"                                   "Chrome cache"
clean_dir "$HOME/Library/Application Support/Google/Chrome/Default/Cache"        "Chrome Default Cache"
clean_dir "$HOME/Library/Application Support/Google/Chrome/Default/Code Cache"   "Chrome Code Cache"

# Firefox
clean_dir "$HOME/Library/Caches/Firefox"                     "Firefox cache"

# Brave
clean_dir "$HOME/Library/Caches/BraveSoftware"               "Brave cache"

# Arc
clean_dir "$HOME/Library/Caches/Arc"                         "Arc cache"

# =============================================================================
# § 4 · XCODE & APPLE DEVELOPER TOOLS
# =============================================================================
section "4 · XCODE & APPLE DEVELOPER TOOLS"

say "Xcode derived data, archives, and simulator caches"
clean_dir "$HOME/Library/Developer/Xcode/DerivedData"          "Xcode DerivedData"
clean_dir "$HOME/Library/Developer/Xcode/Archives"             "Xcode Archives (old builds)"
clean_dir "$HOME/Library/Developer/Xcode/iOS DeviceSupport"    "Xcode iOS DeviceSupport"
clean_dir "$HOME/Library/Developer/CoreSimulator/Caches"       "iOS Simulator caches"

# =============================================================================
# § 5 · SWIFT PACKAGE MANAGER · COCOAPODS · CARTHAGE · MINT
# =============================================================================
section "5 · SWIFT PACKAGE MANAGER · COCOAPODS · CARTHAGE · MINT"

say "Apple/Swift ecosystem package managers"

# Swift Package Manager
clean_dir "$HOME/Library/Caches/org.swift.swiftpm"            "SPM package cache"
clean_dir "$HOME/Library/org.swift.swiftpm/security"          "SPM security cache"

# CocoaPods
if command -v pod &>/dev/null; then
    run_step "CocoaPods cache clean"  "pod cache clean --all"
fi
clean_dir "$HOME/Library/Caches/CocoaPods"                    "CocoaPods cache"

# Carthage
clean_dir "$HOME/Library/Caches/org.carthage.CarthageKit"     "Carthage cache"

# Mint (Swift CLI package manager)
clean_dir "$HOME/.mint"                                        "Mint packages"

# =============================================================================
# § 6 · HOMEBREW
# =============================================================================
section "6 · HOMEBREW"

say "Homebrew orphan deps, stale formulae, cache, and logs"
if command -v brew &>/dev/null; then
    # autoremove first — removes formulae installed only as deps that are now orphaned
    run_step "Homebrew autoremove (orphan deps)"  "brew autoremove"
    # cleanup after autoremove so it catches newly orphaned bottles
    run_step "Homebrew cleanup (prune all)"       "brew cleanup --prune=all -s"
    _brew_cache="$(brew --cache 2>/dev/null)"
    [[ -n $_brew_cache ]] && clean_dir "$_brew_cache" "Homebrew downloads cache"
    clean_dir "$HOME/Library/Logs/Homebrew" "Homebrew logs"
else
    skip_missing "Homebrew"
fi

# =============================================================================
# § 7 · JAVASCRIPT / NODE.JS PACKAGE MANAGERS
#   npm · yarn · pnpm · bun · deno · volta · nvm · fnm · turbo
# =============================================================================
section "7 · JAVASCRIPT / NODE.JS PACKAGE MANAGERS"

say "JS/Node package manager caches and stores"

# CLI cache-clean commands (only run if the tool is present)
command -v npm  &>/dev/null && run_step "npm cache clean"      "npm cache clean --force"
command -v yarn &>/dev/null && run_step "yarn cache clean"      "yarn cache clean"
command -v pnpm &>/dev/null && run_step "pnpm store prune"      "pnpm store prune"
command -v bun  &>/dev/null && run_step "bun pm cache rm"       "bun pm cache rm"
command -v deno &>/dev/null && run_step "deno clean"            "deno clean"

# Cache / store directories
clean_dir "$HOME/.npm/_cacache"              "npm content-addressable cache"
clean_dir "$HOME/.npm/_logs"                 "npm logs"
clean_dir "$HOME/.yarn/cache"                "Yarn classic cache dir"
clean_dir "$HOME/.cache/yarn"                "Yarn cache (~/.cache/yarn)"
clean_dir "$HOME/Library/Caches/Yarn"        "Yarn cache (Library)"
clean_dir "$HOME/Library/pnpm/store"         "pnpm store (Library)"
clean_dir "$HOME/.pnpm-store"                "pnpm store (alt ~/.pnpm-store)"
clean_dir "$HOME/.bun/install/cache"         "Bun install cache"
clean_dir "$HOME/.cache/deno"                "Deno cache"
clean_dir "$HOME/.volta/tmp"                 "Volta tmp"
clean_dir "$HOME/.volta/cache"               "Volta cache"
clean_dir "$HOME/.nvm/.cache"                "nvm binary cache"
clean_dir "$HOME/.cache/node-gyp"            "node-gyp build cache"
clean_dir "$HOME/.turbo"                     "Turbo global cache"
clean_dir "$HOME/.cache/turbo"               "Turbo cache (~/.cache)"
clean_dir "$HOME/.cache/Cypress"             "Cypress binary cache"
clean_dir "$HOME/Library/Caches/Cypress"     "Cypress cache (Library)"
clean_dir "$HOME/.cache/playwright"          "Playwright browser binaries cache"

# =============================================================================
# § 8 · JAVASCRIPT / NODE.JS PROJECT-LEVEL CACHES
#   .next/cache · .turbo · .parcel-cache · jest · eslintcache · tsbuildinfo
# =============================================================================
section "8 · JAVASCRIPT / NODE.JS PROJECT-LEVEL CACHES"

say "Scanning project directories for JS build artefact caches"

_scan_and_delete \
    "JS project cache dirs (.next/cache .turbo .parcel-cache jest_cache)" \
    "JS_SCAN_ROOTS" \
    ".next/cache, .turbo, .parcel-cache, jest_cache" \
    \( -type d \( \
        -name ".parcel-cache" \
        -o -name "jest_cache"  \
        -o -name ".turbo"      \
    \) \)

_scan_and_delete \
    "JS project cache files (.eslintcache .stylelintcache *.tsbuildinfo)" \
    "JS_SCAN_ROOTS" \
    ".eslintcache, .stylelintcache, *.tsbuildinfo" \
    \( -type f \( \
        -name ".eslintcache"    \
        -o -name ".stylelintcache" \
        -o -name "*.tsbuildinfo"   \
    \) \)

# =============================================================================
# § 9 · PYTHON PACKAGE MANAGERS
#   pip · uv · poetry · pipenv · hatch · pdm · pyenv · conda / mamba
# =============================================================================
section "9 · PYTHON PACKAGE MANAGERS"

say "Python tooling caches"

# CLI purge commands
command -v pip   &>/dev/null && run_step "pip cache purge"      "pip cache purge"
command -v pip3  &>/dev/null && run_step "pip3 cache purge"     "pip3 cache purge"
command -v uv    &>/dev/null && run_step "uv cache clean"       "uv cache clean"
command -v conda &>/dev/null && run_step "conda clean --all"    "conda clean --all --yes"

# pip
clean_dir "$HOME/.cache/pip"               "pip cache (~/.cache/pip)"
clean_dir "$HOME/Library/Caches/pip"       "pip cache (Library)"

# uv
clean_dir "$HOME/.cache/uv"                "uv cache"

# Poetry
clean_dir "$HOME/.cache/pypoetry"          "Poetry cache (~/.cache)"
clean_dir "$HOME/Library/Caches/pypoetry"  "Poetry cache (Library)"

# pipenv
clean_dir "$HOME/.cache/pipenv"            "pipenv cache"

# Hatch
clean_dir "$HOME/.cache/hatch"             "Hatch cache"

# PDM
clean_dir "$HOME/.cache/pdm"               "PDM cache"

# virtualenv seed cache
clean_dir "$HOME/.cache/virtualenv"        "virtualenv seed cache"

# pyenv build cache
clean_dir "$HOME/.pyenv/cache"             "pyenv build artefacts"

# pypa generic cache (pip, build, etc.)
clean_dir "$HOME/Library/Caches/pypa"     "pypa cache (Library)"

# Conda / Anaconda / Miniconda / Miniforge / Mambaforge
clean_dir "$HOME/.conda/pkgs"              "conda pkgs (~/.conda)"
clean_dir "$HOME/anaconda3/pkgs"           "Anaconda3 pkgs"
clean_dir "$HOME/miniconda3/pkgs"          "Miniconda3 pkgs"
clean_dir "$HOME/miniforge3/pkgs"          "Miniforge3 pkgs"
clean_dir "$HOME/mambaforge/pkgs"          "Mambaforge pkgs"
clean_dir "$HOME/opt/anaconda3/pkgs"       "Anaconda3 pkgs (opt)"
clean_dir "$HOME/opt/miniconda3/pkgs"      "Miniconda3 pkgs (opt)"

# =============================================================================
# § 10 · PYTHON PROJECT-LEVEL CACHES
#   __pycache__ · .pytest_cache · .mypy_cache · .ruff_cache
# =============================================================================
section "10 · PYTHON PROJECT-LEVEL CACHES"

say "Scanning project directories for Python bytecode and tool caches"

_scan_and_delete \
    "Python project caches (__pycache__ .pytest_cache .mypy_cache .ruff_cache)" \
    "PY_SCAN_ROOTS" \
    "__pycache__, .pytest_cache, .mypy_cache, .ruff_cache" \
    \( -type d \( \
        -name "__pycache__"   \
        -o -name ".pytest_cache" \
        -o -name ".mypy_cache"   \
        -o -name ".ruff_cache"   \
    \) \)

# =============================================================================
# § 11 · GO
# =============================================================================
section "11 · GO"

say "Go build, module, test, and fuzz caches"
if command -v go &>/dev/null; then
    run_step "go clean -cache"     "go clean -cache"
    run_step "go clean -modcache"  "go clean -modcache"
    run_step "go clean -testcache" "go clean -testcache"
    run_step "go clean -fuzzcache" "go clean -fuzzcache"
else
    skip_missing "go"
fi
# macOS stores the Go build cache under Library/Caches; also clean directly
clean_dir "$HOME/Library/Caches/go-build"  "Go build cache (Library/Caches)"
clean_dir "$HOME/go/pkg/mod/cache"          "Go module download cache"

# =============================================================================
# § 12 · RUST  (cargo · rustup · sccache)
# =============================================================================
section "12 · RUST"

say "Cargo registry, git, rustup, and sccache"
if command -v cargo &>/dev/null; then
    clean_dir "$HOME/.cargo/registry/cache"   "Cargo registry cache (tarballs)"
    clean_dir "$HOME/.cargo/registry/src"     "Cargo registry sources (extracted)"
    clean_dir "$HOME/.cargo/git/checkouts"    "Cargo git checkouts"
    clean_dir "$HOME/.cargo/git/db"           "Cargo git databases"
else
    skip_missing "cargo"
fi
clean_dir "$HOME/.rustup/tmp"                 "rustup temp downloads"
clean_dir "$HOME/.cache/sccache"              "sccache (~/.cache)"
clean_dir "$HOME/Library/Caches/Mozilla.sccache" "sccache (Library/Caches)"

# =============================================================================
# § 13 · C / C++  (ccache · Conan v1/v2 · vcpkg)
# =============================================================================
section "13 · C / C++"

say "ccache, Conan, and vcpkg caches"

# ccache — compiler cache
if command -v ccache &>/dev/null; then
    run_step "ccache --clear"  "ccache --clear"
fi
clean_dir "$HOME/.ccache"                   "ccache (~/.ccache)"
clean_dir "$HOME/.cache/ccache"             "ccache (~/.cache/ccache)"
clean_dir "$HOME/Library/Caches/ccache"     "ccache (Library/Caches)"

# Conan v1
clean_dir "$HOME/.conan/data"               "Conan v1 package data"

# Conan v2
clean_dir "$HOME/.conan2/p"                 "Conan v2 package cache"
clean_dir "$HOME/.conan2/tmp"               "Conan v2 tmp"

# vcpkg
clean_dir "$HOME/.vcpkg/downloads"          "vcpkg downloads"
clean_dir "$HOME/.vcpkg/buildtrees"         "vcpkg buildtrees"
clean_dir "$HOME/.vcpkg/packages"           "vcpkg staged packages"

# =============================================================================
# § 14 · RUBY  (gem · bundler)
# =============================================================================
section "14 · RUBY"

say "RubyGems and Bundler caches"
if command -v gem &>/dev/null; then
    run_step "gem cleanup"  "gem cleanup"
fi
clean_dir "$HOME/.bundle/cache"             "Bundler cache"

# =============================================================================
# § 15 · PHP  (Composer · PHP-CS-Fixer · PHPStan · Psalm)
# =============================================================================
section "15 · PHP"

say "PHP package manager and static-analysis caches"

# Composer (all three possible cache locations on macOS)
clean_dir "$HOME/.composer/cache"            "Composer cache (~/.composer)"
clean_dir "$HOME/.composer/tmp"              "Composer tmp"
clean_dir "$HOME/.config/composer/cache"     "Composer cache (XDG)"
clean_dir "$HOME/.cache/composer"            "Composer cache (~/.cache)"

# PHP static analysis result caches
clean_dir "$HOME/.cache/phpstan"             "PHPStan result cache"
clean_dir "/tmp/phpstan"                     "PHPStan /tmp cache"
clean_dir "$HOME/.cache/psalm"               "Psalm result cache"

if command -v php-cs-fixer &>/dev/null; then
    run_step "PHP-CS-Fixer cache clear"  "php-cs-fixer clear-cache"
fi

# =============================================================================
# § 16 · .NET  (NuGet)
# =============================================================================
section "16 · .NET"

say ".NET NuGet local caches"
if command -v dotnet &>/dev/null; then
    run_step ".NET NuGet locals --clear"  "dotnet nuget locals all --clear"
else
    skip_missing "dotnet"
fi

# =============================================================================
# § 17 · JAVA · JVM · KOTLIN · SPRING  (Maven · Gradle · SBT · Ivy · SDKMAN)
# =============================================================================
section "17 · JAVA · JVM · KOTLIN · SPRING"

say "Maven, Gradle, SBT, Ivy2, Kotlin, Spring, and SDKMAN caches"

# Gradle
clean_dir "$HOME/.gradle/caches"             "Gradle caches"
clean_dir "$HOME/.gradle/daemon"             "Gradle daemon logs"
clean_dir "$HOME/.gradle/wrapper/dists"      "Gradle wrapper distributions"

# Maven
clean_dir "$HOME/.m2/repository/.cache"      "Maven .m2 metadata cache"
clean_dir "$HOME/.m2/tmp"                    "Maven tmp"
clean_dir "$HOME/.m2/wrapper/dists"          "Maven wrapper distributions"

# Ivy2 / SBT
clean_dir "$HOME/.ivy2/cache"               "Ivy2 / SBT cache"
clean_dir "$HOME/.sbt/boot"                 "SBT boot cache"

# Kotlin
clean_dir "$HOME/.kotlin/daemon"             "Kotlin compiler daemon"
clean_dir "$HOME/.konan/cache"               "Kotlin/Native cache"
clean_dir "$HOME/.konan/tmp"                 "Kotlin/Native tmp"

# Spring Boot DevTools remote restart cache
clean_dir "$HOME/.spring-boot-devtools"      "Spring Boot DevTools"

# SDKMAN
if [[ -d $HOME/.sdkman ]]; then
    clean_dir "$HOME/.sdkman/tmp"            "SDKMAN tmp"
    clean_dir "$HOME/.sdkman/archives"       "SDKMAN archives"
fi

# =============================================================================
# § 18 · ANDROID  (SDK cache · build cache)
# =============================================================================
section "18 · ANDROID"

say "Android SDK and incremental build caches"
clean_dir "$HOME/.android/cache"             "Android SDK cache"
clean_dir "$HOME/.android/build-cache"       "Android incremental build cache"

# =============================================================================
# § 19 · DOCKER
# =============================================================================
section "19 · DOCKER"

say "Docker build, layer, and image caches"
if command -v docker &>/dev/null; then
    if docker info &>/dev/null 2>&1; then
        # -a  removes ALL unused images, not just dangling ones (much more space freed)
        run_step "docker system prune -a"   "docker system prune -af"
        run_step "docker buildx prune"      "docker buildx prune -f"

        # --volumes removes unnamed volumes — opt-in only because named volumes may
        # hold database data (postgres, mysql, redis) that the user wants to keep.
        step "[Docker volume prune  (opt-in)]"
        info "cmd     : docker volume prune -f"
        info "WARNING : This removes ALL unnamed Docker volumes."
        info "          Named volumes (databases, persistent data) are NOT affected."
        if [[ -t 0 ]]; then   # only prompt when stdin is a terminal
            printf '    Prune unnamed Docker volumes? [y/N] '
            read -r _docker_vol_ans
            if [[ $_docker_vol_ans == [yY] ]]; then
                run_step "docker volume prune" "docker volume prune -f"
            else
                info "status  : skipped by user"
                echo
            fi
        else
            info "status  : non-interactive — skipped (run manually: docker volume prune -f)"
            echo
        fi
    else
        step "[Docker]"; info "status  : daemon not running — skipping"; echo
    fi
else
    skip_missing "Docker"
fi

# =============================================================================
# § 20 · INFRA / CLOUD / DEVOPS
#   Terraform · Pulumi · Ansible · kubectl · minikube · AWS · GCP · Azure · Vagrant
# =============================================================================
section "20 · INFRA / CLOUD / DEVOPS"

say "Infrastructure tooling caches and logs"

clean_dir "$HOME/.terraform.d/plugin-cache"   "Terraform plugin cache"
clean_dir "$HOME/.pulumi/plugins"             "Pulumi plugins (will re-download)"
clean_dir "$HOME/.ansible/tmp"                "Ansible tmp"
clean_dir "$HOME/.kube/cache"                 "kubectl cache"
clean_dir "$HOME/.kube/http-cache"            "kubectl http-cache"
clean_dir "$HOME/.minikube/cache"             "minikube cache"
clean_dir "$HOME/.aws/cli/cache"              "AWS CLI cache"
clean_dir "$HOME/.config/gcloud/logs"         "gcloud logs"
clean_dir "$HOME/.azure/logs"                 "Azure CLI logs"
clean_dir "$HOME/.vagrant.d/tmp"              "Vagrant tmp"

# =============================================================================
# § 21 · LOCAL DATABASE DEV  (Postgres.app · DBngin · Redis)
#   Logs only — data directories are never touched.
# =============================================================================
section "21 · LOCAL DATABASE DEV"

say "Database app logs (data directories skipped)"
clean_dir "$HOME/Library/Application Support/Postgres/var-*/log"  "Postgres.app logs"
clean_dir "$HOME/.dbngin/logs"                                     "DBngin logs"
clean_dir "$HOME/Library/Logs/redis"                               "Redis logs"

# =============================================================================
# § 22 · CODE EDITORS & IDEs
#   VS Code · Cursor · Windsurf · JetBrains · Sublime · Zed · Nova · Atom
# =============================================================================
section "22 · CODE EDITORS & IDEs"

say "IDE and editor caches, compiled extension data, and logs"

# ── VS Code (stable) ─────────────────────────────────────────────────────────
clean_dir "$HOME/Library/Application Support/Code/Cache"                  "VS Code Cache"
clean_dir "$HOME/Library/Application Support/Code/CachedData"             "VS Code CachedData"
clean_dir "$HOME/Library/Application Support/Code/CachedExtensions"       "VS Code CachedExtensions"
clean_dir "$HOME/Library/Application Support/Code/CachedExtensionVSIXs"   "VS Code Extension VSIXs"
clean_dir "$HOME/Library/Application Support/Code/Code Cache"             "VS Code Code Cache"
clean_dir "$HOME/Library/Application Support/Code/GPUCache"               "VS Code GPUCache"
clean_dir "$HOME/Library/Application Support/Code/logs"                   "VS Code logs"
clean_dir "$HOME/Library/Application Support/Code/CachedProfilesData"     "VS Code Profiles Data"
clean_dir "$HOME/Library/Application Support/Code/User/workspaceStorage"  "VS Code workspace storage"
clean_dir "$HOME/Library/Caches/com.microsoft.VSCode"                     "VS Code (Library)"
clean_dir "$HOME/Library/Caches/com.microsoft.VSCode.ShipIt"              "VS Code updater"

# ── VS Code Insiders ─────────────────────────────────────────────────────────
clean_dir "$HOME/Library/Application Support/Code - Insiders/Cache"       "VS Code Insiders Cache"
clean_dir "$HOME/Library/Application Support/Code - Insiders/CachedData"  "VS Code Insiders CachedData"
clean_dir "$HOME/Library/Application Support/Code - Insiders/Code Cache"  "VS Code Insiders Code Cache"
clean_dir "$HOME/Library/Application Support/Code - Insiders/GPUCache"    "VS Code Insiders GPUCache"
clean_dir "$HOME/Library/Application Support/Code - Insiders/logs"        "VS Code Insiders logs"

# ── Cursor ───────────────────────────────────────────────────────────────────
clean_dir "$HOME/Library/Application Support/Cursor/Cache"                "Cursor Cache"
clean_dir "$HOME/Library/Application Support/Cursor/CachedData"           "Cursor CachedData"
clean_dir "$HOME/Library/Application Support/Cursor/Code Cache"           "Cursor Code Cache"
clean_dir "$HOME/Library/Application Support/Cursor/GPUCache"             "Cursor GPUCache"
clean_dir "$HOME/Library/Application Support/Cursor/logs"                 "Cursor logs"
clean_dir "$HOME/Library/Caches/com.todesktop.230313mzl4w4u92"            "Cursor (Library)"

# ── Windsurf ─────────────────────────────────────────────────────────────────
clean_dir "$HOME/Library/Application Support/Windsurf/Cache"              "Windsurf Cache"
clean_dir "$HOME/Library/Application Support/Windsurf/CachedData"         "Windsurf CachedData"
clean_dir "$HOME/Library/Application Support/Windsurf/Code Cache"         "Windsurf Code Cache"
clean_dir "$HOME/Library/Application Support/Windsurf/GPUCache"           "Windsurf GPUCache"
clean_dir "$HOME/Library/Application Support/Windsurf/logs"               "Windsurf logs"

# ── JetBrains (IntelliJ, WebStorm, PyCharm, GoLand, CLion …) ────────────────
clean_dir "$HOME/Library/Caches/JetBrains"                                "JetBrains caches (all IDEs)"
clean_dir "$HOME/Library/Logs/JetBrains"                                  "JetBrains logs"

# ── Sublime Text · Atom · Nova · Zed ─────────────────────────────────────────
clean_dir "$HOME/Library/Caches/com.sublimetext.4"                        "Sublime Text 4 cache"
clean_dir "$HOME/Library/Caches/com.github.atom"                          "Atom cache"
clean_dir "$HOME/Library/Caches/com.panic.Nova"                           "Nova cache"
clean_dir "$HOME/Library/Caches/dev.zed.Zed"                              "Zed cache"
clean_dir "$HOME/Library/Logs/Zed"                                        "Zed logs"

# =============================================================================
# § 23 · AI ASSISTANTS & LLM TOOLS
#   Claude · ChatGPT · Perplexity · LM Studio · Ollama · Jan · Continue.dev
#   Tabnine · Amazon Q · Sourcegraph Cody · Gemini · Warp · Mistral · Groq
#   GitHub Copilot · Raycast · llm CLI
# =============================================================================
section "23 · AI ASSISTANTS & LLM TOOLS"

say "AI assistant app caches, GPU caches, and logs"

# ── Claude (Anthropic) ───────────────────────────────────────────────────────
clean_dir "$HOME/Library/Application Support/Claude/Cache"                "Claude Cache"
clean_dir "$HOME/Library/Application Support/Claude/Code Cache"           "Claude Code Cache"
clean_dir "$HOME/Library/Application Support/Claude/GPUCache"             "Claude GPUCache"
clean_dir "$HOME/Library/Application Support/Claude/logs"                 "Claude logs"
clean_dir "$HOME/Library/Caches/com.anthropic.claudefordesktop"           "Claude desktop (Library)"
clean_dir "$HOME/Library/Logs/Claude"                                     "Claude logs (Library)"

# ── ChatGPT (OpenAI) ─────────────────────────────────────────────────────────
clean_dir "$HOME/Library/Application Support/ChatGPT/Cache"               "ChatGPT Cache"
clean_dir "$HOME/Library/Application Support/ChatGPT/Code Cache"          "ChatGPT Code Cache"
clean_dir "$HOME/Library/Application Support/ChatGPT/GPUCache"            "ChatGPT GPUCache"
clean_dir "$HOME/Library/Application Support/ChatGPT/logs"                "ChatGPT logs"
clean_dir "$HOME/Library/Caches/com.openai.chat"                          "ChatGPT (Library)"
clean_dir "$HOME/Library/Logs/ChatGPT"                                    "ChatGPT logs (Library)"

# ── Perplexity ───────────────────────────────────────────────────────────────
clean_dir "$HOME/Library/Application Support/Perplexity/Cache"            "Perplexity Cache"
clean_dir "$HOME/Library/Application Support/Perplexity/Code Cache"       "Perplexity Code Cache"
clean_dir "$HOME/Library/Application Support/Perplexity/GPUCache"         "Perplexity GPUCache"
clean_dir "$HOME/Library/Caches/ai.perplexity.mac"                        "Perplexity (Library)"

# ── LM Studio ────────────────────────────────────────────────────────────────
# NOTE: ~/.cache/lm-studio/models intentionally skipped (user-downloaded models)
clean_dir "$HOME/Library/Application Support/LM Studio/Cache"             "LM Studio Cache"
clean_dir "$HOME/Library/Application Support/LM Studio/Code Cache"        "LM Studio Code Cache"
clean_dir "$HOME/Library/Application Support/LM Studio/GPUCache"          "LM Studio GPUCache"
clean_dir "$HOME/Library/Application Support/LM Studio/logs"              "LM Studio logs"
clean_dir "$HOME/Library/Caches/ai.lmstudio.app"                          "LM Studio (Library)"

# ── Ollama ───────────────────────────────────────────────────────────────────
# NOTE: ~/.ollama/models intentionally skipped (user-downloaded weights)
clean_dir "$HOME/.ollama/logs"                                             "Ollama logs"
clean_dir "$HOME/.ollama/history"                                          "Ollama history"
clean_dir "$HOME/Library/Logs/Ollama"                                     "Ollama logs (Library)"

# ── Jan AI ───────────────────────────────────────────────────────────────────
clean_dir "$HOME/Library/Application Support/jan/Cache"                   "Jan AI Cache"
clean_dir "$HOME/Library/Application Support/jan/Code Cache"              "Jan AI Code Cache"
clean_dir "$HOME/Library/Application Support/jan/GPUCache"                "Jan AI GPUCache"
clean_dir "$HOME/Library/Application Support/jan/logs"                    "Jan AI logs"
clean_dir "$HOME/Library/Caches/jan-app"                                  "Jan AI (Library)"

# ── Continue.dev (IDE extension) ─────────────────────────────────────────────
clean_dir "$HOME/.continue/logs"                                           "Continue.dev logs"
clean_dir "$HOME/Library/Application Support/continue.Continue/Cache"     "Continue.dev Cache"
clean_dir "$HOME/Library/Application Support/continue.Continue/logs"      "Continue.dev logs (Library)"

# ── Tabnine ──────────────────────────────────────────────────────────────────
clean_dir "$HOME/Library/Application Support/TabNine/Cache"               "Tabnine Cache"
clean_dir "$HOME/Library/Application Support/TabNine/Code Cache"          "Tabnine Code Cache"
clean_dir "$HOME/Library/Application Support/TabNine/GPUCache"            "Tabnine GPUCache"
clean_dir "$HOME/Library/Caches/TabNine"                                  "Tabnine (Library)"
clean_dir "$HOME/.tabnine"                                                 "Tabnine home dir cache"

# ── Amazon Q / CodeWhisperer ─────────────────────────────────────────────────
clean_dir "$HOME/Library/Application Support/Amazon Q/Cache"              "Amazon Q Cache"
clean_dir "$HOME/Library/Application Support/Amazon Q/Code Cache"         "Amazon Q Code Cache"
clean_dir "$HOME/Library/Application Support/Amazon Q/GPUCache"           "Amazon Q GPUCache"
clean_dir "$HOME/Library/Application Support/Amazon Q/logs"               "Amazon Q logs"
clean_dir "$HOME/Library/Caches/com.amazon.codewhisperer"                 "CodeWhisperer (Library)"

# ── Sourcegraph Cody ─────────────────────────────────────────────────────────
clean_dir "$HOME/Library/Application Support/Cody/Cache"                  "Cody Cache"
clean_dir "$HOME/Library/Application Support/Cody/Code Cache"             "Cody Code Cache"
clean_dir "$HOME/Library/Application Support/Cody/GPUCache"               "Cody GPUCache"
clean_dir "$HOME/Library/Application Support/Cody/logs"                   "Cody logs"
clean_dir "$HOME/Library/Caches/com.sourcegraph.cody"                     "Cody (Library)"

# ── Gemini (Google AI) ───────────────────────────────────────────────────────
clean_dir "$HOME/Library/Application Support/Gemini/Cache"                "Gemini Cache"
clean_dir "$HOME/Library/Application Support/Gemini/Code Cache"           "Gemini Code Cache"
clean_dir "$HOME/Library/Application Support/Gemini/GPUCache"             "Gemini GPUCache"
clean_dir "$HOME/Library/Application Support/Gemini/logs"                 "Gemini logs"
clean_dir "$HOME/Library/Caches/com.google.Gemini"                        "Gemini (Library)"

# ── Warp (AI-native terminal) ────────────────────────────────────────────────
clean_dir "$HOME/Library/Application Support/dev.warp.Warp-Stable/Cache"       "Warp Cache"
clean_dir "$HOME/Library/Application Support/dev.warp.Warp-Stable/Code Cache"  "Warp Code Cache"
clean_dir "$HOME/Library/Application Support/dev.warp.Warp-Stable/GPUCache"    "Warp GPUCache"
clean_dir "$HOME/Library/Application Support/dev.warp.Warp-Stable/logs"        "Warp logs"
clean_dir "$HOME/Library/Caches/dev.warp.Warp-Stable"                          "Warp (Library)"

# ── Mistral ──────────────────────────────────────────────────────────────────
clean_dir "$HOME/Library/Application Support/Mistral/Cache"               "Mistral Cache"
clean_dir "$HOME/Library/Application Support/Mistral/Code Cache"          "Mistral Code Cache"
clean_dir "$HOME/Library/Application Support/Mistral/GPUCache"            "Mistral GPUCache"
clean_dir "$HOME/Library/Application Support/Mistral/logs"                "Mistral logs"
clean_dir "$HOME/Library/Caches/ai.mistral.mac"                           "Mistral (Library)"

# ── Groq ─────────────────────────────────────────────────────────────────────
clean_dir "$HOME/Library/Application Support/Groq/Cache"                  "Groq Cache"
clean_dir "$HOME/Library/Application Support/Groq/Code Cache"             "Groq Code Cache"
clean_dir "$HOME/Library/Application Support/Groq/GPUCache"               "Groq GPUCache"
clean_dir "$HOME/Library/Caches/com.groq.app"                             "Groq (Library)"

# ── GitHub Copilot · Raycast ─────────────────────────────────────────────────
clean_dir "$HOME/Library/Application Support/GitHub Copilot/logs"         "GitHub Copilot logs"
clean_dir "$HOME/Library/Caches/com.raycast.macos"                        "Raycast cache"

# ── llm CLI (Simon Willison) / llama.cpp ─────────────────────────────────────
# llama.cpp has no persistent global cache; llm CLI stores logs here:
clean_dir "$HOME/Library/Application Support/io.datasette.llm/logs"       "llm CLI logs"
clean_dir "$HOME/.config/llm"                                              "llm CLI config cache"

# =============================================================================
# § 24 · MAIL & MESSAGES
# =============================================================================
section "24 · MAIL & MESSAGES"

say "Mail download caches"
clean_dir "$HOME/Library/Containers/com.apple.mail/Data/Library/Caches"  "Mail caches"

# =============================================================================
# § 25 · TIME MACHINE LOCAL SNAPSHOTS
#
#   macOS stores local "on-disk" TM snapshots so Time Machine can roll back
#   even when the backup drive is disconnected.  They can accumulate to many
#   GBs on laptops.  Deleting them is safe: your remote TM backup is untouched.
# =============================================================================
section "25 · TIME MACHINE LOCAL SNAPSHOTS"

say "Listing and deleting Time Machine local (on-disk) snapshots"
clean_tm_snapshots

# =============================================================================
# § 26 · QUICK LOOK & iOS DEVICE UPDATES
# =============================================================================
section "26 · QUICK LOOK & iOS DEVICE UPDATES"

say "Quick Look thumbnail cache and old iOS update files"
run_step "Quick Look cache regenerate"  "qlmanage -r cache"
clean_dir "$HOME/Library/iTunes/iPhone Software Updates"  "Old iOS update files"
clean_dir "$HOME/Library/iTunes/iPad Software Updates"    "Old iPadOS update files"

# =============================================================================
# § 27 · SYSTEM CACHES & LOGS  (requires sudo)
# =============================================================================
section "27 · SYSTEM CACHES & LOGS (sudo)"

say "System-level caches, ASL logs, and rotated logs"
if sudo -n true 2>/dev/null || sudo -v; then
    clean_dir "/Library/Caches" "System Library Caches"       "sudo"
    clean_dir "/Library/Logs"   "System Logs"                 "sudo"
    clean_dir "/private/var/log/asl" "Apple System Log (ASL)" "sudo"

    step "[Rotated system logs (*.gz *.[0-9])]"
    info "path    : /private/var/log"
    if sudo rm -rf /private/var/log/*.gz /private/var/log/*.[0-9] 2>/dev/null; then
        (( TOTAL_CLEANED++ ))
        ok "removed rotated system log files"
    else
        warn "no rotated logs found or removal failed"
    fi
    echo

    step "[Purge inactive memory]"
    info "cmd     : sudo purge"
    declare -i _purge_t0 _purge_t1 _purge_rc=0
    _purge_t0=$(date +%s)
    sudo purge 2>/dev/null || _purge_rc=$?
    _purge_t1=$(date +%s)
    info "elapsed : $(( _purge_t1 - _purge_t0 ))s   exit: ${_purge_rc}"
    if (( _purge_rc == 0 )); then
        (( TOTAL_CLEANED++ ))
        ok "released inactive memory back to the kernel"
    else
        warn "purge failed (exit=${_purge_rc})"
    fi
    echo
else
    warn "Skipped system-level cleanup (no sudo access)."
    echo
fi

# =============================================================================
# § 28 · OLD /tmp ITEMS  (>3 days)
# =============================================================================
section "28 · OLD /tmp ITEMS"

say "Removing items older than 3 days from /tmp directories"
clean_old_tmp "/private/tmp"        "/private/tmp"        "sudo"
clean_old_tmp "user TMPDIR"         "${TMPDIR:-/tmp}"

# =============================================================================
# § SUMMARY
# =============================================================================
section "SUMMARY"

declare -i END_TIME ELAPSED
END_TIME=$(date +%s)
(( ELAPSED = END_TIME - START_TIME )) || true

say "Post-cleanup disk usage (compare with pre-run report above)"
report_largest_dirs "$HOME"         "Home directory (~) after cleanup"   1 30
report_largest_dirs "$HOME/Library" "~/Library after cleanup"            1 20

say "════════════════════════════════════════════════════"
info "Disk after               : $(disk_free)"
info "Total freed (dirs)       : $(human_size $TOTAL_FREED_KB)"
info "Steps completed          : $TOTAL_CLEANED"
info "Steps skipped (missing)  : $TOTAL_SKIPPED_MISSING"
info "Steps skipped (in use)   : $TOTAL_SKIPPED_PROTECTED"
info "Steps failed             : $TOTAL_FAILED"
info "Steps timed out          : $TOTAL_TIMEDOUT"
info "Wall-clock elapsed       : ${ELAPSED}s"
info "Full log                 : $LOG_FILE"
ok   "Cleanup complete."
echo
printf 'Tip: restart your Mac to release caches still held by running processes.\n'
printf 'Note: apps rebuild their caches on next launch — first start may be slightly slower.\n'

}   # end run_clean

# =============================================================================
# § ENTRY POINT
# =============================================================================
show_main_menu
