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
    if ! docker info &>/dev/null 2>&1; then
        step "[Docker]"; info "status  : daemon not running - start Docker Desktop and retry"; echo
        return 0
    fi

    # ── current footprint ────────────────────────────────────────────────────
    local -i n_all n_run n_img n_vol
    n_all=$(docker ps -aq      2>/dev/null | grep -c . || true)
    n_run=$(docker ps -q       2>/dev/null | grep -c . || true)
    n_img=$(docker images -aq  2>/dev/null | grep -c . || true)
    n_vol=$(docker volume ls -q 2>/dev/null | grep -c . || true)

    say "Current Docker footprint"
    info "containers : ${n_all} total (${n_run} running)"
    info "images     : ${n_img}"
    info "volumes    : ${n_vol}"
    local df
    df=$(docker system df 2>/dev/null) || true
    if [[ -n $df ]]; then
        info "reclaimable (docker system df):"
        while IFS= read -r _l; do info "  │ $_l"; done <<< "$df"
    fi
    echo

    if (( n_all == 0 && n_img == 0 && n_vol == 0 )); then
        ok "Docker is already empty - nothing to remove."
        echo; return 0
    fi

    # ── confirm (destructive) ─────────────────────────────────────────────────
    warn "This removes ALL containers and ALL images - they must be re-pulled/rebuilt."
    local do_volumes=0
    if [[ -t 0 ]]; then
        printf "  ${YLW}Remove all containers & images now? [y/N]: ${NC}"
        local answer; read -r answer
        if [[ $answer != [yY] ]]; then
            info "Cancelled - nothing removed."; echo; return 0
        fi
        printf "  ${YLW}Also remove ALL volumes (DELETES database data)? [y/N]: ${NC}"
        local vans; read -r vans
        [[ $vans == [yY] ]] && do_volumes=1
    elif [[ ${DOCKER_CLEAN_ASSUME_YES:-0} == 1 ]]; then
        info "non-interactive - DOCKER_CLEAN_ASSUME_YES=1, proceeding"
        [[ ${DOCKER_CLEAN_VOLUMES:-0} == 1 ]] && do_volumes=1
    else
        warn "non-interactive and no confirmation possible - skipping (set DOCKER_CLEAN_ASSUME_YES=1)"
        echo; return 0
    fi
    echo

    # ── run the teardown with a Docker-appropriate timeout ────────────────────
    #   Validate DOCKER_TIMEOUT before assigning into the integer CMD_TIMEOUT -
    #   a non-numeric value would abort the run under `set -u`.
    local -i _saved_to=$CMD_TIMEOUT
    local dto=${DOCKER_TIMEOUT:-300}
    [[ $dto =~ ^[0-9]+$ ]] || dto=300
    CMD_TIMEOUT=$dto

    run_step "stop all running containers" \
        'ids=$(docker ps -q); if [ -n "$ids" ]; then docker stop $ids; else echo "no running containers"; fi'

    run_step "remove all containers" \
        'ids=$(docker ps -aq); if [ -n "$ids" ]; then docker rm -f $ids; else echo "no containers"; fi'

    run_step "remove all images" \
        'ids=$(docker images -aq); if [ -n "$ids" ]; then docker rmi -f $ids; else echo "no images"; fi'

    run_step "prune networks + build cache" "docker system prune -af"
    run_step "prune builder cache"          "docker builder prune -af"

    if (( do_volumes == 1 )); then
        run_step "remove all unused volumes" "docker volume prune -af"
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
    ok "Docker full cleanup complete."
    echo
}
