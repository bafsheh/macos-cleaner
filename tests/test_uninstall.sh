#!/usr/bin/env bash
# =============================================================================
# tests/test_uninstall.sh  ·  Tests for the app and package uninstaller
#
#   Sourced by tests/run_tests.sh. Every test builds fake .app bundles and
#   leftovers under the throwaway HOME; tccutil, osascript, launchctl,
#   lsregister and brew are stubs that only record how they were called.
#
#   What must hold:
#     • an uninstall removes the app AND everything that is provably its own
#     • it never removes another app's data - not a sibling whose bundle ID
#       extends ours, not an app whose name merely contains ours
#     • every delete passes the allow-list guard
#     • nothing is removed without a yes
# =============================================================================

# Makes a fake app:  make_app NAME BUNDLE_ID [BUNDLE_NAME] [DIR]
make_app() {
    local name=$1 bid=$2 short=${3:-$1} dir=${4:-$HOME/Applications}
    local c="$dir/$name.app/Contents"
    mkdir -p "$c/MacOS"
    cat > "$c/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$bid</string>
<key>CFBundleName</key><string>$short</string>
<key>CFBundleShortVersionString</key><string>2.4.1</string>
<key>CFBundleExecutable</key><string>$short</string>
</dict></plist>
PLIST
    dd if=/dev/zero of="$c/MacOS/$short" bs=1024 count=64 2>/dev/null
}

# Stubs for every system tool the uninstaller calls.
stub_system_tools() {
    local t
    for t in tccutil launchctl lsregister brew; do make_stub "$t"; done
    make_stub osascript 0          # "0 login items"
}

