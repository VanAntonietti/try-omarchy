# Omarchy Link guest scaffold

This is the proposed compiled guest broker/CLI. It currently contains the shared v1 frame codec, a typed fake-data request peer with Link Session negotiation, and a placeholder multicall command. It is not installed into the factory image and cannot access host data.

The dependency graph is exact-version locked and vendored. Tests therefore run without network access:

```sh
cd guest/omarchy-link
cargo fmt --check
cargo test --locked --offline
```

The integration tests consume `protocol/omarchy-link/v1/golden-frames.json` and `handshake-fixtures.json`, the same fixtures as the Swift host tests. The fake Swift host derives its allow-listed Capabilities from fixture Service Modes; the Rust guest accepts compatible additive v1 responses and treats typed incompatibility as Link-only unavailability. `GuestPeer` adds correlated Calendar-list results/errors, cancellation, and content-free Invalidations. See the [wire contract and resource bounds](../../protocol/omarchy-link/v1/README.md).

The normal `make test` entry point runs these Rust tests offline alongside Swift tests. `OmarchyLinkLoopbackTests` starts `cargo run --locked --offline --example fake-peer` and exchanges actual framed bytes over anonymous pipes with the Swift fake host, under a 30-second deadline. The example is a test harness, not a supported CLI mode; its stdin/stdout must be connected to that harness. Socket ownership, the daemon, VM transport, and real Mac Service adapters remain unimplemented.

To refresh dependencies deliberately, update the exact versions in `Cargo.toml`, review `Cargo.lock` and every source/license change, then run:

```sh
cargo vendor --locked vendor > .cargo/config.toml
```
