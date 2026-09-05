# Teaser architecture

Status: design baseline; desktop-stage implementation in progress

Last updated: 2026-09-05

## 1. System boundary

Teaser is a native spatial development environment, not a new shell, editor,
browser, or agent model. Its primary unit of presentation is a complete,
project-scoped Workspace rather than a mutually exclusive project tab. Workspaces
can be tiled in parallel, focused, or switched as units while retaining their Panel
layouts and running content. A Workspace is one connected rectangular region, even
when its Panels are backed by windows owned by several applications.

```text
Teaser.app
├── DesktopStageController                     current-Space window orchestration
│   ├── WorkspacePresentation                  display → WorkspaceTree → PanelTree
│   ├── NotesWindowController                  Teaser-owned Notes
│   ├── ManagedExternalWindow                  exact provider-owned top-level window
│   ├── DesktopOverlayController               passive visuals + bounded hit windows
│   └── DesktopStageControlWindow              explicit start / stop / quit
├── TerminalSurfaceAdapter
│   └── pinned libghostty                      VT state + Metal + IME + selection
├── TerminalAttachmentPump                    bounded asynchronous data plane
│   └── AttachmentClient                       teaser.attach.v1 transport
└── low-frequency typed control

teaserd
├── SessionRegistry                            exact Session / Surface leases
├── PTY session workers                        child + master + replay + resize
├── control.sock                               JSON handshake → binary attach
├── TeaserCore                                 Rust, low-frequency UniFFI boundary
│   ├── WorkspaceStore / BlockStore            SQLite WAL
│   ├── ACP client                             Claude + Codex
│   ├── tmux control parser
│   ├── teaser-bridge                          tmux pane byte-stream helper
│   └── CLI IPC                                per-user Unix socket

teaser CLI                                     low-frequency control client
```

The host is macOS-first because AppKit already supplies the hard parts Teaser should
not rebuild: responder routing, text input and IME, Accessibility, drag and drop,
window lifecycle, and native view composition. A single opaque full-screen Teaser
window cannot contain live third-party windows. The desktop stage therefore uses
mutually non-overlapping top-level windows plus transparent overlay windows rather
than a visual container pretending to own every Panel.

## 2. Ownership and performance boundaries

Swift/AppKit owns live window and view lifetime, Workspace and Panel geometry,
presentation transitions, Virtual Focus, explicit Input Focus handoff, native
input, clipboard, image preview, adopted-window leases, arrangement overlays, and
Accessibility permission UX.

`teaserd` owns each Teaser Session's canonical child process, PTY master, attachment
lease, replay offsets, backend lifecycle, and eventual block state. Rust also owns
the authoritative persistent Project, Workspace, Panel, capability, ACP, tmux, CLI
IPC, and diagnostic state.

The in-progress Swift desktop-stage slice persists a typed presentation snapshot in
`~/Library/Application Support/Teaser` until the UniFFI-backed Workspace store
exists. It does not persist AX object references or treat a saved application hint
as live window identity. This is an implementation staging boundary, not a second
long-term source of Workspace truth.

Raw PTY output, keystrokes, pointer motion, IME composition, and render callbacks
must never cross UniFFI, JSON, or SQLite. A TerminalSurface attaches to one exact
Session through a bounded binary Unix-socket stream; JSON is used only for the
initial handshake. Swift sends only low-frequency model commands and semantic
events through the typed control boundary.

## 3. Terminal foundation

Teaser consumes the full Ghostty embedding API rather than implementing a second VT
renderer. Upstream's full surface currently owns its PTY together with terminal
state, renderer, input, selection, and platform surface. Teaser's architecture instead
requires `teaserd` to own the canonical PTY. The pinned Teaser patch now proves an
external-input/output surface mode with no `Exec`, PTY, or child state. This is a
narrow feasibility result, not a stable upstream API. The adapter therefore pins one
exact revision because Ghostty's header says the API is not yet general-purpose or
stable.

Initial baseline:

- Ghostty tag: `v1.3.1`
- commit: `332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28`
- source location: a pinned Git submodule under `vendor/ghostty`
- provenance and parent-owned Teaser patches: documented in `vendor/README.md`

The submodule remains clean. Teaser keeps narrow Zig experiments under
`patches/ghostty`; no workspace or agent behavior is implemented inside Ghostty.

The M0 spike must prove a clean-clone build, bundled runtime resources, AppKit
main-thread/lifetime rules, Ghostty tick/wakeup handling, IME, 120 Hz drawing, and a
signed app bundle. It must also prove that externally supplied Session bytes can
drive the full surface and that surface input/resize can return to `teaserd` without a
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
Apple Silicon XCFramework builds and links. `app/macos/TeaserProbe` passes real
AppKit/Metal draw plumbing to a live `IOSurfaceLayer`, full-screen readback,
exact `probe\r` input forwarding, resize consistency, direct-child snapshots,
and ordered teardown. The source-level backend tests remain the authoritative
proof that no process or PTY state exists; the process snapshot is only
corroborating runtime evidence. This closes CP-M0.8, but not TASK-003's broader
clean-clone host, resources, IME, 120 Hz, and signed-bundle gates.

