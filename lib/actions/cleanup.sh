#!/usr/bin/env bash
# =============================================================================
# § lib/actions/cleanup.sh  ·  Full disk-space cleanup action
#
#   run_clean - the comprehensive cleanup flow (33 sections: Trash, caches,
#   logs, package-manager stores across every major language/tool ecosystem,
#   plus Microsoft/Adobe/Photos app caches and a safe "System Data" sweep).
#   Registered in the action registry as the "Clean up" queue item.
#
#   Each section is one function, _clean_sN, named after the section number
#   that is printed in its heading and listed in the README. The numbers are
#   labels, not the run order - run_clean (bottom of this file) decides which
#   sections run first, which run side by side, and which run last.
#
#   Requires (sourced earlier): colors.sh, core.sh, logging.sh, helpers.sh
#   Public entry: run_clean
# =============================================================================

# =============================================================================
# § STARTUP BANNER
# =============================================================================
_clean_banner() {
    echo
    say "macOS cleaner starting…"
    kv user     "$USER"
    kv host     "$(hostname)"
    kv date     "$(date '+%Y-%m-%d %H:%M:%S %Z')"
    kv bash     "$BASH_VERSION"
    kv log      "$LOG_FILE"
    kv timeouts "cmd=${CMD_TIMEOUT}s  dir=${DIR_TIMEOUT}s  scan=${SCAN_TIMEOUT}s  (enforced with ${_TIMEOUT_BIN:-a built-in watchdog})"
    kv jobs     "${CLEAN_JOBS} sections at a time"
    say "Disk before: $(disk_free)"
}

# =============================================================================
# § 0 · PRE-RUN DISK USAGE REPORT  (informational - nothing deleted)
# =============================================================================
_clean_s0() {
    section "0 · PRE-RUN DISK USAGE REPORT"

    say "Largest directories before cleanup (use these to guide manual cleanup)"
    report_reset
    report_largest_dirs "$HOME"          "Home directory (~)"          30
    report_largest_dirs "$HOME/Library"  "Library folder (~/Library)"  20
}

# =============================================================================
# § 1 · TRASH
# =============================================================================
_clean_s1() {
    section "1 · TRASH"

    say "Emptying Trash"
    empty_trash
}

# =============================================================================
# § 2 · USER CACHES & LOGS
# =============================================================================
_clean_s2() {
    section "2 · USER CACHES & LOGS"

    say "User Library caches and logs"
    # Swept per-subfolder (NOT a blanket wipe) so iCloud-sync staging caches
    # (com.apple.bird · CloudKit · CloudDocs - may hold un-uploaded data) are skipped.
    sweep_caches "User Library Caches" "$HOME/Library/Caches" "$HOME/Library/Caches/*"
    clean_dir "$HOME/Library/Logs"                                "User Logs"
    clean_dir "$HOME/Library/Application Support/CrashReporter"  "User Crash Reports"
    clean_dir "$HOME/Library/Saved Application State"             "Saved Application State"
}

# =============================================================================
# § 3 · BROWSER CACHES
# =============================================================================
_clean_s3() {
    section "3 · BROWSER CACHES"

    say "Browser caches (Safari, Chrome, Firefox, Brave, Arc, Edge) + Electron apps"

    # Safari (website data such as LocalStorage holds logins - deliberately kept)
    clean_dir "$HOME/Library/Caches/com.apple.Safari"           "Safari cache"
    clean_dir "$HOME/Library/Containers/com.apple.Safari/Data/Library/Caches"  "Safari container cache"

    # Google Chrome
    clean_dir "$HOME/Library/Caches/Google/Chrome"                                   "Chrome cache"
    clean_dir "$HOME/Library/Application Support/Google/Chrome/Default/Cache"        "Chrome Default Cache"
    clean_dir "$HOME/Library/Application Support/Google/Chrome/Default/Code Cache"   "Chrome Code Cache"

    # Firefox
    clean_dir "$HOME/Library/Caches/Firefox"                     "Firefox cache"

    # Brave
    clean_dir "$HOME/Library/Caches/BraveSoftware"               "Brave cache"

    # Arc
    clean_dir "$HOME/Library/Caches/Arc"                         "Arc cache"

    # Every Chromium / Electron profile (all browser profiles, not just Default,
    # plus Slack · Discord · Notion · Figma · Teams · Postman · VS Code & forks …)
    sweep_chromium_caches "Chromium & Electron app caches (all profiles)" "$HOME/Library/Application Support"
}

# =============================================================================
# § 4 · XCODE & APPLE DEVELOPER TOOLS
# =============================================================================
_clean_s4() {
    section "4 · XCODE & APPLE DEVELOPER TOOLS"

    say "Xcode derived data, archives, and simulator caches"
    clean_dir "$HOME/Library/Developer/Xcode/DerivedData"          "Xcode DerivedData"
    clean_dir "$HOME/Library/Developer/Xcode/Archives"             "Xcode Archives (old builds)"
    # iOS · watchOS · tvOS · visionOS device symbols (re-copied on next device connect)
    local ds
    for ds in "$HOME/Library/Developer/Xcode/"*DeviceSupport; do
        [[ -d $ds ]] && clean_dir "$ds" "Xcode ${ds##*/}"
    done
    clean_dir "$HOME/Library/Developer/Xcode/UserData/Previews"    "SwiftUI Previews simulators"
    clean_dir "$HOME/Library/Developer/Xcode/DocumentationCache"   "Xcode documentation cache"
    clean_dir "$HOME/Library/Developer/CoreSimulator/Caches"       "iOS Simulator caches"
    # Simulators whose runtime is no longer installed can never boot again.
    local simctl; simctl=$(simctl_cmd)
    if [[ -n $simctl ]]; then
        run_step "Delete unavailable simulators"  "$simctl delete unavailable"
    else
        skip_missing "Xcode simctl"
    fi
}

# =============================================================================
# § 5 · SWIFT PACKAGE MANAGER · COCOAPODS · CARTHAGE · MINT
# =============================================================================
_clean_s5() {
    section "5 · SWIFT PACKAGE MANAGER · COCOAPODS · CARTHAGE · MINT"

    say "Apple/Swift ecosystem package managers"

    # Swift Package Manager
    clean_dir "$HOME/Library/Caches/org.swift.swiftpm"            "SPM package cache"
    clean_dir "$HOME/Library/org.swift.swiftpm/security"          "SPM security cache"

    # CocoaPods
    if command -v pod &>/dev/null; then
        run_step "CocoaPods cache clean"  "pod cache clean --all"
    fi
    clean_dir "$HOME/Library/Caches/CocoaPods"                    "CocoaPods cache"

    # Carthage
    clean_dir "$HOME/Library/Caches/org.carthage.CarthageKit"     "Carthage cache"

    # Mint (Swift CLI package manager)
    clean_dir "$HOME/.mint"                                        "Mint packages"
}

