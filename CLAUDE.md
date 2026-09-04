# Repository Guidelines

## Product Model and Documentation Authority

Teaser is a macOS-first spatial development environment. Its core problem is
screen presentation: tab-based ADEs hide complete project contexts behind mutually
exclusive tabs even while work continues in parallel.

A `Workspace` is a persistent, project-scoped organization and display layer above
Panels. Multiple Workspaces may be tiled, focused, or switched as complete units
without rebuilding their state. A `Panel` is a content-neutral display region;
terminal, agent, project details, diff, image, and input views are Panel content.

Use one current-state source per concern:

- `README.md` defines the public product scope and motivation.
- `CONTEXT.md` defines canonical product and domain terminology.
- `docs/architecture.md` is the architectural source of truth.
- `ROADMAP.md` records milestones and exit gates.
- `plan/architecture-teaser-platform-1.md` contains the implementation and test
  plan.
- `docs/ipc.md` defines the current local control and attachment protocol.

Do not add ADRs or recreate `docs/adr`; decisions belong in the relevant canonical
current-state document. Keep legal and naming changes aligned with `LICENSE`,
`NOTICE`, and `TRADEMARKS.md`.

## Project Structure and Module Organization

The repository contains a runnable fixture-backed SwiftUI application prototype
plus the Rust foundation. The Rust workspace contains `crates/teaser-core` and
`crates/teaserd`. Native application and terminal integration live under
`app/macos/Teaser`; probes live under `app/macos/TeaserProbe` and
`app/macos/TeaserProbeTests`.

The pinned Ghostty source is the `vendor/ghostty` submodule. Teaser-owned provenance
and patches live under `vendor/README.md` and `patches/ghostty`. Shell integration,
terminal benchmarks, the production Ghostty-backed macOS host, and additional
`crates/teaser-*` packages remain planned until their paths exist.

Use exact names consistently: product `Teaser`, daemon and package `teaserd`, core
package `teaser-core`, protocol `teaser.attach.v1`, and runtime directory
`~/Library/Application Support/Teaser`. Do not add old-name aliases or data
migration unless explicitly requested.

## Build, Test, and Development Commands

The canonical full gate is:

```fish
fish scripts/check.fish
```

It verifies the `Teaser.app` build, pinned Ghostty inputs, Rust formatting, Clippy
warnings, Rust tests, Swift terminal-attachment and external-window tests, and
whitespace. The component Rust gates are:

```fish
cargo fmt --check
cargo clippy --workspace --all-targets --all-features -- -D warnings
cargo test --workspace --all-targets
```

Run the foreground daemon prototype with:

```fish
cargo run -p teaserd
```

Build the native application prototype with:

```fish
fish scripts/app.fish --build-only
```

It produces `target/macos/Teaser.app`. There is no Xcode project or production
packaging command yet. Live launch through `scripts/app.fish` requires
`TEASER_CODESIGN_IDENTITY` so Accessibility approval uses a stable application
identity.

## Coding Style and Naming Conventions

Wrap Markdown near 80 columns and preserve requirement identifiers such as
`REQ-001` and `TASK-001`. Application code should be typed Rust and Swift. Use tabs
where the language formatter permits, while letting rustfmt and Swift formatting
control generated layout. Name Rust modules and functions in `snake_case`,
Rust/Swift types in `UpperCamelCase`, and Swift members in `lowerCamelCase`.

Prefer immutable typed values and small traits only at seams with multiple real
implementations. Write repository scripts in fish syntax. Fail fast at internal
boundaries and add bounded, diagnostic logging around long-running or expensive
operations.

## Testing Guidelines

There is no coverage threshold yet. Add tests with each module: Rust integration
tests under `crates/<name>/tests`, Swift tests in the corresponding app test target,
and performance harnesses under `benchmarks/terminal`. Name tests after observable
behavior. Follow the implementation-plan matrix, especially malformed input,
permissions, recovery, IME, attachment ordering, teardown, and equivalent-hardware
performance cases.

## Commit and Pull Request Guidelines

History uses short conventional subjects such as `feat: add asynchronous terminal
attachment pump`. Keep commits focused. Pull requests should summarize the change,
reference applicable requirement or task IDs, and list verification performed.
Include screenshots for visible UI changes and measurements for performance claims.

Never commit `.codex/`, runtime databases, credentials, build products, or generated
user state. Preserve third-party license notices and keep the Ghostty submodule
clean when dependencies change.
