# Ghostty Feasibility Patches

These parent-owned patches target Ghostty `v1.3.1` at commit
`332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28`. The repository keeps
`vendor/ghostty` clean; apply patches only in a disposable checkout.

## `0001`: Semantic Range Reflow

This patch tests one prerequisite for block-native terminal UI: a semantic
command-output range can be tracked while Ghostty reflows its screen.

The repository keeps `vendor/ghostty` as a clean submodule. Verify that the
patch still applies with:

```fish
git -C vendor/ghostty apply --check \
	$PWD/patches/ghostty/0001-test-tracked-semantic-output-reflow.patch
```

The full probe commands are documented in `vendor/README.md`.

## Result and Boundary

The probe passes on Apple Silicon macOS with Zig 0.15.2 using Ghostty's `test`
build step. It exercises OSC 133 parsing and proves the internal range/reflow
mechanism is a viable foundation for blocks.

It does **not** prove the full `ghostty_surface_t` bridge, exit-status lifecycle,
eviction, PTY ownership, or AppKit overlay alignment.

## `0002`: External Surface I/O

This patch adds an explicit external-I/O mode to the full embedding surface. In
that mode Ghostty does not construct `termio.Exec`, open a PTY, or spawn a child.
The host feeds ordered process output through
`ghostty_surface_feed_output`; encoded terminal input and resize events return
through synchronous callbacks on Ghostty's termio thread. The patch also aligns
the existing `ghostty_surface_free_text` Zig export with its two-argument public
C declaration, which is required for safe readback on arm64.

Focused Zig tests cover callback validation, rejected process options, input
ordering and CRLF conversion, resize forwarding, exact C/Zig ABI layout, and the
absence of exec thread state. External surfaces reject implicit window, tab, and
split creation; inherited configurations require the host to bind a distinct
transport rather than aliasing a Session or falling back to `Exec`. Zig 0.15.2
cross-target compilation and C header checks pass. The patch also normalizes
Zig-produced Darwin archives with Apple `ranlib` before `libtool`; otherwise
`libtool` can omit unaligned members while still exiting successfully.
This checkpoint implementation rewrites inputs inside its isolated disposable
Zig cache. Do not share that cache across concurrent builds; production
integration should normalize private archive copies instead.

With Metal Toolchain 17F109, the native Apple Silicon XCFramework builds and
links. `app/macos/TeaserProbe` passes a synchronous Metal draw to a live
IOSurface-backed layer, full-screen readback, exact `probe\r` input forwarding,
resize consistency, direct-child snapshots, and ordered surface/app/config
teardown. It does not perform pixel capture or comparison.

The host callback must copy or enqueue bytes promptly and must not synchronously
re-enter the surface. Producers must stop and all feed calls must finish before
the surface is freed. The Zig backend tests are the authoritative proof that
external mode has no process or PTY state; the runtime child snapshot is only
corroborating evidence. Connecting this surface to `teaserd` remains separate work.
