#!/usr/bin/env bash
# =============================================================================
# § lib/ui/term.sh  ·  Terminal state, size, and keyboard input
#
#   Single responsibility: everything that talks to the terminal device itself.
#   The widgets build on these and never emit raw mode changes on their own.
#
#     ui_cursor_hide / ui_cursor_show   cursor visibility
#     ui_alt_screen_on / _off           the terminal's alternate screen
#     _ui_wrap_off / _ui_wrap_on        automatic line-wrap (see below)
#     _ui_term_restore                  put everything back (also on Ctrl-C)
#     ui_term_size                      → UI_COLS, UI_LINES
#     ui_keys_begin / ui_keys_end       enter / leave key-polling mode
#     ui_keys_poll                      wait ≤ 0.1 s for keys → UI_KEYS
#     ui_keys_lost                      has the keyboard gone away?
#
#   Raw escape sequences are used instead of tput: no fork per call, and they
#   work even where the terminfo database is thin. All of them are no-ops
#   unless stdout is a terminal.
#
#   Requires (sourced earlier): colors.sh, core.sh
# =============================================================================

UI_COLS=100             # terminal width,  refreshed by ui_term_size
UI_LINES=32             # terminal height, refreshed by ui_term_size
UI_KEYS=()              # keys read by the last ui_keys_poll
_UI_STTY_SAVED=''       # tty settings to put back when polling mode ends
declare -i _UI_KEYS_DEPTH=0     # how many ui_keys_begin calls are open
declare -i _UI_KEYS_FAILS=0     # polls in a row that found stdin is no terminal
_UI_ALT_SCREEN=0        # 1 while the alternate screen is active

# ── cursor visibility ────────────────────────────────────────────────────────
ui_cursor_hide() { [[ -t 1 ]] && printf '\033[?25l'; return 0; }
ui_cursor_show() { [[ -t 1 ]] && printf '\033[?25h'; return 0; }

# =============================================================================
# § ui_alt_screen_on / ui_alt_screen_off
#
#   Full-screen widgets draw on the terminal's alternate screen, so whatever
#   was on screen before (the menu, earlier output) is back when they close.
#
#   Globals:
#     writes _UI_ALT_SCREEN
# =============================================================================
ui_alt_screen_on()  { [[ -t 1 ]] && { printf '\033[?1049h\033[H'; _UI_ALT_SCREEN=1; }; return 0; }
ui_alt_screen_off() { (( _UI_ALT_SCREEN )) && printf '\033[?1049l'; _UI_ALT_SCREEN=0; return 0; }

# =============================================================================
# § line-wrap control  (fixes the "menu walks down the screen" glitch)
#
#   The widgets redraw by moving the cursor up exactly one line per row and
#   repainting. That math is only correct when every row occupies a single
#   physical line. A label wider than the window would wrap onto a second
#   line, the cursor-up would land too low, and each keypress would repaint a
#   fresh copy below the old one - the menu appears to repeat.
#
#   So automatic line-wrap is turned OFF (DECAWM, ESC[?7l) while a widget is on
#   screen: an over-long row is cut at the right edge instead of wrapping.
#   Restored (ESC[?7h) on exit.
# =============================================================================
_ui_wrap_off() { [[ -t 1 ]] && printf '\033[?7l'; return 0; }
_ui_wrap_on()  { [[ -t 1 ]] && printf '\033[?7h'; return 0; }

# =============================================================================
# § _ui_term_restore
#
#   Safety net: restores the terminal (tty modes, alternate screen, line-wrap,
#   cursor) on ANY exit, including Ctrl-C in the middle of a widget. The widgets restore
#   inline on a normal return; this covers the paths they cannot reach, so a
#   raw-mode tty or a hidden cursor never leaks into the user's shell.
#
#   Globals:
#     reads/writes _UI_STTY_SAVED, _UI_ALT_SCREEN
# =============================================================================
_ui_term_restore() {
    if [[ -n $_UI_STTY_SAVED ]]; then
        stty "$_UI_STTY_SAVED" 2>/dev/null < /dev/tty
        _UI_STTY_SAVED='' _UI_KEYS_DEPTH=0
    fi
    [[ -t 1 ]] || return 0
    ui_alt_screen_off
    printf '\033[?7h\033[?25h'
}
# EXIT is handled by _mc_on_exit (core.sh), which calls _ui_term_restore and
# removes the scratch folder. HUP (the terminal window was closed) must exit
# through it too, or the scratch folder would be left behind.
trap '_ui_term_restore; exit 130' INT
trap '_ui_term_restore; exit 143' TERM
trap '_ui_term_restore; exit 129' HUP

# =============================================================================
# § ui_term_size
#
#   Reads the window size from the terminal device itself: inside $(…) with
#   stderr silenced, tput sees no terminal at all and falls back to 80 columns.
#
#   Globals:
#     writes UI_COLS, UI_LINES   (sane defaults when there is no terminal)
# =============================================================================
ui_term_size() {
    local size
    size=$(stty size 2>/dev/null < /dev/tty) || size=''
    if [[ $size =~ ^([1-9][0-9]*)\ ([1-9][0-9]*)$ ]]; then
        UI_LINES=${BASH_REMATCH[1]}; UI_COLS=${BASH_REMATCH[2]}
    else
        UI_COLS=100; UI_LINES=32
    fi
    (( UI_COLS < 40 )) && UI_COLS=40
    (( UI_LINES < 12 )) && UI_LINES=12
    return 0
}

