#!/usr/bin/env bash
# =============================================================================
# § lib/actions/worktree_clean.sh  ·  Remove stale git worktrees
#
#   AI agents and parallel branches leave dozens of linked worktrees behind,
#   each with its own vendor/ and node_modules/ (often 0.5-2 GB apiece). This
#   removes only the ones that are provably safe to drop:
#     • a linked worktree (its .git is a file pointing at .../worktrees/<name>)
#     • no file changed in WORKTREE_AGE_DAYS days (vendor/node_modules ignored)
#     • `git status` is clean (no uncommitted or untracked work)
#     • the repo has a remote, and HEAD has no commit missing from every remote
#     • no running process has a file open inside it
#     • its path does not match WORKTREE_KEEP_RE
#   Removal uses `git worktree remove` (never rm -rf), so every BRANCH is kept
#   and can be checked out again. Anything else is listed as kept, with why.
#
#   Opt-in action that always lists candidates and asks first. Automation can
#   opt in with WORKTREE_CLEAN_ASSUME_YES=1.
#
#   Env: WORKTREE_SCAN_ROOTS  space-separated roots (default: dev_roots)
#        WORKTREE_AGE_DAYS    idle threshold in days (default 7, ≥1)
#        WORKTREE_KEEP_RE     extended regex of paths never removed
#
#   Requires (sourced earlier): colors.sh, logging.sh, helpers.sh
#                               (dev_roots · run_timeout · dir_size_kb · human_size)
#   Public entry: worktree_clean
# =============================================================================
worktree_clean() {
    section "STALE GIT WORKTREES"

    if ! command -v git &>/dev/null; then
        skip_missing "git"
        return 0
    fi

    local age=${WORKTREE_AGE_DAYS:-7}
    [[ $age =~ ^[0-9]+$ ]] && (( age >= 1 )) || age=7
    local keep_re=${WORKTREE_KEEP_RE:-}

    local -a roots=()
    local r
    while IFS= read -r r; do roots+=("$r"); done < <(dev_roots WORKTREE_SCAN_ROOTS)
    if (( ${#roots[@]} == 0 )); then
        info "status  : no dev folders found"
        info "tip     : export WORKTREE_SCAN_ROOTS=/your/code to override"
        echo; return 0
    fi

    say "Scanning for linked git worktrees idle ${age}+ days"
    for r in "${roots[@]}"; do info "  - $r"; done
    info "timeout : ${SCAN_TIMEOUT}s"

    local found_f; found_f=$(mktemp)
    run_timeout "$SCAN_TIMEOUT" find "${roots[@]}" -maxdepth 7 \
        \( -name node_modules -o -name vendor -o -name Library -o -name .Trash \
           -o -name .venv -o -name venv \) -prune \
        -o -name .git -type f -print > "$found_f" 2>/dev/null
    (( $? == 124 )) && warn "scan timed out - narrow it with WORKTREE_SCAN_ROOTS"

    local -a cand=() cand_common=() kept=()
    local -i cand_kb=0 total=0
    local gitfile wt common dirty unpushed reason kb
    while IFS= read -r gitfile; do
        wt=${gitfile%/.git}
        grep -q '^gitdir: .*/worktrees/' "$gitfile" 2>/dev/null || continue
        [[ -n $(find "$wt" -maxdepth 3 \( -name node_modules -o -name vendor -o -name .git \) -prune \
                    -o -type f -mtime -"$age" -print 2>/dev/null | head -1) ]] && continue
        (( total++ ))

        reason=""
        if [[ -n $keep_re && $wt =~ $keep_re ]]; then
            reason="matches WORKTREE_KEEP_RE"
        elif ! git -C "$wt" rev-parse --git-dir &>/dev/null; then
            reason="git cannot read it (prunable?)"
        else
            dirty=$(git -C "$wt" status --porcelain 2>/dev/null | grep -c .)
            unpushed=$(git -C "$wt" rev-list HEAD --not --remotes 2>/dev/null | grep -c .)
            if (( dirty > 0 )); then
                reason="${dirty} uncommitted/untracked file(s)"
            elif [[ -z $(git -C "$wt" remote 2>/dev/null) ]]; then
                reason="repo has no remote - can't prove commits are saved"
            elif (( unpushed > 0 )); then
                reason="${unpushed} commit(s) not on any remote"
            elif [[ -n $(lsof -t +D "$wt" 2>/dev/null | head -1) ]]; then
                reason="a running process has files open in it"
            fi
        fi

        if [[ -n $reason ]]; then
            kept+=("${wt/#$HOME/~}  ← $reason")
        else
            common=$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
            kb=$(dir_size_kb "$wt")
            cand+=("$wt"); cand_common+=("$common"); (( cand_kb += kb ))
        fi
    done < "$found_f"
    rm -f "$found_f"

    info "found   : ${total} idle linked worktree(s)"
    echo

    local k
    if (( ${#kept[@]} > 0 )); then
        say "Kept (${#kept[@]}) - have work that is not safe to drop:"
        for k in "${kept[@]}"; do info "  $k"; done
        echo
    fi

    if (( ${#cand[@]} == 0 )); then
        ok "No stale worktrees safe to remove."
        echo; return 0
    fi

    say "Safe to remove (${#cand[@]}, $(human_size "$cand_kb")) - clean, pushed, unused:"
    for k in "${cand[@]}"; do info "  ${k/#$HOME/~}"; done
    echo

    confirm_action "Remove these ${#cand[@]} worktrees? Branches are kept." WORKTREE_CLEAN_ASSUME_YES || return 0

    local -i i removed=0 before_kb after_kb
    before_kb=$(disk_avail_kb)
    for (( i = 0; i < ${#cand[@]}; i++ )); do
        wt=${cand[i]}
        if [[ -n $(git -C "$wt" status --porcelain 2>/dev/null) ]]; then
            warn "changed since the scan - kept: ${wt/#$HOME/~}"
            continue
        fi
        if git --git-dir="${cand_common[i]}" worktree remove "$wt" 2>/dev/null; then
            (( removed++ )); ok "removed ${wt/#$HOME/~}"
        else
            (( TOTAL_FAILED++ )); warn "git refused to remove ${wt/#$HOME/~} (locked?)"
        fi
    done
    after_kb=$(disk_avail_kb)
    (( after_kb > before_kb )) && (( TOTAL_FREED_KB += after_kb - before_kb ))
    (( removed > 0 )) && (( TOTAL_CLEANED++ ))

    info "tip     : 'git worktree add <path> <branch>' brings any of them back"
    ok "Removed ${removed}/${#cand[@]} stale worktree(s)."
    echo
}
