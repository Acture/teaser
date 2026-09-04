# Teaser

Teaser is a macOS-first spatial development environment. It keeps complete project
Workspaces available as composable regions on one screen instead of hiding each
project behind a mutually exclusive tab.

> Status: native layout prototype. `Teaser.app` runs a fixture-backed Workspace
> and Panel UI plus a Zed companion managed through public Accessibility APIs.
> The Rust control plane, detachable PTY data plane, and owning-process-group
> teardown are testable; production Ghostty and Session wiring remain incomplete.

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

## Architecture at a glance

- **AppKit/SwiftUI host:** parallel, focused, and switched Workspace presentation;
  Panel layout; focus; IME; clipboard; previews; and native input.
- **`teaserd` runtime:** owns Teaser sessions, processes, PTYs, block state, and
  lifetime independently of any GUI; each session has zero or one attached
  surface.
- **Ghostty terminal surface:** uses pinned `libghostty` APIs for Metal rendering,
  terminal input, selection, and terminal compatibility.
- **Rust core:** typed project, checkout, Workspace, Panel, session, attachment,
  block, and control-plane state.
- **External environments:** cmux and IDEs remain provider-owned federated
  environments or companion windows instead of entering Teaser's session registry.

Terminal parsing, rendering, and native input stay inside AppKit and `libghostty`.
Canonical PTY bytes use the bounded local attachment stream; UniFFI remains
reserved for low-frequency state and semantic events.

See [Architecture](docs/architecture.md), [Roadmap](ROADMAP.md), and the
[implementation plan](plan/architecture-teaser-platform-1.md).

## Development

Run the full quality gate from the repository root:

```fish
fish scripts/check.fish
```

It builds `Teaser.app` and checks Swift integration tests, formatting, Clippy
warnings, all Rust workspace tests, and whitespace errors.

Build the current macOS app prototype with:

```fish
fish scripts/app.fish --build-only
```

This produces `target/macos/Teaser.app`. Launching the app requires a stable
Apple Development or Developer ID signing identity so macOS can retain Teaser's
Accessibility approval across rebuilds:

```fish
set -lx TEASER_CODESIGN_IDENTITY 'Apple Development: Your Name (TEAMID)'
fish scripts/app.fish
```

The first Zed connection can choose a project directory in the app. Pass
`--zed-repo PATH` to preselect it.

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
- no arbitrary GUI embedding, screen-capture proxy, or private macOS API;
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
