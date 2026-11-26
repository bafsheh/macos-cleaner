#!/usr/bin/env bash
# shellcheck disable=SC2034  # the palette is read by every other module
# =============================================================================
# § lib/colors.sh  ·  Terminal colour + style palette
#
#   Single responsibility: declare the ANSI escape sequences used across the
#   whole TUI. Sourced first so every other module can rely on these names.
#
#   Colour is auto-disabled when output is not a terminal, when TERM=dumb, or
#   when NO_COLOR is set (https://no-color.org). Force it back on with
#   CLICOLOR_FORCE=1. When disabled every name below resolves to an empty
#   string, so the exact same printf templates render as clean plain text.
#
#   Three capability tiers, detected once at source time:
#     _TRUECOLOR  24-bit colour  → gradient progress bars
#     _COLOR256   256 colours    → the soft palette below (every modern macOS
#                                  terminal, including Terminal.app)
#     _COLOR      16 colours     → classic ANSI fallback for thin terminals
#
#   Core palette      : RED GRN YLW BLU CYN MAG DIM NC
#   Bright variants   : BRED BGRN BYLW BBLU BCYN BMAG
#   Style modifiers   : BOLD ITAL UND REV
#   Extra accents     : WHT GRY ORG TEAL ACCENT HL SEL
#
#   Meaning is consistent everywhere: green = done, amber = needs attention,
#   red = failed or destructive, cyan = what is happening now, grey = detail.
# =============================================================================

# ── decide whether ANSI styling is emitted at all ────────────────────────────
#   Evaluated once at source time. core.sh (and `set -u`) is sourced *after*
#   this file, so the ${VAR:-} guards below are belt-and-braces.
_COLOR=1
[[ -n ${NO_COLOR:-} ]]          && _COLOR=0   # user opted out of colour
[[ ${TERM:-dumb} == dumb ]]     && _COLOR=0   # non-capable terminal
[[ -t 1 ]]                      || _COLOR=0   # stdout is piped / redirected
[[ ${CLICOLOR_FORCE:-0} == 1 ]] && _COLOR=1   # explicit override wins

# ── 24-bit (truecolor) capability - drives the progress-bar gradient ─────────
#   The only widely set signal is $COLORTERM. When colour is on but truecolor
#   is not advertised, callers fall back to 256-colour output.
_TRUECOLOR=0
if (( _COLOR )); then
    case ${COLORTERM:-} in
        *truecolor*|*24bit*) _TRUECOLOR=1 ;;
    esac
fi

# ── 256-colour capability - drives the palette below ─────────────────────────
#   A truecolor terminal always has 256 colours; otherwise trust $TERM.
_COLOR256=0
if (( _COLOR )); then
    case ${TERM:-} in
        *256color*|*-direct|xterm-kitty|xterm-ghostty|alacritty|wezterm) _COLOR256=1 ;;
    esac
    (( _TRUECOLOR )) && _COLOR256=1
fi

# =============================================================================
# § _sgr CODE [FALLBACK]
#
#   Prints the "\033[CODEm" escape, or nothing when colour is disabled.
#
#   Arguments:
#     CODE      SGR parameters to use on a 256-colour terminal, e.g. '38;5;78'
#     FALLBACK  SGR parameters for a 16-colour terminal; defaults to CODE
#   Outputs:
#     An *interpreted* escape (real ESC byte), so it works whether the caller
#     feeds it to printf '%s' or splices it into a printf format string.
# =============================================================================
_sgr() {
    (( _COLOR )) || return 0
    if (( _COLOR256 )); then printf '\033[%sm' "$1"; else printf '\033[%sm' "${2:-$1}"; fi
}

# ── core palette ─────────────────────────────────────────────────────────────
RED=$(_sgr '38;5;203' '0;31')     # errors / failures / destructive
GRN=$(_sgr '38;5;78'  '0;32')     # success
YLW=$(_sgr '38;5;221' '1;33')     # warnings / prompts
BLU=$(_sgr '38;5;75'  '0;34')     # headings / info banners
CYN=$(_sgr '38;5;80'  '0;36')     # activity / highlight
MAG=$(_sgr '38;5;176' '0;35')     # secondary accent
DIM=$(_sgr '38;5;245' '2')        # subtle / de-emphasised detail
NC=$(_sgr '0')                    # reset - No Color

# ── bright variants (status glyphs, emphasis) ────────────────────────────────
BRED=$(_sgr '1;38;5;203' '1;91')
BGRN=$(_sgr '1;38;5;84'  '1;92')
BYLW=$(_sgr '1;38;5;221' '1;93')
BBLU=$(_sgr '1;38;5;75'  '1;94')
BCYN=$(_sgr '1;38;5;87'  '1;96')
BMAG=$(_sgr '1;38;5;177' '1;95')

# ── style modifiers ──────────────────────────────────────────────────────────
BOLD=$(_sgr '1')          # bold weight
ITAL=$(_sgr '3')          # italic   (ignored by some terminals - harmless)
UND=$(_sgr '4')           # underline
REV=$(_sgr '7')           # reverse video

# ── extra accents ────────────────────────────────────────────────────────────
#   WHT is "bold, default foreground" rather than literal white, so emphasised
#   text stays readable on light terminal themes too.
WHT=$(_sgr '1;39'      '1;37')    # emphasised text
GRY=$(_sgr '38;5;240'  '0;90')    # rules, empty progress cells
ORG=$(_sgr '38;5;208'  '0;33')    # orange - "needs review" accent
TEAL=$(_sgr '38;5;44'  '0;36')    # teal   - banner / section accent
ACCENT=$(_sgr '38;5;39' '1;34')   # azure  - brand accent
HL=$(_sgr '48;5;236'   '7')       # dark-grey background - soft highlight
SEL=$(_sgr '1;38;5;231;48;5;25' '1;37;44')   # selected row: white on deep blue

# ── freeze the palette ───────────────────────────────────────────────────────
readonly _COLOR _TRUECOLOR _COLOR256 RED GRN YLW BLU CYN MAG DIM NC \
         BRED BGRN BYLW BBLU BCYN BMAG \
         BOLD ITAL UND REV \
         WHT GRY ORG TEAL ACCENT HL SEL
