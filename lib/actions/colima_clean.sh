#!/usr/bin/env bash
# =============================================================================
# § lib/actions/colima_clean.sh  ·  Delete Colima VMs and their data disks
#
#   DESTRUCTIVE - Colima is a second Docker runtime (a Lima VM). Many Macs end
#   up with both it and Docker Desktop, and the idle one keeps several GB:
#     • deletes every Colima profile (VM + its Docker images/containers/volumes)
#     • deletes leftover Lima data disks under ~/.colima/_lima/_disks
#       (`colima delete` without --data keeps them, so they linger)
#
#   Docker Desktop is never touched. Separate, opt-in action that always asks
#   first. Automation can opt in with COLIMA_CLEAN_ASSUME_YES=1.
#
#   Requires (sourced earlier): colors.sh, logging.sh, helpers.sh
#                               (run_step · dir_size_kb · human_size)
#   Public entry: colima_clean
# =============================================================================
colima_clean() {
    section "COLIMA - DELETE VMs + DATA DISKS"

    local colima_home="$HOME/.colima"
    local disks_dir="$colima_home/_lima/_disks"

    if ! command -v colima &>/dev/null && [[ ! -d $colima_home ]]; then
        skip_missing "Colima"
        return 0
    fi

    # ── footprint ──────────────────────────────────────────────────────────────
    local -a profiles=() disks=()
    local p d
    if command -v colima &>/dev/null; then
        while IFS= read -r p; do [[ -n $p ]] && profiles+=("$p"); done \
            < <(colima list -j 2>/dev/null | sed -n 's/.*"name":"\([^"]*\)".*/\1/p')
    fi
    if [[ -d $disks_dir ]]; then
        for d in "$disks_dir"/*/; do [[ -d $d ]] && { d=${d%/}; disks+=("${d##*/}"); }; done
    fi

    local -i total_kb=0
    [[ -d $colima_home ]] && total_kb=$(dir_size_kb "$colima_home")

    say "Current Colima footprint"
    info "folder   : ~/.colima  ($(human_size "$total_kb"))"
    if (( ${#profiles[@]} > 0 )); then
        local listing
        listing=$(colima list 2>/dev/null) || true
        while IFS= read -r _l; do info "  │ $_l"; done <<< "$listing"
    else
        info "profiles : none"
    fi
    if (( ${#disks[@]} > 0 )); then
        for d in "${disks[@]}"; do
            info "data disk: $d  ($(human_size "$(dir_size_kb "$disks_dir/$d")"))"
        done
    fi
    if command -v docker &>/dev/null; then
        info "docker   : current context is '$(docker context show 2>/dev/null || echo unknown)'"
    fi
    echo

    if (( ${#profiles[@]} == 0 && ${#disks[@]} == 0 )); then
        ok "No Colima VMs or data disks - nothing to remove."
        echo; return 0
    fi

    # ── confirm (destructive) ─────────────────────────────────────────────────
    warn "This deletes every Colima VM and ALL Docker data inside it (images, containers, volumes)."
    info "Docker Desktop is not affected."
    confirm_action "Delete all Colima VMs and data disks now?" COLIMA_CLEAN_ASSUME_YES || return 0

    local -i before_kb=$total_kb

    # ── 1. delete each profile together with its runtime data ─────────────────
    for p in ${profiles[@]+"${profiles[@]}"}; do
        run_step "delete Colima profile '$p'" "colima delete --force --data --profile '$p'"
    done

    # ── 2. leftover data disks (kept by an earlier delete without --data) ─────
    if [[ -d $disks_dir ]]; then
        for d in "$disks_dir"/*/; do
            [[ -d $d ]] || continue
            d=${d%/}; d=${d##*/}
            if command -v limactl &>/dev/null; then
                run_step "delete Lima data disk '$d'" \
                    "LIMA_HOME='$colima_home/_lima' limactl disk delete '$d'"
            else
                run_step "delete Lima data disk '$d'" "rm -rf '$disks_dir/$d'"
            fi
        done
    fi

    local -i after_kb=0 freed_kb
    [[ -d $colima_home ]] && after_kb=$(dir_size_kb "$colima_home")
    (( freed_kb = before_kb - after_kb )) || true
    (( freed_kb < 0 )) && freed_kb=0
    (( TOTAL_FREED_KB += freed_kb ))

    info "tip     : run 'colima start' to create a fresh VM if you need it again"
    ok "Colima cleanup complete - freed $(human_size "$freed_kb")."
    echo
}
