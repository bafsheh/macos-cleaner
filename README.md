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
  ╔══════════════════════════════════════════════════════╗
  ║   macOS Cleaner    -    v1.3.0                        ║
  ╠══════════════════════════════════════════════════════╣
  ║   Safe disk-space cleaner + maintenance              ║
  ║   Disk: 249Gi free of 460Gi                          ║
  ╚══════════════════════════════════════════════════════╝

  What would you like to do?
  ❯  Cleanup & maintenance
     Uninstall an app or package
     Exit
```

### Step 1. Move and choose

- Use the **`↑` and `↓` arrow keys** to move up and down.
- Press **`Return (↵)`** to choose the highlighted (`❯`) item.

Pick **Cleanup & maintenance** to open the checklist.

### Step 2. Tick what you want

```
  Cleanup & maintenance - choose actions to run
  ↑ ↓ move  ·  space toggle  ·  a all  ·  Enter run  ·  q cancel

  ❯  [✓]  Clean up             (caches · logs · package stores · Trash)
     [ ]  Free up memory       (release inactive & cached RAM)
     [ ]  Flush DNS cache
     [✓]  Free common dev ports
     [ ]  Kill all open apps   (spares terminals · IDEs · Finder)
     [ ]  Docker - remove ALL containers & images      ⚠ destructive
     [ ]  Ollama / llama - remove ALL models & caches  ⚠ destructive
     [ ]  Shut down Mac when all actions finish
        Back - return to main menu
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
When it finishes, you see a summary of how much space it freed. You return to the
menu, where you can run more or pick **Exit** to finish.

> 💡 Some steps ask for your **Mac password**. That is normal. macOS requires it
> to clean system-level files. Nothing leaves your Mac.

---

## 🧰 What each option does

| Option | In plain English | Good to know |
|---|---|---|
| **Clean up** | The main event. Clears caches, logs, leftover app and tool files, and the Trash. | Safe. Frees the most space. |
| **Free up memory** | Releases unused memory so your Mac feels snappier. | Safe. Deletes no files. |
| **Flush DNS cache** | Refreshes your Mac's address book for websites, which fixes some loading issues. | Asks for your password. |
| **Free common dev ports** | Closes stuck background programs that block common developer connections. | For developers. Leaves normal apps alone. |
| **Kill all open apps** | Quits all your open apps at once. | Asks first. Always spares your Terminal, editor, and Finder. |
| **Docker, remove ALL** | Wipes all Docker containers and images. | ⚠️ For developers. Deletes a lot. Pick it only if you mean it. |
| **Ollama, remove ALL** | Deletes all downloaded AI models. | ⚠️ Large re-downloads later if you need them again. |
| **Shut down when done** | Turns the Mac off after everything finishes. | You get a countdown. Press any key to cancel. |

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

**Did it delete my files?**
No. It removes only regenerable junk. Want proof? Every run saves a full log to
`/tmp/mac_cleaner_…log` that lists what happened.

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
| 0 | Disk usage report before cleaning (info only) |
| 1 | Trash, yours plus all connected drives |
| 2 | System and app caches and logs in your Library |
| 3 | Browser caches: Safari, Chrome, Firefox, Brave, Arc |
| 4 | Xcode: DerivedData, Archives, device support, Simulator |
| 5 | Apple dev tools: Swift PM, CocoaPods, Carthage, Mint |
| 6 | Homebrew: orphaned packages, cleanup, logs |
| 7 | JavaScript / Node: npm, yarn, pnpm, bun, deno, volta, nvm, turbo |
| 8 | JavaScript project caches: `.next/cache`, `.turbo`, jest, eslint |
| 9 | Python tools: pip, uv, poetry, pipenv, hatch, pdm, pyenv, conda |
| 10 | Python project caches: `__pycache__`, pytest, mypy, ruff |
| 11 | Go: build, module, test, and fuzz caches |
| 12 | Rust: Cargo, rustup, sccache |
| 13 | C / C++: ccache, Conan, vcpkg |
| 14 | Ruby: gem cleanup, Bundler cache |
| 15 | PHP: Composer, PHPStan, Psalm, PHP-CS-Fixer |
| 16 | .NET: NuGet local caches |
| 17 | Java / Kotlin: Gradle, Maven, SBT, Ivy2, SDKMAN |
| 18 | Android: SDK and build caches |
| 19 | Docker: unused images and build cache |
| 20 | Cloud / DevOps: Terraform, Pulumi, Ansible, kubectl, AWS, GCP, Azure |
| 21 | Local database dev logs (your data is never touched) |
| 22 | Code editors: VS Code, Cursor, JetBrains, Sublime, Zed, and more |
| 23 | AI assistants: ChatGPT, Perplexity, LM Studio, Ollama, and more |
| 24 | Mail caches |
| 25 | Time Machine local snapshots |
| 26 | Quick Look thumbnails and old iOS update files |
| 27 | System caches and logs (needs your password) |
| 28 | Old temporary files (older than 3 days) |
| (end) | Disk usage report after cleaning, plus a summary |

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
- **Your Terminal, editor, and Finder**: always spared when quitting apps

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
| `PY_SCAN_ROOTS` | auto | Folders to scan for Python caches |
| `JS_SCAN_ROOTS` | auto | Folders to scan for JavaScript caches |
| `SHUTDOWN_DELAY` | `15` | Seconds in the cancellable shutdown countdown |
| `KILL_APPS_ASSUME_YES` | `0` | Set `1` to quit apps without confirmation |
| `DOCKER_CLEAN_ASSUME_YES` | `0` | Set `1` to allow the Docker wipe without confirmation |
| `OLLAMA_CLEAN_ASSUME_YES` | `0` | Set `1` to allow the Ollama wipe without confirmation |
| `NO_COLOR` | unset | Set to turn off coloured output |

```bash
# example: shorter per-command timeout
CMD_TIMEOUT=30 ./mac_cleaner.sh
```

### Logging

Every run writes a full timestamped log to `/tmp/mac_cleaner_YYYYMMDD_HHMMSS.log`.
It captures each command, its result, the time taken, and the space freed.

### It runs in scripts too

Run it non-interactively (piped, or over SSH) and the arrow-key menu falls back to
a numbered prompt, so it still works in automation.

### Project structure

```
mac_cleaner.sh          # entry point: loads lib/* then shows the menu
lib/
├─ colors.sh            # colour palette
├─ core.sh              # runtime flags, macOS guard, timeouts
├─ logging.sh           # status messages
├─ helpers.sh           # disk and execution helpers
├─ ui.sh                # menu, multi-select, spinner, progress bar
├─ uninstaller.sh       # app / package uninstaller
├─ menu.sh              # main menu, action registry, queue runner
└─ actions/
   ├─ cleanup.sh        # the full disk clean-up
   ├─ free_memory.sh    # release inactive RAM
   ├─ flush_dns.sh      # flush the DNS cache
   ├─ free_ports.sh     # free common dev ports
   ├─ kill_apps.sh      # quit open apps (spares terminals / IDEs / Finder)
   ├─ docker_clean.sh   # remove all Docker containers and images
   └─ ollama_clean.sh   # remove all Ollama models and caches
```

</details>

---

## 🤝 Contributing

Bug reports and pull requests are welcome. When you add a new cache path, include
the tool name and version and the macOS version where you confirmed it. To add a
new maintenance action, drop a file in [lib/actions/](lib/actions/) and register
it in the arrays in [lib/menu.sh](lib/menu.sh).

## 📄 License

[MIT](LICENSE) © macOS Cleaner contributors
