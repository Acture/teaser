#!/opt/homebrew/bin/fish

set script_dir (path resolve (dirname (status filename)))
set repo_root (path resolve $script_dir/..)
set app_bundle $repo_root/target/macos/Teaser.app
set app_contents $app_bundle/Contents
set app_binary $app_contents/MacOS/Teaser
set build_only false
set codesign_identity -

if set -q TEASER_CODESIGN_IDENTITY; and test -n "$TEASER_CODESIGN_IDENTITY"
    set codesign_identity $TEASER_CODESIGN_IDENTITY
end

for argument in $argv
    switch $argument
        case --build-only
            if $build_only
                printf 'error: --build-only was provided more than once\n' >&2
                exit 2
            end
            set build_only true
        case '*'
            printf 'usage: fish scripts/app.fish [--build-only]\n' >&2
            exit 2
    end
end

# Teaser is never signed ad-hoc, not even for --build-only: macOS binds
# Accessibility approval to the signature, so an ad-hoc rebuild silently revokes
# the approval of the bundle in use.
if test "$codesign_identity" = -
    printf '%s\n' \
        'error: building Teaser requires a stable code-signing identity.' \
        'Set TEASER_CODESIGN_IDENTITY to an Apple Development or Developer ID identity,' \
        'once for every shell: set -Ux TEASER_CODESIGN_IDENTITY "Apple Development: …"' >&2
    exit 2
end

cd $repo_root
or exit 1

# Same shared module and dependencies as tests; Xcode's SwiftPM backend emits
# macOS-aware resource lookup (Contents/Resources), unlike the CLI-only backend.
swift build --build-system xcode --product Teaser --force-resolved-versions
or exit 1
set swift_bin_dir (swift build --build-system xcode --show-bin-path)
or exit 1

# Assemble from scratch so the signature seals only what this build produced.
rm -rf $app_bundle
mkdir -p $app_contents/MacOS $app_contents/Resources/ThirdPartyNotices
or exit 1
cp $swift_bin_dir/Teaser $app_binary
or exit 1
cp app/macos/Teaser/Info.plist $app_contents/Info.plist
or exit 1
plutil -lint $app_contents/Info.plist
or exit 1

# Keep the .app relocatable and its resource seal valid.
cp -R $swift_bin_dir/KeyboardShortcuts_KeyboardShortcuts.bundle $app_contents/Resources/
or exit 1
cp -f .build/checkouts/KeyboardShortcuts/license $app_contents/Resources/ThirdPartyNotices/KeyboardShortcuts.txt
or exit 1
cp -f .build/checkouts/SplitView/LICENSE $app_contents/Resources/ThirdPartyNotices/SplitView.txt
or exit 1
cp LICENSE NOTICE TRADEMARKS.md THIRD_PARTY_NOTICES.md $app_contents/Resources/
or exit 1

codesign --force --sign "$codesign_identity" --timestamp=none $app_bundle
or exit 1
codesign --verify --strict $app_bundle
or exit 1
$app_binary --check-bundle-resources
or exit 1
printf 'Built %s\n' $app_bundle

if $build_only
    exit 0
end

printf 'Launching Teaser\n'
$app_binary
