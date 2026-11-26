#!/usr/bin/env bash
# =============================================================================
# § lib/ui/picker.sh  ·  Scrollable, filterable, live-updating checklist
#
#   Single responsibility: let the user tick rows in a list that may be long
#   (it scrolls), may be searched (type / to filter) and may still be filling
#   in while it is on screen (a background producer appends rows to a file).
#
#     ╭ Uninstall apps · pick what to remove
#     │ ⠹ ████████▌        23/41  measuring Xcode
#     │ ↑↓ move · space tick · / filter · s sort · Enter uninstall · q back
#     │
#     │ ❯ [✓] Visual Studio Code         612 MB  1.98.0 · /Applications
#     │   [ ] Xcode                           …  16.2 · /Applications
#     ╰ 41 apps · 1 ticked · 612 MB                          filter: code
#
#   The rows file is tab-separated, one row per line:
#
#       ID <TAB> LABEL <TAB> DETAIL <TAB> SIZE_KB [<TAB> FLAG]
#
#     ID       what is returned for a ticked row (a path, a key …); a later
#              line with the same ID replaces the earlier one, which is how a
#              producer first lists a row and then fills in its size
#     SIZE_KB  size in KB; -1 while it is still being measured ("…");
#              -2 when a size does not apply (shown blank)
#     FLAG     "review" = needs a second look: shown in orange and never
#              ticked automatically
#
#   It runs on the terminal's alternate screen, so whatever was on screen
#   before is back when it closes. Falls back to a numbered prompt when stdin
#   or stdout is not a terminal.
#
#   Requires (sourced earlier): colors.sh, helpers/measure.sh (human_size),
#                               ui/term.sh, ui/widgets.sh
#   Public entry: ui_picker
# =============================================================================

# ── status globals written by the --poll function ────────────────────────────
PICKER_BUSY=0           # 1 while rows are still arriving
PICKER_DONE=0           # units finished   } progress bar; TOTAL=0 hides it
PICKER_TOTAL=0          # units in all     }
PICKER_NOTE=''          # what the producer is doing right now

# ── result globals ───────────────────────────────────────────────────────────
PICKER_RESULT=()        # IDs of the chosen rows
PICKER_CANCELLED=0      # 1 when the user left without choosing

# ── loaded view (parallel arrays, rebuilt by _picker_load) ───────────────────
_PK_ID=(); _PK_LABEL=(); _PK_DETAIL=(); _PK_KB=(); _PK_SIZE=(); _PK_FLAG=()
_PK_ALL_ID=(); _PK_ALL_KB=(); _PK_ALL_FLAG=()

# =============================================================================
# § _picker_rows ROWS_FILE FILTER SORT_KEY...
#
#   Outputs:
#     The rows of ROWS_FILE, de-duplicated by ID (the last line wins), each
#     size formatted, fields joined with the unit separator (\037), sorted by
#     SORT_KEY (sort(1) -k options):
#       A␟ID␟-␟-␟KB␟-␟FLAG                 every row (for totals)
#       V␟ID␟LABEL␟DETAIL␟KB␟SIZE␟FLAG     rows that pass FILTER (for display)
# =============================================================================
_picker_rows() {
    local file=$1 filter=$2; shift 2
    awk -F'\t' -v f="$filter" '
        function fmt(k) {
            if (k < -1)       return ""
            if (k < 0)        return "…"
            if (k >= 1048576) return sprintf("%.2f GB", k / 1048576)
            if (k >= 1024)    return sprintf("%.1f MB", k / 1024)
            return sprintf("%d KB", k)
        }
        $1 != "" { if (!($1 in row)) order[++n] = $1; row[$1] = $0 }
        END {
            f = tolower(f)
            for (i = 1; i <= n; i++) {
                split(row[order[i]], c, "\t")
                kb = (c[4] == "" ? -1 : c[4] + 0)
                printf "A\037%s\037-\037-\037%d\037-\037%s\n", c[1], kb, c[5]
                if (f != "" && index(tolower(c[2] " " c[3]), f) == 0) continue
                printf "V\037%s\037%s\037%s\037%d\037%s\037%s\n", c[1], c[2], c[3], kb, fmt(kb), c[5]
            }
        }' "$file" | LC_ALL=C sort -t $'\037' "$@"
}

