# TACO architecture

Status: design baseline

Last updated: 2026-07-27

## 1. System boundary

TACO is a native workspace host, not a new shell, editor, browser, or agent model.
It composes terminal and non-terminal surfaces while preserving the native input
and rendering path of each component.

```text
TACO.app
├── WorkspaceHost                              AppKit / SwiftUI
│   ├── PaneTree                               terminal / agent / image / input
│   ├── DesktopLayout                          TACO windows + external companions
│   └── focus, actions, clipboard, permissions
├── TerminalSurfaceAdapter
│   └── pinned libghostty                      VT state + Metal + IME + selection
├── TerminalAttachmentPump                    bounded asynchronous data plane
│   └── AttachmentClient                       taco.attach.v1 transport
└── low-frequency typed control

tacod
├── SessionRegistry                            exact Session / Surface leases
├── PTY session workers                        child + master + replay + resize
├── control.sock                               JSON handshake → binary attach
├── TacoCore                                   Rust, low-frequency UniFFI boundary
│   ├── WorkspaceStore / BlockStore            SQLite WAL
│   ├── ACP client                             Claude + Codex
│   ├── tmux control parser
│   ├── taco-bridge                            pane byte-stream helper
│   └── CLI IPC                                per-user Unix socket

taco CLI                                       low-frequency control client
```

The host is macOS-first because AppKit already supplies the hard parts TACO should
not rebuild: responder routing, text input and IME, accessibility, drag and drop,
window lifecycle, and native view composition.

## 2. Ownership and performance boundaries

Swift/AppKit owns live view lifetime, window and pane geometry, focus, native input,
clipboard, image preview, and Accessibility permission UX.

`tacod` owns each TACO Session's canonical child process, PTY master, attachment
lease, replay offsets, backend lifecycle, and eventual block state. Rust also owns
the authoritative persistent workspace model, capabilities, ACP state, tmux
parsing, CLI IPC, and diagnostics.

Raw PTY output, keystrokes, pointer motion, IME composition, and render callbacks
must never cross UniFFI, JSON, or SQLite. A TerminalSurface attaches to one exact
Session through a bounded binary Unix-socket stream; JSON is used only for the
initial handshake. Swift sends only low-frequency model commands and semantic
events through the typed control boundary.

## 3. Terminal foundation

TACO consumes the full Ghostty embedding API rather than implementing a second VT
renderer. Upstream's full surface currently owns its PTY together with terminal
state, renderer, input, selection, and platform surface. TACO's architecture instead
requires `tacod` to own the canonical PTY. The pinned TACO patch now proves an
external-input/output surface mode with no `Exec`, PTY, or child state. This is a
narrow feasibility result, not a stable upstream API. The adapter therefore pins one
exact revision because Ghostty's header says the API is not yet general-purpose or
stable.

Initial baseline:

- Ghostty tag: `v1.3.1`
- commit: `332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28`
- source location: a pinned Git submodule under `vendor/ghostty`
- provenance and parent-owned TACO patches: documented in `vendor/README.md`

The submodule remains clean. TACO keeps narrow Zig experiments under
`patches/ghostty`; no workspace or agent behavior is implemented inside Ghostty.

The M0 spike must prove a clean-clone build, bundled runtime resources, AppKit
main-thread/lifetime rules, Ghostty tick/wakeup handling, IME, 120 Hz drawing, and a
signed app bundle. It must also prove that externally supplied Session bytes can
drive the full surface and that surface input/resize can return to `tacod` without a
second PTY. CP-M0.6 proves only the daemon-owned PTY and detachable binary data plane.
If external transport or semantic blocks require redesigning Ghostty's terminal
model, reflow, or renderer, implementation stops and the fork cost is reassessed.

CP-M0.6 uses `portable-pty` 0.9.0 only to validate the macOS data-plane shape.
CP-M0.7 verifies that its initial child is both the process-group and session
leader, then explicitly terminates that owning group with bounded
`SIGTERM`-to-`SIGKILL` escalation. Non-reaping exit observation keeps the PGID
reserved while natural leader exit cleans up remaining members. The gate covers
stubborn descendants that remain in that PGID. It does not claim to reach
foreground or background jobs moved into other PGIDs by interactive shell job
control.

