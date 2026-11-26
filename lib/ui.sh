#!/usr/bin/env bash
# =============================================================================
# § lib/ui.sh  ·  Interactive TUI layer (loader)
#
#   Loads the UI modules in dependency order. Widgets hold no business logic:
#   they draw, read keys, and hand their result back through globals.
#
#     ui/term.sh      terminal state, window size, keyboard polling
#     ui/widgets.sh   progress bar, spinner, live status line, banner
#     ui/select.sh    interactive_menu, interactive_multiselect
#     ui/picker.sh    ui_picker - scrollable, filterable, live checklist
#
#   Every widget degrades gracefully when stdout/stdin is not a TTY, and when
#   colour is disabled (NO_COLOR) every glyph still renders as plain text.
#
#   Requires (sourced earlier): colors.sh, core.sh, logging.sh, helpers.sh
# =============================================================================
_UI_DIR="${BASH_SOURCE[0]%/*}/ui"

# shellcheck source=lib/ui/term.sh
source "$_UI_DIR/term.sh"
# shellcheck source=lib/ui/widgets.sh
source "$_UI_DIR/widgets.sh"
# shellcheck source=lib/ui/select.sh
source "$_UI_DIR/select.sh"
# shellcheck source=lib/ui/picker.sh
source "$_UI_DIR/picker.sh"
