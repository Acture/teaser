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
- **FILE-002**: Planned `crates/teaser-core` and server protocol/persistence seams.
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
- **RISK-003**: Native fullscreen and real-window coexistence remain unsolved by
  the source import; deliver their implementation and honest acceptance evidence.
- **ASSUMPTION-001**: Keep the current GitHub repository/address and published
  history; changing its fork-network membership needs a separate hosting action.

## 8. Related Specifications / Further Reading

- [Architecture](../docs/architecture.md)
- [Protocol](../docs/ipc.md)
- [Delivery outcomes](../ROADMAP.md)
- [Linear execution home](https://linear.app/acturea/project/teaser-efe303ae636d)
