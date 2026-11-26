#!/usr/bin/env bash
# =============================================================================
# § lib/helpers/exec.sh  ·  Running commands safely
#
#   Single responsibility: run external commands with a time limit, a log
#   trail and - for destructive ones - the user's consent.
#
#     run_timeout       portable timeout wrapper
#     run_step          logged, timed command (from a command string)
#     confirm_action    the one y/N gate for destructive actions
#     docker_ready      Docker daemon check that cannot hang
#     simctl_cmd        find a working `simctl`
#     skip_missing / skip_in_use   uniform "not done, and why" notices
#
#   Requires (sourced earlier): colors.sh, core.sh (counters/timeouts), logging.sh
# =============================================================================

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
# shellcheck disable=SC2034  # read by the cleanup banner
_TIMEOUT_BIN=''
if   command -v gtimeout &>/dev/null; then _TIMEOUT_BIN='gtimeout'
elif command -v timeout  &>/dev/null; then _TIMEOUT_BIN='timeout'
fi

# =============================================================================
# § run_timeout SECONDS COMMAND [ARG...]
#
#   Runs COMMAND, stopping it if it is still going after SECONDS.
#
#   Returns:
#     COMMAND's exit code, or 124 when it was stopped for running too long
# =============================================================================
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
# § run_step LABEL COMMAND_STRING
#
#   Executes COMMAND_STRING (via bash -c) with CMD_TIMEOUT.
#   • Captures and logs every line of stdout and stderr verbosely.
#   • Records exit code, elapsed time, and timeout state.
#   • Never aborts the outer script on failure.
#
#   Arguments:
#     LABEL           what the step is, for the log
#     COMMAND_STRING  a fixed command line. Never build it from a path or other
#                     outside text - quote-safe callers use run_timeout + argv.
#   Globals:
#     writes TOTAL_CLEANED / TOTAL_FAILED / TOTAL_TIMEDOUT
# =============================================================================
run_step() {
    local label="$1"
    local cmd="$2"

    local stdout_f stderr_f line
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
# § confirm_action PROMPT ASSUME_VAR
#
#   The one confirmation gate for destructive actions. On a terminal it asks
#   PROMPT with a [y/N] default of No. Without a terminal (cron, pipes) nobody
#   can answer, so it proceeds only when the variable named ASSUME_VAR is 1
#   (e.g. DOCKER_CLEAN_ASSUME_YES=1).
#
#   Arguments:
#     PROMPT      the question, without the "[y/N]"
#     ASSUME_VAR  name of the variable that pre-approves it for automation
#   Returns:
#     0 to go ahead, 1 to skip; the caller does
#     `confirm_action "…?" FOO_ASSUME_YES || return 0`.
# =============================================================================
confirm_action() {
    local prompt="$1" var="$2" answer
    if [[ -t 0 ]]; then
        printf "  ${YLW}%s [y/N]: ${NC}" "$prompt"
        read -r answer
        if [[ $answer != [yY] ]]; then
            info "Cancelled - nothing changed."; echo; return 1
        fi
    elif [[ ${!var:-0} == 1 ]]; then
        info "non-interactive - ${var}=1, proceeding"
    else
        warn "non-interactive and no confirmation possible - skipping (set ${var}=1)"
        echo; return 1
    fi
    echo
}

# =============================================================================
# § docker_ready
#
#   True when the docker CLI exists and its daemon answers within
#   DOCKER_INFO_TIMEOUT seconds (default 20). A daemon that is still starting
#   (Docker Desktop, Colima) can leave `docker info` hanging for minutes.
# =============================================================================
docker_ready() {
    command -v docker &>/dev/null || return 1
    local to=${DOCKER_INFO_TIMEOUT:-20}
    [[ $to =~ ^[0-9]+$ ]] && (( to > 0 )) || to=20
    run_timeout "$to" docker info &>/dev/null
}

# =============================================================================
# § simctl_cmd
#
#   Prints a shell command prefix that runs simctl, or nothing if no Xcode is
#   installed. xcode-select often points at the Command Line Tools, which ship
#   no simctl, so fall back to an installed Xcode.app via DEVELOPER_DIR for
#   this one command (the system setting is left alone).
# =============================================================================
simctl_cmd() {
    if xcrun --find simctl &>/dev/null; then
        printf '%s' "xcrun simctl"; return 0
    fi
    local xc
    for xc in /Applications/Xcode.app /Applications/Xcode*.app; do
        if [[ -x $xc/Contents/Developer/usr/bin/simctl ]]; then
            printf "DEVELOPER_DIR='%s' xcrun simctl" "$xc/Contents/Developer"
            return 0
        fi
    done
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
# § skip_in_use LABEL REASON [TIP]
#
#   Prints a uniform "in use - skipped" notice and counts it as protected.
#   Use when deleting now would break a running process.
# =============================================================================
skip_in_use() {
    step "[$1]"
    info "status  : skipped - $2"
    [[ -n ${3:-} ]] && info "tip     : $3"
    (( TOTAL_SKIPPED_PROTECTED++ ))
    echo
}
