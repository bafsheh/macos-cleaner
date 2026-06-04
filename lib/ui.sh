#!/usr/bin/env bash
# =============================================================================
# § lib/ui.sh  ·  Interactive TUI widgets
#
#   Single responsibility: render and drive terminal UI. No business logic —
#   widgets return their result via globals the caller reads.
#
#     interactive_menu          single-choice arrow menu  → MENU_RESULT
#     interactive_multiselect   checkbox list             → MULTISELECT_RESULT
#                                                           + MULTISELECT_CANCELLED
#                                                           + MULTISELECT_BACK
#     spinner_run               animated spinner around a backgrounded command
#     progress_bar              render a colored fixed-width progress bar
#     ui_banner                 styled box heading
#
#   Every widget degrades gracefully when stdout/stdin is not a TTY, and when
#   colour is disabled (NO_COLOR) every glyph still renders as plain text.
#   Requires (sourced earlier): colors.sh
# =============================================================================

# =============================================================================
# § interactive_menu TITLE ITEM...
#
#   Arrow-key navigable full-screen menu.
#   Sets global MENU_RESULT to the 0-based index of the chosen item.
#   Falls back to a plain numbered prompt when stdin is not a terminal.
# =============================================================================

# ── render one menu row (selected row gets a highlighted bar) ────────────────
_menu_row() {
    local -i idx=$1 sel=$2; shift 2
    local label="$1"
    if (( idx == sel )); then
        printf "  ${HL}${BOLD}${WHT} ❯ %s ${NC}\n" "$label"
    else
        printf "    ${DIM}%s${NC}\n" "$label"
    fi
}

interactive_menu() {
    local title="$1"; shift
    local -a items=("$@")
    local -i n=${#items[@]} sel=0 i

    # ── non-interactive fallback ─────────────────────────────────────────────
    if [[ ! -t 0 ]]; then
        printf '\n%s\n' "$title"
        for (( i=0; i<n; i++ )); do
            printf '  %d.  %s\n' "$(( i+1 ))" "${items[i]}"
        done
        printf 'Enter choice [1-%d]: ' "$n"
        local ans; read -r ans
        MENU_RESULT=$(( ans - 1 ))
        (( MENU_RESULT < 0 || MENU_RESULT >= n )) && MENU_RESULT=$(( n-1 ))
        return
    fi

    tput civis 2>/dev/null       # hide cursor while navigating

    printf '\n'
    printf "  ${ACCENT}${BOLD}%s${NC}\n" "$title"
    printf "  ${DIM}↑ ↓ move  ·  Enter select  ·  q quit${NC}\n\n"

    for (( i=0; i<n; i++ )); do _menu_row "$i" "$sel" "${items[i]}"; done

    # ── input loop ───────────────────────────────────────────────────────────
    local key seq
    while true; do
        IFS= read -rsn1 key

        if [[ $key == $'\x1b' ]]; then
            IFS= read -rsn2 -t 1 seq 2>/dev/null || seq=''
            key="${key}${seq}"
        fi

        case $key in
            $'\x1b[A') (( sel > 0   )) && (( sel-- )) ;;   # ↑
            $'\x1b[B') (( sel < n-1 )) && (( sel++ )) ;;   # ↓
            $'\x1b[H') sel=0 ;;                             # Home
            $'\x1b[F') (( sel = n-1 )) ;;                  # End
            '') break ;;                                    # Enter
            q|Q) (( sel = n-1 )); break ;;                 # q → last item
        esac

        # ── redraw ───────────────────────────────────────────────────────────
        tput cuu "$n" 2>/dev/null
        for (( i=0; i<n; i++ )); do
            printf '\r'; tput el 2>/dev/null
            _menu_row "$i" "$sel" "${items[i]}"
        done
    done

    tput cnorm 2>/dev/null       # restore cursor
    MENU_RESULT=$sel
}

