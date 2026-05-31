#!/usr/bin/env bash
# =============================================================================
# § lib/helpers.sh  ·  Filesystem + execution helpers
#
#   Reusable, side-effect-aware building blocks shared by every action:
#     • disk_free / human_size / dir_size_kb — measurement
#     • run_timeout                          — portable timeout wrapper
#     • run_step                             — logged command execution
#     • clean_dir / clean_old_tmp           — safe content deletion
#     • clean_tm_snapshots                   — Time Machine local snapshots
#     • report_largest_dirs                  — informational disk report
#     • _scan_and_delete                     — dev-folder artefact sweeper
#
#   Requires (sourced earlier): colors.sh, core.sh (counters/timeouts), logging.sh
# =============================================================================

# =============================================================================
# § UTILITY: disk / size helpers
# =============================================================================
disk_free() { df -h / | awk 'NR==2 {print $4 " free of " $2}'; }

human_size() {
    local -i kb=$1
    if   (( kb >= 1048576 )); then awk -v k="$kb" 'BEGIN{printf "%.2f GB", k/1048576}'
    elif (( kb >= 1024 ));    then awk -v k="$kb" 'BEGIN{printf "%.1f MB", k/1024}'
    else                           printf '%d KB' "$kb"
    fi
}

dir_size_kb() {
    local p="$1"
    [[ -d $p ]] || { printf '0'; return; }
    du -sk "$p" 2>/dev/null | awk '{print $1+0}'
}

# =============================================================================
# § TIMEOUT WRAPPER
#
#   Preference order:
#     1. gtimeout  (brew install coreutils)   — most reliable on macOS
#     2. timeout   (available on macOS 12+)
#     3. pure-bash watchdog fallback
#
#   Exit code 124 = timed out  (POSIX timeout convention)
# =============================================================================
_TIMEOUT_BIN=''
if   command -v gtimeout &>/dev/null; then _TIMEOUT_BIN='gtimeout'
elif command -v timeout  &>/dev/null; then _TIMEOUT_BIN='timeout'
fi

run_timeout() {
    local -i secs=$1; shift

    if [[ -n $_TIMEOUT_BIN ]]; then
        "$_TIMEOUT_BIN" --kill-after=5 "$secs" "$@"
        return $?
    fi

    # ── pure-bash fallback ──────────────────────────────────────────────────
    "$@" &
    local -i child=$! waited=0
    while (( waited < secs )); do
        sleep 1; (( waited++ ))
        kill -0 "$child" 2>/dev/null || { wait "$child"; return $?; }
    done
    kill -TERM "$child" 2>/dev/null
    sleep 2
    kill -KILL "$child" 2>/dev/null
    wait "$child" 2>/dev/null
    return 124
}

# =============================================================================
# § run_step LABEL COMMAND_STRING
#
#   Executes COMMAND_STRING (via bash -c) with CMD_TIMEOUT.
#   • Captures and logs every line of stdout and stderr verbosely.
#   • Records exit code, elapsed time, and timeout state.
#   • Never aborts the outer script on failure.
# =============================================================================
run_step() {
    local label="$1"
    local cmd="$2"

    local stdout_f stderr_f
    stdout_f=$(mktemp)
    stderr_f=$(mktemp)

    step  "[$label]"
    info  "cmd     : $cmd"
    info  "timeout : ${CMD_TIMEOUT}s"

    local -i t0 t1 elapsed rc=0
    t0=$(date +%s)

    run_timeout "$CMD_TIMEOUT" bash -c "$cmd" >"$stdout_f" 2>"$stderr_f" || rc=$?

    t1=$(date +%s)
    (( elapsed = t1 - t0 )) || true

    # ── verbose stdout ──────────────────────────────────────────────────────
    if [[ -s $stdout_f ]]; then
        info "stdout  :"
        while IFS= read -r line; do
            info "  │ $line"
        done < "$stdout_f"
    fi

    # ── verbose stderr ──────────────────────────────────────────────────────
    if [[ -s $stderr_f ]]; then
        info "stderr  :"
        while IFS= read -r line; do
            info "  │ $line"
        done < "$stderr_f"
    fi

    rm -f "$stdout_f" "$stderr_f"
    info "exit    : ${rc}   elapsed: ${elapsed}s"

    if   (( rc == 124 )); then
        (( TOTAL_TIMEDOUT++ )); (( TOTAL_FAILED++ ))
        warn "TIMED OUT after ${CMD_TIMEOUT}s ← $label"
    elif (( rc == 0 )); then
        (( TOTAL_CLEANED++ ))
        ok   "done (${elapsed}s) ← $label"
    else
        (( TOTAL_FAILED++ ))
        warn "FAILED exit=${rc} (${elapsed}s) ← $label"
    fi
    echo
}

