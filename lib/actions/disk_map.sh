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
#   Everything slow runs in the background, so the screen never waits:
#     • the scan    - a pool of workers (helpers/duscan.sh) measures the folder;
#                     a folder that takes long is split over all workers, however
#                     deep it sits. DM_JOBS workers (default = CPU count, max 16)
#     • the picture - a renderer turns what is known so far into a new frame a
#                     few times a second; folders still growing show a "~"
#     • the advice  - each recommendation is measured by its own job and joins
#                     the header as soon as it is known
#   The foreground only paints: the newest frame when there is one, and ten
#   times a second the bottom line - a spinner, a progress bar, the folder just
#   measured. Keys work the whole time; q stops a scan early.
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
DM_SCAN_WORK=''         # working folder of the scan in progress ('' = none)
DM_RENDER_PID=''        # background renderer of the scan in progress
DM_RENDER=''            # tile list a frame is drawn from ('' = DM_DIR/render.tsv)
DM_LAST_DU=''           # du listing of an interrupted scan (not cached)
DM_COLS=100; DM_LINES=32
DM_STATUS_ROW=2         # screen row of the bottom line (status / key help)

# Recommendation rows (parallel arrays, refilled by _dm_recs_poll while the
# background measurement started by _dm_recs_start reports its results).
REC_KEY=(); REC_STATUS=(); REC_KB=(); REC_LABEL=(); REC_SHOW=()
DM_RECS_READY=0         # 1 once every recommendation has been measured
DM_RECS_DONE=0          # recommendations measured so far
DM_RECS_TOTAL=0         # recommendations in all
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

# _dm_fmt_r KB → the same text as _dm_fmt, in REPLY, without starting a process
# (the status line is rebuilt ten times a second).
_dm_fmt_r() {
    local -i k=$1 t
    if   (( k < 0 ));          then REPLY='?'
    elif (( k >= 104857600 )); then REPLY="$(( (k + 524288) / 1048576 )) GB"
    elif (( k >= 1048576 ));   then t=$(( (k * 10 + 524288) / 1048576 )); REPLY="$(( t / 10 )).$(( t % 10 )) GB"
    elif (( k >= 1024 ));      then REPLY="$(( (k + 512) / 1024 )) MB"
    else                            REPLY="${k} KB"
    fi
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

# _dm_status PATH → sets REPLY to "safe" (regenerable: caches, logs, build
# output), "review" (large but personal: models, backups, SDKs) or "-" (leave).
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

# _dm_cat_idx CATEGORY → sets REPLY to the category's column in DM_CATS.
_dm_cat_idx() {
    case $1 in code) REPLY=0 ;; docs) REPLY=1 ;; ai) REPLY=2 ;; sdk) REPLY=3 ;; pkg) REPLY=4 ;; *) REPLY=5 ;; esac
}
DM_CATS=(code docs ai sdk pkg other)

# =============================================================================
# § scanning
# =============================================================================
_dm_cache_file() { printf '%s/du_%s' "$DM_DIR" "$(printf '%s' "$1" | cksum | awk '{print $1}')"; }

# =============================================================================
# § live scan
#
#   The measuring itself is done by the worker pool of helpers/duscan.sh. Here
#   it is put on screen. Three things run at once:
#
#     workers    (background)  measure folders and append their results
#     renderer   (background)  every 0.3 s: results so far → tiles → a frame
#                              file, written whole and swapped in with `mv`
#     this shell (foreground)  ten times a second: paint the newest frame if
#                              there is a new one, repaint the status line,
#                              read the keyboard
#
#   Building a frame takes a few hundred milliseconds. With the renderer in
#   the background that cost never blocks the spinner or a key press.
# =============================================================================

