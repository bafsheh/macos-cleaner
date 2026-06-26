#!/usr/bin/env bash
# =============================================================================
# § lib/logging.sh  ·  Output formatting primitives
#
#   Single responsibility: turn structured log calls into colorized,
#   tee'd output. Every helper writes to both the terminal and $LOG_FILE.
#
#   Requires (sourced earlier): colors.sh (RED/GRN/…/NC), core.sh ($LOG_FILE)
#
#   say   - top-level announcement      info  - indented detail
#   step  - sub-step heading            ok    - success line
#   warn  - non-fatal warning           fail  - failure line
#   section - bold banner heading       hr    - thin divider rule
# =============================================================================

_log()    { printf '%b\n' "$*" | tee -a "$LOG_FILE"; }

# ── status lines ─────────────────────────────────────────────────────────────
#   A consistent two-space gutter + coloured glyph gives every line an obvious
#   severity at a glance; detail lines indent one level deeper so scanning the
#   output reads as an outline.
say()     { _log "${BBLU}❯${NC} ${BOLD}$*${NC}"; }
step()    { _log "  ${BCYN}▸${NC} ${BOLD}$*${NC}"; }
info()    { _log "    ${DIM}$*${NC}"; }
ok()      { _log "  ${BGRN}✓${NC} $*"; }
warn()    { _log "  ${BYLW}▲${NC} ${YLW}$*${NC}"; }
fail()    { _log "  ${BRED}✗${NC} ${RED}$*${NC}"; }

# ── thin divider rule (optional visual breather between groups) ──────────────
hr() {
    local -i width=${1:-72}
    local rule; rule=$(printf '·%.0s' $(seq 1 "$width"))
    _log "  ${GRY}${rule}${NC}"
}

# ── bold section banner ──────────────────────────────────────────────────────
#   Renders as a clearly weighted heading: a heavy top corner with the title in
#   bright white, underlined by a full-width rule. Far more prominent than body
#   text - the closest a terminal gets to "larger" text.
section() {
    local title="$1"
    local rule; rule=$(printf '━%.0s' $(seq 1 70))
    _log ""
    _log "${TEAL}${BOLD}┏━━ ${WHT}${title}${NC}"
    _log "${TEAL}┗${rule}${NC}"
    _log ""
}
