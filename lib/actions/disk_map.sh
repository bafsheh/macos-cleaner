#!/usr/bin/env bash
# =============================================================================
# § lib/actions/disk_map.sh  ·  Interactive disk map + cleanup recommendations
#
#   run_disk_map - a colour treemap of your home folder drawn in the terminal,
#   sized by space used, two levels deep, plus a "what's safe to remove" panel:
#
#     ┌ header ─ Free after cleanup · Safe to remove · Needs review · Not scanned
#     │ treemap  one tile per folder, biggest subfolders nested inside
#     │          colour = category (code, documents, SDKs, AI models, caches)
#     │          green hatch = safe to remove (or press v for the cleanup view)
#     └ keys     1-9 open a tile · o open any · u up · v view · r recommendations
#
#   Recommendations list each known space hog with its size; safe ones start
#   ticked. Cleaning runs the same guarded helpers as the main cleanup, and
#   the destructive ones (Ollama, Docker) still ask for their own confirmation.
#
#   Live, parallel scanning: the map opens empty straight away while a pool of
#   background `du` workers (DM_JOBS, default = CPU count, max 8) measures the
#   folders. Once a second the map is redrawn from whatever is known so far -
#   folders still being measured show a "~" estimate - and the status line
#   shows the last folder found. The recommendations are measured in parallel
#   too. Press q to stop a scan early.
#
#   Scans are cached for the session, so opening a folder and coming back is
#   instant. Layout/rendering lives in lib/diskmap.awk.
#
#   Requires (sourced earlier): colors.sh, core.sh, logging.sh, helpers.sh,
#                               ui.sh, actions/temp_clean.sh,
#                               actions/docker_clean.sh, actions/ollama_clean.sh
#   Public entry: run_disk_map
# =============================================================================

DM_DIR=''               # per-session scratch dir (du results, node lists)
DM_VIEW=category        # category | cleanup
DM_TTY=0                # 1 when we can draw frames and read keys
DM_ROOT_KB=0            # size of the folder currently shown
DM_HOME_KB=0            # size of $HOME, once scanned
DM_TILE_PATHS=()        # tile number (1-9) → folder path
DM_OPEN_PATHS=()        # every openable top-level folder, largest first
DM_OPEN_LABELS=()
DM_WORKER_PIDS=()       # running scan workers
DM_LAST_DU=''           # du listing of an interrupted scan (not cached)
DM_COLS=100; DM_LINES=32

# Recommendation rows (parallel arrays, filled by _dm_recs_load once the
# background measurement started by _dm_recs_start has finished).
REC_KEY=(); REC_STATUS=(); REC_KB=(); REC_LABEL=(); REC_SHOW=()
DM_RECS_READY=0
DM_RECS_PID=''

# =============================================================================
# § size formatting  (same rules as diskmap.awk: "41.7 GB", "640 MB")
# =============================================================================
_dm_fmt() {
    awk -v k="$1" 'BEGIN {
        if (k < 0)               print "?"
        else if (k >= 104857600) printf "%.0f GB\n", k / 1048576
        else if (k >= 1048576)   printf "%.1f GB\n", k / 1048576
        else if (k >= 1024)      printf "%.0f MB\n", k / 1024
        else                     printf "%d KB\n", k }'
}

# Shorten a path for display: /Users/me/Desktop → ~/Desktop
_dm_tilde() { local p=$1; [[ $p == "$HOME"* ]] && p="~${p#"$HOME"}"; printf '%s' "$p"; }

# =============================================================================
# § classification  (path → colour category · cleanup status)
#
#   Both set REPLY instead of printing, so the per-node loop needs no subshells.
# =============================================================================
_dm_path_cat() {
    case $1 in
        */.ollama|*/.ollama/*|*/.lmstudio|*/.lmstudio/*|*/.cache/huggingface|*/.cache/huggingface/*|\
        */.cache/lm-studio*|*/.llama|*/.llama/*|*"/Application Support/LM Studio"*|*/.cache/whisper*)
            REPLY=ai ;;
        */Library/Android|*/Library/Android/*|*/.android|*/.android/*|\
        */Library/Developer|*/Library/Developer/*|*/Xcode*.app)
            REPLY=sdk ;;
        */.npm|*/.npm/*|*/.gradle|*/.gradle/*|*/.cache|*/.cache/*|*/.cargo|*/.cargo/*|*/.rustup|*/.rustup/*|\
        */.m2|*/.m2/*|*/.pnpm-store|*/.pnpm-store/*|*/Library/pnpm|*/Library/pnpm/*|*/.bun|*/.bun/*|\
        */.yarn|*/.yarn/*|*/go/pkg|*/go/pkg/*|*/.nvm|*/.nvm/*|*/.pyenv|*/.pyenv/*|*/.conda|*/.conda/*|\
        */miniconda3|*/anaconda3|*/miniforge3|*/Library/Caches|*/Library/Caches/*|*/.pub-cache|\
        */.gem|*/.gem/*|*/.composer|*/.composer/*|*/.ivy2|*/.sbt|*/.volta|*/.volta/*|*/.deno|\
        */.nuget|*/.konan|*/.cocoapods|*/node_modules|*/node_modules/*)
            REPLY=pkg ;;
        */Documents|*/Documents/*|*/Downloads|*/Downloads/*|*/Pictures|*/Pictures/*|*/Movies|*/Movies/*|\
        */Music|*/Music/*|*"/Mobile Documents"|*"/Mobile Documents/"*|*.photoslibrary)
            REPLY=docs ;;
        "$HOME"/[Pp]rojects|"$HOME"/[Pp]rojects/*|"$HOME"/Developer|"$HOME"/Developer/*|\
        "$HOME"/[Cc]ode|"$HOME"/[Cc]ode/*|"$HOME"/[Dd]ev|"$HOME"/[Dd]ev/*|"$HOME"/[Rr]epos|"$HOME"/[Rr]epos/*|\
        "$HOME"/src|"$HOME"/src/*|"$HOME"/[Ww]orkspace|"$HOME"/[Ww]orkspace/*|"$HOME"/Sites|"$HOME"/Sites/*)
            REPLY=code ;;
        *)  REPLY='' ;;
    esac
}

_dm_status() {
    case $1 in
        */.Trash|*/.npm|*/.npm/*|*/Library/Caches|*/Library/Caches/*|*/Library/Logs|\
        */.gradle/caches|*/.gradle/wrapper|*/.gradle/daemon|*/DerivedData|*/DerivedData/*|\
        *DeviceSupport|*/CoreSimulator/Caches|*/.cache/uv|*/.cache/pip|*/.cache/puppeteer|\
        */.cache/chrome-devtools-mcp|*/.cache/selenium|*/.cache/node-gyp|*/.cache/yarn|\
        */.cache/pypoetry|*/.cache/pre-commit|*/.cache/turbo|*/.cache/Cypress|*/.cache/go-build|\
        */.cache/mesa_shader_cache|*/.yarn/cache|*/.pnpm-store|*/Library/pnpm|*/.bun/install|\
        */.cargo/registry|*/.cargo/git|*/.next|*/.turbo|*/.parcel-cache|*/__pycache__|\
        */.pytest_cache|*/.mypy_cache|*/.ruff_cache)
            REPLY=safe ;;
        */.ollama|*/.ollama/*|*/.android|*/.android/avd|*/Library/Android|*/Library/Android/sdk|\
        */CoreSimulator|*/CoreSimulator/Devices|*/Xcode/Archives|*/.cache/huggingface|\
        */.lmstudio|*/.lmstudio/*|*/com.docker.docker|*/.colima|*/.colima/*|*/.lima|*/.orbstack|\
        */node_modules|*/.claude/worktrees|\
        */.claude/worktrees/*|*/MobileSync|*/MobileSync/*|*"/Install macOS"*.app|*/.m2/repository|*/go/pkg/mod)
            REPLY=review ;;
        *)  REPLY='-' ;;
    esac
}

