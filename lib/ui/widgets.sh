#!/usr/bin/env bash
# =============================================================================
# § lib/ui/widgets.sh  ·  Progress, spinner, and banner widgets
#
#   Single responsibility: the small "something is happening" building blocks.
#
#     ui_spin               one frame of the braille spinner       → REPLY
#     ui_bar                a progress bar as a string             → REPLY
#     progress_bar          print a bar with its percentage
#     ui_status             repaint a one-line live status (spinner · bar · text)
#     ui_status_clear       erase that line again
#     ui_pause              "press any key", then clear the screen
#     spinner_run           spinner around a backgrounded command
#     ui_banner             boxed heading
#
#   The live pieces only animate on a terminal; when output is piped they print
#   nothing (or a single plain line), so logs never fill with redraw noise.
#   When colour is disabled every glyph still renders as plain text.
#
#   Requires (sourced earlier): colors.sh, logging.sh, ui/term.sh
# =============================================================================

declare -r _UI_SPIN_FRAMES='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
declare -r _UI_BAR_EIGHTHS=' ▏▎▍▌▋▊▉'       # a cell filled 0/8 … 7/8

# =============================================================================
# § ui_spin FRAME
#
#   Arguments:
#     FRAME   a counter the caller increments once per redraw
#   Globals:
#     writes REPLY   the spinner glyph for that frame, coloured
# =============================================================================
ui_spin() {
    local -i f=$1
    local -a tint=("$CYN" "$BCYN" "$TEAL" "$ACCENT")
    REPLY="${tint[f / 3 % 4]}${_UI_SPIN_FRAMES:f % 10:1}${NC}"
}

