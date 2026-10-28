# Changelog

All notable changes to this project will be documented here.  
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

---

## [Unreleased]

### Changed
- **Disk map scans live and in parallel.** The map opens immediately (empty) and fills in once a
  second while a pool of background `du` workers (`DM_JOBS`, default CPU count, max 8) measures
  folders from a shared queue. Big folders (`~/Library`, `~/Desktop`, `~/Documents`, `~/Projects`, …)
  are split into one job per sub-folder so many workers share them. Folders still being measured
  show `~` estimates; the status line shows progress and the latest folder found. Recommendations
  are measured in the background at the same time. `q` stops a scan early; quitting or Ctrl-C stops
  every worker. On a 207 GB home folder: ~25 s instead of ~52 s, with identical sizes.

- **Cleanup runs its independent sections in parallel** (`CLEAN_JOBS`, default 4). Each section's
  output is buffered and printed in the original order, so the screen and log read like a
  one-at-a-time run. Steps that ask a question or need `sudo` (Docker volumes, Time Machine, system
  caches) still run on their own. Ctrl-C stops every running section.
- The `run_timeout` fallback polls every 0.1 s instead of every second, so hundreds of quick deletes
  no longer take minutes.

### Fixed
- The disk map was drawn 80 columns wide whatever the window size (`tput` inside a command
  substitution with stderr silenced could not see the terminal). It now reads the size from the
  terminal device.
- Redraws no longer blank the screen first (no flicker), and line-wrap is off while the map is on
  screen so an over-long line can't push the frame down.

---

## [1.4.0] - 2026-10-28

### Added
- **Disk map** (main menu): a colour treemap of your home folder drawn in the terminal, two
  levels deep. Tiles are coloured by category (code projects, documents, SDKs, AI models, package
  caches) and hatched green when safe to remove. A header shows free space after cleanup, safe vs.
  needs-review totals, and space outside your home folder. Open tiles with `1`-`9`/`o`, go up with
  `u`, switch to a cleanup view with `v`. Rendering lives in `lib/diskmap.awk` (plain macOS awk).
- **Recommendations & clean** inside the disk map (`r`): measures known space hogs (npm/npx, uv,
  Puppeteer, Gradle, Xcode, app caches, stale temp, Android SDK, Simulators, Docker, Ollama, idle
  `node_modules`, Next.js/Turbo build output, Claude Code worktrees, macOS installers). Safe
  items start ticked; one confirmation runs them. Worktrees are removed with `git worktree remove`,
  which refuses any worktree with uncommitted changes.
- **Empty Trash** and **Clean temp files** as standalone checklist actions.
- Cleanup now also covers: every Chromium/Electron profile's caches (all Chrome/Edge/Brave
  profiles, Slack, Discord, Notion, Figma, VS Code…), the npx cache (`~/.npm/_npx`), Puppeteer,
  Playwright (`~/Library/Caches/ms-playwright`), Chrome for Testing and Selenium downloads, the
  pre-commit cache, watchOS/tvOS/visionOS device support, SwiftUI Previews, the Xcode documentation
  cache, the Safari container cache, and `xcrun simctl delete unavailable`.
- `TEMP_AGE_DAYS` setting (default 3).

### Fixed
- **Trash never emptied.** macOS privacy (TCC) blocks the terminal from even listing `~/.Trash`
  without Full Disk Access, so the step silently reported "already empty". It now detects this and
  asks Finder to empty the Trash (including iCloud Drive and external drives).
- **Silent "already empty" on protected folders.** Any folder macOS privacy refuses to list (Mail,
  Safari, Photos caches) is now reported as blocked, with a Full Disk Access tip in the summary.
- **Temp cleanup did little and was risky.** It deleted files one by one with `-mtime +3`, so folders
  were left half-empty and reported as failures, and no space freed was counted. On a Mac up for more
  than 3 days it could also delete the launchd/ssh-agent and tmux socket folders in `/private/tmp`.
  Temp items are now judged whole: removed only if nothing inside was modified or created within
  `TEMP_AGE_DAYS` and nothing inside is a socket. It now also covers `/private/var/tmp` and old Claude
  Code session folders, and reports space freed.
- The JS project scan claimed to clean `.next/cache` but never matched it. It now does, and project
  scans include `~/Desktop`. Duplicate scan roots on case-insensitive disks (`Projects`/`projects`)
  are no longer scanned twice.

### Changed
- Safari `LocalStorage` is no longer deleted: it is website data (it can hold logins), not a cache.
- Trash on external volumes is cleaned per-user (`.Trashes/<uid>`) without sudo, instead of wiping
  every user's Trash on the volume.

---

## [1.3.0] - 2026-06-07

### Added
- New cleanup section **§ 26 · Adobe Creative Cloud** - clears the shared Media Cache / Peak files
  and per-app + Creative Cloud desktop caches and logs (Photoshop, Premiere Pro, After Effects,
  Illustrator, Bridge). Projects, libraries, and presets are left untouched.
