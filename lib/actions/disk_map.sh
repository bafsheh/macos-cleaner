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
DM_ROOT_KB=0            # size of the folder currently shown
DM_HOME_KB=0            # size of $HOME, once scanned
DM_TILE_PATHS=()        # tile number (1-9) → folder path
DM_OPEN_PATHS=()        # every openable top-level folder, largest first
DM_OPEN_LABELS=()

# Recommendation rows (parallel arrays, filled by _dm_recs_load).
REC_KEY=(); REC_STATUS=(); REC_KB=(); REC_LABEL=(); REC_SHOW=()

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

_dm_du() {   # ROOT OUT - two levels of folder sizes in KB, written atomically
    du -k -d 2 "$1" 2>/dev/null > "$2.part"
    mv "$2.part" "$2"
}

# Picks the tiles to draw from a du listing: up to 14 top-level folders (the
# rest merged into "N more"), up to 8 children each, plus loose files.
# Output TSV: kind id parent kb path label   (path "-" for merged tiles)
_dm_prepare() {
    sort -t "$(printf '\t')" -k1,1nr "$2" | awk -F'\t' -v root="$1" -v maxtop=14 -v maxkid=8 '
        function clean(s) { gsub(/[^ -~]+/, "?", s); gsub(/\t/, " ", s); return s }
        function add(lst, kb, path, label) { n = ++CNT[lst]; AK[lst, n] = kb; AP[lst, n] = path; AL[lst, n] = label }
        function sortlst(lst,   i, j, t1, t2, t3) {          # insertion sort, largest first
            for (i = 2; i <= CNT[lst]; i++)
                for (j = i; j > 1 && AK[lst, j] > AK[lst, j - 1]; j--) {
                    t1 = AK[lst, j]; AK[lst, j] = AK[lst, j - 1]; AK[lst, j - 1] = t1
                    t2 = AP[lst, j]; AP[lst, j] = AP[lst, j - 1]; AP[lst, j - 1] = t2
                    t3 = AL[lst, j]; AL[lst, j] = AL[lst, j - 1]; AL[lst, j - 1] = t3
                }
        }
        {
            kb = $1 + 0; p = $2
            if (p == root) { rootkb = kb; next }
            if (index(p, root "/") != 1) next
            rel = substr(p, length(root) + 2)
            n = split(rel, seg, "/")
            if (n == 1)      { T[++nt] = rel; TK[rel] = kb; sum += kb }
            else if (n == 2) { c = ++NC[seg[1]]; C[seg[1], c] = seg[2]; CK[seg[1], c] = kb }
        }
        END {
            hidden = 0; hiddenkb = 0
            for (i = 1; i <= nt; i++) {
                r = T[i]
                if (CNT["top"] < maxtop && TK[r] > 0 && TK[r] >= rootkb * 0.004) add("top", TK[r], root "/" r, clean(r))
                else { hidden++; hiddenkb += TK[r] }
            }
            files = rootkb - sum
            if (hiddenkb > 0 && hiddenkb >= rootkb * 0.004) add("top", hiddenkb, "-", hidden " more")
            if (files > 0 && files >= rootkb * 0.004)       add("top", files, "-", "files")
            sortlst("top")
            id = 0
            for (i = 1; i <= CNT["top"]; i++) {
                pid = ++id
                printf "1\t%d\t0\t%d\t%s\t%s\n", pid, AK["top", i], AP["top", i], AL["top", i]
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
                    printf "2\t%d\t%d\t%d\t%s\t%s\n", ++id, pid, AK[lst, j], AP[lst, j], AL[lst, j]
            }
            printf "0\t0\t0\t%d\t-\t-\n", rootkb
        }'
}

