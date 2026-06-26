#!/usr/bin/env bash
# =============================================================================
# § lib/colors.sh  ·  Terminal color + style palette
#
#   Single responsibility: declare the ANSI escape sequences used across the
#   whole TUI. Sourced first so every other module can rely on these names.
#
#   Colour is auto-disabled when output is not a terminal, when TERM=dumb, or
#   when NO_COLOR is set (https://no-color.org). Force it back on with
#   CLICOLOR_FORCE=1. When disabled every name below resolves to an empty
#   string, so the exact same printf templates render as clean plain text.
#
#   Core palette      : RED GRN YLW BLU CYN MAG DIM NC
#   Bright variants   : BRED BGRN BYLW BBLU BCYN BMAG
#   Style modifiers   : BOLD ITAL UND REV
#   Extra accents     : WHT GRY ORG TEAL ACCENT HL
# =============================================================================

# ── decide whether ANSI styling is emitted at all ────────────────────────────
#   Evaluated once at source time. core.sh (and `set -u`) is sourced *after*
#   this file, so the ${VAR:-} guards below are belt-and-braces.
_COLOR=1
[[ -n ${NO_COLOR:-} ]]          && _COLOR=0   # user opted out of colour
[[ ${TERM:-dumb} == dumb ]]     && _COLOR=0   # non-capable terminal
[[ -t 1 ]]                      || _COLOR=0   # stdout is piped / redirected
[[ ${CLICOLOR_FORCE:-0} == 1 ]] && _COLOR=1   # explicit override wins

# ── 24-bit (truecolor) capability - drives the progress-bar render path ──────
#   Only trustworthy signal that is widely set is $COLORTERM. When colour is on
#   but truecolor is not advertised, callers fall back to 256-colour output.
_TRUECOLOR=0
if (( _COLOR )); then
    case ${COLORTERM:-} in
        *truecolor*|*24bit*) _TRUECOLOR=1 ;;
    esac
fi

# ── _sgr CODE → the "\033[CODEm" escape, or "" when colour is disabled ───────
#   Returns an *interpreted* escape (real ESC byte) so it works whether the
#   caller feeds it to `printf '%b'` (logging) or splices it into a printf
#   format string (ui widgets) - both render an ESC identically.
_sgr() { (( _COLOR )) && printf '\033[%sm' "$1"; }

# ── core palette ─────────────────────────────────────────────────────────────
RED=$(_sgr '0;31')        # errors / failures
GRN=$(_sgr '0;32')        # success
YLW=$(_sgr '1;33')        # warnings / prompts
BLU=$(_sgr '0;34')        # headings / info banners
CYN=$(_sgr '0;36')        # selection / highlight
MAG=$(_sgr '0;35')        # secondary accent
DIM=$(_sgr '2')           # subtle / de-emphasised
NC=$(_sgr '0')            # reset - No Color

# ── bright variants (clearer status glyphs on dark themes) ───────────────────
BRED=$(_sgr '1;91')
BGRN=$(_sgr '1;92')
BYLW=$(_sgr '1;93')
BBLU=$(_sgr '1;94')
BCYN=$(_sgr '1;96')
BMAG=$(_sgr '1;95')

# ── style modifiers ──────────────────────────────────────────────────────────
BOLD=$(_sgr '1')          # bold weight
ITAL=$(_sgr '3')          # italic   (ignored by some terminals - harmless)
UND=$(_sgr '4')           # underline
REV=$(_sgr '7')           # reverse video

# ── extra accents ────────────────────────────────────────────────────────────
WHT=$(_sgr '1;37')        # bright white
GRY=$(_sgr '0;90')        # bright black / grey
ORG=$(_sgr '38;5;208')    # orange (256-color)  - progress fill accent
TEAL=$(_sgr '38;5;44')    # teal   (256-color)  - banner accent
ACCENT=$(_sgr '38;5;39')  # azure  (256-color)  - brand / section accent
HL=$(_sgr '48;5;236')     # dark-grey background - selected-row highlight

# ── freeze the palette ───────────────────────────────────────────────────────
readonly _COLOR _TRUECOLOR RED GRN YLW BLU CYN MAG DIM NC \
         BRED BGRN BYLW BBLU BCYN BMAG \
         BOLD ITAL UND REV \
         WHT GRY ORG TEAL ACCENT HL
