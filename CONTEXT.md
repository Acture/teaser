# Teaser terminology

These are target product contracts. The imported runtime and retained native
prototype do not yet implement every contract; see `docs/architecture.md`.

## Organization

**Project**: A durable body of work, optionally associated with several checkouts.

**Checkout**: A concrete working copy or worktree, not a Workspace identity.

**Workspace**: A persistent, project-scoped logical group of Panels. Membership
does not depend on one canvas, display, macOS Space, terminal tab, or active
client. Closing a view does not delete the Workspace or terminate its sessions.

**Task reference**: A provider-qualified task identity with cached display data
and context links. The external provider owns task content/status; Teaser owns
associations to Workspaces, Panels, and sessions. A cache is not a task authority.

**Panel**: A content-neutral region with stable identity and Workspace membership.
It can be empty, host terminal/agent/Notes content, or refer to an app, file, or
task provider. A Panel is not a Session or native window.

**Panel kind/profile**: Data describing intent, minimum dimensions, preferred
aspect ratio, and growth priority. Task, CLI, App, Agent, File, and Notes are
predefined; users can add kinds and override Panels. Client adapters interpret
units: terminal cells and native pixels are not interchangeable.

**Panel binding**: Association to a session, task/file reference, Teaser-owned
content, or one exact adopted window. Changing a binding preserves Panel identity.

## Presentation

**Canvas**: A client-owned presentation surface. Each native CanvasWindow can
enter macOS native fullscreen. A TUI viewport is another presentation surface,
not a container capable of embedding arbitrary external GUI windows.

**Placement**: A Panel's position in a presentation and layout tree. Moving across
canvases does not implicitly change Workspace membership.

**Workspace contour**: The same-colored outer boundary of locally adjacent
members, derived from solved Panel rectangles. Separate fragments use the same
group identity/color; an enclosed other-group Panel is a stroked hole. It is not
a background, title bar, or mandatory rectangular container, and a canvas
showing one group draws none: there is nothing to tell apart.

**Layout**: Unequal tiling, split, move, resize, focus, and undo. One flat Panel
tree per canvas: a Workspace is a label on its Panels, never a region. A split
nobody has dragged is sized from its Panels' growth weights; a dragged one keeps
the proportion the person chose. Group adjacency is a soft preference applied
only to a Panel with no placement yet. Topology and constraints can be shared;
native pixel and TUI cell rectangles are computed by their respective adapters.

**Virtual Focus**: A client's selected Panel for layout commands. It does not
redirect another client's focus or native app input.

**Canvas focus**: One canvas emphasising one group, in two stages: weighted
larger and raised, then exclusive, which minimizes the other groups' adopted
windows because macOS offers no way to lower them. It prunes the solve, never
the stored tree, so clearing it restores the canvas exactly, and it can only
emphasise a group the canvas already holds.

**Input Focus**: The real input destination. External-app handoff requires an
explicit action to an exact window; Teaser does not synthesize background input.

## Runtime and clients

**Core**: The shared library of identities, membership, task associations,
commands, and transitions in `crates/teaser-core`. Its current model includes
Panel size preferences; shared placement intent remains planned. It does not
depend on AppKit, SwiftUI, Ratatui rectangles, PTYs, or network clients.

**Server**: The Herdr-derived authoritative session runtime. It applies core
commands and publishes snapshots/events. Sharing code does not justify independent
mutable organization stores in App and TUI.

**Session**: Interactive work owned by the server, separate from Panel placement.
Client detach is not server termination; persistence does not imply original
process survival after the server or machine restarts.

**Client**: TUI, CLI, or native App using server commands and state. Viewport,
interaction state, and focus are client-local. Session-size ownership must be
explicit when several clients observe one terminal.

**Adopted external window**: A provider-owned top-level macOS window bound by exact
runtime identity. The App owns the live AX/CG lease; the server may hold a provider
hint, never an AX object or authoritative stale PID/window ID. Adoption is not
reparenting, capture, or a server-owned terminal Session.

**Retired attachment runtime**: The old `teaserd` / `teaser.attach.v1` experiment in
`prototypes/attachment-runtime`. Those names do not describe Herdr's protocol and
must not become compatibility aliases for it.
