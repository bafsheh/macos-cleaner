#!/usr/bin/env bash
# ┌─────────────────────────────────────────────────────────────────────────────┐
# │  mac_cleaner.sh  ·  Safe macOS disk-space cleaner + maintenance               │
# │                                                                               │
# │  Clears caches, logs, package-manager stores, and Trash, and offers           │
# │  optional maintenance actions (flush DNS · free dev ports · kill apps).       │
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
# │    PY_SCAN_ROOTS     space-separated roots for Python project scan            │
# │    JS_SCAN_ROOTS     space-separated roots for JS project scan                │
# │    SHUTDOWN_DELAY=15 cancellable shutdown countdown, seconds   (default 15)   │
# │    DOCKER_TIMEOUT=300 per-command timeout for the Docker teardown             │
# │    NO_COLOR          set to disable all colour output (CLICOLOR_FORCE=1 re-on)│
# │                                                                               │
# │  Non-interactive opt-ins (destructive actions skip their y/N prompt)          │
# │    KILL_APPS_ASSUME_YES=1      quit apps without confirmation                  │
# │    DOCKER_CLEAN_ASSUME_YES=1   wipe containers+images (DOCKER_CLEAN_VOLUMES=1) │
# │    OLLAMA_CLEAN_ASSUME_YES=1   wipe all Ollama/llama model weights             │
# │    SHUTDOWN_ASSUME_YES=1       allow shutdown on non-TTY stdin (no cancel key) │
# │                                                                               │
# │  Structure                                                                    │
# │    This entry point only resolves its own directory, sources the lib/         │
# │    modules in dependency order, and launches the main menu. All behavior      │
# │    lives in lib/*.sh and lib/actions/*.sh.                                     │
# └─────────────────────────────────────────────────────────────────────────────┘

# =============================================================================
# § MODULE LOADER
#
#   Resolve this script's own directory (so it works regardless of the caller's
#   CWD or symlinks), then source each module. Order matters: colors → core →
#   logging → helpers → ui → actions → uninstaller → menu.
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
source "$LIB_DIR/actions/cleanup.sh"
source "$LIB_DIR/actions/free_memory.sh"
source "$LIB_DIR/actions/flush_dns.sh"
source "$LIB_DIR/actions/free_ports.sh"
source "$LIB_DIR/actions/kill_apps.sh"
source "$LIB_DIR/actions/docker_clean.sh"
source "$LIB_DIR/actions/ollama_clean.sh"

# shellcheck source=lib/uninstaller.sh
source "$LIB_DIR/uninstaller.sh"
# shellcheck source=lib/menu.sh
source "$LIB_DIR/menu.sh"

# =============================================================================
# § ENTRY POINT
# =============================================================================
show_main_menu