# =============================================================================
# § clean_dir TARGET LABEL [SUDO_PREFIX] [TIMEOUT_SECS]
#
#   Removes the *contents* of TARGET (preserves the directory itself).
#   • Logs size-before, item count, and size freed.
#   • Times the deletion and enforces DIR_TIMEOUT.
# =============================================================================
clean_dir() {
    local target="$1"
    local label="$2"
    local sudo_prefix="${3:-}"
    local -i timeout_sec=${4:-$DIR_TIMEOUT}

    step "[$label]"
    info "path    : $target"
    info "timeout : ${timeout_sec}s"

    if [[ ! -d $target ]]; then
        info "status  : not present — nothing to do"
        (( TOTAL_SKIPPED_MISSING++ ))
        echo
        return 0
    fi

    local -i size_before_kb items t0 t1 elapsed rc=0
    local    size_before_h
    size_before_kb=$(dir_size_kb "$target")
    size_before_h=$(human_size "$size_before_kb")
    # shellcheck disable=SC2086
    items=$( $sudo_prefix find "$target" -mindepth 1 2>/dev/null | wc -l | tr -d ' ' )
    info "size    : ${size_before_h}  (${items} items)"

    if (( size_before_kb == 0 && items == 0 )); then
        info "status  : already empty"
        echo
        return 0
    fi

    info "action  : deleting contents…"
    t0=$(date +%s)

    # shellcheck disable=SC2086
    run_timeout "$timeout_sec" $sudo_prefix find "$target" -mindepth 1 -delete 2>/dev/null \
        || rc=$?

    t1=$(date +%s)
    (( elapsed = t1 - t0 )) || true
    info "elapsed : ${elapsed}s   exit: ${rc}"

    if (( rc == 124 )); then
        (( TOTAL_TIMEDOUT++ )); (( TOTAL_SKIPPED_PROTECTED++ ))
        warn "TIMED OUT after ${timeout_sec}s — partial cleanup ← $label"
    elif (( rc == 0 )); then
        local -i size_after_kb freed_kb
        size_after_kb=$(dir_size_kb "$target")
        (( freed_kb = size_before_kb - size_after_kb )) || true
        (( freed_kb < 0 )) && freed_kb=0
        (( TOTAL_FREED_KB += freed_kb ))
        (( TOTAL_CLEANED++ ))
        ok "freed $(human_size $freed_kb) in ${elapsed}s ← $label"
    else
        (( TOTAL_SKIPPED_PROTECTED++ ))
        warn "partial (exit=${rc}, ${elapsed}s) — some items in use ← $label"
    fi
    echo
}

# =============================================================================
# § skip_missing LABEL
#
#   Prints a uniform "not installed — skipping" notice.
#   Use wherever a tool is absent and no action can be taken.
# =============================================================================
skip_missing() {
    step "[$1]"
    info "status  : not installed — skipping"
    echo
}

# =============================================================================
# § clean_old_tmp LABEL PATH [SUDO_PREFIX]
#
#   Removes items inside PATH that have not been modified in >3 days.
#   Safe to call on any tmp-like directory.
# =============================================================================
clean_old_tmp() {
    local label="$1"
    local path="$2"
    local sudo_prefix="${3:-}"

    step "[$label  (mtime >3 days)]"
    info "path    : $path"

    if [[ ! -d $path ]]; then
        info "status  : not present — nothing to do"
        echo; return 0
    fi

    local -i cnt=0 rc=0
    # shellcheck disable=SC2086
    cnt=$( $sudo_prefix find "$path" -mindepth 1 -mtime +3 2>/dev/null \
           | wc -l | tr -d ' ' )
    info "found   : $cnt old items"

    if (( cnt > 0 )); then
        # shellcheck disable=SC2086
        $sudo_prefix find "$path" -mindepth 1 -mtime +3 -delete 2>/dev/null || rc=$?
        if (( rc == 0 )); then
            (( TOTAL_CLEANED++ ))
            ok "removed $cnt items ← $label"
        else
            (( TOTAL_FAILED++ ))
            warn "partial removal (exit=${rc}) ← $label"
        fi
    else
        info "status  : nothing to clean"
    fi
    echo
}