# =============================================================================
# § ui_keys_begin / ui_keys_end
#
#   Key-polling mode lets a widget animate while it waits for the keyboard.
#   bash 3.2 (the macOS system bash) cannot wait a fraction of a second for a
#   key - `read -t` takes whole seconds only. Instead the terminal itself is
#   told to give up a read after 0.1 s (stty min 0 time 1); a plain `read`
#   then returns either the keys typed so far or nothing.
#
#   The two calls nest: a widget that polls keys may call another one that
#   does (the disk map opens a scan); only the outermost ui_keys_end puts the
#   terminal back. Leave polling mode before any ordinary `read` prompt - a
#   line read would time out after 0.1 s like every other read.
#
#   Returns:
#     ui_keys_begin: 0 when polling mode is on, 1 when stdin is not a terminal
# =============================================================================
ui_keys_begin() {
    [[ -t 0 ]] || return 1
    if (( _UI_KEYS_DEPTH > 0 )); then (( _UI_KEYS_DEPTH++ )); return 0; fi
    _UI_STTY_SAVED=$(stty -g 2>/dev/null) || { _UI_STTY_SAVED=''; return 1; }
    stty -icanon -echo min 0 time 1 2>/dev/null
    _UI_KEYS_DEPTH=1 _UI_KEYS_FAILS=0
}

ui_keys_end() {
    (( _UI_KEYS_DEPTH > 1 )) && { (( _UI_KEYS_DEPTH-- )); return 0; }
    [[ -n $_UI_STTY_SAVED ]] && stty "$_UI_STTY_SAVED" 2>/dev/null
    _UI_STTY_SAVED='' _UI_KEYS_DEPTH=0
    return 0
}

# =============================================================================
# § ui_keys_poll
#
#   Waits up to 0.1 s for input (ui_keys_begin must be active).
#
#   A loop built on this must not be able to run away. If stdin stops being a
#   terminal (it was closed, or lost to a failed redirection) the read returns
#   at once instead of after 0.1 s; that is counted, the 0.1 s is waited here
#   instead, and after a few such polls ui_keys_lost tells the caller to end
#   its loop.
#
#   Globals:
#     writes UI_KEYS   the keys pressed, in order (see _ui_keys_parse)
#   Returns:
#     0 if at least one key arrived, 1 if the wait timed out
# =============================================================================
ui_keys_poll() {
    local buf=''
    UI_KEYS=()
    # `read` fails at the 0.1 s timeout but still hands over what was typed;
    # it succeeds only when the input ended with Return.
    if IFS= read -r buf 2>/dev/null; then buf+=$'\n'; fi
    if [[ -n $buf ]]; then
        _UI_KEYS_FAILS=0
        _ui_keys_parse "$buf"
        return
    fi
    if [[ ! -t 0 ]]; then (( _UI_KEYS_FAILS++ )); sleep 0.1; fi
    return 1
}

# =============================================================================
# § ui_keys_lost
#
#   Returns:
#     0 when the last few polls all found that stdin is not a terminal any
#     more - no key will ever arrive, so the caller should stop waiting
# =============================================================================
ui_keys_lost() { (( _UI_KEYS_FAILS >= 5 )); }

# =============================================================================
# § _ui_keys_parse BYTES
#
#   Splits raw terminal input into named keys. Several keys can arrive in one
#   read (key repeat, a pasted word), so the whole buffer is walked.
#
#   Arguments:
#     BYTES   what the terminal sent
#   Globals:
#     writes UI_KEYS   one entry per key: UP DOWN LEFT RIGHT HOME END PGUP PGDN
#                      ENTER ESC SPACE TAB BACKSPACE, or the character itself
#   Returns:
#     0 if any key was recognised
# =============================================================================
_ui_keys_parse() {
    local s=$1
    UI_KEYS=()
    while [[ -n $s ]]; do
        case $s in
            $'\033[A'*|$'\033OA'*)   UI_KEYS+=(UP);    s=${s:3} ;;
            $'\033[B'*|$'\033OB'*)   UI_KEYS+=(DOWN);  s=${s:3} ;;
            $'\033[C'*|$'\033OC'*)   UI_KEYS+=(RIGHT); s=${s:3} ;;
            $'\033[D'*|$'\033OD'*)   UI_KEYS+=(LEFT);  s=${s:3} ;;
            $'\033[H'*|$'\033OH'*)   UI_KEYS+=(HOME);  s=${s:3} ;;
            $'\033[F'*|$'\033OF'*)   UI_KEYS+=(END);   s=${s:3} ;;
            $'\033[1~'*)             UI_KEYS+=(HOME);  s=${s:4} ;;
            $'\033[4~'*)             UI_KEYS+=(END);   s=${s:4} ;;
            $'\033[5~'*)             UI_KEYS+=(PGUP);  s=${s:4} ;;
            $'\033[6~'*)             UI_KEYS+=(PGDN);  s=${s:4} ;;
            $'\033['*)               s=${s:2}; s=${s#*[a-zA-Z~]} ;;   # unknown sequence: skip it
            $'\033'*)                UI_KEYS+=(ESC);   s=${s:1} ;;
            $'\n'*|$'\r'*)           UI_KEYS+=(ENTER); s=${s:1} ;;
            $'\177'*|$'\b'*)         UI_KEYS+=(BACKSPACE); s=${s:1} ;;
            $'\t'*)                  UI_KEYS+=(TAB);   s=${s:1} ;;
            ' '*)                    UI_KEYS+=(SPACE); s=${s:1} ;;
            *)                       UI_KEYS+=("${s:0:1}"); s=${s:1} ;;
        esac
    done
    (( ${#UI_KEYS[@]} > 0 ))
}