CP-M0.8 establishes the narrow Ghostty code seam for daemon-owned transport:
an external full-surface backend has no exec, PTY, or child state; accepts
ordered host output; and returns encoded input and resize events through C
callbacks. The parent-owned patch touches only the embedding/backend boundary
and includes focused Zig and ABI tests. With Metal Toolchain 17F109, the native
Apple Silicon XCFramework builds and links. `app/macos/TACOProbe` passes real
AppKit/Metal draw plumbing to a live `IOSurfaceLayer`, full-screen readback,
exact `probe\r` input forwarding, resize consistency, direct-child snapshots,
and ordered teardown. The source-level backend tests remain the authoritative
proof that no process or PTY state exists; the process snapshot is only
corroborating runtime evidence. This closes CP-M0.8, but not TASK-003's broader
clean-clone host, resources, IME, 120 Hz, and signed-bundle gates.

CP-M0.9 joins the previously separate proofs through the real attachment
protocol. A fixed, non-user-configurable `tacod --probe-session` child owns the
PTY while `TerminalSurfaceAdapter` forwards Ghostty output, input, and resize
over `taco.attach.v1`. The native probe verifies exclusive attachment, real
PTY output readback, resize observed by the child, synchronous input, detach
without child exit, bounded-offset offline replay, same-PID reattachment,
Metal draw plumbing, process exit, and ordered teardown. The probe Session is
created before `tacod` accepts threaded IPC work, so this checkpoint does not
claim that production interactive-shell spawning is safe. Its synchronous,
bounded-frame Swift bridge is a feasibility harness, not the production
asynchronous attachment pump or final paste/backpressure policy.

CP-M0.10 replaces that synchronous bridge with the production-shaped
`TerminalAttachmentPump`. Ghostty callbacks only copy and enqueue data; they
perform no socket I/O and never wait. One reader continuously feeds ordered
output into the Surface, while one writer preserves input/resize order. The
outbound queue is capped at 1 MiB of input and 4,096 events. Only consecutive
tail resize events coalesce. Overflow rejects the whole callback payload,
discards input whose delivery is uncertain, reports that state, and reconnects
rather than silently truncating input.

The pump reconnects under one five-second monotonic deadline from the last
output offset committed after a completed Surface feed. It never retransmits
old input; it may resend only the latest resize. Output resumes after
reconnection with input paused until explicit user confirmation acknowledges
that recovery generation; a stale confirmation cannot unlock a later
reconnect. A replay gap is a fatal desynchronization: the current Surface
receives no later output. Normal detach stops accepting input and drains queued
input for at most five seconds; a timeout aborts the transport and reports
uncertain delivery. Teardown quiesces callbacks, drains or stops the pump,
closes the socket to unblock both workers, joins them, waits for any Surface
feed to finish, and only then frees the Surface on the main thread.

The foreground daemon does not yet expose PTY creation. Before a user shell is
wired in, the spawn path must resolve `portable-pty`'s multithreaded `pre_exec`
risk and cross-PGID session cleanup. Working-directory selection is intentionally
absent until the Checkout resolver can enforce it.

## 4. Surface and layout model

`PaneTree` contains only TACO-owned surfaces:

- `TerminalSurface`: a full Ghostty surface;
- `AgentSurface`: structured ACP turns, tools, permissions, and artifacts;
- `ImageSurface`: Quick Look plus Image I/O metadata where useful;
- `InputSurface`: reusable native rich-text input based on `NSTextView`.

This is a closed internal enum, not a plugin API. There is no dynamic loader,
extension registry, stable ABI, WASM host, or third-party SDK in v1. Interfaces are
introduced only where multiple implementations already exist, such as agent and
session backends.

Neovim is initially a normal TUI inside `TerminalSurface`. A native editor surface
is deliberately out of scope.

Zed is represented by `ManagedExternalWindow`, not by `Surface`. Accessibility
APIs may best-effort set its position, size, and focus and restore its frame while
the same process/window remains identifiable. TACO does not reparent its window,
capture its pixels, synthesize its editor input, or claim it is embedded. The first
implementation supports tiling Zed adjacent to a TACO workspace window on the
current Space; it does not carve an external window into one `NSWindow`.

