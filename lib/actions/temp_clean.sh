#!/usr/bin/env bash
# =============================================================================
# § lib/actions/temp_clean.sh  ·  Temporary-file cleanup
#
#   Removes temp files and folders nothing has touched for TEMP_AGE_DAYS days
#   (default 3) from:
#     • your private temp folder ($TMPDIR, under /var/folders)
#     • old Claude Code session folders (/private/tmp/claude-<uid>/…) - these
#       hold task output and can grow to many GB
#     • the shared /private/tmp and /private/var/tmp (sudo, if you allow it;
#       otherwise only items you own)
#
#   Each item is judged as a whole (see stale_entries in helpers.sh): sockets,
#   launchd/ssh-agent/tmux session folders, and anything touched recently are
#   kept, so running apps and terminals are never disturbed.
#
#   Requires (sourced earlier): colors.sh, core.sh, logging.sh, helpers.sh
#   Public entries: clean_temp (menu action) · temp_purge_all (shared with
#                   run_clean § 31)
# =============================================================================

# Your private temp dir, without the trailing slash macOS puts on $TMPDIR.
_user_tmpdir() {
    local t=${TMPDIR:-$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null)}
    printf '%s' "${t%/}"
}

# =============================================================================
# § temp_purge_all [prompt]
#
#   Runs every temp sweep. With "prompt" it may ask for your password to
#   include other users' / root's stale items in the shared folders; without
#   it, sudo is used only if already granted earlier in this run.
# =============================================================================
temp_purge_all() {
    local want_prompt="${1:-}" sudo_prefix=''

    purge_stale "Your temp folder (\$TMPDIR)" "$(_user_tmpdir)" 1
    purge_stale "Old Claude Code session folders" "/private/tmp/claude-$(id -u)" 2

    if sudo -n true 2>/dev/null; then
        sudo_prefix=sudo
    elif [[ $want_prompt == prompt && -t 0 ]]; then
        printf "  ${YLW}Also remove stale root-owned items in /private/tmp (needs your password)? [y/N]: ${NC}"
        local answer; read -r answer
        [[ $answer == [yY] ]] && sudo -v && sudo_prefix=sudo
        echo
    fi
    [[ -z $sudo_prefix ]] && info "no sudo - only your own items in the shared folders are removed" && echo

    purge_stale "Shared temp (/private/tmp)"     "/private/tmp"     1 "$sudo_prefix"
    purge_stale "Shared temp (/private/var/tmp)" "/private/var/tmp" 1 "$sudo_prefix"
}

# =============================================================================
# § clean_temp  (menu action)
# =============================================================================
clean_temp() {
    section "TEMPORARY FILES"

    local -i freed_before=$TOTAL_FREED_KB
    say "Removing temp items untouched for ${TEMP_AGE_DAYS}+ days (in-use items are kept)"
    info "tip     : TEMP_AGE_DAYS=1 ./mac_cleaner.sh for a more aggressive sweep"
    echo

    temp_purge_all prompt

    ok "Temporary files: $(human_size $(( TOTAL_FREED_KB - freed_before ))) freed."
    echo
}
