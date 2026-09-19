# Teaser

Teaser is a macOS-first spatial development environment, built as a product fork
of [Herdr](https://github.com/herdrdev/herdr). Its main interface is tiling:
complete project contexts stay visible together instead of disappearing behind
mutually exclusive tabs. A real terminal UI and a native App are two clients of
the same intended organization and runtime, not two separate products.

> Current state: the Herdr v0.9.1 server/TUI source and full history are imported.
> The existing AppKit/SwiftUI canvas and window-adoption implementation are
> preserved, but the App is **not yet connected to the Herdr server**. Shared
> organization, task providers, multiple native-fullscreen canvases, and dependable
> live-window adoption remain implementation work. The import is not a completed
> end-to-end demo or a passing runtime build.

## Product model

- A **Workspace** is a persistent, project-scoped group of Panels. Membership is
  independent of placement: a Workspace can span canvases, and one canvas can
  show several Workspaces.
- A **Panel** is content-neutral. Task, CLI, App, Agent, File, and Notes are
  extensible kinds with minimum size, preferred aspect ratio, and growth rules,
  not application-specific subclasses.
- Panels tile at unequal sizes. Same-Workspace adjacency is a preference, not a
  rectangular-container constraint. A fluorescent outer contour expresses the
  group without adding a Workspace card or title bar.
- The native App targets multiple independently fullscreen windows using macOS's
  green-button fullscreen. First launch targets an empty canvas with incremental
  splits, not six prefilled project mockups.
- Task-driven work links external tasks to Panels and sessions. Linear/Notion
  remain task authorities; Teaser provides organization and its own Notes.
- The TUI retains a terminal-native workflow. GUI-only providers are explicit
  references or unavailable views, never simulated application windows.

External applications retain their own rendering and input. Adoption manages one
exact provider window's geometry and releases it safely; it does not reparent,
capture, or inject input. Real-window acceptance is not inferred from headless
geometry tests.

## Source layout

| Path | Role |
| --- | --- |
| `runtime/herdr` | Editable Herdr server/TUI fork, with upstream source and tests |
| `runtime/upstream.toml` | Exact imported baseline and provenance |
| `app/macos` and `Package.swift` | Native App, adapters, and headless harnesses |
| `prototypes/attachment-runtime` | Retired self-built PTY runtime, outside the active workspace |
| `vendor/ghostty` and `patches/ghostty` | Retained native attachment experiment |

The fork uses a history-preserving Git subtree, not an installed Herdr binary or
a read-only submodule. It keeps the `Acture/teaser` repository and macOS history.
This does not change GitHub's fork-network metadata.

See [Architecture](docs/architecture.md), [Terminology](CONTEXT.md),
[Protocol](docs/ipc.md), and the [implementation contract](plan/architecture-teaser-platform-1.md).
Execution status and dependencies live in [Linear](https://linear.app/acturea/project/teaser-efe303ae636d).

## Development

The runtime requires **Rust 1.96.1 and Zig 0.16.0**. Swift harnesses require
Swift 6.2 or newer; App packaging also needs Xcode and a stable Apple Development
or Developer ID signing identity.

Run production Cargo commands from the repository root:

```fish
cargo build --locked -p herdr
cargo fmt --all -- --check
cargo clippy --workspace --all-targets --all-features --locked -- -D warnings
cargo test --workspace --all-targets --locked
```

The inherited binary is still named `herdr`. Its configuration, session names,
integration commands, and update endpoints have not been isolated for Teaser
distribution. Do not install it over an existing Herdr, run upstream update or
release commands, or launch it against a personal session. Namespace isolation is
required before user-facing distribution.

Cargo warns that the nested manifest's patch is ignored; the root manifest
explicitly applies the same vendored `portable-pty` patch. Root `Cargo.lock` is
authoritative. The nested lockfile is retained upstream material, not a second
Teaser dependency authority.

Native checks and packaging remain separate:

Before packaging, put the signing identity in the local, Git-ignored `.env`.
The checked-in `.envrc` loads it through direnv. For a new checkout, copy the
template only if `.env` does not already exist:

```fish
test -e .env; or cp .env.example .env
security find-identity -v -p codesigning
```

Set `TEASER_CODESIGN_IDENTITY="..."` in `.env` to an exact listed Apple Development
or Developer ID Application identity, then run `direnv allow`. Keep an existing
App's identity; do not automatically switch certificates or use ad-hoc signing.
Never commit `.env` or a personal signing identity.

With the fish direnv hook enabled, entering this directory loads `.env` and
leaving restores the previous environment. If needed, enable the hook once in
the fish configuration with `direnv hook fish | source`. Noninteractive commands
can use `direnv exec . fish scripts/app.fish --build-only` without a shell hook.
Then run the native checks or build:

```fish
swift run TeaserWindowAdoptionTests
fish scripts/app.fish --build-only
```

`--build-only` produces `target/macos/Teaser.app` without launching it and requires
`TEASER_CODESIGN_IDENTITY`. The eight Swift suites are executable harnesses, not
`swift test` targets. Headless tests must not create windows, install global
monitors, request Accessibility, or move user windows.

The full gate is:

```fish
pre-commit install
pre-commit run --all-files --hook-stage pre-push
```

It includes runtime Rust checks, native harnesses, App packaging, and retained
Ghostty patch applicability. Initialize the legacy Ghostty submodule only for its
checks; see [dependency/probe instructions](vendor/README.md). First builds can
download and compile substantial dependencies. A manifest/format check is not a
completed build.

## Fork maintenance and licensing

Follow the explicit subtree update procedure in
[Architecture](docs/architecture.md#upstream-maintenance); never automatically
follow upstream master or activate its release automation.

Teaser-owned code retains [AGPL-3.0-or-later](LICENSE). Inherited Herdr code retains
[Apache-2.0](runtime/herdr/LICENSE); vendored dependencies retain their own
licenses. Preserve [NOTICE](NOTICE), [third-party notices](THIRD_PARTY_NOTICES.md),
and the [trademark policy](TRADEMARKS.md). Teaser is independent of Herdr; the
import does not imply endorsement or relicense inherited code.
