#!/usr/bin/env bash
# =============================================================================
# § lib/helpers/duscan.sh  ·  Fast, parallel folder measurement
#
#   Single responsibility: measure a folder two levels deep - the folder, its
#   sub-folders, and their sub-folders - as fast as the disk allows, and let
#   the caller watch it happen. Used by the disk map and by the cleanup's
#   disk-usage report. Nothing here deletes anything.
#
#     du_scan_start      start the background workers on a folder
#     du_scan_running    are they still going?
#     du_scan_progress   → DU_SCAN_DONE / DU_SCAN_TOTAL / DU_SCAN_LATEST
#     du_scan_merge      the listing so far (or the final one)
#     du_scan_stop       stop early
#     du_loose_kb        size of the files directly inside a folder
#
#   Why not just `du`?  One `du` walks a tree on a single core. A home folder
#   usually hides one or two very deep trees (a folder of git worktrees, an
#   Xcode cache) that take a minute on their own, while everything else is
#   done in seconds. So the work is cut into jobs, and the cut adapts:
#
#     • a job is "measure this folder" (one `du`), taken from a shared queue by
#       a pool of workers
#     • a job that is still running after DU_SPLIT_SECS is stopped and replaced
#       by one job per sub-folder - so a slow tree is spread over all workers,
#       level by level, wherever it sits (up to DU_SPLIT_DEPTH levels down)
#     • each finished job adds its size to the folder it belongs to, so the
#       caller sees every folder grow while the scan runs
#
#   Working files (in the WORK folder the caller provides):
#     queue    one job per line: "DEPTH<TAB>PATH"; only ever appended to
#     claim/N  exists once a worker has taken queue line N
#     fin      one line per finished job (its path)
#     out/wK   results of worker K: "KB<TAB>PATH" - KB belongs to PATH
#     latest   the result written last ("KB<TAB>PATH"), for a status line
#     stop     exists when the scan was told to stop
#
#   Env: DM_JOBS          workers (default: CPU count, at most 16)
#        DU_SPLIT_SECS    seconds before a slow folder is split (default 1;
#                         0 = always split, which the tests use)
#        DU_SPLIT_DEPTH   levels below the root that may be split (default 6)
#
#   Requires (sourced earlier): helpers/process.sh (kill_tree)
# =============================================================================

DU_SCAN_PIDS=()         # the running workers
DU_SCAN_DONE=0          # jobs finished       } set by du_scan_progress
DU_SCAN_TOTAL=0         # jobs known so far   }
DU_SCAN_LATEST=''       # "KB<TAB>PATH" of the result written last

# A folder with more sub-folders than this is measured whole, never split:
# thousands of tiny jobs (node_modules, .git/objects) cost more than they save.
declare -ri DU_SPLIT_MAX_KIDS=300

# Folders of the scanned root that are split straight away - in a home folder
# these are always the heavy ones, so there is no point in timing them first.
declare -r DU_PRESPLIT_RE='^(Library|Desktop|Documents|Developer|[Pp]rojects|[Cc]ode|[Dd]ev|[Rr]epos|src|[Ww]orkspace)$'

# =============================================================================
# § du_loose_kb DIR
#
#   Outputs:
#     KB used by the files (not folders) directly inside DIR.
# =============================================================================
du_loose_kb() {
    find "$1" -mindepth 1 -maxdepth 1 ! -type d -exec du -sk {} + 2>/dev/null \
        | awk '{ s += $1 } END { print s + 0 }'
}

