#!/usr/bin/env bash
# =============================================================================
# § lib/actions/ollama_clean.sh  ·  Full Ollama / llama cleanup
#
#   DESTRUCTIVE - removes downloaded model weights, not just caches:
#     • every Ollama model (via `ollama rm`, then the on-disk model store)
#     • Ollama cache / logs / history
#     • Meta llama (llama-stack) checkpoints under ~/.llama, if present
#
#   The safe "Clean up" run deliberately PRESERVES these weights; this is a
#   separate, opt-in action and always requires confirmation. Automation can
#   opt in with OLLAMA_CLEAN_ASSUME_YES=1.
#
#   Note: llama.cpp / llamafile keep no standard global model directory - their
#   .gguf files live wherever you put them, so they can't be safely auto-wiped.
#
#   Requires (sourced earlier): colors.sh, logging.sh, helpers.sh
#                               (clean_dir · dir_size_kb · human_size)
#   Public entry: ollama_clean
# =============================================================================
ollama_clean() {
    section "OLLAMA / LLAMA - FULL CLEANUP (models + caches)"

    local ollama_dir="$HOME/.ollama"
    local models_dir="$ollama_dir/models"
    local llama_dir="$HOME/.llama"

    local -i has_ollama=0 has_store=0 has_llama=0
    command -v ollama &>/dev/null && has_ollama=1
    [[ -d $models_dir ]] && has_store=1
    [[ -d $llama_dir ]]  && has_llama=1

    if (( has_ollama == 0 && has_store == 0 && has_llama == 0 )); then
        skip_missing "Ollama / llama"
        return 0
    fi

    # ── footprint ──────────────────────────────────────────────────────────────
    local -i weights_kb=0
    [[ -d $models_dir ]] && weights_kb=$(dir_size_kb "$models_dir")
    say "Current model footprint"
    info "model store : ${models_dir}"
    info "weights     : $(human_size "$weights_kb")"
    [[ -d $llama_dir ]] && info "llama dir   : ${llama_dir}  ($(human_size "$(dir_size_kb "$llama_dir")"))"

    if (( has_ollama == 1 )); then
        local listing
        listing=$(ollama list 2>/dev/null | awk 'NR>1 && NF { print "  • " $1 "  (" $3 " " $4 ")" }') || true
        if [[ -n $listing ]]; then
            info "installed models:"
            while IFS= read -r _l; do info "$_l"; done <<< "$listing"
        fi
    fi
    echo

    # ── confirm (destructive) ─────────────────────────────────────────────────
    warn "This DELETES all downloaded model weights - they must be re-pulled."
    if [[ -t 0 ]]; then
        printf "  ${YLW}Remove ALL Ollama/llama models & caches now? [y/N]: ${NC}"
        local answer; read -r answer
        if [[ $answer != [yY] ]]; then
            info "Cancelled - nothing removed."; echo; return 0
        fi
    elif [[ ${OLLAMA_CLEAN_ASSUME_YES:-0} == 1 ]]; then
        info "non-interactive - OLLAMA_CLEAN_ASSUME_YES=1, proceeding"
    else
        warn "non-interactive and no confirmation possible - skipping (set OLLAMA_CLEAN_ASSUME_YES=1)"
        echo; return 0
    fi
    echo

    # ── 1. graceful per-model removal (keeps the daemon's index consistent) ───
    if (( has_ollama == 1 )); then
        local -a models=()
        local m
        while IFS= read -r m; do [[ -n $m ]] && models+=("$m"); done \
            < <(ollama list 2>/dev/null | awk 'NR>1 && NF {print $1}')

        if (( ${#models[@]} > 0 )); then
            say "Removing ${#models[@]} Ollama model(s) via 'ollama rm'"
            local -i removed=0
            for m in "${models[@]}"; do
                if ollama rm "$m" &>/dev/null; then
                    (( removed++ )); ok "removed model: $m"
                else
                    (( TOTAL_FAILED++ )); warn "could not remove via ollama: $m"
                fi
            done
            (( TOTAL_CLEANED += removed ))
            echo
        else
            info "ollama list returned no models (daemon stopped?) - wiping store directly"
            echo
        fi
    fi

    # ── 2. wipe the on-disk store + caches (catches any residue / stopped daemon)
    clean_dir "$models_dir"           "Ollama model store (weights/blobs)"
    clean_dir "$ollama_dir/cache"     "Ollama cache"
    clean_dir "$ollama_dir/logs"      "Ollama logs"
    clean_dir "$HOME/Library/Logs/Ollama" "Ollama logs (Library)"

    if [[ -f $ollama_dir/history ]]; then
        if rm -f "$ollama_dir/history" 2>/dev/null; then
            (( TOTAL_CLEANED++ )); ok "removed Ollama prompt history"
        else
            warn "could not remove Ollama history"
        fi
        echo
    fi

    # ── 3. Meta llama (llama-stack) checkpoints ───────────────────────────────
    if [[ -d $llama_dir ]]; then
        clean_dir "$llama_dir/checkpoints" "Meta llama checkpoints"
        clean_dir "$llama_dir"             "Meta llama dir (~/.llama)"
    fi

    info "tip     : restart the Ollama app/daemon so it rebuilds a clean index"
    info "note    : llama.cpp/.gguf files are user-placed and were NOT touched"
    ok "Ollama / llama full cleanup complete."
    echo
}
