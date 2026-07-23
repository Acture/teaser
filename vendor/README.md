# Vendored Dependencies

## Ghostty

- Upstream: <https://github.com/ghostty-org/ghostty>
- Tag: `v1.3.1`
- Commit: `332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28`
- License: MIT; see `ghostty/LICENSE` and `../THIRD_PARTY_NOTICES.md`

`vendor/ghostty` is a Git submodule pinned to the commit above. Initialize it
after cloning TACO:

```fish
git submodule update --init -- vendor/ghostty
```

The submodule must remain clean. TACO-owned experiments and patches live in
`patches/ghostty`; application code belongs outside the submodule.

### Verify the semantic-range test

The parent-owned patch adds one terminal-level test proving that raw OSC 133
command output remains readable while the screen reflows from 80 to 7 columns
and back. Run it in a disposable checkout so the submodule remains unchanged:

```fish
set probe_dir (mktemp -d /tmp/taco-ghostty-probe.XXXXXX)
git clone --quiet --no-hardlinks vendor/ghostty $probe_dir/ghostty
git -C $probe_dir/ghostty checkout --quiet --detach \
	332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28
git -C $probe_dir/ghostty apply \
	$PWD/patches/ghostty/0001-test-tracked-semantic-output-reflow.patch
cd $probe_dir/ghostty
/opt/homebrew/opt/zig@0.15/bin/zig build test \
	-Dapp-runtime=none \
	'-Dtest-filter=tracked semantic output survives reflow through OSC 133'
```

The first build may download Ghostty dependencies. Zig build outputs and caches
stay in the disposable checkout. Do not use `test-lib-vt` at this pin: it also
compiles Ghostty's C ABI target, which fails on the upstream
`semantic_prompt.Command` union before reaching the filtered Terminal test.

### Verify the external-surface I/O gate

The second patch adds host-driven I/O to the full surface without constructing
Ghostty's exec backend. Apply it in a fresh disposable checkout:

```fish
set taco_root $PWD
set probe_dir (mktemp -d /tmp/taco-ghostty-external.XXXXXX)
git clone --quiet --no-hardlinks vendor/ghostty $probe_dir/ghostty
git -C $probe_dir/ghostty checkout --quiet --detach \
	332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28
git -C $probe_dir/ghostty apply \
	$PWD/patches/ghostty/0002-external-surface-io.patch
cd $probe_dir/ghostty
```

Install Xcode's optional Metal toolchain once. Metal Toolchain 17F109 uses the
identifier below; use the identifier reported by
`xcodebuild -showComponent MetalToolchain -json` if it differs.

```fish
xcodebuild -downloadComponent MetalToolchain
set -lx TOOLCHAINS com.apple.dt.toolchain.Metal.32023.883
xcrun -sdk macosx metal --version

set -lx ZIG_GLOBAL_CACHE_DIR $probe_dir/zig-global-cache
set -lx ZIG_LOCAL_CACHE_DIR $probe_dir/zig-local-cache
/opt/homebrew/opt/zig@0.15/bin/zig build test \
	-Dapp-runtime=none \
	'-Dtest-filter=external'
/opt/homebrew/opt/zig@0.15/bin/zig build \
	-Dapp-runtime=none \
	-Dxcframework-target=native \
	-Demit-xcframework=true \
	-Demit-macos-app=false \
	-Demit-themes=false \
	-Di18n=false
```

The patch runs Apple `ranlib` before `libtool`; this is required because an
otherwise successful build can omit unaligned Zig archive members and produce
an unlinkable framework. Confirm the final archive contains the C API, compile
the AppKit probe, and run it:

```fish
set xc $probe_dir/ghostty/macos/GhosttyKit.xcframework/macos-arm64
nm -g $xc/libghostty-fat.a | rg '_ghostty_(app_new|surface_new)'

cd $taco_root
mkdir -p .build
set -lx CLANG_MODULE_CACHE_PATH $probe_dir/clang-module-cache
set -lx SWIFT_MODULECACHE_PATH $probe_dir/swift-module-cache
xcrun swiftc -swift-version 6 -strict-concurrency=complete \
	app/macos/TACOProbe/main.swift \
	-I $xc/Headers \
	$xc/libghostty-fat.a \
	-framework AppKit \
	-framework Carbon \
	-framework CoreFoundation \
	-framework CoreGraphics \
	-framework CoreText \
	-framework CoreVideo \
	-framework IOSurface \
	-framework Metal \
	-framework MetalKit \
	-framework QuartzCore \
	-lc++ \
	-lproc \
	-o .build/TACOProbe

set -lx GHOSTTY_RESOURCES_DIR $probe_dir/ghostty/zig-out/share/ghostty
.build/TACOProbe
```

A pass covers a synchronous Metal draw to a live IOSurface-backed layer,
readback, exact input ordering, resize consistency, direct-child snapshots, and
ordered teardown. It does not compare captured pixels. The Metal download and
GUI probe are intentionally not part of `scripts/check.fish`.

### Update the pin

Fetch an explicitly verified upstream tag, check out its exact commit in the
submodule, and stage the resulting gitlink. Then rebase parent-owned patches,
update this file and `THIRD_PARTY_NOTICES.md`, review the old-to-new upstream
diff, and rerun the semantic test plus `fish scripts/check.fish`. Never use
`git submodule update --remote` as an implicit upgrade.
