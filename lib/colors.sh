#!/usr/bin/env bash
# =============================================================================
# § lib/colors.sh  ·  Terminal color + style palette
#
#   Single responsibility: declare the ANSI escape sequences used across the
#   whole TUI. Sourced first so every other module can rely on these names.
#
#   Originals (kept for backward compatibility):
#     RED GRN YLW BLU CYN DIM NC
#   Additions for richer progress/animation output:
#     BOLD MAG WHT GRY  +  256-color accents (ORG/TEAL)
# =============================================================================

# ── core palette ─────────────────────────────────────────────────────────────
declare -r RED='\033[0;31m'      # errors / failures
declare -r GRN='\033[0;32m'      # success
declare -r YLW='\033[1;33m'      # warnings / prompts
declare -r BLU='\033[0;34m'      # headings / info banners
declare -r CYN='\033[0;36m'      # selection / highlight
declare -r MAG='\033[0;35m'      # secondary accent
declare -r DIM='\033[2m'         # subtle / de-emphasised
declare -r NC='\033[0m'          # reset — No Color

# ── style modifiers + extra accents ────────────────────────────────────────
declare -r BOLD='\033[1m'        # bold weight
declare -r WHT='\033[1;37m'      # bright white
declare -r GRY='\033[0;90m'      # bright black / grey
declare -r ORG='\033[38;5;208m'  # orange (256-color) — progress fill accent
declare -r TEAL='\033[38;5;44m'  # teal  (256-color) — banner accent
