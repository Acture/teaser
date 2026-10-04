# Teaser

Teaser is a macOS-first spatial development environment, built as a product fork
of [Herdr](https://github.com/herdrdev/herdr). Its main interface is tiling:
complete project contexts stay visible together instead of disappearing behind
mutually exclusive tabs. A real terminal UI and a native App are two clients of
the same intended organization and runtime, not two separate products.

Teaser builds on the server, TUI, terminal, and agent integration work of the
[Herdr contributors](https://github.com/herdrdev/herdr/graphs/contributors).
Our imported baseline is [Herdr v0.9.1](https://github.com/herdrdev/herdr/releases/tag/v0.9.1);
the exact revision is recorded in [upstream provenance](src/runtime/upstream.toml).
Teaser is an independent fork, not an official or endorsed Herdr distribution.

> Current state: the Herdr v0.9.1 server/TUI source and full history are imported.
> The fork now has a pure organization core and revisioned JSON commands/events.
> The native App connects to an explicitly selected JSON socket and projects
> server-owned Workspaces/Panels into its existing tiling and Notes interface.
> The App now hosts several canvas windows, each with its own Workspaces,
> lifecycle and adopted windows. Interactive native terminal rendering, TUI
> organization projection, task providers, and dependable live-window adoption
> remain implementation work. Focused headless tests are not a completed
> end-to-end demo or a full build gate.

## Product model

- A **Workspace** is a persistent, project-scoped group of Panels. Membership is
  independent of placement: a Workspace can span canvases, and one canvas can
  show several Workspaces.
- A **Panel** is content-neutral. Task, CLI, App, Agent, File, and Notes are
  extensible kinds with minimum size, preferred aspect ratio, and growth rules,
  not application-specific subclasses.
- Panels tile at unequal sizes. Same-Workspace adjacency is a preference, not a
  rectangular-container constraint. A fluorescent outer contour expresses the
  group without adding a Workspace card or title bar. The canvas also publishes
  an accessibility element per Panel, so the group, the binding and an
  unsatisfied minimum size can be read or spoken rather than only seen.
- The native App hosts several canvas windows. Each can fill its screen, which
  keeps it on its Space where adopted windows tile above it, or enter macOS
  green-button fullscreen, which gives it a Space of its own that only Teaser's
  own content can appear in. First launch opens an empty canvas filling its
  screen, with incremental splits, not six prefilled project mockups.
- Task-driven work links external tasks to Panels and sessions. Linear/Notion
  remain task authorities; Teaser provides organization and its own Notes.
- The TUI retains a terminal-native workflow. GUI-only providers are explicit
  references or unavailable views, never simulated application windows.

External applications retain their own rendering and input. Adoption manages one
exact provider window's geometry and releases it safely; it does not reparent,
capture, or inject input. Real-window acceptance is not inferred from headless
geometry tests.

## Source layout

Source code, retained experiments, and vendored dependencies live under `src/`.
Root manifests remain the Cargo/SwiftPM entry points. `project.yml` declares the
native App; `Teaser.xcworkspace` shares the root dependency lockfile. Run the
commands below from the repository root.

| Path | Role |
| --- | --- |
| `src/runtime/herdr` | Editable Herdr server/TUI fork, with upstream source and tests |
| `src/runtime/upstream.toml` | Exact imported baseline and provenance |
| `src/crates/teaser-core` | Shared organization model and atomic transitions |
| `src/app/macos` and `Package.swift` | Shared native module, adapters, and headless harnesses |
| `project.yml` and `Teaser.xcworkspace` | XcodeGen App target and shared dependency lock |
| `src/probes` | Isolated dependency compatibility probes |
| `notes` | Canonical project documents in the Obsidian vault submodule |
| `src/prototypes/attachment-runtime` | Retired self-built PTY runtime, outside the active workspace |
| `src/vendor/ghostty` and `src/patches/ghostty` | Retained native attachment experiment |

The fork uses a history-preserving Git subtree, not an installed Herdr binary or
a read-only submodule. It keeps the `Acture/teaser` repository and macOS history.
The current subtree prefix is `src/runtime/herdr`; older `runtime/herdr` examples
must use this new prefix. This does not change GitHub's fork-network metadata.

See the [documentation index](notes/README.md),
[Architecture](notes/docs/architecture.md),
[Terminology](notes/CONTEXT.md), [Protocol](notes/docs/ipc.md),
[delivery outcomes](notes/ROADMAP.md), and the
[implementation contract](notes/plan/architecture-teaser-platform-1.md).
Execution status and dependencies live in [Linear](https://linear.app/acturea/project/teaser-efe303ae636d).

## Documentation workflow

`notes/` references the existing
[Acture/obsidian-vault](https://github.com/Acture/obsidian-vault) repository on
`project/teaser`; edit only `notes/**` on that branch. Daily work defaults
to the latest fetched commit on that branch, not the parent's older gitlink.
Git still records an exact commit for provenance and historical reproduction.
The commands below explicitly request the configured remote branch; ordinary
Git clone/update without the remote flags does not automatically follow it.
GitHub readers can open the
[project branch index](https://github.com/Acture/obsidian-vault/blob/project/teaser/teaser/README.md).

The vault requires access to the private repository. Notes are not needed to
build Teaser. README, agent instructions, source, licenses/notices, and vendored
documentation remain here. The original documents and their history remain in
Teaser's pre-migration commits; the vault also retains extracted document history
and its source mapping. There was no `doc` branch; `master` was the migration
source. No existing branch was removed or rewritten.

### Clone and initialize

Clone with the latest notes branch (the retained Ghostty experiment is separate):

```fish
git clone --recurse-submodules=notes --remote-submodules https://github.com/Acture/teaser.git
cd teaser
```

For a new worktree or an uninitialized notes submodule, from the Teaser root:

```fish
git submodule sync -- notes
git submodule update --init --remote --checkout -- notes
git -C notes rev-parse HEAD
```

This fetches `project/teaser` and retrieves its current tip. After pulling code,
and before reading notes at the start of a session, use the refresh workflow
below. A changed `notes` gitlink is expected when the branch has advanced; do not
hide it with an ignore setting. If fetching fails, report that the notes could
not be refreshed instead of calling the cached checkout "latest". A code-only
clone can omit notes; see [vendor instructions](src/vendor/README.md) for Ghostty.

### Refresh notes before daily work

Preserve unrelated parent changes. For initialized notes, first check for local
edits and unpublished commits. Stop if notes status is nonempty, fetching fails,
or the ancestry check fails; do not reset or abandon local work:

```fish
git status --short
git -C notes status --short
git -C notes fetch origin refs/heads/project/teaser:refs/remotes/origin/project/teaser
git -C notes merge-base --is-ancestor HEAD origin/project/teaser
```

Only after those checks succeed, update `notes` (not all submodules):

```fish
git submodule update --init --remote --checkout -- notes
git diff --submodule=log -- notes
```

Review that the checkout still contains `teaser/README.md`. The explicit remote
update follows `project/teaser` and can leave detached HEAD. To record the reviewed
version after the branch has advanced, commit the pointer in the parent repository:

```fish
git add -- notes
git commit -m "docs: update Teaser notes reference"
git push
```

### Reproduce a recorded documentation version

Only when explicitly reproducing an older code/documentation pair, after the
same local-work safety checks, omit `--remote`:

```fish
git submodule update --init --checkout -- notes
```

This restores the parent's fixed commit. It is not the daily-work default.

### Edit and submit notes

Refresh first. With clean notes, switch to the writable project branch
(Git creates its tracking branch from `origin` on a fresh clone):

```fish
git -C notes fetch origin
git -C notes switch project/teaser
git -C notes merge --ff-only origin/project/teaser
```

If local history has diverged, stop and reconcile it; do not force or reset it.
Master/project aggregation follows the vault's
[existing workflow](notes/Workflow/研究工作流.md), not a new sync service here.
Build commands and code paths in the documents refer to the Teaser checkout.

After editing files under `notes/`, review and deliver in this order:

```fish
git -C notes diff --check
git -C notes diff -- teaser
git -C notes add README.md
git -C notes commit -m "docs(teaser): update project documentation"
python3 (git -C notes rev-parse --path-format=absolute --git-common-dir)/hooks/notes-boundary/submit_project.py --repo notes
```

Only after that push succeeds, confirm remote reachability and update the parent:

```fish
git -C notes fetch origin project/teaser
git -C notes merge-base --is-ancestor HEAD origin/project/teaser
git diff --submodule=log -- notes
git add -- notes
git commit -m "docs: update Teaser notes reference"
git push
```

Run the last steps only if the ancestry check succeeds. Never commit a gitlink
to an unpublished local notes commit, edit on detached HEAD, or recreate a
second editable copy at the retired document paths.

## Development

The runtime requires **Rust 1.96.1 and Zig 0.16.0**. Swift harnesses require
Swift 6.2 or newer; App packaging also needs Xcode, XcodeGen 2.46.0 or newer,
direnv, and a stable Apple Development or Developer ID signing identity.
Runtime tests use Herdr's process-isolated nextest runner; install it with
`brew install cargo-nextest`. Plain `cargo test` shares process-global signal
state between tests and is not the full runtime gate. The gate limits concurrency
to four cases because integration tests spawn their own subprocesses.

Run production Cargo commands from the repository root:

```fish
cargo build --locked -p herdr
cargo fmt --all -- --check
cargo clippy --workspace --all-targets --all-features --locked -- -D warnings
cargo nextest run --workspace --all-targets --locked --test-threads 4
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

### Native App and tests

SwiftPM owns `TeaserKit`, its C accessibility bridge, dependencies, and headless
tests. XcodeGen declares only the native `Teaser` App target and its root notices.
Xcode handles the App bundle, package resource bundles, Info.plist, and signing;
there is no separate hand-written packaging script or SwiftPM App executable.

Install XcodeGen with `brew install xcodegen`. Generate the ignored project with
`xcodegen generate --no-env`; regenerate after changing `project.yml` or adding
launcher files. Do not edit or commit `Teaser.xcodeproj`. Open
`Teaser.xcworkspace`, not the generated project alone: its
`xcshareddata/swiftpm/Package.resolved` is a symlink to the root lockfile, so Xcode
and SwiftPM use one dependency version source. Do not replace it with a copy.

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
the fish configuration with `direnv hook fish | source`. `direnv exec` also works
without a shell hook. Xcode expands `$(TEASER_CODESIGN_IDENTITY)` at build time;
the generated project contains no personal identity. GUI builds need Xcode to
inherit that environment too; the CLI command below is the reproducible entry.

Run native tests independently, then explicitly build the App (no UI is opened):

```fish
swift run TeaserWindowAdoptionTests
swift run TeaserBundleTests
xcodegen generate --no-env
direnv exec . xcodebuild -workspace Teaser.xcworkspace -scheme Teaser \
    -configuration Debug -destination 'platform=macOS' \
    -derivedDataPath target/xcode -clonedSourcePackagesDirPath .build \
    -disableAutomaticPackageResolution -skipPackageUpdates build
```

The product is `target/xcode/Build/Products/Debug/Teaser.app`; the old
`target/macos/Teaser.app` is not updated by this workflow. For Release builds, use
`-configuration Release` and the sibling `Release` product directory. Neither
command opens the App. Stable signing remains required; never pass
`CODE_SIGNING_ALLOWED=NO` or an ad-hoc identity as a successful packaging check.

Validate the signed product and exercise its bundled resources without creating
NSApplication or observing the desktop:

```fish
codesign --verify --deep --strict \
    -R '=anchor apple generic and identifier "com.acture.teaser"' \
    target/xcode/Build/Products/Debug/Teaser.app
target/xcode/Build/Products/Debug/Teaser.app/Contents/MacOS/Teaser --check-bundle-resources
```

The signature requirement rejects unsigned/ad-hoc code and a different bundle
identifier, even if a local Xcode override allowed such a build. It does not
replace notarization or guarantee that an identity change preserves existing
Accessibility approval. Keep the same configured certificate.

The resource check covers license/notices and the upstream KeyboardShortcuts
localization accessor. The twelve Swift suites are executable harnesses, not
`swift test` targets. Headless tests must not create windows, install global
monitors, request Accessibility, or move user windows.

The full gate is:

```fish
pre-commit install
pre-commit run --all-files --hook-stage pre-push
```

It includes runtime Rust checks, native harnesses, XcodeGen generation, signed
App packaging/resource checks, and retained Ghostty patch applicability.
Initialize the legacy Ghostty submodule only for its checks; see
[dependency/probe instructions](src/vendor/README.md). First builds can
download and compile substantial dependencies. A manifest/format check is not a
completed build.

### Isolated native integration session

Use a disposable development server, not an installed Herdr session. Build the
App with the XcodeGen/Xcode command above, then build the runtime explicitly;
these builds may take time:

```fish
cargo build --locked -p herdr
```

In one terminal, start the debug server with isolated configuration, state and
sockets. Its debug build disables inherited background update checks. The
directory is deliberately retained when the process exits:

```fish
set -l teaser_run (mktemp -d /tmp/teaser-herdr.XXXXXX)
printf 'JSON socket: %s/control.sock\n' "$teaser_run"
env -u HERDR_SESSION -u HERDR_CONFIG_PATH -u HERDR_CLIENT_SOCKET_PATH \
    -u HERDR_STARTUP_CWD \
    XDG_CONFIG_HOME="$teaser_run/config" \
    XDG_STATE_HOME="$teaser_run/state" \
    HERDR_SOCKET_PATH="$teaser_run/control.sock" \
    ./target/debug/herdr server
```

Use the printed JSON socket path in the native connection controls, not the
adjacent `control-client.sock` binary endpoint. Starting this server does not
establish GUI or external-window acceptance. Do not substitute an upstream
release binary: it lacks the Teaser organization methods.

Open the built `Teaser.app`, enter that path in **Connection & Organization**,
and choose **Connect / Reconnect**. **Create first context** submits a Project,
Workspace and Panel together. The same controls expose rename, regroup, kind,
binding and deletion; server rejections are visible. Empty Workspaces appear in
the controls and enter tiling after gaining a Panel.

Ctrl-D and drag-edge splits create the new Panel at the server before changing
its local placement. The previous local reset, definition-registry editor, and
organization undo cannot write around the server; these remain unavailable in
shared mode. Custom kind strings are editable in the organization controls.

Stage/adoption are separate explicit actions. **Stop / Release** remains usable
offline. Terminal bindings identify real runtime panes but do not render a
terminal. Notes text is local to this Mac and connection scope; reconnect starts
a fresh scope. **Reveal local Notes / layout archives** exposes earlier data for
recovery. The old `presentation.json` is left intact, not silently migrated.

## Fork maintenance and licensing

Follow the explicit subtree update procedure in
[Architecture](notes/docs/architecture.md#upstream-maintenance); never
automatically follow upstream master or activate its release automation.

Teaser-owned code retains [AGPL-3.0-or-later](LICENSE). Inherited Herdr code retains
[Apache-2.0](src/runtime/herdr/LICENSE); vendored dependencies retain their own
licenses. Preserve [NOTICE](NOTICE), [third-party notices](THIRD_PARTY_NOTICES.md),
and the [trademark policy](TRADEMARKS.md). Teaser is independent of Herdr; the
import does not imply endorsement or relicense inherited code.

Apache-2.0 permits forks, modifications, and redistribution. When redistributing
inherited code, include its license, retain applicable upstream notices, and
mark modified files as changed. The license does not grant trademark rights or
permission to imply upstream endorsement; see
[Apache-2.0 sections 4 and 6](https://www.apache.org/licenses/LICENSE-2.0).
