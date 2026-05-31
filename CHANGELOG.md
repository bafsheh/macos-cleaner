# Changelog

All notable changes to this project will be documented here.  
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

---

## [1.1.0] — 2026-05-31

### Added
- Multi-select "Cleanup & maintenance" menu — choose which actions to run via a checkbox
  list (space toggle · `a` select-all · Enter run · `q` cancel); selected actions execute as
  an ordered queue, in list order
- New maintenance action: **Flush DNS cache** (`dscacheutil -flushcache` + restart `mDNSResponder`)
- New maintenance action: **Free common dev ports** — force-kills processes on a curated
  dev-port list (3000, 5173, 8080, 9229, …); never targets system services or the running shell
- New maintenance action: **Kill all open apps** — quits visible GUI apps (graceful then force),
  always sparing terminal emulators, code editors / IDEs, and Finder, with a `y/N` confirmation
  (`KILL_APPS_ASSUME_YES=1` to opt in non-interactively)
- TUI polish — animated braille spinner, colored progress bar, and styled banners
- `KILL_APPS_ASSUME_YES` environment override

### Changed
- Split the single `mac_cleaner.sh` into a thin entry point plus focused `lib/*.sh` and
  `lib/actions/*.sh` modules sourced in dependency order (behavior unchanged for cleanup)
- Maintenance actions are wired through an open/closed action registry in `lib/menu.sh`
- Rewrote the README with architecture and runtime-flow diagrams

---

## [1.0.0] — 2026-05-24

### Added
- 28 cleaning sections covering Trash, user caches, browsers, Xcode, and all major developer toolchains
- Package manager support: npm, yarn, pnpm, bun, deno, pip, uv, poetry, conda, cargo, go, gem, composer, gradle, maven, brew, cocoapods, spm, and more
- AI assistant caches: Claude, ChatGPT, LM Studio, Ollama, Jan, Tabnine, Amazon Q, Cody, Gemini, Warp, Mistral, Groq, Perplexity, Copilot
- IDE caches: VS Code, Cursor, Windsurf, JetBrains, Sublime Text, Zed, Nova
- Time Machine local snapshot deletion (`tmutil deletelocalsnapshots`)
- Docker: `system prune -a` (all unused images) + interactive volume prune opt-in
- `brew autoremove` before `brew cleanup` to catch orphaned dependencies
- Pre-run and post-run `du` disk usage reports for `~` and `~/Library`
- Per-command timeout watchdog (`gtimeout` → `timeout` → pure-bash fallback)
- Verbose stdout/stderr capture and logging for every command
- GitHub-style section headers throughout
- Project-level cache scanning for Python (`__pycache__`, `.pytest_cache`, `.mypy_cache`, `.ruff_cache`) and JS (`.next/cache`, `.turbo`, `.parcel-cache`, jest, eslintcache)
- Full timestamped log written to `/tmp/mac_cleaner_YYYYMMDD_HHMMSS.log`
- Runs on macOS system bash 3.2+ — no external bash required