# =============================================================================
# § 6 · HOMEBREW
# =============================================================================
_clean_s6() {
    section "6 · HOMEBREW"

    say "Homebrew orphan deps, stale formulae, cache, and logs"
    if command -v brew &>/dev/null; then
        # autoremove first - removes formulae installed only as deps that are now orphaned
        run_step "Homebrew autoremove (orphan deps)"  "brew autoremove"
        # cleanup after autoremove so it catches newly orphaned bottles
        run_step "Homebrew cleanup (prune all)"       "brew cleanup --prune=all -s"
        local brew_cache; brew_cache=$(brew --cache 2>/dev/null)
        [[ -n $brew_cache ]] && clean_dir "$brew_cache" "Homebrew downloads cache"
        clean_dir "$HOME/Library/Logs/Homebrew" "Homebrew logs"
    else
        skip_missing "Homebrew"
    fi
}

# =============================================================================
# § 7 · JAVASCRIPT / NODE.JS PACKAGE MANAGERS
#   npm · yarn · pnpm · bun · deno · volta · nvm · fnm · turbo
# =============================================================================
_clean_s7() {
    section "7 · JAVASCRIPT / NODE.JS PACKAGE MANAGERS"

    say "JS/Node package manager caches and stores"

    # CLI cache-clean commands (only run if the tool is present)
    command -v npm  &>/dev/null && run_step "npm cache clean"      "npm cache clean --force"
    command -v yarn &>/dev/null && run_step "yarn cache clean"      "yarn cache clean"
    command -v pnpm &>/dev/null && run_step "pnpm store prune"      "pnpm store prune"
    command -v bun  &>/dev/null && run_step "bun pm cache rm"       "bun pm cache rm"
    command -v deno &>/dev/null && run_step "deno clean"            "deno clean"

    # Cache / store directories
    clean_dir "$HOME/.npm/_cacache"              "npm content-addressable cache"
    clean_dir "$HOME/.npm/_npx"                  "npx package cache"
    clean_dir "$HOME/.npm/_logs"                 "npm logs"
    clean_dir "$HOME/.yarn/cache"                "Yarn classic cache dir"
    clean_dir "$HOME/.yarn/berry/cache"          "Yarn 2+ global cache"
    clean_dir "$HOME/.cache/yarn"                "Yarn cache (~/.cache/yarn)"
    clean_dir "$HOME/Library/Caches/Yarn"        "Yarn cache (Library)"
    clean_dir "$HOME/Library/pnpm/store"         "pnpm store (Library)"
    clean_dir "$HOME/.pnpm-store"                "pnpm store (alt ~/.pnpm-store)"
    clean_dir "$HOME/.bun/install/cache"         "Bun install cache"
    clean_dir "$HOME/.cache/deno"                "Deno cache"
    clean_dir "$HOME/.volta/tmp"                 "Volta tmp"
    clean_dir "$HOME/.volta/cache"               "Volta cache"
    clean_dir "$HOME/.nvm/.cache"                "nvm binary cache"
    clean_dir "$HOME/.cache/node-gyp"            "node-gyp build cache"
    clean_dir "$HOME/.turbo"                     "Turbo global cache"
    clean_dir "$HOME/.cache/turbo"               "Turbo cache (~/.cache)"
    clean_dir "$HOME/.cache/Cypress"             "Cypress binary cache"
    clean_dir "$HOME/Library/Caches/Cypress"     "Cypress cache (Library)"
    clean_dir "$HOME/.cache/playwright"          "Playwright browser binaries cache"
    clean_dir "$HOME/Library/Caches/ms-playwright" "Playwright browsers (Library)"
    clean_dir "$HOME/.cache/puppeteer"           "Puppeteer Chrome downloads"
    clean_dir "$HOME/.cache/chrome-devtools-mcp" "Chrome for Testing (chrome-devtools-mcp)"
    clean_dir "$HOME/.cache/selenium"            "Selenium driver cache"
}

# =============================================================================
# § 8 · JAVASCRIPT / NODE.JS PROJECT-LEVEL CACHES
#   .next/cache · .turbo · .parcel-cache · jest · eslintcache · tsbuildinfo
# =============================================================================
_clean_s8() {
    section "8 · JAVASCRIPT / NODE.JS PROJECT-LEVEL CACHES"

    say "Scanning project directories for JS build artefact caches"

    _scan_and_delete \
        "JS project cache dirs (.next/cache .turbo .parcel-cache jest_cache)" \
        "JS_SCAN_ROOTS" \
        ".next/cache, .turbo, .parcel-cache, jest_cache" \
        \( -type d \( \
            -name ".parcel-cache" \
            -o -name "jest_cache"  \
            -o -name ".turbo"      \
            -o -path "*/.next/cache" \
        \) \)

    _scan_and_delete \
        "JS project cache files (.eslintcache .stylelintcache *.tsbuildinfo)" \
        "JS_SCAN_ROOTS" \
        ".eslintcache, .stylelintcache, *.tsbuildinfo" \
        \( -type f \( \
            -name ".eslintcache"    \
            -o -name ".stylelintcache" \
            -o -name "*.tsbuildinfo"   \
        \) \)
}

