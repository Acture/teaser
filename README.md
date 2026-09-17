# Teaser

Teaser is a macOS-first spatial development environment. It keeps complete project
Workspaces available as composable regions across visible displays instead of
hiding each project behind a mutually exclusive tab.

> Status: desktop-stage implementation in progress. The native app and Rust
> foundation include constrained layout, generic window-control code, local
> presentation persistence, and a six-Workspace preset. Automated checks cover
> geometry and desktop safety; signed real-window drag acceptance is still pending.
> Production Ghostty and Session wiring also remain incomplete.

## Product thesis

Many products marketed as agentic development environments place complete projects
in separate tabs. That display model serializes project visibility even when work
continues in parallel: showing one project hides the agent execution, terminals,
diffs, and project details of the others.

Teaser treats a Workspace as a persistent, project-scoped display unit. Multiple
Workspaces can be tiled in parallel, one Workspace can temporarily take the full
display, or complete Workspaces can be switched as units. Each keeps its own Panel
layout, running content, and spatial relationships across those presentation
changes.

A Panel is a content-neutral display region. Agent execution, project details,
terminals, diffs, images, and input are content placed in Panels rather than separate
application modes. Terminal content still behaves like an ordinary terminal: CLI
and TUI applications require no Teaser-specific rewrite, while shell integration and
built-in adapters add richer semantics progressively.

A Panel may instead bind to a standard window owned by another macOS application.
Dragging that window into a Panel adopts its position and size into the Workspace
layout. The provider still owns rendering, input, and window lifetime: Teaser does
not reparent the window, capture its pixels, or pretend it is an embedded view.

## Architecture at a glance

- **AppKit/SwiftUI desktop stage:** connected rectangular Workspace and Panel
  layout, Teaser-owned windows, click-through arrangement overlays, virtual focus,
  and Accessibility control of adopted external windows, each identified by its
  own window-server window ID.
- **`teaserd` runtime:** owns Teaser sessions, processes, PTYs, block state, and
  lifetime independently of any GUI; each session has zero or one attached
  surface.
- **Ghostty terminal surface:** uses pinned `libghostty` APIs for Metal rendering,
  terminal input, selection, and terminal compatibility.
- **Rust core:** typed project, checkout, Workspace, Panel, session, attachment,
  block, and control-plane state.
- **External applications:** IDEs, terminals, task tools, browsers, and previewers
  remain provider-owned top-level windows even when bound to Panels. Structured
  federated environments remain outside Teaser's Session registry.

Terminal parsing, rendering, and native input stay inside AppKit and `libghostty`.
Canonical PTY bytes use the bounded local attachment stream; UniFFI remains
reserved for low-frequency state and semantic events.

See [Architecture](docs/architecture.md), [Roadmap](ROADMAP.md), and the
[implementation plan](plan/architecture-teaser-platform-1.md).

## Development

Use Swift 6.2 or newer, Rust, and pre-commit. Install the Git hooks once:

```text
pre-commit install
```

Run the full quality gate from the repository root:

```text
pre-commit run --all-files --hook-stage pre-push
```

The hooks build `Teaser.app` and check Swift integration tests, formatting,
Clippy warnings, all Rust workspace tests, whitespace, and Ghostty patch
applicability. Formatting and static analysis also run on commit. Initialize
`vendor/ghostty` as described in [Vendored Dependencies](vendor/README.md) before
running the full gate; it does not require building Ghostty or installing Zig.

`Package.swift` defines the shared `TeaserKit` module, the `Teaser` executable,
and eight Swift test executables. Build them with `swift build`, or run one suite:

```text
swift run TeaserWindowAdoptionTests
```

These are executable harnesses, so use `swift run`, not `swift test`. The adoption
suite runs without desktop interaction, global monitors, or permission prompts.
Only the Ghostty-backed adapter is excluded until its native library is built.
The app script uses SwiftPM's Xcode build system for macOS resource lookup, so it
needs an installed, licensed Xcode.app rather than only a Swift toolchain. It
assembles the bundle from scratch, signs it, and checks library resources
without opening any window.
The [native Ghostty probe](vendor/README.md) remains a separate build.

Build the current macOS app prototype with:

```fish
fish scripts/app.fish --build-only
```

This produces `target/macos/Teaser.app`. Moving adopted external windows requires a
stable Apple Development or Developer ID signing identity so macOS can retain the
one-time Accessibility approval across rebuilds:

```fish
set -lx TEASER_CODESIGN_IDENTITY 'Apple Development: Your Name (TEAMID)'
fish scripts/app.fish
```

