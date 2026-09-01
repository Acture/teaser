#!/opt/homebrew/bin/fish

set script_dir (path resolve (dirname (status filename)))
set repo_root (path resolve $script_dir/..)
set expected_ghostty_commit 332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28
set expected_ghostty_url https://github.com/ghostty-org/ghostty.git
set expected_zig_version 0.15.2
set zig_bin /opt/homebrew/opt/zig@0.15/bin/zig
set ghostty_dir $repo_root/vendor/ghostty
set vendor_readme $repo_root/vendor/README.md
set swift_test_dir $repo_root/target/swift-tests
set swift_test_binary $swift_test_dir/TeaserProbeTests
set swift_module_cache $swift_test_dir/swift-module-cache
set clang_module_cache $swift_test_dir/clang-module-cache
set ghostty_patches \
    $repo_root/patches/ghostty/0001-test-tracked-semantic-output-reflow.patch \
    $repo_root/patches/ghostty/0002-external-surface-io.patch

cd $repo_root
or exit 1

fish -n scripts/*.fish
or exit 1
fish_indent --check scripts/*.fish
or exit 1
if not test -f .gitmodules
    printf 'error: .gitmodules is missing\n' >&2
    exit 1
end
set submodule_path \
    (git config --file .gitmodules --get submodule.vendor/ghostty.path)
or begin
    printf 'error: vendor/ghostty submodule path is not configured\n' >&2
    exit 1
end
if test "$submodule_path" != vendor/ghostty
    printf 'error: unexpected Ghostty submodule path: %s\n' "$submodule_path" >&2
    exit 1
end
set submodule_url \
    (git config --file .gitmodules --get submodule.vendor/ghostty.url)
or begin
    printf 'error: vendor/ghostty submodule URL is not configured\n' >&2
    exit 1
end
if test "$submodule_url" != $expected_ghostty_url
    printf 'error: unexpected Ghostty submodule URL: %s\n' "$submodule_url" >&2
    exit 1
end
if git config --file .gitmodules --get submodule.vendor/ghostty.branch >/dev/null
    printf 'error: Ghostty must be pinned by gitlink, not a moving branch\n' >&2
    exit 1
end
set gitlink_entry (git ls-files --stage -- vendor/ghostty)
set gitlink_fields (string split ' ' -- $gitlink_entry)
if test (count $gitlink_fields) -lt 2 -o "$gitlink_fields[1]" != 160000
    printf 'error: vendor/ghostty is not tracked as a Git submodule\n' >&2
    exit 1
end
set indexed_commit (git rev-parse --verify :vendor/ghostty 2>/dev/null)
or begin
    printf 'error: cannot resolve the vendor/ghostty gitlink\n' >&2
    exit 1
end
if test "$indexed_commit" != $expected_ghostty_commit
    printf 'error: expected Ghostty gitlink %s, got %s\n' \
        $expected_ghostty_commit "$indexed_commit" >&2
    exit 1
end
if not test -e $ghostty_dir/.git
    printf 'error: initialize Ghostty with git submodule update --init -- vendor/ghostty\n' >&2
    exit 1
end
set checkout_commit (git -C $ghostty_dir rev-parse HEAD 2>/dev/null)
or begin
    printf 'error: cannot read the initialized Ghostty checkout\n' >&2
    exit 1
end
if test "$checkout_commit" != $expected_ghostty_commit
    printf 'error: expected Ghostty checkout %s, got %s\n' \
        $expected_ghostty_commit "$checkout_commit" >&2
    exit 1
end
set submodule_changes \
    (git -C $ghostty_dir status --porcelain --untracked-files=all)
if test (count $submodule_changes) -ne 0
    printf 'error: vendor/ghostty must remain clean\n' >&2
    printf '%s\n' $submodule_changes >&2
    exit 1
end
if not rg -Fq -- $expected_ghostty_commit $vendor_readme
    printf 'error: vendor/README.md does not record the pinned Ghostty commit\n' >&2
    exit 1
end
for ghostty_patch in $ghostty_patches
    git -C $ghostty_dir apply --check $ghostty_patch
    or begin
        printf 'error: Ghostty patch no longer applies cleanly: %s\n' \
            (path basename $ghostty_patch) >&2
        exit 1
    end
end
set zig_version unavailable
if test -x $zig_bin
    set zig_version ($zig_bin version 2>/dev/null)
end
if test "$zig_version" != $expected_zig_version
    printf 'error: expected Zig %s at %s, got %s\n' \
        $expected_zig_version $zig_bin "$zig_version" >&2
    exit 1
end

mkdir -p $swift_test_dir $swift_module_cache $clang_module_cache
or exit 1
set -lx SWIFT_MODULECACHE_PATH $swift_module_cache
set -lx CLANG_MODULE_CACHE_PATH $clang_module_cache
xcrun swiftc \
    -swift-version 6 \
    -strict-concurrency=complete \
    -warnings-as-errors \
    app/macos/Teaser/Terminal/AttachmentClient.swift \
    app/macos/Teaser/Terminal/TerminalAttachmentPump.swift \
    app/macos/TeaserProbeTests/main.swift \
    -o $swift_test_binary
or exit 1
$swift_test_binary
or exit 1

cargo fmt --check
or exit 1
cargo clippy --workspace --all-targets --all-features -- -D warnings
or exit 1
cargo test --workspace --all-targets
or exit 1
git diff --check HEAD -- .