# =============================================================================
# § 9 · PYTHON PACKAGE MANAGERS
#   pip · uv · poetry · pipenv · hatch · pdm · pyenv · conda / mamba
# =============================================================================
_clean_s9() {
    section "9 · PYTHON PACKAGE MANAGERS"

    say "Python tooling caches"

    # CLI purge commands
    command -v pip   &>/dev/null && run_step "pip cache purge"      "pip cache purge"
    command -v pip3  &>/dev/null && run_step "pip3 cache purge"     "pip3 cache purge"
    command -v conda &>/dev/null && run_step "conda clean --all"    "conda clean --all --yes"

    # pip
    clean_dir "$HOME/.cache/pip"               "pip cache (~/.cache/pip)"
    clean_dir "$HOME/Library/Caches/pip"       "pip cache (Library)"

    # uv - a running uv/uvx process (e.g. an MCP server started with uvx) holds the
    # cache lock: `uv cache clean` then waits 300s, and deleting files under it
    # breaks that process. Skip both while one is running.
    if pgrep -x uv &>/dev/null || pgrep -x uvx &>/dev/null; then
        skip_in_use "uv cache" "a uv/uvx process is running (often an MCP server) and holds the cache lock" \
            "quit it (close Claude/Codex/IDE sessions), then run: uv cache clean"
    else
        command -v uv &>/dev/null && run_step "uv cache clean" "uv cache clean"
        clean_dir "$HOME/.cache/uv"            "uv cache"
    fi

    # Poetry
    clean_dir "$HOME/.cache/pypoetry"          "Poetry cache (~/.cache)"
    clean_dir "$HOME/Library/Caches/pypoetry"  "Poetry cache (Library)"

    # pipenv
    clean_dir "$HOME/.cache/pipenv"            "pipenv cache"

    # Hatch
    clean_dir "$HOME/.cache/hatch"             "Hatch cache"

    # PDM
    clean_dir "$HOME/.cache/pdm"               "PDM cache"

    # virtualenv seed cache
    clean_dir "$HOME/.cache/virtualenv"        "virtualenv seed cache"

    # pre-commit hook environments (rebuilt on next commit)
    clean_dir "$HOME/.cache/pre-commit"        "pre-commit environments"

    # pyenv build cache
    clean_dir "$HOME/.pyenv/cache"             "pyenv build artefacts"

    # pypa generic cache (pip, build, etc.)
    clean_dir "$HOME/Library/Caches/pypa"     "pypa cache (Library)"

    # Conda / Anaconda / Miniconda / Miniforge / Mambaforge
    clean_dir "$HOME/.conda/pkgs"              "conda pkgs (~/.conda)"
    clean_dir "$HOME/anaconda3/pkgs"           "Anaconda3 pkgs"
    clean_dir "$HOME/miniconda3/pkgs"          "Miniconda3 pkgs"
    clean_dir "$HOME/miniforge3/pkgs"          "Miniforge3 pkgs"
    clean_dir "$HOME/mambaforge/pkgs"          "Mambaforge pkgs"
    clean_dir "$HOME/opt/anaconda3/pkgs"       "Anaconda3 pkgs (opt)"
    clean_dir "$HOME/opt/miniconda3/pkgs"      "Miniconda3 pkgs (opt)"
}

# =============================================================================
# § 10 · PYTHON PROJECT-LEVEL CACHES
#   __pycache__ · .pytest_cache · .mypy_cache · .ruff_cache
# =============================================================================
_clean_s10() {
    section "10 · PYTHON PROJECT-LEVEL CACHES"

    say "Scanning project directories for Python bytecode and tool caches"

    _scan_and_delete \
        "Python project caches (__pycache__ .pytest_cache .mypy_cache .ruff_cache)" \
        "PY_SCAN_ROOTS" \
        "__pycache__, .pytest_cache, .mypy_cache, .ruff_cache" \
        \( -type d \( \
            -name "__pycache__"   \
            -o -name ".pytest_cache" \
            -o -name ".mypy_cache"   \
            -o -name ".ruff_cache"   \
        \) \)
}

# =============================================================================
# § 11 · GO
# =============================================================================
_clean_s11() {
    section "11 · GO"

    say "Go build, module, test, and fuzz caches"
    if command -v go &>/dev/null; then
        run_step "go clean -cache"     "go clean -cache"
        run_step "go clean -modcache"  "go clean -modcache"
        run_step "go clean -testcache" "go clean -testcache"
        run_step "go clean -fuzzcache" "go clean -fuzzcache"
    else
        skip_missing "go"
    fi
    # macOS stores the Go build cache under Library/Caches; also clean directly
    clean_dir "$HOME/Library/Caches/go-build"  "Go build cache (Library/Caches)"
    clean_dir "$HOME/go/pkg/mod/cache"          "Go module download cache"
}

# =============================================================================
# § 12 · RUST  (cargo · rustup · sccache)
# =============================================================================
_clean_s12() {
    section "12 · RUST"

    say "Cargo registry, git, rustup, and sccache"
    local cargo_home=${CARGO_HOME:-$HOME/.cargo}
    if command -v cargo &>/dev/null; then
        clean_dir "$cargo_home/registry/cache"   "Cargo registry cache (tarballs)"
        clean_dir "$cargo_home/registry/src"     "Cargo registry sources (extracted)"
        clean_dir "$cargo_home/git/checkouts"    "Cargo git checkouts"
        clean_dir "$cargo_home/git/db"           "Cargo git databases"
    else
        skip_missing "cargo"
    fi
    clean_dir "$HOME/.rustup/tmp"                 "rustup temp downloads"
    clean_dir "$HOME/.cache/sccache"              "sccache (~/.cache)"
    clean_dir "$HOME/Library/Caches/Mozilla.sccache" "sccache (Library/Caches)"
}

# =============================================================================
# § 13 · C / C++  (ccache · Conan v1/v2 · vcpkg)
# =============================================================================
_clean_s13() {
    section "13 · C / C++"

    say "ccache, Conan, and vcpkg caches"

    # ccache - compiler cache
    if command -v ccache &>/dev/null; then
        run_step "ccache --clear"  "ccache --clear"
    fi
    clean_dir "$HOME/.ccache"                   "ccache (~/.ccache)"
    clean_dir "$HOME/.cache/ccache"             "ccache (~/.cache/ccache)"
    clean_dir "$HOME/Library/Caches/ccache"     "ccache (Library/Caches)"

    # Conan v1
    clean_dir "$HOME/.conan/data"               "Conan v1 package data"

    # Conan v2
    clean_dir "$HOME/.conan2/p"                 "Conan v2 package cache"
    clean_dir "$HOME/.conan2/tmp"               "Conan v2 tmp"

    # vcpkg
    clean_dir "$HOME/.vcpkg/downloads"          "vcpkg downloads"
    clean_dir "$HOME/.vcpkg/buildtrees"         "vcpkg buildtrees"
    clean_dir "$HOME/.vcpkg/packages"           "vcpkg staged packages"
}

# =============================================================================
# § 14 · RUBY  (gem · bundler)
# =============================================================================
_clean_s14() {
    section "14 · RUBY"

    say "RubyGems and Bundler caches"
    if command -v gem &>/dev/null; then
        run_step "gem cleanup"  "gem cleanup"
        # Downloaded .gem archives - installed gems keep working without them.
        # Files only, so Bundler's git-source folder (cache/bundler) is kept.
        local gem_dir; gem_dir=$(gem env gemdir 2>/dev/null)
        if [[ -n $gem_dir && -w $gem_dir/cache ]]; then
            remove_files "$gem_dir/cache" "*.gem" "RubyGems download cache (.gem files)"
        fi
    fi
    clean_dir "$HOME/.bundle/cache"             "Bundler cache"
}

# =============================================================================
# § 15 · PHP  (Composer · PHP-CS-Fixer · PHPStan · Psalm)
# =============================================================================
_clean_s15() {
    section "15 · PHP"

    say "PHP package manager and static-analysis caches"

    # Composer (all three possible cache locations on macOS)
    clean_dir "$HOME/.composer/cache"            "Composer cache (~/.composer)"
    clean_dir "$HOME/.composer/tmp"              "Composer tmp"
    clean_dir "$HOME/.config/composer/cache"     "Composer cache (XDG)"
    clean_dir "$HOME/.cache/composer"            "Composer cache (~/.cache)"

    # PHP static analysis result caches
    clean_dir "$HOME/.cache/phpstan"             "PHPStan result cache"
    clean_dir "/tmp/phpstan"                     "PHPStan /tmp cache"
    clean_dir "$HOME/.cache/psalm"               "Psalm result cache"

    if command -v php-cs-fixer &>/dev/null; then
        run_step "PHP-CS-Fixer cache clear"  "php-cs-fixer clear-cache"
    fi
}

