# Changelog

All notable changes to this project will be documented here.  
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

---

## [1.3.0] — 2026-06-07

### Added
- New cleanup section **§ 26 · Adobe Creative Cloud** — clears the shared Media Cache / Peak files
  and per-app + Creative Cloud desktop caches and logs (Photoshop, Premiere Pro, After Effects,
  Illustrator, Bridge). Projects, libraries, and presets are left untouched.
- New cleanup section **§ 27 · Photos (caches only)** — clears only the Photos app's regenerable
  caches *outside* the library (`com.apple.Photos`, `photolibraryd`, `photoanalysisd`, the Photos
  container cache). Your `.photoslibrary` (originals, edits, albums) is never touched; an info note
  points to Apple's supported ways to reclaim its space.
- New cleanup section **§ 32 · System Data** — a research-backed sweep of regenerable per-app sandbox
  caches (`~/Library/Containers/*/Data/Library/Caches`, `~/Library/Group Containers/*/Library/Caches`)
  plus crash/diagnostic reports. iCloud-sync staging caches (`com.apple.bird`, `cloudphotosd`, `cloudd`,
  …) are deliberately skipped, and large irreplaceable items (iOS device backups) are reported, never
  deleted. Grounded in a multi-source, fact-checked review of what macOS "System Data" actually is.
- `sweep_caches` helper — bulk-clears many cache directories into one compact summary, handles paths
  containing spaces, excludes iCloud-sync caches, and honours the per-directory timeout.

### Fixed
- **Menu navigation glitch** — moving up/down could repaint the menu repeatedly and "walk" it down the
  screen when a row's label was wider than the window. The redraw moved the cursor up by the row count,
  but a wrapped label spanned extra physical lines. Menus now disable the terminal's automatic line-wrap
  while on screen, so one row always occupies one line and the cursor math is exact.

### Changed
- Simplified the first main-menu entry to **"Cleanup & maintenance"** (dropped the long parenthetical).
- The safe "Clean up" run now spans 32 sections, adding Adobe and Photos app caches and the System Data sweep.

---

## [1.2.0] — 2026-06-05

### Added
- New maintenance action: **Free up memory** — releases inactive & cached RAM via `sudo purge`,
  with a before/after `vm_stat` snapshot (free + reclaimable estimate); never quits your apps
- New **opt-in** action: **Docker — full teardown** — stops & removes ALL containers, removes ALL
  images, prunes networks + build cache (volumes are a separate opt-in). Requires `y/N` confirmation;
  `DOCKER_CLEAN_ASSUME_YES=1` (+ `DOCKER_CLEAN_VOLUMES=1`) to opt in non-interactively
- New **opt-in** action: **Ollama / llama — full wipe** — removes every Ollama model (via `ollama rm`,
  then the on-disk store), caches, logs, history, and Meta `~/.llama` checkpoints. Requires confirmation;
  `OLLAMA_CLEAN_ASSUME_YES=1` to opt in. (llama.cpp `.gguf` files are user-placed and left untouched.)
- New cleanup section **§ 25 · Microsoft Office, Teams & Outlook** in the safe "Clean up" run —
  cache-only clearing for Word, Excel, PowerPoint, OneNote, Outlook, Teams (new + classic), OneDrive,
  Remote Desktop, AutoUpdate, and Edge. Outlook's local mail database and account state are preserved.
- **Shut down when done** — a toggle in the cleanup checklist that powers the Mac off (graceful, no
  sudo) after all selected actions finish, behind a cancellable countdown (`SHUTDOWN_DELAY`, default 15s)
- **Back** row — every selection screen can return to the main menu; the cleanup list always shows the
  shutdown toggle second-to-last and **Back** as the final row. "Select all" / `a` no longer arm them.

### Changed
- TUI overhaul — auto colour detection (honours `NO_COLOR`, `CLICOLOR_FORCE`, non-TTY); a richer,
  more legible palette; bolder section banners; highlighted menu selection; a truecolor green→azure
  gradient progress bar; and a spinner with a live elapsed-seconds counter and gentle colour pulse

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
