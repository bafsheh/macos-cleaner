#!/usr/bin/env bash
# =============================================================================
# § lib/actions/free_memory.sh  ·  Free up inactive / cached RAM
#
#   macOS aggressively caches files in otherwise-idle RAM; `purge` forces the
#   kernel to flush that disk cache and return inactive pages to the free pool.
#   This is the supported, non-destructive way to "free memory" on macOS — it
#   never kills user processes, it just drops reclaimable caches.
#
#   The action reports a memory snapshot before and after so the effect is
#   visible, then runs `sudo purge` (the user is prompted by sudo itself).
#
#   Requires (sourced earlier): colors.sh, logging.sh, helpers.sh (human_size)
#   Public entry: free_memory
# =============================================================================

# ── _mem_report WHEN ─────────────────────────────────────────────────────────
#   Prints a one-line free/reclaimable RAM estimate derived from vm_stat.
#   "free"        ≈ truly free + speculative pages
#   "reclaimable" ≈ free + inactive + speculative + purgeable pages
_mem_report() {
    local when="$1"
    command -v vm_stat &>/dev/null || { info "${when} : vm_stat unavailable"; return; }

    local raw ps
    raw=$(vm_stat 2>/dev/null)
    ps=$(printf '%s\n' "$raw" | sed -n 's/.*page size of \([0-9]*\) bytes.*/\1/p')
    [[ $ps =~ ^[0-9]+$ ]] || ps=4096

    # Pull each counter; strip the trailing '.' vm_stat appends.
    local -i pf pin psp ppg
    pf=$(printf  '%s\n' "$raw" | awk '/Pages free/         {gsub(/\./,"",$3); print $3+0; exit}')
    pin=$(printf '%s\n' "$raw" | awk '/Pages inactive/     {gsub(/\./,"",$3); print $3+0; exit}')
    psp=$(printf '%s\n' "$raw" | awk '/Pages speculative/  {gsub(/\./,"",$3); print $3+0; exit}')
    ppg=$(printf '%s\n' "$raw" | awk '/Pages purgeable/    {gsub(/\./,"",$3); print $3+0; exit}')

    local -i free_kb=$(( (pf + psp) * ps / 1024 ))
    local -i reclaim_kb=$(( (pf + pin + psp + ppg) * ps / 1024 ))
    info "$when : free ~$(human_size "$free_kb")  ·  reclaimable ~$(human_size "$reclaim_kb")"
}

free_memory() {
    section "FREE UP MEMORY (RAM)"

    if ! command -v purge &>/dev/null; then
        warn "purge not found — cannot free memory on this system"
        echo; return 0
    fi

    say "Releasing inactive & cached memory back to the kernel"
    info "note    : purge only drops reclaimable caches — it never quits your apps"

    # Bonus: overall free percentage if memory_pressure is available.
    if command -v memory_pressure &>/dev/null; then
        local mp
        mp=$(memory_pressure 2>/dev/null | awk -F': ' '/free percentage/ {print $2; exit}')
        [[ -n $mp ]] && info "pressure: system-wide memory free ${mp}"
    fi

    _mem_report "before"

    # purge requires root; mirror the sudo handling used by the system-cache step.
    if sudo -n true 2>/dev/null || sudo -v; then
        step "[Purge inactive memory]"
        info "cmd     : sudo purge"
        local -i t0 t1 rc=0
        t0=$(date +%s)
        sudo purge 2>/dev/null || rc=$?
        t1=$(date +%s)
        info "elapsed : $(( t1 - t0 ))s   exit: ${rc}"
        if (( rc == 0 )); then
            (( TOTAL_CLEANED++ ))
            ok "released inactive memory back to the kernel"
        else
            (( TOTAL_FAILED++ ))
            fail "purge failed (exit=${rc})"
        fi
        echo
        _mem_report "after "
    else
        warn "no sudo access — skipping (purge requires root)"
    fi

    echo
}