# A folder is a code project if it is a git repo or has a build manifest.
_dm_is_code() {
    local p=$1 f
    [[ -e $p/.git ]] && return 0
    for f in package.json Cargo.toml go.mod pyproject.toml composer.json Package.swift \
             pom.xml build.gradle build.gradle.kts Gemfile; do
        [[ -f $p/$f ]] && return 0
    done
    return 1
}

_dm_cat_idx() {
    case $1 in code) REPLY=0 ;; docs) REPLY=1 ;; ai) REPLY=2 ;; sdk) REPLY=3 ;; pkg) REPLY=4 ;; *) REPLY=5 ;; esac
}
DM_CATS=(code docs ai sdk pkg other)

# =============================================================================
# § scanning
# =============================================================================
_dm_cache_file() { printf '%s/du_%s' "$DM_DIR" "$(printf '%s' "$1" | cksum | awk '{print $1}')"; }

# =============================================================================
# § parallel scanner
#
#   WORK/queue holds one job per line, "D<TAB>folder" or "S<TAB>folder":
#     D  a folder of the root - `du -d 2` gives it and its sub-folders
#     S  a sub-folder of a big folder that was split up (~/Library, ~/Desktop,
#        ~/Projects …) so many workers share it - `du -d 1` gives just it.
#        The split folder's own total is rebuilt from its pieces (_dm_merge).
#   Each worker claims the next line number from WORK/next (guarded by an
#   atomic mkdir lock - bash 3.2 has no `wait -n`, so this is the job queue),
#   writes du's output to out/N.<d|s>.part, and renames it to .done when the
#   folder is finished. du prints each folder as soon as it completes, so a
#   .part file is a growing, always-valid list of finished sub-folders.
# =============================================================================
_dm_worker() {   # WORK TOTAL
    local work=$1 kind item
    local -i total=$2 i
    while [[ ! -e $work/stop ]]; do
        until mkdir "$work/lock" 2>/dev/null; do sleep 0.05; done
        i=$(< "$work/next")
        echo $(( i + 1 )) > "$work/next"
        rmdir "$work/lock"
        (( i >= total )) && break
        IFS=$'\t' read -r kind item < <(sed -n "$(( i + 1 ))p" "$work/queue")
        if [[ $kind == S ]]; then
            du -k -d 1 "$item" 2>/dev/null > "$work/out/$i.s.part"
            mv "$work/out/$i.s.part" "$work/out/$i.s.done"
        else
            du -k -d 2 "$item" 2>/dev/null > "$work/out/$i.d.part"
            mv "$work/out/$i.d.part" "$work/out/$i.d.done"
        fi
    done
}

# Folder names worth splitting into per-sub-folder jobs: usually the biggest,
# deepest trees in a home folder.
DM_SPLIT_RE='^(Library|Desktop|Documents|Developer|[Pp]rojects|[Cc]ode|[Dd]ev|[Rr]epos|src|[Ww]orkspace)$'

