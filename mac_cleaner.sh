#!/usr/bin/env bash
# ┌─────────────────────────────────────────────────────────────────────────────┐
# │  mac_cleaner.sh  ·  Safe macOS disk-space cleaner + maintenance               │
# │                                                                               │
# │  Clears caches, logs, package-manager stores, and Trash, offers optional      │
# │  maintenance actions (flush DNS · free dev ports · kill apps), maps disk      │
# │  usage, and uninstalls apps together with everything they left behind.        │
# │  Never touches personal files (Documents, Desktop, Pictures, …).              │
# │                                                                               │
# │  Requires : bash 3.2+ (ships with macOS - no extra install needed)            │
# │  Sudo     : system-cache, DNS-flush, and Time Machine steps prompt for a pw.  │
# │                                                                               │
# │  Usage                                                                        │
# │    chmod +x mac_cleaner.sh && ./mac_cleaner.sh                                 │
# │                                                                               │
# │  Env overrides                                                                │
# │    CMD_TIMEOUT=60    per-command timeout in seconds     (default 60)          │
# │    DIR_TIMEOUT=120   per-directory delete timeout       (default 120)         │
# │    SCAN_TIMEOUT=60   project-scan find timeout          (default 60)          │
# │    CLEAN_JOBS=4      cleanup sections run in parallel   (1 = one at a time)   │
# │    PY_SCAN_ROOTS     space-separated roots for Python project scan            │
# │    JS_SCAN_ROOTS     space-separated roots for JS project scan                │
# │    SHUTDOWN_DELAY=15 cancellable shutdown countdown, seconds   (default 15)   │
# │    TEMP_AGE_DAYS=3   temp items untouched this many days are removed (≥1)     │
# │    DM_JOBS           folders measured at the same time (default CPUs, max 16) │
# │    REPORT_TIMEOUT=90 max seconds for the disk usage report (s skips it)       │
# │    DOCKER_TIMEOUT=300 per-command timeout for the Docker teardown             │
# │    WORKTREE_SCAN_ROOTS  space-separated roots for the stale-worktree scan     │
# │    WORKTREE_AGE_DAYS=7  worktrees untouched this many days are candidates     │
# │    WORKTREE_KEEP_RE     regex of worktree paths never removed                 │
# │    PROJECT_SCAN_ROOTS   space-separated roots for the project-folder scan     │
# │    PROJECT_QUIET_HOURS=24 skip repos with Git activity this recently          │
# │    PROJECT_KEEP_RE      regex of project-folder paths never removed           │
# │    UNINSTALL_APP_ROOTS  colon-separated app folders for the uninstall list    │
# │    UNINSTALL_SPOTLIGHT=0  do not ask Spotlight for apps / leftovers elsewhere │
# │    UNINSTALL_JOBS       apps measured at the same time (default CPUs, max 6)  │
# │    UNINSTALL_NO_SUDO=1  never ask for admin rights while uninstalling         │
# │    MAC_CLEANER_LOG      write the run log to this file                        │
# │    NO_COLOR          set to disable all colour output (CLICOLOR_FORCE=1 re-on)│
# │                                                                               │
# │  Non-interactive opt-ins (destructive actions skip their y/N prompt)          │
# │    KILL_APPS_ASSUME_YES=1      quit apps without confirmation                  │
# │    WORKTREE_CLEAN_ASSUME_YES=1 remove clean, pushed, idle git worktrees        │
# │    PROJECT_CLEAN_ASSUME_YES=1  delete Git-ignored project build folders        │
# │    DOCKER_CLEAN_ASSUME_YES=1   wipe containers+images (DOCKER_CLEAN_VOLUMES=1) │
# │    COLIMA_CLEAN_ASSUME_YES=1   delete all Colima VMs and their data disks      │
# │    OLLAMA_CLEAN_ASSUME_YES=1   wipe all Ollama/llama model weights             │
# │    UNINSTALL_ASSUME_YES=1      uninstall the chosen apps + their safe leftovers│
# │    SHUTDOWN_ASSUME_YES=1       allow shutdown on non-TTY stdin (no cancel key) │
# │                                                                               │
# │  Structure                                                                    │
# │    This entry point only resolves its own directory, sources the lib/         │
# │    modules in dependency order, and launches the main menu. All behavior      │
# │    lives in lib/ - helpers/ (shared building blocks), ui/ (widgets),          │
# │    actions/ (one file per maintenance action) and uninstall/.                 │
# └─────────────────────────────────────────────────────────────────────────────┘

# =============================================================================
# § MODULE LOADER
#
#   Resolve this script's own directory (so it works regardless of the caller's
#   CWD or symlinks), then source each module. Order matters: colors → core →
#   logging → helpers → ui → actions → uninstaller → menu. helpers.sh, ui.sh
#   and uninstaller.sh each load the modules of their own sub-folder.
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"

if [[ ! -d $LIB_DIR ]]; then
    printf 'ERROR: lib/ directory not found next to %s\n' "${BASH_SOURCE[0]}" >&2
    exit 1
fi

# shellcheck source=lib/colors.sh
source "$LIB_DIR/colors.sh"
# shellcheck source=lib/core.sh
source "$LIB_DIR/core.sh"
# shellcheck source=lib/logging.sh
source "$LIB_DIR/logging.sh"
# shellcheck source=lib/helpers.sh
source "$LIB_DIR/helpers.sh"
# shellcheck source=lib/ui.sh
source "$LIB_DIR/ui.sh"

# Action modules (registered in lib/menu.sh).
# shellcheck source=lib/actions/cleanup.sh
source "$LIB_DIR/actions/cleanup.sh"
# shellcheck source=lib/actions/temp_clean.sh
source "$LIB_DIR/actions/temp_clean.sh"
# shellcheck source=lib/actions/free_memory.sh
source "$LIB_DIR/actions/free_memory.sh"
# shellcheck source=lib/actions/flush_dns.sh
source "$LIB_DIR/actions/flush_dns.sh"
# shellcheck source=lib/actions/free_ports.sh
source "$LIB_DIR/actions/free_ports.sh"
# shellcheck source=lib/actions/kill_apps.sh
source "$LIB_DIR/actions/kill_apps.sh"
# shellcheck source=lib/actions/worktree_clean.sh
source "$LIB_DIR/actions/worktree_clean.sh"
# shellcheck source=lib/actions/project_clean.sh
source "$LIB_DIR/actions/project_clean.sh"
# shellcheck source=lib/actions/docker_clean.sh
source "$LIB_DIR/actions/docker_clean.sh"
# shellcheck source=lib/actions/colima_clean.sh
source "$LIB_DIR/actions/colima_clean.sh"
# shellcheck source=lib/actions/ollama_clean.sh
source "$LIB_DIR/actions/ollama_clean.sh"
# shellcheck source=lib/actions/disk_map.sh
source "$LIB_DIR/actions/disk_map.sh"

# shellcheck source=lib/uninstaller.sh
source "$LIB_DIR/uninstaller.sh"
# shellcheck source=lib/menu.sh
source "$LIB_DIR/menu.sh"

# =============================================================================
# § ENTRY POINT
#
#   The menu loop lives here, at the top level of the script, on purpose:
#   bash 3.2 keeps the file descriptor of every process substitution used
#   inside a function open until control is back at the top level. One pass
#   of this loop per menu action releases them (details in lib/core.sh).
#   show_main_menu exits the program when "Exit" is chosen.
# =============================================================================
while true; do
    show_main_menu
done
