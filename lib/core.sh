#!/usr/bin/env bash
# =============================================================================
# § lib/core.sh  ·  Runtime configuration + global state
#
#   Single responsibility: establish the execution environment shared by every
#   module — shell flags, the macOS guard, the run log file, statistic counters,
#   and the tunable timeouts. No business logic lives here.
#
#   Requires (sourced earlier): nothing (this is sourced right after colors.sh)
# =============================================================================

# ── runtime flags ──────────────────────────────────────────────────────────
#   -u          : abort on unset variable reference
#   -o pipefail : pipeline exit-code = first failure
#   (no -e: individual steps may fail without aborting the whole run)
set -uo pipefail

# ── macOS guard ──────────────────────────────────────────────────────────────
#   The script targets bash 3.2+ (the version shipped with macOS) and macOS
#   only — bail out early on any other platform.
if [[ $(uname) != Darwin ]]; then
    printf 'ERROR: This script is macOS-only.\n' >&2
    exit 1
fi

# ── run log file ─────────────────────────────────────────────────────────────
#   Every line of output is tee'd here by the logging primitives.
LOG_FILE="${TMPDIR:-/tmp}/mac_cleaner_$(date +%Y%m%d_%H%M%S).log"
: > "$LOG_FILE"   # create / truncate immediately

# ── statistic counters ───────────────────────────────────────────────────────
#   declare -i → bash treats these as integers; arithmetic is always safe.
declare -i TOTAL_FREED_KB=0
declare -i TOTAL_CLEANED=0
declare -i TOTAL_SKIPPED_MISSING=0
declare -i TOTAL_SKIPPED_PROTECTED=0
declare -i TOTAL_FAILED=0
declare -i TOTAL_TIMEDOUT=0
declare -r START_TIME=$(date +%s)

# ── tunable timeouts (seconds — override via environment) ────────────────────
declare -i CMD_TIMEOUT=${CMD_TIMEOUT:-60}
declare -i DIR_TIMEOUT=${DIR_TIMEOUT:-120}
declare -i SCAN_TIMEOUT=${SCAN_TIMEOUT:-60}
