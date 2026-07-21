# TACO Context

TACO coordinates concurrent software work across multiple projects while keeping
the concrete environments used by terminals, agents, and external tools explicit.

## Language

**Project**:
A durable, named body of work that may contain one or more checkouts.
_Avoid_: Repository, working directory, worktree

**Checkout**:
A concrete filesystem working copy or worktree through which terminals, agents,
attached surfaces, and federated panels operate.
_Avoid_: Project, workspace

**Workspace**:
A saved arrangement of selected projects and checkouts that may span multiple
projects. A project may appear in more than one workspace.
_Avoid_: Project, all-project catalog

## Sessions and presentation

**tacod**:
The long-lived TACO runtime that owns sessions independently of any user interface.
_Avoid_: TACO app, terminal emulator, attached surface

**Session**:
An authoritative unit of interactive work maintained by tacod, attached to one
checkout, and presented by at most one attached surface at a time.
_Avoid_: Panel, window, terminal tab

**Multiplexing**:
Maintaining multiple independent sessions in tacod while routing each session to
zero or one attached surface without transferring session ownership.
_Avoid_: Simultaneous session mirroring, window tiling, duplicated session

**Attached Surface**:
A user interface actively connected to a TACO session for interaction and state.
It may be owned by TACO or presented by an external application.
_Avoid_: External panel, tiled window

**Federated Panel**:
An external project environment connected to TACO through a structured adapter
while retaining ownership of its internal sessions, terminals, and layout.
_Avoid_: Attached surface, companion window, embedded application

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
TACO session or structured TACO adapter.
_Avoid_: Attached surface, federated panel