# =============================================================================
# § _dm_stop_all
#
#   Stops everything the disk map has running in the background - the scan
#   workers, the renderer, the recommendation jobs - and whatever they
#   started. Safe to call when nothing is running.
# =============================================================================
_dm_stop_all() {
    local pid
    [[ -n $DM_SCAN_WORK && -d $DM_SCAN_WORK ]] && du_scan_stop "$DM_SCAN_WORK"
    for pid in ${DM_RENDER_PID:-} ${DM_RECS_PID:-}; do
        kill -0 "$pid" 2>/dev/null && kill_tree "$pid"
    done
    DM_RENDER_PID='' DM_SCAN_WORK=''
}

# =============================================================================
# § _dm_render_loop ROOT WORK
#
#   The background renderer of a live scan. Writes WORK/frame: a sequence
#   number on the first line (so the foreground can tell a new frame from the
#   one it already painted), then the packed frame (_dm_frame_packed).
#   The view (category / cleanup) is read from WORK/view each round, so the v
#   key takes effect on the next frame. Ends when the scan finishes or stops.
# =============================================================================
_dm_render_loop() {
    local root=$1 work=$2
    local -i seq=0
    DM_RENDER="$work/render.tsv"
    while [[ ! -e $work/stop && ! -e $work/finished ]]; do
        [[ -s $work/view ]] && read -r DM_VIEW < "$work/view"
        # Loose files join only in the final listing: on their own they would
        # fill the whole map before the first folder arrives.
        du_scan_merge "$root" "$work" 0 > "$work/merged.live"
        _dm_recs_poll
        _dm_build "$root" "$work/merged.live"
        _dm_term_size
        { printf '%d\n' "$(( ++seq ))"; _dm_frame_packed "$root" 1; } > "$work/frame.new"
        mv "$work/frame.new" "$work/frame"
        sleep 0.3
    done
}

