# Semantic Range Reflow Probe

This is TACO's first executable development slice. It tests one prerequisite for
block-native terminal UI: a semantic command-output range can be tracked while
Ghostty reflows its screen.

The patch targets Ghostty `v1.3.1` at commit
`332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28`. The test creates prompt, input,
output, and following-prompt cells; selects the output; tracks both range
endpoints; resizes from 80 to 7 columns and back; and asserts that the same
display text is returned after each resize.

Run it against a clean or dirty local Ghostty checkout without modifying that
checkout:

```fish
fish scripts/run-block-range-probe.fish /path/to/ghostty
```

The runner clones the pinned revision into a temporary directory, applies
`0001-test-tracked-semantic-output-reflow.patch`, and runs only the probe test.
It expects Homebrew's patched Zig 0.15 toolchain at
`/opt/homebrew/opt/zig@0.15/bin/zig`; pass a second argument to override it.

## Result and Boundary

The probe passes on Linux ARM64 with Zig 0.15.2 using Ghostty's
`test-lib-vt` build step. It proves the internal range/reflow mechanism is a
viable foundation for blocks.

It does **not** yet prove the full `ghostty_surface_t` bridge, OSC 133 parsing in
the same test, exit-status lifecycle, eviction, PTY ownership, or AppKit overlay
alignment. The next slice should expose the smallest query-only full-surface
bridge for creating, reading, and freeing this tracked range. Do not add a broad
callback API until that query seam passes a real embedded-surface test.