Launch opens a normal control window. Allow Accessibility, then click **Start
Layout**; launching alone never covers the desktop. Physically dragging a standard
window into a visible Panel is the explicit adoption action. Teaser does not request per-application or per-project
authorization, and it does not guess a replacement window after either application
restarts.

Use the Teaser menu's **Stop Layout**, or `Ctrl+Option+Esc`, to remove the stage.
Switching macOS Space also stops it. The Dock icon reopens the control window;
closing that window or using `Cmd+Q` quits Teaser. Closed Notes stay closed until
explicitly focused or a new stage session begins. Arrange uses only small labels
and divider handles for input, never a display-sized mouse shield.

`Ctrl+Option+Space` toggles Arrange on and off. `Ctrl+Option+D` splits,
`Ctrl+Option+F` focuses a Workspace, and `Ctrl+Option+Return` hands input to the
selected Panel. Layout Undo is `Ctrl+Option+Z` in Arrange or the menu action;
`Cmd+Z` remains exclusively with the app receiving keyboard input.
KeyboardShortcuts registers these Control-Option chords only while the stage is
running, and layout Undo only in Arrange. A registered chord is consumed
system-wide, so no unmodified key such as `Esc` is bound. Conflicts with other
apps' hot keys still need real-desktop verification; Stop and Quit remain
available from the status menu and the control window.

**Layout Editor…** in the control window opens a normal, closable SplitView
layout map. Select a display or Workspace and drag its dividers. Releasing the
divider commits to the same constrained layout, provider placement, Undo, and
persistence used by desktop handles. While stopped, it edits saved proportions
without starting the stage. The map labels are not replicas of provider apps.

For read-only window-selection diagnostics, run the signed bundle's executable
with `--inspect-windows PID`. It reports current-Space window IDs, AX permission,
and selection failures without showing the stage, prompting, or moving windows:

```fish
target/macos/Teaser.app/Contents/MacOS/Teaser --inspect-windows PID
```

`--check-bundle-resources` instead checks the upstream shortcut localization
accessor without creating `NSApplication`, registering hotkeys, or observing
windows, and exits 1 when the bundled strings table is missing.

Replace `PID` with the selected provider process. No selectable window returns
exit status 1; invalid arguments return 2. This is not a drag/placement test.
`--observe-window-drag PID WINDOW_ID` passively watches one specified window for
20 seconds without showing or adopting anything. It prints `BEGAN` and `ENDED`
and returns 0 only after a complete qualified drag; timeout returns 1. A human or
an authorized UI test driver must actually drag that window during observation.
Runtime drag milestones use the `com.acture.teaser` log subsystem and
`window-adoption` category; window titles and provider document contents are not
included.

To run the current foreground daemon prototype:

```fish
cargo run -p teaserd
```

It uses `~/Library/Application Support/Teaser/runtime` by default. Pass
`--runtime-dir PATH` only for development or tests.

The daemon supports metadata-only `session.create` plus an internal
`session.attach` upgrade for already-resolved PTY Sessions. The public protocol
does not accept arbitrary commands or working directories before the Checkout
catalog exists. See [Local control and attachment protocol](docs/ipc.md) for the
wire format and current limits.

## Agent integration has two modes

- **Native CLI mode:** run `claude`, `codex`, or any other harness inside a normal
  TerminalSurface. This retains vendor behavior but provides only terminal-level
  semantics.
- **Structured ACP mode:** run `teaser agent claude` or `teaser agent codex`. Teaser
  owns input and presentation, but only capabilities exposed by the ACP adapter are
  available; this is not promised to equal every vendor CLI feature.

## Deliberate non-goals for v1

- no Warp, Zed, Claude Code, or Codex fork;
- no browser-based host or custom terminal renderer;
- no GUI reparenting, pixel-capture proxy, or synthetic application input;
- no private macOS API beyond one declaration that returns a window's own window
  ID, which no public API exposes;
- no third-party plugin SDK or compatibility promise;
- no custom agent protocol when ACP already covers the semantic control plane;
- no replacement for every CLI application's own interface.

## License and name

Teaser is licensed under [AGPL-3.0-or-later](LICENSE). The source license preserves
source-sharing and legal-notice obligations; it does not require derivative
products to keep the Teaser product name. The separate
[trademark policy](TRADEMARKS.md) reserves the Teaser name and logo against confusing
redistribution while allowing truthful nominative use. See [NOTICE](NOTICE) for the
project notice.
