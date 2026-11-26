# Changelog

All notable changes to this project will be documented here.  
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

---

## [Unreleased]

### Added
- **Uninstall ▸ Apps: a live list of every app on the Mac.** The list opens at once and fills in
  while a background scan runs: each app appears as soon as it is found, its size replaces `…` once
  measured (several apps at a time), and a progress bar covers the whole list. Scroll, filter with
  `/`, sort by name or size with `s`, tick one or more apps. Apps in `/Applications`,
  `~/Applications` and those Spotlight finds elsewhere in the home folder are listed; macOS system
  apps are not, because they cannot be removed.
- **Complete uninstall.** For each chosen app the uninstaller searches 30 locations at the same
  time (app data, caches, preferences, saved state, containers, group containers, web data, logs,
  crash reports, launch agents and daemons, privileged helpers, install receipts, per-user temp and
  cache folders, dotfolders, Spotlight) with a live progress line, shows what it found in two
  groups (*belongs to the app* and *needs your review*), and asks: `y` app and its own items, `a`
  everything, `c` choose item by item. It then quits the app, stops its launchd services, resets
  its privacy permissions (`tccutil reset All`, also for helper bundles inside the app), removes
  its login item, tells Homebrew (casks) and Launch Services, deletes each item with a progress
  bar and one log line per item, and prints a receipt: removed, freed, failed with the reason,
  kept. Every searched location goes to the log file.
- Uninstall safety: leftovers match by exact bundle ID or exact name only (uninstalling "Code"
  never matches "Xcode"); data of an installed sibling app (Chrome Canary next to Chrome) and of a
  second copy of the same app is kept; generic names (Electron, Helper …) are never matched by
  name; every delete passes an allow-list of folders (`un_safe_target`); the app running the
  current session is never uninstalled; Keychain entries are never touched.
  `UNINSTALL_ASSUME_YES=1` for scripts (own items only), plus `UNINSTALL_APP_ROOTS`,
  `UNINSTALL_SPOTLIGHT`, `UNINSTALL_JOBS`, `UNINSTALL_NO_SUDO`.
- **Uninstall ▸ Packages & command-line tools**: the former name search, now only for Homebrew,
  npm, pip, Cargo, RubyGems and loose binaries, with a tick list and a summary.
- **Summary boxes.** The action queue ends with *What happened* (each action: space freed, time,
  failed steps). The clean-up ends with *Cleanup complete*, including the eight biggest wins of
  the run. The result stays on screen until a key is pressed.
- Menus show a description beside each item, in two aligned columns; destructive items are marked
  in red. The main menu shows a disk gauge (green, amber from 75%, red from 90%).
- Smoother progress bars (eight steps per cell), a shared spinner, and a live one-line status used
  by the leftover search and the removal.
- `ui_picker`: a scrollable, filterable checklist that can update while a background job feeds it.
  Runs on the alternate screen, so the previous screen is restored on exit.
- Tests: 45 new ones (52 in all) for long-running screens (no file-descriptor growth), the folder scanner, the disk usage report, the disk map, app
  discovery, leftover matching, the delete guard, the full
  uninstall flow, packages, key parsing, the progress bar, the picker, menus and logging. Run a
  subset with `bash tests/run_tests.sh <part of a test name>`.
- `MAC_CLEANER_LOG` chooses the log file.