# =============================================================================
# § interactive_multiselect TITLE ITEM...
#
#   Arrow-key navigable checkbox list (select / unselect).
#   ITEM 0 is treated as a special "Select all" toggle that mirrors the
#   combined state of every *action* row.
#
#   Optional input globals (read once, then reset to defaults):
#     MS_TAIL_CONTROLS   number of trailing rows that are NOT governed by the
#                        "Select all" row or the 'a' key (e.g. a "Shut down"
#                        toggle + a "Back" row). Default 0.
#     MS_BACK_ROW        full item index (0-based, where 0 = "Select all") of a
#                        row that acts as "Back": activating it (Enter or space
#                        while highlighted) exits with MULTISELECT_BACK=1. -1 to
#                        disable. Default -1.
#
#   Keys: ↑ ↓ navigate · space toggle · a toggle-all · Enter confirm · q cancel
#
#   Result globals:
#     MULTISELECT_RESULT     space-separated, 0-based indices of the selected
#                            rows (row index minus the "Select all" row at 0).
#                            Includes any selected trailing toggle rows. Empty
#                            if none.
#     MULTISELECT_CANCELLED  1 if the user pressed q / quit, else 0.
#     MULTISELECT_BACK       1 if the user activated the Back row, else 0.
#
#   Falls back to a plain numbered prompt when stdin is not a terminal.
# =============================================================================
interactive_multiselect() {
    local title="$1"; shift
    local -a items=("$@")
    local -i n=${#items[@]} sel=0 i
    local -a SELECTED=()
    for (( i=0; i<n; i++ )); do SELECTED[i]=0; done

    # ── absorb optional input globals, then reset so they never leak ──────────
    local -i tail=${MS_TAIL_CONTROLS:-0}
    local -i back_row=${MS_BACK_ROW:--1}
    MS_TAIL_CONTROLS=0
    MS_BACK_ROW=-1

    # last index that "Select all" governs (action rows are 1..last_action)
    local -i last_action=$(( n - 1 - tail ))
    (( last_action < 0 )) && last_action=0

    MULTISELECT_CANCELLED=0
    MULTISELECT_BACK=0
    MULTISELECT_RESULT=''

    # ── recompute the "Select all" row (index 0) from the action rows only ────
    _ms_sync_all() {
        local -i j all=1
        for (( j=1; j<=last_action; j++ )); do (( SELECTED[j] == 0 )) && { all=0; break; }; done
        SELECTED[0]=$all
    }
    # ── set the all-row + every action row to STATE (control rows untouched) ──
    _ms_set_all() {
        local -i state=$1 j
        SELECTED[0]=$state
        for (( j=1; j<=last_action; j++ )); do SELECTED[j]=$state; done
    }

    # ── non-interactive fallback ─────────────────────────────────────────────
    if [[ ! -t 0 || ! -t 1 ]]; then
        printf '\n%s\n' "$title"
        for (( i=1; i<n; i++ )); do
            printf '  %d.  %s\n' "$i" "${items[i]}"
        done
        printf 'Enter numbers to run (e.g. "1 3"), "a" for all, blank to cancel: '
        local ans; read -r ans
        local -a picked=()
        if [[ $ans == [aA] ]]; then
            for (( i=1; i<=last_action; i++ )); do picked+=("$(( i-1 ))"); done
        elif [[ -n $ans ]]; then
            local num
            for num in $ans; do
                [[ $num =~ ^[0-9]+$ ]] || continue
                (( num >= 1 && num <= n-1 )) || continue
                if (( back_row >= 0 && num == back_row )); then
                    MULTISELECT_BACK=1; MULTISELECT_RESULT=''; return
                fi
                picked+=("$(( num-1 ))")
            done
        fi
        (( ${#picked[@]} == 0 )) && MULTISELECT_CANCELLED=1
        MULTISELECT_RESULT="${picked[*]:-}"
        return
    fi

    # ── render a single row ───────────────────────────────────────────────────
    _ms_row() {
        local -i idx=$1
        local cursor
        (( idx == sel )) && cursor="${BCYN}❯${NC}" || cursor=' '

        # Back row renders as an action (no checkbox), not a toggle.
        if (( back_row >= 0 && idx == back_row )); then
            if (( idx == sel )); then
                printf "  %b  ${HL}${BOLD}${WHT} ↩ %s ${NC}\n" "$cursor" "${items[idx]}"
            else
                printf "  %b  ${DIM}↩ %s${NC}\n" "$cursor" "${items[idx]}"
            fi
            return
        fi

        local box
        if (( SELECTED[idx] == 1 )); then box="${BGRN}[✓]${NC}"; else box="${DIM}[ ]${NC}"; fi
        if (( idx == sel )); then
            printf "  %b  %b  ${BOLD}${WHT}%s${NC}\n" "$cursor" "$box" "${items[idx]}"
        else
            printf "  %b  %b  ${DIM}%s${NC}\n" "$cursor" "$box" "${items[idx]}"
        fi
    }

    tput civis 2>/dev/null       # hide cursor while navigating

    printf '\n'
    printf "  ${ACCENT}${BOLD}%s${NC}\n" "$title"
    printf "  ${DIM}↑ ↓ move  ·  space toggle  ·  a all  ·  Enter run  ·  q cancel${NC}\n\n"

    for (( i=0; i<n; i++ )); do _ms_row "$i"; done

    # ── input loop ───────────────────────────────────────────────────────────
    local key seq
    while true; do
        IFS= read -rsn1 key
        if [[ $key == $'\x1b' ]]; then
            IFS= read -rsn2 -t 1 seq 2>/dev/null || seq=''
            key="${key}${seq}"
        fi

        case $key in
            $'\x1b[A') (( sel > 0   )) && (( sel-- )) ;;            # ↑
            $'\x1b[B') (( sel < n-1 )) && (( sel++ )) ;;            # ↓
            $'\x1b[H') sel=0 ;;                                      # Home
            $'\x1b[F') (( sel = n-1 )) ;;                           # End
            ' ')                                                    # space toggle
                if (( back_row >= 0 && sel == back_row )); then
                    MULTISELECT_BACK=1; break
                elif (( sel == 0 )); then
                    _ms_set_all "$(( 1 - SELECTED[0] ))"
                else
                    SELECTED[sel]=$(( 1 - SELECTED[sel] )); _ms_sync_all
                fi ;;
            a|A) _ms_set_all "$(( 1 - SELECTED[0] ))" ;;            # toggle-all
            '')                                                     # Enter
                if (( back_row >= 0 && sel == back_row )); then
                    MULTISELECT_BACK=1
                fi
                break ;;
            q|Q) MULTISELECT_CANCELLED=1; break ;;                 # cancel
        esac

        # ── redraw ─────────────────────────────────────────────────────────────
        tput cuu "$n" 2>/dev/null
        for (( i=0; i<n; i++ )); do
            printf '\r'; tput el 2>/dev/null
            _ms_row "$i"
        done
    done

    tput cnorm 2>/dev/null       # restore cursor
    unset -f _ms_row _ms_sync_all _ms_set_all

    if (( MULTISELECT_CANCELLED == 1 || MULTISELECT_BACK == 1 )); then
        MULTISELECT_RESULT=''; return
    fi

    local -a picked=()
    for (( i=1; i<n; i++ )); do (( SELECTED[i] == 1 )) && picked+=("$(( i-1 ))"); done
    MULTISELECT_RESULT="${picked[*]:-}"
}