# =============================================================================
# § 16 · .NET  (NuGet)
# =============================================================================
_clean_s16() {
    section "16 · .NET"

    say ".NET NuGet local caches"
    if command -v dotnet &>/dev/null; then
        run_step ".NET NuGet locals --clear"  "dotnet nuget locals all --clear"
    else
        skip_missing "dotnet"
    fi
}

# =============================================================================
# § 17 · JAVA · JVM · KOTLIN · SPRING  (Maven · Gradle · SBT · Ivy · SDKMAN)
# =============================================================================
_clean_s17() {
    section "17 · JAVA · JVM · KOTLIN · SPRING"

    say "Maven, Gradle, SBT, Ivy2, Kotlin, Spring, and SDKMAN caches"

    # Gradle (GRADLE_USER_HOME moves all of ~/.gradle)
    local gradle_home=${GRADLE_USER_HOME:-$HOME/.gradle}
    clean_dir "$gradle_home/caches"             "Gradle caches"
    clean_dir "$gradle_home/daemon"             "Gradle daemon logs"
    clean_dir "$gradle_home/wrapper/dists"      "Gradle wrapper distributions"

    # Maven
    clean_dir "$HOME/.m2/repository/.cache"      "Maven .m2 metadata cache"
    clean_dir "$HOME/.m2/tmp"                    "Maven tmp"
    clean_dir "$HOME/.m2/wrapper/dists"          "Maven wrapper distributions"

    # Ivy2 / SBT
    clean_dir "$HOME/.ivy2/cache"               "Ivy2 / SBT cache"
    clean_dir "$HOME/.sbt/boot"                 "SBT boot cache"

    # Kotlin
    clean_dir "$HOME/.kotlin/daemon"             "Kotlin compiler daemon"
    clean_dir "$HOME/.konan/cache"               "Kotlin/Native cache"
    clean_dir "$HOME/.konan/tmp"                 "Kotlin/Native tmp"

    # Spring Boot DevTools remote restart cache
    clean_dir "$HOME/.spring-boot-devtools"      "Spring Boot DevTools"

    # SDKMAN
    if [[ -d $HOME/.sdkman ]]; then
        clean_dir "$HOME/.sdkman/tmp"            "SDKMAN tmp"
        clean_dir "$HOME/.sdkman/archives"       "SDKMAN archives"
    fi
}

# =============================================================================
# § 18 · ANDROID  (SDK cache · build cache)
# =============================================================================
_clean_s18() {
    section "18 · ANDROID"

    say "Android SDK and incremental build caches"
    clean_dir "$HOME/.android/cache"             "Android SDK cache"
    clean_dir "$HOME/.android/build-cache"       "Android incremental build cache"
}

# =============================================================================
# § 33 · MORE TOOLCHAINS  (Zig · Elixir Hex · Erlang rebar3 · mise)
#   Shared caches from plonge's rules (github.com/mattt/plonge) that the
#   sections above did not cover. All are re-downloaded on the next build.
# =============================================================================
_clean_s33() {
    section "33 · MORE TOOLCHAINS (Zig · Elixir · Erlang · mise)"

    say "Zig, Hex, rebar3, and mise download caches"

    # Zig has no cache-clean command. ZIG_GLOBAL_CACHE_DIR, else the XDG path -
    # Zig uses ~/.cache/zig on macOS too.
    clean_dir "${ZIG_GLOBAL_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/zig}" "Zig global cache"

    # Elixir (mix) Hex package tarballs and Erlang rebar3's Hex cache
    clean_dir "${HEX_HOME:-$HOME/.hex}/packages"  "Hex package cache"
    clean_dir "$HOME/.cache/rebar3/hex"           "rebar3 Hex cache"

    # mise download cache. Installed tool versions are left alone (mise prune
    # --tools would uninstall versions that no config file mentions).
    if command -v mise &>/dev/null; then
        run_step "mise cache prune"  "mise cache prune"
    fi
}

# =============================================================================
# § 19 · DOCKER
# =============================================================================
_clean_s19() {
    section "19 · DOCKER"

    say "Docker build, layer, and image caches"
    if command -v docker &>/dev/null; then
        if docker_ready; then
            # -a  removes ALL unused images, not just dangling ones (much more space freed)
            run_step "docker system prune -a"   "docker system prune -af"
            run_step "docker builder prune"     "docker builder prune -af"

            # Answer collected up front by _clean_docker_ask (jobs can't prompt).
            step "[Docker volume prune  (opt-in)]"
            case $_DOCKER_VOL_ANS in
                yes) run_step "docker volume prune" "docker volume prune -f" ;;
                no)  info "status  : skipped by user"; echo ;;
                *)   info "status  : non-interactive - skipped (run manually: docker volume prune -f)"; echo ;;
            esac
        else
            step "[Docker]"; info "status  : daemon not running - skipping"; echo
        fi
    else
        skip_missing "Docker"
    fi
}

# =============================================================================
# § 20 · INFRA / CLOUD / DEVOPS
#   Terraform · Pulumi · Ansible · kubectl · minikube · AWS · GCP · Azure · Vagrant
# =============================================================================
_clean_s20() {
    section "20 · INFRA / CLOUD / DEVOPS"

    say "Infrastructure tooling caches and logs"

    clean_dir "$HOME/.terraform.d/plugin-cache"   "Terraform plugin cache"
    clean_dir "$HOME/.pulumi/plugins"             "Pulumi plugins (will re-download)"
    clean_dir "$HOME/.ansible/tmp"                "Ansible tmp"
    clean_dir "$HOME/.kube/cache"                 "kubectl cache"
    clean_dir "$HOME/.kube/http-cache"            "kubectl http-cache"
    clean_dir "$HOME/.minikube/cache"             "minikube cache"
    clean_dir "$HOME/.aws/cli/cache"              "AWS CLI cache"
    clean_dir "$HOME/.config/gcloud/logs"         "gcloud logs"
    clean_dir "$HOME/.azure/logs"                 "Azure CLI logs"
    clean_dir "$HOME/.vagrant.d/tmp"              "Vagrant tmp"
}

