#!/usr/bin/env bash
# =============================================================================
# § lib/helpers/macos.sh  ·  macOS-managed stores and privacy
#
#   Single responsibility: the parts of cleaning that need macOS-specific
#   handling - privacy protection (TCC), the Trash, and Time Machine's local
#   snapshots.
#
#     is_tcc_blocked / fda_hint      detect and explain a privacy block
#     empty_trash                    Trash on every volume (Finder fallback)
#     clean_tm_snapshots             Time Machine local snapshots
#
#   Requires (sourced earlier): colors.sh, core.sh, logging.sh,
#                               helpers/measure.sh, helpers/exec.sh,
#                               helpers/clean.sh (clean_dir)
# =============================================================================

# =============================================================================
# § is_tcc_blocked PATH
#
#   True when PATH exists but macOS privacy protection (TCC) refuses to list
#   it - e.g. ~/.Trash, ~/Library/Mail, Safari or Photos containers when the
#   terminal lacks Full Disk Access. Without this check `du` and `find` fail
#   quietly, sizes read as 0, and a folder full of data looks "already empty".
#
#   Arguments:
#     PATH  folder to probe
#   Returns:
#     0 when PATH exists but may not be listed, 1 otherwise
# =============================================================================
is_tcc_blocked() {
    [[ -d $1 ]] && ! ls -A "$1" >/dev/null 2>&1
}

# =============================================================================
# § fda_hint
#
#   Prints the "how to grant Full Disk Access" hint.
# =============================================================================
fda_hint() {
    info "tip     : give your terminal Full Disk Access to clean protected folders:"
    info "          System Settings ▸ Privacy & Security ▸ Full Disk Access ▸ add"
    info "          your terminal app (Terminal, iTerm, VS Code, …), then reopen it."
}

# =============================================================================
# § _clean_trash_dir DIR LABEL
#
#   clean_dir for a Trash folder. Trashed items are often read-only folders
#   (node_modules, Go module caches, app bundles) or files locked in Finder
#   (Get Info ▸ Locked). `find -delete` cannot remove those, so first clear the
#   user "locked" flag and give yourself write permission on everything inside.
#   Only your own items: anything owned by root still needs Finder or sudo.
# =============================================================================
_clean_trash_dir() {
    local dir="$1" label="$2"
    if [[ -d $dir ]] && ! is_tcc_blocked "$dir"; then
        run_timeout "$DIR_TIMEOUT" chflags -R nouchg "$dir" 2>/dev/null
        run_timeout "$DIR_TIMEOUT" chmod -R u+w "$dir" 2>/dev/null
    fi
    clean_dir "$dir" "$label"
}

