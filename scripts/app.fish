#!/opt/homebrew/bin/fish

set script_dir (path resolve (dirname (status filename)))
set repo_root (path resolve $script_dir/..)
set source_dir $repo_root/app/macos/Teaser
set model_source_dir $source_dir/Model
set layout_source_dir $source_dir/Layout
set desktop_stage_source_dir $source_dir/DesktopStage
set notes_source_dir $source_dir/Notes
set persistence_source_dir $source_dir/Persistence
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
        case '*'
            printf 'usage: fish scripts/app.fish [--build-only]\n' >&2
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
if not test -d $model_source_dir
    printf 'error: Teaser model sources are missing: %s\n' $model_source_dir >&2
    exit 1
end
if not test -d $layout_source_dir
    printf 'error: Teaser layout sources are missing: %s\n' $layout_source_dir >&2
    exit 1
end
for required_source_dir in \
    $desktop_stage_source_dir \
    $notes_source_dir \
    $persistence_source_dir
    if not test -d $required_source_dir
        printf 'error: Teaser source directory is missing: %s\n' \
            $required_source_dir >&2
        exit 1
    end
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
set model_sources (find $model_source_dir -maxdepth 1 -type f -name '*.swift' | sort)
set layout_sources (find $layout_source_dir -maxdepth 1 -type f -name '*.swift' | sort)
set desktop_stage_sources \
    (find $desktop_stage_source_dir -maxdepth 1 -type f -name '*.swift' | sort)
set notes_sources (find $notes_source_dir -maxdepth 1 -type f -name '*.swift' | sort)
set persistence_sources \
    (find $persistence_source_dir -maxdepth 1 -type f -name '*.swift' | sort)
if test (count $model_sources) -eq 0
    printf 'error: no Swift sources found in %s\n' $model_source_dir >&2
    exit 1
end
if test (count $layout_sources) -eq 0
    printf 'error: no Swift sources found in %s\n' $layout_source_dir >&2
    exit 1
end
if test (count $desktop_stage_sources) -eq 0
    printf 'error: no Swift sources found in %s\n' $desktop_stage_source_dir >&2
    exit 1
end
if test (count $notes_sources) -eq 0
    printf 'error: no Swift sources found in %s\n' $notes_source_dir >&2
    exit 1
end
if test (count $persistence_sources) -eq 0
    printf 'error: no Swift sources found in %s\n' $persistence_source_dir >&2
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
    $model_sources \
    $layout_sources \
    $desktop_stage_sources \
    $notes_sources \
    $persistence_sources \
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
$app_binary
