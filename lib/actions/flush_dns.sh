#!/usr/bin/env bash
# =============================================================================
# § lib/actions/flush_dns.sh  ·  Flush the macOS DNS cache
#
#   Clears the system resolver cache and signals mDNSResponder to reload, the
#   standard fix for stale DNS entries after a network/host change.
#   Both commands require sudo (the user is prompted by sudo itself).
#
#   Requires (sourced earlier): logging.sh, helpers.sh (run_step)
#   Public entry: flush_dns
# =============================================================================
flush_dns() {
    section "FLUSH DNS CACHE"

    say "Flushing the system DNS resolver cache"
    run_step "flush directory-service cache" "sudo dscacheutil -flushcache"
    run_step "restart mDNSResponder"         "sudo killall -HUP mDNSResponder"

    ok "DNS cache flushed"
    echo
}