## 5. Capability model

Every session advertises a `CapabilitySet`; UI actions appear only when the backing
session can honor them.

| Tier | Integration | Guaranteed behavior |
|---|---|---|
| 0 | Legacy CLI/TUI | Normal PTY rendering and input |
| 1 | Shell-aware | OSC 133 command semantics and OSC 7 cwd |
| 2 | Adapter-assisted | ACP, tmux control mode, or application RPC |
| 3 | Native TACO surface | Typed actions, resources, and native presentation |

Alternate-screen applications remain opaque. TACO never infers fake blocks from a
full-screen TUI merely because text happens to be visible.

## 6. Block model

A block is semantic metadata over terminal or agent activity, not an arbitrary UI
widget container.

```text
Block
├── id / session_id / source
├── kind                             shell_command | agent_turn | tool_call
├── cwd / command / timestamps
├── status                           running | succeeded | failed | interrupted
├── terminal live range              optional, ephemeral Ghostty handle
├── durable payload                  bounded snapshot or structured ACP events
└── artifacts                        files, images, diffs, links
```

Terminal and agent blocks share identity, status, search, and artifact concepts, but
do not pretend to have identical storage: terminal blocks have ephemeral Ghostty
ranges plus plain-text snapshots; agent blocks retain structured ACP events.

Ghostty already stores OSC 133 semantic content on cells and rows. The full surface
API does not expose enough range lifecycle information for TACO, so M0 attempts a
narrow API extension for semantic-zone lifecycle, opaque range handles, text reads,
and eviction notification. TACO assigns stable block IDs and persists completed
payloads in SQLite at
`~/Library/Application Support/TACO/workspaces/<workspace-id>.sqlite`.

Workspace databases and snapshots use user-only permissions. Settings must expose
history retention, maximum storage, clear-history, and disable-persistence controls;
raw output is never retained without a bound because commands and agent events may
contain secrets.

The first block UI supports status, copy, jump, rerun preparation, and search.
`Rerun` restores the command into the original session/cwd input area for user
confirmation; it never executes automatically. Missing cwd, remote sessions,
multiline commands, and secret-like input require explicit review.

Arbitrary block folding, reordering, or vertical gaps are not v1 promises because
they require a second terminal layout engine or deep renderer changes.

Search defaults are local: `Cmd-F` searches the focused pane and
`Cmd-Shift-F` searches the current workspace. There is no default all-workspaces
search.

## 7. Agent sessions and input

ACP is an optional agent semantic/control plane. TACO implements an ACP client and
starts pinned Claude and Codex ACP adapters as supervised subprocesses. Protocol
version and capabilities are negotiated at runtime; TACO does not infer wire
compatibility from a crate/package version. ACP events become blocks while vendor
`_meta` fields are retained for lossless round-tripping.

Structured public commands are:

```text
taco agent claude [--cwd PATH]
taco agent codex  [--cwd PATH]
```

This mode exposes only adapter-supported capabilities and is not equivalent to the
full vendor CLI. Existing `claude` and `codex` commands remain untouched and can
always run in a normal TerminalSurface for complete vendor behavior.

Agent input uses the same host-owned `InputSurface` available to other workflows.
It supports multiline text, native text services, file/image attachments, and typed
approval or question interactions. The completed value is submitted to ACP as one
operation; the agent adapter never handles per-keystroke editing.

ACP does not replace PTY, LSP, DAP, workspace, or multiplexer protocols.

## 8. Multiplexing and remote sessions

TACO owns visible layout. Every TACO-owned Session passes through `tacod`, even
when it has only one Surface. This means lifecycle and byte-stream multiplexing,
not simultaneous mirroring: a Session has at most one live Surface lease.

The direct Session path is:

```text
child process ↔ PTY slave
                 ↕
tacod PTY master → bounded replay / absolute offsets
                 ↕ taco.attach.v1
TerminalSurfaceAdapter ↔ pinned libghostty external transport gate
```

tmux remains a future persistence backend through documented control mode. Its
helper must sit behind the same Session abstraction and report `SIGWINCH`, arbitrary
bytes, backpressure, `%pause/%continue`, and `capture-pane` repair without sending
terminal bytes through UniFFI.

