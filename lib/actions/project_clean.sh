#!/usr/bin/env bash
# =============================================================================
# § lib/actions/project_clean.sh  ·  Project build folders (plonge rules)
#
#   Every project keeps its own node_modules, .venv, target, .build, dist …
#   and every agent worktree keeps another copy. This finds those folders under
#   your dev folders and deletes the ones that are provably rebuildable, using
#   the rules and Git checks of plonge (github.com/mattt/plonge):
#
#     • the name matches a rule; generic names also need a project file beside
#       them (target → Cargo.toml or pom.xml, dist → package.json, …)
#     • it is inside a Git work tree, Git ignores it, and none of its files
#       are tracked
#     • it holds no Git repository of its own
#     • the repo has had no Git activity (commit, checkout, …) for
#       PROJECT_QUIET_HOURS hours, and no running process works inside it
#     • its path does not match PROJECT_KEEP_RE
#   Everything else is kept and listed with why.
#
#   Opt-in action that always lists candidates and asks first. Automation can
#   opt in with PROJECT_CLEAN_ASSUME_YES=1.
#
#   Env: PROJECT_SCAN_ROOTS   space-separated roots (default: dev_roots)
#        PROJECT_QUIET_HOURS  hours with no Git activity (default 24, ≥1)
#        PROJECT_KEEP_RE      extended regex of paths never removed
#
#   Requires (sourced earlier): colors.sh, logging.sh, helpers.sh
#                               (dev_roots · run_timeout · dir_size_kb · human_size)
#   Public entry: project_clean
# =============================================================================

# Folder names deleted wherever Git ignores them (plonge's default rules).
_PC_ALWAYS=" .astro .build .gradle .mypy_cache .next .nox .parcel-cache .pytest_cache \
.ruff_cache .svelte-kit .tox .turbo .venv DerivedData __pycache__ node_modules "

# _pc_rule PATH → prints the matched rule ("node_modules", "target beside
# Cargo.toml", …) and returns 0, or returns 1 when PATH matches no rule.
_pc_rule() {
    local p=$1 name=${1##*/} parent=${1%/*} f
    if [[ $_PC_ALWAYS == *" $name "* ]]; then printf '%s' "$name"; return 0; fi

    local -a beside=()
    case $p in
        */tmp/cache)     parent=${p%/tmp/cache};     name="tmp/cache";     beside=(config.ru) ;;
        */vendor/bundle) parent=${p%/vendor/bundle}; name="vendor/bundle"; beside=(Gemfile gems.rb) ;;
        *)
            case $name in
                .zig-cache|zig-cache) beside=(build.zig) ;;
                _build)  beside=(mix.exs) ;;
                bin|obj) beside=('*.csproj' '*.fsproj' '*.vbproj') ;;
                build)   beside=(build.gradle build.gradle.kts pyproject.toml settings.gradle settings.gradle.kts setup.py) ;;
                dist)    beside=(package.json pyproject.toml setup.py) ;;
                target)  beside=(Cargo.toml pom.xml) ;;
                venv)    beside=(pyproject.toml requirements.txt setup.py) ;;
                *) return 1 ;;
            esac ;;
    esac
    local pat
    for pat in "${beside[@]}"; do
        # shellcheck disable=SC2086
        for f in "$parent"/$pat; do
            [[ -f $f ]] && { printf '%s beside %s' "$name" "${f##*/}"; return 0; }
        done
    done
    return 1
}

