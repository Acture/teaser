# Semantic Range Reflow Probe

This parent-owned patch tests one prerequisite for block-native terminal UI: a
semantic command-output range can be tracked while Ghostty reflows its screen.
It targets Ghostty `v1.3.1` at commit
`332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28`.

The repository keeps `vendor/ghostty` as a clean submodule. Verify that the
patch still applies with:

```fish
git -C vendor/ghostty apply --check \
	$PWD/patches/ghostty/0001-test-tracked-semantic-output-reflow.patch
```

The full probe commands are documented in `vendor/README.md`. They clone the
submodule into a disposable directory, apply the patch there, and run only the
targeted test with Homebrew's Zig 0.15 toolchain. The submodule itself must never
become dirty.

## Result and Boundary

The probe passes on Apple Silicon macOS with Zig 0.15.2 using Ghostty's `test`
build step. It exercises OSC 133 parsing and proves the internal range/reflow
mechanism is a viable foundation for blocks.

It does **not** yet prove the full `ghostty_surface_t` bridge, exit-status
lifecycle, eviction, PTY ownership, or AppKit overlay alignment. The next slice
should expose the smallest query-only full-surface bridge for creating, reading,
and freeing this tracked range. Do not add a broad callback API until that query
seam passes a real embedded-surface test.
