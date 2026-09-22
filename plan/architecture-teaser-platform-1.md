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
- File › New Canvas (⌘N), New Canvas in New Space (⇧⌘N), Close (⌘W) and Reopen
  Closed Canvas (⇧⌘T); View › Enter Full Screen (⌃⌘F) and Fill Screen (⌃⌘↩);
  Window lists the canvases, and going to one orders its window front. Launch
  opens one blank canvas filling its screen rather than in macOS fullscreen: a
  fullscreen Space admits no adopted window, so the state a person lands in is
  the one that can hold their windows. Later canvases open windowed. Closing the
  last canvas keeps the app running, and reopening with none open creates a
  blank canvas. Only quit performs global release.
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
  (REQ-008), and no private interface changes this: window managers that disable
  SIP still leave fullscreen Spaces unmanaged. Native fullscreen therefore
  carries Teaser-owned content only. Adopted windows keep their leases and are
  re-solved on the desktop Space; a fullscreen canvas solves inside its frame
  clipped to the screen's visible frame, so drawn and applied frames agree.
  Teaser-owned Notes are views inside their canvas and appear in fullscreen.
- A canvas therefore also has a Fill Screen state: opaque, covering its screen,
  staying on its ordinary Space, where adopted windows tile above it with native
  rendering and input. It is presented as filling the screen, never as macOS
  fullscreen. Immersion comes from the opaque canvas plus the system settings
  that hide the menu bar and Dock, not from imitating a fullscreen Space.
- Canvases are Space-aware through public interfaces only. A canvas records the
  Space it was opened on, read from `com.apple.spaces` (`ManagedSpaceID`,
  `uuid`, desktop vs fullscreen type, and the current Space). Going to a canvas
  orders its window front, which makes macOS switch Spaces; a canvas that is not
  on the active Space says so instead of being silently re-solved into view.
  Opening a canvas on a new Space drives the Dock's own Accessibility Spaces bar
  to add a desktop and press it, and falls back to asking the person to add one
  when the Dock no longer exposes those controls.

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

### Canvas layout and Workspace contour slice

This slice implements the in-canvas half of TASK-030 (P-561) on the canvas host
slice. It does not deliver cross-launch persistence (P-563), real-window write
paths beyond existing adoption (P-511), shortcut routing (P-562), or the TUI
projection. The Rust core is unchanged.

#### One flat tree per canvas

- A Workspace owns no rectangle. Membership is `PanelDescriptor.workspaceID`,
  mirroring `Panel.workspace_id` in the shared core, and placement is whichever
  canvas tree holds the leaf. The display→Workspace→Panel nesting is gone, with
  `LayoutScope`, `DisplayWorkspaceLayout` and `PresentationLayout.workspaceFrames`.
  That separation is what lets one group span canvases and lets two of its
  Panels sit apart with another group's Panel between them.
- Each canvas owns one `LayoutTree<PanelID>`, nil while blank. A move changes
  placement only; membership changes through an explicit server command.
- A split nobody has dragged is sized from the summed growth weights of its two
  subtrees, so Panels follow their kinds instead of halving. A dragged divider
  records `SplitPreference.userRatio` and keeps it; a solve clamped by a minimum
  is never written back, so a proportion the canvas is currently too small to
  honour returns intact when the room does.
- Spacing carries the hierarchy: the narrow gutter inside one group, the wide
  one wherever a split's two subtrees are not the same single group. A subtree
  mixing groups always takes the wide gutter, and both the measuring and the
  placing pass read the same per-node gap.
- A Panel the canvas cannot give its minimum is still placed, and reported:
  `LayoutQuality.shortfalls` names it and the size it needs, and the canvas says
  so in its own status text. The solve never fails for it.

#### Group contours

- Contours are derived from the solved frames by a grid pass, not by cancelling
  rectangle edges: every rectangle contributes its coordinates to one snapped
  axis pair, so a tall Panel facing two shorter ones already has its edge split
  at their shared coordinate. Partial overlap, T-junctions and an edge that is
  interior on one half and boundary on the other are then the same rule.
- Adjacent members of one group produce one continuous loop; a locally
  disconnected group produces one loop per fragment, and a fragment on another
  canvas keeps the same colour and a group-wide ordinal. A ring around another
  group's Panel strokes the hole as well: the inner edge is as much the group's
  boundary as the outer one.
- Colour is FNV-1a over the Workspace ID, not a seeded hash, so it survives a
  relaunch and agrees between clients. The palette omits the arc around
  `systemBlue`, which the Virtual Focus ring and the drop highlight both use.
- A canvas showing a single group draws no contour and reserves no gutter for
  one. There is nothing to tell apart, and a lone window must not sit inside a
  border of wasted space.
