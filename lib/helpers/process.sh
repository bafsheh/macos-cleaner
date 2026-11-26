#!/usr/bin/env bash
# =============================================================================
# § lib/helpers/process.sh  ·  Process inspection and control
#
#   Single responsibility: stop processes reliably and know which ones must
#   never be stopped.
#
#     kill_tree            stop a process and everything it started
#     proc_wait_gone       wait until a PID has really exited
#     proc_ancestor_pids   the PID chain from this script up to launchd
#     proc_pids_under      PIDs whose executable lives inside a folder
#
#   Requires (sourced earlier): nothing
# =============================================================================

# =============================================================================
# § kill_tree PID
#
#   Sends SIGTERM to PID and to every process it started (find, rm, du, brew…).
#   The parent is frozen first so it cannot launch a new child while the tree
#   is being walked.
#
#   Arguments:
#     PID   root of the process tree to stop
# =============================================================================
kill_tree() {
    local pid=$1 kids c
    kids=$(pgrep -P "$pid" 2>/dev/null)
    kill -STOP "$pid" 2>/dev/null
    for c in $kids; do kill_tree "$c"; done
    kill -TERM "$pid" 2>/dev/null
    kill -CONT "$pid" 2>/dev/null
    return 0
}

# =============================================================================
# § proc_wait_gone PID TIMEOUT
#
#   Polls `kill -0` (send no signal, just probe existence) every 200 ms. This
#   is what turns "quit" from fire-and-forget into a verified outcome.
#
#   Arguments:
#     PID      process to watch
#     TIMEOUT  how long to wait, in seconds
#   Returns:
#     0 once the process is gone, 1 if it is still alive after TIMEOUT
# =============================================================================
proc_wait_gone() {
    local pid=$1 timeout=$2
    local -i waited=0
    while (( waited < timeout * 5 )); do
        kill -0 "$pid" 2>/dev/null || return 0
        sleep 0.2
        (( waited++ ))
    done
    kill -0 "$pid" 2>/dev/null && return 1
    return 0
}

# =============================================================================
# § proc_ancestor_pids
#
#   Whatever launched this script (login shell, terminal, or an editor's
#   integrated terminal) appears in this chain. Sparing these PIDs means the
#   script never force-quits its own host.
#
#   Outputs:
#     The PID chain from this process up to (not including) pid 1, one per line.
# =============================================================================
proc_ancestor_pids() {
    local pid=$$
    while (( pid > 1 )); do
        printf '%s\n' "$pid"
        pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
        [[ -z $pid ]] && break
    done
}

# =============================================================================
# § proc_pids_under DIR
#
#   Finds the running processes that belong to an app bundle (or any folder):
#   those whose executable path starts with DIR/.
#
#   Arguments:
#     DIR   absolute folder path, e.g. /Applications/Foo.app
#   Outputs:
#     Matching PIDs, one per line (nothing when none are running).
# =============================================================================
proc_pids_under() {
    ps -axo pid=,comm= 2>/dev/null | awk -v dir="$1/" '
        { pid = $1; $1 = ""; sub(/^ +/, "") }
        index($0, dir) == 1 { print pid }'
}