# =============================================================================
# § _du_scan_split WORK WORKER DEPTH PATH
#
#   Replaces the job for PATH by one job per sub-folder. The files directly in
#   PATH are counted here, since no sub-folder job will see them.
#
#   Returns:
#     0 when the jobs were queued; 1 when PATH has no sub-folders, or too many
#     to be worth it - the caller then measures PATH whole
# =============================================================================
_du_scan_split() {
    local work=$1 path=$4 kid
    local -i depth=$3 n=0
    local -a kids=()
    # A glob, not `find` through a process substitution: this runs hundreds of
    # times in one worker, and bash 3.2 would keep a file descriptor open for
    # each of those (see "process substitution" in lib/core.sh).
    for kid in "$path"/* "$path"/.[!.]* "$path"/..?*; do
        [[ -d $kid && ! -L $kid ]] || continue        # real folders only
        kids+=("$kid")
        (( ++n > DU_SPLIT_MAX_KIDS )) && return 1
    done
    (( n == 0 )) && return 1

    printf '%d\t%s\n' "$(du_loose_kb "$path")" "$path" >> "$work/out/w$2"
    # One short append per job: each is written whole, so a worker reading the
    # queue never sees half a line.
    for kid in "${kids[@]}"; do printf '%d\t%s\n' "$(( depth + 1 ))" "$kid" >> "$work/queue"; done
    return 0
}

# =============================================================================
# § _du_scan_job WORK WORKER DEPTH PATH
#
#   Measures one folder. DEPTH is how far below the scan root it sits: a
#   depth-1 folder is listed together with its sub-folders (the caller shows
#   two levels); anything deeper only reports its total.
#
#   A folder that may still be split is given DU_SPLIT_SECS; if `du` has not
#   finished by then it is stopped and the folder is split instead.
# =============================================================================
_du_scan_job() {
    local work=$1 k=$2 path=$4 tmp="$1/tmp.$2" kb
    local -i depth=$3 levels=0 rc=0 pid dog
    (( depth == 1 )) && levels=1

    if (( depth < _DU_DEPTH )); then
        if (( _DU_SECS == 0 )); then
            rc=143                                   # test mode: always split
        else
            du -k -d "$levels" "$path" > "$tmp" 2>/dev/null &
            pid=$!
            ( sleep "$_DU_SECS"; kill "$pid" ) > /dev/null 2>&1 &    # the time limit
            dog=$!
            wait "$pid"; rc=$?
            kill "$dog" 2>/dev/null; wait "$dog" 2>/dev/null
        fi
        if (( rc == 143 )); then                     # stopped by the time limit
            if _du_scan_split "$work" "$k" "$depth" "$path"; then
                printf '%s\n' "$path" >> "$work/fin"
                return 0
            fi
            du -k -d "$levels" "$path" > "$tmp" 2>/dev/null      # cannot be split: run to the end
        fi
    else
        du -k -d "$levels" "$path" > "$tmp" 2>/dev/null
    fi

    if (( levels == 0 )); then
        kb=''; IFS=$'\t' read -r kb _ < "$tmp"
        printf '%d\t%s\n' "${kb:-0}" "$path" >> "$work/out/w$k"
        printf '%d\t%s' "${kb:-0}" "$path" > "$work/latest"
    else
        # du lists the sub-folders, then PATH with everything in it. Results
        # are "KB that belongs to this path alone", so PATH keeps only what
        # its sub-folders do not already account for (its own files).
        awk -F'\t' -v self="$path" -v latest="$work/latest" '
            $2 == self { total = $1; next }
            { print; sum += $1 }
            END { printf "%d\t%s\n", (total > sum ? total - sum : 0), self
                  printf "%d\t%s", total, self > latest }' "$tmp" >> "$work/out/w$k"
    fi
    printf '%s\n' "$path" >> "$work/fin"
}

# =============================================================================
# § _du_scan_worker WORK WORKER
#
#   One worker of the pool: takes the next unclaimed job from the queue until
#   the scan is finished or stopped.
#
#   No lock is needed. The worker reads the queue through its own file handle;
#   it claims line N by creating claim/N, which fails if another worker was
#   first. The scan is finished when the worker has caught up with the queue
#   and every queued job is finished - a job adds its sub-folder jobs to the
#   queue before it reports itself finished, so "all finished" cannot be true
#   while more work is on its way.
# =============================================================================
_du_scan_worker() {
    local work=$1 k=$2 depth path
    local -i line=0 finished=0
    exec 7< "$work/queue" 8< "$work/fin"
    while [[ ! -e $work/stop ]]; do
        if ! IFS=$'\t' read -r depth path <&7; then
            # Caught up with the queue. Count what has finished, then look
            # once more: only if nothing new was queued can the scan be over.
            while IFS= read -r _ <&8; do (( finished++ )); done
            if ! IFS=$'\t' read -r depth path <&7; then
                (( finished == line )) && break
                sleep 0.1
                continue
            fi
        fi
        (( line++ ))
        # noclobber turns the redirection into an atomic "create if absent":
        # it fails when another worker has already claimed this line.
        set -C
        # shellcheck disable=SC2188  # a bare redirection: no builtin that could abort the shell
        if { > "$work/claim/$line"; } 2>/dev/null; then
            set +C
            _du_scan_job "$work" "$k" "$depth" "$path"
        fi
        set +C
    done
    exec 7<&- 8<&-
}

# =============================================================================
# § du_scan_start ROOT WORK
#
#   Starts measuring ROOT in the background and returns at once.
#
#   Arguments:
#     ROOT  the folder to measure
#     WORK  an empty folder for the scan's working files
#   Globals:
#     reads  DM_JOBS, DU_SPLIT_SECS, DU_SPLIT_DEPTH
#     writes DU_SCAN_PIDS
# =============================================================================
du_scan_start() {
    local root=${1%/} work=$2 d
    local -i jobs k

    _DU_SECS=${DU_SPLIT_SECS:-1};   [[ $_DU_SECS  =~ ^[0-9]+$ ]] || _DU_SECS=1
    _DU_DEPTH=${DU_SPLIT_DEPTH:-6}; [[ $_DU_DEPTH =~ ^[0-9]+$ ]] || _DU_DEPTH=6

    mkdir -p "$work/out" "$work/claim"
    : > "$work/queue"; : > "$work/fin"; : > "$work/out/w0"
    rm -f "$work/stop" "$work/latest"

    # The known-heavy folders are split straight away and go first.
    : > "$work/queue.rest"
    for d in "$root"/* "$root"/.[!.]* "$root"/..?*; do
        [[ -d $d && ! -L $d ]] || continue            # real folders only
        if [[ ${d##*/} =~ $DU_PRESPLIT_RE ]] && _du_scan_split "$work" 0 1 "$d"; then
            continue
        fi
        printf '1\t%s\n' "$d" >> "$work/queue.rest"
    done
    cat "$work/queue.rest" >> "$work/queue"; rm -f "$work/queue.rest"

    jobs=0; [[ ${DM_JOBS:-} =~ ^[0-9]+$ ]] && jobs=$DM_JOBS
    (( jobs >= 1 )) || jobs=$(sysctl -n hw.ncpu 2>/dev/null || echo 4)
    (( jobs > 16 )) && jobs=16
    (( jobs < 1 )) && jobs=1

    DU_SCAN_PIDS=()
    for (( k=1; k<=jobs; k++ )); do
        : > "$work/out/w$k"
        _du_scan_worker "$work" "$k" 2>/dev/null &
        DU_SCAN_PIDS+=($!)
    done
}