- Contours are drawn and never hit-tested. No cursor rect or mouse path reads
  one, so a contour cannot intercept input meant for a provider window.

#### Focus, adoption and the unconnected canvas

- Focus is per canvas and has two stages. The first weights the group larger and
  raises it, leaving every other Panel framed and usable. The second gives the
  group the canvas and minimizes the other groups' adopted windows, which is all
  macOS offers: Accessibility has raise and minimize and no lower. A third press
  restores. Only windows Teaser minimized are restored, and a window that
  refuses to minimize is reported without aborting the transition.
- Focus prunes the solve, never the stored tree. Every split ID and every
  `userRatio` survives untouched, which is what makes clearing focus restore the
  canvas exactly. A canvas can only focus a group it already holds, so focus
  never recalls a member placed elsewhere.
- An open canvas is the consent to run: there is no separate Start step and no
  connection gate. Activation never prompts — an unauthorized app stays inactive
  and says so. An explicit Stop is remembered until an explicit Start.
- A canvas with no authoritative projection behind it seeds one empty Panel, so
  it has something to drag a window into and to split. Server ownership is
  decided by a projection having arrived, never by a session object existing.
- Control-Option-A adopts the frontmost window into the focused Panel without a
  drag. A drag asks macOS to recognise a window-move gesture, which Stage
  Manager breaks by scaling and animating the window it moves.
- The Layout Editor window is removed: the canvas resizes by dragging its own
  dividers, so a second window editing a thumbnail of it was a duplicate entry
  point. Its SplitView dependency is removed with it.

#### Evidence

- `TeaserLayoutTests` covers contour geometry (adjacent pair, L shape, partial
  overlap, an edge half interior and half boundary, a ring with a hole, a
  diagonal touch, disconnected fragments, determinism, degenerate frames), the
  palette's distance from the focus blue and the stability of its hash, growth
  weighted ratios and user-ratio survival including a clamped solve, the gap
  hierarchy and the gutter rule, shortfall reporting, and both focus stages.
- `TeaserCanvasLifecycleTests` covers Mission Control's own Space naming — a
  fullscreen Space taking no desktop number, per-monitor numbering, the live
  record beating a stale copy, and a Space the bar no longer describes — and
  seeing a canvas establishing which Space it is on without touching its frame
  or phase. It also covers per-canvas isolation on the flat model,
  the unconnected seed, seeding stopping once a projection owns the
  presentation, and the adjacency preference together with its refusal to tidy a
  scattered layout.
- `TeaserWindowAdoptionTests` covers activation against a substituted
  Accessibility service without prompting, the explicit Stop surviving, the two
  focus stages against fake leases, restoring only what Teaser minimized, a
  refused minimize, and the split axis.
- Authorized native checks, all unrun: a contour visible under a real adopted
  window; a click near a gutter never intercepted; fluorescence legible over
  light and dark wallpapers in both appearances; the frosted backdrop; adoption
  by Control-Option-A against a real provider; and the full pre-push gate.

### Canvas accessibility tree slice

This slice implements the readable half of TASK-030 (P-698) on the contour
slice. It publishes the canvas's own accessibility tree; it does not deliver
remappable shortcuts, Reduce Motion / Reduce Transparency responses, a contrast
audit of the fluorescent palette, or reading a canvas that is on another Space.
No Rust, no wire format and no organization state changes.

#### One element per placed Panel

- The canvas view is an `AXGroup` under its window, and each Panel with a
  solved frame is an `AXGroup` under the canvas. `AXTitle` is the title the
  canvas draws, provider prefix included, so what is shown and what is spoken
  are one string. `AXDescription` names the group, numbers the fragment when
  the group has more than one, where the group continues, and says what the
  Panel is bound to. `AXValue` carries the Workspace's own identity and
  `AXIdentifier` the Panel's, so an automated read partitions Panels into
  groups and addresses one without matching on display text a person or a
  provider is free to change. `AXHelp` carries an unsatisfied minimum size.
- Group identity stops being a colour and nothing else. The contour's ten hues
  are spaced for normal colour vision, which is not everyone's, and a hue is
  inaudible to all of them; the element says "Alpha" where the contour only
  showed a shade. The fragment ordinal is group-wide, so a group split across
  canvases reads 1 of 2 here and 2 of 2 there. A group in one piece is not
  numbered 1 of 1, and a canvas showing one group still names it: suppressing
  the contour is a drawing rule, not a naming rule.
- A fragment ordinal on its own is a dangling reference, so a group that
  continues elsewhere names the canvas it continues on and the Space that
  canvas is on, the way Mission Control names it: "Desktop 2", or the Space's
  own ID when the Spaces bar no longer describes it, or "another Space" when
  nothing ever established which. That can only be said from here: a canvas on
  another Space publishes no window at all, so it cannot say so about itself,
  and the canvas that can see it is the one that must. A canvas whose placement
  is unknown is left unsaid rather than guessed at, and fragments of one group
  on this same canvas send nobody anywhere.
