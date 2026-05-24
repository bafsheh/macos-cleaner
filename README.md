# macos-cleaner

A safe, comprehensive macOS disk-space cleaner for developers.  
Clears caches, logs, package-manager stores, and Trash in one run.  
**Never touches personal files** (Documents, Desktop, Pictures, Downloads, etc.).

---

## What it cleans

| # | Section |
|---|---------|
| 0 | Pre-run disk usage report (informational) |
| 1 | Trash — user + all mounted volumes |
| 2 | User Library caches and logs |
| 3 | Browser caches — Safari, Chrome, Firefox, Brave, Arc |
| 4 | Xcode — DerivedData, Archives, iOS DeviceSupport, Simulator |
| 5 | Swift PM · CocoaPods · Carthage · Mint |
| 6 | Homebrew — autoremove orphan deps, cleanup, logs |
| 7 | JavaScript / Node.js package managers — npm, yarn, pnpm, bun, deno, volta, nvm, turbo |
| 8 | JavaScript project-level caches — .next/cache, .turbo, .parcel-cache, jest, eslintcache |
| 9 | Python package managers — pip, uv, poetry, pipenv, hatch, pdm, pyenv, conda/mamba |
| 10 | Python project-level caches — \_\_pycache\_\_, .pytest\_cache, .mypy\_cache, .ruff\_cache |
| 11 | Go — build, module, test, and fuzz caches |
| 12 | Rust — Cargo registry/git, rustup, sccache |
| 13 | C / C++ — ccache, Conan v1/v2, vcpkg |
| 14 | Ruby — gem cleanup, Bundler cache |
| 15 | PHP — Composer, PHPStan, Psalm, PHP-CS-Fixer |
| 16 | .NET — NuGet local caches |
| 17 | Java / JVM / Kotlin / Spring — Gradle, Maven, SBT, Ivy2, SDKMAN |
| 18 | Android — SDK cache, incremental build cache |
| 19 | Docker — unused images (`-a`), build cache, optional volume prune |
| 20 | Infra / Cloud / DevOps — Terraform, Pulumi, Ansible, kubectl, minikube, AWS, GCP, Azure |
| 21 | Local DB dev logs — Postgres.app, DBngin, Redis (data dirs never touched) |
| 22 | Code editors / IDEs — VS Code, Cursor, Windsurf, JetBrains, Sublime, Zed, Nova |
| 23 | AI assistants — Claude, ChatGPT, Perplexity, LM Studio, Ollama, Jan, Tabnine, Amazon Q, Cody, Gemini, Warp, Mistral, Groq, Copilot |
| 24 | Mail caches |
| 25 | Time Machine local (on-disk) snapshots |
| 26 | Quick Look thumbnails · old iOS/iPadOS update files |
| 27 | System caches and logs (sudo) |
| 28 | Old /tmp items (>3 days) |
| — | Post-run disk usage report + summary |

---

## Requirements

| Requirement | Notes |
|---|---|
| macOS 12+ | Tested on macOS 26 Tahoe |
| bash 3.2+ | Ships with macOS — no extra install needed |
| sudo | Only for system-cache and Time Machine steps — you will be prompted |

### Optional but recommended

```bash
brew install coreutils   # provides gtimeout → more reliable per-command timeouts
```

---

## Usage

```bash
chmod +x mac_cleaner.sh
./mac_cleaner.sh
```

### Environment overrides

| Variable | Default | Description |
|---|---|---|
| `CMD_TIMEOUT` | `60` | Per-command timeout in seconds |
| `DIR_TIMEOUT` | `120` | Per-directory delete timeout in seconds |
| `SCAN_TIMEOUT` | `60` | Project-scan find timeout in seconds |
| `PY_SCAN_ROOTS` | auto | Space-separated dirs for Python project cache scan |
| `JS_SCAN_ROOTS` | auto | Space-separated dirs for JS project cache scan |

```bash
# examples
CMD_TIMEOUT=30 ./mac_cleaner.sh
PY_SCAN_ROOTS="$HOME/src $HOME/work" ./mac_cleaner.sh
```

---

## What it intentionally skips

- **Personal files** — Documents, Desktop, Downloads, Pictures, Music, Movies
- **Docker named volumes** — may contain database data; prompted separately
- **Ollama / LM Studio models** — user-downloaded weights; too large and intentional
- **Maven local repository** — only the metadata `.cache` subdir is removed, not packages
- **Homebrew formulae themselves** — only the download cache is cleared

---

## Logging

Every run writes a full timestamped log to:

```
/tmp/mac_cleaner_YYYYMMDD_HHMMSS.log
```

The log includes stdout/stderr from every command, exit codes, elapsed times, and freed-space measurements.

---

## Timeout behaviour

Each step runs under a timeout watchdog (using `gtimeout` if available, falling back to a pure-bash watchdog). A timed-out step is marked in the log and counted separately in the summary — it never aborts the rest of the run.

---

## Contributing

Bug reports and PRs are welcome.  
When adding a new cache path please include:

- The tool name and version where you confirmed the path
- The macOS version where you tested it

---

## License

MIT — see [LICENSE](LICENSE).