# _pc_why_kept PATH → prints why PATH must be kept, or nothing when it is safe.
_pc_why_kept() {
    local p=$1 top gitdir head_log
    if [[ -n ${PROJECT_KEEP_RE:-} && $p =~ $PROJECT_KEEP_RE ]]; then
        printf 'matches PROJECT_KEEP_RE'; return
    fi
    top=$(git -C "${p%/*}" rev-parse --show-toplevel 2>/dev/null) || { printf 'not inside a Git work tree'; return; }
    git -C "$top" check-ignore -q "$p" 2>/dev/null || { printf 'Git does not ignore it'; return; }
    [[ -z $(git -C "$top" ls-files -- "$p" 2>/dev/null | head -1) ]] || { printf 'holds files tracked by Git'; return; }
    [[ -z $(find "$p" -mindepth 1 -maxdepth 4 -name .git -print 2>/dev/null | head -1) ]] \
        || { printf 'holds a Git repository'; return; }
    case $p in
        */_build) [[ -z $(find "$p" -mindepth 2 -maxdepth 4 \( -path '*/rel' -o -path '*/lib/*/src' \) -print 2>/dev/null | head -1) ]] \
                      || { printf 'holds a release or source folder'; return; } ;;
    esac

    # Quiet: no Git activity (reflog / HEAD change) in PROJECT_QUIET_HOURS.
    gitdir=$(git -C "$top" rev-parse --path-format=absolute --git-dir 2>/dev/null)
    head_log="$gitdir/logs/HEAD"; [[ -f $head_log ]] || head_log="$gitdir/HEAD"
    if [[ -n $(find "$head_log" -mmin -$(( _PC_QUIET * 60 )) 2>/dev/null) ]]; then
        printf 'Git activity in the last %sh' "$_PC_QUIET"; return
    fi
    # In use: a running process has its working directory inside the project.
    local cwd
    while IFS= read -r cwd; do
        [[ $cwd == "$top" || $cwd == "$top"/* ]] && { printf 'a running process works in %s' "${top/#$HOME/~}"; return; }
    done <<< "$_PC_CWDS"
}

project_clean() {
    section "PROJECT BUILD FOLDERS (node_modules · .venv · target · …)"

    if ! command -v git &>/dev/null; then
        skip_missing "git"
        return 0
    fi

    _PC_QUIET=${PROJECT_QUIET_HOURS:-24}
    [[ $_PC_QUIET =~ ^[0-9]+$ ]] && (( _PC_QUIET >= 1 )) || _PC_QUIET=24

    local -a roots=()
    local r
    while IFS= read -r r; do roots+=("$r"); done < <(dev_roots PROJECT_SCAN_ROOTS)
    if (( ${#roots[@]} == 0 )); then
        info "status  : no dev folders found"
        info "tip     : export PROJECT_SCAN_ROOTS=/your/code to override"
        echo; return 0
    fi

    say "Scanning for rebuildable project folders (plonge rules)"
    for r in "${roots[@]}"; do info "  - $r"; done
    info "timeout : ${SCAN_TIMEOUT}s"

    # A matched folder is printed and not entered (-prune): nothing nested in
    # a node_modules is ever listed on its own.
    local found_f; found_f=$(mktemp)
    run_timeout "$SCAN_TIMEOUT" find "${roots[@]}" -maxdepth 8 \
        \( -name .git -o -name Library -o -name .Trash \) -prune -o \
        -type d \( -name node_modules -o -name .venv -o -name venv -o -name target \
            -o -name .build -o -name build -o -name dist -o -name DerivedData \
            -o -name .next -o -name .svelte-kit -o -name .astro -o -name .turbo \
            -o -name .parcel-cache -o -name .gradle -o -name .tox -o -name .nox \
            -o -name __pycache__ -o -name .pytest_cache -o -name .mypy_cache \
            -o -name .ruff_cache -o -name .zig-cache -o -name zig-cache -o -name _build \
            -o -name bin -o -name obj -o -path '*/tmp/cache' -o -path '*/vendor/bundle' \) \
        -print -prune > "$found_f" 2>/dev/null
    (( $? == 124 )) && warn "scan timed out - narrow it with PROJECT_SCAN_ROOTS"

    _PC_CWDS=$(lsof -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | sort -u)

    local -a cand=() cand_kb=() kept=()
    local -i total_kb=0 kb
    local p rule why
    while IFS= read -r p; do
        rule=$(_pc_rule "$p") || continue
        why=$(_pc_why_kept "$p")
        if [[ -n $why ]]; then
            kept+=("${p/#$HOME/~}  ← $why")
        else
            kb=$(dir_size_kb "$p")
            (( kb == 0 )) && continue
            cand+=("$p"); cand_kb+=("$kb"); (( total_kb += kb ))
        fi
    done < "$found_f"
    rm -f "$found_f"

    local k i
    if (( ${#kept[@]} > 0 )); then
        say "Kept (${#kept[@]}):"
        for (( i = 0; i < ${#kept[@]} && i < 25; i++ )); do info "  ${kept[i]}"; done
        (( ${#kept[@]} > 25 )) && info "  … and $(( ${#kept[@]} - 25 )) more (see the log)"
        for (( ; i < ${#kept[@]}; i++ )); do printf '    %s\n' "${kept[i]}" >> "$LOG_FILE"; done
        echo
    fi

    if (( ${#cand[@]} == 0 )); then
        ok "No project build folders safe to remove."
        echo; return 0
    fi

    say "Safe to remove (${#cand[@]}, $(human_size "$total_kb")) - ignored by Git, rebuildable:"
    # Largest 30 on screen; the full list goes to the log.
    local -i n=0
    for (( i = 0; i < ${#cand[@]}; i++ )); do
        printf '%s\t%s\n' "${cand_kb[i]}" "${cand[i]}"
    done | sort -rn | while IFS=$'\t' read -r kb p; do
        (( n++ ))
        if (( n <= 30 )); then
            info "  $(printf '%10s' "$(human_size "$kb")")  ${p/#$HOME/~}"
        else
            printf '    %10s  %s\n' "$(human_size "$kb")" "${p/#$HOME/~}" >> "$LOG_FILE"
        fi
    done
    (( ${#cand[@]} > 30 )) && info "  … and $(( ${#cand[@]} - 30 )) smaller ones (full list in the log)"
    echo

    if [[ -t 0 ]]; then
        printf "  ${YLW}Delete these %d folders? Rebuild with npm install, uv sync, cargo build … [y/N]: ${NC}" "${#cand[@]}"
        local answer; read -r answer
        if [[ $answer != [yY] ]]; then
            info "Cancelled - nothing removed."; echo; return 0
        fi
    elif [[ ${PROJECT_CLEAN_ASSUME_YES:-0} == 1 ]]; then
        info "non-interactive - PROJECT_CLEAN_ASSUME_YES=1, proceeding"
    else
        warn "non-interactive and no confirmation possible - skipping (set PROJECT_CLEAN_ASSUME_YES=1)"
        echo; return 0
    fi
    echo

    local -i removed=0 freed_kb=0
    for (( i = 0; i < ${#cand[@]}; i++ )); do
        p=${cand[i]}
        why=$(_pc_why_kept "$p")     # re-check: a lot can change while you read
        if [[ -n $why ]]; then
            warn "changed since the scan - kept: ${p/#$HOME/~} ($why)"
            continue
        fi
        # Read-only trees (Go module caches inside .venv, etc.) need u+w first.
        if run_timeout "$DIR_TIMEOUT" rm -rf "$p" 2>/dev/null \
           || { chmod -R u+w "$p" 2>/dev/null; run_timeout "$DIR_TIMEOUT" rm -rf "$p" 2>/dev/null; }; then
            (( removed++ )); (( freed_kb += cand_kb[i] ))
        else
            (( TOTAL_FAILED++ )); warn "could not fully remove ${p/#$HOME/~}"
        fi
    done
    (( TOTAL_FREED_KB += freed_kb ))
    (( removed > 0 )) && (( TOTAL_CLEANED++ ))
    ok "Removed ${removed}/${#cand[@]} folder(s), $(human_size "$freed_kb") freed."
    echo
}
