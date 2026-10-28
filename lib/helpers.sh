#!/usr/bin/env bash
# =============================================================================
# § lib/helpers.sh  ·  Filesystem + execution helpers
#
#   Reusable, side-effect-aware building blocks shared by every action:
#     • disk_free / human_size / dir_size_kb - measurement
#     • run_timeout                          - portable timeout wrapper
#     • run_step                             - logged command execution
#     • clean_dir / purge_stale             - safe content deletion
#     • sweep_caches / sweep_chromium_caches - bulk cache sweeps
#     • empty_trash                          - Trash (Finder fallback under TCC)
#     • clean_tm_snapshots                   - Time Machine local snapshots
#     • report_largest_dirs                  - informational disk report
#     • dev_roots / _scan_and_delete         - dev-folder artefact sweeper
#
#   Requires (sourced earlier): colors.sh, core.sh (counters/timeouts), logging.sh
# =============================================================================

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

# Free space on the boot volume in KB (APFS: shared by every volume).
disk_avail_kb() { df -k / | awk 'NR==2 {print $4+0}'; }

# =============================================================================
# § is_tcc_blocked PATH
#
#   True when PATH exists but macOS privacy protection (TCC) refuses to list
#   it - e.g. ~/.Trash, ~/Library/Mail, Safari or Photos containers when the
#   terminal lacks Full Disk Access. Without this check `du` and `find` fail
#   quietly, sizes read as 0, and a folder full of data looks "already empty".
# =============================================================================
is_tcc_blocked() {
    [[ -d $1 ]] && ! ls -A "$1" >/dev/null 2>&1
}

# Prints the one-time "how to grant Full Disk Access" hint.
fda_hint() {
    info "tip     : give your terminal Full Disk Access to clean protected folders:"
    info "          System Settings ▸ Privacy & Security ▸ Full Disk Access ▸ add"
    info "          your terminal app (Terminal, iTerm, VS Code, …), then reopen it."
}

# =============================================================================
# § TIMEOUT WRAPPER
#
#   Preference order:
#     1. gtimeout  (brew install coreutils)   - most reliable on macOS
#     2. timeout   (if some other package put one on PATH; macOS ships none)
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
    # Polls every 0.1s: a whole-second poll costs ≥1s per call, which turns
    # hundreds of instant rm's (purge_stale) into minutes of silence.
    "$@" &
    local -i child=$! ticks=0
    sleep 0.01
    kill -0 "$child" 2>/dev/null || { wait "$child"; return $?; }
    while (( ticks < secs * 10 )); do
        sleep 0.1; (( ticks++ ))
        kill -0 "$child" 2>/dev/null || { wait "$child"; return $?; }
    done
    kill -TERM "$child" 2>/dev/null
    sleep 2
    kill -KILL "$child" 2>/dev/null
    wait "$child" 2>/dev/null
    return 124
}

# =============================================================================
# § run_parallel FUNC...
#
#   Runs each FUNC (a function taking no arguments) as a background job, at
#   most CLEAN_JOBS at a time. Each job's output is buffered and printed in the
#   order given, as soon as it and every job before it are done, so the screen
#   and the log read like a one-at-a-time run - just sooner.
#
#   Rules for a FUNC:
#     • no prompts - jobs read from /dev/null; ask before calling run_parallel
#     • never touch a folder another FUNC in the same call touches: two
#       deletes racing on one tree report errors and miscount freed space
#
#   Jobs are subshells, so each writes its TOTAL_* counters to a file on exit
#   and they are added up here. Background jobs ignore Ctrl+C, so the trap
#   stops them all, then lets Ctrl+C do whatever it did before.
#
#   On a terminal, a live panel under the finished output shows every running
#   job: its section, current step, last line logged and the command it is
#   running right now (see _par_panel).
# =============================================================================
_PAR_DIR='' _PAR_OLD_INT='' _PAR_OLD_TERM=''
_PAR_PIDS=() _PAR_STARTS=()
declare -i _PAR_PANEL_H=0   # lines the live panel last drew (0 = none on screen)

