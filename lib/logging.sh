#!/usr/bin/env bash
# =============================================================================
# § lib/logging.sh  ·  Output formatting primitives
#
#   Single responsibility: turn structured log calls into output. Every helper
#   writes a coloured line to the terminal and a plain, time-stamped copy to
#   $LOG_FILE - the log file never contains colour codes, so it stays readable
#   in any editor and greps cleanly.
#
#   Requires (sourced earlier): colors.sh (RED/GRN/…/NC), core.sh ($LOG_FILE)
#
#   The lines form an outline, most important first:
#
#     section  ┏━━ TITLE            one per action / phase
#     say      ❯ announcement       what is about to happen
#     step       ▸ [label]          one unit of work
#     kv           key     : value  a fact about that step
#     info         free-form detail
#     ok         ✓ outcome          it worked
#     warn       ▲ outcome          it worked partly, or was skipped
#     fail       ✗ outcome          it did not work
#     hr         ·····              thin divider
#     summary_card                  boxed recap at the end of an action
#
#   Helpers: strip_ansi · human_duration · log_only (log file only)
# =============================================================================

# =============================================================================
# § strip_ansi TEXT
#
#   Removes ANSI escape sequences (colours, cursor moves) from TEXT.
#
#   Arguments:
#     TEXT   the string to clean
#   Globals:
#     writes REPLY   the cleaned string (no subshell needed by the caller)
# =============================================================================
strip_ansi() {
    local s=$1 rest
    REPLY=''
    while [[ $s == *$'\033['* ]]; do
        REPLY+=${s%%$'\033['*}
        rest=${s#*$'\033['}
        s=${rest#*[a-zA-Z]}      # drop the parameters up to the final letter
    done
    REPLY+=$s
}

# =============================================================================
# § human_duration SECONDS
#
#   Globals:
#     writes REPLY   "42s", "3m 05s" or "1h 12m"
# =============================================================================
human_duration() {
    local -i s=$1
    if   (( s < 60 ));   then REPLY="${s}s"
    elif (( s < 3600 )); then printf -v REPLY '%dm %02ds' "$(( s / 60 ))" "$(( s % 60 ))"
    else                      printf -v REPLY '%dh %02dm' "$(( s / 3600 ))" "$(( s % 3600 / 60 ))"
    fi
}

# =============================================================================
# § _log MESSAGE...
#
#   The one place a log line is emitted: coloured to stdout, plain and
#   time-stamped ("[+MM:SS]" since the run started) to the log file.
#
#   Globals:
#     reads  LOG_FILE (the parallel cleanup jobs set it to /dev/null: their
#            buffered output is appended to the log by run_parallel instead)
# =============================================================================
_log() {
    printf '%s\n' "$*"
    [[ $LOG_FILE == /dev/null ]] && return 0
    strip_ansi "$*"
    printf '[+%02d:%02d] %s\n' "$(( SECONDS / 60 ))" "$(( SECONDS % 60 ))" "$REPLY" >> "$LOG_FILE"
}

# =============================================================================
# § log_only MESSAGE...
#
#   Writes a line to the log file only - for detail that would drown the
#   screen (long lists, raw command output) but is worth keeping.
# =============================================================================
log_only() {
    [[ $LOG_FILE == /dev/null ]] && return 0
    strip_ansi "$*"
    printf '[+%02d:%02d] %s\n' "$(( SECONDS / 60 ))" "$(( SECONDS % 60 ))" "$REPLY" >> "$LOG_FILE"
}

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

# =============================================================================
# § kv KEY VALUE
#
#   One aligned "key : value" fact under a step, e.g.
#       path     : ~/Library/Caches/com.example
#   The key is dimmed and the value keeps the normal text colour, so the eye
#   lands on the value.
# =============================================================================
kv() {
    local key=$1; shift
    _log "$(printf '    %s%-8s :%s %s' "$DIM" "$key" "$NC" "$*")"
}

# =============================================================================
# § hr [WIDTH]
#
#   Thin divider rule - an optional visual breather between groups.
# =============================================================================
hr() {
    local -i width=${1:-72}
    local rule; printf -v rule '%*s' "$width" ''
    _log "  ${GRY}${rule// /·}${NC}"
}

# =============================================================================
# § section TITLE
#
#   Bold section banner: a heavy top corner with the title, underlined by a
#   full-width rule. The live panel of run_parallel recognises a job's section
#   by the "┏━━ " prefix - keep the two in step.
# =============================================================================
section() {
    local title="$1" rule
    printf -v rule '%*s' 70 ''
    _log ""
    _log "${TEAL}${BOLD}┏━━ ${NC}${WHT}${title}${NC}"
    _log "${TEAL}┗${rule// /━}${NC}"
    _log ""
}

# =============================================================================
# § summary_card TITLE LINE...
#
#   Boxed recap printed at the end of an action, so the outcome is the last
#   and clearest thing on screen:
#
#     ╭─ Uninstall summary ──────────────────────────────────╮
#     │ ✓ 14 items removed · 1.8 GB freed                     │
#     │ ▲ 2 items kept for review                             │
#     ╰───────────────────────────────────────────────────────╯
#
#   Arguments:
#     TITLE    heading set into the top border
#     LINE...  body lines; a line may start with a tag that picks its glyph:
#                "ok:"   → green ✓      "warn:" → amber ▲
#                "fail:" → red ✗        "dim:"  → grey detail, no glyph
#              untagged lines print as plain text
#   Globals:
#     reads UI_COLS  the window width, when the UI module has measured it
# =============================================================================
summary_card() {
    local title=$1; shift
    local -i width=62 pad longest=0 limit=${UI_COLS:-100}
    local line body glyph colour rule plain

    # The box grows to fit its longest line, up to the window width; anything
    # longer still is cut with an ellipsis so the border never breaks.
    for line in "$@"; do
        strip_ansi "${line#*:}"
        (( ${#REPLY} > longest )) && longest=${#REPLY}
    done
    (( limit -= 6 )); (( limit < 40 )) && limit=40
    (( longest + 4 > width )) && width=$(( longest + 4 ))
    (( width > limit )) && width=$limit

    printf -v rule '%*s' "$(( width - ${#title} - 3 ))" ''
    _log ""
    _log "  ${TEAL}╭─ ${NC}${BOLD}${title}${NC} ${TEAL}${rule// /─}╮${NC}"
    for line in "$@"; do
        glyph=' ' colour=''
        case $line in
            ok:*)   glyph="${BGRN}✓${NC}"; body=${line#ok:} ;;
            warn:*) glyph="${BYLW}▲${NC}"; body=${line#warn:}; colour=$YLW ;;
            fail:*) glyph="${BRED}✗${NC}"; body=${line#fail:}; colour=$RED ;;
            dim:*)  body=${line#dim:}; colour=$DIM ;;
            *)      body=$line ;;
        esac
        strip_ansi "$body"; plain=$REPLY
        if (( ${#plain} > width - 4 )); then
            plain="${plain:0:width-5}…"; body=$plain
        fi
        (( pad = width - 3 - ${#plain} ))
        _log "$(printf '  %s│%s %s %s%s%s%*s%s│%s' \
            "$TEAL" "$NC" "$glyph" "$colour" "$body" "$NC" "$pad" '' "$TEAL" "$NC")"
    done
    printf -v rule '%*s' "$width" ''
    _log "  ${TEAL}╰${rule// /─}╯${NC}"
    _log ""
}
