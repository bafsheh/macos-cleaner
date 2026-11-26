#!/usr/bin/env bash
# =============================================================================
# § lib/helpers.sh  ·  Shared helpers (loader)
#
#   Loads the reusable, side-effect-aware building blocks shared by every
#   action, one focused module each:
#
#     helpers/measure.sh    disk_free · human_size · dir_size_kb · ledger_*
#                           · report_largest_dirs
#     helpers/exec.sh       run_timeout · run_step · confirm_action
#                           · docker_ready · simctl_cmd · skip_*
#     helpers/process.sh    kill_tree · proc_wait_gone · proc_ancestor_pids
#     helpers/parallel.sh   run_parallel + its live panel
#     helpers/duscan.sh     du_scan_* - fast parallel folder measurement
#     helpers/macos.sh      is_tcc_blocked · empty_trash · clean_tm_snapshots
#     helpers/clean.sh      clean_dir · remove_files · sweep_* · purge_stale
#     helpers/scan.sh       dev_roots · _scan_and_delete
#
#   Requires (sourced earlier): colors.sh, core.sh (counters/timeouts), logging.sh
# =============================================================================
_HELPERS_DIR="${BASH_SOURCE[0]%/*}/helpers"

# shellcheck source=lib/helpers/measure.sh
source "$_HELPERS_DIR/measure.sh"
# shellcheck source=lib/helpers/exec.sh
source "$_HELPERS_DIR/exec.sh"
# shellcheck source=lib/helpers/process.sh
source "$_HELPERS_DIR/process.sh"
# shellcheck source=lib/helpers/parallel.sh
source "$_HELPERS_DIR/parallel.sh"
# shellcheck source=lib/helpers/duscan.sh
source "$_HELPERS_DIR/duscan.sh"
# shellcheck source=lib/helpers/macos.sh
source "$_HELPERS_DIR/macos.sh"
# shellcheck source=lib/helpers/clean.sh
source "$_HELPERS_DIR/clean.sh"
# shellcheck source=lib/helpers/scan.sh
source "$_HELPERS_DIR/scan.sh"