Remote modes are intentionally distinct:

- `ssh_command`: system `ssh` runs inside a normal terminal surface;
- `ssh_tmux_control`: system `ssh` transports tmux control mode to TacoCore;
- `mosh_opaque`: `mosh` runs inside a normal terminal surface.

SSH control mode initially supports preconfigured host keys and key/agent
authentication. Password, MFA, and first-host-key prompts require a separate
bootstrap UI so they cannot corrupt the control stream.

If TACO disconnects from tmux, `capture-pane` can restore visible text but cannot
reconstruct missed OSC 133 lifecycles or exit status. Recovered text is marked
semantic-degraded rather than converted into authoritative historical blocks. TACO
also supplies its own UI for tmux modes that control mode does not render.

Mosh synchronizes terminal state rather than providing a transparent byte stream,
so TACO does not carry tmux control semantics through it. Mosh handles network
roaming only while the owning `tacod` PTY remains alive; a daemon crash/restart
terminates that Mosh session. Running `tmux attach` inside Mosh remains usable but
opaque.

## 9. CLI and persistence

The Rust `taco` CLI connects to
`~/Library/Application Support/TACO/runtime/control.sock`. The app creates the
parent directory with user-only access and the socket with mode `0600`. If the
socket is absent, the CLI launches `TACO.app`, waits for readiness with a bounded
retry, and sends a versioned request.

Stable v1 commands:

```text
taco
taco shell [--cwd PATH]
taco agent <claude|codex> [--cwd PATH]
taco open <PATH>
```

Workspace persistence includes pane layout, bounded block history, resources, and
backend identity. Direct PTYs survive Surface or GUI disconnection while their
owning `tacod` process remains alive, but cannot survive daemon termination and
restore as terminated placeholders. tmux-backed sessions reconnect to surviving
pane IDs, with the semantic-degraded recovery rule above.

## 10. Distribution and maintenance

TACO targets Apple Silicon macOS and direct Developer ID distribution. Accessibility
window management is incompatible with the App Sandbox, so Mac App Store delivery
is out of scope. v1 distribution is a notarized release archive plus Homebrew cask.

Ghostty updates are explicit dependency upgrades: change the pinned commit, rebuild
the semantic patch, run compile/integration/performance gates, and record upstream
API changes. TACO never follows Ghostty `main` implicitly.

M0 first locks a benchmark methodology using the same Ghostty revision, config,
hardware, workload, and display refresh rate. The initial design targets are at most
10% direct-terminal regression and 20% tmux-bridge regression; any revised release
SLO must be recorded with measurements and rationale before later milestones begin.

## 11. Fixed decisions

| Area | Decision |
|---|---|
| License | AGPL-3.0-or-later plus separate trademark policy |
| Host | AppKit/SwiftUI with Rust core |
| Terminal | Full pinned `libghostty`, isolated behind one adapter |
| Editor | Neovim in terminal; optional externally tiled Zed |
| Agent | Native CLI for completeness; ACP for structured supported capabilities |
| Input | Reusable native `NSTextView`-based input surface |
| Blocks | OSC 133/ACP semantics plus bounded durable BlockStore |
| Multiplexer | TACO layout with tmux control-mode persistence |
| Remote | system SSH, remote tmux control mode, opaque Mosh |
| Plugins | none in v1; internal seams have no compatibility guarantee |
| Unsupported apps | always usable through normal PTY behavior |

## 12. Primary references

- [Ghostty full embedding header](https://github.com/ghostty-org/ghostty/blob/main/include/ghostty.h)
- [Ghostty VT screen semantics](https://github.com/ghostty-org/ghostty/blob/main/include/ghostty/vt/screen.h)
- [Agent Client Protocol v1](https://agentclientprotocol.com/protocol/v1/overview)
- [tmux control mode](https://github.com/tmux/tmux/wiki/Control-Mode)
- [Mosh technical description](https://mosh.org/#techinfo)
- [UniFFI user guide](https://mozilla.github.io/uniffi-rs/latest/)
- [macOS AXUIElement API](https://developer.apple.com/documentation/applicationservices/axuielement_h)
