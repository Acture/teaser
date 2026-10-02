# Teaser

Teaser is a macOS-first spatial development environment, built as a product fork
of [Herdr](https://github.com/herdrdev/herdr). Its main interface is tiling:
complete project contexts stay visible together instead of disappearing behind
mutually exclusive tabs. A real terminal UI and a native App are two clients of
the same intended organization and runtime, not two separate products.

Teaser builds on the server, TUI, terminal, and agent integration work of the
[Herdr contributors](https://github.com/herdrdev/herdr/graphs/contributors).
Our imported baseline is [Herdr v0.9.1](https://github.com/herdrdev/herdr/releases/tag/v0.9.1);
the exact revision is recorded in [upstream provenance](runtime/upstream.toml).
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

| Path | Role |
| --- | --- |
| `runtime/herdr` | Editable Herdr server/TUI fork, with upstream source and tests |
| `runtime/upstream.toml` | Exact imported baseline and provenance |
| `crates/teaser-core` | Shared organization model and atomic transitions |
| `app/macos` and `Package.swift` | Native App, adapters, and headless harnesses |
| `notes/teaser` | Canonical project documents in the Obsidian vault submodule |
| `prototypes/attachment-runtime` | Retired self-built PTY runtime, outside the active workspace |
| `vendor/ghostty` and `patches/ghostty` | Retained native attachment experiment |

The fork uses a history-preserving Git subtree, not an installed Herdr binary or
a read-only submodule. It keeps the `Acture/teaser` repository and macOS history.
This does not change GitHub's fork-network metadata.

See the [documentation index](notes/teaser/README.md),
[Architecture](notes/teaser/docs/architecture.md),
[Terminology](notes/teaser/CONTEXT.md), [Protocol](notes/teaser/docs/ipc.md),
[delivery outcomes](notes/teaser/ROADMAP.md), and the
[implementation contract](notes/teaser/plan/architecture-teaser-platform-1.md).
Execution status and dependencies live in [Linear](https://linear.app/acturea/project/teaser-efe303ae636d).

## Documentation workflow

`notes/` references the existing
[Acture/obsidian-vault](https://github.com/Acture/obsidian-vault) repository on
`project/teaser`; edit only `notes/teaser/**` on that branch. Daily work defaults
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
clone can omit notes; see [vendor instructions](vendor/README.md) for Ghostty.

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

After editing files under `notes/teaser/`, review and deliver in this order:

```fish
git -C notes diff --check
git -C notes diff -- teaser
git -C notes add -- teaser
git -C notes commit -m "docs(teaser): update project documentation"
git -C notes push origin HEAD:refs/heads/project/teaser
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
`TEASER_CODESIGN_IDENTITY`. The eleven Swift suites are executable harnesses,
not `swift test` targets. Headless tests must not create windows, install global
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

### Isolated native integration session

Use a disposable development server, not an installed Herdr session. Build the
runtime and App explicitly; these commands may take time:

```fish
cargo build --locked -p herdr
direnv exec . fish scripts/app.fish --build-only
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
[Architecture](notes/teaser/docs/architecture.md#upstream-maintenance); never
automatically follow upstream master or activate its release automation.

Teaser-owned code retains [AGPL-3.0-or-later](LICENSE). Inherited Herdr code retains
[Apache-2.0](runtime/herdr/LICENSE); vendored dependencies retain their own
licenses. Preserve [NOTICE](NOTICE), [third-party notices](THIRD_PARTY_NOTICES.md),
and the [trademark policy](TRADEMARKS.md). Teaser is independent of Herdr; the
import does not imply endorsement or relicense inherited code.

Apache-2.0 permits forks, modifications, and redistribution. When redistributing
inherited code, include its license, retain applicable upstream notices, and
mark modified files as changed. The license does not grant trademark rights or
permission to imply upstream endorsement; see
[Apache-2.0 sections 4 and 6](https://www.apache.org/licenses/LICENSE-2.0).