# =============================================================================
# § _picker_load ROWS_FILE FILTER SORT
#
#   Reads the rows file into the view arrays: de-duplicated by ID (last line
#   wins), filtered by a case-insensitive substring of label + detail, sorted,
#   with each size already formatted for display.
#
#   Arguments:
#     ROWS_FILE  the tab-separated rows file
#     FILTER     substring to keep ('' = keep everything)
#     SORT       name | size
#   Globals:
#     writes _PK_*      the rows that pass the filter, in display order
#     writes _PK_ALL_*  ID / size / flag of every row (for totals)
# =============================================================================
_picker_load() {
    local file=$1 filter=$2 order=$3 kind id label detail kb size flag
    local -a sort_keys=('-k3,3f')
    [[ $order == size ]] && sort_keys=('-k5,5nr' '-k3,3f')

    _PK_ID=(); _PK_LABEL=(); _PK_DETAIL=(); _PK_KB=(); _PK_SIZE=(); _PK_FLAG=()
    _PK_ALL_ID=(); _PK_ALL_KB=(); _PK_ALL_FLAG=()
    [[ -s $file ]] || return 0

    # Fields are joined with the unit separator (\037): unlike a TAB it is not
    # IFS whitespace, so `read` keeps empty fields in place.
    # (Loaded with $(…) and a here-string, not a process substitution: this
    # runs on every reload while a scan feeds the list - see lib/core.sh.)
    local loaded
    loaded=$(_picker_rows "$file" "$filter" "${sort_keys[@]}")
    while IFS=$'\037' read -r kind id label detail kb size flag; do
        [[ -n $kind ]] || continue
        if [[ $kind == A ]]; then
            _PK_ALL_ID+=("$id"); _PK_ALL_KB+=("$kb"); _PK_ALL_FLAG+=("$flag")
        else
            _PK_ID+=("$id"); _PK_LABEL+=("$label"); _PK_DETAIL+=("$detail")
            _PK_KB+=("$kb"); _PK_SIZE+=("$size"); _PK_FLAG+=("$flag")
        fi
    done <<< "$loaded"
}