run_parallel() {
    local -a fns=("$@") running
    local -i n=${#fns[@]} started=0 shown=0 finished i frame=0 t0
    local c v
    local -i tty=0; [[ -t 1 ]] && tty=1

    # mac_cleaner_ prefix: the temp sweep (TEMP_KEEP_RE) never touches it.
    _PAR_DIR=$(mktemp -d "${TMPDIR:-/tmp}/mac_cleaner_par.XXXXXX") || {
        for c in "${fns[@]}"; do "$c"; done    # no scratch space: run in order
        return 0
    }
    _PAR_PIDS=() _PAR_STARTS=() _PAR_PANEL_H=0
    _PAR_OLD_INT=$(trap -p INT); _PAR_OLD_TERM=$(trap -p TERM)
    trap '_par_abort INT'  INT
    trap '_par_abort TERM' TERM

    t0=$SECONDS
    while (( shown < n )); do
        # ── fill free slots ─────────────────────────────────────────────────
        finished=0
        for (( i = shown; i < started; i++ )); do
            [[ -e $_PAR_DIR/$i.done ]] && (( finished++ ))
        done
        while (( started - shown - finished < CLEAN_JOBS && started < n )); do
            _par_start "${fns[started]}" "$_PAR_DIR/$started"
            (( started++ ))
        done

        # ── print finished jobs from the front of the queue, in order ───────
        while (( shown < started )) && [[ -e $_PAR_DIR/$shown.done ]]; do
            (( tty )) && _par_panel_clear
            cat "$_PAR_DIR/$shown.out"
            cat "$_PAR_DIR/$shown.out" >> "$LOG_FILE"
            if [[ -f $_PAR_DIR/$shown.stats ]]; then
                while read -r c v; do
                    [[ $c == TOTAL_* ]] && (( $c += v ))
                done < "$_PAR_DIR/$shown.stats"
            fi
            (( shown++ ))
        done
        (( shown < n )) || break

        if (( tty )); then
            running=() finished=$shown
            for (( i = shown; i < started; i++ )); do
                if [[ -e $_PAR_DIR/$i.done ]]; then (( finished++ )); else running+=("$i"); fi
            done
            _par_panel "$frame" "$finished" "$n" "$(( SECONDS - t0 ))" \
                ${running[@]+"${running[@]}"}
            (( frame++ ))
        fi
        sleep 0.2
    done

    wait "${_PAR_PIDS[@]}" 2>/dev/null
    eval "${_PAR_OLD_INT:-trap - INT}"; eval "${_PAR_OLD_TERM:-trap - TERM}"
    rm -rf "$_PAR_DIR"; _PAR_DIR=''
}

# =============================================================================
# § _par_panel FRAME DONE TOTAL ELAPSED IDX...
#
#   Redraws the live panel in place: a progress header, then one block per
#   running job IDX:
#
#     ● 7 · HOMEBREW  12s  ▸ [brew cleanup]      section, time, current step
#       │ cmd     : brew cleanup --prune=all     last line it logged
#       ⚙ ruby …/brew.rb cleanup --prune=all     command running right now
#
#   The step and log line come from the job's output buffer; the command is
#   the deepest live child process of the job (shell subshells, exiting
#   processes, the logger's tee and the run_timeout poll `sleep` are skipped).
#   When the window is too short for three lines per job, each job gets one
#   line: the command, else the step. Every line is cut to the window width
#   so nothing wraps and the next redraw lands on the same rows.
# =============================================================================
_par_panel() {   # FRAME DONE TOTAL ELAPSED IDX...
    local -i frame=$1 fin=$2 total=$3 secs=$4; shift 4
    local spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏' size buf title stp last now bar line
    local -i cols=80 rows=24 w rest fill bw=20 i k=0 full=1
    local -a files=() pids=() info=() cmds=()

    size=$(stty size 2>/dev/null < /dev/tty) || size=''
    [[ $size =~ ^([1-9][0-9]*)\ ([1-9][0-9]*)$ ]] && { rows=${BASH_REMATCH[1]}; cols=${BASH_REMATCH[2]}; }
    (( w = cols - 8 ))
    (( cols < 80 )) && bw=10
    (( 1 + 3 * $# > rows - 4 )) && full=0

    for i in "$@"; do files+=("$_PAR_DIR/$i.out"); pids+=("${_PAR_PIDS[i]}"); done

    if (( $# > 0 )); then
        # One record per job: title ␟ step ␟ last line (ANSI and $HOME stripped).
        while IFS= read -r line; do info+=("$line"); done < <(awk -v home="$HOME" '
            function clean(s) {
                gsub(/\033\[[0-9;]*[A-Za-z]/, "", s); gsub(/[\r\t]/, " ", s)
                gsub(home, "~", s); sub(/^ +/, "", s); sub(/ +$/, "", s); return s
            }
            { s = clean($0) }
            s == "" || s ~ /^┗/ { next }
            s ~ /^┏━━ / { if (!(FILENAME in T)) { sub(/^┏━━ /, "", s); T[FILENAME] = s }; next }
            s ~ /^▸ / { sub(/^▸ /, "", s); S[FILENAME] = s; L[FILENAME] = ""; next }
            { L[FILENAME] = s }
            END { for (i = 1; i < ARGC; i++) { f = ARGV[i]; print T[f] "\037" S[f] "\037" L[f] } }
        ' "${files[@]}")

        # Deepest live descendant of each job pid, one line per job.
        while IFS= read -r line; do cmds+=("$line"); done < <(ps -Ao pid=,ppid=,command= -ww 2>/dev/null |
            awk -v roots="${pids[*]}" -v home="$HOME" '
            BEGIN { n = split(roots, r, " "); for (i = 1; i <= n; i++) root[r[i]] = 1 }
            { p = $1; par[p] = $2; $1 = $2 = ""; sub(/^ +/, ""); cmd[p] = $0 }
            END {
                for (p in par) {
                    if (p in root || cmd[p] == cmd[r[1]] || cmd[p] ~ /^(\(|(\/bin\/)?sleep |tee -a )/) continue
                    d = 0; q = p
                    while ((q in par) && !(q in root) && d < 64) { q = par[q]; d++ }
                    if ((q in root) && d > best[q]) { best[q] = d; c = cmd[p]; gsub(home, "~", c); bc[q] = c }
                }
                for (i = 1; i <= n; i++) print bc[r[i]]
            }')
    fi

    (( fill = total > 0 ? fin * bw / total : 0 ))
    bar=$(printf '%*s' "$fill" '' | tr ' ' '#')$(printf '%*s' $(( bw - fill )) '' | tr ' ' '.')
    bar=${bar//#/█}; bar=${bar//./░}
    buf=$(printf "  ${BCYN}%s${NC} ${BOLD}Parallel cleanup${NC}  ${TEAL}%s${NC}  %d/%d done · %d running · %ds" \
        "${spin:frame%10:1}" "$bar" "$fin" "$total" "$#" "$secs")
    buf+=$'\033[K\n'

    for i in "$@"; do
        IFS=$'\037' read -r title stp last <<< "${info[k]:-}"
        now=${cmds[k]:-}; now=${now:0:w}
        [[ -n $title ]] || title=${fns[i]:-job $i}   # run_parallel's list; nothing printed yet
        (( secs = SECONDS - ${_PAR_STARTS[i]:-$SECONDS} ))
        title=${title:0:w/2}
        (( rest = w - ${#title} - 8, rest < 0 )) && rest=0
        if (( full )); then
            buf+="  ${BGRN}●${NC} ${BOLD}${title}${NC}  ${DIM}${secs}s${NC}  ${BCYN}▸${NC} ${stp:0:rest}"$'\033[K\n'
            buf+="    ${GRY}│${NC} ${DIM}${last:0:w}${NC}"$'\033[K\n'
            buf+="    ${YLW}⚙${NC} ${now:-${DIM}…${NC}}"$'\033[K\n'
        else
            now=${now:-$stp}
            buf+="  ${BGRN}●${NC} ${BOLD}${title}${NC} ${DIM}${secs}s${NC} ${YLW}⚙${NC} ${now:0:rest}"$'\033[K\n'
        fi
        (( k++ ))
    done

    (( _PAR_PANEL_H > 0 )) && printf '\r\033[%dA' "$_PAR_PANEL_H"
    printf '%s\033[J' "$buf"
    (( _PAR_PANEL_H = 1 + (full ? 3 : 1) * $# ))
}

# Erases the live panel so finished output can print in its place.
_par_panel_clear() {
    (( _PAR_PANEL_H > 0 )) && printf '\r\033[%dA\033[J' "$_PAR_PANEL_H"
    _PAR_PANEL_H=0
}

# Starts FUNC in the background. Writes PREFIX.out (all output), PREFIX.stats
# (counters) and, last, PREFIX.done - even if FUNC fails.
_par_start() {   # FUNC PREFIX
    local fn=$1 out=$2 c
    _PAR_STARTS+=("$SECONDS")
    {
        (
            LOG_FILE=/dev/null    # run_parallel appends the buffer to the log
            for c in "${STAT_COUNTERS[@]}"; do printf -v "$c" 0; done
            "$fn"
            for c in "${STAT_COUNTERS[@]}"; do printf '%s %d\n' "$c" "${!c}"; done > "$out.stats"
        ) > "$out.out" 2>&1 < /dev/null
        : > "$out.done"
    } &
    _PAR_PIDS+=($!)
}

_par_abort() {   # SIGNAL
    local pid old
    _par_panel_clear
    for pid in ${_PAR_PIDS[@]+"${_PAR_PIDS[@]}"}; do _kill_tree "$pid"; done
    { wait ${_PAR_PIDS[@]+"${_PAR_PIDS[@]}"}; } 2>/dev/null   # no "Terminated" noise
    [[ -n $_PAR_DIR ]] && rm -rf "$_PAR_DIR"
    printf '\n'
    [[ $1 == INT ]] && old=$_PAR_OLD_INT || old=$_PAR_OLD_TERM
    eval "${_PAR_OLD_INT:-trap - INT}"; eval "${_PAR_OLD_TERM:-trap - TERM}"
    # Run the previous handler ourselves: bash 3.2 drops a signal re-sent from
    # inside its own trap. `trap -p` prints: trap -- 'COMMAND' SIGNAL
    if [[ -n $old ]]; then
        eval "set -- ${old#trap }"
        eval "$2"
    else
        kill -"$1" $$
    fi
}

# Stops PID and everything it started (find, rm, brew …).
_kill_tree() {   # PID
    local kids c
    kids=$(pgrep -P "$1" 2>/dev/null)
    kill -TERM "$1" 2>/dev/null
    for c in $kids; do _kill_tree "$c"; done
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
        local -i size_after_kb freed_kb
        size_after_kb=$(dir_size_kb "$target")
        (( freed_kb = size_before_kb - size_after_kb )) || true
        (( freed_kb < 0 )) && freed_kb=0
        (( TOTAL_FREED_KB += freed_kb ))
        (( TOTAL_CLEANED++ ))
        ok "freed $(human_size $freed_kb) in ${elapsed}s ← $label"
    else
        (( TOTAL_SKIPPED_PROTECTED++ ))
        warn "partial (exit=${rc}, ${elapsed}s) - some items in use ← $label"
    fi
    echo
}

# =============================================================================
# § skip_missing LABEL
#
#   Prints a uniform "not installed - skipping" notice.
#   Use wherever a tool is absent and no action can be taken.
# =============================================================================
skip_missing() {
    step "[$1]"
    info "status  : not installed - skipping"
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
    if (( failed == 0 )); then
        (( TOTAL_CLEANED++ ))
        ok "freed $(human_size $freed) from ${removed} item(s) ← $label"
    else
        (( TOTAL_SKIPPED_PROTECTED++ ))
        warn "freed $(human_size $freed); ${failed} item(s) could not be removed ← $label"
    fi
    echo
}

# =============================================================================
# § empty_trash
#
#   Empties your Trash: ~/.Trash, iCloud Drive's Trash, and your Trash on
#   every mounted external volume.
#
#   macOS protects ~/.Trash with privacy controls (TCC). Unless the terminal
#   has Full Disk Access it cannot even list the folder, so deleting it
#   directly silently does nothing. In that case we ask Finder to empty the
#   Trash instead - the same as Finder ▸ Empty Trash. The first time, macOS
#   asks once whether your terminal may control Finder.
# =============================================================================
empty_trash() {
    local trash="$HOME/.Trash"

    if ! is_tcc_blocked "$trash"; then
        clean_dir "$trash" "User Trash"
        clean_dir "$HOME/Library/Mobile Documents/com~apple~CloudDocs/.Trash" "iCloud Drive Trash"
        local vol
        for vol in /Volumes/*; do
            [[ $vol -ef / ]] && continue                 # boot volume alias
            [[ -d "$vol/.Trashes/$UID" ]] && clean_dir "$vol/.Trashes/$UID" "Trash on ${vol##*/}"
        done
        return 0
    fi

    step "[Trash  (via Finder)]"
    info "note    : macOS privacy blocks direct access to ~/.Trash - asking Finder"

    # Finder's own confirmation dialog is switched off just for this call and
    # restored afterwards. Output: "<items before> <items left>".
    local out
    local -i before_kb after_kb freed rc=0
    before_kb=$(disk_avail_kb)
    out=$(run_timeout 960 osascript \
        -e 'tell application "Finder"' \
        -e '  set n to count of items of trash' \
        -e '  if n > 0 then' \
        -e '    set w to warns before emptying of trash' \
        -e '    set warns before emptying of trash to false' \
        -e '    try' \
        -e '      with timeout of 900 seconds' \
        -e '        empty trash' \
        -e '      end timeout' \
        -e '    end try' \
        -e '    set warns before emptying of trash to w' \
        -e '  end if' \
        -e '  return (n as text) & " " & ((count of items of trash) as text)' \
        -e 'end tell' 2>&1) || rc=$?
    after_kb=$(disk_avail_kb)

    if (( rc == 0 )) && [[ $out =~ ^([0-9]+)\ ([0-9]+)$ ]]; then
        local -i n=${BASH_REMATCH[1]} left=${BASH_REMATCH[2]}
        if (( n == 0 )); then
            info "status  : Trash is already empty"
            echo; return 0
        fi
        (( freed = after_kb - before_kb )) || true
        (( freed < 0 )) && freed=0
        (( TOTAL_FREED_KB += freed ))
        (( TOTAL_CLEANED++ ))
        if (( left == 0 )); then
            ok "emptied ${n} item(s), ~$(human_size $freed) freed ← Trash (Finder)"
        else
            warn "emptied $(( n - left )) of ${n} item(s); ${left} in use or locked ← Trash (Finder)"
        fi
    elif (( rc == 124 )); then
        warn "Finder is still emptying the Trash in the background (large Trash)"
    elif [[ $out == *-1743* ]]; then
        (( TOTAL_FAILED++ ))
        warn "macOS did not allow this terminal to control Finder ← Trash"
        info "allow   : System Settings ▸ Privacy & Security ▸ Automation ▸"
        info "          your terminal ▸ turn on Finder - or use Full Disk Access:"
        fda_hint
    else
        (( TOTAL_FAILED++ ))
        warn "Finder could not empty the Trash (exit=${rc}) ← Trash"
        [[ -n $out ]] && info "detail  : $out"
    fi
    echo
}

# =============================================================================
# § clean_tm_snapshots
#
#   Lists and deletes all Time Machine local snapshots on the boot volume.
#   Local snapshots are temporary backups stored on-disk; deleting them is
#   safe - they have no effect on your remote Time Machine backup.
#   Requires sudo for deletion.
# =============================================================================
clean_tm_snapshots() {
    step "[Time Machine local snapshots]"

    if ! command -v tmutil &>/dev/null; then
        info "status  : tmutil not found - skipping"
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
        info "status  : no local snapshots - nothing to do"
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
        warn "deleted ${deleted}/${#dates[@]} (${failed} failed - may need sudo or newer macOS)"
    fi
    echo
}

# =============================================================================
# § report_largest_dirs PATH LABEL [DEPTH] [COUNT]
#
#   Prints a ranked list of the largest subdirectories under PATH.
#   Purely informational - nothing is deleted.
#   DEPTH defaults to 1; COUNT defaults to 20.
# =============================================================================
report_largest_dirs() {
    local path="$1"
    local label="$2"
    local -i depth=${3:-1}
    local -i count=${4:-20}

    step "[$label - top ${count} by size]"
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
# § dev_roots [ENVVAR]
#
#   Prints the folders where code projects usually live, one per line. If
#   ENVVAR names a non-empty variable, its space-separated list wins instead.
#   ~/Desktop is included: many people keep their projects there.
#   On a case-insensitive disk (the macOS default) ~/Projects and ~/projects
#   are the same folder, so duplicates are dropped by inode.
# =============================================================================
dev_roots() {
    local envvar="${1:-}" d seen
    local -a list=()
    if [[ -n $envvar && -n ${!envvar:-} ]]; then
        read -ra list <<< "${!envvar}"
    else
        list=(
            "$HOME/Desktop"   "$HOME/Documents" "$HOME/Developer" "$HOME/Projects"
            "$HOME/projects"  "$HOME/Code"      "$HOME/code"      "$HOME/dev"
            "$HOME/Dev"       "$HOME/repos"     "$HOME/Repos"     "$HOME/src"
            "$HOME/workspace" "$HOME/Workspace" "$HOME/Sites"     "$HOME/work"
            "$HOME/Work"
        )
    fi
    local -a out=()
    for d in "${list[@]}"; do
        [[ -d $d ]] || continue
        for seen in ${out[@]+"${out[@]}"}; do [[ $d -ef $seen ]] && continue 2; done
        out+=("$d")
        printf '%s\n' "$d"
    done
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
    local d
    while IFS= read -r d; do roots+=("$d"); done < <(dev_roots "$envvar")

    if (( ${#roots[@]} == 0 )); then
        info "status  : no dev folders found"
        info "tip     : export ${envvar}=/your/code to override"
        echo; return 0
    fi

    info "roots   :"
    local r; for r in "${roots[@]}"; do info "  - $r"; done
    info "(heartbeat active - Ctrl+C to skip this scan)"

    local hit_list; hit_list=$(mktemp)

    (
        find "${roots[@]}" \
            -maxdepth 6 \
            \( -path '*/node_modules' -o -path '*/.git'   -o -path '*/Library' \
               -o -path '*/.Trash'    -o -path '*/.venv'  -o -path '*/venv'    \
               -o -path '*/.tox' \) -prune -o \
            "${preds[@]}" -print 2>/dev/null
    ) > "$hit_list" &
    local -i fpid=$! waited=0 scan_ok=1 tty=0
    [[ -t 1 ]] && tty=1    # live counters only on a terminal, not in a job's buffer

    while kill -0 "$fpid" 2>/dev/null; do
        sleep 2; (( waited += 2 ))
        local -i cur; cur=$(wc -l < "$hit_list" 2>/dev/null | tr -d ' ')
        (( tty )) && printf "${DIM}    …%ds  %d found${NC}\r" "$waited" "${cur:-0}"
        if (( waited >= SCAN_TIMEOUT )); then
            kill "$fpid" 2>/dev/null; wait "$fpid" 2>/dev/null
            (( tty )) && printf '\n'
            warn "scan timed out (${SCAN_TIMEOUT}s) - set ${envvar}= for a narrower scope"
            scan_ok=0; break
        fi
    done
    wait "$fpid" 2>/dev/null; (( tty )) && printf '\n'

    local -i found=0 deleted=0
    found=$(wc -l < "$hit_list" | tr -d ' ')
    info "found   : ${found} entries"

    if (( found > 0 )); then
        local entry
        while IFS= read -r entry; do
            rm -rf "$entry" 2>/dev/null && (( deleted++ )) || true
            if (( tty && deleted % 25 == 0 && deleted > 0 )); then
                printf "${DIM}    deleted %d / %d${NC}\r" "$deleted" "$found"
            fi
        done < "$hit_list"
        (( tty )) && printf '\n'
        (( TOTAL_CLEANED++ ))
        ok "deleted ${deleted}/${found} entries ← $label"
    else
        info "status  : nothing to clean"
    fi

    rm -f "$hit_list"
    echo
}