# Writes WORK/queue (split jobs first - they belong to the heaviest folders)
# and WORK/split: "folder<TAB>loose-files-kb<TAB>job count<TAB>first job" per
# split folder - its jobs are the consecutive queue lines from "first job".
_dm_make_queue() {   # ROOT WORK
    local root=$1 work=$2 d c
    local -i n first=0
    : > "$work/split"; : > "$work/q.s"; : > "$work/q.d"
    while IFS= read -r d; do
        if [[ ${d##*/} =~ $DM_SPLIT_RE ]]; then
            n=0
            while IFS= read -r c; do printf 'S\t%s\n' "$c" >> "$work/q.s"; (( n++ )); done \
                < <(find "$d" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
            if (( n > 0 )); then
                printf '%s\t%s\t%d\t%d\n' "$d" "$(_dm_loose_kb "$d")" "$n" "$first" >> "$work/split"
                (( first += n ))
                continue
            fi
        fi
        printf 'D\t%s\n' "$d" >> "$work/q.d"
    done < <(find "$root" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
    cat "$work/q.s" "$work/q.d" > "$work/queue"
}

# KB used by the files (not folders) directly inside DIR.
_dm_loose_kb() {
    find "$1" -mindepth 1 -maxdepth 1 ! -type d -exec du -sk {} + 2>/dev/null \
        | awk '{ s += $1 } END { print s + 0 }'
}

# Kill PID and everything it started. The parent is frozen first so it can't
# launch a new child while we walk the tree.
_dm_kill_tree() {
    local pid=$1 kids c
    kids=$(pgrep -P "$pid" 2>/dev/null)
    kill -STOP "$pid" 2>/dev/null
    for c in $kids; do _dm_kill_tree "$c"; done
    kill -TERM "$pid" 2>/dev/null
    kill -CONT "$pid" 2>/dev/null
}

_dm_stop_all() {
    local pid
    [[ -n $DM_DIR ]] && touch "$DM_DIR"/scan.*/stop 2>/dev/null
    for pid in ${DM_WORKER_PIDS[@]+"${DM_WORKER_PIDS[@]}"} ${DM_RECS_PID:-}; do
        kill -0 "$pid" 2>/dev/null && _dm_kill_tree "$pid"
    done
    DM_WORKER_PIDS=()
}

# Merges finished and in-progress worker output into one du-style listing
# (kb TAB path TAB live) of ROOT, its folders, and their sub-folders.
#   finished folder     → exact sizes from its own du lines
#   folder in progress  → estimated from the sub-folders finished so far;
#                         live=1 so the map can mark it "~"
#   split folder        → sum of its pieces + its loose files (WORK/split);
#                         live until every piece's job is .done (counted by
#                         file, since a privacy-blocked piece prints nothing)
#   ROOT                → sum of all folders + FILES_KB of loose files
# Files are read with getline, which shrugs off a .part renamed to .done
# mid-read (it then reads the .done instead) instead of aborting like a
# missing command-line file would.
_dm_merge() {   # ROOT WORK FILES_KB
    local f
    for f in "$2"/out/*.done "$2"/out/*.part; do [[ -e $f ]] && printf '%s\n' "$f"; done |
    awk -v root="$1" -v fileskb="$3" -v splitf="$2/split" '
        function rel(p) { return substr(p, length(root) + 2) }
        function load(f, live,   line, r, n, s, a, kb, p, sp, par, j, t) {
            r = (getline line < f)
            if (r < 0 && live) { f = substr(f, 1, length(f) - 5) ".done"; live = 0; r = (getline line < f) }
            sp = (f ~ /\.s\.(part|done)$/)
            if (sp && !live) {                             # count finished pieces by job number
                j = f; sub(/.*\//, "", j); j = j + 0
                for (t in SPN) if (j >= SPFIRST[t] && j < SPFIRST[t] + SPN[t]) SPFIN[t]++
            }
            while (r > 0) {
                split(line, a, "\t"); kb = a[1] + 0; p = a[2]
                if (index(p, root "/") == 1) {
                    n = split(rel(p), s, "/")
                    if (sp) {                              # piece of a split folder
                        par = root "/" s[1]
                        if (n == 2)            { OUT[p] = kb; SPSUM[par] += kb }
                        else if (n == 3 && live) SPK[root "/" s[1] "/" s[2]] += kb
                    }
                    else if (live && n <= 3)  { P[p] = kb; PD[p] = n }
                    else if (!live && n <= 2) { OUT[p] = kb; if (n == 1) tot += kb }
                }
                r = (getline line < f)
            }
            close(f)
        }
        BEGIN {
            while ((getline line < splitf) > 0) { split(line, a, "\t"); SPLOOSE[a[1]] = a[2] + 0; SPN[a[1]] = a[3] + 0; SPFIRST[a[1]] = a[4] + 0 }
            close(splitf)
        }
        { load($0, $0 ~ /\.part$/) }
        END {
            for (m in SPK) if (!(m in OUT)) {              # split pieces still in progress
                split(rel(m), s, "/"); OUT[m] = SPK[m]; SPSUM[root "/" s[1]] += SPK[m]
            }
            for (t in SPN) {
                OUT[t] = SPSUM[t] + SPLOOSE[t]; tot += OUT[t]
                if (SPFIN[t] < SPN[t]) LIVE[t] = 1
            }
            for (p in P) {
                n = PD[p]; split(rel(p), s, "/"); t = root "/" s[1]
                if (n == 1) { FIN[t] = P[p]; continue }      # finished, not renamed yet
                m = t "/" s[2]; TOPS[t] = 1
                if (n == 2)        MK[m] = P[p]
                else if (!(m in P)) MK[m] += P[p]
            }
            for (t in FIN) { OUT[t] = FIN[t]; tot += FIN[t] }
            for (m in MK) {
                split(rel(m), s, "/"); t = root "/" s[1]
                if (t in FIN) { if (m in P) OUT[m] = P[m]; continue }
                OUT[m] = MK[m]; EST[t] += MK[m]
            }
            for (t in TOPS) if (!(t in FIN)) { LIVE[t] = 1; OUT[t] = EST[t] + 0; tot += EST[t] }
            for (p in OUT) printf "%d\t%s\t%d\n", OUT[p], p, (p in LIVE)
            printf "%d\t%s\t0\n", tot + fileskb, root
        }'
}

# Scans ROOT with the worker pool, redrawing the map once a second (TTY only).
# Writes the finished listing to CACHE and returns 0; if the user stops the
# scan with q, leaves the partial listing in DM_LAST_DU and returns 1.
_dm_scan_live() {   # ROOT CACHE
    local root=$1 cache=$2 work
    work=$(mktemp -d "$DM_DIR/scan.XXXXXX") || return 1
    mkdir "$work/out"

    _dm_make_queue "$root" "$work"
    echo 0 > "$work/next"

    local -i total jobs files_kb k
    total=$(wc -l < "$work/queue" | tr -d ' ')
    files_kb=$(_dm_loose_kb "$root")
    jobs=${DM_JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 4)}
    (( jobs > 8 )) && jobs=8
    (( jobs > total )) && jobs=total
    (( jobs < 1 )) && jobs=1

    DM_WORKER_PIDS=()
    for (( k=0; k<jobs; k++ )); do
        _dm_worker "$work" "$total" &
        DM_WORKER_PIDS+=($!)
    done

    local spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏' key latest newest status pid
    local -i t0 alive finished frame=0 stopped=0 lkb
    t0=$(date +%s)
    while :; do
        alive=0
        for pid in "${DM_WORKER_PIDS[@]}"; do kill -0 "$pid" 2>/dev/null && { alive=1; break; }; done
        # Loose files join only in the final listing: on their own they would
        # fill the whole map before the first folder arrives.
        _dm_merge "$root" "$work" 0 > "$work/merged"

        if (( DM_TTY )); then
            _dm_recs_poll
            _dm_build "$root" "$work/merged"
            finished=$(find "$work/out" -name '*.done' | wc -l | tr -d ' ')
            # the last line of the newest non-empty result = the latest folder found
            latest=''
            for newest in $(ls -t "$work/out" 2>/dev/null | head -8); do
                IFS=$'\t' read -r lkb latest < <(tail -n 1 "$work/out/$newest" 2>/dev/null)
                [[ -n $latest ]] && break
            done
            if [[ -n $latest ]]; then
                latest=$(_dm_tilde "$latest")
                _dm_term_size
                # keep the whole status line within the window (~70 cols of other text)
                (( ${#latest} > DM_COLS - 72 && DM_COLS > 90 )) && latest="…${latest: -$(( DM_COLS - 73 ))}"
                latest="  ·  ${YLW}${latest}${NC}  $(_dm_fmt "$lkb")"
            fi
            status=$(printf '%s %s Scanning  %d/%d jobs · %d workers · %ds%s%s' \
                "$BCYN" "${spin:frame%10:1}${NC}" "$finished" "$total" "$jobs" \
                "$(( $(date +%s) - t0 ))" "$latest" "  ${DIM}(q stop · v view)${NC}")
            _dm_draw "$root" "$status"
        fi

        (( alive )) || break
        if (( DM_TTY )); then
            if IFS= read -rsn1 -t 1 key; then
                case $key in
                    q|Q) stopped=1; break ;;
                    v|V) [[ $DM_VIEW == category ]] && DM_VIEW=cleanup || DM_VIEW=category ;;
                esac
            fi
        else
            sleep 1
        fi
        (( frame++ ))
    done

    if (( stopped )); then
        _dm_stop_all
        _dm_merge "$root" "$work" "$files_kb" > "$work/merged"
        DM_LAST_DU="$work/merged"
        return 1
    fi
    DM_WORKER_PIDS=()
    _dm_merge "$root" "$work" "$files_kb" > "$cache"
    rm -rf "$work"
    return 0
}

# Picks the tiles to draw from a du listing: up to 14 top-level folders (the
# rest merged into "N more"), up to 8 children each, plus loose files.
# Input may carry a 3rd "live" column (folder still being scanned).
# Output TSV: kind id parent kb path label live   (path "-" for merged tiles)
_dm_prepare() {
    sort -t "$(printf '\t')" -k1,1nr "$2" | awk -F'\t' -v root="$1" -v maxtop=14 -v maxkid=8 '
        function clean(s) { gsub(/[^ -~]+/, "?", s); gsub(/\t/, " ", s); return s }
        function add(lst, kb, path, label, live) {
            n = ++CNT[lst]; AK[lst, n] = kb; AP[lst, n] = path; AL[lst, n] = label; AV[lst, n] = live + 0
        }
        function sortlst(lst,   i, j, t1, t2, t3, t4) {      # insertion sort, largest first
            for (i = 2; i <= CNT[lst]; i++)
                for (j = i; j > 1 && AK[lst, j] > AK[lst, j - 1]; j--) {
                    t1 = AK[lst, j]; AK[lst, j] = AK[lst, j - 1]; AK[lst, j - 1] = t1
                    t2 = AP[lst, j]; AP[lst, j] = AP[lst, j - 1]; AP[lst, j - 1] = t2
                    t3 = AL[lst, j]; AL[lst, j] = AL[lst, j - 1]; AL[lst, j - 1] = t3
                    t4 = AV[lst, j]; AV[lst, j] = AV[lst, j - 1]; AV[lst, j - 1] = t4
                }
        }
        {
            kb = $1 + 0; p = $2
            if (p == root) { rootkb = kb; next }
            if (index(p, root "/") != 1) next
            rel = substr(p, length(root) + 2)
            n = split(rel, seg, "/")
            if (n == 1)      { T[++nt] = rel; TK[rel] = kb; TL[rel] = ($3 == "1"); sum += kb }
            else if (n == 2) { c = ++NC[seg[1]]; C[seg[1], c] = seg[2]; CK[seg[1], c] = kb }
        }
        END {
            hidden = 0; hiddenkb = 0
            for (i = 1; i <= nt; i++) {
                r = T[i]
                if (CNT["top"] < maxtop && TK[r] > 0 && TK[r] >= rootkb * 0.004) add("top", TK[r], root "/" r, clean(r), TL[r])
                else { hidden++; hiddenkb += TK[r] }
            }
            files = rootkb - sum
            if (hiddenkb > 0 && hiddenkb >= rootkb * 0.004) add("top", hiddenkb, "-", hidden " more")
            if (files > 0 && files >= rootkb * 0.004)       add("top", files, "-", "files")
            sortlst("top")
            id = 0
            for (i = 1; i <= CNT["top"]; i++) {
                pid = ++id
                printf "1\t%d\t0\t%d\t%s\t%s\t%d\n", pid, AK["top", i], AP["top", i], AL["top", i], AV["top", i]
                if (AP["top", i] == "-") continue
                r = substr(AP["top", i], length(root) + 2); K = AK["top", i]
                lst = "k" pid; csum = 0; ch = 0
                for (j = 1; j <= NC[r]; j++) {
                    if (CNT[lst] < maxkid && CK[r, j] > 0 && CK[r, j] >= K * 0.02) {
                        add(lst, CK[r, j], root "/" r "/" C[r, j], clean(C[r, j])); csum += CK[r, j]
                    } else ch++
                }
                rest = K - csum
                if (CNT[lst] > 0 && rest > 0 && rest >= K * 0.03) add(lst, rest, "-", ch > 0 ? ch " more" : "files")
                sortlst(lst)
                for (j = 1; j <= CNT[lst]; j++)
                    printf "2\t%d\t%d\t%d\t%s\t%s\t0\n", ++id, pid, AK[lst, j], AP[lst, j], AL[lst, j]
            }
            printf "0\t0\t0\t%d\t-\t-\t0\n", rootkb
        }'
}

# Makes sure ROOT has been measured (cached per session; a new scan runs
# live, see _dm_scan_live) and builds the tiles for it.
_dm_scan() {
    local root=$1 cache src
    cache=$(_dm_cache_file "$root"); src=$cache
    if [[ ! -s $cache ]]; then
        _dm_scan_live "$root" "$cache" || src=$DM_LAST_DU
    fi
    _dm_build "$root" "$src"
}

# Classifies every tile of a du listing of ROOT and writes $DM_DIR/render.tsv.
_dm_build() {   # ROOT DU_LISTING
    local root=$1 listing=$2
    local -a kind=() id=() par=() kb=() path=() label=() live=() cat=() st=()
    local k i p l pa b lv
    local -i n=0
    DM_ROOT_KB=0
    while IFS=$'\t' read -r k i pa b p l lv; do
        if [[ $k == 0 ]]; then DM_ROOT_KB=$b; continue; fi
        kind[n]=$k; id[n]=$i; par[n]=$pa; kb[n]=$b; path[n]=$p; label[n]=$l; live[n]=${lv:-0}
        (( n++ ))
    done < <(_dm_prepare "$root" "$listing")
    [[ $root == "$HOME" ]] && DM_HOME_KB=$DM_ROOT_KB

    # Pass 1 - children and top tiles: category from the path, or "code" for
    # repos; per-parent category totals feed the majority vote in pass 2.
    local -a tally=()
    local -i j ci
    for (( j=0; j<n; j++ )); do
        cat[j]=''; st[j]='-'
        [[ ${path[j]} == - ]] && continue
        _dm_path_cat "${path[j]}"; cat[j]=$REPLY
        if [[ -z ${cat[j]} || ${cat[j]} == docs ]] && _dm_is_code "${path[j]}"; then cat[j]=code; fi
        _dm_status "${path[j]}"; st[j]=$REPLY
        if [[ ${kind[j]} == 2 && -n ${cat[j]} ]]; then
            _dm_cat_idx "${cat[j]}"; ci=$(( par[j] * 8 + REPLY ))
            tally[ci]=$(( ${tally[ci]:-0} + kb[j] ))
        fi
    done

    # Pass 2 - top tiles without a category take their children's majority
    # (≥ 50% of the size), e.g. ~/Desktop full of repos becomes "code".
    local -a top_cat=()
    local -i best bestv c v
    for (( j=0; j<n; j++ )); do
        [[ ${kind[j]} == 1 ]] || continue
        if [[ -z ${cat[j]} ]]; then
            best=-1; bestv=0
            for (( c=0; c<6; c++ )); do
                v=${tally[id[j] * 8 + c]:-0}
                (( v > bestv )) && { bestv=$v; best=$c; }
            done
            if (( best >= 0 && bestv * 2 >= kb[j] )); then cat[j]=${DM_CATS[best]}
            elif [[ ${path[j]##*/} == Desktop ]];      then cat[j]=docs
            else                                            cat[j]=other
            fi
        fi
        top_cat[id[j]]=${cat[j]}
    done

    # Pass 3 - children inherit an unknown category from their parent; number
    # the first nine real folders so they can be opened with keys 1-9.
    DM_TILE_PATHS=(); DM_OPEN_PATHS=(); DM_OPEN_LABELS=()
    local -i num=0
    local shown
    : > "$DM_DIR/render.tsv"
    for (( j=0; j<n; j++ )); do
        [[ -z ${cat[j]} ]] && cat[j]=${top_cat[par[j]]:-other}
        shown='-'
        if [[ ${kind[j]} == 1 && ${path[j]} != - && -d ${path[j]} ]]; then
            DM_OPEN_PATHS+=("${path[j]}")
            DM_OPEN_LABELS+=("$(printf '%-34s %9s' "${label[j]}" "$(_dm_fmt "${kb[j]}")")")
            if (( num < 9 )); then (( num++ )); shown=$num; DM_TILE_PATHS[num]=${path[j]}; fi
        fi
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "${kind[j]}" "${id[j]}" "${par[j]}" "${kb[j]}" \
            "${cat[j]}" "${st[j]}" "${label[j]}" "$shown" "${live[j]}" >> "$DM_DIR/render.tsv"
    done
}

# =============================================================================
# § recommendations  (what's worth removing, measured once per session)
#
#   _dm_rec_paths KEY prints the folders behind a recommendation - the single
#   source of truth for both measuring and cleaning it.
# =============================================================================
_dm_rec_paths() {
    local p
    case $1 in
        trash)     printf '%s\n' "$HOME/.Trash" ;;
        npm)       printf '%s\n' "$HOME/.npm/_cacache" "$HOME/.npm/_npx" "$HOME/.npm/_logs" ;;
        jscache)   printf '%s\n' "$HOME/.cache/yarn" "$HOME/.yarn/cache" "$HOME/Library/pnpm/store" \
                                 "$HOME/.pnpm-store" "$HOME/.bun/install/cache" ;;
        gradle)    printf '%s\n' "$HOME/.gradle/caches" "$HOME/.gradle/wrapper/dists" "$HOME/.gradle/daemon" ;;
        xcode)     printf '%s\n' "$HOME/Library/Developer/Xcode/DerivedData" \
                                 "$HOME/Library/Developer/CoreSimulator/Caches" \
                                 "$HOME/Library/Developer/Xcode/UserData/Previews"
                   for p in "$HOME/Library/Developer/Xcode/"*DeviceSupport; do
                       [[ -d $p ]] && printf '%s\n' "$p"
                   done ;;
        tools)     for p in uv pip puppeteer chrome-devtools-mcp selenium node-gyp pypoetry pre-commit turbo Cypress; do
                       printf '%s\n' "$HOME/.cache/$p"
                   done ;;
        cargo)     printf '%s\n' "$HOME/.cargo/registry" "$HOME/.cargo/git" ;;
        appcache)  printf '%s\n' "$HOME/Library/Caches" ;;
        android)   printf '%s\n' "$HOME/Library/Android/sdk" "$HOME/.android/avd" ;;
        sims)      printf '%s\n' "$HOME/Library/Developer/CoreSimulator/Devices" ;;
        archives)  printf '%s\n' "$HOME/Library/Developer/Xcode/Archives" ;;
        ollama)    printf '%s\n' "$HOME/.ollama/models" ;;
        aimodels)  printf '%s\n' "$HOME/.cache/huggingface" "$HOME/.lmstudio/models" "$HOME/.cache/lm-studio" ;;
        docker)    printf '%s\n' "$HOME/Library/Containers/com.docker.docker/Data/vms" ;;
        temp|jsbuild|nodemods|worktrees|installers)
                   [[ -f $DM_DIR/list_$1 ]] && cat "$DM_DIR/list_$1" ;;
    esac
}