CP-M0.9 joins the previously separate proofs through the real attachment
protocol. A fixed, non-user-configurable `teaserd --probe-session` child owns the
PTY while `TerminalSurfaceAdapter` forwards Ghostty output, input, and resize
over `teaser.attach.v1`. The native probe verifies exclusive attachment, real
PTY output readback, resize observed by the child, synchronous input, detach
without child exit, bounded-offset offline replay, same-PID reattachment,
Metal draw plumbing, process exit, and ordered teardown. The probe Session is
created before `teaserd` accepts threaded IPC work, so this checkpoint does not
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

## 4. Workspace, Panel, and desktop-stage model

A Workspace is a persistent, project-scoped organization of Panels. Panels within
that Workspace may bind to different Checkouts of the same Project, but a Workspace
does not combine unrelated Projects. Multiple Workspaces keep unrelated project
contexts independently available for parallel presentation.

`WorkspacePresentation` is a two-level constrained slicing layout. Each display has
one `WorkspaceTree`; each Workspace leaf owns one `PanelTree`. Both trees partition
their parent rectangle exactly except for explicit gutters. This guarantees that a
Workspace is one connected rectangle, Panels do not overlap, and unequal Workspace
and Panel sizes can still fill the visible display. A Workspace has display affinity
and does not span displays; each display in the current Space is solved independently.

The persistent value model stores tree topology and user-requested split ratios.
Minimum sizes clamp the feasible ratio without overwriting the user's requested
ratio. Preferred aspect ranges currently contribute diagnostic quality metrics;
growth weights are stored intent, not allocation inputs yet. Automatic aesthetic
optimization remains planned. Manual divider movement is authoritative.
Presentation may tile Workspaces, temporarily enlarge one, or switch complete
Workspaces without recreating their Panel trees, content, or Session ownership.

A Panel is a stable spatial identity, not a view subclass. Its data-defined
`PanelKindDefinition` supplies a label and `LayoutProfile` containing minimum size,
preferred aspect-ratio range, and growth weight. Initial kinds are Task, CLI, App,
Agent, File, and Notes. Users may define more kinds and override a profile on one
Panel; a kind does not select an application, provider, protocol, or capability.

`PanelID`, a Panel binding, and `SurfaceID` are deliberately distinct. A binding is
replaceable and may be:

- Teaser-owned `PanelContent`, such as Notes, a `TerminalSurface`, structured agent
  detail, project detail, a diff, Quick Look content, or native input;
- one exact provider-owned external top-level window under a live
  `ManagedExternalWindow` lease; or
- empty, optionally retaining a provider hint for the user.

Built-in Teaser content uses a closed internal enum, not a plugin API. Extensible
Panel kinds change presentation metadata only. There is no dynamic loader, stable
ABI, WASM host, or third-party SDK in v1. Neovim remains a normal TUI inside a
terminal, and Notes is the only Teaser-owned content required by the real-window
showcase.

### 4.1 External-window adoption

Adoption is geometry orchestration, not embedding. The provider retains ownership
of rendering, input, accessibility, menus, tabs, process lifetime, and the top-level
window. Teaser never reparents the window, mirrors its pixels, synthesizes its
application input, or represents it as a Teaser Session or Surface.

After macOS grants the stably signed Teaser application Accessibility access once,
physically dragging a window into a Panel is the explicit selection action. A global
mouse monitor, button-state sampling, and front-to-back Core Graphics hit testing
with unique Accessibility correlation lock one
exact `(PID, window ID, AX element)` identity at drag start. Teaser recognizes the
gesture only after the same window's movement correlates with pointer movement, so
tab, file, text, and in-application drags do not become window adoptions.

During a qualified drag, a nonactivating click-through overlay exposes Panel targets.
Dropping on an empty Panel adopts it; dropping at an occupied Panel edge inserts a
local split; dropping a managed window on another empty Panel moves its binding.
An occupied center rejects an unmanaged window rather than silently replacing
content. Every successful adoption is one atomic layout transaction with single-step
Undo. On identity, feasibility, or frame verification failure, Teaser attempts
compensation for every affected window, reports incomplete rollback, and retains
failed restoration leases. This is best-effort orchestration, not an OS-atomic
multi-window transaction.

