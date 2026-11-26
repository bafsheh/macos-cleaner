#!/usr/bin/env bash
# =============================================================================
# § lib/helpers/parallel.sh  ·  Run cleanup sections side by side
#
#   Single responsibility: run_parallel and its live panel.
#
#   Requires (sourced earlier): colors.sh, core.sh (CLEAN_JOBS, STAT_COUNTERS),
#                               logging.sh, helpers/process.sh (kill_tree)
# =============================================================================

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
#
#   Arguments:
#     FUNC...  names of functions that take no arguments
#   Globals:
#     reads  CLEAN_JOBS, STAT_COUNTERS, LOG_FILE
#     writes every TOTAL_* counter (summed from the jobs)
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
            _par_log_buffer "$_PAR_DIR/$shown.out"
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
        # (Captured with $(…) and read from a here-string: the panel is
        # redrawn five times a second for minutes, and a process substitution
        # would cost bash 3.2 a file descriptor every time - see lib/core.sh.)
        local records
        records=$(awk -v home="$HOME" '
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
        while IFS= read -r line; do info+=("$line"); done <<< "$records"

        # Deepest live descendant of each job pid, one line per job.
        records=$(ps -Ao pid=,ppid=,command= -ww 2>/dev/null |
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
        while IFS= read -r line; do cmds+=("$line"); done <<< "$records"
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

# =============================================================================
# § _par_log_buffer FILE
#
#   Appends a finished job's buffered output to the log file as plain text:
#   colour codes stripped, each line stamped like _log does.
# =============================================================================
_par_log_buffer() {
    local stamp
    printf -v stamp '[+%02d:%02d]' "$(( SECONDS / 60 ))" "$(( SECONDS % 60 ))"
    sed -e $'s/\033\\[[0-9;]*[A-Za-z]//g' -e "s/^/$stamp /" "$1" >> "$LOG_FILE" 2>/dev/null
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

# _par_abort SIGNAL → Ctrl-C / TERM during run_parallel: stops every job and
# what it started, removes the scratch folder, then runs the handler that was
# installed before run_parallel began.
_par_abort() {
    local pid old
    _par_panel_clear
    for pid in ${_PAR_PIDS[@]+"${_PAR_PIDS[@]}"}; do kill_tree "$pid"; done
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