# =============================================================================
# § clean_tm_snapshots
#
#   Lists and deletes all Time Machine local snapshots on the boot volume.
#   Local snapshots are temporary backups stored on-disk; deleting them is
#   safe — they have no effect on your remote Time Machine backup.
#   Requires sudo for deletion.
# =============================================================================
clean_tm_snapshots() {
    step "[Time Machine local snapshots]"

    if ! command -v tmutil &>/dev/null; then
        info "status  : tmutil not found — skipping"
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
        info "status  : no local snapshots — nothing to do"
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
        warn "deleted ${deleted}/${#dates[@]} (${failed} failed — may need sudo or newer macOS)"
    fi
    echo
}

# =============================================================================
# § report_largest_dirs PATH LABEL [DEPTH] [COUNT]
#
#   Prints a ranked list of the largest subdirectories under PATH.
#   Purely informational — nothing is deleted.
#   DEPTH defaults to 1; COUNT defaults to 20.
# =============================================================================
report_largest_dirs() {
    local path="$1"
    local label="$2"
    local -i depth=${3:-1}
    local -i count=${4:-20}

    step "[$label — top ${count} by size]"
    info "path    : $path  (depth ${depth})"

    if [[ ! -d $path ]]; then
        info "status  : directory not present"
        echo; return 0
    fi

    local results
    results=$(du -hd "$depth" "$path" 2>/dev/null | sort -hr | head -"$count")

    if [[ -n $results ]]; then
        while IFS= read -r line; do
            info "  $line"
        done <<< "$results"
    else
        info "status  : no data returned"
    fi
    echo
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
    if [[ -n ${!envvar:-} ]]; then
        read -ra roots <<< "${!envvar}"
    else
        local d
        for d in \
            "$HOME/Documents" "$HOME/Developer" "$HOME/Projects" "$HOME/projects" \
            "$HOME/Code"      "$HOME/code"      "$HOME/dev"      "$HOME/Dev"     \
            "$HOME/repos"     "$HOME/Repos"     "$HOME/src"      "$HOME/workspace" \
            "$HOME/Workspace" "$HOME/Sites"     "$HOME/work"     "$HOME/Work"; do
            [[ -d $d ]] && roots+=("$d")
        done
    fi

    if (( ${#roots[@]} == 0 )); then
        info "status  : no dev folders found"
        info "tip     : export ${envvar}=/your/code to override"
        echo; return 0
    fi

    info "roots   :"
    local r; for r in "${roots[@]}"; do info "  - $r"; done
    info "(heartbeat active — Ctrl+C to skip this scan)"

    local hit_list; hit_list=$(mktemp)

    (
        find "${roots[@]}" \
            -maxdepth 6 \
            \( -path '*/node_modules' -o -path '*/.git'   -o -path '*/Library' \
               -o -path '*/.Trash'    -o -path '*/.venv'  -o -path '*/venv'    \
               -o -path '*/.tox' \) -prune -o \
            "${preds[@]}" -print 2>/dev/null
    ) > "$hit_list" &
    local -i fpid=$! waited=0 scan_ok=1

    while kill -0 "$fpid" 2>/dev/null; do
        sleep 2; (( waited += 2 ))
        local -i cur; cur=$(wc -l < "$hit_list" 2>/dev/null | tr -d ' ')
        printf "${DIM}    …%ds  %d found${NC}\r" "$waited" "${cur:-0}"
        if (( waited >= SCAN_TIMEOUT )); then
            kill "$fpid" 2>/dev/null; wait "$fpid" 2>/dev/null
            printf '\n'
            warn "scan timed out (${SCAN_TIMEOUT}s) — set ${envvar}= for a narrower scope"
            scan_ok=0; break
        fi
    done
    wait "$fpid" 2>/dev/null; printf '\n'

    local -i found=0 deleted=0
    found=$(wc -l < "$hit_list" | tr -d ' ')
    info "found   : ${found} entries"

    if (( found > 0 )); then
        local entry
        while IFS= read -r entry; do
            rm -rf "$entry" 2>/dev/null && (( deleted++ )) || true
            if (( deleted % 25 == 0 && deleted > 0 )); then
                printf "${DIM}    deleted %d / %d${NC}\r" "$deleted" "$found"
            fi
        done < "$hit_list"
        printf '\n'
        (( TOTAL_CLEANED++ ))
        ok "deleted ${deleted}/${found} entries ← $label"
    else
        info "status  : nothing to clean"
    fi

    rm -f "$hit_list"
    echo
}
