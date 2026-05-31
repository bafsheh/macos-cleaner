#!/usr/bin/env bash
# =============================================================================
# § lib/logging.sh  ·  Output formatting primitives
#
#   Single responsibility: turn structured log calls into colorized,
#   tee'd output. Every helper writes to both the terminal and $LOG_FILE.
#
#   Requires (sourced earlier): colors.sh (RED/GRN/…/NC), core.sh ($LOG_FILE)
#
#   say   — top-level announcement      info  — indented detail
#   step  — sub-step heading            ok    — success line
#   warn  — non-fatal warning           fail  — failure line
#   section — GitHub-style banner heading
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