# Sum of du -sk over newline-separated paths on stdin (missing ones count 0).
_dm_sum_kb() {
    local p
    local -a found=()
    while IFS= read -r p; do [[ -n $p && -e $p ]] && found+=("$p"); done
    if (( ${#found[@]} == 0 )); then echo 0; return; fi
    du -sk "${found[@]}" 2>/dev/null | awk '{ s += $1 } END { print s + 0 }'
}

# Finds project folders worth listing: .next/.turbo build output, node_modules
# of projects idle for 30+ days, and Claude Code git worktrees.
_dm_scan_projects() {
    local -a roots=()
    local d p
    while IFS= read -r d; do roots+=("$d"); done < <(dev_roots)
    : > "$DM_DIR/list_jsbuild"; : > "$DM_DIR/list_nodemods"; : > "$DM_DIR/list_worktrees"
    (( ${#roots[@]} == 0 )) && return 0

    run_timeout "$SCAN_TIMEOUT" find "${roots[@]}" -maxdepth 6 \
        \( -name .git -o -name Library -o -name .Trash -o -name .venv -o -name venv \) -prune -o \
        -type d \( -name node_modules -o -name .next -o -name .turbo -o -path '*/.claude/worktrees' \) \
        -prune -print 2>/dev/null > "$DM_DIR/devscan"

    while IFS= read -r p; do
        case $p in
            */node_modules)
                # idle = nothing in the project folder itself changed for 30 days
                [[ -z $(find "${p%/node_modules}" -maxdepth 1 -mtime -30 -print -quit 2>/dev/null) ]] \
                    && printf '%s\n' "$p" >> "$DM_DIR/list_nodemods" ;;
            */.next|*/.turbo)
                printf '%s\n' "$p" >> "$DM_DIR/list_jsbuild" ;;
            */.claude/worktrees)
                find "$p" -mindepth 1 -maxdepth 1 -type d >> "$DM_DIR/list_worktrees" 2>/dev/null ;;
        esac
    done < "$DM_DIR/devscan"
}

_dm_recs_measure() {   # OUT - one TSV row per non-empty recommendation
    local out=$1 key status label show
    local -i kb
    : > "$out"

    _dm_scan_projects
    { stale_entries "$(_user_tmpdir)" 1
      stale_entries "/private/tmp/claude-$(id -u)" 2; } > "$DM_DIR/list_temp"
    local inst
    : > "$DM_DIR/list_installers"
    for inst in "/Applications/Install macOS"*.app; do
        [[ -d $inst ]] && printf '%s\n' "$inst" >> "$DM_DIR/list_installers"
    done

    while IFS='|' read -r key status label show; do
        if [[ $key == trash ]] && is_tcc_blocked "$HOME/.Trash"; then
            kb=-1                                  # unknown, but Finder can still empty it
        else
            kb=$(_dm_rec_paths "$key" | _dm_sum_kb)
            (( kb < 1024 )) && continue            # under 1 MB - not worth a row
        fi
        printf '%s\t%s\t%s\t%s\t%s\n' "$key" "$status" "$kb" "$label" "$show" >> "$out"
    done <<'RECS'
trash|safe|Trash|~/.Trash
npm|safe|npm & npx cache|~/.npm
jsbuild|safe|Next.js & Turbo build output|<projects>/.next, .turbo
jscache|safe|Yarn, pnpm & Bun caches|~/.yarn, ~/Library/pnpm, ~/.bun
gradle|safe|Gradle caches|~/.gradle/caches
xcode|safe|Xcode DerivedData & device support|~/Library/Developer/Xcode
tools|safe|uv, pip, Puppeteer & test-browser caches|~/.cache/uv, ~/.cache/puppeteer, …
cargo|safe|Cargo registry & git cache|~/.cargo/registry
appcache|safe|App caches|~/Library/Caches
temp|safe|Stale temp files & old Claude sessions|$TMPDIR, /private/tmp/claude-*
android|review|Android SDK & emulators|~/Library/Android/sdk, ~/.android/avd
sims|review|iOS Simulators (erase all content)|~/Library/Developer/CoreSimulator
archives|review|Xcode Archives (needed to symbolicate)|~/Library/Developer/Xcode/Archives
ollama|review|Ollama models|~/.ollama/models
aimodels|review|Hugging Face & LM Studio models|~/.cache/huggingface, ~/.lmstudio
docker|review|Docker disk (all containers & images)|~/Library/Containers/com.docker.docker
nodemods|review|node_modules in idle projects (30+ days)|<projects>/*/node_modules
worktrees|review|Claude Code worktrees (clean ones only)|<projects>/.claude/worktrees
installers|review|macOS installer apps|/Applications/Install macOS*.app
RECS
}

# Measures the recommendations in the background, alongside the map scan.
# recs.tsv appears (atomically) only once the measurement is complete.
_dm_recs_start() {
    DM_RECS_READY=0
    REC_KEY=(); REC_STATUS=(); REC_KB=(); REC_LABEL=(); REC_SHOW=()
    rm -f "$DM_DIR/recs.tsv"
    ( _dm_recs_measure "$DM_DIR/recs.part" && mv "$DM_DIR/recs.part" "$DM_DIR/recs.tsv" ) &
    DM_RECS_PID=$!
}

# Loads the recommendations if they just became ready. Returns 0 only then,
# so callers know to redraw.
_dm_recs_poll() {
    (( DM_RECS_READY )) && return 1
    [[ -e $DM_DIR/recs.tsv ]] || return 1
    REC_KEY=(); REC_STATUS=(); REC_KB=(); REC_LABEL=(); REC_SHOW=()
    local k s b l w
    while IFS=$'\t' read -r k s b l w; do
        REC_KEY+=("$k"); REC_STATUS+=("$s"); REC_KB+=("$b"); REC_LABEL+=("$l"); REC_SHOW+=("$w")
    done < "$DM_DIR/recs.tsv"
    DM_RECS_READY=1
    return 0
}

_dm_wait_pid() { while kill -0 "$1" 2>/dev/null; do sleep 1; done; }

# Blocks (with a spinner) until the background measurement is done.
_dm_recs_wait() {
    (( DM_RECS_READY )) && return 0
    kill -0 "${DM_RECS_PID:-0}" 2>/dev/null \
        && spinner_run "Finishing the space measurements" _dm_wait_pid "$DM_RECS_PID"
    _dm_recs_poll
    return 0
}

# Totals for the header: REPLY="safe_kb safe_n review_kb review_n"
_dm_rec_totals() {
    local -i i sk=0 sn=0 rk=0 rn=0 b
    for (( i=0; i<${#REC_KEY[@]}; i++ )); do
        b=${REC_KB[i]}; (( b < 0 )) && b=0
        if [[ ${REC_STATUS[i]} == safe ]]; then (( sk += b, sn++ )); else (( rk += b, rn++ )); fi
    done
    REPLY="$sk $sn $rk $rn"
}

# =============================================================================
# § cleaning a recommendation
# =============================================================================

# rm -rf every listed path - but only paths that look exactly like what the
# list is supposed to hold, so a corrupt list can never delete anything else.
_dm_rm_list() {
    local key=$1 label=$2 p
    local -i kb freed=0 removed=0 failed=0
    step "[$label]"
    while IFS= read -r p; do
        [[ -n $p ]] || continue
        case $key:$p in
            nodemods:*/node_modules|jsbuild:*/.next|jsbuild:*/.turbo|installers:"/Applications/Install macOS"*.app) ;;
            *) warn "skipped unexpected path: $p"; continue ;;
        esac
        kb=$(dir_size_kb "$p")
        rm -rf "$p" 2>/dev/null
        if [[ -e $p ]]; then (( failed++ )); warn "could not remove: $(_dm_tilde "$p")"
        else (( removed++, freed += kb )); info "  removed : $(_dm_tilde "$p")  ($(human_size "$kb"))"
        fi
    done < <(_dm_rec_paths "$key")
    (( TOTAL_FREED_KB += freed, TOTAL_CLEANED++ ))
    ok "freed $(human_size $freed) from ${removed} folder(s) ← $label"
    echo
}

# `git worktree remove` refuses worktrees with uncommitted or untracked
# changes, so only fully clean worktrees go; their branches are kept.
_dm_remove_worktrees() {
    local wt repo
    local -i kb freed=0 removed=0 kept=0
    step "[Claude Code worktrees]"
    while IFS= read -r wt; do
        [[ $wt == */.claude/worktrees/* ]] || continue
        repo=${wt%%/.claude/worktrees/*}
        kb=$(dir_size_kb "$wt")
        if git -C "$repo" worktree remove "$wt" &>/dev/null; then
            (( removed++, freed += kb )); info "  removed : $(_dm_tilde "$wt")  ($(human_size "$kb"))"
        else
            (( kept++ )); info "  kept    : $(_dm_tilde "$wt")  (uncommitted changes, locked, or not a worktree)"
        fi
    done < <(_dm_rec_paths worktrees)
    (( TOTAL_FREED_KB += freed, TOTAL_CLEANED++ ))
    ok "removed ${removed} worktree(s), kept ${kept}, freed $(human_size $freed)"
    echo
}

_dm_apply() {
    local key=$1 label=$2 p
    case $key in
        trash)     empty_trash ;;
        appcache)  sweep_caches "App caches" "$HOME/Library/Caches" "$HOME/Library/Caches/*" ;;
        temp)      temp_purge_all ;;
        jsbuild|nodemods|installers) _dm_rm_list "$key" "$label" ;;
        worktrees) _dm_remove_worktrees ;;
        ollama)    ollama_clean ;;
        docker)    docker_clean ;;
        sims)      run_step "Shut down all simulators" "xcrun simctl shutdown all"
                   run_step "Erase all simulators"     "xcrun simctl erase all" ;;
        *)         while IFS= read -r p; do
                       [[ -d $p ]] && clean_dir "$p" "$label - ${p##*/}"
                   done < <(_dm_rec_paths "$key") ;;
    esac
}

# Recommendation list → pick → confirm → clean. Returns 0 if anything ran.
_dm_recommend() {
    local -i n=${#REC_KEY[@]} i
    if (( n == 0 )); then
        printf '\n'; say "Nothing worth cleaning was found."; sleep 2; return 1
    fi

    local -a items=("Select all")
    local pre='' tag
    for (( i=0; i<n; i++ )); do
        [[ ${REC_STATUS[i]} == safe ]] && { tag='safe  '; pre+="$i "; } || tag='review'
        items+=("$(printf '%s  %-42s %8s   %s' "$tag" "${REC_LABEL[i]}" "$(_dm_fmt "${REC_KB[i]}")" "${REC_SHOW[i]}")")
    done
    items+=("Back - return to the disk map")

    MS_TAIL_CONTROLS=1
    MS_BACK_ROW=$(( ${#items[@]} - 1 ))
    MS_PRESELECT=$pre
    clear 2>/dev/null || true
    interactive_multiselect "Recommendations - safe items are pre-ticked, review items are not" "${items[@]}"

    (( MULTISELECT_BACK == 1 || MULTISELECT_CANCELLED == 1 )) && return 1
    local -a chosen=()
    local x
    for x in $MULTISELECT_RESULT; do (( x < n )) && chosen+=("$x"); done
    (( ${#chosen[@]} == 0 )) && return 1

    local -i total=0 b
    printf '\n'
    say "About to clean:"
    for x in "${chosen[@]}"; do
        b=${REC_KB[x]}; (( b > 0 )) && (( total += b ))
        info "• ${REC_LABEL[x]}  ($(_dm_fmt "${REC_KB[x]}"))"
    done
    printf "\n  ${YLW}Clean %d item(s), about %s? [y/N]: ${NC}" "${#chosen[@]}" "$(_dm_fmt "$total")"
    local answer; read -r answer
    [[ $answer == [yY] ]] || { info "Cancelled - nothing removed."; sleep 1; return 1; }

    local -i freed_before=$TOTAL_FREED_KB
    for x in "${chosen[@]}"; do
        section "${REC_LABEL[x]}"
        _dm_apply "${REC_KEY[x]}" "${REC_LABEL[x]}"
    done
    ok "Done - $(human_size $(( TOTAL_FREED_KB - freed_before ))) freed. Disk: $(disk_free)"
    printf "\n  ${DIM}Press any key to rescan and return to the map…${NC}"
    IFS= read -rsn1 _
    return 0
}

# =============================================================================
# § drawing
#
#   A frame is built in memory and painted in one write: cursor home, every
#   line followed by "clear to end of line", then "clear below". Nothing is
#   blanked first, so redrawing once a second during a scan doesn't flicker.
# =============================================================================
_dm_frame() {   # ROOT W H STATUS
    local root=$1 status=$4
    local -i W=$2 H=$3

    local mode=plain
    if (( _COLOR )); then (( _TRUECOLOR )) && mode=truecolor || mode=256; fi

    local -i sk sn rk rn avail used
    _dm_rec_totals
    read -r sk sn rk rn <<< "$REPLY"
    avail=$(disk_avail_kb)
    used=$(df -k / | awk 'NR==2 {print $2 - $4}')

    printf "  ${ACCENT}${BOLD}Disk map${NC}  ${WHT}%s${NC}   ${DIM}%s %s · %s view${NC}\n" \
        "$(_dm_tilde "$root")" "$(_dm_fmt "$DM_ROOT_KB")" \
        "$([[ -n $status ]] && echo 'found so far' || echo 'in this folder')" "$DM_VIEW"

    local c1 c2 c3 c4 v1 v2 v3 v4
    c1="Free after cleanup"; c2="Safe to remove"; c3="Needs review"; c4="Not scanned"
    if (( DM_RECS_READY )); then
        v1="$(_dm_fmt $(( avail + sk )))  +$(_dm_fmt "$sk")"
        v2="$(_dm_fmt "$sk")  ${sn} items"
        v3="$(_dm_fmt "$rk")  ${rn} items"
    else
        v1="$(_dm_fmt "$avail")  measuring…"; v2="measuring…"; v3="measuring…"
    fi
    v4="-"
    (( DM_HOME_KB > 0 && used > DM_HOME_KB )) && v4="$(_dm_fmt $(( used - DM_HOME_KB )))  system & apps"
    printf "  ${DIM}%-24s${NC}${BGRN}●${NC} ${DIM}%-22s${NC}${ORG}●${NC} ${DIM}%-22s${NC}${DIM}%s${NC}\n" \
        "$c1" "$c2" "$c3" "$c4"
    printf "  ${BOLD}%-24s${NC}  ${BOLD}%-22s${NC}  ${BOLD}%-22s${NC}${BOLD}%s${NC}\n" "$v1" "$v2" "$v3" "$v4"
    printf '\n'

    awk -v W="$W" -v H="$H" -v mode="$mode" -v view="$DM_VIEW" \
        -v msg="Scanning - folders appear here as they are measured..." \
        -f "$LIB_DIR/diskmap.awk" "$DM_DIR/render.tsv"

    if [[ -n $status ]]; then
        printf '\n%s' "$status"
    elif (( DM_TTY )); then
        printf "\n  ${DIM}1-9 open tile · o open any · u up · v %s view · r recommendations & clean · s rescan · q back${NC}" \
            "$([[ $DM_VIEW == category ]] && echo cleanup || echo category)"
    fi
}

# Sets DM_COLS / DM_LINES. Asks the terminal device itself: inside $(…) with
# stderr silenced, tput sees no terminal at all and falls back to 80 columns.
_dm_term_size() {
    local size; size=$(stty size 2>/dev/null < /dev/tty) || size=''
    if [[ $size =~ ^([0-9]+)\ ([0-9]+)$ ]]; then
        DM_LINES=${BASH_REMATCH[1]}; DM_COLS=${BASH_REMATCH[2]}
    else
        DM_COLS=$(tput cols 2>/dev/null || echo 100); DM_LINES=$(tput lines 2>/dev/null || echo 32)
    fi
    (( DM_COLS < 40 )) && DM_COLS=100; (( DM_LINES < 16 )) && DM_LINES=32
    return 0
}

_dm_draw() {   # ROOT [STATUS]
    local root=$1 status=${2:-} frame
    local -i cols lines W H
    _dm_term_size; cols=$DM_COLS; lines=$DM_LINES
    W=$(( cols - 3 )); (( W > 220 )) && W=220
    H=$(( lines - 9 ))

    if (( ! DM_TTY )); then _dm_frame "$root" "$W" "$H" "$status"; return; fi
    frame=$(_dm_frame "$root" "$W" "$H" "$status")
    # Line-wrap off: a line wider than the window is cut at the edge instead
    # of wrapping, which would push every later frame down a line.
    _ui_wrap_off
    printf '\033[H%s\033[K\033[J' "${frame//$'\n'/$'\033[K\n'}"
}

# =============================================================================
# § run_disk_map  (main-menu entry)
# =============================================================================
run_disk_map() {
    DM_DIR=$(mktemp -d "${TMPDIR:-/tmp}/mac_cleaner_map.XXXXXX") || { fail "could not create a temp folder"; return 1; }
    DM_VIEW=category; DM_HOME_KB=0; DM_TTY=0
    [[ -t 0 && -t 1 ]] && DM_TTY=1
    : > "$DM_DIR/render.tsv"

    # Ctrl-C must not leave background du workers running.
    trap '_dm_stop_all; _ui_term_restore; exit 130' INT
    if (( DM_TTY )); then clear 2>/dev/null || true; tput civis 2>/dev/null; fi

    local root=$HOME key seq pick
    local -i redraw=1

    _dm_recs_start
    _dm_scan "$root"
    (( DM_TTY )) || _dm_recs_wait
    _dm_recs_poll

    while true; do
        _dm_recs_poll && redraw=1
        (( redraw )) && _dm_draw "$root"
        redraw=1

        # Not interactive: one static picture is all we can do.
        (( DM_TTY )) || { printf '\n'; break; }

        # While the recommendations are still measuring, wake once a second
        # so the header fills in as soon as they're ready.
        if (( DM_RECS_READY )); then
            IFS= read -rsn1 key
        elif ! IFS= read -rsn1 -t 1 key; then
            redraw=0; continue
        fi
        if [[ $key == $'\x1b' ]]; then
            IFS= read -rsn2 -t 1 seq 2>/dev/null || seq=''
            key="${key}${seq}"
        fi

        case $key in
            [1-9])
                [[ -n ${DM_TILE_PATHS[key]:-} ]] && { root=${DM_TILE_PATHS[key]}; _dm_scan "$root"; } ;;
            o|O)
                (( ${#DM_OPEN_PATHS[@]} > 0 )) || continue
                clear 2>/dev/null || true
                MENU_RESULT=${#DM_OPEN_PATHS[@]}
                interactive_menu "Open which folder in $(_dm_tilde "$root")?" "${DM_OPEN_LABELS[@]}" "Cancel"
                tput civis 2>/dev/null
                pick=$MENU_RESULT
                if (( pick < ${#DM_OPEN_PATHS[@]} )); then root=${DM_OPEN_PATHS[pick]}; _dm_scan "$root"; fi ;;
            u|U|$'\x1b[D'|$'\x7f')
                if [[ $root != "$HOME" ]]; then root=${root%/*}; _dm_scan "$root"; fi ;;
            v|V)
                [[ $DM_VIEW == category ]] && DM_VIEW=cleanup || DM_VIEW=category ;;
            r|R|c|C)
                tput cnorm 2>/dev/null
                printf '\n'
                _dm_recs_wait
                if _dm_recommend; then
                    rm -f "$DM_DIR"/du_*
                    clear 2>/dev/null || true; tput civis 2>/dev/null
                    _dm_recs_start
                    _dm_scan "$root"
                else
                    tput civis 2>/dev/null
                fi ;;
            s|S)
                rm -f "$(_dm_cache_file "$root")"
                _dm_recs_start
                _dm_scan "$root" ;;
            q|Q|b|B|$'\x1b')
                break ;;
        esac
    done

    _dm_stop_all
    (( DM_TTY )) && { tput cnorm 2>/dev/null; _ui_wrap_on; }
    trap '_ui_term_restore; exit 130' INT
    printf '\n'
    rm -rf "$DM_DIR"
}