- Desktops are numbered per monitor and count only desktops, because a
  fullscreen Space shows its application's name in the bar and takes no desktop
  number. The live record decides: a Space keeps its ID while becoming or
  ceasing to be fullscreen, so a caller's stale copy must not name it.
- macOS publishes no way to ask which Space a window is on, so a canvas is
  stamped with the Space that is current whenever it is visible during a Space
  switch. That is identity only — no frame, no phase, no transition — and a
  canvas nobody has seen since it moved keeps the Space it was last seen on.
- A Workspace title is a label the person chose and nothing in the core stops
  two Workspaces carrying one. When two do, the spoken name is qualified with
  the identity that cannot collide; when the label is already unambiguous it is
  not cluttered with one. The identity is published either way, because
  partitioning Panels into groups must not depend on display text.
- Binding state is read from the live lease and from `nativeContent`, never
  from geometry: a provider hint the server holds is not an adopted window.
  A Panel below its minimum names the deficit on each axis that is actually
  short, because `LayoutQuality` records a shortfall when either one is, and a
  deficit under a point says so rather than rounding to "0 pt short". The
  minimum named is the Panel's own: an adopted window that refuses to shrink
  writes its size onto that Panel, so it is not a fact about the kind.
- `AXFocused` is Virtual Focus, which is one Panel for the whole presentation,
  so at most one element in the whole tree reports it. Only `.layoutChanged` is
  posted. `.focusedUIElementChanged` never is: announcing a layout selection as
  the application's focused element would pull a reader's cursor into a window
  that does not hold the keyboard, which is the implicit redirect REQ-014
  forbids.
- The canvas element reports how many Panels it holds, in how many Workspaces,
  and which focus stage it is in. It says Workspace rather than group, because
  the menu bar already does and a person hearing both must not have to work out
  that they are the same thing. Counts describe the published tree: an exclusive
  focus prunes the others out of the solve, and claiming a group nothing in the
  tree can be read about would be a second lie about the same canvas.
- Everything derives from `WorkspacePresentation` plus `PresentationLayout` in
  the same step that builds the drawn snapshot, so the tree cannot disagree
  with the pixels and there is no second store. Elements are cached per Panel
  and mutated in place — handing a reader a new object on every solve would
  drop its cursor out of the canvas whenever a divider moved — and an unchanged
  projection is not republished, because the snapshot is rebuilt several times
  per drag frame.
- Publishing a tree is the server half of accessibility and needs no
  permission. It is the opposite of adopting a provider window, which reads
  another application's elements and does require the Accessibility service.
  SEC-003 still holds unchanged: nothing here prompts, and no harness does.
- Elements are informational, and `accessibilityHitTest(_:)` is left to AppKit.
  A Panel's element must not become a third thing that can stand between a
  pointer and a provider's window, any more than a contour may.

#### Known boundaries

- Teaser-owned Notes content keeps publishing its own editable subtree beside
  the canvas element rather than inside its Panel's group. The Panel's group
  still says the Panel is bound to Notes; nesting a live view under a published
  element would give it two parents.
- A canvas that is not on the active Space reports no window at all through
  Accessibility, so nothing under it can be read either. This slice delivers
  "present but not frontmost". What it adds across Spaces is a pointer, not a
  reading: a readable canvas names the off-Space canvas its group continues on,
  so the rest of the group is reachable rather than merely implied. Reading
  that canvas's own Panels still means going to its Space.

#### Evidence

- `TeaserCanvasAccessibilityTests` covers the group name and its identifier
  fallback, fragment numbering across two canvases, a single-group canvas that
  draws no contour and still names its group, the three binding states and a
  provider hint that is not a lease, Virtual Focus marking exactly one element,
  canvas-relative frames inside the canvas, the canvas summary for a blank
  canvas and for both focus stages, the shortfall sentence on one axis, on both,
  and under a point, one published `AXGroup` per Panel with its role,
  identifier, title, label, value, help, focus, parent and frame, two
  Workspaces sharing a title, where a split group continues including the named
  Space and the unnameable, unknown and same-canvas cases, element identity
  surviving a solve and leaving with its Panel, and an unchanged projection not
  being republished. It shows no window, installs no
  monitor and requests no Accessibility.
- Authorized native checks, all unrun: a real VoiceOver pass naming each
  Panel's group on a live canvas; the same tree read without a screenshot while
  the canvas is on the active Space but not frontmost; and the full pre-push
  gate.

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
