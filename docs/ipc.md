# Teaser control and client protocol

## Current boundary

The active runtime is the Herdr fork in `runtime/herdr`. Its protocol implementation
is in `src/api` and `src/protocol`; the pinned schema is
[`herdr-api.schema.json`](../runtime/herdr/docs/next/api/herdr-api.schema.json).
The retained native App is not yet connected to it.

Use the inherited JSON control/event API and negotiated client endpoint. The JSON
socket uses newline-delimited messages; the client endpoint negotiates codecs and
capabilities. Its stable endpoint does not require matching builds; private binary
operations must not be assumed compatible across builds. See the pinned
[API documentation](../runtime/herdr/docs/next/website/src/content/docs/socket-api.mdx).

`teaser.attach.v1` is not the Herdr protocol. The superseded protocol is archived
with its implementation under
[`prototypes/attachment-runtime`](../prototypes/attachment-runtime/docs/ipc.md).
There is no compatibility bridge or silent fallback to that daemon.

## Required integration contract

- The server owns membership, task references, and sessions. App/TUI issue typed
  commands and consume snapshots/events.
- Client and object IDs are explicit. Paths, titles, active tabs, and macOS Spaces
  are not object identities.
- Viewport and focus remain local. Terminal resize ownership is arbitrated, not
  whichever client's redraw loop runs last.
- New commands advertise capabilities. Missing capability, rejection, stale
  state, and disconnect are explicit; clients cannot report success before apply.
- The native host owns AX/CG leases. Do not serialize handles or stale PID/window
  identities as durable bindings.
- Bootstrap, event sequencing, reconnect, and persistence converge on the same
  state without replaying uncertain terminal input.
- Preserve endpoint contracts; negotiate new codecs/methods when needed.

Teaser extensions and native transport are implementation work, not a shipped
API. Runtime namespace and update-endpoint isolation precede installation or use
against personal Herdr sessions.
