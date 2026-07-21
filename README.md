# TACO

**Terminal Application Composition & Orchestration**

TACO is a macOS-first, terminal-centric workspace. Shells, agents, image previews,
and editors are peers inside one orchestration model; the editor is not the root
abstraction and agent CLIs do not each need to reinvent terminal UI.

> Status: foundation prototype. The Rust session registry is testable, but there
> is no runnable application yet.

## Product thesis

A terminal should own three things that are currently split across terminal
emulators, multiplexers, agent harnesses, and IDEs:

1. native terminal rendering and input;
2. workspace layout, session lifetime, and remote transport;
3. semantic objects such as shell commands, agent turns, tool calls, and files.

TACO keeps ordinary CLI and TUI programs working as ordinary terminal programs.
Applications gain richer behavior progressively through shell integration,
standard protocols, or built-in adapters; unsupported applications never need a
TACO-specific rewrite.

## Architecture at a glance

- **AppKit/SwiftUI host:** native windows, panes, focus, IME, clipboard, image
  previews, and input surfaces.
- **`tacod` runtime:** owns TACO sessions, processes, PTYs, block state, and
  lifetime independently of any GUI; each session has zero or one attached
  surface.
- **Ghostty terminal surface:** uses pinned `libghostty` APIs for Metal rendering,
  terminal input, selection, and terminal compatibility.
- **Rust core:** typed project, checkout, workspace, session, attachment, block,
  and control-plane state.
- **External environments:** cmux and IDEs remain provider-owned federated panels
  or companion windows instead of entering TACO's session registry.

The terminal render/input hot path stays entirely inside AppKit and `libghostty`.
Rust/Swift bridging is reserved for low-frequency state and semantic events.

See [Architecture](docs/architecture.md), [Roadmap](ROADMAP.md), and the
[implementation plan](plan/architecture-taco-platform-1.md).

## Development

Run the current Rust quality gate from the repository root:

```fish
fish scripts/check.fish
```

It checks formatting, Clippy warnings, all workspace tests, and whitespace errors.

To run the current foreground daemon prototype:

```fish
cargo run -p tacod
```

It uses `~/Library/Application Support/TACO/runtime` by default. Pass
`--runtime-dir PATH` only for development or tests.

The daemon currently supports only the versioned `session.create` control request.
See [Local control protocol](docs/ipc.md) for its wire format and current limits.

## Agent integration has two modes

- **Native CLI mode:** run `claude`, `codex`, or any other harness inside a normal
  TerminalSurface. This retains vendor behavior but provides only terminal-level
  semantics.
- **Structured ACP mode:** run `taco agent claude` or `taco agent codex`. TACO
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

TACO is licensed under [AGPL-3.0-or-later](LICENSE). The source license preserves
source-sharing and legal-notice obligations; it does not require derivative
products to keep the TACO product name. The separate
[trademark policy](TRADEMARKS.md) reserves the TACO name and logo against confusing
redistribution while allowing truthful nominative use. See [NOTICE](NOTICE) for the
project notice.
