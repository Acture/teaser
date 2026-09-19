# Teaser architecture

## Decision and implemented boundary

Teaser is a product fork of Herdr: reuse its server, TUI, terminal machinery,
agent integrations, and remote transport; add task-driven spatial organization
and the native macOS App. `runtime/upstream.toml` records the imported release.

The baseline contains:

- `runtime/herdr`: an editable full-history subtree, initially unchanged from
  Herdr v0.9.1. Root Cargo builds it with its vendored PTY patch.
- `app/macos`: the retained Swift/AppKit implementation and eight headless test
  harnesses. It is not yet a client of the imported server.
- `prototypes/attachment-runtime`: the previous self-built PTY runtime, outside
  the active workspace. Its protocol and native Ghostty experiment are preserved
  as reference/test material, not as another production session authority.

The import does not implement shared organization, native multi-canvas fullscreen,
task providers, or dependable external-window adoption. No GUI acceptance follows
from an import or a headless check.

## Target responsibility boundaries

```text
Shared organization core (planned)
  Project / Workspace / TaskRef / Panel / placement intent / commands
                         |
Herdr-derived server: authoritative state, sessions, persistence, events
                         |
             +-----------+-----------+
             |           |           |
            TUI         CLI      Native App
        cell layout   automation   CanvasWindows / native input / AX leases
```

The core is a library, not another daemon. Server ownership prevents competing
organization stores. Swift can use the shared rules through typed protocol calls;
an FFI layer is not a prerequisite. Client snapshots are projections, not separate
authoritative databases.

Upstream currently binds Workspace to tabs and an active tab; layout depends on
Ratatui cell rectangles/borders. These are not a finished content-neutral core.
Extract seams incrementally with behavior tests, keeping the upstream runtime
and TUI operational throughout.

## Organization and layout

Workspace membership is independent of placement. One Workspace can span native
canvas windows; one canvas can display several Workspaces. Closing a canvas is
not deleting a Workspace, terminating sessions, or releasing other canvases.

Panels have stable IDs, typed bindings, and data-defined size profiles. Task,
CLI, App, Agent, File, and Notes are kinds, not subclasses. A move changes
placement; explicit regroup changes membership. Neither recreates the content.

Tiling fills usable space with unequal sizes and clear gaps. Same-Workspace
adjacency is a soft preference, not a connected-rectangle constraint. Adjacent
members share an outer fluorescent contour; disconnected fragments use the same
color. Do not draw a giant bounding box around intervening groups.

Share topology, constraints, ratios, and commands where meaningful. Native pixel
geometry and TUI cell geometry remain separate projections. Terminal resize
ownership needs explicit server arbitration: two clients must not continuously
resize one PTY against each other. Viewport and focus remain client-local.

## Native App and external windows

Reuse the existing native implementation. Replace its single-canvas and
display/Workspace/Panel hierarchy at the model boundary as it becomes a client.

The target is one `Teaser.app`, several CanvasWindows, and macOS native
green-button fullscreen per window. First launch targets an empty canvas; saved
layouts restore their own state. A borderless display-sized window is not native
fullscreen, and six Workspaces are a density scene, not a startup preset.

Provider-owned windows keep native rendering and input. The App leases exact
PID + CGWindowID + AX identity, manages geometry, verifies writes, and compensates
failures. Never rebind by title/path or duplicate a live window into several
Panels. Persist provider hints, not live identities.

Virtual Focus selects layout targets without stealing OS input. Explicit input
handoff activates the exact provider window. Local close releases local leases;
global stop/quit releases all. Restore a provider frame only while its identity
is valid and it remains at the frame last applied by Teaser.

The retained code uses public AX/CG APIs plus the isolated read-only
`_AXUIElementGetWindow` declaration for exact identity, following AeroSpace's
approach. SplitView and KeyboardShortcuts remain pinned native dependencies.
Neither embeds windows or solves native fullscreen coexistence. Swindler remains
an optional probe, not a fork-migration dependency.

Fullscreen transitions, Spaces, permissions, and real-window coexistence remain
native implementation work. Do not promise arbitrary reparenting, forced
cross-Space movement, screenshots as live Panels, or synthetic background input.

## Task-driven workflow

Providers own task content/status. Teaser stores qualified task references and
links to Workspaces, checkouts, Panels, and sessions. Selecting a task can reveal
or arrange existing context without recreating terminals.

Provider integration belongs behind a shared server-side interface. App and TUI
render the same structured data. A native Linear/Notion window does not make a
task readable in TUI: use provider data or an honest link/unavailable state. A
cache is not another execution authority. Notes can remain Teaser-owned content.

## Protocol and persistence

Start from Herdr's JSON control/event API and negotiated client endpoint. Do not
assume its private binary attachment protocol is stable across builds. Shared
organization operations must be typed server-visible commands, not TUI-only side
effects. Preserve frozen endpoint contracts or negotiate a new capability; never
silently reinterpret published IDs or wire fields.

Persist membership, task references, binding hints, and layout intent at the
server boundary. Native presentation preferences are not task/session truth.
Reject stale commands; expose unavailable providers and reconnect state.

Keep the runtime lifecycle: client detach need not terminate sessions. Restoring
layout or resuming an agent conversation after server restart does not mean the
original PTY survived. See `docs/ipc.md`.

## Build and distribution boundary

Root Cargo owns the active workspace and lockfile. Its patch section repeats the
nested portable-pty patch because Cargo ignores non-root patches. The nested
lockfile records upstream, not another authoritative Teaser resolution. Rust
1.96.1 and Zig 0.16.0 match the imported baseline; the build script compiles
vendored libghostty-vt. No installed Herdr binary is a build dependency.

The inherited package/binary remains `herdr`. Public `teaser` / `teaserd` names,
config/socket/session isolation, integration launchers, and disabling/replacing
upstream update endpoints are a coordinated follow-up, not a blind string
replacement. Until then, do not install or launch against personal Herdr state.
The App does not yet bundle the runtime.

Upstream workflows, installer payloads, maintainer metadata, and release scripts
stay inside the subtree. They are not Teaser release automation. Do not activate
them or upload to upstream repositories. Preserve inherited Apache-2.0 and vendor
licenses; Teaser-owned code retains its existing license. Packaging must inventory
notices for the actual artifacts shipped.

## Upstream maintenance

The initial subtree commit has both the pre-fork Teaser commit and the pinned
Herdr release as parents. Source history is preserved without rewriting the
published branch. The existing GitHub repository remains independent; its fork
network badge is a separate hosting property.

For an explicit upgrade on a clean integration branch:

1. Add remote `upstream` for `https://github.com/herdrdev/herdr.git` if absent.
2. Fetch the reviewed release without global prune/submodule side effects:
   `git -c fetch.prune=false -c fetch.pruneTags=false fetch --no-recurse-submodules --no-tags upstream refs/tags/RELEASE:refs/tags/herdr/RELEASE`.
3. Review the diff and run
   `git subtree merge --prefix=runtime/herdr herdr/RELEASE` without squash.
4. Update `runtime/upstream.toml`, root toolchain/config/patches, and root lockfile
   deliberately. Review protocol, persistence, and vendor changes. Do not
   overwrite Teaser modifications by copying an upstream directory over them.
5. Run runtime checks and affected native headless harnesses. Live desktop checks
   stay separate and explicitly authorized. Publish only to Teaser's own branch;
   upstream contribution is a separate action.

`RELEASE` means a chosen upstream tag, not a literal argument. Shared-core
extraction should minimize terminal/runtime churn so future merges stay tractable.
Tests accompany implementation tasks, not a separate feasibility milestone.
