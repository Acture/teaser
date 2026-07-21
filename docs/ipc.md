# Local Control Protocol

`tacod` currently accepts one newline-terminated JSON request per Unix socket
connection and returns one newline-terminated JSON response. Start the foreground
prototype with the standard per-user runtime directory:

```fish
cargo run -p tacod
```

For an isolated development run, pass `--runtime-dir PATH`. The runtime directory,
permanent lock file, and `control.sock` use modes `0700`, `0600`, and `0600`.
Only one daemon may own a runtime directory. After a crash, the next owner removes
a confirmed stale socket, but preserves regular files, symlinks, and live sockets.

The only supported request creates a detached Session for an explicit Checkout:

```json
{"version":1,"request_id":41,"method":"session.create","checkout_id":7}
```

A successful response preserves the request identity:

```json
{"version":1,"request_id":41,"status":"ok","session_id":"550e8400-e29b-41d4-a716-446655440000"}
```

The protocol rejects unknown versions, methods, missing parameters, malformed
JSON, and payloads larger than 16 KiB without mutating Session state. The socket
is mode `0600`, and a client has five seconds to read or write one frame.

This is deliberately not a stable public protocol yet. Session IDs are opaque,
collision-resistant UUIDs, but Session state is still memory-only and Checkout IDs
are not validated against a catalog. PTY spawning, persistence, attachment IPC,
and Federated Panels remain out of this interface.