# =============================================================================
# § du_scan_running
#
#   Returns:
#     0 while at least one worker of the last du_scan_start is alive
# =============================================================================
du_scan_running() {
    local pid
    for pid in ${DU_SCAN_PIDS[@]+"${DU_SCAN_PIDS[@]}"}; do
        kill -0 "$pid" 2>/dev/null && return 0
    done
    return 1
}

# =============================================================================
# § du_scan_progress WORK
#
#   Globals:
#     writes DU_SCAN_DONE    jobs finished
#     writes DU_SCAN_TOTAL   jobs known so far (grows while folders are split)
#     writes DU_SCAN_LATEST  "KB<TAB>PATH" of the newest result ('' if none)
# =============================================================================
# shellcheck disable=SC2034  # DU_SCAN_* are the result, read by the callers
du_scan_progress() {
    local work=$1 a='' b='' counts
    # Polled ten times a second: a command substitution and a here-string,
    # never a process substitution (see lib/core.sh).
    counts=$(wc -l "$work/fin" "$work/queue" 2>/dev/null)
    { read -r a _; read -r b _; } <<< "$counts"
    [[ $a =~ ^[0-9]+$ ]] && DU_SCAN_DONE=$a
    [[ $b =~ ^[0-9]+$ ]] && DU_SCAN_TOTAL=$b
    DU_SCAN_LATEST=''
    [[ -s $work/latest ]] && IFS= read -r DU_SCAN_LATEST < "$work/latest"
    return 0
}

# =============================================================================
# § du_scan_stop WORK
#
#   Stops the workers of WORK and whatever they started. What was measured so
#   far stays available to du_scan_merge.
# =============================================================================
du_scan_stop() {
    local pid
    : > "$1/stop"
    for pid in ${DU_SCAN_PIDS[@]+"${DU_SCAN_PIDS[@]}"}; do
        kill -0 "$pid" 2>/dev/null && kill_tree "$pid"
    done
    wait ${DU_SCAN_PIDS[@]+"${DU_SCAN_PIDS[@]}"} 2>/dev/null
    DU_SCAN_PIDS=()
}

# =============================================================================
# § du_scan_merge ROOT WORK [FILES_KB]
#
#   Adds the results up into a du-style listing. Works at any moment: during
#   the scan it gives the sizes known so far.
#
#   Arguments:
#     ROOT      the folder that was scanned
#     WORK      its working folder
#     FILES_KB  KB of the files directly inside ROOT, added to ROOT's total
#               (default 0)
#   Outputs:
#     "KB<TAB>PATH<TAB>LIVE" for ROOT's folders and their sub-folders, then a
#     last line for ROOT itself. LIVE is 1 for a folder of ROOT that still has
#     unfinished jobs - its size is still growing.
# =============================================================================
du_scan_merge() {
    local root=${1%/} work=$2
    awk -F'\t' -v root="$root" -v fileskb="${3:-0}" -v qf="$work/queue" -v ff="$work/fin" '
        # the folder of ROOT that path p lies in
        function top(p,   r, i) {
            r = substr(p, length(root) + 2); i = index(r, "/")
            return root "/" (i ? substr(r, 1, i - 1) : r)
        }
        BEGIN {
            while ((getline line < qf) > 0) { sub(/^[0-9]+\t/, "", line); QUEUED[top(line)]++ }
            close(qf)
            while ((getline line < ff) > 0) FINISHED[top(line)]++
            close(ff)
        }
        index($2, root "/") == 1 {
            kb = $1 + 0
            n = split(substr($2, length(root) + 2), seg, "/")
            t = root "/" seg[1]
            OUT[t] += kb; total += kb
            if (n >= 2) OUT[t "/" seg[2]] += kb
        }
        END {
            for (p in OUT) printf "%d\t%s\t%d\n", OUT[p], p, (QUEUED[p] > FINISHED[p])
            printf "%d\t%s\t0\n", total + fileskb, root
        }' "$work"/out/w* /dev/null
}