# =============================================================================
# § 21 · LOCAL DATABASE DEV  (Postgres.app · DBngin · Redis)
#   Logs only - data directories are never touched.
# =============================================================================
_clean_s21() {
    section "21 · LOCAL DATABASE DEV"

    say "Database app logs (data directories skipped)"
    clean_dir "$HOME/Library/Application Support/Postgres/var-*/log"  "Postgres.app logs"
    clean_dir "$HOME/.dbngin/logs"                                     "DBngin logs"
    clean_dir "$HOME/Library/Logs/redis"                               "Redis logs"
}

# =============================================================================
# § 22 · CODE EDITORS & IDEs
#   VS Code · Cursor · Windsurf · JetBrains · Sublime · Zed · Nova · Atom
# =============================================================================
_clean_s22() {
    section "22 · CODE EDITORS & IDEs"

    say "IDE and editor caches, compiled extension data, and logs"
    local as="$HOME/Library/Application Support" caches="$HOME/Library/Caches"

    # ── VS Code (stable) ─────────────────────────────────────────────────────
    clean_subdirs "$as/Code" "VS Code" \
        Cache CachedData CachedExtensions CachedExtensionVSIXs "Code Cache" GPUCache \
        logs CachedProfilesData User/workspaceStorage
    clean_dir "$caches/com.microsoft.VSCode"         "VS Code (Library)"
    clean_dir "$caches/com.microsoft.VSCode.ShipIt"  "VS Code updater"

    # ── VS Code Insiders ─────────────────────────────────────────────────────
    clean_subdirs "$as/Code - Insiders" "VS Code Insiders" \
        Cache CachedData "Code Cache" GPUCache logs

    # ── Cursor ───────────────────────────────────────────────────────────────
    clean_subdirs "$as/Cursor" "Cursor" Cache CachedData "Code Cache" GPUCache logs
    clean_dir "$caches/com.todesktop.230313mzl4w4u92"  "Cursor (Library)"
    # Stale copies of Cursor's settings DB (often ~500 MB each). The live
    # state.vscdb and VS Code's own state.vscdb.backup are never touched.
    remove_files "$as/Cursor/User/globalStorage" "state.vscdb.bak-*" "Cursor state DB backups"

    # ── Windsurf ─────────────────────────────────────────────────────────────
    clean_subdirs "$as/Windsurf" "Windsurf" Cache CachedData "Code Cache" GPUCache logs

    # ── JetBrains (IntelliJ, WebStorm, PyCharm, GoLand, CLion …) ────────────
    clean_dir "$caches/JetBrains"             "JetBrains caches (all IDEs)"
    clean_dir "$HOME/Library/Logs/JetBrains"  "JetBrains logs"

    # ── Sublime Text · Atom · Nova · Zed ─────────────────────────────────────
    clean_dir "$caches/com.sublimetext.4"  "Sublime Text 4 cache"
    clean_dir "$caches/com.github.atom"    "Atom cache"
    clean_dir "$caches/com.panic.Nova"     "Nova cache"
    clean_dir "$caches/dev.zed.Zed"        "Zed cache"
    clean_dir "$HOME/Library/Logs/Zed"     "Zed logs"
}

# =============================================================================
# § 23 · AI ASSISTANTS & LLM TOOLS
#   Claude · ChatGPT · Perplexity · LM Studio · Ollama · Jan · Continue.dev
#   Tabnine · Amazon Q · Sourcegraph Cody · Gemini · Warp · Mistral · Groq
#   GitHub Copilot · Raycast · llm CLI
# =============================================================================
_clean_s23() {
    section "23 · AI ASSISTANTS & LLM TOOLS"

    say "AI assistant app caches, GPU caches, and logs"
    local as="$HOME/Library/Application Support" caches="$HOME/Library/Caches"

    # ── Claude (Anthropic) ───────────────────────────────────────────────────
    clean_subdirs "$as/Claude" "Claude" Cache "Code Cache" GPUCache logs
    clean_dir "$caches/com.anthropic.claudefordesktop"  "Claude desktop (Library)"
    clean_dir "$HOME/Library/Logs/Claude"               "Claude logs (Library)"

    # ── Codex CLI ────────────────────────────────────────────────────────────
    # Downloaded runtimes (~2 GB); Codex fetches them again on next start.
    if pgrep -f "$HOME/.cache/codex-runtimes" &>/dev/null; then
        skip_in_use "Codex runtimes" "a process is running from ~/.cache/codex-runtimes" \
            "quit Codex, then run the cleanup again"
    else
        clean_dir "$HOME/.cache/codex-runtimes"  "Codex runtimes"
    fi
    clean_dir "$caches/Codex"  "Codex cache (Library)"

    # ── ChatGPT (OpenAI) ─────────────────────────────────────────────────────
    clean_subdirs "$as/ChatGPT" "ChatGPT" Cache "Code Cache" GPUCache logs
    clean_dir "$caches/com.openai.chat"     "ChatGPT (Library)"
    clean_dir "$HOME/Library/Logs/ChatGPT"  "ChatGPT logs (Library)"

    # ── Perplexity ───────────────────────────────────────────────────────────
    clean_subdirs "$as/Perplexity" "Perplexity" Cache "Code Cache" GPUCache
    clean_dir "$caches/ai.perplexity.mac"  "Perplexity (Library)"

    # ── LM Studio ────────────────────────────────────────────────────────────
    # NOTE: ~/.cache/lm-studio/models intentionally skipped (user-downloaded models)
    clean_subdirs "$as/LM Studio" "LM Studio" Cache "Code Cache" GPUCache logs
    clean_dir "$caches/ai.lmstudio.app"  "LM Studio (Library)"

    # ── Ollama ───────────────────────────────────────────────────────────────
    # NOTE: ~/.ollama/models intentionally skipped (user-downloaded weights)
    clean_dir "$HOME/.ollama/logs"         "Ollama logs"
    clean_dir "$HOME/.ollama/history"      "Ollama history"
    clean_dir "$HOME/Library/Logs/Ollama"  "Ollama logs (Library)"

    # ── Jan AI ───────────────────────────────────────────────────────────────
    clean_subdirs "$as/jan" "Jan AI" Cache "Code Cache" GPUCache logs
    clean_dir "$caches/jan-app"  "Jan AI (Library)"

    # ── Continue.dev (IDE extension) ─────────────────────────────────────────
    clean_dir "$HOME/.continue/logs"  "Continue.dev logs"
    clean_subdirs "$as/continue.Continue" "Continue.dev" Cache logs

    # ── Tabnine ──────────────────────────────────────────────────────────────
    clean_subdirs "$as/TabNine" "Tabnine" Cache "Code Cache" GPUCache
    clean_dir "$caches/TabNine"  "Tabnine (Library)"
    clean_dir "$HOME/.tabnine"   "Tabnine home dir cache"

    # ── Amazon Q / CodeWhisperer ─────────────────────────────────────────────
    clean_subdirs "$as/Amazon Q" "Amazon Q" Cache "Code Cache" GPUCache logs
    clean_dir "$caches/com.amazon.codewhisperer"  "CodeWhisperer (Library)"

    # ── Sourcegraph Cody ─────────────────────────────────────────────────────
    clean_subdirs "$as/Cody" "Cody" Cache "Code Cache" GPUCache logs
    clean_dir "$caches/com.sourcegraph.cody"  "Cody (Library)"

    # ── Gemini (Google AI) ───────────────────────────────────────────────────
    clean_subdirs "$as/Gemini" "Gemini" Cache "Code Cache" GPUCache logs
    clean_dir "$caches/com.google.Gemini"  "Gemini (Library)"

    # ── Warp (AI-native terminal) ────────────────────────────────────────────
    clean_subdirs "$as/dev.warp.Warp-Stable" "Warp" Cache "Code Cache" GPUCache logs
    clean_dir "$caches/dev.warp.Warp-Stable"  "Warp (Library)"

    # ── Mistral ──────────────────────────────────────────────────────────────
    clean_subdirs "$as/Mistral" "Mistral" Cache "Code Cache" GPUCache logs
    clean_dir "$caches/ai.mistral.mac"  "Mistral (Library)"

    # ── Groq ─────────────────────────────────────────────────────────────────
    clean_subdirs "$as/Groq" "Groq" Cache "Code Cache" GPUCache
    clean_dir "$caches/com.groq.app"  "Groq (Library)"

    # ── GitHub Copilot · Raycast ─────────────────────────────────────────────
    clean_dir "$as/GitHub Copilot/logs"   "GitHub Copilot logs"
    clean_dir "$caches/com.raycast.macos" "Raycast cache"

    # ── llm CLI (Simon Willison) / llama.cpp ─────────────────────────────────
    # llama.cpp has no persistent global cache; llm CLI stores logs here:
    clean_dir "$as/io.datasette.llm/logs"  "llm CLI logs"
    clean_dir "$HOME/.config/llm"          "llm CLI config cache"
}

