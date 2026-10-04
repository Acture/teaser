# Repository Guidelines

## Product and authority

Teaser is a macOS-first spatial development environment built as a Herdr product
fork. Tiling is primary; TUI and native App are clients of a shared server. A
Workspace groups Panels independently of canvas placement. Same-group adjacency
is a preference, expressed with fluorescent outer contours, not container cards.
Task providers retain task authority. Native input remains provider-owned.

One current-state source per concern:

- `README.md`: public scope and implemented boundary.
- `notes/CONTEXT.md`: canonical domain terminology.
- `notes/docs/architecture.md`: architecture and upstream maintenance.
- `notes/docs/ipc.md`: current protocol boundary and planned extensions.
- `src/runtime/upstream.toml`: exact fork provenance.
- `notes/ROADMAP.md`: delivery outcomes and exit gates, not a second tracker.
- `notes/plan/architecture-teaser-platform-1.md`: implementation contracts.
- Linear: active tasks, dependencies, blockers, and execution status.

Do not add ADRs or another parallel plan. Update canonical documents and Linear
when decisions change. Preserve `LICENSE`, `NOTICE`, and third-party licenses.

## Project documentation

The existing `https://github.com/Acture/obsidian-vault.git` repository is the
`notes/` submodule, configured for `project/teaser`. Its project entry is
`notes/README.md`. Read it alongside Linear and the code before planning.
Only edit `notes/**` on this project branch; leave other projects and
vault configuration unchanged. Do not add another notes repository or sync layer.

Daily work defaults to the latest `origin/project/teaser`, not the parent's
recorded gitlink. At the start of a session and after pulling code, refresh notes
before reading them. Follow README's safety checks first: refuse dirty notes,
fetch the project branch, and confirm notes HEAD is its ancestor so unpublished
commits are not abandoned. Then run
`git submodule update --init --remote --checkout -- notes`. For uninitialized
notes, run that command directly. If the fetch fails, report the failure; cached
content must not be described as current. Preserve unrelated parent changes.

New clones use `--recurse-submodules=notes --remote-submodules`. A newer notes
gitlink is expected and should be reviewed and recorded, not hidden or reset to
the old pin. Git still stores a commit; omit `--remote` only when explicitly
reproducing that historical version. Never update all submodules as a notes-sync
shortcut. Do not install implicit hooks, background sync or network-on-cd logic.

Initialization/remote update may detach HEAD. Before editing, fetch in `notes`,
switch to `project/teaser`, and fast-forward from `origin/project/teaser`.
Stop on dirty worktrees or diverged history; do not reset, force, or silently
choose a side. Commit and push the notes branch first. Confirm that notes HEAD
is reachable from the fetched remote project branch before staging the parent
gitlink. An unpublished notes commit must never become a delivered dependency.

The code repository retains README, this instruction file and its symlinks,
licenses/notices, source, build instructions and upstream/vendor documentation.
Notes access is not a build prerequisite. The five migrated documents have one
editable home in the vault; their original history remains in Teaser and the
extracted path history is recorded in the vault. No `doc` branch existed; the
approved migration source was `master`. Do not remove existing branches as part
of this workflow.

## Source structure

Keep product source, probes, prototypes, vendored source, and their patches under
`src/`. Root Cargo/SwiftPM manifests and `project.yml` remain build entry points.
Do not restore old root-level source directories or compatibility symlinks.

`src/runtime/herdr` is an editable, full-history subtree of the pinned upstream.
Root Cargo builds this runtime/TUI; its vendored portable-pty patch is repeated
at the workspace root. The root lockfile is authoritative; nested lockfiles
record the inherited source. Never activate upstream release automation for
Teaser or push to the upstream remote. Follow the explicit subtree update
procedure with prefix `src/runtime/herdr`, not the old `runtime/herdr` path.

`src/crates/teaser-core` owns pure organization transitions; the runtime exposes
revisioned JSON commands/events and persists that state. Inherited terminal
workspace/tab containers are not Teaser logical groups; TUI projection is pending.

