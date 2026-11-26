#!/usr/bin/env bash
# =============================================================================
# § lib/uninstall/packages.sh  ·  Uninstall packages and command-line tools
#
#   Single responsibility: find things that are NOT .app bundles by name -
#   Homebrew formulae and casks, global npm packages, pip packages, Cargo
#   binaries, RubyGems, and loose binaries in the usual bin folders - and
#   remove the ones the user picks, each with its own package manager.
#
#   Removal is dispatched on the package KIND (pkg_remove); a found name is
#   only ever passed as an argument, never spliced into a command string.
#
#   Requires (sourced earlier): colors.sh, core.sh, logging.sh, helpers.sh, ui.sh
#   Public entry: uninstall_packages
# =============================================================================

# Folders searched for loose binaries.
_pkg_bin_dirs() {
    printf '%s\n' /opt/homebrew/bin /opt/homebrew/sbin /usr/local/bin /usr/local/sbin \
        "$HOME/.local/bin" "$HOME/bin"
}

# =============================================================================
# § pkg_search NAME
#
#   Arguments:
#     NAME  what to look for; matched case-insensitively as part of the name
#   Outputs:
#     One "KIND<TAB>TARGET" line per package found. KIND is one of
#     brew-formula · brew-cask · npm · pip3 · pip · cargo · gem · binary;
#     TARGET is the package name (or, for a binary, its path).
# =============================================================================
pkg_search() {
    local name=$1 line dir pip

    if command -v brew &>/dev/null; then
        while IFS= read -r line; do [[ -n $line ]] && printf 'brew-formula\t%s\n' "$line"
        done < <(brew list --formula 2>/dev/null | grep -iF -- "$name")
        while IFS= read -r line; do [[ -n $line ]] && printf 'brew-cask\t%s\n' "$line"
        done < <(brew list --cask 2>/dev/null | grep -iF -- "$name")
    fi

    if command -v npm &>/dev/null; then
        # "├── @scope/name@1.2.3" → "@scope/name"
        while IFS= read -r line; do [[ -n $line ]] && printf 'npm\t%s\n' "$line"
        done < <(npm list -g --depth=0 2>/dev/null | sed -n 's/^[^A-Za-z@]*\(@\{0,1\}[^@ ]*\)@.*/\1/p' | grep -iF -- "$name")
    fi

    for pip in pip3 pip; do
        command -v "$pip" &>/dev/null || continue
        if "$pip" show -- "$name" &>/dev/null; then
            printf '%s\t%s\n' "$pip" "$name"
            break
        fi
    done

    if [[ -d $HOME/.cargo/bin ]]; then
        while IFS= read -r line; do [[ -n $line ]] && printf 'cargo\t%s\n' "${line##*/}"
        done < <(find "$HOME/.cargo/bin" -maxdepth 1 -type f -iname "*${name}*" 2>/dev/null)
    fi

    if command -v gem &>/dev/null; then
        while IFS= read -r line; do [[ -n $line ]] && printf 'gem\t%s\n' "$line"
        done < <(gem list 2>/dev/null | awk '{print $1}' | grep -iF -- "$name")
    fi

    while IFS= read -r dir; do
        [[ -d $dir ]] || continue
        while IFS= read -r line; do [[ -n $line ]] && printf 'binary\t%s\n' "$line"
        done < <(find "$dir" -maxdepth 1 \( -type f -o -type l \) -iname "*${name}*" 2>/dev/null)
    done < <(_pkg_bin_dirs)
    return 0
}

# =============================================================================
# § pkg_kind_label KIND
#
#   Globals:
#     writes REPLY  the human name of a package kind
# =============================================================================
pkg_kind_label() {
    case $1 in
        brew-formula) REPLY='Homebrew formula' ;;
        brew-cask)    REPLY='Homebrew cask' ;;
        npm)          REPLY='npm global package' ;;
        pip3|pip)     REPLY="Python package ($1)" ;;
        cargo)        REPLY='Cargo binary' ;;
        gem)          REPLY='RubyGem' ;;
        binary)       REPLY='Binary' ;;
        *)            REPLY=$1 ;;
    esac
}

# =============================================================================
# § pkg_remove KIND TARGET
#
#   Removes one package with the tool that installed it.
#
#   Arguments:
#     KIND    see pkg_search
#     TARGET  package name, or the path of a binary
#   Outputs:
#     The tool's own output (the caller logs it)
#   Returns:
#     the tool's exit code; 124 when it ran longer than 3 × CMD_TIMEOUT;
#     2 for an unknown KIND or an unsafe binary path
# =============================================================================
pkg_remove() {
    local kind=$1 target=$2 dir
    local -i limit=$(( CMD_TIMEOUT * 3 ))
    case $kind in
        brew-formula) HOMEBREW_NO_AUTO_UPDATE=1 run_timeout "$limit" brew uninstall --formula -- "$target" ;;
        brew-cask)    HOMEBREW_NO_AUTO_UPDATE=1 run_timeout "$limit" brew uninstall --cask -- "$target" ;;
        npm)          run_timeout "$limit" npm uninstall -g -- "$target" ;;
        pip3|pip)     run_timeout "$limit" "$kind" uninstall -y -- "$target" ;;
        cargo)        run_timeout "$limit" cargo uninstall -- "$target" ;;
        gem)          run_timeout "$limit" gem uninstall -a -x -- "$target" ;;
        binary)
            # Only a file directly inside one of the searched bin folders.
            while IFS= read -r dir; do
                [[ $target == "$dir"/* && ${target#"$dir"/} != */* ]] && { rm -f -- "$target"; return $?; }
            done < <(_pkg_bin_dirs)
            printf 'refused: %s is not in a known bin folder\n' "$target"
            return 2 ;;
        *) printf 'unknown package kind: %s\n' "$kind"; return 2 ;;
    esac
}

