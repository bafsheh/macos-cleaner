#!/usr/bin/env bash
# shellcheck disable=SC2034  # shared state, read by every other module
# =============================================================================
# § lib/core.sh  ·  Runtime configuration + global state
#
#   Single responsibility: establish the execution environment shared by every
#   module - shell flags, the macOS guard, the run log file, the per-run scratch
#   folder, statistic counters, and the tunable timeouts. No business logic
#   lives here.
#
#   Requires (sourced earlier): nothing (this is sourced right after colors.sh)
# =============================================================================

# ── version (single source of truth - shown in the main-menu banner) ─────────
declare -r MC_VERSION='1.4.0'

# ── runtime flags ──────────────────────────────────────────────────────────
#   -u          : abort on unset variable reference
#   -o pipefail : pipeline exit-code = first failure
#   (no -e: individual steps may fail without aborting the whole run)
set -uo pipefail

# ── process substitution: never in anything that repeats ─────────────────────
#   bash 3.2 does not close the file descriptor of `< <(cmd)` while it is
#   inside a shell function; it only does so back at the top level of the
#   script. A loop that uses one on every pass therefore runs out of file
#   descriptors (a Terminal window allows 256): redirections start to fail,
#   and once the keyboard's descriptor cannot be saved, stdin is gone.
#   So:  • code that runs per frame, per poll or per item uses a command
#          substitution, a here-string (`done <<< "$(cmd)"`), a glob or a file
#        • one-off uses are fine - the main menu loop runs at the top level of
#          mac_cleaner.sh, which releases them after every menu action
#        • tests/test_long_runs.sh keeps the repeating paths honest
#   The limit is also raised where the system allows it, as headroom.
_MC_FDS=$(ulimit -n 2>/dev/null)
[[ $_MC_FDS =~ ^[0-9]+$ ]] && (( _MC_FDS < 4096 )) && ulimit -n 4096 2>/dev/null

# ── macOS guard ──────────────────────────────────────────────────────────────
#   The script targets bash 3.2+ (the version shipped with macOS) and macOS
#   only - bail out early on any other platform.
if [[ $(uname) != Darwin ]]; then
    printf 'ERROR: This script is macOS-only.\n' >&2
    exit 1
fi

# ── run log file ─────────────────────────────────────────────────────────────
#   Every log line is also written here as plain text (no colour codes), each
#   prefixed with the time since the run started. MAC_CLEANER_LOG overrides the
#   location (the tests point it into their throwaway folder).
_MC_TMP=${TMPDIR:-/tmp}; _MC_TMP=${_MC_TMP%/}      # macOS ends $TMPDIR with a slash
LOG_FILE="${MAC_CLEANER_LOG:-$_MC_TMP/mac_cleaner_$(date +%Y%m%d_%H%M%S).log}"
printf 'macOS Cleaner %s - run started %s\n' "$MC_VERSION" "$(date '+%Y-%m-%d %H:%M:%S %Z')" > "$LOG_FILE"

# ── per-run scratch folder ───────────────────────────────────────────────────
#   Background scans (app list, leftover search) and the "biggest wins" ledger
#   keep their working files here. Removed again by _mc_on_exit. The
#   mac_cleaner_ prefix keeps the temp sweep (TEMP_KEEP_RE) away from it.
MC_RUN_DIR=$(mktemp -d "$_MC_TMP/mac_cleaner_run.XXXXXX" 2>/dev/null) || MC_RUN_DIR=''

# =============================================================================
# § _mc_on_exit
#
#   EXIT trap for the whole program: puts the terminal back the way it was
#   (when the UI module is loaded) and deletes the scratch folder. Runs on a
#   normal exit and after Ctrl-C (the INT trap ends with `exit`).
#
#   Globals:
#     reads  MC_RUN_DIR
# =============================================================================
_mc_on_exit() {
    # Closing the terminal window sends HUP to this shell AND to the `rm`
    # below; ignored signals are inherited, so the cleanup always finishes.
    trap '' HUP INT TERM
    declare -F _ui_term_restore >/dev/null && _ui_term_restore
    [[ -n $MC_RUN_DIR && -d $MC_RUN_DIR ]] && rm -rf "$MC_RUN_DIR"
    return 0
}
trap '_mc_on_exit' EXIT

# ── statistic counters ───────────────────────────────────────────────────────
#   declare -i → bash treats these as integers; arithmetic is always safe.
declare -i TOTAL_FREED_KB=0
declare -i TOTAL_CLEANED=0
declare -i TOTAL_SKIPPED_MISSING=0
declare -i TOTAL_SKIPPED_PROTECTED=0
declare -i TOTAL_FAILED=0
declare -i TOTAL_TIMEDOUT=0
declare -i TOTAL_TCC_BLOCKED=0   # folders macOS privacy (TCC) refused to list
START_TIME=$(date +%s); declare -r START_TIME
# Every counter above - run_parallel carries these back from its jobs.
declare -ra STAT_COUNTERS=(
    TOTAL_FREED_KB TOTAL_CLEANED TOTAL_SKIPPED_MISSING TOTAL_SKIPPED_PROTECTED
    TOTAL_FAILED TOTAL_TIMEDOUT TOTAL_TCC_BLOCKED
)

# ── "biggest wins" ledger ────────────────────────────────────────────────────
#   One "KB<TAB>LABEL" line per step that freed space. A plain file, so the
#   parallel cleanup jobs (subshells) can all append to it; the summary reads
#   it back to show where the space actually came from. See ledger_add.
FREED_LEDGER="${MC_RUN_DIR:-${TMPDIR:-/tmp}}/freed_ledger.tsv"

# ── tunable timeouts (seconds - override via environment) ────────────────────
declare -i CMD_TIMEOUT=${CMD_TIMEOUT:-60}
declare -i DIR_TIMEOUT=${DIR_TIMEOUT:-120}
declare -i SCAN_TIMEOUT=${SCAN_TIMEOUT:-60}

# ── cleanup sections run side by side (run_parallel) - sanitised like below ──
[[ ${CLEAN_JOBS:-4} =~ ^[0-9]+$ ]] || CLEAN_JOBS=4
declare -i CLEAN_JOBS=${CLEAN_JOBS:-4}
(( CLEAN_JOBS < 1 )) && CLEAN_JOBS=1

# ── temp-file age threshold (days) - sanitised: `declare -i` on junk aborts ──
[[ ${TEMP_AGE_DAYS:-3} =~ ^[0-9]+$ ]] || TEMP_AGE_DAYS=3
declare -i TEMP_AGE_DAYS=${TEMP_AGE_DAYS:-3}
(( TEMP_AGE_DAYS < 1 )) && TEMP_AGE_DAYS=1