`src/app/macos/Teaser` and `Package.swift` contain the Swift/AppKit client and
twelve headless executable harnesses. `TeaserKit` is a SwiftPM library consumed
by the thin XcodeGen App target; do not duplicate its source/dependency list in
`project.yml` or add a second SwiftPM App executable. `Teaser.xcworkspace` links
its resolved-package file to the root lockfile; preserve this single source.
Its Herdr connection is explicit, does not start a server or request
Accessibility, and has no local organization fallback.
Publishing the canvas's own accessibility tree is the opposite direction and
needs no permission; do not confuse it with requesting the service.
Terminal bindings are metadata, not native interactive terminal rendering.
Task providers remain implementation work, and restoring canvases across launches
belongs to persistence. Do not infer real-window adoption from pure geometry tests. Preserve legacy
presentation files and connection-scoped Notes archives; do not transplant local
leases/content across connections using only a matching socket path or object ID.

`src/prototypes/attachment-runtime` is the retired self-built Rust runtime. It and
the root Ghostty submodule/patches are retained experiments, not a second
production backend. Do not add new product behavior or compatibility aliases
there. Remove superseded adapters when their replacement integration lands.

The imported binary is still `herdr`; runtime namespace, installer, integration,
and update-endpoint isolation must precede Teaser distribution. Never launch this
baseline against the user's installed Herdr state. The native product remains
one `Teaser.app`, not a separate demo app.

## Build and test

Runtime: Rust 1.96.1, Zig 0.16.0, and cargo-nextest. Native: Swift 6.2+, Xcode,
XcodeGen 2.46.0+, direnv, and a stable signing identity for App packaging.
Use Herdr's process-per-test runner: its tests exercise process-global signal
state, so a shared `cargo test` process is not the full runtime gate.
Bound its subprocess-heavy integration suite to four concurrent tests.
From the repository root:

```fish
cargo build --locked -p herdr
cargo fmt --all -- --check
cargo clippy --workspace --all-targets --all-features --locked -- -D warnings
cargo nextest run --workspace --all-targets --locked --test-threads 4
swift run TeaserWindowAdoptionTests
swift run TeaserBundleTests
xcodegen generate --no-env
direnv exec . xcodebuild -workspace Teaser.xcworkspace -scheme Teaser \
    -configuration Debug -destination 'platform=macOS' \
    -derivedDataPath target/xcode -clonedSourcePackagesDirPath .build \
    -disableAutomaticPackageResolution -skipPackageUpdates build
codesign --verify --deep --strict \
    -R '=anchor apple generic and identifier "com.acture.teaser"' \
    target/xcode/Build/Products/Debug/Teaser.app
target/xcode/Build/Products/Debug/Teaser.app/Contents/MacOS/Teaser --check-bundle-resources
pre-commit run --all-files --hook-stage pre-push
```

Install both Git hook stages with `pre-commit install`. Swift tests are executable
harnesses, not `swift test` targets. Xcode owns the App bundle and signing, using
`TEASER_CODESIGN_IDENTITY` loaded by direnv from the ignored `.env`. Never select
another identity automatically or accept ad-hoc/disabled signing as a passed
packaging gate. Generated `Teaser.xcodeproj` and `target/xcode` stay ignored.
No build command opens the App. Do not claim project generation or build-settings
inspection proves compilation, signing, or resource validation.
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


## Project notes submission

`docs/` is reserved for public documentation. Private research notes live in `notes/`, which tracks `project/teaser` in `Acture/obsidian-vault`; start at `notes/README.md`. This checkout's root contains only this project's notes. Master places these notes under `teaser/`. Keep automation and vault configuration on master. Preserve existing local edits when updating a checkout.

Install or refresh the trusted submission tools in Git metadata, including in new clones:

```fish
git -C notes fetch origin refs/heads/master:refs/remotes/origin/master
set notes_common_gitdir (git -C notes rev-parse --path-format=absolute --git-common-dir)
git -C notes show origin/master:.github/scripts/install_push_hook.py > "$notes_common_gitdir/install_push_hook.py"
python3 "$notes_common_gitdir/install_push_hook.py" --repo notes --source-ref origin/master
```

After committing specific note files, submit through `python3 "$notes_common_gitdir/hooks/notes-boundary/submit_project.py" --repo notes`. The remote requires `notes-boundary/root/teaser` from GitHub Actions. Only after successful submission should this repository commit and push the `notes` gitlink. See the central repository's `项目接入.md` for initialization, updates and conflict handling.
