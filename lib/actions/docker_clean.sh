#!/usr/bin/env bash
# =============================================================================
# § lib/actions/docker_clean.sh  ·  Full Docker teardown
#
#   DESTRUCTIVE - removes EVERYTHING Docker is holding locally:
#     • stops then removes ALL containers (running and stopped)
#     • removes ALL images (not just dangling)
#     • prunes networks and the entire build cache
#     • OPTIONALLY removes ALL volumes (opt-in - volumes hold database data)
#
#   This is intentionally a separate, opt-in menu action (not part of the safe
#   "Clean up" run) and always requires confirmation. Automation can opt in
#   with DOCKER_CLEAN_ASSUME_YES=1 (and DOCKER_CLEAN_VOLUMES=1 for volumes).
#
#   Docker image removal can take a while, so commands run with a generous
#   timeout (override with DOCKER_TIMEOUT, default 300s).
#
#   Requires (sourced earlier): colors.sh, logging.sh, helpers.sh (run_step),
#                               core.sh (CMD_TIMEOUT)
#   Public entry: docker_clean
# =============================================================================
docker_clean() {
    section "DOCKER - FULL CLEANUP (containers + images)"

    if ! command -v docker &>/dev/null; then
        skip_missing "Docker"
        return 0
    fi
    if ! docker_ready; then
        step "[Docker]"
        info "status  : daemon not running or not answering - start Docker Desktop and retry"
        echo
        return 0
    fi

    # ── current footprint ────────────────────────────────────────────────────
    #   An image with several tags is listed once per tag - count unique IDs.
    local -i n_all n_run n_img n_vol
    n_all=$(docker ps -aq      2>/dev/null | grep -c . || true)
    n_run=$(docker ps -q       2>/dev/null | grep -c . || true)
    n_img=$(docker images -aq  2>/dev/null | sort -u | grep -c . || true)
    n_vol=$(docker volume ls -q 2>/dev/null | grep -c . || true)

    say "Current Docker footprint"
    info "containers : ${n_all} total (${n_run} running)"
    info "images     : ${n_img}"
    info "volumes    : ${n_vol}"
    local df cache_size
    df=$(docker system df 2>/dev/null) || true
    if [[ -n $df ]]; then
        info "reclaimable (docker system df):"
        while IFS= read -r _l; do info "  │ $_l"; done <<< "$df"
    fi
    # "Build Cache  <total> <active> <size> <reclaimable>" → the SIZE column
    cache_size=$(awk '/^Build Cache/ {print $5; exit}' <<< "$df")
    echo

    if (( n_all == 0 && n_img == 0 && n_vol == 0 )) && [[ -z $cache_size || $cache_size == 0B ]]; then
        ok "Docker is already empty - nothing to remove."
        echo; return 0
    fi

    # ── confirm (destructive) ─────────────────────────────────────────────────
    warn "This removes ALL containers and ALL images - they must be re-pulled/rebuilt."
    confirm_action "Remove all containers & images now?" DOCKER_CLEAN_ASSUME_YES || return 0

    # Volumes are a second, separate opt-in (DOCKER_CLEAN_VOLUMES=1 for scripts).
    local do_volumes=0
    if [[ -t 0 ]]; then
        printf "  ${YLW}Also remove ALL volumes (DELETES database data)? [y/N]: ${NC}"
        local vans; read -r vans
        [[ $vans == [yY] ]] && do_volumes=1
        echo
    elif [[ ${DOCKER_CLEAN_VOLUMES:-0} == 1 ]]; then
        do_volumes=1
    fi

    # ── run the teardown with a Docker-appropriate timeout ────────────────────
    #   Validate DOCKER_TIMEOUT before assigning into the integer CMD_TIMEOUT -
    #   a non-numeric value would abort the run under `set -u`.
    local -i _saved_to=$CMD_TIMEOUT
    local dto=${DOCKER_TIMEOUT:-300}
    [[ $dto =~ ^[0-9]+$ ]] || dto=300
    CMD_TIMEOUT=$dto

    local -i host_before_kb vm_before_kb
    host_before_kb=$(disk_avail_kb)
    vm_before_kb=$(_docker_vm_disk_kb)

    run_step "stop all running containers" \
        'ids=$(docker ps -q); if [ -n "$ids" ]; then docker stop $ids; else echo "no running containers"; fi'

    run_step "remove all containers" \
        'ids=$(docker ps -aq); if [ -n "$ids" ]; then docker rm -f $ids; else echo "no containers"; fi'

    # sort -u: a multi-tag image is listed once per tag, and `docker rmi`
    # fails on the second copy of an ID it has already removed.
    run_step "remove all images" \
        'ids=$(docker images -aq | sort -u); if [ -n "$ids" ]; then docker rmi -f $ids; else echo "no images"; fi'

    run_step "prune networks + build cache" "docker system prune -af"
    run_step "prune builder cache"          "docker builder prune -af"

    if (( do_volumes == 1 )); then
        # -a (named volumes too) needs Docker 23+; older CLIs reject it.
        run_step "remove all unused volumes" \
            "docker volume prune -af 2>/dev/null || docker volume prune -f"
    else
        step "[Docker volumes]"
        info "status  : kept (named volumes / database data preserved)"
        echo
    fi

    CMD_TIMEOUT=$_saved_to

    # ── after ─────────────────────────────────────────────────────────────────
    df=$(docker system df 2>/dev/null) || true
    if [[ -n $df ]]; then
        say "Docker footprint after cleanup"
        while IFS= read -r _l; do info "  │ $_l"; done <<< "$df"
    fi

    # ── space back on the Mac ───────────────────────────────────────────────
    #   Images live inside the Docker VM's disk file. Docker Desktop hands the
    #   freed blocks back to macOS in the background, so the Mac's free space
    #   can keep rising for a few minutes after this step.
    local -i host_after_kb vm_after_kb freed_kb
    host_after_kb=$(disk_avail_kb)
    vm_after_kb=$(_docker_vm_disk_kb)
    (( freed_kb = host_after_kb - host_before_kb )) || true
    (( freed_kb < 0 )) && freed_kb=0
    (( TOTAL_FREED_KB += freed_kb ))
    info "Mac free space : +$(human_size $freed_kb) so far"
    if (( vm_before_kb > 0 )); then
        info "Docker VM disk : $(human_size $vm_before_kb) → $(human_size $vm_after_kb) on disk"
        info "note    : Docker Desktop returns freed space to macOS gradually;"
        info "          check again in a few minutes, or restart Docker Desktop."
    fi
    ok "Docker full cleanup complete."
    echo
}

# Space the Docker Desktop VM disk file really uses on the Mac, in KB (0 when
# there is none, e.g. Colima or OrbStack). `du` counts allocated blocks, not
# the sparse file's much larger apparent size.
_docker_vm_disk_kb() {
    local f
    for f in "$HOME/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw" \
             "$HOME/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.qcow2"; do
        [[ -f $f ]] && { du -k "$f" 2>/dev/null | awk '{print $1+0}'; return; }
    done
    printf '0'
}