# =============================================================================
# § empty_trash
#
#   Empties your Trash: ~/.Trash, iCloud Drive's Trash, and your Trash on
#   every mounted external volume.
#
#   macOS protects ~/.Trash with privacy controls (TCC). Unless the terminal
#   has Full Disk Access it cannot even list the folder, so deleting it
#   directly silently does nothing. In that case we ask Finder to empty the
#   Trash instead - the same as Finder ▸ Empty Trash. The first time, macOS
#   asks once whether your terminal may control Finder.
# =============================================================================
empty_trash() {
    local trash="$HOME/.Trash"

    if ! is_tcc_blocked "$trash"; then
        _clean_trash_dir "$trash" "User Trash"
        _clean_trash_dir "$HOME/Library/Mobile Documents/com~apple~CloudDocs/.Trash" "iCloud Drive Trash"
        local vol
        for vol in /Volumes/*; do
            [[ $vol -ef / ]] && continue                 # boot volume alias
            [[ -d "$vol/.Trashes/$UID" ]] && _clean_trash_dir "$vol/.Trashes/$UID" "Trash on ${vol##*/}"
        done
        return 0
    fi

    step "[Trash  (via Finder)]"
    info "note    : macOS privacy blocks direct access to ~/.Trash - asking Finder"

    # Finder's own confirmation dialog is switched off just for this call and
    # restored afterwards. Output: "<items before> <items left>".
    local out
    local -i before_kb after_kb freed rc=0
    before_kb=$(disk_avail_kb)
    out=$(run_timeout 960 osascript \
        -e 'tell application "Finder"' \
        -e '  set n to count of items of trash' \
        -e '  if n > 0 then' \
        -e '    set w to warns before emptying of trash' \
        -e '    set warns before emptying of trash to false' \
        -e '    try' \
        -e '      with timeout of 900 seconds' \
        -e '        empty trash' \
        -e '      end timeout' \
        -e '    end try' \
        -e '    set warns before emptying of trash to w' \
        -e '  end if' \
        -e '  return (n as text) & " " & ((count of items of trash) as text)' \
        -e 'end tell' 2>&1) || rc=$?
    after_kb=$(disk_avail_kb)

    if (( rc == 0 )) && [[ $out =~ ^([0-9]+)\ ([0-9]+)$ ]]; then
        local -i n=${BASH_REMATCH[1]} left=${BASH_REMATCH[2]}
        if (( n == 0 )); then
            info "status  : Trash is already empty"
            echo; return 0
        fi
        (( freed = after_kb - before_kb )) || true
        (( freed < 0 )) && freed=0
        (( TOTAL_FREED_KB += freed ))
        ledger_add "Trash" "$freed"
        (( TOTAL_CLEANED++ ))
        if (( left == 0 )); then
            ok "emptied ${n} item(s), ~$(human_size $freed) freed ← Trash (Finder)"
        else
            warn "emptied $(( n - left )) of ${n} item(s); ${left} in use or locked ← Trash (Finder)"
        fi
    elif (( rc == 124 )); then
        warn "Finder is still emptying the Trash in the background (large Trash)"
    elif [[ $out == *-1743* ]]; then
        (( TOTAL_FAILED++ ))
        warn "macOS did not allow this terminal to control Finder ← Trash"
        info "allow   : System Settings ▸ Privacy & Security ▸ Automation ▸"
        info "          your terminal ▸ turn on Finder - or use Full Disk Access:"
        fda_hint
    else
        (( TOTAL_FAILED++ ))
        warn "Finder could not empty the Trash (exit=${rc}) ← Trash"
        [[ -n $out ]] && info "detail  : $out"
    fi
    echo
}

# =============================================================================
# § clean_tm_snapshots
#
#   Lists and deletes all Time Machine local snapshots on the boot volume.
#   Local snapshots are temporary backups stored on-disk; deleting them is
#   safe - they have no effect on your remote Time Machine backup.
#   Requires sudo for deletion.
# =============================================================================
clean_tm_snapshots() {
    step "[Time Machine local snapshots]"

    if ! command -v tmutil &>/dev/null; then
        info "status  : tmutil not found - skipping"
        echo; return 0
    fi

    # listlocalsnapshotdates returns bare date strings: "2024-06-01-120000"
    local -a dates=()
    local d
    while IFS= read -r d; do
        [[ -n $d ]] && dates+=("$d")
    done < <(tmutil listlocalsnapshotdates / 2>/dev/null)

    info "found   : ${#dates[@]} local snapshot(s)"

    if (( ${#dates[@]} == 0 )); then
        info "status  : no local snapshots - nothing to do"
        echo; return 0
    fi

    for d in "${dates[@]}"; do
        info "  snapshot: $d"
    done

    local -i deleted=0 failed=0
    for d in "${dates[@]}"; do
        if sudo tmutil deletelocalsnapshots "$d" &>/dev/null; then
            (( deleted++ ))
            info "  deleted : $d"
        else
            (( failed++ ))
            warn "  failed  : $d"
        fi
    done

    if (( failed == 0 )); then
        (( TOTAL_CLEANED++ ))
        ok "deleted ${deleted} local snapshot(s)"
    else
        warn "deleted ${deleted}/${#dates[@]} (${failed} failed - may need sudo or newer macOS)"
    fi
    echo
}