- New cleanup section **§ 27 · Photos (caches only)** - clears only the Photos app's regenerable
  caches *outside* the library (`com.apple.Photos`, `photolibraryd`, `photoanalysisd`, the Photos
  container cache). Your `.photoslibrary` (originals, edits, albums) is never touched; an info note
  points to Apple's supported ways to reclaim its space.
- New cleanup section **§ 32 · System Data** - a research-backed sweep of regenerable per-app sandbox
  caches (`~/Library/Containers/*/Data/Library/Caches`, `~/Library/Group Containers/*/Library/Caches`)
  plus crash/diagnostic reports. iCloud-sync staging caches (`com.apple.bird`, `cloudphotosd`, `cloudd`,
  …) are deliberately skipped, and large irreplaceable items (iOS device backups) are reported, never
  deleted. Grounded in a multi-source, fact-checked review of what macOS "System Data" actually is.
- `sweep_caches` helper - bulk-clears many cache directories into one compact summary, handles paths
  containing spaces, excludes iCloud-sync caches, and honours the per-directory timeout.

### Fixed
- **Menu navigation glitch** - moving up/down could repaint the menu repeatedly and "walk" it down the
  screen when a row's label was wider than the window. The redraw moved the cursor up by the row count,
  but a wrapped label spanned extra physical lines. Menus now disable the terminal's automatic line-wrap
  while on screen, so one row always occupies one line and the cursor math is exact.

### Changed
- Simplified the first main-menu entry to **"Cleanup & maintenance"** (dropped the long parenthetical).
- The safe "Clean up" run now spans 32 sections, adding Adobe and Photos app caches and the System Data sweep.

---

## [1.2.0] - 2026-06-05

### Added
- New maintenance action: **Free up memory** - releases inactive & cached RAM via `sudo purge`,
  with a before/after `vm_stat` snapshot (free + reclaimable estimate); never quits your apps
- New **opt-in** action: **Docker - full teardown** - stops & removes ALL containers, removes ALL
  images, prunes networks + build cache (volumes are a separate opt-in). Requires `y/N` confirmation;
  `DOCKER_CLEAN_ASSUME_YES=1` (+ `DOCKER_CLEAN_VOLUMES=1`) to opt in non-interactively
- New **opt-in** action: **Ollama / llama - full wipe** - removes every Ollama model (via `ollama rm`,
  then the on-disk store), caches, logs, history, and Meta `~/.llama` checkpoints. Requires confirmation;
  `OLLAMA_CLEAN_ASSUME_YES=1` to opt in. (llama.cpp `.gguf` files are user-placed and left untouched.)
- New cleanup section **§ 25 · Microsoft Office, Teams & Outlook** in the safe "Clean up" run -
  cache-only clearing for Word, Excel, PowerPoint, OneNote, Outlook, Teams (new + classic), OneDrive,
  Remote Desktop, AutoUpdate, and Edge. Outlook's local mail database and account state are preserved.
- **Shut down when done** - a toggle in the cleanup checklist that powers the Mac off (graceful, no
  sudo) after all selected actions finish, behind a cancellable countdown (`SHUTDOWN_DELAY`, default 15s)
- **Back** row - every selection screen can return to the main menu; the cleanup list always shows the
  shutdown toggle second-to-last and **Back** as the final row. "Select all" / `a` no longer arm them.

### Changed
- TUI overhaul - auto colour detection (honours `NO_COLOR`, `CLICOLOR_FORCE`, non-TTY); a richer,
  more legible palette; bolder section banners; highlighted menu selection; a truecolor green→azure
  gradient progress bar; and a spinner with a live elapsed-seconds counter and gentle colour pulse

---

## [1.1.0] - 2026-05-31

### Added
- Multi-select "Cleanup & maintenance" menu - choose which actions to run via a checkbox
  list (space toggle · `a` select-all · Enter run · `q` cancel); selected actions execute as
  an ordered queue, in list order
- New maintenance action: **Flush DNS cache** (`dscacheutil -flushcache` + restart `mDNSResponder`)
- New maintenance action: **Free common dev ports** - force-kills processes on a curated
  dev-port list (3000, 5173, 8080, 9229, …); never targets system services or the running shell
- New maintenance action: **Kill all open apps** - quits visible GUI apps (graceful then force),
  always sparing terminal emulators, code editors / IDEs, and Finder, with a `y/N` confirmation
  (`KILL_APPS_ASSUME_YES=1` to opt in non-interactively)
- TUI polish - animated braille spinner, colored progress bar, and styled banners
- `KILL_APPS_ASSUME_YES` environment override

### Changed
- Split the single `mac_cleaner.sh` into a thin entry point plus focused `lib/*.sh` and
  `lib/actions/*.sh` modules sourced in dependency order (behavior unchanged for cleanup)
- Maintenance actions are wired through an open/closed action registry in `lib/menu.sh`
- Rewrote the README with architecture and runtime-flow diagrams

---

## [1.0.0] - 2026-05-24

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
- Runs on macOS system bash 3.2+ - no external bash required