# =============================================================================
# § uninstall_packages
#
#   Asks for a name, lists every package and binary that carries it, lets the
#   user tick what to remove, confirms, removes, and prints a summary.
#
#   Globals:
#     reads UNINSTALL_ASSUME_YES (pre-approval for non-interactive runs)
# =============================================================================
uninstall_packages() {
    local name rows kind target line id shown
    local -a kinds=() targets=()
    local -i n=0 removed=0 failed=0 rc kb

    section "UNINSTALL · PACKAGES & COMMAND-LINE TOOLS"
    printf "  ${DIM}Searches Homebrew, npm, pip, Cargo, RubyGems and the bin folders by name.${NC}\n"
    printf "  ${DIM}Leave blank and press Enter to go back.${NC}\n"
    printf "  ${CYN}Package or tool name:${NC} "
    read -r name || name=''
    name="${name#"${name%%[! ]*}"}"; name="${name%"${name##*[! ]}"}"     # trim
    if [[ -z $name ]]; then
        info "No name entered - going back."; echo; return 0
    fi
    # The name becomes part of a file-name pattern: letters, digits and a few
    # separators are all a package name ever needs.
    if [[ ! $name =~ ^[A-Za-z0-9@][A-Za-z0-9@._+/-]*$ ]]; then
        warn "\"$name\" does not look like a package name (letters, digits, . _ + - @ / only)."
        echo; return 0
    fi

    rows=$(mktemp "${MC_RUN_DIR:-${TMPDIR:-/tmp}}/packages.XXXXXX") || { fail "could not create a temp file"; return 1; }
    echo
    spinner_run "Searching the package managers for \"$name\"" _pkg_search_to "$name" "$rows.found"

    while IFS=$'\t' read -r kind target; do
        [[ -n $kind && -n $target ]] || continue
        kinds+=("$kind"); targets+=("$target")
        pkg_kind_label "$kind"
        kb=-2; shown=$target          # a package has no single size on disk
        if [[ $kind == binary ]]; then
            kb=$(path_size_kb "$target")
            [[ $target == "$HOME"/* ]] && shown="~${target#"$HOME"}"
        fi
        printf '%d\t%s\t%s\t%d\n' "$n" "$REPLY" "$shown" "$kb" >> "$rows"
        (( n++ ))
    done < "$rows.found"
    rm -f "$rows.found"

    if (( n == 0 )); then
        warn "Nothing found for \"$name\"."
        info "Looking for an app? Use \"Apps\" in the uninstall menu instead."
        rm -f "$rows"; echo; return 0
    fi

    ui_picker --hint "$n match(es) for \"$name\" - tick what to uninstall" \
              --verb uninstall --unit packages "Uninstall packages" "$rows"
    rm -f "$rows"
    if (( PICKER_CANCELLED )); then info "Cancelled - nothing changed."; echo; return 0; fi

    say "Selected ${#PICKER_RESULT[@]} of ${n}:"
    for id in "${PICKER_RESULT[@]}"; do
        pkg_kind_label "${kinds[id]}"
        info "• ${REPLY}  ${targets[id]}"
    done
    echo
    confirm_action "Uninstall these ${#PICKER_RESULT[@]} item(s)?" UNINSTALL_ASSUME_YES || return 0

    for id in "${PICKER_RESULT[@]}"; do
        kind=${kinds[id]} target=${targets[id]}
        pkg_kind_label "$kind"
        step "[$REPLY]  $target"
        rc=0
        pkg_remove "$kind" "$target" > "$MC_RUN_DIR/pkg.out" 2>&1 || rc=$?
        while IFS= read -r line; do info "│ $line"; done < "$MC_RUN_DIR/pkg.out"
        rm -f "$MC_RUN_DIR/pkg.out"
        if (( rc == 0 )); then
            (( removed++ )); (( TOTAL_CLEANED++ ))
            ok "uninstalled ← $target"
        else
            (( failed++ )); (( TOTAL_FAILED++ ))
            fail "failed (exit=${rc}) ← $target"
        fi
        echo
    done

    local -a card=("ok:${removed} of ${#PICKER_RESULT[@]} item(s) uninstalled")
    (( failed > 0 )) && card+=("fail:${failed} failed - the tool's own message is shown above")
    summary_card "Package uninstall summary" "${card[@]}"
    info "Full log: ${LOG_FILE}"
    echo
}

# Runs pkg_search into a file (spinner_run needs a plain command).
_pkg_search_to() { pkg_search "$1" > "$2" 2>/dev/null; }
