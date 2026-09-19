# Teaser delivery outcomes

Linear owns active milestones, issues, dependencies, and status. This file defines
exit contracts, not a second tracker. Work can proceed concurrently across stable
interfaces; no separate feasibility ticket blocks implementation.

## Fork foundation

Establish a history-preserving Herdr server/TUI source fork and retain the native
App. Root Cargo resolves only the selected runtime, licenses/provenance remain
intact, and old self-built PTY code is outside the active workspace. Importing
source does not prove compilation, client integration, or desktop acceptance.

## Shared organization across clients

Extract pure Project/Workspace/TaskRef/Panel organization and layout intent. The
server applies commands and publishes authoritative snapshots/events. TUI and
App refer to the same IDs and relationships, with local viewport and focus.

Exit: either client can create/move/regroup a Panel and the other observes the
committed result without recreating its session. Disconnect/reconnect converges;
two clients do not fight over PTY size. Inherited terminal behavior stays usable.

## Task-driven spatial Demo

Demo is a milestone, not another duplicate feature ticket. Video work follows an
operable product path.

Exit:

- One `Teaser.app` has multiple independent native-fullscreen canvases.
- Workspace membership spans canvases; a canvas can contain several Workspaces.
  Unequal Panels tile with group contours and adjustable adjacency.
- A task-provider reference leads to its existing terminal/agent/app context.
  App and TUI use the same task associations and organization authority.
- Real external apps can be selected, adopted, resized, used with native input,
  and safely released; fake provider UIs are not substitutes.
- Closing one canvas is local. Restart, display changes, and reconnect preserve
  logical context without guessing replacement external windows.
- Native desktop behavior is explicitly exercised in an authorized environment;
  unrun scenarios are not claimed as passed.

## Distribution and daily use

Isolate Teaser executable/config/socket/session and integration identity from an
installed Herdr. Disable or replace upstream installers/updaters before shipping.
Package one native App with its actual runtime notices and source obligations.
Finish signing/notarization, recovery, resource limits, accessibility, and release
automation under Teaser ownership. No implicit upstream release publishing.

## Deferred

Native Windows App, custom terminal renderer, replacement task databases, GUI
reparenting/capture proxies, and custom roaming infrastructure are not prerequisites
for this demo. Inherited cross-platform runtime capability is not evidence of a
completed cross-platform Teaser App.