# =============================================================================
# § 24 · MAIL & MESSAGES
# =============================================================================
_clean_s24() {
    section "24 · MAIL & MESSAGES"

    say "Mail download caches"
    clean_dir "$HOME/Library/Containers/com.apple.mail/Data/Library/Caches"  "Mail caches"
}

# =============================================================================
# § 25 · MICROSOFT OFFICE, TEAMS & OUTLOOK
#   Word · Excel · PowerPoint · Outlook · OneNote · Teams · OneDrive · Edge ·
#   AutoUpdate · Remote Desktop.
#
#   Cache-only: each app's container CACHES are cleared, never its Data store.
#   Outlook's local mail database, account state, and signatures all live
#   OUTSIDE the Caches folder, so they are left untouched.
# =============================================================================
_clean_s25() {
    section "25 · MICROSOFT OFFICE, TEAMS & OUTLOOK"

    say "Microsoft app caches (documents, accounts, and mail are preserved)"
    local as="$HOME/Library/Application Support" caches="$HOME/Library/Caches"
    local containers="$HOME/Library/Containers"

    # ── Office apps - sandboxed container caches ─────────────────────────────
    clean_dir "$containers/com.microsoft.Word/Data/Library/Caches"         "Word cache"
    clean_dir "$containers/com.microsoft.Excel/Data/Library/Caches"        "Excel cache"
    clean_dir "$containers/com.microsoft.Powerpoint/Data/Library/Caches"   "PowerPoint cache"
    clean_dir "$containers/com.microsoft.onenote.mac/Data/Library/Caches"  "OneNote cache"
    clean_dir "$containers/com.microsoft.Outlook/Data/Library/Caches"      "Outlook cache (mail DB preserved)"

    # ── Microsoft Teams (new / v2) ───────────────────────────────────────────
    clean_dir "$containers/com.microsoft.teams2/Data/Library/Caches"                         "Teams cache"
    clean_dir "$HOME/Library/Group Containers/UBF8T346G9.com.microsoft.teams/Library/Caches" "Teams shared cache"
    # classic Teams (legacy, non-sandboxed)
    clean_subdirs "$as/Microsoft/Teams" "Teams (classic)" Cache "Code Cache" GPUCache

    # ── OneDrive · Remote Desktop ────────────────────────────────────────────
    clean_dir "$containers/com.microsoft.OneDrive-mac/Data/Library/Caches"  "OneDrive cache"
    clean_dir "$caches/com.microsoft.OneDrive"                              "OneDrive cache (Library)"
    clean_dir "$containers/com.microsoft.rdc.macos/Data/Library/Caches"     "Remote Desktop cache"

    # ── non-sandboxed / legacy caches ────────────────────────────────────────
    clean_dir "$caches/com.microsoft.Word"         "Word cache (Library)"
    clean_dir "$caches/com.microsoft.Excel"        "Excel cache (Library)"
    clean_dir "$caches/com.microsoft.Powerpoint"   "PowerPoint cache (Library)"
    clean_dir "$caches/com.microsoft.Outlook"      "Outlook cache (Library)"
    clean_dir "$caches/com.microsoft.onenote.mac"  "OneNote cache (Library)"

    # ── Microsoft AutoUpdate ─────────────────────────────────────────────────
    clean_dir "$caches/com.microsoft.autoupdate2"     "Microsoft AutoUpdate cache"
    clean_dir "$caches/com.microsoft.autoupdate.fba"  "Microsoft AutoUpdate (fba) cache"

    # ── Microsoft Edge (Chromium) - Default profile caches ───────────────────
    clean_dir "$caches/com.microsoft.edgemac"  "Edge cache (Library)"
    clean_subdirs "$as/Microsoft Edge/Default" "Edge Default" \
        Cache "Code Cache" GPUCache "Service Worker/CacheStorage"
}

