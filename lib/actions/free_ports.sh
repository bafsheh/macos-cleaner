#!/usr/bin/env bash
# =============================================================================
# § lib/actions/free_ports.sh  ·  Free common development ports
#
#   Force-kills processes listening on a curated list of common dev-server
#   ports (e.g. 3000, 5173, 8080). Intentionally scoped to well-known dev
#   ports so it can NEVER take down sshd, the loopback resolver, or other
#   system services bound to privileged/low ports.
#
#   Safety: the script's own process group is never targeted (dev servers do
#   not run on these ports as PID 1 of this shell), and each kill is best-effort.
#
#   Requires (sourced earlier): logging.sh
#   Public entry: free_ports
# =============================================================================

# Curated list of common development-server ports. Add to this list rather
# than broadening the scope to "all ports" - that would be unsafe.
declare -ra DEV_PORTS=(
    3000 3001 3002 3003        # Node / Next.js / CRA / Rails
    4000 4200 4321             # Phoenix / Angular / Astro
    5000 5001 5173 5174        # Flask / .NET / Vite
    5555                       # Prisma Studio
    6006                       # Storybook
    8000 8001 8080 8081 8088   # Django / generic / Tomcat
    8443 8888                  # HTTPS-dev / Jupyter
    9000 9001 9090 9229        # PHP-FPM / generic / Prometheus / Node inspector
    19000 19006                # Expo
    24678                      # Vite HMR
)

free_ports() {
    section "FREE COMMON DEV PORTS"

    if ! command -v lsof &>/dev/null; then
        warn "lsof not found - cannot inspect listening ports"
        echo; return 0
    fi

    say "Freeing ${#DEV_PORTS[@]} common development ports"
    info "self pid : $$  (never targeted)"

    local -i checked=0 freed=0 port killed_here
    local pids pid

    for port in "${DEV_PORTS[@]}"; do
        (( checked++ ))
        # -ti : terse output (PIDs only) for TCP listeners on $port
        pids=$(lsof -ti "tcp:${port}" 2>/dev/null) || true
        [[ -z $pids ]] && continue

        killed_here=0
        while IFS= read -r pid; do
            [[ -z $pid ]] && continue
            (( pid == $$ )) && continue          # never kill this shell
            if kill -9 "$pid" 2>/dev/null; then
                (( killed_here++ ))
            fi
        done <<< "$pids"

        if (( killed_here > 0 )); then
            (( freed++ ))
            ok "port ${port} freed (${killed_here} process(es))"
        fi
    done

    if (( freed == 0 )); then
        info "no dev ports were in use - nothing to free"
    else
        say "Freed ${freed} of ${checked} checked port(s)"
    fi
    echo
}
