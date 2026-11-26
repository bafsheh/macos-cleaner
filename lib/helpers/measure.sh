#!/usr/bin/env bash
# =============================================================================
# § lib/helpers/measure.sh  ·  Disk and size measurement
#
#   Single responsibility: answer "how big / how much is free", and keep the
#   ledger of where freed space came from. Nothing here deletes anything.
#
#     disk_free / disk_avail_kb / disk_used_pct   the boot volume
#     human_size / dir_size_kb                    sizes
#     ledger_add / ledger_top / ledger_reset      "biggest wins" bookkeeping
#     report_largest_dirs                         ranked folder report
#
#   Requires (sourced earlier): core.sh (FREED_LEDGER), logging.sh
# =============================================================================

# =============================================================================
# § disk_free
#
#   Outputs:
#     Free space on the boot volume as text, e.g. "249Gi free of 460Gi".
# =============================================================================
disk_free() { df -h / | awk 'NR==2 {print $4 " free of " $2}'; }

# =============================================================================
# § disk_avail_kb
#
#   Outputs:
#     Free space on the boot volume in KB (APFS: shared by every volume).
# =============================================================================
disk_avail_kb() { df -k / | awk 'NR==2 {print $4+0}'; }

# =============================================================================
# § disk_used_pct
#
#   Outputs:
#     How full the disk is, as a whole percentage (0-100). Counted as
#     "everything that is not free": on APFS the system volume's own "used"
#     figure leaves out the data volume that shares its space.
# =============================================================================
disk_used_pct() { df -k / | awk 'NR==2 { print ($2 > 0 ? int(($2 - $4) * 100 / $2) : 0) }'; }

# =============================================================================
# § human_size KB
#
#   Arguments:
#     KB   a size in kilobytes
#   Outputs:
#     The size in the largest sensible unit: "1.25 GB", "640.0 MB", "12 KB".
# =============================================================================
human_size() {
    local -i kb=$1
    if   (( kb >= 1048576 )); then awk -v k="$kb" 'BEGIN{printf "%.2f GB", k/1048576}'
    elif (( kb >= 1024 ));    then awk -v k="$kb" 'BEGIN{printf "%.1f MB", k/1024}'
    else                           printf '%d KB' "$kb"
    fi
}

# =============================================================================
# § dir_size_kb PATH
#
#   Arguments:
#     PATH   a folder
#   Outputs:
#     Its size on disk in KB; 0 when PATH is not a folder or cannot be read.
# =============================================================================
dir_size_kb() {
    local p="$1"
    [[ -d $p ]] || { printf '0'; return; }
    du -sk "$p" 2>/dev/null | awk '{print $1+0}'
}

# =============================================================================
# § path_size_kb PATH
#
#   Like dir_size_kb, but for a file or a folder.
#
#   Outputs:
#     Size on disk in KB; 0 when PATH does not exist or cannot be read.
# =============================================================================
path_size_kb() {
    [[ -e $1 || -L $1 ]] || { printf '0'; return; }
    du -sk "$1" 2>/dev/null | awk '{print $1+0; f=1} END {if (!f) print 0}'
}

# =============================================================================
# § ledger_add LABEL KB
#
#   Records that a step freed KB of space, so the summary can show where the
#   space actually came from. A plain append to a shared file: safe to call
#   from the parallel cleanup jobs.
#
#   Arguments:
#     LABEL  what was cleaned ("Xcode DerivedData")
#     KB     space freed; zero or less is not recorded
#   Globals:
#     reads FREED_LEDGER
# =============================================================================
ledger_add() {
    (( $2 > 0 )) || return 0
    printf '%d\t%s\n' "$2" "$1" >> "$FREED_LEDGER" 2>/dev/null
    return 0
}

# Empties the ledger (start of a cleanup run).
ledger_reset() { : > "$FREED_LEDGER" 2>/dev/null; return 0; }

# =============================================================================
# § ledger_top [COUNT]
#
#   Outputs:
#     The COUNT (default 8) biggest ledger entries, largest first, one
#     "KB<TAB>LABEL" per line. Entries with the same label are added up.
# =============================================================================
ledger_top() {
    [[ -s $FREED_LEDGER ]] || return 0
    awk -F'\t' '{ kb[$2] += $1 } END { for (l in kb) printf "%d\t%s\n", kb[l], l }' "$FREED_LEDGER" \
        | sort -rn | head -"${1:-8}"
}

# =============================================================================
# § disk usage report
#
#   A ranked "what is big" list for a folder. Measuring a whole home folder
#   takes a while, so it is never done in silence: the folder is measured by
#   the parallel scanner (helpers/duscan.sh) while a live line shows how far it
#   is, it can be skipped with `s`, and it gives up after REPORT_TIMEOUT
#   seconds - whatever was measured by then is still listed.
#
#   One scan covers two levels, so the report for ~/Library that follows the
#   report for ~ is printed straight from the same measurement.
#
#   Env: REPORT_TIMEOUT   seconds before the measuring stops (default 90)
# =============================================================================
_REPORT_ROOT=''         # folder covered by the last scan
_REPORT_FILE=''         # its listing ("KB<TAB>PATH<TAB>LIVE", see du_scan_merge)
_REPORT_PARTIAL=''      # why the last scan is incomplete ('' = it is complete)

