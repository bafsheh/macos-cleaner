<div align="center">

# 🧹 macOS Cleaner

**Free up disk space and tidy your Mac, safely, in a few clicks.**

It clears the junk your apps leave behind (caches, logs, temporary files) and
gives you gigabytes back. It never touches your personal files. Your photos,
documents, downloads, and music stay exactly where they are.

[![Platform](https://img.shields.io/badge/platform-macOS%2012%2B-black?logo=apple)](https://www.apple.com/macos/)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Personal files](https://img.shields.io/badge/personal%20files-never%20touched-success)](#-is-it-safe)

</div>

---

## 👋 New here? Start with this

Picture your Mac as a kitchen. As you cook each day, used dishes and scraps pile
up. This tool is the cleanup crew. It washes the dishes and takes out the trash.
It never throws away your groceries.

It removes things your Mac rebuilds on its own the next time you need them:

- 🗑️ Trash you haven't emptied
- 🌐 Old website data stored by browsers (Safari, Chrome, Firefox, and others)
- 📦 Leftover files from apps and developer tools
- 📄 Old logs and temporary files

It also does a few handy extras, all optional:

- 🧠 Free up memory so your Mac feels faster
- 🌐 Fix some website loading issues by refreshing your Mac's address book (a "DNS flush")
- 🔌 Close stuck programs that hold onto connections
- 🚪 Quit all your open apps at once

You pick what you want from a menu. Nothing runs until you say so.

---

## ✅ Is it safe?

Yes. This is the part most people worry about, so here it is plainly:

> **Your personal files are never touched.** Documents, Desktop, Downloads,
> Pictures, Music, and Movies stay off-limits.

The tool removes files that are safe to delete, the kind your Mac and apps
rebuild on their own the next time you open them. A few more promises:

- It asks for your permission before anything risky, such as quitting apps.
- It spares your Terminal, code editor, and Finder when quitting apps.
- It saves a detailed log of everything it did, so you can review it later.
- It skips any step that takes too long, so a run never hangs.

---

## 🚀 Setup, step by step

You do this part once. It takes about two minutes.

> 💡 **What is the "Terminal"?** It is an app that comes with every Mac. You type
> commands instead of clicking buttons. You will copy and paste a few lines.

### Step 1. Open the Terminal

1. Press **`Command (⌘)` + `Space`** to open Spotlight search.
2. Type **`Terminal`** and press **`Return (↵)`**.
3. A window with a blank text prompt opens. That is the Terminal.

### Step 2. Download the tool

Copy the line below, paste it into the Terminal, and press **`Return`**:

```bash
git clone https://github.com/bafsheh/macos-cleaner.git
```

> 💡 If you see *"git: command not found"*, your Mac shows a box offering to
> install developer tools. Click **Install**, wait for it to finish, then run the
> line above again.

### Step 3. Go into the folder

```bash
cd macos-cleaner
```

### Step 4. Make it runnable (one time)

```bash
chmod +x mac_cleaner.sh
```

✅ Setup done. You will not repeat steps 1 to 4 again.

---

## ▶️ How to use it

Each time you want to clean your Mac:

1. Open the Terminal (Step 1 above).
2. Go into the folder and start the tool:

   ```bash
   cd macos-cleaner
   ./mac_cleaner.sh
   ```

You land on the main menu:

```
  ╭──────────────────────────────────────────────────────╮
  │  macOS Cleaner                               v1.4.0  │
  │  Safe disk-space cleaner + maintenance               │
  │                                                      │
  │  Disk  ███████████▌              46% used            │
  │        249Gi free of 460Gi                           │
  ╰──────────────────────────────────────────────────────╯

  What would you like to do?
   ❯ Cleanup & maintenance   free space · tidy caches · quick fixes
     Disk map                see what is using your space
     Uninstall               apps with all their leftovers · packages
     Exit
```

The gauge shows how full your disk is. It turns amber at 75% and red at 90%.

### Step 1. Move and choose

- Use the **`↑` and `↓` arrow keys** to move up and down.
- Press **`Return (↵)`** to choose the highlighted (`❯`) item.

Pick **Cleanup & maintenance** to open the checklist.

### Step 2. Tick what you want

```
  Cleanup & maintenance - choose actions to run
  ↑ ↓ move  ·  space toggle  ·  a all  ·  Enter run  ·  q cancel

  ❯  [✓]  Clean up                  caches · logs · package stores · Microsoft · Trash
     [ ]  Empty Trash               all volumes · works without Full Disk Access
     [ ]  Clean temp files          stale /tmp · TMPDIR · old Claude Code sessions
     [ ]  Free up memory            release inactive & cached RAM
     [ ]  Flush DNS cache           fixes stale website addresses
     [✓]  Free common dev ports     stops whatever holds 3000 · 5173 · 8080 …
     [ ]  Kill all open apps        spares terminals and the app running this session
     [ ]  Stale git worktrees       clean · pushed · idle 7+ days · branches kept
     [ ]  Project build dirs        node_modules · .venv · target · Git-ignored
     [ ]  Docker                    ⚠ removes ALL containers & images
     [ ]  Colima                    ⚠ deletes its VMs & their Docker data
     [ ]  Ollama / llama            ⚠ removes ALL models & caches
     [ ]  Shut down Mac when done   cancellable countdown
      ↩ Back - return to main menu
```

The controls:

| Key | What it does |
|---|---|
| `↑` / `↓` | Move up and down the list |
| `space` | Tick or untick the highlighted item (`[✓]` means selected) |
| `a` | Tick everything |
| `Return (↵)` | Run all the ticked items |
| `q` | Cancel and go back |

> 💡 **Want a good general clean-up?** Tick only **Clean up** and press `Return`.
> That is the safe everyday choice.

### Step 3. Let it run

The tool runs your chosen tasks one by one and shows a progress bar as it goes.
When it finishes, a **What happened** box lists each task with the space it freed
and how long it took. The clean-up adds its own box with the biggest wins:

```
  ╭─ Cleanup complete ───────────────────────────────────────────╮
  │ ✓ 18.42 GB freed · disk now 267Gi free of 460Gi              │
  │ ✓ 141 step(s) done in 3m 12s                                 │
  │                                                              │
  │   Biggest wins                                               │
  │      9.10 GB  Xcode DerivedData                              │
  │      3.87 GB  Homebrew downloads cache                       │
  │      2.20 GB  npm content-addressable cache                  │
  ╰──────────────────────────────────────────────────────────────╯
```

The result stays on screen until you are done reading:

```
  ────────────────────────────────────────────────────────
  ✓ Finished.  Press any key to clear the screen and return to the menu.
```

Press any key. The screen is cleared and you are back at the menu, where you can
run more or pick **Exit** to finish. The uninstaller ends the same way.

> 💡 Some steps ask for your **Mac password**. That is normal. macOS requires it
> to clean system-level files. Nothing leaves your Mac.

---

## 🧰 What each option does

| Option | In plain English | Good to know |
|---|---|---|
| **Clean up** | The main event. Clears caches, logs, leftover app and tool files, temp files, and the Trash. | Safe. Frees the most space. |
| **Empty Trash** | Empties your Trash, including iCloud Drive's and external drives'. | Works even without Full Disk Access (it asks Finder to do it). |
| **Clean temp files** | Removes temporary files nothing has used for 3+ days, plus old Claude Code session folders. | Safe. Anything in use or touched recently is kept. |
| **Free up memory** | Releases unused memory so your Mac feels snappier. | Safe. Deletes no files. |
| **Flush DNS cache** | Refreshes your Mac's address book for websites, which fixes some loading issues. | Asks for your password. |
| **Free common dev ports** | Closes stuck background programs that block common developer connections. | For developers. Leaves normal apps alone. |
| **Kill all open apps** | Quits all your open apps at once. | Asks first. Always spares terminal apps and the app this tool is running in. |
| **Stale git worktrees** | Removes extra git worktrees (often left behind by AI coding agents) that nobody has touched for 7+ days. | For developers. Shows the list and asks first. Only removes a worktree with no uncommitted work, every commit pushed, and nothing running in it. Branches are kept. |
| **Project build dirs** | Deletes rebuildable folders inside your code projects: `node_modules`, `.venv`, `target`, `.build`, `dist`, `DerivedData` and more (the rules of [plonge](https://github.com/mattt/plonge)). | For developers. Shows the list and asks first. Only deletes a folder that Git ignores, holds no tracked file, sits in a repo with no Git activity for 24 hours, and no running program is working in. Rebuild with `npm install`, `uv sync`, `cargo build` … |
| **Docker, remove ALL** | Wipes all Docker containers, images and build cache. | ⚠️ For developers. Deletes a lot. Pick it only if you mean it. Docker Desktop gives the space back to your Mac over a few minutes. |
| **Colima, delete** | Deletes Colima, a second Docker runtime many Macs have next to Docker Desktop, with all its data. | ⚠️ Deletes its images, containers and volumes. Docker Desktop is not touched. |
| **Ollama, remove ALL** | Deletes all downloaded AI models. | ⚠️ Large re-downloads later if you need them again. |
| **Shut down when done** | Turns the Mac off after everything finishes. | You get a countdown. Press any key to cancel. |
| **Uninstall** (main menu) | Removes an app together with its settings, caches, background services and privacy permissions. | Lists everything first and asks. See [Uninstall an app, completely](#-uninstall-an-app-completely). |

---

## 📦 Uninstall an app, completely

Dragging an app to the Trash leaves its settings, caches and background helpers
behind. Pick **Uninstall** on the main menu, then **Apps**.

The list opens at once and fills in live. Each app appears as soon as it is found,
its size replaces the `…` once it is measured, and the bar at the top shows how
far the whole list is:

```
  Uninstall apps  every app on this Mac · sizes fill in as they are measured
  ⠸ ██████████▌              17/62  measuring Microsoft Outlook
  ↑↓ move · space tick · a all · / filter · s sort (name) · Enter uninstall · q back

  ❯ [✓] Foo Editor            904 MB  v2.4.1 · /Applications
    [ ] Google Chrome         1.50 GB  v158.0 · /Applications
    [ ] Microsoft Outlook           …  v16.115 · /Applications

  62 apps · 1 ticked · 904 MB
```

| Key | What it does |
|---|---|
| `↑` / `↓`, `PgUp` / `PgDn` | Move through the list |
| `space` | Tick or untick the highlighted app |
| `/` | Filter: type part of a name, `Return` to keep it, `Esc` to clear |
| `s` | Sort by name or by size |
| `Return (↵)` | Uninstall the ticked apps (or the highlighted one) |
| `q` | Back |

For each app you picked, the tool then:

1. **Searches 30 places** for what the app left behind, all at the same time:
   settings, caches, saved window state, sandbox containers, logs, crash reports,
   background services, install receipts.
2. **Shows what it found**, in two groups. *Belongs to the app* is matched by the
   app's bundle ID or its exact name. *Needs your review* is anything less
   certain, such as a hidden folder in your home folder. Review items are kept
   unless you choose them.
3. **Asks**: `y` removes the app and its own items, `a` also removes the review
   items, `c` lets you tick item by item, anything else cancels.
4. **Removes**, with a line per step: quits the app, stops its background
   services, resets its privacy permissions (Camera, Microphone, Files, Full Disk
   Access …), drops its login item, then deletes the app and each leftover.
5. **Prints a receipt**: what was removed, how much space came back, and anything
   it could not remove, with the reason.

It is careful about what it deletes. A name must match exactly, so uninstalling
"Code" never touches "Xcode". Data of a related app that is still installed (Chrome
Canary next to Chrome) is kept. Every delete is checked against a fixed list of
folders an uninstall may touch. The app that is running your terminal is never
uninstalled. Keychain entries are never touched.

**Packages & command-line tools** (the second item) finds Homebrew formulae and
casks, global npm packages, pip packages, Cargo binaries, RubyGems and loose
binaries by name, and removes the ones you tick with their own package manager.

> 💡 macOS system apps (Mail, Safari, Calculator …) are not listed. macOS seals
> them and they cannot be removed.

---

## 🗺️ Disk map

Pick **Disk map** on the main menu to see where your space went. The map opens
straight away and fills in live. Nothing waits on anything else:

- **The scan** runs on every CPU core. A folder that takes long to measure is
  split up and shared between the scanners, however deep it sits, so one huge
  folder no longer holds up the rest.
- **The picture** is redrawn a few times a second from what is known so far.
  Sizes marked `~` are still growing.
- **The advice** in the header ("Safe to remove", "Needs review") fills in item
  by item, for example `4.2 GB  14/20 checked`.

The bottom line always shows what is happening: a spinner, a progress bar, the
number of folders measured and the folder just finished.

```
  ⠹ ██████████▌        412/980 folders · 9s  ·  ~/Library/Developer 34.1 GB  (q stop · v view)
```

Keys work the whole time; press `q` to stop a scan early. On a 185 GB home folder
the first tiles appear within two seconds and the full scan takes about 35 seconds.

- **Colour tiles**, sized by space used: code projects, documents and media, iOS and
  Android SDKs, AI models, package caches, and everything else.
- **Green stripes** mark folders that are safe to remove.
- **Header**: free space after cleanup, how much is safe to remove, how much needs
  your review, and how much sits outside your home folder (system and apps).

| Key | What it does |
|---|---|
| `1`-`9` | Open the numbered tile |
| `o` | Pick any folder from a list |
| `u` or `←` | Go up one level |
| `v` | Switch between the category view and the cleanup view (green = safe, orange = review) |
| `r` | Open the recommendations: tick what to clean, then confirm |
| `s` | Rescan |
| `q` | Back to the main menu |

In the recommendations list, the **safe** items start ticked and the **review**
items do not. Nothing is deleted until you confirm, and the Docker and Ollama wipes
still ask once more.

---

## 🆘 Common questions and fixes

**"git: command not found"**
Your Mac offered to install developer tools. Click **Install**, wait, then run the
download command again. See Setup, Step 2.

**"Permission denied" when I run it**
You skipped Step 4. Run `chmod +x mac_cleaner.sh` once, then try again.

**"No such file or directory"**
You are not inside the folder. Run `cd macos-cleaner` first, then
`./mac_cleaner.sh`.

**It asked for my password. Is that a virus?**
No. macOS requires your password to clean protected system files. The tool runs
on your Mac and sends nothing anywhere.

**It says "blocked by macOS privacy (needs Full Disk Access)"**
macOS hides some folders (Mail, Safari, Photos caches) from apps until you allow it.
To let the tool clean them: System Settings ▸ Privacy & Security ▸ Full Disk Access,
add your terminal app (Terminal, iTerm, VS Code…), then reopen it. Skipping this is
fine: those folders are just left alone.

**My Trash did not empty before**
macOS blocks direct access to the Trash folder. The tool now asks Finder to empty it.
The first time, macOS asks whether your terminal may control Finder. Click **OK**.

**"Clean up" seems to sit at the disk usage report**
It is measuring your home folder to show you the biggest folders before and after.
A progress line shows how far it is. Press `s` to skip the report; the cleaning
itself does not depend on it. It also gives up on its own after 90 seconds.

**It printed "read error: 0: Bad file descriptor" over and over**
That was a bug in the disk map (and, after a long clean-up, the progress panel):
it ran out of open files. It is fixed. If you still have the old version running,
close that terminal window and start the tool again.

**Did it delete my files?**
No. It removes only regenerable junk. Want proof? Every run saves a full log that
lists what happened. Its path is printed at the end of each run.

**The uninstaller says "macOS protects app containers"**
Some apps keep their data in a protected folder that only the app itself, or a
terminal with Full Disk Access, may delete. Give your terminal Full Disk Access
(see above) and uninstall again, or remove that one folder in Finder.

**An app is missing from the uninstall list**
The list shows apps in `/Applications`, `~/Applications`, and apps Spotlight
finds elsewhere in your home folder. System apps are left out on purpose.

---

## 📋 What you need

| Requirement | Notes |
|---|---|
| **A Mac** | macOS 12 or newer (tested up to macOS 26 "Tahoe"). |
| **Nothing to install** | Everything it needs ships with macOS. |
| **Your password** | Only for a few system-cleaning steps. You get prompted. |

**Optional speed-up** (for advanced users): installing `coreutils` through
[Homebrew](https://brew.sh) makes timeouts a bit more reliable.

```bash
brew install coreutils
```

---

<details>
<summary><strong>🧽 The full list of what it cleans (click to expand)</strong></summary>

<br>

The "Clean up" action sweeps these areas. Most are developer tools. If you do not
use one, that section finds nothing and moves on.

| # | Area |
|---|------|
| 0 | Disk usage report before cleaning (info only). Shows live progress; press `s` to skip it |
| 1 | Trash: yours, iCloud Drive's, and your Trash on connected drives (via Finder if needed) |
| 2 | System and app caches and logs in your Library |
| 3 | Browser caches (every profile): Safari, Chrome, Firefox, Brave, Arc, Edge, plus Electron apps like Slack, Discord, Notion, Figma |
| 4 | Xcode: DerivedData, Archives, device support, SwiftUI Previews, Simulator caches, unavailable simulators |
| 5 | Apple dev tools: Swift PM, CocoaPods, Carthage, Mint |
| 6 | Homebrew: orphaned packages, cleanup, logs |
| 7 | JavaScript / Node: npm and npx, yarn (1 and 2+), pnpm, bun, deno, volta, nvm, turbo, Puppeteer, Playwright |
| 8 | JavaScript project caches: `.next/cache`, `.turbo`, jest, eslint |
| 9 | Python tools: pip, uv, poetry, pipenv, hatch, pdm, pyenv, conda |
| 10 | Python project caches: `__pycache__`, pytest, mypy, ruff |
| 11 | Go: build, module, test, and fuzz caches |
| 12 | Rust: Cargo (honours `CARGO_HOME`), rustup, sccache |
| 13 | C / C++: ccache, Conan, vcpkg |
| 14 | Ruby: gem cleanup, downloaded `.gem` files, Bundler cache |
| 15 | PHP: Composer, PHPStan, Psalm, PHP-CS-Fixer |
| 16 | .NET: NuGet local caches |
| 17 | Java / Kotlin: Gradle (honours `GRADLE_USER_HOME`), Maven, SBT, Ivy2, SDKMAN |
| 18 | Android: SDK and build caches |
| 19 | Docker: unused images and build cache |
| 20 | Cloud / DevOps: Terraform, Pulumi, Ansible, kubectl, AWS, GCP, Azure |
| 21 | Local database dev logs (your data is never touched) |
| 22 | Code editors: VS Code, Cursor, JetBrains, Sublime, Zed, and more |
| 23 | AI assistants: ChatGPT, Perplexity, LM Studio, Ollama, and more |
| 24 | Mail caches |
| 25 | Microsoft Office, Teams, Outlook, OneDrive, Edge (caches only; mail and documents stay) |
| 26 | Adobe Creative Cloud: media cache, per-app caches, logs (projects and presets stay) |
| 27 | Photos app caches (your photo library is never touched) |
| 28 | Time Machine local snapshots |
| 29 | Quick Look thumbnails and old iOS update files |
| 30 | System caches and logs (needs your password) |
| 31 | Temporary files untouched for 3+ days, plus old Claude Code session folders |
| 32 | "System Data": app container caches, crash and diagnostic reports |
| 33 | More toolchains: Zig global cache, Elixir Hex packages, Erlang rebar3 Hex cache, mise download cache |
| (end) | Disk usage report after cleaning, plus a summary box with the biggest wins |

</details>

<details>
<summary><strong>🛡️ Exactly what it never touches (click to expand)</strong></summary>

<br>

- **Your personal files**: Documents, Desktop, Downloads, Pictures, Music, Movies
- **Docker named volumes**: they may hold database data, so the tool wipes them only on a separate opt-in
- **Ollama / LM Studio models**: removed only if you pick that option
- **Maven packages**: the tool clears throwaway metadata, never your packages
- **Installed Homebrew software**: the tool clears only the download cache
- **System services and SSH**: "Free dev ports" targets a known list of dev ports
- **Your terminal and the app this tool runs in**: always spared when quitting apps
- **Other apps' data, when you uninstall one**: leftovers are matched by exact bundle ID or exact name, and every delete is checked against a list of allowed folders
- **Keychain entries**: never removed, also not by the uninstaller

</details>

<details>
<summary><strong>⚙️ Advanced settings and how it works (click to expand)</strong></summary>

<br>

### Settings (for power users)

You can tweak behaviour with environment variables. No config file needed:

| Variable | Default | What it controls |
|---|---|---|
| `CMD_TIMEOUT` | `60` | Max seconds for any single command |
| `DIR_TIMEOUT` | `120` | Max seconds to delete one folder |
| `SCAN_TIMEOUT` | `60` | Max seconds for project scans |
| `CLEAN_JOBS` | `4` | Cleanup sections run at the same time (`1` = one at a time) |
| `PY_SCAN_ROOTS` | auto | Folders to scan for Python caches |
| `JS_SCAN_ROOTS` | auto | Folders to scan for JavaScript caches (auto includes `~/Desktop`) |
| `TEMP_AGE_DAYS` | `3` | Temp items untouched this many days are removed |
| `DM_JOBS` | CPU count (max 16) | How many folders are measured at the same time (disk map and disk usage report) |
| `DU_SPLIT_SECS` | `1` | A folder still being measured after this many seconds is split up and shared between the scanners |
| `REPORT_TIMEOUT` | `90` | Max seconds the clean-up waits for its disk usage report; what was measured by then is still listed |
| `SHUTDOWN_DELAY` | `15` | Seconds in the cancellable shutdown countdown |
| `WORKTREE_SCAN_ROOTS` | auto | Folders to scan for stale git worktrees |
| `WORKTREE_AGE_DAYS` | `7` | Worktrees untouched this many days are candidates |
| `WORKTREE_KEEP_RE` | unset | Regex of worktree paths never removed (e.g. one an MCP server runs from) |
| `PROJECT_SCAN_ROOTS` | auto | Folders to scan for project build folders |
| `PROJECT_QUIET_HOURS` | `24` | Skip a repo with Git activity (commit, checkout …) this recently |
| `PROJECT_KEEP_RE` | unset | Regex of project-folder paths never removed |
| `DOCKER_INFO_TIMEOUT` | `20` | Seconds to wait for the Docker daemon before skipping Docker |
| `KILL_APPS_ASSUME_YES` | `0` | Set `1` to quit apps without confirmation |
| `WORKTREE_CLEAN_ASSUME_YES` | `0` | Set `1` to remove stale worktrees without confirmation |
| `PROJECT_CLEAN_ASSUME_YES` | `0` | Set `1` to delete project build folders without confirmation |
| `DOCKER_CLEAN_ASSUME_YES` | `0` | Set `1` to allow the Docker wipe without confirmation |
| `COLIMA_CLEAN_ASSUME_YES` | `0` | Set `1` to allow the Colima delete without confirmation |
| `OLLAMA_CLEAN_ASSUME_YES` | `0` | Set `1` to allow the Ollama wipe without confirmation |
| `UNINSTALL_ASSUME_YES` | `0` | Set `1` to uninstall the chosen apps without confirmation (their own items only, never the review items) |
| `UNINSTALL_APP_ROOTS` | `/Applications:~/Applications` | Colon-separated folders listed in the uninstaller |
| `UNINSTALL_SPOTLIGHT` | `1` | Set `0` to skip Spotlight when looking for apps and leftovers elsewhere |
| `UNINSTALL_JOBS` | CPU count (max 6) | How many apps the uninstall list measures at the same time |
| `UNINSTALL_NO_SUDO` | `0` | Set `1` so the uninstaller never asks for your password; root-owned items are reported, not removed |
| `MAC_CLEANER_LOG` | temp folder | Write the run log to this file |
| `NO_COLOR` | unset | Set to turn off coloured output |

```bash
# example: shorter per-command timeout
CMD_TIMEOUT=30 ./mac_cleaner.sh
```

### Logging

Every run writes a full log to `mac_cleaner_YYYYMMDD_HHMMSS.log` in your temp
folder (`$TMPDIR`); the path is printed at the end of each run. The log is plain
text, with no colour codes, and each line starts with the time since the run
began, for example `[+02:14]`. It captures each command, its result, the time
taken, the space freed, and for an uninstall every place that was searched.
Set `MAC_CLEANER_LOG=/path/to/file` to choose where it goes.

### It runs in scripts too

Run it non-interactively (piped, or over SSH) and the arrow-key menu falls back to
a numbered prompt, so it still works in automation.

### Project structure

```
mac_cleaner.sh            # entry point: loads lib/* then shows the menu
lib/
├─ colors.sh              # colour palette (truecolor / 256 / 16 / none)
├─ core.sh                # runtime flags, macOS guard, counters, timeouts
├─ logging.sh             # status lines, summary cards, plain-text log file
├─ helpers.sh             # loads helpers/
├─ helpers/
│  ├─ measure.sh          # disk and folder sizes, "biggest wins" ledger
│  ├─ exec.sh             # timeouts, logged commands, the y/N gate
│  ├─ process.sh          # stop a process tree, wait for a PID, own ancestry
│  ├─ parallel.sh         # run cleanup sections side by side, live panel
│  ├─ duscan.sh           # fast parallel folder measurement (splits slow folders)
│  ├─ macos.sh            # privacy (TCC) checks, Trash, Time Machine snapshots
│  ├─ clean.sh            # empty folders, sweep caches, purge stale temp items
│  └─ scan.sh             # where projects live, sweep build artefacts
├─ ui.sh                  # loads ui/
├─ ui/
│  ├─ term.sh             # cursor, alternate screen, window size, key polling
│  ├─ widgets.sh          # progress bar, spinner, live status line, banner
│  ├─ select.sh           # arrow-key menu and checkbox list
│  └─ picker.sh           # scrollable, filterable list that updates live
├─ uninstaller.sh         # uninstall menu; loads uninstall/
├─ uninstall/
│  ├─ apps.sh             # find and measure every app (background scan)
│  ├─ leftovers.sh        # find what one app left behind (parallel search)
│  ├─ remove.sh           # uninstall one app: guard, permissions, receipt
│  └─ packages.sh         # Homebrew / npm / pip / Cargo / gem / binaries
├─ menu.sh                # main menu, action registry, queue runner
├─ diskmap.awk            # treemap layout used by the disk map
└─ actions/
   ├─ cleanup.sh          # the full disk clean-up
   ├─ temp_clean.sh       # stale temp files and old Claude Code sessions
   ├─ free_memory.sh      # release inactive RAM
   ├─ flush_dns.sh        # flush the DNS cache
   ├─ free_ports.sh       # free common dev ports
   ├─ kill_apps.sh        # quit open apps (spares terminals and its own host)
   ├─ worktree_clean.sh   # remove clean, pushed, idle git worktrees
   ├─ project_clean.sh    # delete Git-ignored build folders (plonge rules)
   ├─ docker_clean.sh     # remove all Docker containers and images
   ├─ colima_clean.sh     # delete Colima VMs and their data disks
   ├─ ollama_clean.sh     # remove all Ollama models and caches
   └─ disk_map.sh         # interactive treemap of your home folder
tests/
├─ run_tests.sh           # runner: throwaway HOME, stub system tools
├─ test_cleanup.sh        # Trash, Docker, project folders, clean helpers
├─ test_uninstall.sh      # app list, leftover matching, delete guard, full flow
├─ test_ui.sh             # key parser, progress bar, picker, menus, logging
├─ test_diskscan.sh       # folder scanner, disk usage report, disk map
└─ test_long_runs.sh      # long-running screens must not run out of open files
```

</details>

---

## 🤝 Contributing

Bug reports and pull requests are welcome. When you add a new cache path, include
the tool name and version and the macOS version where you confirmed it. To add a
new maintenance action, drop a file in [lib/actions/](lib/actions/), source it in
[mac_cleaner.sh](mac_cleaner.sh), and register it in the arrays in
[lib/menu.sh](lib/menu.sh). Destructive actions ask through `confirm_action` in
[lib/helpers/exec.sh](lib/helpers/exec.sh), so they never run unattended without
their `*_ASSUME_YES=1`.

The code runs on the bash that ships with macOS (3.2), so nothing has to be
installed. Each function has a header comment that says what it does, its
arguments, the globals it reads or writes, and what it returns.

One bash 3.2 rule to know: do not use process substitution (`< <(cmd)`) in code
that runs repeatedly (per frame, per poll, per item). bash 3.2 keeps its file
descriptor open until the script is back at its top level, and a loop runs out of
them. Use `$(cmd)` with a here-string, a glob, or a file. The reason is written up
in [lib/core.sh](lib/core.sh), and [tests/test_long_runs.sh](tests/test_long_runs.sh)
checks the repeating paths under the 256-file limit of a Terminal window.

Every bug fix comes with a test in [tests/](tests/) that fails without the fix.
Run the tests with macOS's own bash, as CI does:

```bash
/bin/bash tests/run_tests.sh              # everything
/bin/bash tests/run_tests.sh uninstall    # only tests with "uninstall" in the name
```

The tests use a throwaway home folder and stand-ins for `tccutil`, `osascript`,
`launchctl`, `brew` and `docker`, so they never touch your Mac. CI also runs
[ShellCheck](https://www.shellcheck.net) on every file:

```bash
shellcheck --severity=warning -x mac_cleaner.sh lib/*.sh lib/*/*.sh tests/*.sh
```

## 📄 License

[MIT](LICENSE) © macOS Cleaner contributors
