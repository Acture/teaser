# Teaser Context

Teaser composes multiple project Workspaces across visible displays while keeping
their Panel layouts, running content, and concrete execution environments explicit.

## Language

**Project**:
A durable, named body of work that may contain one or more checkouts.
_Avoid_: Repository, working directory, worktree

**Checkout**:
A concrete filesystem working copy or worktree through which terminals, agents,
attached surfaces, and federated environments operate.
_Avoid_: Project, workspace

**Workspace**:
A persistent, project-scoped organization and display of Panels. A Workspace may
use multiple Checkouts from its Project, and retains its Panel layout and running
content while tiled, focused, hidden, or restored.
_Avoid_: Panel, tab, all-project catalog

**Workspace Presentation**:
The persistent, two-level rectangular arrangement of one or more Workspaces on
displays and Panels inside each Workspace. It can tile Workspaces in parallel,
focus one Workspace, or switch complete Workspaces without rebuilding their
internal Panel layouts.
_Avoid_: Workspace, project tab bar

**Panel**:
A content-neutral display region inside one Workspace. A Panel may show agent
execution, project details, a terminal, a file, a diff, an image, input, or another
built-in content type, or bind to one provider-owned external window. It remains a
Panel while empty or unbound.
_Avoid_: Workspace, Project, Session, terminal tab

**Panel Kind**:
A data-defined label and layout profile for a Panel. Built-in kinds are Task, CLI,
App, Agent, File, and Notes; users may define more. A kind supplies layout intent,
not a Swift subclass, provider, capability, or content implementation.
_Avoid_: Panel subclass, application type, integration API

**Panel Binding**:
The replaceable association between a Panel and either Teaser-owned content or one
adopted external window. Layout identity remains stable when the binding disappears.
_Avoid_: Panel, Session, embedding

**Desktop Stage**:
The AppKit runtime that realizes Workspace Presentation using Teaser-owned windows,
provider-owned external windows, and temporary click-through arrangement overlays.
_Avoid_: full-screen container window, screen capture, window manager

**Focused Workspace**:
The Workspace containing Virtual Focus and therefore receiving Workspace-level
commands. Focusing it may enlarge or isolate its presentation, but does not destroy
or recreate sibling Workspaces and does not itself request an Input Focus transfer.
_Avoid_: only visible project, selected tab

**Virtual Focus**:
Teaser's persistent selection of one Workspace and Panel for navigation, split,
resize, and layout commands. It can move without activating another application or
changing the operating system's keyboard target.
_Avoid_: key window, first responder, Input Focus

**Input Focus**:
The macOS window and responder currently receiving ordinary keyboard input. Teaser
hands it to a virtually focused Panel only after an explicit click, double-click, or
focus action; layout navigation alone does not transfer it.
_Avoid_: Virtual Focus, selected Panel

## Sessions and presentation

**teaserd**:
The long-lived Teaser runtime that owns sessions independently of any user interface.
_Avoid_: Teaser app, terminal emulator, attached surface

**Session**:
An authoritative unit of interactive work maintained by teaserd, attached to one
checkout, and presented by at most one attached surface at a time.
_Avoid_: Panel, Workspace, window

**Multiplexing**:
Maintaining multiple independent sessions in teaserd while routing each session to
zero or one attached surface without transferring session ownership.
_Avoid_: Simultaneous session mirroring, window tiling, duplicated session

**Attached Surface**:
A user interface actively connected to one exact Teaser Session for interaction and
state. It may be Teaser-owned or an explicit protocol-capable external client; an
arbitrary adopted window is not a Surface.
_Avoid_: adopted external window, Panel, tiled window

**Federated Environment**:
An external project environment connected to Teaser through a structured adapter
while retaining ownership of its internal sessions, terminals, and layout.
_Avoid_: Panel, attached surface, companion window, embedded application

**Attachment**:
The association of one attached surface with one exact session, established using
system-managed identity rather than inferred from a checkout path.
_Avoid_: Manual attach command, cwd matching

**Adopted External Window**:
A standard provider-owned top-level window whose exact runtime identity and frame
are leased to one Panel after the user physically drags it there. Adoption manages
geometry only: it is not reparenting, pixel capture, input forwarding, a Surface, or
a Teaser Session. The binding is not guessed or silently recreated after restart.
_Avoid_: embedded application, companion window, captured Panel
