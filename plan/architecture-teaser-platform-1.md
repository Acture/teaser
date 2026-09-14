---
goal: Build the first supportable macOS Teaser platform from the current architecture baseline
version: 1.0
date_created: 2026-07-21
last_updated: 2026-09-04
owner: Acture
status: 'In Progress'
tags: [architecture, terminal, macos, rust, swift, agents]
---

# Introduction

![Status: In Progress](https://img.shields.io/badge/status-In%20Progress-yellow)

This plan builds Teaser's foundation prototype into a macOS spatial development
environment. It implements risk spikes first, then parallel project Workspaces,
the provider-owned window desktop stage, structured terminal detail, ACP agents,
persistent/remote sessions, and release hardening. Every phase has an explicit stop
condition; no phase may compensate for a failed terminal foundation by adding a
second renderer.

## 1. Requirements & Constraints

- **REQ-001**: Render and accept input through the full Ghostty embedding surface; do not implement a second VT renderer.
- **REQ-002**: Keep raw PTY output, keystrokes, pointer events, IME composition, and render callbacks outside UniFFI, JSON, and SQLite paths.
- **REQ-003**: Use a two-level per-display slicing layout so each Workspace is one connected rectangle and its unequal Panels fill that rectangle; support parallel presentation, focus, and complete-Workspace switching without losing tree identity, running content, or requested split ratios.
- **REQ-004**: Preserve unsupported CLI/TUI behavior through an ordinary PTY with no required Teaser adapter.
- **REQ-005**: Produce shell blocks from OSC 133/OSC 7 and agent blocks from ACP while storing bounded completed payloads in SQLite.
- **REQ-006**: Support `teaser agent claude` and `teaser agent codex` without shadowing or modifying the vendor `claude` and `codex` commands.
- **REQ-007**: Support local tmux control mode, system SSH, SSH-carried tmux control mode, and capability-degraded opaque Mosh sessions.
- **REQ-008**: Let the user drag any eligible current-Space application window into a Panel and manage its geometry through public Accessibility APIs; never reparent, capture, or synthesize input for it.
- **REQ-009**: Default search to the virtually focused Panel and require a distinct action for current-Workspace search.
- **REQ-010**: Ship v1 without a dynamic plugin loader, public surface SDK, stable internal ABI, or third-party extension promise.
- **REQ-011**: Preserve native Claude/Codex CLI mode in TerminalSurface because ACP adapters may expose fewer capabilities than the vendor CLIs.
- **REQ-012**: Restore a command for rerun into an editable input area and require user confirmation; never auto-execute historical commands.
- **REQ-013**: Keep Panel identity content-neutral and distinct from kind, binding, and Surface identity so an empty Panel can bind either Teaser-owned content or one exact provider-owned external window without requiring a Session.
- **REQ-014**: Keep Teaser's `VirtualFocus` for layout commands independent from macOS `InputFocus`; transfer keyboard focus only after an explicit user action.
- **REQ-015**: Define Task, CLI, App, Agent, File, and Notes as data-driven layout profiles with per-Panel overrides and user-defined kinds, not application-specific Swift subclasses.
- **SEC-001**: Create the control socket at `~/Library/Application Support/Teaser/runtime/control.sock` with mode `0600` inside a user-only directory.
- **SEC-002**: Treat PTY output, OSC payloads, ACP `_meta`, file paths, and tmux control messages as untrusted input and bound every decoded frame or stored payload.
- **SEC-003**: Request Accessibility access only when external-window management is invoked; after the one system decision, use the physical drag as explicit window selection and continue without adoption when permission is denied.
- **SEC-004**: Create workspace databases with user-only permissions and expose retention duration, capacity, disable-history, and clear-history controls.
- **CON-001**: Target Apple Silicon macOS first and distribute outside the Mac App Store sandbox.
- **CON-002**: Pin Ghostty `v1.3.1` commit `332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28`; never follow `main` implicitly.
- **CON-003**: Write Teaser application logic in typed Rust and Swift; restrict Zig changes to the Ghostty embedding boundary.
- **CON-004**: Use tabs in new project-owned source where the language formatter permits; otherwise follow rustfmt and Swift format conventions.
- **CON-005**: Use AGPL-3.0-or-later for Teaser and preserve every bundled dependency notice.
- **CON-006**: Do not claim arbitrary block folding/reordering, external-window embedding, cross-Space movement, or direct PTY survival across `teaserd` termination in v1.
- **CON-007**: Treat tmux text recovered after a control disconnect as semantic-degraded when OSC 133 lifecycle or exit status was missed.
- **CON-008**: Treat Mosh roaming as valid only while its owning `teaserd` direct PTY remains alive; daemon restart does not restore that Mosh process.
- **GUD-001**: Use closed enums for built-in Panel content, data values for extensible Panel kinds, and traits only for seams with multiple implementations, including `SessionBackend` and `AgentBackend`.
- **GUD-002**: Log lifecycle transitions, reconnects, adapter failures, and expensive operations at INFO; do not log raw prompts, PTY contents, or credentials by default.
- **GUD-003**: Display progress and elapsed time for dependency builds, packaging, and benchmark suites that exceed five seconds.
- **GUD-004**: Run `cargo fmt`, `cargo clippy --all-targets --all-features`, Swift compiler checks, and project tests before completing each implementation phase.
- **PAT-001**: Rust owns persistent Project, Workspace, Panel, and Teaser content-binding state; Swift owns live AppKit geometry, overlays, external-window leases, focus handoff, and view lifetime; messages crossing the boundary are immutable typed values.
- **PAT-002**: Model missing integration as an explicit `CapabilitySet`, not as guessed behavior or silent fallback.
- **PAT-003**: Supervise ACP adapters, tmux, SSH, and bridge processes with bounded restart and deterministic terminal states.
- **PAT-004**: Persist external provider hints but never persist or reconstruct AX references; after either process restarts, require the user to drag the window again.

## 2. Implementation Steps

### Implementation Phase 0 — Foundation and feasibility gates

- **GOAL-001**: Prove the Ghostty, Swift/Rust, semantic-block, ACP, tmux, and Accessibility boundaries before product implementation.

| Task | Description | Completed | Date |
|------|-------------|-----------|------|
| TASK-001 | Create a Cargo workspace in `Cargo.toml` containing `crates/teaser-core`, `crates/teaser-cli`, `crates/teaser-bridge`, `crates/teaser-acp`, and `crates/teaser-tmux`; create the Swift macOS app under `app/macos` with bundle identifier `com.acture.teaser`; define Swift build targets in `Package.swift` and quality gates in `.pre-commit-config.yaml`. | | |
| TASK-002 | Register Ghostty as a clean Git submodule under `vendor/ghostty`, pinned to CON-002; keep Teaser deltas in parent-owned patches; document provenance, verification, and explicit updates in `vendor/README.md`; copy required MIT notices into `THIRD_PARTY_NOTICES.md`. | Yes | 2026-07-23 |
| TASK-003 | Implement `TerminalSurfaceAdapter` in `app/macos/Teaser/Terminal/TerminalSurfaceAdapter.swift`; host one Ghostty surface in an `NSView` and attach it to a `teaserd`-owned Session without creating a second PTY; verify clean-clone resources, binary flow control, app tick/wakeup, main-thread and lifetime behavior, resize, focus, selection, clipboard, English input, Chinese IME, process exit, 120 Hz, and a signed development bundle. | | |
| TASK-004 | Add `benchmarks/terminal` with reproducible direct-Ghostty and Teaser harnesses using the same Ghostty revision, config, hardware, workload, and display rate; measure p50/p95 input-to-present, sustained output, CPU, memory, and dropped frames; record the methodology and initial 10% direct-terminal target before v0.1. | | |
| TASK-005 | Extend only the Ghostty embedding/query boundary to expose semantic-zone begin/update/end/evict callbacks, opaque range handles, and plain-text range reads; add C/Zig tests proving OSC 133 prompt/input/output classification survives wrapping and resize. Stop the plan if terminal-model, reflow, or renderer redesign is required. | | |
| TASK-006 | Implement the UniFFI boundary in `crates/teaser-core/src/ffi.rs` and `app/macos/Teaser/Core/TeaserCoreBridge.swift` with `TeaserCore`, `WorkspaceSnapshot`, `CoreAction`, and `CoreEvent`; add a guard test that no terminal byte-buffer type is exported. | | |
| TASK-007 | In `crates/teaser-acp/tests/smoke.rs`, start pinned Claude and Codex ACP adapters, negotiate `protocolVersion` and capabilities, initialize one session, submit one prompt, collect updates, and terminate cleanly; compare advertised features with native CLI mode and record exact adapter revisions/notices. | | |
| TASK-008 | In `crates/teaser-tmux`, parse one local tmux control session and connect one pane through `crates/teaser-bridge` to the same `teaserd` Session data plane used by a TerminalSurface; test arbitrary bytes, Unicode, IME-produced input, bracketed paste, mouse protocol, resize, `%pause/%continue`, `capture-pane` repair, malformed messages, and flow control; record the initial 20% bridge target. | | |
| TASK-009 | Implement the `ManagedExternalWindow` foundation in `app/macos/Teaser/ExternalWindows`; prove exact AX/Core Graphics identity, current-Space validation, move/resize observation, transactional frame application, and best-effort same-window restoration. Zed may be the fixture, but title, path, and application-specific lookup are not the product interaction. | | |

CP-M0.6 now proves a real daemon-owned PTY, exclusive attachment leases, bounded
binary frames, monotonic replay offsets, replay-gap reporting, detach/reattach with
one unchanged child PID, and resize. It deliberately leaves PTY creation out of the
foreground daemon until Checkout resolution exists. CP-M0.7 additionally verifies
the initial child as its session and process-group leader and reaps a stubborn
same-PGID descendant after both explicit termination and natural leader exit. It
uses non-reaping exit observation to preserve PGID identity through cleanup, but
does not cover job-control processes moved into other PGIDs. Before TASK-003 starts
a user shell, replace or isolate the checkpoint `portable-pty` multithreaded
`pre_exec` path and provide cross-PGID session cleanup.

CP-M0.8 adds a parent-owned Ghostty external-I/O patch: the full surface can select
a backend with no `Exec`, PTY, or child state; host output enters through the C ABI;
and encoded input plus resize return through callbacks. Focused tests, exact ABI
checks, a native Apple Silicon XCFramework build/link, and
`app/macos/TeaserProbe` pass. The probe covers IOSurface-backed Metal draw plumbing,
readback, exact input ordering, resize consistency, direct-child snapshots, and
ordered teardown. It checks a live IOSurface draw target, not captured pixels.
Source-level tests prove the backend contains no process or PTY state; the runtime
snapshot is corroborating rather than exhaustive. CP-M0.8 is closed, but TASK-003
remains open for the clean-clone host, bundled resources, IME, clipboard,
selection, 120 Hz, and signed-app gates.

CP-M0.9 connects a fixed daemon-owned PTY fixture to the native Ghostty surface
through the production-shaped `teaser.attach.v1` binary stream. The probe proves
exclusive attachment, output/input/resize forwarding, detach with a live child,
offline replay, same-PID reattachment, Metal draw plumbing, full-screen readback,
and ordered exit/teardown. It deliberately creates the fixed child before
threaded IPC accept begins and exposes no configurable program or cwd. It does
not close the interactive-shell spawn, cross-PGID cleanup, clean-clone bundle,
IME, clipboard, selection, 120 Hz, or production asynchronous input-pump
portions of TASK-003.

CP-M0.10 replaces the synchronous Swift bridge with a bounded asynchronous
attachment pump while leaving `teaser.attach.v1` unchanged. Ghostty callbacks
only copy and enqueue. A dedicated reader feeds ordered output, and a dedicated
writer preserves input/resize order behind 1 MiB input and 4,096-event limits.
Overflow rejects the complete payload and reports uncertain input delivery.
The pump reconnects under one five-second monotonic deadline from the last
output offset committed after Surface feed, never retransmits old input, and
resumes output with input paused until a recovery-ID-bound confirmation. Replay
gaps terminate the current Surface as desynchronized. Detach drains for at most
five seconds, and teardown joins socket workers after all Surface feeds
quiesce. Fake-transport tests cover ordering, pressure, reconnect, gap, drain,
and blocked-worker teardown; the native probe covers automatic offline
recovery, same-PID continuity, explicit input resume, resize, exit, and ordered
Surface teardown.
TASK-003 remains open for the clean-clone host, bundled resources, IME,
clipboard, selection, 120 Hz, signed bundle, and production Session creation.

### Implementation Phase 1 — Parallel project Workspaces

- **GOAL-002**: Deliver a real-window desktop stage in which multiple connected project Workspaces remain tiled in parallel, focus, or switch as units while retaining unequal Panel layouts and live content.

| Task | Description | Completed | Date |
|------|-------------|-----------|------|
| TASK-010 | Implement immutable `WorkspacePresentation`, `DisplayWorkspaceLayout`, `WorkspaceDescriptor`, `PanelDescriptor`, generic `LayoutTree`, `PanelKindDefinition`, `LayoutProfile`, `PanelBinding`, `LayoutAxis`, `VirtualFocusState`, and stable ID values. Add deterministic constrained-layout reducers for split, close, move, resize, tile, focus, switch, display-affinity changes, and optimization; prove exact fill, non-overlap, connected Workspaces, feasible minimum sizes, unequal ratios, and round trips. | | |
| TASK-011 | Implement `DesktopStageCoordinator`, Teaser-owned Panel windows, click-through arrangement overlays, action routing, and `InputFocusBridge` under `app/macos/Teaser`; use `Ctrl-Option-D` to split the virtually focused Panel, move Virtual Focus without activation, and require click/double-click/Enter for Input Focus. Replace fixture-rendered third-party interfaces with a six-Workspace unequal showcase using real IDE, task, terminal/agent, file, and browser windows plus Teaser-owned persistent Notes. | | |
| TASK-012 | Implement schema-versioned Workspace persistence with user-only permissions. Store display affinity, Workspace/Panel trees, requested ratios, Virtual Focus, kinds and overrides, Notes, Project/Checkout bindings, Teaser content descriptors, and backend restoration state. During the Swift-only desktop-stage slice, one atomic typed snapshot under `~/Library/Application Support/Teaser` owns this state; cut directly to the Rust Workspace store when TASK-006 lands, with no dual write. Persist only hints for external providers and require re-drag after restart. Reattach a direct PTY only while its exact owning `teaserd` Session remains live. | | |
| TASK-013 | Implement `HistoryPolicy` with maximum database bytes, retention duration, persistence enabled/disabled, clear-on-exit, and explicit clear-now action; enforce bounds transactionally and expose the controls in native settings. | | |
| TASK-014 | Implement `ImageViewController` as optional Teaser-owned Panel content under `app/macos/Teaser/Images` using `QLPreviewView` with Image I/O metadata fallback; route `teaser open <PATH>` to image preview for supported media and to a terminal editor command for text. The showcase may instead adopt a real Preview window as a File Panel. | | |
| TASK-015 | Promote the AX spike into generic drag-to-adopt window orchestration. Correlate global mouse movement with one exact standard, movable, resizable current-Space window; expose targets only during a qualified drag; adopt an empty target, edge-split an occupied target, move an existing lease, or detach outside the layout. Apply every layout atomically with frame readback, compensation rollback, single-step Undo, close/move observation, explicit focus handoff, and safe same-window release. Fail closed on ambiguity or permission denial and never locate by title, path, or provider-specific polling. | | |
| TASK-016 | Implement the versioned CLI protocol in `crates/teaser-core/src/ipc` and `crates/teaser-cli`; support `teaser`, `teaser shell [--cwd PATH]`, and `teaser open <PATH>`; validate paths, socket ownership, stale sockets, bounded app-launch retry, and structured errors. | | |

The adoption chain has one replaceable boundary and one business entry point.
`DesktopStageOrchestrator` owns drag handling, drop targets, leases, layout
transactions, and Undo, and creates no AppKit window; `DesktopStageController`
supplies the real chrome, displays, and persistence. `ExternalWindowService`,
`ExternalWindowLease`, `ExternalWindowHandle`, `ExternalWindowPointerSource`, and
`ExternalWindowClock` are the only substitution points, and `AXUIElement` values
stay inside the Accessibility implementation: a substituted handle is rejected
there rather than adapted, so PID, `CGWindowID`, and AX identity checks are
unchanged. TEST-012 therefore proves the boundary and the orchestration only.
Real drag acceptance and real provider adoption remain unverified and still
require a signed bundle with granted Accessibility.

#### Adoption regression matrix

The first batch of TEST-012 lives in `app/macos/TeaserWindowAdoptionTests` and
runs with `swift run TeaserWindowAdoptionTests`, also included in the pre-push
hooks. `Fixtures.swift` holds the substituted world and the `PointerDriver`
both harnesses compose, `AdoptionTests.swift` drives
`DesktopStageOrchestrator`, and `DragObserverTests.swift` drives
`WindowDragObserver` directly, because a duplicated `began` or a missing `ended`
is not observable in orchestration state alone. One ordered operation log
records pointer, lease, and host calls together, so ordering claims are
assertions about a sequence rather than about counters that happen to agree.

The substituted boundary mirrors the Accessibility implementation rather than
being merely convenient: post-selection reads fail as an unavailable window
rather than as a permission error, a handle holds the fixture object the way
production holds an `AXUIElement`, binding re-checks permission, current Space,
and manageability, writes require the current Space, and a release that cannot
validate its window returns failure and keeps the lease. A test that passes
because the substitute was lenient is not evidence about the product.

Covered contracts, each naming the regressions that defend it:

- **Drag in — the right Panel highlights, that exact window binds, and the
  placement reads back.** Qualified drag adopts an empty Panel; highlight
  follows the pointer across Panels; button-state samples drive the same chain;
  sampler alone keeps the highlight following the pointer; split Panel
  describes the window that created it.
- **A content drag never adopts.** Content drag never adopts; resize drag never
  adopts; correlated resize is not a drag; window moved without the pointer
  never adopts; divergent pointer and window motion never adopts;
  sub-threshold nudge is not a drag; unqualified drag is never announced.
- **Interleaved deliveries, duplicate notifications, missing drag or up.**
  Duplicate press does not restart the drag; duplicate release ends the drag
  once; monitored and sampled deliveries interleave into one drag; missing drag
  deliveries still complete the drop; missing release is closed by button
  sampling; release inside the sampling interval still drops; stale button
  sample after the drop does not readopt; cancelled drag stays disarmed while
  the button is held; restarted stage observes the next drag; time advancement
  gates resampling.
- **Empty Panel, occupied center, edge split, managed move and swap, drag
  out.** Qualified drag adopts an empty Panel; occupied center rejects an
  unmanaged window; every occupied edge highlights its own split; edge and
  center boundary is where the hit test says it is; edge drop splits and
  adopts; top-edge drop splits on the other axis; managed window moves to an
  empty Panel without rebinding; managed windows swap on an occupied center;
  managed window dropped on its own Panel returns; managed window split onto
  another edge frees its old Panel; content Panel is never offered as a swap;
  content Panel is occupied for an unmanaged window; window moved across
  Workspaces follows its focus; drops move Virtual Focus to where the window
  landed; drop outside every Panel detaches without restoring; detached window
  is readopted without rebinding; undo releases the adopted window.
- **Window closed, identity lost, permission lost, wrong Space,
  unmanageable.** Window lost during drag cancels and diagnoses; substitute
  window at the same point is never adopted; permission lost during drag stops
  adoption; window off the current Space at release is not adopted; closed
  provider window frees its Panel; unmanageable windows are never adopted;
  cancelled drag ignores its late release; rejected candidate is diagnosed once
  the drag is real; rejection is not reported after its press ended; denied
  permission never observes or prompts.
- **Write failure, readback mismatch, partial success, failed compensation.**
  Window that refuses to move rolls back and reports; frame readback mismatch
  refuses the adoption; failed split leaves no half-created Panel; partial
  multi-window apply rolls back in reverse order; compensation continues past a
  window that refuses restoration; failed compensation reports both errors and
  keeps leases; unrestorable window retains its lease; undo that cannot release
  reports and retains its lease.
- **Stop, shutdown, and what the user does afterwards.** Stopping the stage
  restores adopted windows; stopping mid-drag cancels without adopting;
  stopping the observer cancels an in-flight drag; stopping leaves a detached
  window where the user put it; user-moved window is not snapped back on stop;
  stopped stage never moves the window again; shutdown releases every lease and
  observer; input handoff prefers the adopted window; default run touches no
  desktop state; no window is ever displayed.

Run evidence, 2026-09-10: `Teaser window-adoption regression passed: 66 cases
(no desktop, no monitors, no prompts)`, plus `Teaser layout tests passed` and a
green full gate before the SwiftPM migration. Every mutation below was applied,
run, and reverted; none is committed:

- `handleDragEvent` stops updating `dropHighlight` — caught by 16 of 66,
  starting at qualified drag adopts an empty Panel.
- `applySynchronously` rolls back to each lease's current frame instead of its
  pre-apply snapshot — partial multi-window apply rolls back in reverse order;
  failed compensation reports both errors and keeps leases; compensation
  continues past a window that refuses restoration.
- Rollback breaks at the first window that refuses restoration — compensation
  continues past a window that refuses restoration.
- The center-drop decision is re-derived at the highlight instead of shared —
  managed window dropped on its own Panel returns.
- A Teaser-content Panel is offered as a swap again — content Panel is never
  offered as a swap.
- A retired press keeps reporting its rejection — caught by 22 of 66, because
  the press value also gates the next press.
- The `.dragged` branch reports a rejection without checking the press is live
  — rejected candidate is diagnosed once the drag is real.
- `stopStage` closes Teaser chrome after provider leases release —
  stopping the stage restores adopted windows.
- `stopStage` restores every window, detached ones included — stopping
  leaves a detached window where the user put it.
- `LayoutEdge.insertsBeforeTarget` reverted to `.leading || .top` — top-edge
  drop splits on the other axis, plus the layout edge-geometry assertions.
- The split branch never vacates the Panel a managed window left — managed
  window split onto another edge frees its old Panel.
- Drops no longer move Virtual Focus — drops move Virtual Focus to where the
  window landed; window moved across Workspaces follows its focus.
- The sampler stops synthesizing movement while the button is held — sampler
  alone keeps the highlight following the pointer.
- `endPendingDrag` no longer resets the sampling throttle — release inside the
  sampling interval still drops.
- Drag qualification movement floors dropped to 1 pt — sub-threshold nudge is
  not a drag; release inside the sampling interval still drops.
- The drag-qualification size guard disabled — correlated resize is not a
  drag.
- `stop()` no longer clears the press state — restarted stage observes the
  next drag.
- A split Panel no longer describes the window that created it — split Panel
  describes the window that created it.
- The drop hit test's edge band widened to 400 pt — edge and center
  boundary is where the hit test says it is.

SwiftPM migration revalidation, 2026-09-10: the pre-push hooks passed all eight
Swift harnesses, including the same 66 adoption cases and 24 attachment-pump
cases, all Rust workspace tests, formatting, Clippy, patch applicability, and
the app bundle build. `Package.swift` replaces the repeated compiler source
lists with one `TeaserKit` module. The generated build commands carry Swift 6
language mode and warnings-as-errors for the library and all eight harnesses.
The full command is `pre-commit run --all-files --hook-stage pre-push`.

Two temporary fault probes verified the new hook wiring, then were restored:

- Change the first Ghostty patch's trailing context from
  `Terminal: semantic prompt continuations` to a nonexistent test name. Running
  `pre-commit run ghostty-patches-apply --files vendor/ghostty` exits 1 with
  `patch does not apply`, proving that a gitlink-only trigger checks the patches.
- Append a synthetic failure before the adoption runner's final guard. The
  `swift-test-window-adoption` pre-push hook, invoked with `--files` naming the
  edited runner, recompiles it and exits 1 with the injected diagnostic. The
  hook invokes `swift run` so even a standalone run builds the current sources.

Four defects this matrix found are fixed here, and their reverted forms are
mutations above.

`ConstrainedLayoutSolver` lays a split's first child at the lower coordinate on
its axis and layout frames are AppKit screen frames, so a `.top` edge insertion
placed the new Panel in the lower half while the drop highlight promised the
upper half; the same inversion sent a `Ctrl-Option-D` split of a tall Panel to
the wrong half. `LayoutEdge.insertsBeforeTarget` now reads `.leading ||
.bottom`, and TEST-001 asserts both the tree order and the solved geometry of
all four edges.

A drop on a Panel's center had its outcome derived twice: once for the
highlight label and once in `acceptDrop`. The two disagreed for a Panel holding
Teaser-owned content, which has no window to trade, and again for a window
dropped on its own Panel. Both now read one `centerDrop` derivation, so the
label cannot promise what the drop will refuse.

A press that selected no eligible window kept its rejection after the button
came up, so a later unrelated movement reported it over whatever the user had
done since — including over a completed adoption. Press location and rejection
are now one value whose lifetime is the press.

Library integration evidence, 2026-09-14 (P-595): the adoption harness passes
72 cases, including SplitView-driven provider apply/Undo, rejected and invalid
fractions, vertical orientation, display-level Workspace resize, offline editing,
and failed-release/stale-gesture safety. The controls harness additionally checks
scoped subscriptions, cancellation, stale callbacks, restart, and owner teardown
through a fake shortcut source; it never registers system hotkeys. The full
pre-push gate passes with the pinned Swift dependencies.

The signed app was copied to a fresh temporary directory, passed
`codesign --verify --strict`, and printed `KeyboardShortcuts resources: Space`
through `--check-bundle-resources` with resource override environment variables
unset. That branch exits before creating `NSApplication`. This proves packaged
resource lookup, not interactive shortcut delivery or visual acceptance.

The separate Swindler compile probe passes with its pinned upstream revision,
including the internal Window-to-AX-element bridge. Reproduce it without
initializing window services:

```fish
swift build --package-path probes/swindler-compatibility \
    --scratch-path target/library-probes/swindler-compatibility/.build \
    --product SwindlerProbe --force-resolved-versions
```

Its test-only import is not a production adapter. Lifecycle and asynchronous
write/release integration remain open under P-511; see `docs/architecture.md`
section 4.3. Real Zed dragging, native keyboard delivery/conflicts, and visible
editor interaction remain unverified by this headless run.

The default P-511 showcase uses actual provider windows and six unequal Workspace
regions. Missing providers leave empty hinted Panels; they are never replaced by a
fixture-rendered copy.

| Workspace | Panel bindings |
|---|---|
| Teaser | Zed App, Linear Task, Ghostty Codex Agent |
| Research | Notion Task, Teaser-owned Notes |
| Foch | Warp Claude Agent |
| Ark Solver | Terminal.app SSH CLI |
| Paper | Preview File |
| Sort & Pour | Chrome App |

On a 2560×1440 visible frame, the default WorkspaceTree gives the left branch 62%
and the right 38%. Teaser and Research split the left branch 65/35; Foch, Ark
Solver, and the Paper/Sort branch receive 40/21/39% of the right branch. Teaser's
three-Panel tree is intentionally asymmetric. The solver clamps these requests to
the feasible range on other displays.

Default `LayoutProfile` values are points and may be overridden per Panel:

The showcase uses compact external-slot overrides (at most 320 pt minimum width,
200 pt minimum height) so all targets fit laptop displays. These are empty-slot
constraints, not claims about provider minimum sizes; adoption verifies actual
frames and can reject a slot that an app cannot fit. Aspect ranges are currently
diagnostic and growth weights are stored for later optimization.

| Kind | Minimum | Preferred aspect ratio | Growth weight |
|---|---:|---:|---:|
| Task | 360×240 | 1.2–2.0 | 1.0 |
| CLI | 400×220 | 1.6–3.2 | 1.0 |
| App | 520×320 | 1.2–2.2 | 1.5 |
| Agent | 440×280 | 1.1–2.2 | 1.3 |
| File | 300×360 | 0.55–1.4 | 0.8 |
| Notes | 320×240 | 0.8–1.6 | 0.8 |

### Implementation Phase 2 — Semantic block system

- **GOAL-003**: Add durable shell-command semantics and Warp-like copy/rerun/search affordances without replacing Ghostty rendering.

| Task | Description | Completed | Date |
|------|-------------|-----------|------|
| TASK-017 | Define `Block`, `BlockID`, `BlockSource`, `BlockKind`, `BlockStatus`, `LiveRange`, `TerminalPayload`, `AgentPayload`, and `Artifact` in `crates/teaser-core/src/blocks`; share common identity/status/search fields without forcing terminal snapshots and ACP events into one payload type. | | |
| TASK-018 | Implement semantic callback handling in `TerminalSurfaceAdapter`; assign a Teaser `BlockID` at command start, update status on command finish, snapshot on finish/eviction, and invalidate only the live range when Ghostty discards rows. | | |
| TASK-019 | Add fish, zsh, and bash integration under `shell-integration`; emit standard OSC 133 and OSC 7 only, preserve user prompts, avoid duplicate installation, and test multiline prompts, pipelines, signals, nonzero exit, nested shells, and SSH. | | |
| TASK-020 | Implement `BlockOverlayController` and block actions under `app/macos/Teaser/Blocks`; provide status, copy, jump, and rerun preparation while drawing only host chrome aligned to Ghostty ranges; rerun restores editable input in the recorded session/cwd and always requires confirmation. | | |
| TASK-021 | Implement `SearchScope.focusedPanel` on `Cmd-F` and `SearchScope.workspace` on `Cmd-Shift-F`; search retained terminal text and persisted snapshots, return source/session/block identity, and never search every Workspace implicitly. | | |

### Implementation Phase 3 — ACP agent sessions and generic input

- **GOAL-004**: Render Claude and Codex execution as Panel content while keeping native CLI completeness and host-owned input/presentation.

| Task | Description | Completed | Date |
|------|-------------|-----------|------|
| TASK-022 | Implement `AgentBackend`, `AcpAgentBackend`, `AgentSession`, and `AgentEvent` in `crates/teaser-acp`; negotiate ACP protocol/capabilities and support only advertised initialize, session, prompt, update, tool, permission, plan, resource, cancel, and vendor `_meta` behavior. | | |
| TASK-023 | Add a hard-coded v1 `AgentRegistry` containing only `claude` and `codex`; supervise pinned adapter subprocesses with bounded restart, sanitized environment inheritance, stderr diagnostics, cancellation, and deterministic crash state. | | |
| TASK-024 | Implement `InputViewController` as built-in Panel content under `app/macos/Teaser/Input` using `NSTextView`; support multiline text, undo/redo, native IME, file/image attachments, configurable submit shortcut, and typed approval/question prompts; submit completed values to Rust as one operation. | | |
| TASK-025 | Implement `AgentViewController` as built-in Panel content under `app/macos/Teaser/Agents`; map supported turns, tools, permissions, plans, diffs, images, and resources to BlockStore-backed native views; show explicit unsupported-capability states rather than imitating vendor CLI behavior. | | |
| TASK-026 | Extend `crates/teaser-cli` with `teaser agent <claude|codex> [--cwd PATH]`; reject unknown names, preserve vendor commands, surface missing-auth/missing-adapter errors, and document native `claude`/`codex` TerminalSurface mode as the full-feature fallback. | | |

### Implementation Phase 4 — Persistent and remote terminal backends

- **GOAL-005**: Add tmux-backed persistence, SSH workflows, and honest opaque Mosh support while Teaser remains the visible layout owner.

| Task | Description | Completed | Date |
|------|-------------|-----------|------|
| TASK-027 | Complete `TmuxControlBackend` in `crates/teaser-tmux`; implement pane identity, create/close, input, decoded output, resize, notifications, pause/continue flow control, reconnect, capture-pane recovery, Teaser replacements for non-rendered tmux modes, and malformed-protocol limits. | | |
| TASK-028 | Complete `teaser-bridge`; authenticate to TeaserCore's per-session socket, forward stdin/stdout as bounded binary frames, report `SIGWINCH`, preserve ordering, apply backpressure, and exit when either owning surface or backend closes. | | |
| TASK-029 | Implement `RemoteMode::SshCommand` and `RemoteMode::SshTmuxControl` using the system `ssh` executable and existing user SSH config/agent; never implement private-key parsing; support preconfigured host keys and key/agent auth first; route password, MFA, and first-host-key setup through a separate bootstrap flow outside the control stream. | | |
| TASK-030 | Implement `RemoteMode::MoshOpaque` by launching the installed `mosh` executable in a direct terminal surface; advertise only opaque terminal/network-roaming capabilities, state that app restart terminates it, and treat inner `tmux attach` as terminal content. | | |
| TASK-031 | On tmux control reconnect, restore pane text through `capture-pane` and mark the recovered interval `semantic_degraded`; never invent missed command boundaries, exit status, or historical blocks. | | |
| TASK-032 | Add restart/reconnect integration tests using local tmux and an isolated SSH target; verify pane routing, ordering, size restoration, stale IDs, network loss, auth bootstrap isolation, degraded recovery, remote exit, and Mosh capability degradation. | | |

### Implementation Phase 5 — Release hardening

- **GOAL-006**: Produce a diagnosable, accessible, signed, documented, and reproducibly packaged macOS v1 release.

| Task | Description | Completed | Date |
|------|-------------|-----------|------|
| TASK-033 | Add structured logging and diagnostic export across Swift and Rust; record timings and lifecycle metadata while redacting prompt text, terminal output, tokens, environment secrets, and file contents by default. | | |
| TASK-034 | Add crash recovery for workspace metadata, block transactions, adapter processes, tmux connections, and external-window frame restoration; test forced termination at each persistence boundary and document that direct PTY/Mosh processes survive GUI detach but not `teaserd` exit. | | |
| TASK-035 | Add VoiceOver labels, keyboard-only navigation, contrast checks, reduced-motion behavior, permission education, and IME/accessibility regression tests for every native surface. | | |
| TASK-036 | Add CI for Rust format/clippy/tests, Swift build/tests, Ghostty submodule-pin and patch-application verification, license/notice verification, shell-integration tests, and benchmark smoke thresholds; cache only reproducible build artifacts. | | |
| TASK-037 | Create Developer ID signing/notarization and release packaging, generate GitHub release archives and a Homebrew cask, produce checksums, and document manual credential steps without storing secrets in the repository. | | |
| TASK-038 | Complete `docs/user-guide.md`, `CONTRIBUTING.md`, `docs/benchmark-report.md`, and exact `THIRD_PARTY_NOTICES.md`; verify all v1 release criteria in `ROADMAP.md` and mark this plan Completed only after every task and test is recorded. | | |

## 3. Alternatives

- **ALT-001**: Thin-fork the complete Ghostty macOS application. Rejected as the default because it couples Teaser workspace code to upstream UI churn; retained only as a foundation reassessment if the documented embedding gate fails.
- **ALT-002**: Build on `libghostty-vt` and write a new renderer. Rejected because it discards the performance/input implementation that motivated Ghostty.
- **ALT-003**: Use GPUI or Zed as the host. Rejected because GPUI is pre-1.0 and Zed's editor/workspace is not a stable embeddable library; adopting Zed's provider-owned window preserves native behavior at lower cost.
- **ALT-004**: Reparent, capture, and forward arbitrary external GUI windows. Rejected because macOS provides no public general reparent API and pixel mirroring cannot preserve IME, drag/drop, accessibility, or native focus. Public top-level window geometry orchestration is the accepted boundary.
- **ALT-005**: Define a custom agent protocol. Rejected because ACP covers the semantic control plane and Claude/Codex adapters already exist.
- **ALT-006**: Use Mosh as a transport for tmux control mode. Rejected because Mosh synchronizes terminal state rather than exposing a transparent ordered byte stream.
- **ALT-007**: Open a third-party plugin SDK in v1. Rejected because there are no concrete plugin consumers and early compatibility promises would freeze unvalidated surface/session abstractions.
- **ALT-008**: Put complete project Workspaces in mutually exclusive tabs. Rejected because it hides parallel project state and reproduces the display discontinuity Teaser exists to remove.
- **ALT-009**: Keep one opaque full-screen Teaser window and draw imitations of provider applications inside it. Rejected because it cannot coexist correctly with live provider-owned windows and a fixture skin is not product evidence.
- **ALT-010**: Locate or silently rebind windows by application, title, repository path, or polling. Rejected because those fields are ambiguous and mutable; the physical drag selects an exact runtime window, and restart requires re-drag.

## 4. Dependencies

- **DEP-001**: Ghostty `v1.3.1` commit `332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28`, MIT license.
- **DEP-002**: macOS AppKit, SwiftUI, Quick Look, Image I/O, Core Animation, Core Graphics window lists, Accessibility, and Developer ID tooling.
- **DEP-003**: Rust stable toolchain with Cargo, rustfmt, and clippy; versions are locked in `rust-toolchain.toml` when TASK-001 executes.
- **DEP-004**: UniFFI for typed low-frequency Rust/Swift bindings, locked in `Cargo.lock`.
- **DEP-005**: SQLite through a typed Rust crate with bundled-vs-system linkage recorded before distribution.
- **DEP-006**: ACP v1 Rust SDK plus pinned Claude and Codex ACP adapters; runtime compatibility is determined by protocol/capability negotiation.
- **DEP-007**: tmux control mode and the system OpenSSH client; tests record minimum supported versions.
- **DEP-008**: Mosh executable for optional opaque sessions; absence disables only that capability.
- **DEP-009**: Homebrew for developer dependencies and eventual cask distribution.
- **DEP-010**: SplitView `3.5.3` and KeyboardShortcuts `3.1.0`, MIT; exact SwiftPM
  pins and resource/license bundling are part of the app gate.

## 5. Files

- **FILE-001**: `Cargo.toml`, `Cargo.lock`, and `rust-toolchain.toml` define the Rust workspace and exact toolchain/dependency graph.
- **FILE-002**: `app/macos` contains the native Swift application, resources, probes, and tests; project scripts currently build it without an Xcode project.
- **FILE-003**: `crates/teaser-core` contains Project, Workspace, Panel, content-binding, block, capability, persistence, FFI, and IPC models.
- **FILE-004**: `crates/teaser-cli` contains the public `teaser` command.
- **FILE-005**: `crates/teaser-bridge` contains the tmux-pane byte-stream helper.
- **FILE-006**: `crates/teaser-acp` contains ACP sessions and built-in Claude/Codex adapter supervision.
- **FILE-007**: `crates/teaser-tmux` contains tmux control-mode parsing and backend lifecycle.
- **FILE-008**: `vendor/ghostty` is the pinned Ghostty submodule; `vendor/README.md` records provenance and parent-owned patches.
- **FILE-009**: `shell-integration` contains fish, zsh, and bash OSC integration and tests.
- **FILE-010**: `benchmarks/terminal` contains comparative terminal performance harnesses and methodology.
- **FILE-011**: `docs`, `ROADMAP.md`, `README.md`, `LICENSE`, `NOTICE`, `TRADEMARKS.md`, and `THIRD_PARTY_NOTICES.md` contain public documentation and legal notices.
- **FILE-012**: `.codex/HANDOFF.md` contains local session state and must remain ignored and untracked.

## 6. Testing

- **TEST-001**: Workspace/Panel layout tests preserve identities, valid Virtual Focus, requested ratios, exact fill, non-overlap, connected rectangular Workspaces, minimum sizes, deterministic unequal layouts, solved edge-insertion geometry for all four edges, and exact state across split/move/resize/tile/focus/switch/display/restore sequences.
- **TEST-002**: Ghostty embedding tests cover clean-clone resources, runtime tick/wakeup, lifetime, signed bundle, render, resize, focus, clipboard, selection, Kitty graphics, English input, and Chinese IME.
- **TEST-003**: Block tests cover OSC 133/OSC 7, multiline prompts, wrapping, resize, scrollback, eviction, signals, exit status, nested shells, alternate screen, snapshot limits, retention controls, confirmed rerun, and search scope.
- **TEST-004**: ACP tests cover protocol negotiation, capability gaps, Claude/Codex initialization, updates, tools, permissions, plans, resources, cancellation, auth failure, malformed messages, adapter crash, and restart limits.
- **TEST-005**: tmux tests cover parser fuzzing, arbitrary bytes, Unicode, bracketed paste, mouse protocol, pane mapping, escaped output, pause/continue, backpressure, resize, capture repair, reconnect, and degraded semantics.
- **TEST-006**: Mosh tests confirm network roaming while the direct PTY lives, termination on `teaserd` exit, ordinary terminal use, and absence of structured tmux/block capabilities.
- **TEST-007**: Accessibility tests cover permission denied, exact AX/Core Graphics identity, window-versus-content drag qualification, four edge targets, empty/occupied targets, move/swap/detach, frame readback and rollback, Undo, Virtual/Input Focus separation, same-application multiple windows, close, multiple displays, current-Space behavior, identity loss, and safe frame restoration.
- **TEST-012**: Adoption-chain tests run headless in the default gate: they substitute pointer events, window snapshots, and time at `ExternalWindowService`, `ExternalWindowLease`, `ExternalWindowHandle`, `ExternalWindowPointerSource`, and `ExternalWindowClock`, drive the same `DesktopStageOrchestrator` and `WindowDragObserver` the application drives, and assert drop highlights, Panel bindings, operation ordering, frame readback, diagnostics, and restoration records without a global event monitor, a visible window, a permission request, or any movement of a user's window. The covered contracts and the mutations that prove the assertions bite are recorded in the adoption regression matrix in Phase 1.
- **TEST-008**: IPC/security tests cover ownership, mode `0600`, stale sockets, oversized frames, invalid paths, malformed versions, process impersonation, and redacted logs.
- **TEST-009**: Persistence tests cover schema migration, atomic-write or WAL recovery, interrupted writes, permissions, display affinity, requested ratios, kinds, Notes, external provider hints without live identity, safe re-drag after restart, direct-PTY placeholders, tmux identity, block consistency, and corrupted-state quarantine.
- **TEST-010**: Comparative performance tests record direct-terminal and tmux-bridge SLOs while proving no hot-path UniFFI/JSON/SQLite activity.
- **TEST-011**: Release tests verify clean-machine install, signing, notarization, checksums, Homebrew cask, uninstall boundaries, notices, and update behavior.

## 7. Risks & Assumptions

- **RISK-001**: The full Ghostty embedding API is explicitly unstable. Mitigation: exact pin, one adapter, narrow patch, compile gate, comparative tests, and no automatic updates.
- **RISK-002**: The proposed semantic-range export may not remain narrow. Mitigation: M0 stops if it touches terminal model, reflow, or renderer rather than hiding the cost.
- **RISK-003**: every attached Session adds a local binary socket hop, while tmux adds another bridge and cannot reconstruct missed command lifecycles. Mitigation: benchmark both paths, apply bounded backpressure, and mark repaired intervals semantic-degraded.
- **RISK-004**: AX external-window control depends on permission, transient identity, provider frame constraints, and current-Space visibility. Mitigation: one-time permission education, drag-driven exact selection, identity revalidation, transactional frame readback and rollback, provider-hint-only persistence, explicit re-drag, and best-effort same-window restoration.
- **RISK-005**: ACP adapters may expose fewer or different capabilities than native vendor CLIs. Mitigation: negotiate capabilities, pin revisions, retain native CLI mode, and never claim equivalence.
- **RISK-006**: SQLite history may capture secrets. Mitigation: mode `0600`, bounded payloads, configurable retention/capacity, disable/clear controls, and redacted logs.
- **RISK-007**: AGPL does not force derivative products to display the Teaser product name. Mitigation: preserve source/legal-notice obligations, ship NOTICE, and use a separate non-confusing trademark policy.
- **ASSUMPTION-001**: Apple Silicon macOS is the only supported v1 host platform.
- **ASSUMPTION-002**: Users accept direct Developer ID distribution and one macOS Accessibility decision for external-window geometry management.
- **ASSUMPTION-003**: Neovim-in-terminal and an adopted provider-owned editor window cover v1 editor needs; Teaser does not need a native editor engine.
- **ASSUMPTION-004**: Third-party plugins have no current consumer and remain excluded until a separate approved design exists.
- **ASSUMPTION-005**: Direct PTY speed and compatibility are more important than making every backend structurally inspectable.

## 8. Related Specifications / Further Reading

- [Teaser architecture](../docs/architecture.md)
- [Teaser roadmap](../ROADMAP.md)
- [Ghostty embedding API](https://github.com/ghostty-org/ghostty/blob/main/include/ghostty.h)
- [Ghostty VT screen semantics](https://github.com/ghostty-org/ghostty/blob/main/include/ghostty/vt/screen.h)
- [Agent Client Protocol v1](https://agentclientprotocol.com/protocol/v1/overview)
- [tmux control mode](https://github.com/tmux/tmux/wiki/Control-Mode)
- [Mosh technical description](https://mosh.org/#techinfo)
- [UniFFI guide](https://mozilla.github.io/uniffi-rs/latest/)
- [macOS AXUIElement API](https://developer.apple.com/documentation/applicationservices/axuielement_h)
- [AppKit global event monitoring](https://developer.apple.com/documentation/appkit/nsevent/addglobalmonitorforevents%28matching%3Ahandler%3A%29)
- [Core Graphics window list](https://developer.apple.com/documentation/coregraphics/cgwindowlistcopywindowinfo%28_%3A_%3A%29)