# =============================================================================
# § _dm_scan_status FRAME ELAPSED
#
#   Builds the bottom line of a running scan:
#
#     ⠹ ██████████▌        412/980 folders · 9s  ·  ~/Library/Developer 34.1 GB  (q stop · v view)
#
#   No process is started here - it runs ten times a second.
#
#   Globals:
#     reads  DU_SCAN_DONE / DU_SCAN_TOTAL / DU_SCAN_LATEST, DM_COLS
#     writes REPLY
# =============================================================================
_dm_scan_status() {
    local spin bar latest='' size=''
    local -i room=$(( DM_COLS - 62 ))
    ui_spin "$1"; spin=$REPLY
    ui_bar "$DU_SCAN_DONE" "$DU_SCAN_TOTAL" 18; bar=$REPLY
    if [[ -n $DU_SCAN_LATEST ]]; then
        latest=${DU_SCAN_LATEST#*$'\t'}
        [[ $latest == "$HOME"* ]] && latest="~${latest#"$HOME"}"
        (( room < 12 )) && room=12
        (( ${#latest} > room )) && latest="…${latest: -$(( room - 1 ))}"
        _dm_fmt_r "${DU_SCAN_LATEST%%$'\t'*}"; size=$REPLY
        latest="  ${DIM}·${NC}  ${YLW}${latest}${NC} ${size}"
    fi
    REPLY="  ${spin} ${bar} ${BOLD}${DU_SCAN_DONE}/${DU_SCAN_TOTAL}${NC} folders ${DIM}· ${2}s${NC}${latest}  ${DIM}(q stop · v view)${NC}"
}

# =============================================================================
# § _dm_scan_live ROOT CACHE
#
#   Scans ROOT and shows it happening (see "live scan" above). Without a
#   terminal it just waits for the workers.
#
#   Arguments:
#     ROOT   folder to scan
#     CACHE  file that receives the finished listing
#   Globals:
#     writes DM_SCAN_WORK, DM_RENDER_PID, DM_LAST_DU, DM_VIEW (v key)
#   Returns:
#     0 when the scan finished and CACHE was written; 1 when the user stopped
#     it with q - the partial listing is then in DM_LAST_DU
# =============================================================================
_dm_scan_live() {
    local root=$1 cache=$2 work key txt body='' seq='' newseq status rows
    local -i files_kb frame=0 stopped=0 t0=$SECONDS keys=0
    work=$(mktemp -d "$DM_DIR/scan.XXXXXX") || return 1
    DM_SCAN_WORK=$work
    printf '%s\n' "$DM_VIEW" > "$work/view"

    du_scan_start "$root" "$work"

    if (( DM_TTY )); then
        ( _dm_render_loop "$root" "$work" ) > /dev/null 2>&1 &
        DM_RENDER_PID=$!
        ui_keys_begin && keys=1
        _dm_term_size
        # Something to look at while the first frame is on its way.
        printf '\033[H  %sDisk map%s  %s%s%s\033[K\n\033[J' \
            "${ACCENT}${BOLD}" "$NC" "$WHT" "$(_dm_tilde "$root")" "$NC"
        DM_STATUS_ROW=3
    fi
    files_kb=$(du_loose_kb "$root")

    while du_scan_running; do
        if (( ! DM_TTY )); then sleep 0.5; continue; fi

        du_scan_progress "$work"
        _dm_scan_status "$frame" "$(( SECONDS - t0 ))"; status=$REPLY

        # A new frame from the renderer? Paint it; otherwise just the status.
        newseq=''
        [[ -s $work/frame ]] && IFS= read -r newseq < "$work/frame"
        if [[ -n $newseq && $newseq != "$seq" ]]; then
            seq=$newseq
            IFS= read -r -d '' txt < "$work/frame"
            txt=${txt#*$'\n'}                       # drop the sequence line
            rows=${txt%%$'\n'*}; body=${txt#*$'\n'}; body=${body%$'\n'}
            [[ $rows =~ ^[0-9]+$ ]] && _dm_paint "$body" "$status" "$rows"
            _dm_term_size
        else
            _dm_bottom "$status"
        fi
        (( frame++ ))

        if (( keys )); then
            if ! ui_keys_poll; then
                ui_keys_lost && { stopped=1; break; }       # no keyboard: do not wait forever
                continue
            fi
            for key in "${UI_KEYS[@]}"; do
                case $key in
                    q|Q|ESC) stopped=1 ;;
                    v|V)     [[ $DM_VIEW == category ]] && DM_VIEW=cleanup || DM_VIEW=category
                             printf '%s\n' "$DM_VIEW" > "$work/view" ;;
                esac
            done
            (( stopped )) && break
        else
            sleep 0.1
        fi
    done

    (( keys )) && ui_keys_end
    : > "$work/finished"
    if [[ -n $DM_RENDER_PID ]]; then
        kill_tree "$DM_RENDER_PID"; wait "$DM_RENDER_PID" 2>/dev/null
        DM_RENDER_PID=''
    fi

    if (( stopped )); then
        du_scan_stop "$work"
        du_scan_merge "$root" "$work" "$files_kb" > "$work/merged"
        DM_LAST_DU="$work/merged"; DM_SCAN_WORK=''
        return 1
    fi
    du_scan_merge "$root" "$work" "$files_kb" > "$cache"
    rm -rf "$work"; DM_SCAN_WORK=''
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

# _dm_scan ROOT → makes sure ROOT has been measured (cached per session; a new
# scan runs live, see _dm_scan_live) and builds the tiles for it.
_dm_scan() {
    local root=$1 cache src
    cache=$(_dm_cache_file "$root"); src=$cache
    if [[ ! -s $cache ]]; then
        _dm_scan_live "$root" "$cache" || src=$DM_LAST_DU
    fi
    _dm_build "$root" "$src"
}

# _dm_build ROOT DU_LISTING → classifies every tile of a du listing of ROOT and
# writes the tile list a frame is drawn from (DM_RENDER, default
# $DM_DIR/render.tsv). Also sets DM_ROOT_KB, DM_TILE_PATHS and DM_OPEN_*.
_dm_build() {   # ROOT DU_LISTING
    local root=$1 listing=$2
    local -a kind=() id=() par=() kb=() path=() label=() live=() cat=() st=()
    local k i p l pa b lv
    local -i n=0
    DM_ROOT_KB=0
    # (A here-string, not a process substitution: the renderer calls this for
    # every frame of a live scan - see lib/core.sh.)
    while IFS=$'\t' read -r k i pa b p l lv; do
        [[ -n $k ]] || continue
        if [[ $k == 0 ]]; then DM_ROOT_KB=$b; continue; fi
        kind[n]=$k; id[n]=$i; par[n]=$pa; kb[n]=$b; path[n]=$p; label[n]=$l; live[n]=${lv:-0}
        (( n++ ))
    done <<< "$(_dm_prepare "$root" "$listing")"
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
    local render=${DM_RENDER:-$DM_DIR/render.tsv}
    : > "$render"
    for (( j=0; j<n; j++ )); do
        [[ -z ${cat[j]} ]] && cat[j]=${top_cat[par[j]]:-other}
        shown='-'
        if [[ ${kind[j]} == 1 && ${path[j]} != - && -d ${path[j]} ]]; then
            DM_OPEN_PATHS+=("${path[j]}")
            DM_OPEN_LABELS+=("$(printf '%-34s %9s' "${label[j]}" "$(_dm_fmt "${kb[j]}")")")
            if (( num < 9 )); then (( num++ )); shown=$num; DM_TILE_PATHS[num]=${path[j]}; fi
        fi
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "${kind[j]}" "${id[j]}" "${par[j]}" "${kb[j]}" \
            "${cat[j]}" "${st[j]}" "${label[j]}" "$shown" "${live[j]}" >> "$render"
    done
}

# =============================================================================
# § recommendations  (what's worth removing, measured once per scan)
#
#   _dm_rec_paths KEY prints the folders behind a recommendation - the single
#   source of truth for both measuring and cleaning it.
#
#   Measuring is spread over one background job per recommendation
#   (_dm_recs_measure). Each job drops its result into $DM_DIR/recs.d as soon
#   as it has it, and _dm_recs_poll picks up whatever is there - so the header
#   fills in step by step instead of saying "measuring…" until the slowest
#   folder is done.
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
        colima)    printf '%s\n' "$HOME/.colima" ;;
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

# =============================================================================
# § _dm_recs_table
#
#   Outputs:
#     Every recommendation, one per line:  KEY|STATUS|LABEL|WHAT IS SHOWN
#     STATUS is "safe" (starts ticked) or "review".
# =============================================================================
_dm_recs_table() {
    cat <<'RECS'
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
colima|review|Colima VMs & their Docker data|~/.colima
nodemods|review|node_modules in idle projects (30+ days)|<projects>/*/node_modules
worktrees|review|Claude Code worktrees (clean ones only)|<projects>/.claude/worktrees
installers|review|macOS installer apps|/Applications/Install macOS*.app
RECS
}

# =============================================================================
# § _dm_recs_row INDEX KEY STATUS LABEL SHOW
#
#   Measures one recommendation and publishes it as $DM_DIR/recs.d/INDEX.row:
#   one TSV line (key · status · KB · label · what is shown), or an empty file
#   when it is under 1 MB and not worth a row. The file appears whole (it is
#   written under another name and renamed), so a reader never sees half of it.
# =============================================================================
_dm_recs_row() {
    local dir="$DM_DIR/recs.d" idx=$1 key=$2
    local -i kb
    if [[ $key == trash ]] && is_tcc_blocked "$HOME/.Trash"; then
        kb=-1                                  # unknown, but Finder can still empty it
    else
        kb=$(_dm_rec_paths "$key" | _dm_sum_kb)
    fi
    if (( kb == -1 || kb >= 1024 )); then
        printf '%s\t%s\t%s\t%s\t%s\n' "$key" "$3" "$kb" "$4" "$5" > "$dir/$idx.tmp"
    else
        : > "$dir/$idx.tmp"
    fi
    mv "$dir/$idx.tmp" "$dir/$idx.row"
}

# =============================================================================
# § _dm_recs_measure
#
#   Measures every recommendation, all at the same time: one background job
#   per row. Three rows need a list that takes a moment to build (project
#   folders, stale temp items); those lists are built by two more jobs, and
#   the rows that need them wait for the matching ".ready" marker.
#   recs.d/complete appears once every row has been published.
# =============================================================================
_dm_recs_measure() {
    local dir="$DM_DIR/recs.d" key status label show need inst
    local -i i=0
    mkdir -p "$dir"

    ( _dm_scan_projects; : > "$dir/projects.ready" ) &
    ( { stale_entries "$(_user_tmpdir)" 1
        stale_entries "/private/tmp/claude-$(id -u)" 2; } > "$DM_DIR/list_temp"
      : > "$dir/temp.ready" ) &
    : > "$DM_DIR/list_installers"
    for inst in "/Applications/Install macOS"*.app; do
        [[ -d $inst ]] && printf '%s\n' "$inst" >> "$DM_DIR/list_installers"
    done

    while IFS='|' read -r key status label show; do
        need=''
        case $key in
            jsbuild|nodemods|worktrees) need="$dir/projects.ready" ;;
            temp)                       need="$dir/temp.ready" ;;
        esac
        (
            [[ -n $need ]] && until [[ -e $need ]]; do sleep 0.2; done
            _dm_recs_row "$(printf '%02d' "$i")" "$key" "$status" "$label" "$show"
        ) &
        (( i++ ))
    done < <(_dm_recs_table)
    wait
    : > "$dir/complete"
}

# =============================================================================
# § _dm_recs_start
#
#   Starts measuring the recommendations in the background, alongside the map
#   scan, and returns at once. A measurement still running from before (the
#   user asked for a rescan) is stopped first.
#
#   Globals:
#     writes DM_RECS_PID, DM_RECS_READY, DM_RECS_DONE, DM_RECS_TOTAL, REC_*
# =============================================================================
_dm_recs_start() {
    [[ -n $DM_RECS_PID ]] && kill -0 "$DM_RECS_PID" 2>/dev/null && kill_tree "$DM_RECS_PID"
    DM_RECS_READY=0 DM_RECS_DONE=0
    DM_RECS_TOTAL=$(( $(_dm_recs_table | wc -l) + 0 ))
    REC_KEY=(); REC_STATUS=(); REC_KB=(); REC_LABEL=(); REC_SHOW=()
    rm -rf "$DM_DIR/recs.d"; mkdir -p "$DM_DIR/recs.d"
    ( _dm_recs_measure ) > /dev/null 2>&1 &
    DM_RECS_PID=$!
}

# =============================================================================
# § _dm_recs_poll
#
#   Loads the recommendations measured so far.
#
#   Globals:
#     writes REC_* (the rows known so far, in table order), DM_RECS_DONE,
#            DM_RECS_READY (1 once all of them are in)
#   Returns:
#     0 when something changed since the last call - the caller should redraw;
#     1 when nothing is new
# =============================================================================
_dm_recs_poll() {
    (( DM_RECS_READY )) && return 1
    local dir="$DM_DIR/recs.d" f k s b l w
    local -i n=0 complete=0
    [[ -e $dir/complete ]] && complete=1
    for f in "$dir"/*.row; do [[ -e $f ]] && (( n++ )); done
    (( n == DM_RECS_DONE && ! complete )) && return 1

    REC_KEY=(); REC_STATUS=(); REC_KB=(); REC_LABEL=(); REC_SHOW=()
    for f in "$dir"/*.row; do
        [[ -s $f ]] || continue
        IFS=$'\t' read -r k s b l w < "$f" || continue
        REC_KEY+=("$k"); REC_STATUS+=("$s"); REC_KB+=("$b"); REC_LABEL+=("$l"); REC_SHOW+=("$w")
    done
    DM_RECS_DONE=$n DM_RECS_READY=$complete
    return 0
}

# _dm_wait_pid PID → returns once the process has exited.
_dm_wait_pid() { while kill -0 "$1" 2>/dev/null; do sleep 0.2; done; }

# Blocks (with a spinner) until every recommendation has been measured.
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

# _dm_apply KEY LABEL → cleans one recommendation with the same guarded helper
# the main cleanup uses for it (the destructive ones still ask on their own).
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
        colima)    colima_clean ;;
        sims)      local sc; sc=$(simctl_cmd)
                   if [[ -z $sc ]]; then skip_missing "Xcode simctl"; return; fi
                   run_step "Shut down all simulators" "$sc shutdown all"
                   run_step "Erase all simulators"     "$sc erase all" ;;
        *)         while IFS= read -r p; do
                       [[ -d $p ]] || continue
                       if [[ $p == "$HOME/.cache/uv" ]] && pgrep -x uv &>/dev/null; then
                           skip_in_use "$label - uv" "a uv/uvx process holds the cache lock"
                           continue
                       fi
                       clean_dir "$p" "$label - ${p##*/}"
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

    # shellcheck disable=SC2034  # options read by interactive_multiselect
    MS_TAIL_CONTROLS=1 MS_BACK_ROW=$(( ${#items[@]} - 1 )) MS_PRESELECT=$pre
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
#   The screen has two parts: the frame (header · map · legend) and, under it,
#   one bottom line (a status while something is being measured, the key help
#   otherwise). A frame is built off-screen and painted in one write: cursor
#   home, every line ending in "clear to end of line", then "clear below".
#   Nothing is blanked first, so repainting does not flicker. The bottom line
#   can be repainted on its own, which is what makes its animation cheap.
# =============================================================================

# =============================================================================
# § _dm_frame ROOT LIVE
#
#   Prints the frame for ROOT at the size set by _dm_term_size: a title line,
#   the four header figures, the treemap with its legend, and a blank line.
#
#   Arguments:
#     ROOT  the folder shown
#     LIVE  1 while ROOT is still being scanned ("found so far")
#   Globals:
#     reads DM_COLS, DM_LINES, DM_VIEW, DM_ROOT_KB, DM_HOME_KB, DM_RENDER and
#           the recommendation state (REC_*, DM_RECS_*)
# =============================================================================
_dm_frame() {
    local root=$1 scanning=${2:-0} mode=plain note='in this folder'
    local -i W=$(( DM_COLS - 3 )) H=$(( DM_LINES - 9 ))
    (( W > 220 )) && W=220
    (( scanning )) && note='found so far'
    if (( _COLOR )); then (( _TRUECOLOR )) && mode=truecolor || mode=256; fi

    local -i sk sn rk rn avail used
    _dm_rec_totals
    read -r sk sn rk rn <<< "$REPLY"
    avail=$(disk_avail_kb)
    used=$(df -k / | awk 'NR==2 {print $2 - $4}')

    printf "  ${ACCENT}${BOLD}Disk map${NC}  ${WHT}%s${NC}   ${DIM}%s %s · %s view${NC}\n" \
        "$(_dm_tilde "$root")" "$(_dm_fmt "$DM_ROOT_KB")" "$note" "$DM_VIEW"

    # The header figures fill in as the recommendations are measured.
    local c1 c2 c3 c4 v1 v2 v3 v4
    c1="Free after cleanup"; c2="Safe to remove"; c3="Needs review"; c4="Not scanned"
    if (( DM_RECS_READY )); then
        v1="$(_dm_fmt $(( avail + sk )))  +$(_dm_fmt "$sk")"
        v2="$(_dm_fmt "$sk")  ${sn} items"
        v3="$(_dm_fmt "$rk")  ${rn} items"
    elif (( DM_RECS_DONE > 0 )); then
        v1="$(_dm_fmt $(( avail + sk )))  +$(_dm_fmt "$sk") …"
        v2="$(_dm_fmt "$sk")  ${DM_RECS_DONE}/${DM_RECS_TOTAL} checked"
        v3="$(_dm_fmt "$rk")  so far"
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
        -f "$LIB_DIR/diskmap.awk" "${DM_RENDER:-$DM_DIR/render.tsv}"
    printf '\n'
}

# =============================================================================
# § _dm_frame_packed ROOT LIVE
#
#   The frame, ready to paint: the first line is its number of rows, every
#   row after it ends in "clear to end of line".
# =============================================================================
_dm_frame_packed() {
    _dm_frame "$1" "${2:-0}" | awk '{ row[NR] = $0 } END { print NR; for (i = 1; i <= NR; i++) printf "%s\033[K\n", row[i] }'
}

# =============================================================================
# § _dm_paint BODY BOTTOM ROWS
#
#   Paints a packed frame and the bottom line in one write.
#
#   Globals:
#     writes DM_STATUS_ROW  the screen row the bottom line is on
# =============================================================================
_dm_paint() {
    # Line-wrap off: a line wider than the window is cut at the edge instead
    # of wrapping, which would push everything after it down a line.
    _ui_wrap_off
    printf '\033[H%s\n%s\033[K\033[J' "$1" "$2"
    DM_STATUS_ROW=$(( $3 + 1 ))
}

# _dm_bottom TEXT → repaints only the bottom line.
_dm_bottom() { printf '\033[%d;1H%s\033[K' "$DM_STATUS_ROW" "$1"; }

# _dm_help → sets REPLY to the key help shown on the bottom line.
_dm_help() {
    local other=cleanup
    [[ $DM_VIEW == cleanup ]] && other=category
    REPLY="  ${DIM}1-9 open tile · o open any · u up · v ${other} view · r recommendations & clean · s rescan · q back${NC}"
}

# =============================================================================
# § _dm_recs_status FRAME
#
#   Bottom line while the map is ready but the recommendations are not:
#
#     ⠹ ████████▌     14/20  checking what is safe to remove  ·  keys work: 1-9 o u v s q
#
#   Globals:
#     writes REPLY
# =============================================================================
_dm_recs_status() {
    local spin
    ui_spin "$1"; spin=$REPLY
    ui_bar "$DM_RECS_DONE" "$DM_RECS_TOTAL" 14
    REPLY="  ${spin} ${REPLY} ${BOLD}${DM_RECS_DONE}/${DM_RECS_TOTAL}${NC} checking what is safe to remove  ${DIM}·  keys work already: 1-9 o u v s q${NC}"
}

# =============================================================================
# § _dm_term_size
#
#   Sets DM_COLS / DM_LINES. Asks the terminal device itself: inside $(…) with
#   stderr silenced, tput sees no terminal at all and falls back to 80 columns.
# =============================================================================
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

# =============================================================================
# § _dm_draw ROOT
#
#   Paints the finished map of ROOT with the key help under it. Without a
#   terminal it prints the frame once, as plain output.
# =============================================================================
_dm_draw() {
    local root=$1 packed
    _dm_term_size
    if (( ! DM_TTY )); then _dm_frame "$root" 0; return; fi
    packed=$(_dm_frame_packed "$root" 0)
    _dm_help
    _dm_paint "${packed#*$'\n'}" "$REPLY" "${packed%%$'\n'*}"
}

# =============================================================================
# § run_disk_map  (main-menu entry)
#
#   Opens the map of the home folder and handles the keys until the user goes
#   back. The loop wakes ten times a second (key polling): it repaints the map
#   when something changed, and animates the bottom line while the
#   recommendations are still being measured.
# =============================================================================
run_disk_map() {
    local tmp=${TMPDIR:-/tmp}
    DM_DIR=$(mktemp -d "${tmp%/}/mac_cleaner_map.XXXXXX") || { fail "could not create a temp folder"; return 1; }
    DM_VIEW=category; DM_HOME_KB=0; DM_TTY=0; DM_RENDER=''; DM_SCAN_WORK=''; DM_RENDER_PID=''
    [[ -t 0 && -t 1 ]] && DM_TTY=1
    : > "$DM_DIR/render.tsv"

    # Ctrl-C must not leave background workers running.
    trap '_dm_stop_all; _ui_term_restore; exit 130' INT
    if (( DM_TTY )); then clear 2>/dev/null || true; ui_cursor_hide; ui_keys_begin; fi

    local root=$HOME key pick
    local -i redraw=1 frame=0 leave=0

    _dm_recs_start
    _dm_scan "$root"
    (( DM_TTY )) || _dm_recs_wait
    _dm_recs_poll

    while (( ! leave )); do
        _dm_recs_poll && redraw=1
        if (( redraw )); then _dm_draw "$root"; redraw=0; fi

        # Not interactive: one static picture is all we can do.
        (( DM_TTY )) || { printf '\n'; break; }

        if (( ! DM_RECS_READY )); then
            _dm_recs_status "$frame"; _dm_bottom "$REPLY"; (( frame++ ))
        fi

        if ! ui_keys_poll; then
            ui_keys_lost && leave=1                         # no keyboard: go back instead of spinning
            continue
        fi
        redraw=1
        for key in "${UI_KEYS[@]}"; do
            case $key in
                [1-9])
                    [[ -n ${DM_TILE_PATHS[key]:-} ]] && { root=${DM_TILE_PATHS[key]}; _dm_scan "$root"; } ;;
                o|O)
                    (( ${#DM_OPEN_PATHS[@]} > 0 )) || continue
                    ui_keys_end                      # the menu reads keys its own way
                    clear 2>/dev/null || true
                    MENU_RESULT=${#DM_OPEN_PATHS[@]}
                    interactive_menu "Open which folder in $(_dm_tilde "$root")?" "${DM_OPEN_LABELS[@]}" "Cancel"
                    ui_cursor_hide; ui_keys_begin
                    pick=$MENU_RESULT
                    if (( pick < ${#DM_OPEN_PATHS[@]} )); then root=${DM_OPEN_PATHS[pick]}; _dm_scan "$root"; fi ;;
                u|U|LEFT|BACKSPACE)
                    if [[ $root != "$HOME" ]]; then root=${root%/*}; _dm_scan "$root"; fi ;;
                v|V)
                    [[ $DM_VIEW == category ]] && DM_VIEW=cleanup || DM_VIEW=category ;;
                r|R|c|C)
                    ui_keys_end                      # prompts and password entry need a normal terminal
                    ui_cursor_show
                    _dm_bottom ''; printf '\n'
                    _dm_recs_wait
                    if _dm_recommend; then
                        rm -f "$DM_DIR"/du_*
                        clear 2>/dev/null || true; ui_cursor_hide; ui_keys_begin
                        _dm_recs_start
                        _dm_scan "$root"
                    else
                        ui_cursor_hide; ui_keys_begin
                    fi ;;
                s|S)
                    rm -f "$(_dm_cache_file "$root")"
                    _dm_recs_start
                    _dm_scan "$root" ;;
                q|Q|b|B|ESC)
                    leave=1 ;;
            esac
            (( leave )) && break
        done
    done

    _dm_stop_all
    if (( DM_TTY )); then ui_keys_end; ui_cursor_show; _ui_wrap_on; fi
    trap '_ui_term_restore; exit 130' INT
    printf '\n'
    rm -rf "$DM_DIR"
}