# Forgets the last scan, so the next report measures again (after a cleanup).
report_reset() { _REPORT_ROOT='' _REPORT_FILE='' _REPORT_PARTIAL=''; }

# =============================================================================
# § _report_scan ROOT
#
#   Measures ROOT two levels deep, showing progress while it runs.
#
#   Globals:
#     reads  REPORT_TIMEOUT, MC_RUN_DIR
#     writes _REPORT_ROOT, _REPORT_FILE, _REPORT_PARTIAL
# =============================================================================
_report_scan() {
    local root=${1%/} work key shown limit=${REPORT_TIMEOUT:-90}
    local -i frame=0 t0=$SECONDS keys=0 stop=0 keys_gone=0
    [[ $limit =~ ^[0-9]+$ ]] && (( limit > 0 )) || limit=90

    work=$(mktemp -d "${MC_RUN_DIR:-${TMPDIR:-/tmp}}/report.XXXXXX") || return 1
    _REPORT_ROOT=$root _REPORT_FILE="${MC_RUN_DIR:-${TMPDIR:-/tmp}}/report.listing" _REPORT_PARTIAL=''

    du_scan_start "$root" "$work"
    # On a terminal: a live progress line, and `s` skips the wait.
    if [[ -t 0 && -t 1 ]] && declare -F ui_keys_begin > /dev/null && ui_keys_begin; then
        keys=1; ui_term_size; ui_cursor_hide
    fi
    while du_scan_running; do
        if (( keys && ! keys_gone )); then
            du_scan_progress "$work"
            shown=${DU_SCAN_LATEST#*$'\t'}; [[ $shown == "$HOME"* ]] && shown="~${shown#"$HOME"}"
            ui_status "$frame" "$DU_SCAN_DONE" "$DU_SCAN_TOTAL" "folders measured · s to skip · ${shown}"
            (( frame++ ))
            if ui_keys_poll; then
                for key in "${UI_KEYS[@]}"; do [[ $key == [sSqQ] || $key == ESC ]] && stop=1; done
            elif ui_keys_lost; then
                keys_gone=1                 # no keyboard: keep measuring, just stop polling it
            fi
        else
            sleep 0.2
        fi
        if (( stop )); then _REPORT_PARTIAL='skipped - only what was measured until then is listed'; break; fi
        if (( SECONDS - t0 >= limit )); then
            _REPORT_PARTIAL="stopped after ${limit}s - only what was measured until then is listed (REPORT_TIMEOUT=${limit})"
            break
        fi
    done
    if (( keys )); then ui_status_clear; ui_cursor_show; ui_keys_end; fi
    [[ -n $_REPORT_PARTIAL ]] && du_scan_stop "$work"

    du_scan_merge "$root" "$work" "$(du_loose_kb "$root")" > "$_REPORT_FILE"
    rm -rf "$work"
}

# =============================================================================
# § report_largest_dirs PATH LABEL [COUNT]
#
#   Prints a ranked list of the largest folders directly inside PATH.
#   Purely informational - nothing is deleted.
#
#   Arguments:
#     PATH   folder to report on
#     LABEL  heading for the report
#     COUNT  how many rows to show (default 20)
# =============================================================================
report_largest_dirs() {
    local path=${1%/} label=$2 shown line
    local -i count=${3:-20} t0=$SECONDS

    step "[$label - top ${count} by size]"
    shown=$path; [[ $shown == "$HOME"* ]] && shown="~${shown#"$HOME"}"
    kv path "$shown"

    if [[ ! -d $path ]]; then
        info "status  : directory not present"
        echo; return 0
    fi

    # Already measured as part of the folder above it? Then no second scan.
    if [[ -z $_REPORT_FILE || ! -s $_REPORT_FILE || ( $path != "$_REPORT_ROOT" && ${path%/*} != "$_REPORT_ROOT" ) ]]; then
        _report_scan "$path"
        kv measured "in $(( SECONDS - t0 ))s"
    fi
    [[ -n $_REPORT_PARTIAL ]] && warn "$_REPORT_PARTIAL"

    # The folders directly inside PATH, largest first, sizes made readable.
    while IFS= read -r line; do info "$line"; done < <(
        awk -F'\t' -v dir="$path" -v home="$HOME" '
            function fmt(k) {
                if (k >= 1048576) return sprintf("%.2f GB", k / 1048576)
                if (k >= 1024)    return sprintf("%.1f MB", k / 1024)
                return sprintf("%d KB", k)
            }
            index($2, dir "/") == 1 && index(substr($2, length(dir) + 2), "/") == 0 {
                p = $2; if (index(p, home) == 1) p = "~" substr(p, length(home) + 1)
                printf "%d\t%10s  %s%s\n", $1, fmt($1), p, ($3 == 1 ? "  (still being measured)" : "")
            }' "$_REPORT_FILE" | sort -rn | head -"$count" | cut -f2-)
    echo
}
