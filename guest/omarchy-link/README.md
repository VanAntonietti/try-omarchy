# Omarchy Link guest scaffold

This is the proposed compiled guest broker/CLI. It currently contains only the shared v1 frame codec and a placeholder multicall command; it is not installed into the factory image and cannot access host data.

The dependency graph is exact-version locked and vendored. Tests therefore run without network access:

```sh
cd guest/omarchy-link
cargo fmt --check
cargo test --locked --offline
```

The integration test consumes `protocol/omarchy-link/v1/golden-frames.json`, the same fixture as the Swift host test. The bounded Calendar spike will add session negotiation, capability policy, socket ownership, and fake adapters before any real virtio or Apple-service access is connected.

To refresh dependencies deliberately, update the exact versions in `Cargo.toml`, review `Cargo.lock` and every source/license change, then run:

```sh
cargo vendor --locked vendor > .cargo/config.toml
```