# =============================================================================
# § 26 · ADOBE CREATIVE CLOUD
#   Photoshop · Premiere Pro · After Effects · Lightroom · Illustrator ·
#   Bridge · Creative Cloud desktop.
#
#   Cache-only: the shared Media Cache (video/audio conform + peak files) and
#   per-app caches/logs are cleared. These regenerate from your source media on
#   next launch. Project files, libraries, presets, and settings are NOT touched.
# =============================================================================
_clean_s26() {
    section "26 · ADOBE CREATIVE CLOUD"

    say "Adobe shared media caches, app caches, and logs (projects & presets preserved)"

    # ── shared media cache (Premiere / After Effects / Audition) - often many GB ─
    clean_dir "$HOME/Library/Application Support/Adobe/Common/Media Cache Files"  "Adobe Media Cache Files"
    clean_dir "$HOME/Library/Application Support/Adobe/Common/Media Cache"        "Adobe Media Cache"
    clean_dir "$HOME/Library/Application Support/Adobe/Common/Peak Files"         "Adobe Peak Files (audio waveforms)"
    clean_dir "$HOME/Library/Application Support/Adobe/CameraRaw/Cache"           "Camera Raw cache"

    # ── per-app + generic caches ─────────────────────────────────────────────────
    clean_dir "$HOME/Library/Caches/Adobe"                                        "Adobe caches (Library)"
    clean_dir "$HOME/Library/Caches/com.adobe.Photoshop"                          "Photoshop cache (Library)"
    clean_dir "$HOME/Library/Caches/com.adobe.PremierePro"                        "Premiere Pro cache (Library)"
    clean_dir "$HOME/Library/Caches/com.adobe.AfterEffects"                       "After Effects cache (Library)"
    clean_dir "$HOME/Library/Caches/com.adobe.illustrator"                        "Illustrator cache (Library)"
    clean_dir "$HOME/Library/Caches/com.adobe.acc.AdobeCreativeCloud"             "Creative Cloud desktop cache"
    clean_dir "$HOME/Library/Caches/CSXS"                                         "Adobe CEP/CSXS cache"

    # ── logs ─────────────────────────────────────────────────────────────────────
    clean_dir "$HOME/Library/Logs/Adobe"                                          "Adobe logs"
    clean_dir "$HOME/Library/Logs/CreativeCloud"                                  "Creative Cloud logs"
}

# =============================================================================
# § 27 · PHOTOS  (caches only - your library is never touched)
#
#   Cleans ONLY the Photos app's regenerable caches that live OUTSIDE the
#   library bundle. The ~/Pictures/*.photoslibrary package (originals, edits,
#   albums, faces) is irreplaceable user data: it is NEVER modified, because
#   deleting files inside it can corrupt the library and force a full rebuild.
# =============================================================================
_clean_s27() {
    section "27 · PHOTOS (caches only)"

    say "Photos app caches (your photo library is never touched)"
    clean_dir "$HOME/Library/Caches/com.apple.Photos"                          "Photos app cache"
    clean_dir "$HOME/Library/Caches/com.apple.photolibraryd"                   "photolibraryd cache"
    clean_dir "$HOME/Library/Caches/com.apple.photoanalysisd"                  "photoanalysisd cache"
    clean_dir "$HOME/Library/Containers/com.apple.Photos/Data/Library/Caches"  "Photos container cache"

    # Informational only - the library itself is left untouched (no du scan: it can
    # be huge). Match ANY *.photoslibrary in ~/Pictures (the default name is
    # localized and users rename/keep several), not just the English default.
    if [[ -n "$(find "$HOME/Pictures" -maxdepth 1 -name '*.photoslibrary' -print -quit 2>/dev/null)" ]]; then
        info "Photos Library detected - originals & edits are NEVER deleted."
        info "  reclaim space via Photos ▸ Recently Deleted, or System Settings ▸"
        info "  Apple Account ▸ iCloud ▸ Photos ▸ 'Optimise Mac Storage'."
    fi
}

# =============================================================================
# § 28 · TIME MACHINE LOCAL SNAPSHOTS
#
#   macOS stores local "on-disk" TM snapshots so Time Machine can roll back
#   even when the backup drive is disconnected.  They can accumulate to many
#   GBs on laptops.  Deleting them is safe: your remote TM backup is untouched.
# =============================================================================
_clean_s28() {
    section "28 · TIME MACHINE LOCAL SNAPSHOTS"

    say "Listing and deleting Time Machine local (on-disk) snapshots"
    clean_tm_snapshots
}

# =============================================================================
# § 29 · QUICK LOOK & iOS DEVICE UPDATES
# =============================================================================
_clean_s29() {
    section "29 · QUICK LOOK & iOS DEVICE UPDATES"

    say "Quick Look thumbnail cache and old iOS update files"
    run_step "Quick Look cache regenerate"  "qlmanage -r cache"
    clean_dir "$HOME/Library/iTunes/iPhone Software Updates"  "Old iOS update files"
    clean_dir "$HOME/Library/iTunes/iPad Software Updates"    "Old iPadOS update files"
}

# =============================================================================
# § 30 · SYSTEM CACHES & LOGS  (requires sudo)
# =============================================================================
_clean_s30() {
    section "30 · SYSTEM CACHES & LOGS (sudo)"

    say "System-level caches, ASL logs, and rotated logs"
    if sudo -n true 2>/dev/null || sudo -v; then
        clean_dir "/Library/Caches" "System Library Caches"       "sudo"
        clean_dir "/Library/Logs"   "System Logs"                 "sudo"
        clean_dir "/private/var/log/asl" "Apple System Log (ASL)" "sudo"

        step "[Rotated system logs (*.gz *.[0-9])]"
        info "path    : /private/var/log"
        if sudo rm -rf /private/var/log/*.gz /private/var/log/*.[0-9] 2>/dev/null; then
            (( TOTAL_CLEANED++ ))
            ok "removed rotated system log files"
        else
            warn "no rotated logs found or removal failed"
        fi
        echo

        step "[Purge inactive memory]"
        info "cmd     : sudo purge"
        local -i purge_t0=$SECONDS purge_rc=0
        sudo purge 2>/dev/null || purge_rc=$?
        info "elapsed : $(( SECONDS - purge_t0 ))s   exit: ${purge_rc}"
        if (( purge_rc == 0 )); then
            (( TOTAL_CLEANED++ ))
            ok "released inactive memory back to the kernel"
        else
            warn "purge failed (exit=${purge_rc})"
        fi
        echo
    else
        warn "Skipped system-level cleanup (no sudo access)."
        echo
    fi
}

# =============================================================================
# § 31 · TEMPORARY FILES  (untouched for TEMP_AGE_DAYS days, default 3)
# =============================================================================
_clean_s31() {
    section "31 · TEMPORARY FILES"

    say "Removing temp items untouched for ${TEMP_AGE_DAYS}+ days (in-use items are kept)"
    temp_purge_all
}

# =============================================================================
# § 32 · SYSTEM DATA  (app cache sweep · diagnostics · informational)
#
#   "System Data" in Storage settings is a residual catch-all - everything not
#   counted as Apps/Photos/Documents/etc. The portion that is genuinely safe to
#   reclaim is regenerable app caches and crash reports, handled here. The other
#   big contributors are deliberately left alone:
#     • Time Machine local snapshots → §28 (blessed tmutil thinning)
#     • system caches / logs (sudo)  → §30
#     • core OS / SSV-sealed files   → UNSAFE, never touched
#     • iOS device backups           → irreplaceable user data → REPORTED only
#     • the Photos .photoslibrary    → see §27 (never touched)
#
#   NB: we intentionally do NOT blanket-wipe ~/Library/Caches - CloudKit
#   (com.apple.bird) can stage un-uploaded user data there. We sweep only the
#   per-app sandbox cache subfolders, which regenerate cleanly.
# =============================================================================
_clean_s32() {
    section "32 · SYSTEM DATA (app caches · diagnostics)"

    say "Reclaiming regenerable app caches counted under \"System Data\""

    # ── per-app sandbox caches (regenerate on next launch) ───────────────────────
    sweep_caches "App container caches"   "$HOME/Library/Containers"        "*/Data/Library/Caches"
    sweep_caches "Group container caches" "$HOME/Library/Group Containers"  "*/Library/Caches"

    # ── crash / diagnostic reports (post-mortem artefacts; safe to remove) ───────
    clean_dir "$HOME/Library/Logs/DiagnosticReports"  "User crash & diagnostic reports"
    if sudo -n true 2>/dev/null; then
        clean_dir "/Library/Logs/DiagnosticReports"   "System crash & diagnostic reports" "sudo"
    else
        step "[System crash & diagnostic reports]"
        info "status  : needs sudo (only granted if you authorised §30) - skipped"
        echo
    fi

    # ── informational only: large, IRREPLACEABLE items we never auto-delete ──────
    say "Large items counted as System Data that are NEVER auto-deleted:"
    local ios_backup="$HOME/Library/Application Support/MobileSync/Backup"
    if [[ -d $ios_backup ]]; then
        info "iOS/iPadOS backups : $(human_size "$(dir_size_kb "$ios_backup")")  (~/Library/Application Support/MobileSync/Backup)"
        info "  → manage in Finder ▸ select device ▸ Manage Backups to remove old device backups."
    fi
    info "Tip: in Disk Utility choose View ▸ Show APFS Snapshots to see snapshot and"
    info "     purgeable space - the most accurate view of reclaimable System Data."
}