# Writes the "path<TAB>bundle-id" index the app scan normally provides.
make_meta() {
    local a
    for a in "$HOME"/Applications/*.app; do
        app_identity "$a"; printf '%s\t%s\n' "$a" "${APP_BID:--}"
    done > "$TEST_TMP/meta.tsv"
}

# The scene used by the flow tests: Foo Editor, with leftovers of its own, a
# sibling app (Foo Editor Beta) and look-alikes that must all survive.
make_foo_scene() {
    local L="$HOME/Library"
    make_app "Foo Editor"      com.acme.FooEditor      Foo
    make_app "Foo Editor Beta" com.acme.FooEditor.beta FooBeta
    make_app "Xfoo"            org.other.Xfoo          Xfoo
    mkdir -p "$L/Application Support/Foo" "$L/Application Support/Xfoo" "$L/Application Support/FooBeta" \
        "$L/Caches/com.acme.FooEditor" "$L/Caches/com.acme.FooEditor.beta" "$L/Preferences" \
        "$L/Saved Application State/com.acme.FooEditor.savedState" "$L/Containers/com.acme.FooEditor" \
        "$L/Group Containers/ABCDE12345.com.acme.FooEditor" "$L/Logs/Foo Editor" "$L/LaunchAgents" \
        "$L/Logs/DiagnosticReports" "$HOME/.foo" "$HOME/Documents"
    echo x > "$L/Application Support/Foo/data.db"
    echo x > "$L/Application Support/Xfoo/keep"
    echo x > "$L/Application Support/FooBeta/keep"
    echo x > "$L/Caches/com.acme.FooEditor/blob"
    echo x > "$L/Caches/com.acme.FooEditor.beta/keep"
    echo x > "$L/Preferences/com.acme.FooEditor.plist"
    echo x > "$L/Preferences/com.acme.FooEditor.helper.plist"
    echo x > "$L/Preferences/com.acme.FooEditor.beta.plist"
    echo x > "$L/Preferences/com.acme.FooEditorX.plist"
    echo x > "$L/LaunchAgents/com.acme.FooEditor.agent.plist"
    echo x > "$L/Logs/DiagnosticReports/Foo-2026-11-01-101010.ips"
    echo x > "$L/Logs/DiagnosticReports/Foobar-2026-11-01-101010.ips"
    echo x > "$HOME/.foo/config"
    echo mine > "$HOME/Documents/notes.txt"
    stub_system_tools
    make_meta
}

# ── app discovery ───────────────────────────────────────────────────────────

test_app_list_shows_user_apps_and_hides_helpers_and_build_output() {
    assert "an app in the app folder is listed"   app_is_listable "$HOME/Applications/Foo.app"
    assert "an app in a sub-folder is listed"     app_is_listable "$HOME/Applications/Suite/Foo.app"
    assert "an app in Downloads is listed"        app_is_listable "$HOME/Downloads/Foo.app"
    refute "a helper inside a bundle is hidden"   app_is_listable "$HOME/Applications/Foo.app/Contents/Helpers/Bar.app"
    refute "an app in ~/Library is hidden"        app_is_listable "$HOME/Library/Application Support/x/Bar.app"
    refute "an app in the Trash is hidden"        app_is_listable "$HOME/.Trash/Foo.app"
    refute "a system app is hidden"               app_is_listable "/System/Applications/Mail.app"
    refute "node_modules content is hidden"       app_is_listable "$HOME/code/web/node_modules/electron/dist/Electron.app"
    refute "build output is hidden"               app_is_listable "$HOME/code/app/build/Debug/My.app"
    refute "something that is not an app"         app_is_listable "$HOME/Applications/readme.txt"
}

test_app_scan_lists_every_app_with_its_size_and_bundle_id() {
    make_app "Foo Editor" com.acme.FooEditor Foo
    make_app "Bar"        org.bar.Bar
    make_app "Nested"     org.nested.App Nested "$HOME/Applications/Suite"
    mkdir -p "$TEST_TMP/scan"
    : > "$TEST_TMP/scan/rows.tsv"; : > "$TEST_TMP/scan/meta.tsv"; : > "$TEST_TMP/scan/done"

    _apps_scan "$TEST_TMP/scan"          # the scan itself, run to completion

    assert "the scan marks itself finished" test -e "$TEST_TMP/scan/finished"
    assert "all three apps are counted"     test "$(cat "$TEST_TMP/scan/total")" -eq 3
    assert "every app was measured"         test "$(wc -l < "$TEST_TMP/scan/done" | tr -d ' ')" -eq 3
    assert "the bundle ID index has the app" grep -q "Foo Editor.app	com.acme.FooEditor$" "$TEST_TMP/scan/meta.tsv"

    # The picker shows the last row per app: by then each carries a real size.
    _picker_load "$TEST_TMP/scan/rows.tsv" '' name
    assert "three rows are shown, got ${#_PK_ID[@]}" test "${#_PK_ID[@]}" -eq 3
    assert "rows are sorted by name: ${_PK_LABEL[*]}" test "${_PK_LABEL[0]}" = "Bar"
    local kb
    for kb in "${_PK_KB[@]}"; do assert "every size is known, got $kb" test "$kb" -gt 0; done
}

test_app_identity_rejects_a_bundle_id_that_is_not_a_plain_identifier() {
    make_app "Evil" 'com.evil" & do shell script "rm'
    app_identity "$HOME/Applications/Evil.app"
    assert "a bundle ID with quotes is discarded, got [$APP_BID]" test -z "$APP_BID"
    assert "the name still comes from the bundle" test "$APP_NAME" = "Evil"
}

# ── leftover matching ───────────────────────────────────────────────────────

test_leftover_matching_is_exact_never_a_substring() {
    make_app "Code" com.microsoft.VSCode
    make_app "Code Insiders" com.microsoft.VSCode.insiders
    make_meta
    un_set_identity "$HOME/Applications/Code.app" "$TEST_TMP/meta.tsv"

    assert "the bundle ID itself"              un_match_bid "com.microsoft.VSCode"
    assert "the ID with a suffix"              un_match_bid "com.microsoft.VSCode.plist"
    assert "IDs match in any case"             un_match_bid "com.microsoft.vscode.savedState"
    refute "an ID that merely starts the same" un_match_bid "com.microsoft.VSCodeInsiders.plist"
    refute "a different app of the vendor"     un_match_bid "com.microsoft.Word.plist"
    refute "a sibling app's own files"         un_match_bid "com.microsoft.VSCode.insiders.plist"

    assert "a group container with a team prefix" un_match_group "UBF8T346G9.com.microsoft.VSCode"
    assert "a group.* container"                  un_match_group "group.com.microsoft.VSCode.shared"
    refute "a sibling's group container"          un_match_group "group.com.microsoft.VSCode.insiders"

    assert "the app's exact name"             un_match_name "Code"
    assert "the name with a version"          un_match_name "Code 2"
    refute "a longer name that contains it"   un_match_name "Xcode"
    refute "a name that starts with it"       un_match_name "CodeEdit"
    refute "a name with a word after it"      un_match_name "Code Helper"
}

test_generic_app_names_are_never_searched_by_name() {
    make_app "Helper" com.acme.helperapp Electron
    un_set_identity "$HOME/Applications/Helper.app"
    assert "no name is used for matching, got: ${UN_NAMES[*]:-}" test "${#UN_NAMES[@]}" -eq 0
    refute "a folder called Electron is not ours" un_match_name "Electron"
    assert "the bundle ID still matches"          un_match_bid "com.acme.helperapp"
}

# ── the delete guard ────────────────────────────────────────────────────────

test_delete_guard_allows_app_data_and_refuses_everything_else() {
    local p
    for p in "$HOME/Applications/Foo.app" \
             "$HOME/Library/Caches/com.acme.Foo" \
             "$HOME/Library/Application Support/Google/Chrome" \
             "$HOME/Library/Preferences/com.acme.Foo.plist" \
             "$HOME/.config/foo" "$HOME/.foo" "$HOME/Downloads/Foo.app" \
             "/Library/LaunchDaemons/com.acme.Foo.plist" \
             "/Library/Application Support/Foo" \
             "/private/var/db/receipts/com.acme.Foo.bom"; do
        assert "may delete: $p" un_safe_target "$p"
    done
    for p in "" "/" "$HOME" "$HOME/" "$HOME/Library" "$HOME/Library/Caches" "$HOME/Library/Preferences/" \
             "$HOME/Documents" "$HOME/Desktop" "$HOME/.ssh" "$HOME/.ssh/id_ed25519" "$HOME/.config" \
             "$HOME/Library/Mobile Documents/com~apple~CloudDocs" "$HOME/Library/Keychains/login.keychain-db" \
             "$HOME/Library/Caches/../../Documents" "$HOME/Library//Caches" "relative/path" \
             "/Applications" "/Library" "/Library/Frameworks/Foo.framework" "/System/Applications/Mail.app" \
             "/usr/local/bin/foo" "/etc/hosts" "/Users" "/Users/Shared"; do
        refute "must refuse: [$p]" un_safe_target "$p"
    done
}

test_removal_refuses_a_path_the_guard_rejects() {
    mkdir -p "$HOME/Documents"; echo mine > "$HOME/Documents/notes.txt"
    refute "deleting ~/Documents is refused" _un_rm "$HOME/Documents"
    assert "the folder is untouched" test -f "$HOME/Documents/notes.txt"
    assert "the reason says why: $UN_RM_NOTE" test "${UN_RM_NOTE#refused}" != "$UN_RM_NOTE"
}

# ── the full uninstall ──────────────────────────────────────────────────────

test_uninstall_removes_the_app_its_leftovers_and_its_permissions() {
    make_foo_scene
    export UNINSTALL_ASSUME_YES=1
    local L="$HOME/Library"

    uninstall_app "$HOME/Applications/Foo Editor.app" "$TEST_TMP/meta.tsv"

    assert "the app bundle is gone"        test ! -e "$HOME/Applications/Foo Editor.app"
    assert "its app data is gone"          test ! -e "$L/Application Support/Foo"
    assert "its cache is gone"             test ! -e "$L/Caches/com.acme.FooEditor"
    assert "its preferences are gone"      test ! -e "$L/Preferences/com.acme.FooEditor.plist"
    assert "its helper's preferences too"  test ! -e "$L/Preferences/com.acme.FooEditor.helper.plist"
    assert "its saved state is gone"       test ! -e "$L/Saved Application State/com.acme.FooEditor.savedState"
    assert "its container is gone"         test ! -e "$L/Containers/com.acme.FooEditor"
    assert "its group container is gone"   test ! -e "$L/Group Containers/ABCDE12345.com.acme.FooEditor"
    assert "its logs are gone"             test ! -e "$L/Logs/Foo Editor"
    assert "its crash report is gone"      test ! -e "$L/Logs/DiagnosticReports/Foo-2026-11-01-101010.ips"
    assert "its launch agent is gone"      test ! -e "$L/LaunchAgents/com.acme.FooEditor.agent.plist"

    assert "privacy permissions were reset" grep -qx "tccutil reset All com.acme.FooEditor" "$TEST_TMP/calls.log"
    assert "its launch agent was unloaded"  grep -q "^launchctl bootout gui/.*com.acme.FooEditor.agent.plist" "$TEST_TMP/calls.log"
    assert "it was unregistered from Launch Services" grep -q "^lsregister -u .*Foo Editor.app" "$TEST_TMP/calls.log"
    assert "the run counted one uninstall" test "$TOTAL_CLEANED" -eq 1
    assert "freed space was counted"       test "$TOTAL_FREED_KB" -gt 0
}

test_uninstall_keeps_other_apps_data_and_personal_files() {
    make_foo_scene
    export UNINSTALL_ASSUME_YES=1
    local L="$HOME/Library"

    uninstall_app "$HOME/Applications/Foo Editor.app" "$TEST_TMP/meta.tsv"

    assert "the sibling app stays"                test -d "$HOME/Applications/Foo Editor Beta.app"
    assert "the sibling's cache stays"            test -f "$L/Caches/com.acme.FooEditor.beta/keep"
    assert "the sibling's preferences stay"       test -f "$L/Preferences/com.acme.FooEditor.beta.plist"
    assert "the sibling's app data stays"         test -f "$L/Application Support/FooBeta/keep"
    assert "an app whose name contains ours stays" test -f "$L/Application Support/Xfoo/keep"
    assert "a look-alike bundle ID stays"         test -f "$L/Preferences/com.acme.FooEditorX.plist"
    assert "a look-alike crash report stays"      test -f "$L/Logs/DiagnosticReports/Foobar-2026-11-01-101010.ips"
    assert "personal files stay"                  test -f "$HOME/Documents/notes.txt"
    assert "a review item (~/.foo) is kept unless chosen" test -f "$HOME/.foo/config"
    refute "no permission reset for the sibling"  grep -q "com.acme.FooEditor.beta" "$TEST_TMP/calls.log"
}

# Destructive actions must never run unattended without their *_ASSUME_YES.
test_uninstall_without_terminal_or_opt_in_removes_nothing() {
    make_foo_scene
    unset UNINSTALL_ASSUME_YES

    uninstall_app "$HOME/Applications/Foo Editor.app" "$TEST_TMP/meta.tsv"

    assert "the app is still there"      test -d "$HOME/Applications/Foo Editor.app"
    assert "its data is still there"     test -f "$HOME/Library/Application Support/Foo/data.db"
    assert "no system tool was called"   test ! -e "$TEST_TMP/calls.log"
}

test_uninstall_keeps_shared_data_when_a_second_copy_is_installed() {
    make_foo_scene
    make_app "Foo Editor" com.acme.FooEditor Foo "$HOME/Applications/Old"
    make_meta
    printf '%s\t%s\n' "$HOME/Applications/Old/Foo Editor.app" com.acme.FooEditor >> "$TEST_TMP/meta.tsv"
    export UNINSTALL_ASSUME_YES=1

    uninstall_app "$HOME/Applications/Old/Foo Editor.app" "$TEST_TMP/meta.tsv"

    assert "the chosen copy is removed"      test ! -e "$HOME/Applications/Old/Foo Editor.app"
    assert "the other copy stays"            test -d "$HOME/Applications/Foo Editor.app"
    assert "the data they share is kept"     test -f "$HOME/Library/Application Support/Foo/data.db"
    assert "their preferences are kept"      test -f "$HOME/Library/Preferences/com.acme.FooEditor.plist"
}

test_uninstall_reports_an_item_it_could_not_remove() {
    make_foo_scene
    export UNINSTALL_ASSUME_YES=1
    # A folder that cannot be deleted, however hard we try: it is not ours to
    # make writable. (Its parent is read-only and locked.)
    local stuck="$HOME/Library/Logs"
    chmod 0555 "$stuck"; chflags uchg "$stuck"

    local out; out=$(uninstall_app "$HOME/Applications/Foo Editor.app" "$TEST_TMP/meta.tsv")
    chflags nouchg "$stuck"; chmod 0755 "$stuck"

    assert "the stuck item is reported as not removed" grep -q "not removed .*Logs/Foo Editor" <<< "$out"
    assert "the summary counts the failure"            grep -q "could not be removed" <<< "$out"
    assert "the rest was still removed"                test ! -e "$HOME/Library/Caches/com.acme.FooEditor"
}

# ── packages ────────────────────────────────────────────────────────────────

test_package_removal_only_deletes_binaries_inside_the_bin_folders() {
    mkdir -p "$HOME/.local/bin" "$HOME/Documents"
    echo x > "$HOME/.local/bin/mytool"; echo x > "$HOME/Documents/mytool"

    assert "a binary in ~/.local/bin is removed" pkg_remove binary "$HOME/.local/bin/mytool"
    assert "it is gone" test ! -e "$HOME/.local/bin/mytool"

    refute "a file elsewhere is refused" pkg_remove binary "$HOME/Documents/mytool"
    assert "and left alone" test -f "$HOME/Documents/mytool"
    refute "a path that climbs out is refused" pkg_remove binary "$HOME/.local/bin/../../Documents/mytool"
    refute "an unknown package kind is refused" pkg_remove rpm something
}

test_package_removal_passes_the_name_as_one_argument() {
    make_stub brew
    pkg_remove brew-formula 'wget; rm -rf ~' > /dev/null
    assert "the whole name reaches brew as a single argument" \
        grep -qx 'brew uninstall --formula -- wget; rm -rf ~' "$TEST_TMP/calls.log"
}
