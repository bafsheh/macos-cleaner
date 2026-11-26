#!/usr/bin/env bash
# =============================================================================
# § lib/ui/select.sh  ·  Arrow-key menus
#
#   Single responsibility: the two list widgets used for short, fixed lists.
#   No business logic - each returns its result through globals.
#
#     interactive_menu          single choice   → MENU_RESULT
#     interactive_multiselect   checkbox list   → MULTISELECT_RESULT
#                                                 + MULTISELECT_CANCELLED
#                                                 + MULTISELECT_BACK
#
#   An ITEM may carry a description after a TAB character:
#
#       "Clean up<TAB>caches · logs · package stores · Trash"
#
#   The label and the description are drawn as two aligned columns, the
#   description in a quieter colour (red when it starts with ⚠). Items without
#   a TAB render exactly as before.
#
#   Long lists that need scrolling, filtering or live updates use ui_picker
#   (lib/ui/picker.sh) instead. Both widgets fall back to a plain numbered
#   prompt when stdin is not a terminal.
#
#   Requires (sourced earlier): colors.sh, ui/term.sh
# =============================================================================

# =============================================================================
# § _ui_label_width ITEM...
#
#   Width of the label column: the longest label among the items that have a
#   description, so the descriptions line up.
#
#   Globals:
#     writes REPLY   the width (0 when no item has a description)
# =============================================================================
_ui_label_width() {
    local item label
    local -i w=0
    for item in "$@"; do
        [[ $item == *$'\t'* ]] || continue
        label=${item%%$'\t'*}
        (( ${#label} > w )) && w=${#label}
    done
    REPLY=$w
}

# =============================================================================
# § _ui_hint_colour HINT
#
#   Globals:
#     writes REPLY   the colour for a description: red for ⚠ warnings, else grey
# =============================================================================
_ui_hint_colour() {
    if [[ $1 == ⚠* ]]; then REPLY=$RED; else REPLY=$DIM; fi
}

# =============================================================================
# § _menu_row INDEX SELECTED LABEL_WIDTH ITEM
#
#   Renders one single-choice row; the selected row gets a highlighted bar.
# =============================================================================
_menu_row() {
    local -i idx=$1 sel=$2 lw=$3
    local label=${4%%$'\t'*} hint=''
    [[ $4 == *$'\t'* ]] && hint=${4#*$'\t'}
    _ui_hint_colour "$hint"
    if (( idx == sel )); then
        printf "  ${SEL} ❯ %-*s ${NC}  %s%s${NC}\n" "$lw" "$label" "$REPLY" "$hint"
    else
        printf "     %-*s   %s%s${NC}\n" "$lw" "$label" "$REPLY" "$hint"
    fi
}

# =============================================================================
# § interactive_menu TITLE ITEM...
#
#   Arrow-key navigable single-choice menu.
#
#   Arguments:
#     TITLE     heading shown above the list
#     ITEM...   rows; "label<TAB>description" adds a description column
#   Globals:
#     writes MENU_RESULT   0-based index of the chosen item. `q` picks the last
#                          item, which callers reserve for Exit / Back / Cancel.
#   Keys:
#     ↑ ↓ move · Home / End · Enter select · q last item
# =============================================================================
interactive_menu() {
    local title="$1"; shift
    local -a items=("$@")
    local -i n=${#items[@]} sel=0 i lw

    # ── non-interactive fallback ─────────────────────────────────────────────
    if [[ ! -t 0 ]]; then
        printf '\n%s\n' "$title"
        for (( i=0; i<n; i++ )); do
            printf '  %d.  %s\n' "$(( i+1 ))" "${items[i]//$'\t'/  - }"
        done
        printf 'Enter choice [1-%d]: ' "$n"
        local ans; read -r ans
        [[ $ans =~ ^[0-9]+$ ]] || ans=0
        MENU_RESULT=$(( ans - 1 ))
        (( MENU_RESULT < 0 || MENU_RESULT >= n )) && MENU_RESULT=$(( n-1 ))
        return
    fi

    _ui_label_width "${items[@]}"; lw=$REPLY

    ui_cursor_hide               # hide cursor while navigating
    _ui_wrap_off                 # one row == one line (see ui/term.sh)

    printf '\n'
    printf "  ${ACCENT}${BOLD}%s${NC}\n" "$title"
    printf "  ${DIM}↑ ↓ move  ·  Enter select  ·  q quit${NC}\n\n"

    for (( i=0; i<n; i++ )); do _menu_row "$i" "$sel" "$lw" "${items[i]}"; done

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

        # ── redraw in place ──────────────────────────────────────────────────
        printf '\033[%dA' "$n"
        for (( i=0; i<n; i++ )); do
            printf '\r\033[K'
            _menu_row "$i" "$sel" "$lw" "${items[i]}"
        done
    done

    _ui_wrap_on                  # restore automatic line-wrap
    ui_cursor_show               # restore cursor
    MENU_RESULT=$sel
}

# =============================================================================
# § interactive_multiselect TITLE ITEM...
#
#   Arrow-key navigable checkbox list (select / unselect).
#   ITEM 0 is treated as a special "Select all" toggle that mirrors the
#   combined state of every *action* row.
#
#   Arguments:
#     TITLE     heading shown above the list
#     ITEM...   rows; "label<TAB>description" adds a description column
#
#   Optional input globals (read once, then reset to defaults):
#     MS_TAIL_CONTROLS   number of trailing rows that are NOT governed by the
#                        "Select all" row or the 'a' key (e.g. a "Shut down"
#                        toggle + a "Back" row). Default 0.
#     MS_BACK_ROW        full item index (0-based, where 0 = "Select all") of a
#                        row that acts as "Back": activating it (Enter or space
#                        while highlighted) exits with MULTISELECT_BACK=1. -1 to
#                        disable. Default -1.
#     MS_PRESELECT       space-separated result indices (same numbering as
#                        MULTISELECT_RESULT) that start out ticked. Default none.
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
# =============================================================================
interactive_multiselect() {
    local title="$1"; shift
    local -a items=("$@")
    local -i n=${#items[@]} sel=0 i lw
    local -a SELECTED=()
    for (( i=0; i<n; i++ )); do SELECTED[i]=0; done

    # ── absorb optional input globals, then reset so they never leak ──────────
    local -i tail=${MS_TAIL_CONTROLS:-0}
    local -i back_row=${MS_BACK_ROW:--1}
    local preselect=${MS_PRESELECT:-}
    MS_TAIL_CONTROLS=0
    MS_BACK_ROW=-1
    MS_PRESELECT=''

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

    local p
    for p in $preselect; do
        [[ $p =~ ^[0-9]+$ ]] && (( p + 1 < n )) && SELECTED[p+1]=1
    done
    [[ -n $preselect ]] && _ms_sync_all

    # ── non-interactive fallback ─────────────────────────────────────────────
    if [[ ! -t 0 || ! -t 1 ]]; then
        printf '\n%s\n' "$title"
        for (( i=1; i<n; i++ )); do
            printf '  %d.  %s\n' "$i" "${items[i]//$'\t'/  - }"
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

    _ui_label_width "${items[@]}"; lw=$REPLY

    # ── render a single row ───────────────────────────────────────────────────
    _ms_row() {
        local -i idx=$1
        local cursor label=${items[idx]%%$'\t'*} hint=''
        [[ ${items[idx]} == *$'\t'* ]] && hint=${items[idx]#*$'\t'}
        (( idx == sel )) && cursor="${BCYN}❯${NC}" || cursor=' '

        # Back row renders as an action (no checkbox), not a toggle.
        if (( back_row >= 0 && idx == back_row )); then
            if (( idx == sel )); then
                printf "  %s  ${SEL} ↩ %s ${NC}\n" "$cursor" "$label"
            else
                printf "  %s  ${DIM} ↩ %s${NC}\n" "$cursor" "$label"
            fi
            return
        fi

        local box weight
        if (( SELECTED[idx] == 1 )); then box="${BGRN}[✓]${NC}"; else box="${GRY}[ ]${NC}"; fi
        (( idx == sel )) && weight=$WHT || weight=''
        _ui_hint_colour "$hint"
        printf "  %s  %s  %s%-*s${NC}   %s%s${NC}\n" \
            "$cursor" "$box" "$weight" "$lw" "$label" "$REPLY" "$hint"
    }

    ui_cursor_hide               # hide cursor while navigating
    _ui_wrap_off                 # one row == one line (see ui/term.sh)

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

        # ── redraw in place ────────────────────────────────────────────────────
        printf '\033[%dA' "$n"
        for (( i=0; i<n; i++ )); do
            printf '\r\033[K'
            _ms_row "$i"
        done
    done

    _ui_wrap_on                  # restore automatic line-wrap
    ui_cursor_show               # restore cursor
    unset -f _ms_row _ms_sync_all _ms_set_all

    if (( MULTISELECT_CANCELLED == 1 || MULTISELECT_BACK == 1 )); then
        MULTISELECT_RESULT=''; return
    fi

    local -a picked=()
    for (( i=1; i<n; i++ )); do (( SELECTED[i] == 1 )) && picked+=("$(( i-1 ))"); done
    # shellcheck disable=SC2034  # result global, read by the caller
    MULTISELECT_RESULT="${picked[*]:-}"
}