- **Project build dirs** menu action, using the rules of [plonge](https://github.com/mattt/plonge).
  Finds `node_modules`, `.venv`, `target`, `.build`, `dist`, `DerivedData`, `.next`, `_build`,
  `vendor/bundle` and similar folders in your dev folders. Generic names need a project file beside
  them (`target` next to `Cargo.toml` or `pom.xml`, `dist` next to `package.json` …). A folder is
  deleted only when Git ignores it, it holds no tracked file or nested repo, its repo has had no Git
  activity for `PROJECT_QUIET_HOURS` (default 24), and no running process works in that repo.
  Lists what it keeps and why, asks first. `PROJECT_KEEP_RE`, `PROJECT_SCAN_ROOTS`,
  `PROJECT_CLEAN_ASSUME_YES=1` for scripts.
- Clean up §33 (from plonge's shared-cache rules): Zig global cache, Elixir Hex packages, rebar3 Hex
  cache and `mise cache prune`. Also Yarn 2+ global cache, downloaded RubyGems `.gem` files, and
  `CARGO_HOME` / `GRADLE_USER_HOME` are honoured.
- `tests/run_tests.sh`: regression tests that run in CI against a throwaway HOME and a stub
  `docker`.
- **Stale git worktrees** menu action. Finds linked worktrees under your dev folders that no one
  has touched for `WORKTREE_AGE_DAYS` (default 7) and removes only those with a clean
  `git status`, every commit on a remote, and no process using them. Lists what it keeps and why,
  asks first, and uses `git worktree remove`, so branches survive. `WORKTREE_KEEP_RE` protects
  paths; `WORKTREE_CLEAN_ASSUME_YES=1` for scripts.
- **Colima** menu action and disk-map recommendation. Deletes every Colima profile with its data
  (`colima delete --data`) and leftover Lima data disks that a plain `colima delete` leaves
  behind. Docker Desktop is untouched. `COLIMA_CLEAN_ASSUME_YES=1` for scripts.
- Clean up now removes Codex CLI runtimes (`~/.cache/codex-runtimes`, skipped while Codex runs)
  and stale Cursor settings-DB copies (`state.vscdb.bak-*`, often ~500 MB each).

### Fixed
- **Disk map printed "read error: 0: Bad file descriptor" without end.** bash 3.2 does not close
  the file descriptor of a process substitution (`< <(cmd)`) while it is inside a function, only
  back at the top level of the script, and the main menu was a function that loops. The disk map
  used one ten times a second, so after about 25 seconds of scanning it reached the 256 open
  files a Terminal window allows, lost the keyboard's descriptor, and its loop spun on failed
  reads. The same leak sat in the cleanup's live panel (two per redraw, also in earlier releases),
  the disk usage report, the app list and the picker. Now: nothing that repeats uses process
  substitution, the menu loop runs at the top level of `mac_cleaner.sh` so one-off uses are
  released after every menu action, the limit is raised to 4096 where allowed, and a loop that
  waits for keys ends if the keyboard is ever gone (`ui_keys_lost`). Measured on a full scan
  under a 256 limit: 4 to 6 open descriptors throughout, where it used to climb to 256.
- **"Clean up" looked frozen at the disk usage report.** The report measured the whole home
  folder with one `du` in the foreground: nothing was printed until it finished, there was no
  time limit and no way out, and it ran twice (home, then `~/Library`) before and after cleaning.
  It now uses the parallel scanner, shows a live progress line (`412/980 folders measured`), can
  be skipped with `s`, stops after `REPORT_TIMEOUT` seconds (default 90) and lists what it has by
  then, and gets both lists from a single scan. On a 185 GB home folder: 34 s with progress,
  instead of several minutes of silence.
- The main menu cleared the screen as soon as an action finished, so its result scrolled away
  unread. Every action (cleanup queue, app uninstall, package uninstall) now ends with a clear
  prompt, "✓ Finished. Press any key to clear the screen and return to the menu.", and the
  screen is cleared after the key, so the next menu is no longer drawn under the old output.
- The old uninstaller matched leftovers by substring (`*name*`), which could list another app's
  folders for removal. Matching is now exact (see Added).
- **Empty Trash left items behind.** With Full Disk Access, read-only folders (trashed
  `node_modules`, Go module caches, app bundles) and Finder-locked files could not be deleted, yet
  the step still reported success. Trash folders are now unlocked and made writable first, and any
  folder clean that leaves items behind now says how many.
- **Docker cleanup** said "already empty" while the build cache still used gigabytes, failed on an
  image with two tags, froze when the daemon did not answer (`docker info` now times out after
  `DOCKER_INFO_TIMEOUT`, default 20 s), and never reported the space freed. It now shows the Mac's
  free-space gain and the Docker Desktop disk size, and explains that Docker Desktop returns space
  gradually. Clean up uses the built-in `docker builder prune` instead of the optional buildx plugin.
- "Delete unavailable simulators" (and the disk map's simulator erase) were skipped when
  `xcode-select` points at the Command Line Tools, which have no `simctl`. They now fall back to
  an installed `Xcode.app` for that one command.
- The uv step no longer waits 300 s on the cache lock or deletes files under a running uv/uvx
  process (such as an MCP server started with `uvx`). It is skipped with a tip while one runs.

### Changed
- **Disk map: faster and never waiting.**
  - New scanner (`lib/helpers/duscan.sh`). A folder that is still being measured after one second
    is stopped and split into one job per sub-folder, at any depth, so a single deep tree (a
    folder of git worktrees, an Xcode cache) is spread over all workers instead of setting the pace
    of the whole scan. Workers default to the CPU count (max 16, was 8) and need no lock to share
    the queue. Measured on a 185 GB home folder: 83 s before, about 35 s now; `~/Projects` alone
    15 s instead of 60-80 s, with totals identical to `du`.
  - The map is rendered by a background job; the foreground only paints finished frames and, ten
    times a second, the bottom line: spinner, progress bar, folders measured, the folder just
    finished. Keys respond at once instead of once a second.
  - Recommendations are measured by one job each and join the header as they finish
    (`4.2 GB  14/20 checked`), instead of "measuring…" until the slowest one is done. While they
    are still coming in after the scan, the bottom line shows their progress.
  - `DU_SPLIT_SECS` tunes the split time; `DM_JOBS` now applies to the report too.
- **The log file is plain text.** It used to be a copy of the terminal output, colour codes
  included. Each line now starts with the time since the run began (`[+02:14]`).
- Colours: one palette for 256-colour terminals (softer green, amber, red, cyan), with a 16-colour
  fallback; bold text uses the terminal's own foreground, so it stays readable on light themes;
  the selected row is white on blue.
- `lib/helpers.sh` and `lib/ui.sh` are now loaders. The code moved, unchanged in behaviour, into
  `lib/helpers/` (measure, exec, process, parallel, macos, clean, scan) and `lib/ui/` (term,
  widgets, select, picker). `kill_tree`, `proc_wait_gone` and `proc_ancestor_pids` replace three
  private copies in the disk map, the parallel runner and "Kill all open apps".
- `lib/actions/cleanup.sh`: section bodies are indented, their variables are local, and the
  repeated per-app cache lines use `clean_subdirs`. The paths cleaned are the same as before.
- The uninstaller no longer builds command strings and runs them with `eval`; names and paths
  are passed as arguments.
- CI lints every file with ShellCheck (it used to lint only `mac_cleaner.sh`) and syntax-checks
  every file with the system bash.
- The main menu is a loop instead of a function that calls itself.
- The version shown in the banner comes from one place, `MC_VERSION` in `lib/core.sh`.
- Destructive actions (Docker, Colima, Ollama, worktrees, project folders, quit apps) share one
  confirmation helper, `confirm_action`, instead of six copies of the same prompt.
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
- **Live view of what each parallel section is doing.** While sections run, a panel under the
  finished output shows a progress bar and, for every running section, how long it has run, its
  current step, the last line it logged and the command it is running right now (for example
  `find ~/Library/Caches/Homebrew -mindepth 1 -delete`). On a short window each section gets one
  line. The panel is removed once all sections finish; the log is unchanged.
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