# =============================================================================
# § _picker_fallback TITLE ROWS_FILE POLL_FN
#
#   Non-interactive version: waits for the producer, prints a numbered list,
#   and reads the chosen numbers from stdin.
# =============================================================================
_picker_fallback() {
    local title=$1 file=$2 poll=$3 ans num
    local -i i

    if [[ -n $poll ]]; then
        "$poll"
        while (( PICKER_BUSY )); do sleep 0.2; "$poll"; done
    fi
    _picker_load "$file" '' name

    printf '\n%s\n' "$title"
    for (( i=0; i<${#_PK_ID[@]}; i++ )); do
        printf '  %3d.  %-32s %9s  %s\n' "$(( i+1 ))" "${_PK_LABEL[i]}" "${_PK_SIZE[i]}" "${_PK_DETAIL[i]}"
    done
    if (( ${#_PK_ID[@]} == 0 )); then
        printf '  (nothing found)\n'; PICKER_CANCELLED=1; return 0
    fi
    printf 'Enter numbers (e.g. "1 3"), "a" for all, blank to cancel: '
    read -r ans || ans=''
    if [[ $ans == [aA] ]]; then
        PICKER_RESULT=("${_PK_ID[@]}")
    else
        for num in $ans; do
            [[ $num =~ ^[0-9]+$ ]] && (( num >= 1 && num <= ${#_PK_ID[@]} )) \
                && PICKER_RESULT+=("${_PK_ID[num-1]}")
        done
    fi
    (( ${#PICKER_RESULT[@]} == 0 )) && PICKER_CANCELLED=1
    return 0
}

# =============================================================================
# § ui_picker [OPTION...] TITLE ROWS_FILE
#
#   Shows the checklist and returns when the user confirms or leaves.
#
#   Arguments:
#     TITLE      heading
#     ROWS_FILE  tab-separated rows (format in the file header); may be
#                appended to while the picker is open
#   Options:
#     --hint TEXT        description shown beside the title
#     --verb TEXT        what Enter does, e.g. "uninstall"   (default "select")
#     --unit TEXT        noun for the count, e.g. "apps"     (default "items")
#     --preselect all    rows start ticked, except FLAG=review rows
#     --sort name|size   initial order                       (default name)
#     --poll FUNCTION    a function called about ten times a second. It
#                        reports on the producer by setting PICKER_BUSY,
#                        PICKER_DONE, PICKER_TOTAL and PICKER_NOTE. While
#                        PICKER_BUSY is 1 the header shows a spinner and a
#                        progress bar and the rows file is re-read as it grows.
#
#   Keys:
#     ↑ ↓ · PgUp PgDn · Home End   move
#     space                        tick / untick the highlighted row
#     a                            tick / untick every row shown
#     /                            filter (type, Enter to keep, Esc to clear)
#     s                            sort by name ↔ size
#     Enter                        confirm: the ticked rows. With nothing ticked
#                                  it means the highlighted row - except with
#                                  --preselect all, where it means "none"
#                                  (PICKER_RESULT empty, PICKER_CANCELLED 0)
#     q · Esc                      leave without choosing
#
#   Result globals:
#     PICKER_RESULT      array of the chosen IDs (empty when cancelled)
#     PICKER_CANCELLED   1 when the user left without choosing
# =============================================================================
ui_picker() {
    local hint='' verb='select' unit='items' preselect=none order=name poll=''
    while [[ ${1:-} == --* ]]; do
        case $1 in
            --hint)      hint=$2 ;;
            --verb)      verb=$2 ;;
            --unit)      unit=$2 ;;
            --preselect) preselect=$2 ;;
            --sort)      order=$2 ;;
            --poll)      poll=$2 ;;
            *)           printf 'ui_picker: unknown option %s\n' "$1" >&2; return 2 ;;
        esac
        shift 2
    done
    local title=$1 file=$2
    PICKER_RESULT=() PICKER_CANCELLED=0
    PICKER_BUSY=0 PICKER_DONE=0 PICKER_TOTAL=0 PICKER_NOTE=''

    if [[ ! -t 0 || ! -t 1 ]]; then
        _picker_fallback "$title" "$file" "$poll"
        return 0
    fi

    local nl=$'\n'
    local ticked=$nl          # newline-wrapped IDs: "\nID\nID\n" (bash 3.2: no maps)
    local known=$nl           # IDs already seen once (auto-tick happens only then)
    local filter='' cur_id='' key frame_txt line box mark size_col lbl det
    local -i cur=0 top=0 rows=0 n=0 i frame=0 dirty=1 filtering=0 was_busy=1
    local -i fsize=-1 newsize lw room note_w ticked_n=0 ticked_kb=0 all_n=0 done_flag=0 moved=0

    # ── reload the view, keep the cursor on the same row, apply auto-ticks ───
    _pk_reload() {
        _picker_load "$file" "$filter" "$order"
        n=${#_PK_ID[@]}; all_n=${#_PK_ALL_ID[@]}
        for (( i=0; i<all_n; i++ )); do
            [[ $known == *"$nl${_PK_ALL_ID[i]}$nl"* ]] && continue
            known+="${_PK_ALL_ID[i]}$nl"
            [[ $preselect == all && ${_PK_ALL_FLAG[i]} != review ]] && ticked+="${_PK_ALL_ID[i]}$nl"
        done
        cur=0
        if [[ -n $cur_id ]]; then
            for (( i=0; i<n; i++ )); do [[ ${_PK_ID[i]} == "$cur_id" ]] && { cur=i; break; }; done
        fi
        _pk_totals
    }
    # ── count the ticked rows and add up their sizes ─────────────────────────
    _pk_totals() {
        ticked_n=0 ticked_kb=0
        for (( i=0; i<all_n; i++ )); do
            [[ $ticked == *"$nl${_PK_ALL_ID[i]}$nl"* ]] || continue
            (( ticked_n++ ))
            (( _PK_ALL_KB[i] > 0 )) && (( ticked_kb += _PK_ALL_KB[i] ))
        done
    }
    _pk_toggle() {   # ID
        if [[ $ticked == *"$nl$1$nl"* ]]; then ticked=${ticked/"$nl$1$nl"/$nl}
        else ticked+="$1$nl"; fi
    }
    # ── build and paint one frame ────────────────────────────────────────────
    _pk_paint() {
        ui_term_size
        rows=$(( UI_LINES - 6 )); (( rows < 3 )) && rows=3
        (( cur >= n )) && cur=$(( n > 0 ? n - 1 : 0 ))
        (( cur < top )) && top=cur
        (( cur >= top + rows )) && top=$(( cur - rows + 1 ))
        (( top > n - rows )) && top=$(( n - rows ))
        (( top < 0 )) && top=0

        lw=12
        for (( i=top; i<n && i<top+rows; i++ )); do (( ${#_PK_LABEL[i]} > lw )) && lw=${#_PK_LABEL[i]}; done
        (( lw > UI_COLS / 2 - 8 )) && lw=$(( UI_COLS / 2 - 8 ))
        (( lw < 12 )) && lw=12
        room=$(( UI_COLS - lw - 24 )); (( room < 0 )) && room=0

        note_w=$(( UI_COLS - 48 )); (( note_w < 8 )) && note_w=8

        # header: title · producer status · key help
        frame_txt="  ${ACCENT}${BOLD}${title}${NC}  ${DIM}${hint}${NC}"$'\033[K\n'
        if (( PICKER_BUSY )); then
            ui_spin "$frame"; line="  $REPLY "
            if (( PICKER_TOTAL > 0 )); then
                ui_bar "$PICKER_DONE" "$PICKER_TOTAL" 24
                line+="$REPLY ${BOLD}${PICKER_DONE}/${PICKER_TOTAL}${NC}  "
            fi
            line+="${DIM}${PICKER_NOTE:0:note_w}${NC}"
        else
            line="  ${BGRN}✓${NC} ${all_n} ${unit}"
            [[ -n $PICKER_NOTE ]] && line+="  ${DIM}${PICKER_NOTE:0:note_w}${NC}"
        fi
        frame_txt+="$line"$'\033[K\n'
        if (( filtering )); then
            frame_txt+="  ${BYLW}filter:${NC} ${filter}${REV} ${NC}  ${DIM}type to narrow · Enter keep · Esc clear${NC}"$'\033[K\n'
        else
            frame_txt+="  ${DIM}↑↓ move · space tick · a all · / filter · s sort (${order}) · Enter ${verb} · q back${NC}"$'\033[K\n'
        fi
        frame_txt+=$'\033[K\n'

        # rows
        for (( i=top; i<top+rows; i++ )); do
            if (( i >= n )); then
                (( i == 0 )) && { (( PICKER_BUSY )) && line="    ${DIM}looking…${NC}" || line="    ${DIM}nothing to show${NC}"; } || line=''
                frame_txt+="$line"$'\033[K\n'; continue
            fi
            if [[ $ticked == *"$nl${_PK_ID[i]}$nl"* ]]; then box="${BGRN}[✓]${NC}"; else box="${GRY}[ ]${NC}"; fi
            printf -v lbl '%-*s' "$lw" "${_PK_LABEL[i]:0:lw}"
            printf -v size_col '%9s' "${_PK_SIZE[i]}"
            det=${_PK_DETAIL[i]:0:room}
            if [[ ${_PK_FLAG[i]} == review ]]; then size_col="${ORG}${size_col}${NC}"; det="${ORG}review${NC} ${DIM}· ${det}"; fi
            if (( i == cur )); then
                mark="${BCYN}❯${NC}"; lbl="${SEL}${lbl}${NC}"
            else
                mark=' '
            fi
            frame_txt+="  ${mark} ${box} ${lbl}  ${size_col}  ${DIM}${det}${NC}"$'\033[K\n'
        done

        # footer
        line="  ${DIM}"
        if [[ -n $filter ]]; then line+="${n} of ${all_n} ${unit} shown"; else line+="${all_n} ${unit}"; fi
        line+=" · ${NC}${BOLD}${ticked_n} ticked${NC}"
        (( ticked_kb > 0 )) && line+="${DIM} · $(human_size "$ticked_kb")${NC}"
        (( n > rows )) && line+="${DIM}   rows $(( top + 1 ))-$(( top + rows > n ? n : top + rows ))${NC}"
        [[ -n $filter && $filtering -eq 0 ]] && line+="   ${BYLW}filter:${NC} ${filter}"
        frame_txt+=$'\033[K\n'"$line"$'\033[K'

        printf '\033[H%s\033[J' "$frame_txt"
    }

    ui_alt_screen_on
    ui_cursor_hide
    _ui_wrap_off
    ui_keys_begin

    [[ -n $poll ]] && "$poll"
    _pk_reload
    while (( ! done_flag )); do
        # ── follow the producer ──────────────────────────────────────────────
        if [[ -n $poll ]] && (( was_busy )); then
            "$poll"
            newsize=$(wc -c < "$file" 2>/dev/null) || newsize=0
            if (( newsize != fsize || ! PICKER_BUSY )); then
                fsize=$newsize
                # Until the user moves, the cursor stays on the top row while
                # rows arrive; after that it follows the row it was put on.
                (( moved && n > 0 )) && cur_id=${_PK_ID[cur]}
                _pk_reload
            fi
            was_busy=$PICKER_BUSY
            dirty=1
        fi
        if (( dirty )); then _pk_paint; dirty=0; fi
        (( frame++ ))

        if ! ui_keys_poll; then
            ui_keys_lost && { PICKER_CANCELLED=1; done_flag=1; }     # no keyboard: leave
            continue
        fi
        dirty=1 moved=1
        for key in "${UI_KEYS[@]}"; do
            # ── filter mode: printable keys edit the filter ──────────────────
            if (( filtering )); then
                case $key in
                    ENTER)     filtering=0; continue ;;
                    ESC)       filtering=0; filter=''; cur_id=''; _pk_reload; continue ;;
                    BACKSPACE) filter=${filter%?}; cur_id=''; _pk_reload; continue ;;
                    SPACE)     filter+=' '; cur_id=''; _pk_reload; continue ;;
                    UP|DOWN|PGUP|PGDN|HOME|END) ;;      # fall through to movement
                    ?)         filter+=$key; cur_id=''; _pk_reload; continue ;;
                    *)         continue ;;
                esac
            fi
            case $key in
                UP|k)    (( cur > 0 )) && (( cur-- )) ;;
                DOWN|j)  (( cur < n - 1 )) && (( cur++ )) ;;
                PGUP)    (( cur -= rows )); (( cur < 0 )) && cur=0 ;;
                PGDN)    (( cur += rows )); (( cur > n - 1 )) && cur=$(( n > 0 ? n - 1 : 0 )) ;;
                HOME|g)  cur=0 ;;
                END|G)   cur=$(( n > 0 ? n - 1 : 0 )) ;;
                SPACE)   (( n > 0 )) && { _pk_toggle "${_PK_ID[cur]}"; _pk_totals; } ;;
                a|A)     # all shown rows ticked → untick them; otherwise tick them
                    local -i every=1
                    for (( i=0; i<n; i++ )); do [[ $ticked == *"$nl${_PK_ID[i]}$nl"* ]] || { every=0; break; }; done
                    for (( i=0; i<n; i++ )); do
                        if [[ $ticked == *"$nl${_PK_ID[i]}$nl"* ]]; then
                            (( every )) && _pk_toggle "${_PK_ID[i]}"
                        else
                            _pk_toggle "${_PK_ID[i]}"
                        fi
                    done
                    _pk_totals ;;
                s|S)     [[ $order == name ]] && order=size || order=name
                         (( n > 0 )) && cur_id=${_PK_ID[cur]}; _pk_reload ;;
                /)       filtering=1 ;;
                ENTER)   (( n > 0 || ticked_n > 0 )) && done_flag=1 ;;
                q|Q|ESC)
                    if [[ $key == ESC && -n $filter ]]; then
                        filter=''; cur_id=''; _pk_reload
                    else
                        PICKER_CANCELLED=1; done_flag=1
                    fi ;;
            esac
            (( done_flag )) && break
        done
        (( n > 0 )) && cur_id=${_PK_ID[cur]}
    done

    # ── collect the result ───────────────────────────────────────────────────
    if (( ! PICKER_CANCELLED )); then
        for (( i=0; i<all_n; i++ )); do
            [[ $ticked == *"$nl${_PK_ALL_ID[i]}$nl"* ]] && PICKER_RESULT+=("${_PK_ALL_ID[i]}")
        done
        # Nothing ticked: Enter means "this one" - unless the rows started out
        # ticked, where unticking everything really does mean "none".
        if (( ${#PICKER_RESULT[@]} == 0 )) && [[ $preselect != all ]]; then
            (( n > 0 )) && PICKER_RESULT=("${_PK_ID[cur]}") || PICKER_CANCELLED=1
        fi
    fi

    ui_keys_end
    _ui_wrap_on
    ui_cursor_show
    ui_alt_screen_off
    unset -f _pk_reload _pk_totals _pk_toggle _pk_paint
    return 0
}