# Scans ROOT (cached), classifies every tile and writes $DM_DIR/render.tsv.
_dm_scan() {
    local root=$1 cache
    cache=$(_dm_cache_file "$root")
    if [[ ! -s $cache ]]; then
        spinner_run "Measuring $(_dm_tilde "$root")  (first scan can take a minute)" _dm_du "$root" "$cache"
    fi

    local -a kind=() id=() par=() kb=() path=() label=() cat=() st=()
    local k i p l pa b
    local -i n=0
    DM_ROOT_KB=0
    while IFS=$'\t' read -r k i pa b p l; do
        if [[ $k == 0 ]]; then DM_ROOT_KB=$b; continue; fi
        kind[n]=$k; id[n]=$i; par[n]=$pa; kb[n]=$b; path[n]=$p; label[n]=$l
        (( n++ ))
    done < <(_dm_prepare "$root" "$cache")
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
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "${kind[j]}" "${id[j]}" "${par[j]}" "${kb[j]}" \
            "${cat[j]}" "${st[j]}" "${label[j]}" "$shown" >> "$DM_DIR/render.tsv"
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

_dm_recs_load() {
    local f="$DM_DIR/recs.tsv"
    [[ -s $f ]] || spinner_run "Looking for space you can safely reclaim" _dm_recs_measure "$f"
    REC_KEY=(); REC_STATUS=(); REC_KB=(); REC_LABEL=(); REC_SHOW=()
    local k s b l w
    while IFS=$'\t' read -r k s b l w; do
        REC_KEY+=("$k"); REC_STATUS+=("$s"); REC_KB+=("$b"); REC_LABEL+=("$l"); REC_SHOW+=("$w")
    done < "$f"
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
# =============================================================================
_dm_draw() {
    local root=$1
    local -i cols lines W H
    cols=$(tput cols 2>/dev/null || echo 100); lines=$(tput lines 2>/dev/null || echo 32)
    (( cols < 40 )) && cols=100; (( lines < 16 )) && lines=32
    W=$(( cols - 3 )); (( W > 220 )) && W=220
    H=$(( lines - 9 ))

    local mode=plain
    if (( _COLOR )); then (( _TRUECOLOR )) && mode=truecolor || mode=256; fi

    _dm_rec_totals
    local -i sk sn rk rn avail used
    read -r sk sn rk rn <<< "$REPLY"
    avail=$(disk_avail_kb)
    used=$(df -k / | awk 'NR==2 {print $2 - $4}')

    [[ -t 1 ]] && { clear 2>/dev/null || true; }
    printf "  ${ACCENT}${BOLD}Disk map${NC}  ${WHT}%s${NC}   ${DIM}%s in this folder · %s view${NC}\n" \
        "$(_dm_tilde "$root")" "$(_dm_fmt "$DM_ROOT_KB")" "$DM_VIEW"

    local c1 c2 c3 c4 v1 v2 v3 v4
    c1="Free after cleanup"; v1="$(_dm_fmt $(( avail + sk )))  +$(_dm_fmt "$sk")"
    c2="Safe to remove";     v2="$(_dm_fmt "$sk")  ${sn} items"
    c3="Needs review";       v3="$(_dm_fmt "$rk")  ${rn} items"
    c4="Not scanned";        v4="-"
    (( DM_HOME_KB > 0 && used > DM_HOME_KB )) && v4="$(_dm_fmt $(( used - DM_HOME_KB )))  system & apps"
    printf "  ${DIM}%-24s${NC}${BGRN}●${NC} ${DIM}%-22s${NC}${ORG}●${NC} ${DIM}%-22s${NC}${DIM}%s${NC}\n" \
        "$c1" "$c2" "$c3" "$c4"
    printf "  ${BOLD}%-24s${NC}  ${BOLD}%-22s${NC}  ${BOLD}%-22s${NC}${BOLD}%s${NC}\n" "$v1" "$v2" "$v3" "$v4"
    printf '\n'

    awk -v W="$W" -v H="$H" -v mode="$mode" -v view="$DM_VIEW" -f "$LIB_DIR/diskmap.awk" "$DM_DIR/render.tsv"

    [[ -t 0 && -t 1 ]] || return 0
    printf "\n  ${DIM}1-9 open tile · o open any · u up · v %s view · r recommendations & clean · s rescan · q back${NC}" \
        "$([[ $DM_VIEW == category ]] && echo cleanup || echo category)"
}

# =============================================================================
# § run_disk_map  (main-menu entry)
# =============================================================================
run_disk_map() {
    DM_DIR=$(mktemp -d "${TMPDIR:-/tmp}/mac_cleaner_map.XXXXXX") || { fail "could not create a temp folder"; return 1; }
    DM_VIEW=category; DM_HOME_KB=0
    local root=$HOME key seq pick

    _dm_scan "$root"
    _dm_recs_load

    while true; do
        _dm_draw "$root"

        # Not interactive: one static picture is all we can do.
        if [[ ! -t 0 || ! -t 1 ]]; then printf '\n'; break; fi

        IFS= read -rsn1 key
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
                pick=$MENU_RESULT
                if (( pick < ${#DM_OPEN_PATHS[@]} )); then root=${DM_OPEN_PATHS[pick]}; _dm_scan "$root"; fi ;;
            u|U|$'\x1b[D'|$'\x7f')
                if [[ $root != "$HOME" ]]; then root=${root%/*}; _dm_scan "$root"; fi ;;
            v|V)
                [[ $DM_VIEW == category ]] && DM_VIEW=cleanup || DM_VIEW=category ;;
            r|R|c|C)
                if _dm_recommend; then
                    rm -f "$DM_DIR"/du_* "$DM_DIR/recs.tsv"
                    _dm_scan "$root"; _dm_recs_load
                fi ;;
            s|S)
                rm -f "$(_dm_cache_file "$root")" "$DM_DIR/recs.tsv"
                _dm_scan "$root"; _dm_recs_load ;;
            q|Q|b|B|$'\x1b')
                break ;;
        esac
    done

    printf '\n'
    rm -rf "$DM_DIR"
}