# =============================================================================
# § spinner_run MESSAGE COMMAND [ARG...]
#
#   Runs COMMAND in the background while animating a braille spinner (with a
#   live elapsed-seconds counter and a gentle colour pulse) next to MESSAGE,
#   then prints a ✓/✗ line and returns COMMAND's exit code.
#   On a non-TTY it simply runs the command and prints a plain status line.
# =============================================================================
spinner_run() {
    local msg="$1"; shift

    if [[ ! -t 1 ]]; then
        "$@"; local -i rc=$?
        (( rc == 0 )) && ok "$msg" || fail "$msg (exit=$rc)"
        return $rc
    fi

    local frames='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local -a fcol=("$CYN" "$BCYN" "$TEAL" "$ACCENT")
    "$@" & local -i pid=$! i=0 t0 el
    t0=$(date +%s)
    tput civis 2>/dev/null
    while kill -0 "$pid" 2>/dev/null; do
        el=$(( $(date +%s) - t0 ))
        printf "\r  %b%s%b %s ${DIM}(%ds)${NC} " \
            "${fcol[i%4]}" "${frames:i%${#frames}:1}" "$NC" "$msg" "$el"
        (( i++ )); sleep 0.08
    done
    wait "$pid"; local -i rc=$?
    el=$(( $(date +%s) - t0 ))
    tput cnorm 2>/dev/null
    printf '\r'; tput el 2>/dev/null
    (( rc == 0 )) && printf "  ${BGRN}✓${NC} %s ${DIM}(%ds)${NC}\n" "$msg" "$el" \
                  || printf "  ${BRED}✗${NC} %s ${DIM}(exit=%d)${NC}\n" "$msg" "$rc"
    return $rc
}

