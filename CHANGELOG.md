# Changelog

All notable changes to this project will be documented here.  
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

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