Only standard, unminimized, movable, resizable windows on the current Space are
eligible. Public macOS APIs cannot send an arbitrary provider window to a selected
Space, so Teaser fails closed across that boundary. Multiple visible displays are
supported. Display topology changes automatically redistribute whole Workspaces
and rebuild display trees deterministically; they do not preserve old display
split IDs or ratios. A Workspace never straddles displays.

Launching opens a normal closable control window. Only explicit Start Layout
creates the desktop stage, after Accessibility authorization. Stop Layout and
Control-Option-Escape immediately remove Teaser chrome and Notes before releasing
provider leases. Switching Space stops the stage; overlays do not join every Space
or full-screen application. The display-sized visual window always ignores mouse
events; only bounded labels and divider handles intercept input in Arrange mode.

The live AX identity and pre-adoption frame are ephemeral. Graceful release restores
the original frame only while the exact window still exists and remains at the frame
last applied by Teaser. Persistence retains layout and a non-authoritative provider
hint, not PID, window ID, or AX references. After Teaser or the provider restarts,
the Panel remains empty and requires another physical drag; Teaser never guesses a
replacement by title, repository path, or application name.

### 4.2 Virtual and input focus

`VirtualFocus` is Teaser's persistent Workspace and Panel selection for navigation,
split, resize, focus, and arrangement commands. Moving it or changing Workspace
presentation does not activate another application. It is drawn independently of
the macOS key-window state.

`InputFocus` is the operating system's actual keyboard destination. A direct click,
double-click, or explicit focus action such as Control-Option-Return transfers it to the virtually
focused Panel. For an external binding, the bridge focuses that exact AX window and
activates only as required; it does not request that every window of the provider be
raised. Clicking an adopted window also synchronizes Virtual Focus to its Panel.

Teaser cannot deliver ordinary keyboard input to an inactive provider window without
event injection or private behavior, so it does not attempt to virtualize Input
Focus. Workspace enlargement and switching do not deliberately hand it to another
Panel; macOS may still choose a new key window if the current provider closes or
hides its own window.

Control-Option-Z invokes layout Undo while Arrange is active. Command-Z is never
observed as a layout command because a passive global monitor cannot consume it
without also delivering Undo to the provider.

## 5. Capability model

Every session advertises a `CapabilitySet`; UI actions appear only when the backing
session can honor them.

| Tier | Integration | Guaranteed behavior |
|---|---|---|
| 0 | Legacy CLI/TUI | Normal PTY rendering and input |
| 1 | Shell-aware | OSC 133 command semantics and OSC 7 cwd |
| 2 | Adapter-assisted | ACP, tmux control mode, or application RPC |
| 3 | Native Teaser surface | Typed actions, resources, and native presentation |

Alternate-screen applications remain opaque. Teaser never infers fake blocks from a
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
API does not expose enough range lifecycle information for Teaser, so M0 attempts a
narrow API extension for semantic-zone lifecycle, opaque range handles, text reads,
and eviction notification. Teaser assigns stable block IDs and persists completed
payloads in SQLite at
`~/Library/Application Support/Teaser/workspaces/<workspace-id>.sqlite`.

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

Search defaults are local: `Cmd-F` searches the virtually focused Panel and
`Cmd-Shift-F` searches the current Workspace. There is no default all-Workspaces
search.

## 7. Agent sessions and input

ACP is an optional agent semantic/control plane. Teaser implements an ACP client and
starts pinned Claude and Codex ACP adapters as supervised subprocesses. Protocol
version and capabilities are negotiated at runtime; Teaser does not infer wire
compatibility from a crate/package version. ACP events become blocks while vendor
`_meta` fields are retained for lossless round-tripping.

Structured public commands are:

```text
teaser agent claude [--cwd PATH]
teaser agent codex  [--cwd PATH]
```

This mode exposes only adapter-supported capabilities and is not equivalent to the
full vendor CLI. Existing `claude` and `codex` commands remain untouched and can
always run in a normal TerminalSurface for complete vendor behavior.

Agent input uses the same host-owned `InputView` available to other workflows.
It supports multiline text, native text services, file/image attachments, and typed
approval or question interactions. The completed value is submitted to ACP as one
operation; the agent adapter never handles per-keystroke editing.

ACP does not replace PTY, LSP, DAP, workspace, or multiplexer protocols.

## 8. Multiplexing and remote sessions

Teaser owns visible layout. Every Teaser-owned Session passes through `teaserd`, even
when it has only one Surface. This means lifecycle and byte-stream multiplexing,
not simultaneous mirroring: a Session has at most one live Surface lease.

The direct Session path is:

```text
child process ↔ PTY slave
                 ↕
teaserd PTY master → bounded replay / absolute offsets
                 ↕ teaser.attach.v1
TerminalSurfaceAdapter ↔ pinned libghostty external transport gate
```

