# Teaser control and client protocol

## Current boundary

The active runtime is the Herdr fork in `runtime/herdr`. Its protocol implementation
is in `src/api` and `src/protocol`; the pinned schema is
[`herdr-api.schema.json`](../runtime/herdr/docs/next/api/herdr-api.schema.json).
The native App uses its JSON organization extension through an explicit endpoint.
Interactive terminal attachment is not implemented by that connection.

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

## Organization extension

The native integration slice adds a JSON-only organization boundary to the
existing server. It does not change the frozen TUI endpoint codecs. A client
discovers support by requesting `teaser.organization.snapshot`; an unsupported
method is a visible connection outcome, not permission to use the retired daemon.

Both `teaser.organization.snapshot` and `teaser.organization.apply` return:

```json
{
  "id": "request-id",
  "result": {
    "type": "teaser_organization_snapshot",
    "snapshot": {
      "revision": 0,
      "projects": [],
      "workspaces": [],
      "panels": []
    }
  }
}
```

Apply takes `expected_revision` and a nonempty `commands` array. Commands are
tagged by `type`; the entire batch validates and commits atomically, advancing
the revision once. A stale revision returns `revision_conflict` without mutation.
Rejections use the existing `{id, error: {code, message}}` response shape. The
core's types define the command and model fields; the generated Herdr JSON schema
includes the extension.

Subscribe with `events.subscribe` and
`subscriptions: [{"type": "teaser.organization.updated"}]`. The normal
`subscription_started` acknowledgement precedes updates. Subscribing dedicates
that socket to the event stream; issue snapshot/apply requests on separate
request connections after receiving the acknowledgement. Each update contains
the full authoritative snapshot under `data.snapshot`, with event name
`teaser.organization.updated` and data type `teaser_organization_updated`.
Subscribe before requesting the initial snapshot. Reconcile by revision rather
than applying an older buffered event or delayed response over a newer snapshot.
Reconnect obtains a new snapshot and never replays uncertain writes.

The organization contains Projects, project-scoped Workspaces and content-neutral
Panels. Panel identity, kind, size profile, and binding are separate. A terminal
binding references an existing Herdr pane; App and Notes bindings do not spawn
PTYs. Provider ownership and live AX/CG identities remain outside the core.
Deleting a logical Panel does not close its application or terminal session.

Inherited Herdr workspace/tab containers still organize terminal runtime objects;
they are not the authority for Teaser logical group membership. The richer TUI
projection is a separate integration step. This API must not be presented as an
interactive native terminal attachment protocol.

Organization snapshots are bounded to 1 MiB at the server boundary. Core limits
include 4,096 objects, 256 commands per batch, 128-byte identifiers, and
4,096-byte text fields. Clients also bound frames, pending replies and event
buffers before decoding or caching them.

Text validation rejects Unicode control category Cc, not formatting scalars such
as the zero-width joiner in emoji. Blankness uses Unicode whitespace. Notes
document references retain exact UTF-8 identity: canonically equivalent spellings
are not interchangeable keys, and clients must not normalize or alias them.

Native connections are explicit; no endpoint discovery or server startup occurs
on application launch. Runtime namespace and update-endpoint isolation still
precede installation or use against personal Herdr sessions. This extension does
not prove native full-screen/window-adoption acceptance.
