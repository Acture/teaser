---
goal: Turn the Herdr product fork into shared task-driven TUI and native App clients
version: 2.0
date_created: 2026-07-21
last_updated: 2026-09-19
owner: Acture
status: 'In Progress'
tags: [architecture, herdr, fork, macos, tui, rust, swift]
---

# Introduction

![Status: In Progress](https://img.shields.io/badge/status-In%20Progress-yellow)

This contract replaces the independent PTY/Ghostty-first implementation route.
Execution status belongs in Linear. Existing requirement IDs below retain their
meaning; retired terminal/block/ACP/tmux-specific requirements are not release
gates for the Herdr fork. Their previous definitions remain in Git history.

## 1. Requirements & Constraints

- **REQ-008**: Adopt exact provider windows without reparenting, capture, synthetic
  input, title/path guessing, or promises of forced cross-Space movement.
- **REQ-013**: Panel identity is independent of kind, binding, and Session.
- **REQ-014**: Virtual Focus does not implicitly redirect native Input Focus.
- **REQ-015**: Panel kinds/profiles are extensible data with per-Panel overrides.
- **REQ-016**: Reuse the pinned Herdr server/TUI as the production runtime source.
- **REQ-017**: Share organization rules in a pure core and authority in the server.
- **REQ-018**: Workspace membership is independent of canvas placement.
- **REQ-019**: Task providers own task truth; clients share qualified references.
- **REQ-020**: Support multiple independent native-fullscreen CanvasWindows.
- **SEC-001**: Isolate Teaser runtime identity before installation; never attach
  development checks to personal Herdr state or activate upstream release tools.
- **SEC-002**: Bound decoded data, snapshots, queues, and cached provider content;
  never log credentials or raw terminal content by default.
- **SEC-003**: Headless checks cannot request Accessibility or operate the desktop.
- **CON-001**: The native App is macOS-first; runtime portability is not App parity.
- **CON-003**: Use typed Rust/Swift and existing terminal machinery.
- **CON-005**: Preserve Teaser and inherited upstream licenses and notices.
- **PAT-001**: Server owns shared state; clients own rendering, viewport, and focus.
- **PAT-002**: Unsupported capabilities and failures are explicit, not fallback
  to a second organization store or the retired daemon.

## 2. Implementation Steps

### Phase 1 — Fork baseline

- **GOAL-001**: Establish an inspectable source fork without losing native work.

| Task | Contract | Completion evidence |
| --- | --- | --- |
| TASK-001 | Import Herdr with full Git ancestry into `runtime/herdr`; record provenance in `runtime/upstream.toml`. | Both source histories are ancestors; imported tree matches the pinned release before Teaser deltas. |
| TASK-002 | Point root `Cargo.toml`, lockfile, toolchain, and PTY patch at the fork; isolate old crates in `prototypes/attachment-runtime`. | Cargo metadata selects Herdr; no old daemon is an active workspace member. |
| TASK-003 | Retain `app/macos`, `Package.swift`, notices, and headless harnesses; update canonical contracts. | Native source diff is empty for baseline import; links and structural checks pass. |

### Phase 2 — Shared core and server authority

- **GOAL-002**: Implement shared organization without a second runtime.

| Task | Contract | Completion evidence |
| --- | --- | --- |
| TASK-010 | Extract organization types and pure commands into `crates/teaser-core`; replace tab/container assumptions at `runtime/herdr/src/workspace.rs` and the native model boundary. | Unit tests cover cross-canvas membership, stable IDs, explicit regroup, and close semantics without PTYs/UI. |
| TASK-011 | Connect core commands, snapshots/events, and persistence to `runtime/herdr/src/server`, `src/api`, and `src/persist`. Depends on TASK-010. | Two clients converge after mutations and reconnect; stale changes and unsupported capabilities are explicit. |
| TASK-012 | Separate Teaser binary/config/socket/integration/update identity in the fork before packaging or live use. | Isolated test roots cannot contact or overwrite installed Herdr state; upstream update/release paths cannot publish a Teaser build as Herdr. |

### Phase 3 — Client and task integration

- **GOAL-003**: Keep terminal-native interaction and add the native client.

| Task | Contract | Completion evidence |
| --- | --- | --- |
| TASK-020 | Adapt `runtime/herdr/src/client`, `src/ui`, and layout projection to shared organization. Depends on TASK-011. | TUI commands mutate shared IDs; client focus remains local; terminal cell geometry is isolated. |
| TASK-021 | Add typed server transport/projection under `app/macos/Teaser`; replace duplicate organization authority and retire obsolete attachment code. Depends on TASK-011. | App/TUI share state, disconnect is visible, and GUI-only providers degrade honestly in TUI. |
| TASK-022 | Implement shared task-provider interfaces and TaskRef associations in the server/core, with App/TUI projections. Depends on TASK-011. | A provider task selects the same existing context in both clients; errors/stale caches are explicit. |

### Phase 4 — Spatial integration

- **GOAL-004**: Deliver the real multi-application task-driven demo.

| Task | Contract | Completion evidence |
| --- | --- | --- |
| TASK-030 | Adapt `DesktopStageController` and presentation to multiple native-fullscreen canvases, unequal layouts/contours, exact adoption, local focus/undo, and recovery. Depends on TASK-021. | Existing native issue contracts pass without reverting to display-owned Workspace rectangles. |
| TASK-031 | Integrate task, terminal/agent, and real-app context across TUI/App. Depends on TASK-020, TASK-022, TASK-030, and namespace isolation before live use. | Demonstrable end-to-end flow; no mock provider UI or unrun acceptance claim. |

### Native integration implementation slice

This slice implements the dependencies of TASK-021 incrementally on the merged
fork. It does not complete the TUI projection, terminal rendering, distribution
isolation, task providers, or native fullscreen contracts. No existing endpoint
codec is changed. Native connection is explicit and never starts a server.

#### Task 1: Server-owned organization and JSON boundary

- Implement the pure organization model in `crates/teaser-core`: stable typed
  identifiers, project-scoped Workspaces, content-neutral Panels, qualified task
  references, bindings, and extensible size profiles. Placement and focus remain
  client-local; regroup and rebind are explicit operations.
- Add typed, atomic commands and revisioned snapshots. Reject unknown objects,
  invalid/duplicate IDs, invalid profiles, and stale revisions without changing
  state. Deleting a logical Panel does not terminate its provider session.
- Host the state in the existing Herdr server, using its persistence and JSON
  request/event infrastructure, not another process or native-side database.
  Expose `teaser.organization.snapshot` and `teaser.organization.apply`, with an
  expected revision on writes and full authoritative snapshots in responses and
  `teaser.organization.updated` events. Unknown/unsupported methods are explicit.
- Keep terminal runtime identity separate from Panel identity. A terminal binding
  refers to an existing Herdr pane; App and Notes Panels never create fake PTYs.
  Inherited Herdr tabs/workspaces remain terminal runtime structures during this
  slice, not a second writer of Teaser logical membership. Do not advertise the
  deferred TUI organization projection as implemented.
- Preserve frozen codecs and existing method semantics. Discover the new feature
  using its snapshot method; do not modify a capability struct reachable from a
  frozen binary codec just to advertise it. Restore old sessions with an empty
  organization extension; never infer durable identity from titles or paths.
- Add pure transition tests and focused server tests for revision conflicts,
  persistence, snapshot/event agreement, and invalid session bindings. All test
  data is temporary; no personal Herdr session, terminal, or desktop is touched.

#### Task 2: Native client and existing spatial presentation

- Add typed, bounded Unix-socket JSON transport and a shared-state client under
  `app/macos/Teaser/Herdr`, with explicit connect/disconnect/reconnect controls.
  Require an explicitly selected endpoint; no installed-Herdr discovery, launch,
  old-daemon fallback, or Accessibility request during connection.
- Subscribe before snapshot and reconcile snapshots/events by organization
  revision. Ignore stale replies, invalidate prior connection generations, bound
  event buffers/frame sizes/timeouts, and recover gaps by a fresh snapshot.
  Do not automatically replay uncertain mutations after a disconnect.
- Project server Workspaces and Panels into the existing native presentation
  using stable IDs. Reuse unequal tiling, local focus, Notes and exact-window
  adoption boundaries. Persist only local presentation preferences for this mode;
  membership, labels, kinds and bindings are accepted from the server.
- Route logical create/rename/regroup/rebind/delete actions through typed server
  commands. Keep pixel layout and live AX/CG leases local. Do not map a Herdr pane
  to an adopted external window or pretend pane metadata is a terminal renderer.
- Preserve first-class split gestures, including Ctrl-D and drag-edge splitting:
  create the new logical Panel through the server, then apply generation-scoped
  local placement/adoption intent only after an authoritative commit. Rejection,
  disconnect, or stale target invalidates the intent without replay.
- Show unsupported/disconnected/stale-command errors. Do not silently switch to
  a writable local organization model. Activating a stage or adopting a window
  requires a separate explicit user action.
- Add a no-desktop executable harness for the actual framing/client/projection
  boundaries and register it in SwiftPM and the existing pre-push gate. Retire old
  attachment code only where a real replacement exists; do not remove an
  unrelated terminal experiment merely to make the diff look complete.

The implementation reports partial coverage against P-613/P-621/P-623 rather
than marking their broader exit contracts complete. Full runtime/native builds
and the complete pre-push gate remain explicit user-run commands when long.

### Native canvas host slice

This slice implements the canvas host of TASK-030 (P-614) on the native
integration slice. It does not deliver contours, Workspace fragments across
canvases, focus routing, persistence/restore, or the multi-application demo.

#### Canvas lifecycle

- One app-wide `DesktopStageOrchestrator` keeps leases, the drag observer, and
  one lease per exact window. Each open CanvasWindow has a stable canvas ID and
  is one orchestrator display whose frame is the canvas content rectangle. A
  canvas can show several Workspaces; it is not a Workspace.
- File › New Canvas (⌘N), Close (⌘W) and Reopen Closed Canvas (⇧⌘T); View ›
  Enter Full Screen. Launch opens one blank canvas and requests native
  fullscreen; later canvases open windowed. Closing the last canvas keeps the
  app running, and reopening the app with none open creates a blank canvas.
  Only quit performs global release.
- Fullscreen is a per-canvas state (`windowed`, `entering`, `fullScreen`,
  `exiting`) driven by AppKit delegate callbacks. One app-wide gate admits a
  single native transition; other requests keep a pending target and start on a
  later run-loop turn. A failed or contrary callback ends in exactly one settled
  state. Geometry during a transition is ignored; the settled frame is applied
  once.
- Canvas windows opt into `[.managed, .fullScreenPrimary,
  .fullScreenDisallowsTiling]`. Windowed canvases stay transparent one level
  below normal; fullscreen canvases are opaque at normal level. Closing a
  fullscreen canvas exits fullscreen first and then closes the window; hiding a
  fullscreen window is not closing it. Every open creates a fresh window.
- macOS does not admit other applications' windows to a fullscreen Space
  (REQ-008). Adopted windows keep their leases and are re-solved on the desktop
  Space. A fullscreen canvas solves inside its frame clipped to the screen's
  visible frame, so drawn and applied frames agree. Teaser-owned Notes are views
  inside their canvas and therefore appear in fullscreen.

#### Placement and isolation

- Placement is client-owned and in memory: the session maps each Workspace to a
  canvas, places new Workspaces on the last key canvas, and projects only
  Workspaces on open canvases. Reconnect starts a new map; persistence and
  restore belong to P-563.
- Shared mode never runs display-topology rebalancing. Opening, moving,
  resizing, entering fullscreen or closing one canvas does not move another
  canvas's Workspaces, trees, ratios or windows.
- Closing a canvas releases only the leases of Panels placed on it, without
  aborting mid-release; failed restorations stay retained for that canvas. Its
  Workspaces are hidden, not deleted. Reopen Closed Canvas restores the same
  canvas ID with its layout trees for the rest of the session.
- A drop resolves the frontmost visible canvas on the active Space under the
  pointer first, then only that canvas's Panels. Overlapping or off-Space
  canvases never detach a dragged window.
- A focused Workspace fills only its own canvas; other canvases keep tiling.
- A Workspace occupies one canvas in this slice. Dropping a leased window on
  another canvas rebinds it there; Workspace fragments spanning canvases belong
  to P-561/P-511.
- Screen changes re-read canvas frames, never physical monitors, and Space
  changes never stop the stage. The unreachable desktop overlay is removed.

#### Evidence

- `TeaserCanvasLifecycleTests` covers transition serialization and failure,
  geometry gating, close during a transition, per-canvas release that leaves
  other canvases' leases intact, two-canvas projection and reopen, focus
  scoping, and drops across overlapping canvases. It shows no window, installs
  no global monitor and requests no Accessibility.
- Authorized native checks: green-button fullscreen at the backdrop level, two
  canvases fullscreen at once, Notes in a fullscreen canvas, New Canvas from a
  fullscreen Space, and adopted-window placement below the menu bar. Unrun
  checks are reported as unrun.

## 3. Alternatives

- **ALT-001**: Stock Herdr plus App/plugins cannot by itself implement the chosen
  changes to shared organization and TUI; keep APIs useful without limiting scope.
- **ALT-002**: Rebuild server/TUI independently duplicates inherited infrastructure.
- **ALT-003**: Replace published Git history or discard the native code loses work
  and disrupts existing sessions; preserve both histories through a subtree.

## 4. Dependencies

- **DEP-001**: Exact Herdr baseline and licenses in `runtime/upstream.toml`.
- **DEP-002**: Rust 1.96.1 and Zig 0.16.0 for the imported runtime build.
- **DEP-003**: Swift 6.2+, Xcode, and stable signing for native packaging.

## 5. Files

- **FILE-001**: `runtime/herdr`, root Cargo manifests/config, and provenance.
- **FILE-002**: `crates/teaser-core` and server protocol/persistence seams.
- **FILE-003**: Existing `app/macos`, `Package.swift`, and native harnesses.
- **FILE-004**: Canonical product/architecture/protocol docs and license notices.

## 6. Testing

- **TEST-001**: Check full ancestry, baseline subtree identity, lock provenance,
  workspace selection, native-source preservation, and document links.
- **TEST-002**: Run runtime fmt/Clippy/tests with the pinned tools; metadata/format
  checks using another installed toolchain are narrower evidence, not compilation.
- **TEST-003**: Test core transitions and two-client synchronization with isolated
  state and explicit terminal resize ownership; no desktop required.
- **TEST-004**: Run existing native headless harnesses plus new lifecycle cases;
  exercise real GUI input/adoption only in an explicitly authorized environment.
- **TEST-005**: Run the repository pre-push gate before integration; report
  missing tools, deferred long builds, and unrun scenarios rather than passing them.

## 7. Risks & Assumptions

- **RISK-001**: Organization changes can conflict with future upstream updates;
  keep them out of terminal parsing/rendering and preserve wire contracts.
- **RISK-002**: Imported runtime names/update endpoints still address Herdr;
  do not install or launch this baseline against personal sessions.
- **RISK-003**: Public macOS API cannot place another application's window on a
  fullscreen Space. Adopted windows stay on the desktop Space while their canvas
  is fullscreen; real-window coexistence still needs authorized native evidence.
- **ASSUMPTION-001**: Keep the current GitHub repository/address and published
  history; changing its fork-network membership needs a separate hosting action.

## 8. Related Specifications / Further Reading

- [Architecture](../docs/architecture.md)
- [Protocol](../docs/ipc.md)
- [Delivery outcomes](../ROADMAP.md)
- [Linear execution home](https://linear.app/acturea/project/teaser-efe303ae636d)