# =============================================================================
# § ui_bar CURRENT TOTAL [WIDTH] [COLOUR]
#
#   Builds a progress bar WIDTH cells wide. Each cell has eight sub-steps
#   (▏▎▍▌▋▊▉█), so even a narrow bar moves smoothly. With 24-bit colour the
#   filled run is a green→azure gradient; with 256 colours a solid green; with
#   colour disabled it degrades to plain ASCII ("####----").
#
#   Arguments:
#     CURRENT  units done
#     TOTAL    units in all (0 or less is treated as 1)
#     WIDTH    cells, default 28
#     COLOUR   an escape from colors.sh for a solid fill instead of the
#              gradient (a gauge that turns amber, then red)
#   Globals:
#     writes REPLY   the bar, without brackets or percentage
# =============================================================================
ui_bar() {
    local -i cur=$1 tot=$2 width=${3:-28}
    local solid=${4:-}
    (( tot <= 0 )) && tot=1
    (( cur > tot )) && cur=tot
    (( cur < 0 )) && cur=0
    local -i units=$(( cur * width * 8 / tot )) full part i
    (( full = units / 8, part = units % 8 ))
    local out='' cell

    # ── plain fallback (colour disabled) ─────────────────────────────────────
    if (( ! _COLOR )); then
        printf -v out '%*s' "$full" ''; out=${out// /#}
        printf -v cell '%*s' "$(( width - full ))" ''
        REPLY="${out}${cell// /-}"
        return
    fi

    # The empty part is a dark track (background colour), so a half-filled
    # cell sits flush against it.
    local track; track=$(_sgr '48;5;237' '100')

    if (( _TRUECOLOR )) && [[ -z $solid ]]; then
        # gradient fill: green (46,204,113) → azure (52,152,219)
        local -i r g b denom=$(( width > 1 ? width - 1 : 1 ))
        for (( i=0; i<full; i++ )); do
            (( r = 46 + 6 * i / denom, g = 204 - 52 * i / denom, b = 113 + 106 * i / denom ))
            printf -v cell '\033[38;2;%d;%d;%dm█' "$r" "$g" "$b"
            out+=$cell
        done
        if (( part > 0 && full < width )); then
            (( r = 46 + 6 * full / denom, g = 204 - 52 * full / denom, b = 113 + 106 * full / denom ))
            printf -v cell '\033[38;2;%d;%d;%dm' "$r" "$g" "$b"
            out+="${track}${cell}${_UI_BAR_EIGHTHS:part:1}"
        fi
    else
        [[ -n $solid ]] || solid=$GRN
        printf -v cell '%*s' "$full" ''
        out="${solid}${cell// /█}"
        (( part > 0 && full < width )) && out+="${track}${solid}${_UI_BAR_EIGHTHS:part:1}"
    fi

    local -i rest=$(( width - full - (part > 0 && full < width ? 1 : 0) ))
    printf -v cell '%*s' "$rest" ''
    REPLY="${out}${track}${cell}${NC}"
}

# =============================================================================
# § progress_bar CURRENT TOTAL [WIDTH]
#
#   Prints "  <bar>  NN%" with no trailing newline (see ui_bar for the look).
# =============================================================================
progress_bar() {
    local -i cur=$1 tot=$2 width=${3:-28} pct
    (( tot <= 0 )) && tot=1
    (( pct = cur * 100 / tot )); (( pct > 100 )) && pct=100
    ui_bar "$cur" "$tot" "$width"
    if (( _COLOR )); then
        printf "  %s  ${BOLD}%3d%%${NC}" "$REPLY" "$pct"
    else
        printf '  [%s] %3d%%' "$REPLY" "$pct"
    fi
}

# =============================================================================
# § ui_status FRAME CURRENT TOTAL TEXT
#
#   Repaints a single live line in place:
#
#       ⠹ ███████████▌         12/31  ~/Library/Containers
#
#   Call it in a loop with an increasing FRAME; follow the last call with
#   ui_status_clear (or print a final line starting with \r). Prints nothing
#   when stdout is not a terminal, so progress never pollutes a pipe or log.
#
#   Arguments:
#     FRAME    redraw counter (drives the spinner)
#     CURRENT  units done        TOTAL  units in all (0 hides the bar)
#     TEXT     what is happening right now; cut to the window width
# =============================================================================
ui_status() {
    [[ -t 1 ]] || return 0
    local -i frame=$1 cur=$2 tot=$3 room
    local text=$4 spin bar=''
    ui_spin "$frame"; spin=$REPLY
    room=$(( UI_COLS - 8 ))
    if (( tot > 0 )); then
        ui_bar "$cur" "$tot" 20
        bar="${REPLY} ${BOLD}${cur}/${tot}${NC}  "
        room=$(( room - 24 - ${#cur} - ${#tot} ))
    fi
    (( room < 10 )) && room=10
    (( ${#text} > room )) && text="…${text: -$(( room - 1 ))}"
    printf '\r  %s %s%s%s%s\033[K' "$spin" "$bar" "$DIM" "$text" "$NC"
}

# Erases the line drawn by ui_status.
ui_status_clear() { [[ -t 1 ]] && printf '\r\033[K'; return 0; }

# =============================================================================
# § ui_pause [MESSAGE]
#
#   The last step of an action: keeps its result on screen until it has been
#   read, then clears the screen so the menu that follows starts clean instead
#   of being drawn underneath the old output.
#
#       ────────────────────────────────────────────────────────
#       ✓ Finished.  Press any key to clear the screen and return to the menu.
#
#   Does nothing when stdin or stdout is not a terminal.
#
#   Arguments:
#     MESSAGE  what the key does; defaults to the line above
# =============================================================================
ui_pause() {
    [[ -t 0 && -t 1 ]] || return 0
    local rule
    printf -v rule '%*s' 56 ''
    printf "  ${GRY}%s${NC}\n" "${rule// /─}"
    printf "  ${BGRN}✓${NC} ${BOLD}Finished.${NC}  ${BYLW}%s${NC} " \
        "${1:-Press any key to clear the screen and return to the menu.}"
    IFS= read -rsn1 _ || true
    printf '\033[H\033[2J'        # cursor home + clear the screen
}

# =============================================================================
# § spinner_run MESSAGE COMMAND [ARG...]
#
#   Runs COMMAND in the background while animating a spinner (with a live
#   elapsed-seconds counter) next to MESSAGE, then prints a ✓/✗ line.
#   On a non-TTY it simply runs the command and prints a plain status line.
#
#   Returns:
#     COMMAND's exit code
# =============================================================================
spinner_run() {
    local msg="$1"; shift

    if [[ ! -t 1 ]]; then
        "$@"; local -i rc=$?
        (( rc == 0 )) && ok "$msg" || fail "$msg (exit=$rc)"
        return $rc
    fi

    "$@" & local -i pid=$! frame=0 t0=$SECONDS el
    ui_cursor_hide
    while kill -0 "$pid" 2>/dev/null; do
        (( el = SECONDS - t0 ))
        ui_spin "$frame"
        printf "\r  %s %s ${DIM}(%ds)${NC} \033[K" "$REPLY" "$msg" "$el"
        (( frame++ )); sleep 0.08
    done
    wait "$pid"; local -i rc=$?
    (( el = SECONDS - t0 ))
    ui_cursor_show
    printf '\r\033[K'
    (( rc == 0 )) && printf "  ${BGRN}✓${NC} %s ${DIM}(%ds)${NC}\n" "$msg" "$el" \
                  || printf "  ${BRED}✗${NC} %s ${DIM}(exit=%d)${NC}\n" "$msg" "$rc"
    return $rc
}

# =============================================================================
# § ui_banner TITLE [SUBTITLE]
#
#   Renders a compact rounded box heading used to introduce a phase/action.
# =============================================================================
ui_banner() {
    local title="$1" subtitle="${2:-}" rule
    printf -v rule '%*s' 54 ''; rule=${rule// /─}
    printf '\n'
    printf "  ${TEAL}╭%s╮${NC}\n" "$rule"
    printf "  ${TEAL}│${NC} ${WHT}%-52s${NC} ${TEAL}│${NC}\n" "$title"
    [[ -n $subtitle ]] && printf "  ${TEAL}│${NC} ${DIM}%-52s${NC} ${TEAL}│${NC}\n" "$subtitle"
    printf "  ${TEAL}╰%s╯${NC}\n" "$rule"
}
