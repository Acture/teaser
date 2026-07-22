# Local Control and Attachment Protocol

`tacod` listens on
`~/Library/Application Support/TACO/runtime/control.sock`. The runtime
directory, permanent lock file, and socket use modes `0700`, `0600`, and
`0600`. One daemon owns a runtime directory; a later owner removes only a
confirmed stale socket.

Start the foreground prototype with:

```fish
cargo run -p tacod
```

Use `--runtime-dir PATH` only for isolated development and tests.

## JSON control handshake

Every connection begins with one newline-terminated JSON request of at most
16 KiB. `session.create` still creates metadata only because no Checkout
catalog resolves a trusted program or working directory yet:

```json
{"version":1,"request_id":41,"method":"session.create","checkout_id":7}
```

```json
{"version":1,"request_id":41,"status":"ok","session_id":"550e8400-e29b-41d4-a716-446655440000"}
```

Internally resolved PTY Sessions may be attached by exact Session and Surface
identity. The GUI will issue this request; users do not type an attach command.

```json
{"version":1,"request_id":42,"method":"session.attach","session_id":"550e8400-e29b-41d4-a716-446655440000","surface_id":11,"next_offset":0}
```

On success, the same socket upgrades after the response newline:

```json
{"version":1,"request_id":42,"status":"ok","session_id":"550e8400-e29b-41d4-a716-446655440000","upgrade":"taco.attach.v1","replay_from":0,"live_offset":0,"max_frame_payload_bytes":65536}
```

Only one live attachment lease may own a Session, even if a second connection
repeats the same Surface ID. EOF, malformed binary input, or transport failure
releases that lease without terminating the child.

## Binary attachment stream

After upgrade, each frame is `kind:u8 | payload_length:u32 BE | payload`.
Payload length is checked before allocation and cannot exceed 65,536 bytes.

| Direction | Kind | Payload |
|---|---:|---|
| Surface → daemon | `0x01` | raw PTY input bytes |
| Surface → daemon | `0x02` | rows, columns, pixel width, pixel height as four `u16 BE` values |
| Daemon → surface | `0x81` | absolute `u64 BE` offset followed by output bytes |
| Daemon → surface | `0x82` | requested and oldest retained offsets as two `u64 BE` values |
| Daemon → surface | `0x83` | process exit code as `u32 BE` |

Output offsets are monotonic. A reattaching Surface supplies its next unread
offset and receives only missing retained bytes. If that offset was evicted,
`0x82` reports the gap before replay starts at the oldest retained byte.

This protocol is not stable yet. Arbitrary `argv` and `cwd` are deliberately
absent, Session state is memory-only, and the foreground binary cannot create a
PTY Session until the Checkout resolver exists.

## Verification

```fish
fish scripts/check.fish
```

The integration test uses a real macOS PTY and Unix socket to prove exclusive
attach, detach-time output replay, unchanged child PID, resize, exit, and an
explicit replay gap.
