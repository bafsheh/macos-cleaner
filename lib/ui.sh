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
#     spinner_run               animated spinner around a backgrounded command
#     progress_bar              render a colored fixed-width progress bar
#     ui_banner                 styled box heading
#
#   Every widget degrades gracefully when stdout/stdin is not a TTY.
#   Requires (sourced earlier): colors.sh
# =============================================================================

# =============================================================================
# § interactive_menu TITLE ITEM...
#
#   Arrow-key navigable full-screen menu.
#   Sets global MENU_RESULT to the 0-based index of the chosen item.
#   Falls back to a plain numbered prompt when stdin is not a terminal.
# =============================================================================
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
    printf "  ${BLU}%s${NC}\n" "$title"
    printf "  ${DIM}↑ ↓ arrows  ·  Enter to select  ·  q to quit${NC}\n\n"

    # ── initial render ───────────────────────────────────────────────────────
    for (( i=0; i<n; i++ )); do
        if (( i == sel )); then
            printf "  ${CYN}❯  %s${NC}\n" "${items[i]}"
        else
            printf "  ${DIM}   %s${NC}\n" "${items[i]}"
        fi
    done

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
            if (( i == sel )); then
                printf "  ${CYN}❯  %s${NC}\n" "${items[i]}"
            else
                printf "  ${DIM}   %s${NC}\n" "${items[i]}"
            fi
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
#   combined state of every other row.
#
#   Keys: ↑ ↓ navigate · space toggle · a toggle-all · Enter confirm · q cancel
#
#   Result globals:
#     MULTISELECT_RESULT     space-separated, 0-based indices of the selected
#                            *action* rows (i.e. row index minus the
#                            "Select all" row at index 0). Empty if none.
#     MULTISELECT_CANCELLED  1 if the user pressed q / quit, else 0.
#
#   Falls back to a plain numbered prompt when stdin is not a terminal.
# =============================================================================
interactive_multiselect() {
    local title="$1"; shift
    local -a items=("$@")
    local -i n=${#items[@]} sel=0 i
    local -a SELECTED=()
    for (( i=0; i<n; i++ )); do SELECTED[i]=0; done

    MULTISELECT_CANCELLED=0
    MULTISELECT_RESULT=''

    # ── recompute the "Select all" row (index 0) from the action rows ─────────
    _ms_sync_all() {
        local -i j all=1
        for (( j=1; j<n; j++ )); do (( SELECTED[j] == 0 )) && { all=0; break; }; done
        SELECTED[0]=$all
    }
    # ── set every action row (and the all-row) to STATE ───────────────────────
    _ms_set_all() {
        local -i state=$1 j
        for (( j=0; j<n; j++ )); do SELECTED[j]=$state; done
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
            for (( i=1; i<n; i++ )); do picked+=("$(( i-1 ))"); done
        elif [[ -n $ans ]]; then
            local num
            for num in $ans; do
                [[ $num =~ ^[0-9]+$ ]] && (( num >= 1 && num <= n-1 )) && picked+=("$(( num-1 ))")
            done
        fi
        (( ${#picked[@]} == 0 )) && MULTISELECT_CANCELLED=1
        MULTISELECT_RESULT="${picked[*]:-}"
        return
    fi

    # ── render a single row ───────────────────────────────────────────────────
    _ms_row() {
        local -i idx=$1
        local cursor box
        (( idx == sel )) && cursor="${CYN}❯${NC}" || cursor=' '
        if (( SELECTED[idx] == 1 )); then box="${GRN}[✓]${NC}"; else box="${DIM}[ ]${NC}"; fi
        if (( idx == sel )); then
            printf "  %b  %b  ${BOLD}${CYN}%s${NC}\n" "$cursor" "$box" "${items[idx]}"
        else
            printf "  %b  %b  ${DIM}%s${NC}\n" "$cursor" "$box" "${items[idx]}"
        fi
    }

    tput civis 2>/dev/null       # hide cursor while navigating

    printf '\n'
    printf "  ${BLU}%s${NC}\n" "$title"
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
                if (( sel == 0 )); then
                    _ms_set_all "$(( 1 - SELECTED[0] ))"
                else
                    SELECTED[sel]=$(( 1 - SELECTED[sel] )); _ms_sync_all
                fi ;;
            a|A) _ms_set_all "$(( 1 - SELECTED[0] ))" ;;            # toggle-all
            '') break ;;                                            # Enter → confirm
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

    (( MULTISELECT_CANCELLED == 1 )) && { MULTISELECT_RESULT=''; return; }

    local -a picked=()
    for (( i=1; i<n; i++ )); do (( SELECTED[i] == 1 )) && picked+=("$(( i-1 ))"); done
    MULTISELECT_RESULT="${picked[*]:-}"
}

# =============================================================================
# § spinner_run MESSAGE COMMAND [ARG...]
#
#   Runs COMMAND in the background while animating a braille spinner next to
#   MESSAGE, then prints a ✓/✗ line and returns COMMAND's exit code.
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
    "$@" & local -i pid=$! i=0
    tput civis 2>/dev/null
    while kill -0 "$pid" 2>/dev/null; do
        printf "\r  ${CYN}%s${NC} %s" "${frames:i++%${#frames}:1}" "$msg"
        sleep 0.08
    done
    wait "$pid"; local -i rc=$?
    tput cnorm 2>/dev/null
    printf '\r'; tput el 2>/dev/null
    (( rc == 0 )) && printf "  ${GRN}✓${NC} %s\n" "$msg" \
                  || printf "  ${RED}✗${NC} %s ${DIM}(exit=%d)${NC}\n" "$msg" "$rc"
    return $rc
}

# =============================================================================
# § progress_bar CURRENT TOTAL [WIDTH]
#
#   Prints a colored fixed-width progress bar with a percentage, no newline.
#   Filled cells use the orange accent; empty cells are dim grey.
# =============================================================================
progress_bar() {
    local -i cur=$1 tot=$2 width=${3:-28}
    (( tot <= 0 )) && tot=1
    local -i filled=$(( cur * width / tot )) pct=$(( cur * 100 / tot )) i
    (( filled > width )) && filled=width
    (( pct > 100 )) && pct=100

    local fbar='' ebar=''
    for (( i=0; i<filled; i++ ))      do fbar+='█'; done
    for (( i=filled; i<width; i++ ))  do ebar+='░'; done
    printf "  ${ORG}%s${GRY}%s${NC}  ${BOLD}%3d%%${NC}" "$fbar" "$ebar" "$pct"
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
