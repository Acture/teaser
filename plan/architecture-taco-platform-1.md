---
goal: Build the first supportable macOS TACO platform from the validated architecture
version: 1.0
date_created: 2026-07-21
last_updated: 2026-07-21
owner: Acture
status: 'Planned'
tags: [architecture, terminal, macos, rust, swift, agents]
---

# Introduction

![Status: Planned](https://img.shields.io/badge/status-Planned-blue)

This plan builds TACO from an empty repository into a macOS daily-driver terminal
workspace. It implements risk spikes first, then the terminal workspace, semantic
blocks, ACP agents, persistent/remote sessions, and release hardening. Every phase
has an explicit stop condition; no phase may compensate for a failed terminal
foundation by adding a second renderer.

## 1. Requirements & Constraints

- **REQ-001**: Render and accept input through the full Ghostty embedding surface; do not implement a second VT renderer.
- **REQ-002**: Keep raw PTY output, keystrokes, pointer events, IME composition, and render callbacks outside UniFFI, JSON, and SQLite paths.
- **REQ-003**: Model TACO-owned terminal, agent, image, and input surfaces in one `PaneTree` with tabs, splits, focus, resize, and restoration.
- **REQ-004**: Preserve unsupported CLI/TUI behavior through an ordinary PTY with no required TACO adapter.
- **REQ-005**: Produce shell blocks from OSC 133/OSC 7 and agent blocks from ACP while storing bounded completed payloads in SQLite.
- **REQ-006**: Support `taco agent claude` and `taco agent codex` without shadowing or modifying the vendor `claude` and `codex` commands.
- **REQ-007**: Support local tmux control mode, system SSH, SSH-carried tmux control mode, and capability-degraded opaque Mosh sessions.
- **REQ-008**: Manage Zed only as an adjacent external desktop companion through public Accessibility APIs; never reparent or capture it.
- **REQ-009**: Default search to the focused pane and require a distinct action for current-workspace search.
- **REQ-010**: Ship v1 without a dynamic plugin loader, public surface SDK, stable internal ABI, or third-party extension promise.
- **REQ-011**: Preserve native Claude/Codex CLI mode in TerminalSurface because ACP adapters may expose fewer capabilities than the vendor CLIs.
- **REQ-012**: Restore a command for rerun into an editable input area and require user confirmation; never auto-execute historical commands.
- **SEC-001**: Create the control socket at `~/Library/Application Support/TACO/runtime/control.sock` with mode `0600` inside a user-only directory.
- **SEC-002**: Treat PTY output, OSC payloads, ACP `_meta`, file paths, and tmux control messages as untrusted input and bound every decoded frame or stored payload.
- **SEC-003**: Request Accessibility access only when external-window management is invoked and continue without it when permission is denied.
- **SEC-004**: Create workspace databases with user-only permissions and expose retention duration, capacity, disable-history, and clear-history controls.
- **CON-001**: Target Apple Silicon macOS first and distribute outside the Mac App Store sandbox.
- **CON-002**: Pin Ghostty `v1.3.1` commit `332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28`; never follow `main` implicitly.
- **CON-003**: Write TACO application logic in typed Rust and Swift; restrict Zig changes to the Ghostty embedding boundary.
- **CON-004**: Use tabs in new project-owned source where the language formatter permits; otherwise follow rustfmt and Swift format conventions.
- **CON-005**: Use AGPL-3.0-or-later for TACO and preserve every bundled dependency notice.
- **CON-006**: Do not claim arbitrary block folding/reordering, native Zed embedding, or direct PTY survival across `tacod` termination in v1.
- **CON-007**: Treat tmux text recovered after a control disconnect as semantic-degraded when OSC 133 lifecycle or exit status was missed.
- **CON-008**: Treat Mosh roaming as valid only while its owning `tacod` direct PTY remains alive; daemon restart does not restore that Mosh process.
- **GUD-001**: Use closed enums for built-in surfaces and introduce traits only for seams with multiple implementations, including `SessionBackend` and `AgentBackend`.
- **GUD-002**: Log lifecycle transitions, reconnects, adapter failures, and expensive operations at INFO; do not log raw prompts, PTY contents, or credentials by default.
- **GUD-003**: Display progress and elapsed time for dependency builds, packaging, and benchmark suites that exceed five seconds.
- **GUD-004**: Run `cargo fmt`, `cargo clippy --all-targets --all-features`, Swift compiler checks, and project tests before completing each implementation phase.
- **PAT-001**: Rust owns persistent workspace state; Swift owns live AppKit geometry and view lifetime; messages crossing the boundary are immutable typed values.
- **PAT-002**: Model missing integration as an explicit `CapabilitySet`, not as guessed behavior or silent fallback.
- **PAT-003**: Supervise ACP adapters, tmux, SSH, and bridge processes with bounded restart and deterministic terminal states.

## 2. Implementation Steps

### Implementation Phase 0 — Foundation and feasibility gates

- **GOAL-001**: Prove the Ghostty, Swift/Rust, semantic-block, ACP, tmux, and Accessibility boundaries before product implementation.

| Task | Description | Completed | Date |
|------|-------------|-----------|------|
| TASK-001 | Create a Cargo workspace in `Cargo.toml` containing `crates/taco-core`, `crates/taco-cli`, `crates/taco-bridge`, `crates/taco-acp`, and `crates/taco-tmux`; create the Swift macOS app under `app/macos` with bundle identifier `com.acture.taco`; add `scripts/bootstrap.fish` and `scripts/check.fish` using fish syntax only. | | |
| TASK-002 | Register Ghostty as a clean Git submodule under `vendor/ghostty`, pinned to CON-002; keep TACO deltas in parent-owned patches; document provenance, verification, and explicit updates in `vendor/README.md`; copy required MIT notices into `THIRD_PARTY_NOTICES.md`. | Yes | 2026-07-23 |
| TASK-003 | Implement `TerminalSurfaceAdapter` in `app/macos/TACO/Terminal/TerminalSurfaceAdapter.swift`; host one Ghostty surface in an `NSView` and attach it to a `tacod`-owned Session without creating a second PTY; verify clean-clone resources, binary flow control, app tick/wakeup, main-thread and lifetime behavior, resize, focus, selection, clipboard, English input, Chinese IME, process exit, 120 Hz, and a signed development bundle. | | |
| TASK-004 | Add `benchmarks/terminal` with reproducible direct-Ghostty and TACO harnesses using the same Ghostty revision, config, hardware, workload, and display rate; measure p50/p95 input-to-present, sustained output, CPU, memory, and dropped frames; record the methodology and initial 10% direct-terminal target before v0.1. | | |
| TASK-005 | Extend only the Ghostty embedding/query boundary to expose semantic-zone begin/update/end/evict callbacks, opaque range handles, and plain-text range reads; add C/Zig tests proving OSC 133 prompt/input/output classification survives wrapping and resize. Stop the plan if terminal-model, reflow, or renderer redesign is required. | | |
| TASK-006 | Implement the UniFFI boundary in `crates/taco-core/src/ffi.rs` and `app/macos/TACO/Core/TacoCoreBridge.swift` with `TacoCore`, `WorkspaceSnapshot`, `CoreAction`, and `CoreEvent`; add a guard test that no terminal byte-buffer type is exported. | | |
| TASK-007 | In `crates/taco-acp/tests/smoke.rs`, start pinned Claude and Codex ACP adapters, negotiate `protocolVersion` and capabilities, initialize one session, submit one prompt, collect updates, and terminate cleanly; compare advertised features with native CLI mode and record exact adapter revisions/notices. | | |
| TASK-008 | In `crates/taco-tmux`, parse one local tmux control session and connect one pane through `crates/taco-bridge` to the same `tacod` Session data plane used by a TerminalSurface; test arbitrary bytes, Unicode, IME-produced input, bracketed paste, mouse protocol, resize, `%pause/%continue`, `capture-pane` repair, malformed messages, and flow control; record the initial 20% bridge target. | | |
| TASK-009 | Implement a `ManagedExternalWindow` spike in `app/macos/TACO/ExternalWindows`; locate one Zed window through AX on the current Space, tile it beside TACO, observe move/close events, and best-effort restore the original frame while the same window remains identifiable. | | |

CP-M0.6 now proves a real daemon-owned PTY, exclusive attachment leases, bounded
binary frames, monotonic replay offsets, replay-gap reporting, detach/reattach with
one unchanged child PID, and resize. It deliberately leaves PTY creation out of the
foreground daemon until Checkout resolution exists. CP-M0.7 additionally verifies
the initial child as its session and process-group leader and reaps a stubborn
same-PGID descendant after both explicit termination and natural leader exit. It
uses non-reaping exit observation to preserve PGID identity through cleanup, but
does not cover job-control processes moved into other PGIDs. Before TASK-003 starts
a user shell, replace or isolate the checkpoint `portable-pty` multithreaded
`pre_exec` path, bound input backpressure, and provide cross-PGID session cleanup.

CP-M0.8 adds a parent-owned Ghostty external-I/O patch: the full surface can select
a backend with no `Exec`, PTY, or child state; host output enters through the C ABI;
and encoded input plus resize return through callbacks. Focused tests, exact ABI
checks, a native Apple Silicon XCFramework build/link, and
`app/macos/TACOProbe` pass. The probe covers IOSurface-backed Metal draw plumbing,
readback, exact input ordering, resize consistency, direct-child snapshots, and
ordered teardown. It checks a live IOSurface draw target, not captured pixels.
Source-level tests prove the backend contains no process or PTY state; the runtime
snapshot is corroborating rather than exhaustive. CP-M0.8 is closed, but TASK-003
remains open for the clean-clone host, bundled resources, IME, clipboard,
selection, 120 Hz, and signed-app gates.

CP-M0.9 connects a fixed daemon-owned PTY fixture to the native Ghostty surface
through the production-shaped `taco.attach.v1` binary stream. The probe proves
exclusive attachment, output/input/resize forwarding, detach with a live child,
offline replay, same-PID reattachment, Metal draw plumbing, full-screen readback,
and ordered exit/teardown. It deliberately creates the fixed child before
threaded IPC accept begins and exposes no configurable program or cwd. It does
not close the interactive-shell spawn, cross-PGID cleanup, clean-clone bundle,
IME, clipboard, selection, 120 Hz, or production asynchronous input-pump
portions of TASK-003.

### Implementation Phase 1 — Native terminal workspace

- **GOAL-002**: Deliver a reliable local shell/TUI workspace with images, external Zed tiling, persistence, and CLI control.

| Task | Description | Completed | Date |
|------|-------------|-----------|------|
| TASK-010 | Implement immutable `PaneTree`, `PaneNode`, `SplitAxis`, `SurfaceID`, and `WorkspaceID` types plus split/close/move/resize/focus reducers in `crates/taco-core/src/workspace`; add property tests for tree invariants and focus validity. | | |
| TASK-011 | Implement `WorkspaceHost`, `PaneContainerView`, and action routing under `app/macos/TACO/Workspace`; render terminal panes without adding per-frame host work; add tabs, splits, zoom, focus, resize, and command palette. | | |
| TASK-012 | Implement workspace SQLite persistence in `crates/taco-core/src/store`; store schema version, pane tree, surface descriptors, backend identity, and restoration state at the architecture-defined path with mode `0600`; reattach a direct PTY only while its exact owning `tacod` Session remains live, otherwise restore a terminated placeholder. | | |
| TASK-013 | Implement `HistoryPolicy` with maximum database bytes, retention duration, persistence enabled/disabled, clear-on-exit, and explicit clear-now action; enforce bounds transactionally and expose the controls in native settings. | | |
| TASK-014 | Implement `ImageSurfaceController` under `app/macos/TACO/Images` using `QLPreviewView` with Image I/O metadata fallback; route `taco open <PATH>` to image preview for supported media and to a terminal editor command for text. | | |
| TASK-015 | Promote the AX spike into `DesktopLayoutCoordinator`; support one external Zed companion adjacent to one TACO workspace window, explicit permission UX, focus, close observation, and best-effort frame restoration; do not represent Zed as a `Surface`. | | |
| TASK-016 | Implement the versioned CLI protocol in `crates/taco-core/src/ipc` and `crates/taco-cli`; support `taco`, `taco shell [--cwd PATH]`, and `taco open <PATH>`; validate paths, socket ownership, stale sockets, bounded app-launch retry, and structured errors. | | |

### Implementation Phase 2 — Semantic block system

- **GOAL-003**: Add durable shell-command semantics and Warp-like copy/rerun/search affordances without replacing Ghostty rendering.

| Task | Description | Completed | Date |
|------|-------------|-----------|------|
| TASK-017 | Define `Block`, `BlockID`, `BlockSource`, `BlockKind`, `BlockStatus`, `LiveRange`, `TerminalPayload`, `AgentPayload`, and `Artifact` in `crates/taco-core/src/blocks`; share common identity/status/search fields without forcing terminal snapshots and ACP events into one payload type. | | |
| TASK-018 | Implement semantic callback handling in `TerminalSurfaceAdapter`; assign a TACO `BlockID` at command start, update status on command finish, snapshot on finish/eviction, and invalidate only the live range when Ghostty discards rows. | | |
| TASK-019 | Add fish, zsh, and bash integration under `shell-integration`; emit standard OSC 133 and OSC 7 only, preserve user prompts, avoid duplicate installation, and test multiline prompts, pipelines, signals, nonzero exit, nested shells, and SSH. | | |
| TASK-020 | Implement `BlockOverlayController` and block actions under `app/macos/TACO/Blocks`; provide status, copy, jump, and rerun preparation while drawing only host chrome aligned to Ghostty ranges; rerun restores editable input in the recorded session/cwd and always requires confirmation. | | |
| TASK-021 | Implement `SearchScope.focusedPane` on `Cmd-F` and `SearchScope.workspace` on `Cmd-Shift-F`; search retained terminal text and persisted snapshots, return source/session/block identity, and never search every workspace implicitly. | | |

### Implementation Phase 3 — ACP agent sessions and generic input

- **GOAL-004**: Integrate Claude and Codex as structured sessions while keeping native CLI completeness and host-owned input/presentation.

| Task | Description | Completed | Date |
|------|-------------|-----------|------|
| TASK-022 | Implement `AgentBackend`, `AcpAgentBackend`, `AgentSession`, and `AgentEvent` in `crates/taco-acp`; negotiate ACP protocol/capabilities and support only advertised initialize, session, prompt, update, tool, permission, plan, resource, cancel, and vendor `_meta` behavior. | | |
| TASK-023 | Add a hard-coded v1 `AgentRegistry` containing only `claude` and `codex`; supervise pinned adapter subprocesses with bounded restart, sanitized environment inheritance, stderr diagnostics, cancellation, and deterministic crash state. | | |
| TASK-024 | Implement `InputSurfaceController` under `app/macos/TACO/Input` using `NSTextView`; support multiline text, undo/redo, native IME, file/image attachments, configurable submit shortcut, and typed approval/question prompts; submit completed values to Rust as one operation. | | |
| TASK-025 | Implement `AgentSurfaceController` under `app/macos/TACO/Agents`; map supported turns, tools, permissions, plans, diffs, images, and resources to BlockStore-backed native views; show explicit unsupported-capability states rather than imitating vendor CLI behavior. | | |
| TASK-026 | Extend `crates/taco-cli` with `taco agent <claude|codex> [--cwd PATH]`; reject unknown names, preserve vendor commands, surface missing-auth/missing-adapter errors, and document native `claude`/`codex` TerminalSurface mode as the full-feature fallback. | | |

### Implementation Phase 4 — Persistent and remote terminal backends

- **GOAL-005**: Add tmux-backed persistence, SSH workflows, and honest opaque Mosh support while TACO remains the visible layout owner.

| Task | Description | Completed | Date |
|------|-------------|-----------|------|
| TASK-027 | Complete `TmuxControlBackend` in `crates/taco-tmux`; implement pane identity, create/close, input, decoded output, resize, notifications, pause/continue flow control, reconnect, capture-pane recovery, TACO replacements for non-rendered tmux modes, and malformed-protocol limits. | | |
| TASK-028 | Complete `taco-bridge`; authenticate to TacoCore's per-session socket, forward stdin/stdout as bounded binary frames, report `SIGWINCH`, preserve ordering, apply backpressure, and exit when either owning surface or backend closes. | | |
| TASK-029 | Implement `RemoteMode::SshCommand` and `RemoteMode::SshTmuxControl` using the system `ssh` executable and existing user SSH config/agent; never implement private-key parsing; support preconfigured host keys and key/agent auth first; route password, MFA, and first-host-key setup through a separate bootstrap flow outside the control stream. | | |
| TASK-030 | Implement `RemoteMode::MoshOpaque` by launching the installed `mosh` executable in a direct terminal surface; advertise only opaque terminal/network-roaming capabilities, state that app restart terminates it, and treat inner `tmux attach` as terminal content. | | |
| TASK-031 | On tmux control reconnect, restore pane text through `capture-pane` and mark the recovered interval `semantic_degraded`; never invent missed command boundaries, exit status, or historical blocks. | | |
| TASK-032 | Add restart/reconnect integration tests using local tmux and an isolated SSH target; verify pane routing, ordering, size restoration, stale IDs, network loss, auth bootstrap isolation, degraded recovery, remote exit, and Mosh capability degradation. | | |

### Implementation Phase 5 — Release hardening

- **GOAL-006**: Produce a diagnosable, accessible, signed, documented, and reproducibly packaged macOS v1 release.

| Task | Description | Completed | Date |
|------|-------------|-----------|------|
| TASK-033 | Add structured logging and diagnostic export across Swift and Rust; record timings and lifecycle metadata while redacting prompt text, terminal output, tokens, environment secrets, and file contents by default. | | |
| TASK-034 | Add crash recovery for workspace metadata, block transactions, adapter processes, tmux connections, and external-window frame restoration; test forced termination at each persistence boundary and document that direct PTY/Mosh processes survive GUI detach but not `tacod` exit. | | |
| TASK-035 | Add VoiceOver labels, keyboard-only navigation, contrast checks, reduced-motion behavior, permission education, and IME/accessibility regression tests for every native surface. | | |
| TASK-036 | Add CI for Rust format/clippy/tests, Swift build/tests, Ghostty submodule-pin and patch-application verification, license/notice verification, shell-integration tests, and benchmark smoke thresholds; cache only reproducible build artifacts. | | |
| TASK-037 | Create Developer ID signing/notarization and release packaging, generate GitHub release archives and a Homebrew cask, produce checksums, and document manual credential steps without storing secrets in the repository. | | |
| TASK-038 | Complete `docs/user-guide.md`, `CONTRIBUTING.md`, `docs/benchmark-report.md`, and exact `THIRD_PARTY_NOTICES.md`; verify all v1 release criteria in `ROADMAP.md` and mark this plan Completed only after every task and test is recorded. | | |

## 3. Alternatives

- **ALT-001**: Thin-fork the complete Ghostty macOS application. Rejected as the default because it couples TACO workspace code to upstream UI churn; retained only as a foundation reassessment if the documented embedding gate fails.
- **ALT-002**: Build on `libghostty-vt` and write a new renderer. Rejected because it discards the performance/input implementation that motivated Ghostty.
- **ALT-003**: Use GPUI or Zed as the host. Rejected because GPUI is pre-1.0 and Zed's editor/workspace is not a stable embeddable library; external Zed tiling preserves native behavior at lower cost.
- **ALT-004**: Capture and forward arbitrary external GUI windows. Rejected because macOS provides no public general reparent API and pixel mirroring cannot preserve IME, drag/drop, accessibility, or native focus.
- **ALT-005**: Define a custom agent protocol. Rejected because ACP covers the semantic control plane and Claude/Codex adapters already exist.
- **ALT-006**: Use Mosh as a transport for tmux control mode. Rejected because Mosh synchronizes terminal state rather than exposing a transparent ordered byte stream.
- **ALT-007**: Open a third-party plugin SDK in v1. Rejected because there are no concrete plugin consumers and early compatibility promises would freeze unvalidated surface/session abstractions.

## 4. Dependencies

- **DEP-001**: Ghostty `v1.3.1` commit `332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28`, MIT license.
- **DEP-002**: macOS AppKit, SwiftUI, Quick Look, Image I/O, Core Animation, Accessibility, and Developer ID tooling.
- **DEP-003**: Rust stable toolchain with Cargo, rustfmt, and clippy; versions are locked in `rust-toolchain.toml` when TASK-001 executes.
- **DEP-004**: UniFFI for typed low-frequency Rust/Swift bindings, locked in `Cargo.lock`.
- **DEP-005**: SQLite through a typed Rust crate with bundled-vs-system linkage recorded before distribution.
- **DEP-006**: ACP v1 Rust SDK plus pinned Claude and Codex ACP adapters; runtime compatibility is determined by protocol/capability negotiation.
- **DEP-007**: tmux control mode and the system OpenSSH client; tests record minimum supported versions.
- **DEP-008**: Mosh executable for optional opaque sessions; absence disables only that capability.
- **DEP-009**: Homebrew for developer dependencies and eventual cask distribution.

## 5. Files

- **FILE-001**: `Cargo.toml`, `Cargo.lock`, and `rust-toolchain.toml` define the Rust workspace and exact toolchain/dependency graph.
- **FILE-002**: `app/macos` contains the native application, Xcode project, Swift sources, resources, and tests.
- **FILE-003**: `crates/taco-core` contains workspace, block, capability, persistence, FFI, and IPC models.
- **FILE-004**: `crates/taco-cli` contains the public `taco` command.
- **FILE-005**: `crates/taco-bridge` contains the terminal-pane byte-stream helper.
- **FILE-006**: `crates/taco-acp` contains ACP sessions and built-in Claude/Codex adapter supervision.
- **FILE-007**: `crates/taco-tmux` contains tmux control-mode parsing and backend lifecycle.
- **FILE-008**: `vendor/ghostty` is the pinned Ghostty submodule; `vendor/README.md` records provenance and parent-owned patches.
- **FILE-009**: `shell-integration` contains fish, zsh, and bash OSC integration and tests.
- **FILE-010**: `benchmarks/terminal` contains comparative terminal performance harnesses and methodology.
- **FILE-011**: `docs`, `ROADMAP.md`, `README.md`, `LICENSE`, `NOTICE`, `TRADEMARKS.md`, and `THIRD_PARTY_NOTICES.md` contain public documentation and legal notices.
- **FILE-012**: `.codex/HANDOFF.md` contains local session state and must remain ignored and untracked.

## 6. Testing

- **TEST-001**: PaneTree property tests preserve a nonempty valid root, unique IDs, valid focus, and normalized split weights across every reducer sequence.
- **TEST-002**: Ghostty embedding tests cover clean-clone resources, runtime tick/wakeup, lifetime, signed bundle, render, resize, focus, clipboard, selection, Kitty graphics, English input, and Chinese IME.
- **TEST-003**: Block tests cover OSC 133/OSC 7, multiline prompts, wrapping, resize, scrollback, eviction, signals, exit status, nested shells, alternate screen, snapshot limits, retention controls, confirmed rerun, and search scope.
- **TEST-004**: ACP tests cover protocol negotiation, capability gaps, Claude/Codex initialization, updates, tools, permissions, plans, resources, cancellation, auth failure, malformed messages, adapter crash, and restart limits.
- **TEST-005**: tmux tests cover parser fuzzing, arbitrary bytes, Unicode, bracketed paste, mouse protocol, pane mapping, escaped output, pause/continue, backpressure, resize, capture repair, reconnect, and degraded semantics.
- **TEST-006**: Mosh tests confirm network roaming while the direct PTY lives, termination on `tacod` exit, ordinary terminal use, and absence of structured tmux/block capabilities.
- **TEST-007**: Accessibility tests cover permission denied, Zed launch/find, move/resize/focus, user movement, close, multiple windows, current-Space behavior, identity loss, and best-effort frame restoration.
- **TEST-008**: IPC/security tests cover ownership, mode `0600`, stale sockets, oversized frames, invalid paths, malformed versions, process impersonation, and redacted logs.
- **TEST-009**: Persistence tests cover schema migration, WAL recovery, interrupted writes, permissions, capacity/retention, disable/clear, direct-PTY placeholders, tmux identity, block consistency, and corrupted-state quarantine.
- **TEST-010**: Comparative performance tests record direct-terminal and tmux-bridge SLOs while proving no hot-path UniFFI/JSON/SQLite activity.
- **TEST-011**: Release tests verify clean-machine install, signing, notarization, checksums, Homebrew cask, uninstall boundaries, notices, and update behavior.

## 7. Risks & Assumptions

- **RISK-001**: The full Ghostty embedding API is explicitly unstable. Mitigation: exact pin, one adapter, narrow patch, compile gate, comparative tests, and no automatic updates.
- **RISK-002**: The proposed semantic-range export may not remain narrow. Mitigation: M0 stops if it touches terminal model, reflow, or renderer rather than hiding the cost.
- **RISK-003**: every attached Session adds a local binary socket hop, while tmux adds another bridge and cannot reconstruct missed command lifecycles. Mitigation: benchmark both paths, apply bounded backpressure, and mark repaired intervals semantic-degraded.
- **RISK-004**: AX external-window control depends on permission and unstable external window identity. Mitigation: adjacent current-Space tiling, permission-on-use, visible degradation, and best-effort restoration only.
- **RISK-005**: ACP adapters may expose fewer or different capabilities than native vendor CLIs. Mitigation: negotiate capabilities, pin revisions, retain native CLI mode, and never claim equivalence.
- **RISK-006**: SQLite history may capture secrets. Mitigation: mode `0600`, bounded payloads, configurable retention/capacity, disable/clear controls, and redacted logs.
- **RISK-007**: AGPL does not force derivative products to display the TACO product name. Mitigation: preserve source/legal-notice obligations, ship NOTICE, and use a separate non-confusing trademark policy.
- **ASSUMPTION-001**: Apple Silicon macOS is the only supported v1 host platform.
- **ASSUMPTION-002**: Users accept direct Developer ID distribution and Accessibility permission for optional external-window tiling.
- **ASSUMPTION-003**: Neovim-in-terminal and externally tiled Zed cover v1 editor needs; TACO does not need a native editor engine.
- **ASSUMPTION-004**: Third-party plugins have no current consumer and remain excluded until a separate approved design exists.
- **ASSUMPTION-005**: Direct PTY speed and compatibility are more important than making every backend structurally inspectable.

## 8. Related Specifications / Further Reading

- [TACO architecture](../docs/architecture.md)
- [TACO roadmap](../ROADMAP.md)
- [Ghostty embedding API](https://github.com/ghostty-org/ghostty/blob/main/include/ghostty.h)
- [Ghostty VT screen semantics](https://github.com/ghostty-org/ghostty/blob/main/include/ghostty/vt/screen.h)
- [Agent Client Protocol v1](https://agentclientprotocol.com/protocol/v1/overview)
- [tmux control mode](https://github.com/tmux/tmux/wiki/Control-Mode)
- [Mosh technical description](https://mosh.org/#techinfo)
- [UniFFI guide](https://mozilla.github.io/uniffi-rs/latest/)
