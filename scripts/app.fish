#!/opt/homebrew/bin/fish

set script_dir (path resolve (dirname (status filename)))
set repo_root (path resolve $script_dir/..)
set source_dir $repo_root/app/macos/Teaser
set external_window_source_dir $repo_root/app/macos/Teaser/ExternalWindows
set build_dir $repo_root/target/macos
set app_bundle $build_dir/Teaser.app
set app_contents $app_bundle/Contents
set app_macos $app_contents/MacOS
set app_binary $app_macos/Teaser
set source_info_plist $source_dir/Info.plist
set bundle_info_plist $app_contents/Info.plist
set swift_module_cache $build_dir/swift-module-cache
set clang_module_cache $build_dir/clang-module-cache
set build_only false
set zed_repo
set codesign_identity -

if set -q TEASER_CODESIGN_IDENTITY
    if test -n "$TEASER_CODESIGN_IDENTITY"
        set codesign_identity $TEASER_CODESIGN_IDENTITY
    end
end

set argument_index 1
while test $argument_index -le (count $argv)
    set argument $argv[$argument_index]
    switch $argument
        case --build-only
            if $build_only
                printf 'error: --build-only was provided more than once\n' >&2
                exit 2
            end
            set build_only true
        case --zed-repo
            if test -n "$zed_repo"
                printf 'error: --zed-repo was provided more than once\n' >&2
                exit 2
            end
            set argument_index (math $argument_index + 1)
            if test $argument_index -gt (count $argv)
                printf 'usage: fish scripts/app.fish [--build-only] [--zed-repo PATH]\n' >&2
                exit 2
            end
            set repository_argument $argv[$argument_index]
            if not test -d "$repository_argument"
                printf 'error: Zed repository is not a directory: %s\n' "$repository_argument" >&2
                exit 2
            end
            set zed_repo (path resolve "$repository_argument")
        case '*'
            printf 'usage: fish scripts/app.fish [--build-only] [--zed-repo PATH]\n' >&2
            exit 2
    end
    set argument_index (math $argument_index + 1)
end

if not $build_only; and test "$codesign_identity" = -
    printf '%s\n' \
        'error: launching Teaser requires a stable code-signing identity.' \
        'Set TEASER_CODESIGN_IDENTITY to an Apple Development or Developer ID identity.' \
        'Ad-hoc signatures change across builds and cannot retain Accessibility approval.' >&2
    exit 2
end

cd $repo_root
or exit 1

if not test -d $source_dir
    printf 'error: Teaser sources are missing: %s\n' $source_dir >&2
    exit 1
end
if not test -d $external_window_source_dir
    printf 'error: external-window sources are missing: %s\n' \
        $external_window_source_dir >&2
    exit 1
end
if not test -f $source_info_plist
    printf 'error: Teaser Info.plist is missing: %s\n' $source_info_plist >&2
    exit 1
end

set swift_sources (find $source_dir -maxdepth 1 -type f -name '*.swift' | sort)
if test (count $swift_sources) -eq 0
    printf 'error: no Swift sources found in %s\n' $source_dir >&2
    exit 1
end
set external_window_sources \
    (find $external_window_source_dir -maxdepth 1 -type f -name '*.swift' | sort)
if test (count $external_window_sources) -eq 0
    printf 'error: no Swift sources found in %s\n' $external_window_source_dir >&2
    exit 1
end

mkdir -p $app_macos $swift_module_cache $clang_module_cache
or exit 1
cp $source_info_plist $bundle_info_plist
or exit 1
plutil -lint $bundle_info_plist
or exit 1

set -lx SWIFT_MODULECACHE_PATH $swift_module_cache
set -lx CLANG_MODULE_CACHE_PATH $clang_module_cache

printf 'Building Teaser\n'
xcrun swiftc \
    -swift-version 6 \
    -strict-concurrency=complete \
    -warnings-as-errors \
    -module-cache-path $swift_module_cache \
    -framework AppKit \
    -framework SwiftUI \
    -framework Combine \
    -framework ApplicationServices \
    -framework CoreGraphics \
    $swift_sources \
    $external_window_sources \
    -o $app_binary
or exit 1

if test -d $app_contents/_CodeSignature
    codesign --remove-signature $app_bundle
    or exit 1
end
codesign --force --sign "$codesign_identity" --timestamp=none $app_bundle
or exit 1
codesign --verify --strict $app_bundle
or exit 1

printf 'Built %s\n' $app_bundle

if $build_only
    exit 0
end

printf 'Launching Teaser\n'
if test -n "$zed_repo"
    env TEASER_ZED_REPO="$zed_repo" $app_binary
else
    $app_binary
end
