# Teaser Context

Teaser composes multiple project Workspaces on one screen while keeping their Panel
layouts, running content, and concrete execution environments explicit.

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
The screen-level arrangement of one or more Workspaces. It can tile Workspaces in
parallel, focus one Workspace, or switch complete Workspaces without rebuilding
their internal Panel layouts.
_Avoid_: Workspace, project tab bar

**Panel**:
A content-neutral display region inside one Workspace. A Panel may show agent
execution, project details, a terminal, a file, a diff, an image, input, or another
built-in content type.
_Avoid_: Workspace, Project, Session, terminal tab

**Focused Workspace**:
The Workspace currently receiving Workspace-level commands. Focusing it may enlarge
or isolate its presentation, but does not destroy or recreate sibling Workspaces.
_Avoid_: only visible project, selected tab

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
A user interface actively connected to a Teaser session for interaction and state.
It may be owned by Teaser or presented by an external application.
_Avoid_: External panel, tiled window

**Federated Environment**:
An external project environment connected to Teaser through a structured adapter
while retaining ownership of its internal sessions, terminals, and layout.
_Avoid_: Panel, attached surface, companion window, embedded application

**Focused Surface**:
The attached surface currently holding local operating-system keyboard focus. It
alone forwards ordinary local user input to its session.
_Avoid_: Controller surface, primary client

**Attachment**:
The association of one attached surface with one exact session, established using
system-managed identity rather than inferred from a checkout path.
_Avoid_: Manual attach command, cwd matching

**Companion Window**:
An external application window associated with a checkout but not connected to a
Teaser session or structured Teaser adapter.
_Avoid_: Panel, attached surface, federated environment
