#!/usr/bin/env bash
# =============================================================================
# § lib/helpers/scan.sh  ·  Dev-folder discovery and artefact sweeper
#
#   Single responsibility: know where code projects live, and sweep named
#   build artefacts out of them.
#
#     dev_roots           the folders where projects usually live
#     _scan_and_delete    find + delete artefacts by find(1) predicates
#
#   Requires (sourced earlier): colors.sh, core.sh (SCAN_TIMEOUT), logging.sh
# =============================================================================

# =============================================================================
# § dev_roots [ENVVAR]
#
#   Prints the folders where code projects usually live, one per line. If
#   ENVVAR names a non-empty variable, its space-separated list wins instead.
#   ~/Desktop is included: many people keep their projects there.
#   On a case-insensitive disk (the macOS default) ~/Projects and ~/projects
#   are the same folder, so duplicates are dropped by inode.
# =============================================================================
dev_roots() {
    local envvar="${1:-}" d seen
    local -a list=()
    if [[ -n $envvar && -n ${!envvar:-} ]]; then
        read -ra list <<< "${!envvar}"
    else
        list=(
            "$HOME/Desktop"   "$HOME/Documents" "$HOME/Developer" "$HOME/Projects"
            "$HOME/projects"  "$HOME/Code"      "$HOME/code"      "$HOME/dev"
            "$HOME/Dev"       "$HOME/repos"     "$HOME/Repos"     "$HOME/src"
            "$HOME/workspace" "$HOME/Workspace" "$HOME/Sites"     "$HOME/work"
            "$HOME/Work"
        )
    fi
    local -a out=()
    for d in "${list[@]}"; do
        [[ -d $d ]] || continue
        for seen in ${out[@]+"${out[@]}"}; do [[ $d -ef $seen ]] && continue 2; done
        out+=("$d")
        printf '%s\n' "$d"
    done
}

# =============================================================================
# § _scan_and_delete  LABEL ENVVAR DESCRIPTION FIND_PREDICATES...
#
#   Finds and removes directories/files matching FIND_PREDICATES inside
#   common dev-folder roots.  ENVVAR can supply a custom root list.
#   • Heartbeat every 2s; aborts at SCAN_TIMEOUT.
#   • Logs found count, deleted count, and any partial-timeout notice.
# =============================================================================
_scan_and_delete() {
    local label="$1"
    local envvar="$2"
    local desc="$3"
    shift 3
    local -a preds=("$@")    # raw find predicates passed through unchanged

    step "[$label]"
    info "timeout : ${SCAN_TIMEOUT}s"
    info "looking : $desc"

    # ── build root list ─────────────────────────────────────────────────────
    local -a roots=()
    local d
    while IFS= read -r d; do roots+=("$d"); done < <(dev_roots "$envvar")

    if (( ${#roots[@]} == 0 )); then
        info "status  : no dev folders found"
        info "tip     : export ${envvar}=/your/code to override"
        echo; return 0
    fi

    info "roots   :"
    local r; for r in "${roots[@]}"; do info "  - $r"; done
    info "(heartbeat active - Ctrl+C to skip this scan)"

    local hit_list; hit_list=$(mktemp)

    (
        find "${roots[@]}" \
            -maxdepth 6 \
            \( -path '*/node_modules' -o -path '*/.git'   -o -path '*/Library' \
               -o -path '*/.Trash'    -o -path '*/.venv'  -o -path '*/venv'    \
               -o -path '*/.tox' \) -prune -o \
            "${preds[@]}" -print 2>/dev/null
    ) > "$hit_list" &
    local -i fpid=$! waited=0 tty=0
    [[ -t 1 ]] && tty=1    # live counters only on a terminal, not in a job's buffer

    while kill -0 "$fpid" 2>/dev/null; do
        sleep 2; (( waited += 2 ))
        local -i cur; cur=$(wc -l < "$hit_list" 2>/dev/null | tr -d ' ')
        (( tty )) && printf "${DIM}    …%ds  %d found${NC}\r" "$waited" "${cur:-0}"
        if (( waited >= SCAN_TIMEOUT )); then
            kill "$fpid" 2>/dev/null; wait "$fpid" 2>/dev/null
            (( tty )) && printf '\n'
            warn "scan timed out (${SCAN_TIMEOUT}s) - set ${envvar}= for a narrower scope"
            break
        fi
    done
    wait "$fpid" 2>/dev/null; (( tty )) && printf '\n'

    local -i found=0 deleted=0
    found=$(wc -l < "$hit_list" | tr -d ' ')
    info "found   : ${found} entries"

    if (( found > 0 )); then
        local entry
        while IFS= read -r entry; do
            rm -rf "$entry" 2>/dev/null && (( deleted++ )) || true
            if (( tty && deleted % 25 == 0 && deleted > 0 )); then
                printf "${DIM}    deleted %d / %d${NC}\r" "$deleted" "$found"
            fi
        done < "$hit_list"
        (( tty )) && printf '\n'
        (( TOTAL_CLEANED++ ))
        ok "deleted ${deleted}/${found} entries ← $label"
    else
        info "status  : nothing to clean"
    fi

    rm -f "$hit_list"
    echo
}
