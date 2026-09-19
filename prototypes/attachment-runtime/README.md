# Retired attachment-runtime prototype

This is the pre-Herdr `teaser-core` / `teaserd` experiment, preserved with its
tests and wire-format documentation. It is an independent Cargo workspace,
excluded from Teaser's production workspace. Do not add new product behavior here
or start it alongside Herdr as a second session authority.

The native Ghostty attachment probe still uses this protocol. Its Swift transport
tests remain useful historical coverage, not proof of Herdr/App integration.
The existing macOS canvas does not become a Herdr client merely by importing the
fork.

For deliberate maintenance of this prototype only, from the repository root:

```fish
cargo +1.94.0 test --manifest-path prototypes/attachment-runtime/Cargo.toml --locked
```

Run the native GUI probe only in an explicitly authorized desktop environment.
See [its protocol](docs/ipc.md) and [the probe instructions](../../vendor/README.md).
Remove the superseded runtime and attachment adapters once the App's replacement
transport is integrated; do not carry a compatibility daemon into a release.
