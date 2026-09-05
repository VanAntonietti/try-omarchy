# Omarchy Link guest scaffold

This is the proposed compiled guest broker/CLI. It currently contains the shared v1 frame codec, a fake Link Session handshake peer, and a placeholder multicall command. It is not installed into the factory image and cannot access host data.

The dependency graph is exact-version locked and vendored. Tests therefore run without network access:

```sh
cd guest/omarchy-link
cargo fmt --check
cargo test --locked --offline
```

The integration tests consume `protocol/omarchy-link/v1/golden-frames.json` and `handshake-fixtures.json`, the same fixtures as the Swift host tests. The fake Swift host derives its allow-listed Capabilities from fixture Service Modes; the Rust guest accepts compatible additive v1 responses and treats typed incompatibility as Link-only unavailability. Socket ownership and fake Mac Service adapters still come before any real virtio or Apple-service access is connected.

To refresh dependencies deliberately, update the exact versions in `Cargo.toml`, review `Cargo.lock` and every source/license change, then run:

```sh
cargo vendor --locked vendor > .cargo/config.toml
```
