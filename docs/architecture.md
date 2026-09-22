# Teaser architecture

## Decision and implemented boundary

Teaser is a product fork of Herdr: reuse its server, TUI, terminal machinery,
agent integrations, and remote transport; add task-driven spatial organization
and the native macOS App. `runtime/upstream.toml` records the imported release.

The baseline contains:

- `runtime/herdr`: an editable full-history subtree, initially unchanged from
  Herdr v0.9.1. Root Cargo builds it with its vendored PTY patch. Its JSON API
  now applies Teaser organization commands and persists the shared graph.
- `crates/teaser-core`: pure typed identities, membership, task references,
  content-neutral bindings, size profiles, and atomic revisioned transitions.
- `app/macos`: the retained Swift/AppKit implementation, explicit JSON client,
  and ten headless test harnesses. The client projects the server graph into
  native tiling; interactive terminal rendering is not connected yet.
- `prototypes/attachment-runtime`: the previous self-built PTY runtime, outside
  the active workspace. Its protocol and native Ghostty experiment are preserved
  as reference/test material, not as another production session authority.

Shared organization is separate from inherited terminal workspace/tab containers;
the TUI has not yet been projected onto it. Task providers and dependable
external-window adoption remain implementation work.
No GUI acceptance follows from an import or a headless check.

## Target responsibility boundaries

```text
Shared organization core
  Project / Workspace / TaskRef / Panel / size profiles / commands
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

Tiling fills usable space with unequal sizes and clear gaps: the narrow gutter
inside one group, the wide one between groups. Unequal sizing comes from the
Panels' growth weights, and a divider the person drags keeps their proportion.
Same-Workspace adjacency is a soft preference, not a connected-rectangle
constraint. Adjacent members share an outer fluorescent contour; disconnected
fragments use the same color, and an enclosed other-group Panel is a stroked
hole. Do not draw a giant bounding box around intervening groups, and draw
nothing on a canvas showing a single group. A Panel below its minimum is still
placed and is reported with the size it needs.

Share topology, constraints, ratios, and commands where meaningful. Native pixel
geometry and TUI cell geometry remain separate projections. Terminal resize
ownership needs explicit server arbitration: two clients must not continuously
resize one PTY against each other. Viewport and focus remain client-local.

## Native App and external windows

The JSON client reuses the existing native implementation. Each open canvas is
one display to the layout solver and owns one flat Panel tree; the projection
seats each Panel on a canvas the client owns, so closing one canvas never
rearranges another. A Workspace owns no rectangle: membership travels on the
Panel, and the group's shape is a contour derived from the solved frames.
A canvas with no authoritative projection behind it seeds one empty Panel, so it
is usable before anything connects.

Connection and organization controls accept an explicit JSON socket path. They
can create, rename, delete, regroup, change kind, and rebind through server
commands. Only committed snapshots change the logical projection. Empty
Workspaces remain in the controls; the current tiler needs at least one Panel.
Pixel geometry and virtual focus stay local. Startup/connect do not activate the
stage or request Accessibility; Stage and Adopt remain separate user gestures.

Within a connection, unchanged bindings retain local window leases. Removed or
rebound Panels release them. Connection switches stop/release before accepting
the new graph, and Stop/Release stays available offline. Native terminal bindings
are explicitly labelled metadata-only; they do not activate a terminal renderer.

Splitting first creates the logical Panel at the server; local placement and
adoption intent only proceeds after confirmation on the same connection. An
unbound target is rebound to an App provider before installing its exact lease.
An App-bound target requires a matching bundle; terminal/Notes and other App
bindings require explicit rebind. Cross-provider center swaps are unavailable in
this slice rather than changing bindings in native state alone.

The old local organization reset, custom kind-definition registry editor, and
organization undo are disabled in shared mode. Custom kind strings can be edited
through server commands; the shared profile data is not a finished kind-template
registry. Local focus, divider changes, and presentation still use native rules.
The adapter validates the full wire profile and maps minima, aspect range and
growth weight into the retained solver. Profile name and preferred dimensions
are retained in the authoritative snapshot, not additional native solver inputs.

The server has no durable instance identity in this slice. Each connection gets
a fresh local scope, even at the same socket path. Notes text is keyed by scope
and byte-exact UTF-8 document reference, without Unicode normalization; local
layout preferences and Notes document records are archived beneath
`~/Library/Application Support/Teaser/connection-scopes`. Reconnect does not
automatically restore another scope's content or placement. The controls expose
the archive directory for recovery and report write failures. Legacy
`presentation.json` is neither overwritten nor silently imported.

One `Teaser.app` hosts several CanvasWindows. A canvas either fills its screen
and stays on its ordinary Space, where adopted windows tile above it, or enters
macOS green-button fullscreen, which macOS gives a Space of its own. No public or
private interface admits another application's window to a fullscreen Space, so a
fullscreen canvas carries Teaser's own content; adopted windows keep their leases
on the desktop Space. First launch opens an empty canvas filling its screen;
restoring saved canvases across launches is still implementation work. Six
Workspaces are a density scene, not a startup preset.

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
approach. KeyboardShortcuts remains a pinned native dependency; SplitView went
with the Layout Editor window it was the only user of. Neither embeds windows or
solves native fullscreen coexistence. Swindler remains an optional probe, not a
fork-migration dependency.

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

Persist membership, task references, binding hints, and size preferences at the
server boundary. Shared placement intent remains planned. Native presentation
preferences are not task/session truth. The JSON organization extension rejects
stale commands and publishes full revisioned snapshots; see `docs/ipc.md`.

Successful writes confirm an in-memory authoritative commit; disk writes use the
existing debounced atomic session writer. Organization-only sessions are retained.
On startup and handoff, terminal bindings are cleared rather than guessing whether
an old public pane ID still identifies the same process. App bindings are provider
hints, not live window identities. Neither removing a Panel nor clearing a binding
terminates its provider.

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
