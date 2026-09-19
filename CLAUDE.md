# Repository Guidelines

## Product and authority

Teaser is a macOS-first spatial development environment built as a Herdr product
fork. Tiling is primary; TUI and native App are clients of a shared server. A
Workspace groups Panels independently of canvas placement. Same-group adjacency
is a preference, expressed with fluorescent outer contours, not container cards.
Task providers retain task authority. Native input remains provider-owned.

One current-state source per concern:

- `README.md`: public scope and implemented boundary.
- `CONTEXT.md`: canonical domain terminology.
- `docs/architecture.md`: architecture and upstream maintenance.
- `docs/ipc.md`: current protocol boundary and planned extensions.
- `runtime/upstream.toml`: exact fork provenance.
- `ROADMAP.md`: delivery outcomes and exit gates, not a second status tracker.
- `plan/architecture-teaser-platform-1.md`: implementation/test contracts.
- Linear: active tasks, dependencies, blockers, and execution status.

Do not add ADRs or another parallel plan. Update canonical documents and Linear
when decisions change. Preserve `LICENSE`, `NOTICE`, and third-party licenses.

## Source structure

`runtime/herdr` is an editable, full-history subtree of the pinned upstream. Root
Cargo builds this runtime/TUI; its vendored portable-pty patch is repeated at the
workspace root. The root lockfile is authoritative; nested lockfiles record the
inherited source. Never activate upstream release automation for Teaser or push
to the upstream remote. Follow the explicit subtree update procedure.

`app/macos/Teaser` and `Package.swift` retain the Swift/AppKit app and eight
headless executable harnesses. The App is not yet connected to Herdr. Shared core,
task providers, and multiple native-fullscreen canvases remain implementation
work. Do not infer real-window adoption from pure geometry tests.

`prototypes/attachment-runtime` is the retired self-built Rust runtime. It and
the root Ghostty submodule/patches are retained experiments, not a second
production backend. Do not add new product behavior or compatibility aliases
there. Remove superseded adapters when their replacement integration lands.

The imported binary is still `herdr`; runtime namespace, installer, integration,
and update-endpoint isolation must precede Teaser distribution. Never launch this
baseline against the user's installed Herdr state. The native product remains
one `Teaser.app`, not a separate demo app.

## Build and test

Runtime: Rust 1.96.1 and Zig 0.16.0. Native: Swift 6.2+, Xcode, and a stable
signing identity for App packaging. From the repository root:

```fish
cargo build --locked -p herdr
cargo fmt --all -- --check
cargo clippy --workspace --all-targets --all-features --locked -- -D warnings
cargo test --workspace --all-targets --locked
swift run TeaserWindowAdoptionTests
fish scripts/app.fish --build-only
pre-commit run --all-files --hook-stage pre-push
```

Install both Git hook stages with `pre-commit install`. Swift tests are executable
harnesses, not `swift test` targets. `--build-only` creates
`target/macos/Teaser.app` without launching it and requires
`TEASER_CODESIGN_IDENTITY`. Do not claim a manifest check proves compilation.
Give long toolchain/dependency downloads and full-build commands to the user to
run manually; do not launch them implicitly during a migration check.

Default native tests must not show windows, install global event monitors, request
Accessibility, or move the user's windows. Do not launch the App, TUI, server, or
desktop overlay for a smoke test without explicit scoped authorization. Headless
runtime tests must use isolated disposable sessions and state.

## Implementation conventions

Use typed Rust and Swift, tabs where formatters permit, and small protocols/traits
only at meaningful seams. Shared core owns pure organization and transitions;
server owns mutable runtime authority; clients own presentation/focus. Keep
terminal cell geometry separate from native pixels. Preserve negotiated upstream
endpoint contracts when introducing Teaser capabilities.

Use fish for Teaser-owned shell scripts. Fail fast at internal boundaries; log
bounded lifecycle/timing diagnostics without raw terminal content or credentials.
Preserve requirement IDs and wrap prose near 80 columns. Add behavior tests with
each change, not separate feasibility tickets that defer implementation.

## Git and vendored material

Use focused conventional commits without AI co-author trailers. Never rewrite
published history, change GitHub fork-network membership, or enable release
automation as an implicit source migration step. Preserve unrelated work.

Root `CLAUDE.md` is the real instruction file; `AGENTS.md` and
`.github/copilot-instructions.md` are symlinks. Nested upstream instructions are
inherited project material, not Teaser hosting/release policy. Do not commit
personal `.codex/` settings, runtime databases, credentials, or build products.
Keep vendored source and license notices intact during dependency updates.
