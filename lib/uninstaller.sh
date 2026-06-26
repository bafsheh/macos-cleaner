#!/usr/bin/env bash
# =============================================================================
# § lib/uninstaller.sh  ·  Interactive app / package uninstaller
#
#   Prompts for an app/package name, searches every known install location,
#   displays findings with type/path/size, then removes confirmed items.
#
#   Requires (sourced earlier): colors.sh, logging.sh, helpers.sh
#   Public entry: run_uninstaller
# =============================================================================

# =============================================================================
# § run_uninstaller
#
#   Prompts for an app/package name, searches every known install location,
#   displays findings with type, path, and size, then removes confirmed items.
#
#   Search locations
#     /Applications · ~/Applications - .app bundles
#     Homebrew formula + cask
#     CLI binary dirs (/opt/homebrew/bin, /usr/local/bin, …)
#     npm global packages
#     pip / pip3 packages
#     Cargo binaries (~/.cargo/bin)
#     RubyGems
#     ~/Library/Application Support + /Library/Application Support
#     ~/Library/Preferences + /Library/Preferences
#     ~/Library/Caches + /Library/Caches
#     ~/Library/LaunchAgents + /Library/LaunchAgents + /Library/LaunchDaemons
#     ~/Library/Containers
#     ~/Library/Logs + /Library/Logs
# =============================================================================
run_uninstaller() {
    printf '\n'
    printf "  ${BLU}┌─────────────────────────────────────────────────┐${NC}\n"
    printf "  ${BLU}│  Uninstaller                                    │${NC}\n"
    printf "  ${BLU}└─────────────────────────────────────────────────┘${NC}\n\n"
    printf "  ${DIM}Leave blank and press Enter to go back to the main menu.${NC}\n"
    printf "  ${CYN}App or package name to search (case-insensitive): ${NC}"

    local search_name
    read -r search_name
    # trim surrounding whitespace
    search_name="${search_name#"${search_name%%[! ]*}"}"
    search_name="${search_name%"${search_name##*[! ]}"}"

    if [[ -z $search_name ]]; then
        warn "No name entered - returning to menu."
        echo; return
    fi

    say "Searching for: \"$search_name\""
    echo

    # ── result arrays + dedup set ────────────────────────────────────────────
    local -a _paths=() _types=() _cmds=()
    local -a _seen=()   # tracks recorded paths to avoid duplicates

    _record() {   # type  path  remove_cmd
        local _t="$1" _p="$2" _c="$3"
        local _s; for _s in "${_seen[@]:-}"; do [[ "$_s" == "$_p" ]] && return; done
        _seen+=("$_p"); _types+=("$_t"); _paths+=("$_p"); _cmds+=("$_c")
    }

    # ── safe single-quote escape for paths used inside eval strings ──────────
    _sq() { printf '%s' "${1//\'/\'\\\'\'}"; }   # foo'bar → foo'\''bar

    # ── collect extra search terms from discovered .app bundles ─────────────
    # Populated during step 1; used in steps 8-13 so support files named by
    # bundle-ID (e.g. com.logi.optionsplus) are found when the user searches
    # by display name (e.g. "Logi Options+").
    local -a _extra_terms=()

    # ── 1. .app bundles ──────────────────────────────────────────────────────
    # Search by BOTH filesystem name (find) and Spotlight display name (mdfind)
    # so apps whose bundle folder name differs from their Finder name are found.
    step "[.app bundles]"
    local p

    _process_app_bundle() {
        local bundle="$1"
        [[ -d $bundle ]] || return
        local info="${bundle}/Contents/Info.plist"
        local bid exec_name
        bid=$(defaults  read "${bundle}/Contents/Info" CFBundleIdentifier 2>/dev/null || true)
        exec_name=$(defaults read "${bundle}/Contents/Info" CFBundleExecutable  2>/dev/null \
                    || basename "$bundle" .app)

        local sq_bundle; sq_bundle=$(_sq "$bundle")
        local sq_exec;   sq_exec=$(_sq "$exec_name")

        # Kill running processes, then delete the bundle
        _record "macOS App" "$bundle" \
            "pkill -xi '$sq_exec' 2>/dev/null; pkill -f '$sq_bundle' 2>/dev/null; sudo rm -rf '$sq_bundle'"

        # Stash bundle-ID and filesystem name so steps 8-13 can search by them.
        # We intentionally do NOT add the vendor prefix (e.g. "google", "apple")
        # because it is far too broad and would surface unrelated apps.
        if [[ -n $bid ]]; then
            _extra_terms+=("$bid")
        fi
        local fs_name; fs_name=$(basename "$bundle" .app)
        [[ -n $fs_name ]] && _extra_terms+=("$fs_name")
    }

    # filesystem name search
    while IFS= read -r p; do
        [[ -n $p ]] && _process_app_bundle "$p"
    done < <(find /Applications ~/Applications /System/Applications \
        -maxdepth 3 -iname "*${search_name}*" -name "*.app" -type d 2>/dev/null)

    # Spotlight display-name search (catches apps like "Logi Options+"
    # whose folder on disk is logioptionsplus.app)
    if command -v mdfind &>/dev/null; then
        while IFS= read -r p; do
            [[ -n $p && -d $p ]] && _process_app_bundle "$p"
        done < <(mdfind \
            "kMDItemContentType == 'com.apple.application-bundle' \
             && kMDItemDisplayName == '*${search_name}*'cd" 2>/dev/null)
    fi

    unset -f _process_app_bundle

    # ── 2. Homebrew ──────────────────────────────────────────────────────────
    step "[Homebrew formulae and casks]"
    if command -v brew &>/dev/null; then
        local f
        while IFS= read -r f; do
            [[ -n $f ]] && _record "Homebrew formula" "$f" "brew uninstall '$(_sq "$f")'"
        done < <(brew list --formula 2>/dev/null | grep -i "$search_name")
        while IFS= read -r f; do
            [[ -n $f ]] && _record "Homebrew cask" "$f" "brew uninstall --cask '$(_sq "$f")'"
        done < <(brew list --cask 2>/dev/null | grep -i "$search_name")
    fi

    # ── 3. CLI binaries ──────────────────────────────────────────────────────
    step "[CLI binaries]"
    local bin_dir
    for bin_dir in /opt/homebrew/bin /opt/homebrew/sbin \
                   /usr/local/bin /usr/local/sbin \
                   "$HOME/.local/bin" "$HOME/bin"; do
        [[ -d $bin_dir ]] || continue
        while IFS= read -r p; do
            [[ -n $p ]] && _record "Binary" "$p" "rm -f '$(_sq "$p")'"
        done < <(find "$bin_dir" -maxdepth 1 -iname "*${search_name}*" 2>/dev/null)
    done

    # ── 4. npm global packages ───────────────────────────────────────────────
    step "[npm global packages]"
    if command -v npm &>/dev/null; then
        local pkg
        while IFS= read -r pkg; do
            [[ -n $pkg ]] && _record "npm global" "$pkg" "npm uninstall -g '$(_sq "$pkg")'"
        done < <(npm list -g --depth=0 2>/dev/null \
            | grep -i "$search_name" | awk -F@ '{print $1}' | awk '{print $NF}')
    fi

    # ── 5. pip packages ──────────────────────────────────────────────────────
    step "[pip packages]"
    local pip_cmd
    for pip_cmd in pip3 pip; do
        command -v "$pip_cmd" &>/dev/null || continue
        if $pip_cmd show "$search_name" &>/dev/null; then
            _record "Python ($pip_cmd)" "$search_name" \
                    "$pip_cmd uninstall -y '$(_sq "$search_name")'"
            break
        fi
    done

    # ── 6. Cargo binaries ────────────────────────────────────────────────────
    step "[Cargo binaries]"
    if [[ -d $HOME/.cargo/bin ]]; then
        while IFS= read -r p; do
            [[ -n $p ]] && _record "Cargo binary" "$p" \
                "cargo uninstall '$(_sq "$(basename "$p")")'"
        done < <(find "$HOME/.cargo/bin" -maxdepth 1 \
            -iname "*${search_name}*" 2>/dev/null)
    fi

    # ── 7. RubyGems ──────────────────────────────────────────────────────────
    step "[RubyGems]"
    if command -v gem &>/dev/null; then
        local gem_name
        while IFS= read -r gem_name; do
            [[ -n $gem_name ]] && _record "RubyGem" "$gem_name" \
                "gem uninstall -a '$(_sq "$gem_name")'"
        done < <(gem list 2>/dev/null | grep -i "$search_name" | awk '{print $1}')
    fi

    # ── Helper: search a set of directories for a term ───────────────────────
    # _search_dirs TYPE RM_CMD MAXDEPTH TERM DIR...
    _search_dirs() {
        local _type="$1" _rm="$2" _depth="$3" _term="$4"; shift 4
        local _d _q
        for _d in "$@"; do
            [[ -d $_d ]] || continue
            while IFS= read -r p; do
                [[ -n $p ]] || continue
                _q=$(_sq "$p")
                _record "$_type" "$p" "${_rm//__PATH__/$_q}"
            done < <(find "$_d" -maxdepth "$_depth" -iname "*${_term}*" 2>/dev/null)
        done
    }

    # ── Build full term list: user query + bundle IDs found in step 1 ────────
    local -a _all_terms=("$search_name")
    local _t; for _t in "${_extra_terms[@]:-}"; do _all_terms+=("$_t"); done

    # ── 8. Application Support ───────────────────────────────────────────────
    step "[Application Support]"
    for _t in "${_all_terms[@]}"; do
        _search_dirs "App Support" "rm -rf '__PATH__'" 1 "$_t" \
            "$HOME/Library/Application Support" "/Library/Application Support"
    done

    # ── 9. Preferences ───────────────────────────────────────────────────────
    step "[Preferences]"
    for _t in "${_all_terms[@]}"; do
        _search_dirs "Preference" "rm -f '__PATH__'" 1 "$_t" \
            "$HOME/Library/Preferences" "/Library/Preferences"
    done

    # ── 10. Caches ───────────────────────────────────────────────────────────
    step "[Caches]"
    for _t in "${_all_terms[@]}"; do
        _search_dirs "Cache" "rm -rf '__PATH__'" 1 "$_t" \
            "$HOME/Library/Caches" "/Library/Caches"
    done

    # ── 11. LaunchAgents / LaunchDaemons ─────────────────────────────────────
    step "[LaunchAgents / LaunchDaemons]"
    for _t in "${_all_terms[@]}"; do
        _search_dirs "Launch plist" \
            "sudo launchctl unload '__PATH__' 2>/dev/null; sudo rm -f '__PATH__'" \
            1 "$_t" \
            "$HOME/Library/LaunchAgents" "/Library/LaunchAgents" "/Library/LaunchDaemons"
    done

    # ── 12. Containers ───────────────────────────────────────────────────────
    step "[Containers]"
    for _t in "${_all_terms[@]}"; do
        _search_dirs "Container" "rm -rf '__PATH__'" 1 "$_t" \
            "$HOME/Library/Containers"
    done

    # ── 13. Logs ─────────────────────────────────────────────────────────────
    step "[Logs]"
    for _t in "${_all_terms[@]}"; do
        _search_dirs "Log dir" "rm -rf '__PATH__'" 1 "$_t" \
            "$HOME/Library/Logs" "/Library/Logs"
    done

    unset -f _search_dirs _sq

    # ── Display results ───────────────────────────────────────────────────────
    echo
    local -i total=${#_paths[@]}

    if (( total == 0 )); then
        warn "Nothing found for \"$search_name\"."
        echo; return
    fi

    say "Found ${total} item(s) matching \"${search_name}\":"
    echo
    printf "  ${DIM}  #   %-20s  %-8s  %s${NC}\n" "TYPE" "SIZE" "PATH"
    printf "  ${DIM}  ─   ────────────────────  ────────  $(printf '─%.0s' {1..50})${NC}\n"

    local -i i
    local sz
    for (( i=0; i<total; i++ )); do
        sz=''
        [[ -e ${_paths[i]} ]] && sz=$(du -sh "${_paths[i]}" 2>/dev/null | awk '{print $1}')
        printf "  ${CYN}[%2d]${NC}  %-20s  ${DIM}%-8s${NC}  %s\n" \
            "$(( i+1 ))" "${_types[i]}" "${sz:----}" "${_paths[i]}"
    done

    echo
    printf "  ${YLW}Remove all ${total} items? [y/N]  or enter numbers e.g. \"1 3 5\": ${NC}"
    local answer
    read -r answer

    # ── determine which indices to act on ────────────────────────────────────
    local -a to_remove=()
    if [[ $answer == [yY] ]]; then
        for (( i=0; i<total; i++ )); do to_remove+=("$i"); done
    elif [[ -n $answer ]]; then
        local num
        for num in $answer; do
            if [[ $num =~ ^[0-9]+$ ]] && (( num >= 1 && num <= total )); then
                to_remove+=("$(( num-1 ))")
            fi
        done
    fi

    if (( ${#to_remove[@]} == 0 )); then
        info "Nothing removed - returning to menu."
        echo; return
    fi

    echo
    say "Removing ${#to_remove[@]} item(s)…"
    echo

    local -i removed=0 failed=0 rc
    for i in "${to_remove[@]}"; do
        step "[${_types[i]}]  ${_paths[i]}"
        info "cmd : ${_cmds[i]}"
        rc=0
        eval "${_cmds[i]}" >/dev/null 2>&1 || rc=$?
        if (( rc == 0 )); then
            (( removed++ ))
            ok "removed ← ${_paths[i]}"
        else
            (( failed++ ))
            warn "failed (exit=${rc}) ← ${_paths[i]}"
        fi
        echo
    done

    say "Done - removed: ${removed}   failed: ${failed}"
    echo

    # unset local helper so it doesn't leak into global scope
    unset -f _record
}