# =============================================================================
# § progress_bar CURRENT TOTAL [WIDTH]
#
#   Prints a fixed-width progress bar with a percentage, no newline.
#   When 24-bit colour is available the filled run is drawn as a smooth
#   green→azure gradient; otherwise it degrades to a plain ASCII bar.
# =============================================================================
progress_bar() {
    local -i cur=$1 tot=$2 width=${3:-28}
    (( tot <= 0 )) && tot=1
    local -i filled=$(( cur * width / tot )) pct=$(( cur * 100 / tot )) i
    (( filled > width )) && filled=width
    (( pct > 100 )) && pct=100

    # ── plain fallback (colour disabled) ─────────────────────────────────────
    if (( ! _COLOR )); then
        local bar=''
        for (( i=0; i<filled; i++ ))     do bar+='#'; done
        for (( i=filled; i<width; i++ )) do bar+='-'; done
        printf '  [%s] %3d%%' "$bar" "$pct"
        return
    fi

    # ── colour but no truecolor: solid 256-colour fill (no per-cell gradient) ─
    if (( ! _TRUECOLOR )); then
        local fbar='' ebar=''
        for (( i=0; i<filled; i++ ))     do fbar+='█'; done
        for (( i=filled; i<width; i++ )) do ebar+='░'; done
        printf "  ${ORG}%s${GRY}%s${NC}  ${BOLD}%3d%%${NC}" "$fbar" "$ebar" "$pct"
        return
    fi

    # ── gradient fill: green (46,204,113) → azure (52,152,219) ───────────────
    local out='  '
    local -i r g b denom=$(( width > 1 ? width - 1 : 1 ))
    for (( i=0; i<filled; i++ )); do
        r=$(( 46  + (52  - 46 ) * i / denom ))
        g=$(( 204 + (152 - 204) * i / denom ))
        b=$(( 113 + (219 - 113) * i / denom ))
        out+=$(printf '\033[38;2;%d;%d;%dm█' "$r" "$g" "$b")
    done
    out+="${GRY}"
    for (( i=filled; i<width; i++ )) do out+='░'; done
    out+="${NC}  ${BOLD}$(printf '%3d' "$pct")%${NC}"
    printf '%s' "$out"
}

# =============================================================================
# § ui_banner TITLE [SUBTITLE]
#
#   Renders a compact styled box heading used to introduce a phase/action.
# =============================================================================
ui_banner() {
    local title="$1" subtitle="${2:-}"
    local rule; rule=$(printf '─%.0s' {1..54})
    printf '\n'
    printf "  ${TEAL}┌%s┐${NC}\n" "$rule"
    printf "  ${TEAL}│${NC} ${BOLD}${WHT}%-52s${NC} ${TEAL}│${NC}\n" "$title"
    [[ -n $subtitle ]] && printf "  ${TEAL}│${NC} ${DIM}%-52s${NC} ${TEAL}│${NC}\n" "$subtitle"
    printf "  ${TEAL}└%s┘${NC}\n" "$rule"
}