# =============================================================================
# § SUMMARY
# =============================================================================
_clean_summary() {
    section "SUMMARY"

    say "Post-cleanup disk usage (compare with pre-run report above)"
    report_reset          # measure again: the numbers changed
    report_largest_dirs "$HOME"          "Home directory (~) after cleanup"          30
    report_largest_dirs "$HOME/Library"  "Library folder (~/Library) after cleanup"  20

    # ── where the space came from: the biggest wins of this run ─────────────
    local kb label
    local -a wins=()
    while IFS=$'\t' read -r kb label; do
        [[ -n $label ]] && wins+=("dim:$(printf '%10s  %s' "$(human_size "$kb")" "${label:0:44}")")
    done < <(ledger_top 8)

    # ── the recap card: the outcome first, the detail after ─────────────────
    human_duration "$(( $(date +%s) - START_TIME ))"
    local -a card=(
        "ok:$(human_size "$TOTAL_FREED_KB") freed · disk now $(disk_free)"
        "ok:${TOTAL_CLEANED} step(s) done in ${REPLY}"
    )
    (( TOTAL_SKIPPED_MISSING > 0 ))   && card+=("dim:${TOTAL_SKIPPED_MISSING} step(s) skipped - tool or folder not on this Mac")
    (( TOTAL_SKIPPED_PROTECTED > 0 )) && card+=("warn:${TOTAL_SKIPPED_PROTECTED} step(s) skipped or partial - in use or protected")
    (( TOTAL_TIMEDOUT > 0 ))          && card+=("warn:${TOTAL_TIMEDOUT} step(s) timed out")
    (( TOTAL_FAILED > 0 ))            && card+=("fail:${TOTAL_FAILED} step(s) failed - see the lines marked ✗ / ▲ above")
    (( TOTAL_TCC_BLOCKED > 0 ))       && card+=("warn:${TOTAL_TCC_BLOCKED} folder(s) blocked by macOS privacy and left as-is")
    if (( ${#wins[@]} > 0 )); then
        card+=("" "Biggest wins" "${wins[@]}")
    fi
    summary_card "Cleanup complete" "${card[@]}"
    info "Full log: ${LOG_FILE}"

    (( TOTAL_TCC_BLOCKED > 0 )) && fda_hint
    info "Tip : restart your Mac to release caches still held by running processes."
    info "Note: apps rebuild their caches on next launch - first start may be slightly slower."
    echo
}

# =============================================================================
# § _clean_docker_ask
#
#   Asks the §19 volume-prune question before the parallel phase starts:
#   background jobs read from /dev/null, so they cannot prompt. --volumes
#   removes unnamed volumes - opt-in only because named volumes may hold
#   database data (postgres, mysql, redis) that the user wants to keep.
#   Sets _DOCKER_VOL_ANS to yes / no / skip.
# =============================================================================
_DOCKER_VOL_ANS=skip
_clean_docker_ask() {
    _DOCKER_VOL_ANS=skip
    [[ -t 0 ]] || return 0   # only prompt when stdin is a terminal
    docker_ready || return 0

    step "[Docker volume prune  (opt-in)]"
    info "cmd     : docker volume prune -f"
    info "WARNING : This removes ALL unnamed Docker volumes."
    info "          Named volumes (databases, persistent data) are NOT affected."
    printf '    Prune unnamed Docker volumes? [y/N] '
    local ans; read -r ans
    [[ $ans == [yY] ]] && _DOCKER_VOL_ANS=yes || _DOCKER_VOL_ANS=no
    echo
}

# =============================================================================
# § run_clean
#
#   Full cleanup flow - all 33 sections, in three phases:
#     1. in order: banner, disk report, Trash (§1) and the broad sweeps of
#        ~/Library/Caches, ~/Library/Logs and every Chromium/Electron profile
#        (§2-§3). Many later sections clear a sub-folder of these, so they
#        finish first: two deletes racing on one folder report errors.
#     2. in parallel, CLEAN_JOBS at a time: the per-tool sections §4-§27,
#        §29 and §33, which never share a folder. Output still prints in order.
#     3. in order: §28 and §30 (may ask for your password), then §31 + §32
#        side by side, then the summary.
#   Called from show_main_menu when the user selects option 1.
# =============================================================================
run_clean() {
    ledger_reset
    _clean_banner
    _clean_s0
    _clean_s1
    _clean_s2
    _clean_s3

    _clean_docker_ask
    run_parallel _clean_s4  _clean_s5  _clean_s6  _clean_s7  _clean_s8  _clean_s9 \
                 _clean_s10 _clean_s11 _clean_s12 _clean_s13 _clean_s14 _clean_s15 \
                 _clean_s16 _clean_s17 _clean_s18 _clean_s19 _clean_s20 _clean_s21 \
                 _clean_s22 _clean_s23 _clean_s24 _clean_s25 _clean_s26 _clean_s27 \
                 _clean_s29 _clean_s33

    _clean_s28
    _clean_s30
    run_parallel _clean_s31 _clean_s32

    _clean_summary
}