tmux remains a future persistence backend through documented control mode. Its
helper must sit behind the same Session abstraction and report `SIGWINCH`, arbitrary
bytes, backpressure, `%pause/%continue`, and `capture-pane` repair without sending
terminal bytes through UniFFI.

Remote modes are intentionally distinct:

- `ssh_command`: system `ssh` runs inside a normal terminal surface;
- `ssh_tmux_control`: system `ssh` transports tmux control mode to TeaserCore;
- `mosh_opaque`: `mosh` runs inside a normal terminal surface.

SSH control mode initially supports preconfigured host keys and key/agent
authentication. Password, MFA, and first-host-key prompts require a separate
bootstrap UI so they cannot corrupt the control stream.

If Teaser disconnects from tmux, `capture-pane` can restore visible text but cannot
reconstruct missed OSC 133 lifecycles or exit status. Recovered text is marked
semantic-degraded rather than converted into authoritative historical blocks. Teaser
also supplies its own UI for tmux modes that control mode does not render.

Mosh synchronizes terminal state rather than providing a transparent byte stream,
so Teaser does not carry tmux control semantics through it. Mosh handles network
roaming only while the owning `teaserd` PTY remains alive; a daemon crash/restart
terminates that Mosh session. Running `tmux attach` inside Mosh remains usable but
opaque.

## 9. CLI and persistence

The following CLI and backend-history behavior is a v1 target, not implemented by
the desktop-stage prototype. Current persistence contains presentation and Notes
only, with no live external-window identities.

The planned Rust `teaser` CLI connects to
`~/Library/Application Support/Teaser/runtime/control.sock`. The app creates the
parent directory with user-only access and the socket with mode `0600`. If the
socket is absent, the CLI launches `Teaser.app`, waits for readiness with a bounded
retry, and sends a versioned request.

Planned v1 commands:

```text
teaser
teaser shell [--cwd PATH]
teaser agent <claude|codex> [--cwd PATH]
teaser open <PATH>
```

Workspace persistence includes display affinity, Workspace and Panel trees,
requested split ratios, Virtual Focus, Panel kinds and profiles, Notes, bounded
block history, resources, and Teaser backend identity. An external-window binding
persists only an empty-slot provider hint and must be re-established by dragging the
window again. Direct PTYs survive Surface or GUI disconnection while their owning
`teaserd` process remains alive, but cannot survive daemon termination and restore
as terminated placeholders. tmux-backed sessions reconnect to surviving pane IDs,
with the semantic-degraded recovery rule above.

## 10. Distribution and maintenance

Teaser targets Apple Silicon macOS and direct Developer ID distribution.
Accessibility window management is incompatible with the App Sandbox, so Mac App
Store delivery is out of scope. A stable signature lets macOS retain one Teaser
Accessibility decision; Teaser does not maintain a per-application authorization
list. v1 distribution is a notarized release archive plus Homebrew cask.

Ghostty updates are explicit dependency upgrades: change the pinned commit, rebuild
the semantic patch, run compile/integration/performance gates, and record upstream
API changes. Teaser never follows Ghostty `main` implicitly.

M0 first locks a benchmark methodology using the same Ghostty revision, config,
hardware, workload, and display refresh rate. The initial design targets are at most
10% direct-terminal regression and 20% tmux-bridge regression; any revised release
SLO must be recorded with measurements and rationale before later milestones begin.

## 11. Fixed decisions

| Area | Decision |
|---|---|
| License | AGPL-3.0-or-later plus separate trademark policy |
| Host | AppKit/SwiftUI with Rust core |
| Desktop stage | Provider-owned top-level windows plus Teaser-owned windows and overlays |
| Workspace | One connected rectangle; multiple Workspaces may tile, focus, or switch |
| Panel | Stable region; identity is separate from kind, binding, and Surface |
| Layout | Per-display WorkspaceTree containing one PanelTree per Workspace |
| Focus | Virtual Focus is independent from explicit macOS Input Focus |
| Terminal | Full pinned `libghostty`, isolated behind one adapter |
| External apps | Exact current-Space window leases through public AX APIs |
| Editor | Neovim in terminal or an adopted provider-owned editor window |
| Agent | Native CLI for completeness; ACP for structured supported capabilities |
| Input | Reusable native `NSTextView`-based input surface |
| Blocks | OSC 133/ACP semantics plus bounded durable BlockStore |
| Multiplexer | Teaser layout with tmux control-mode persistence |
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
- [AppKit global event monitoring](https://developer.apple.com/documentation/appkit/nsevent/addglobalmonitorforevents%28matching%3Ahandler%3A%29)
- [Core Graphics window list](https://developer.apple.com/documentation/coregraphics/cgwindowlistcopywindowinfo%28_%3A_%3A%29)
