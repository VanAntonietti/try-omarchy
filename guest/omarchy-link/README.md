# Omarchy Link guest scaffold

This is the proposed compiled guest broker/CLI. It contains the shared v1 frame codec, typed fake-data request peer with Link Session negotiation, an invented Calendar agenda model, and a development-only Calendar Mutation Proposal Review Interlock. It cannot access host data. The daemon and production `call` command remain placeholders.

The dependency graph is exact-version locked and vendored. Tests therefore run without network access:

```sh
cd guest/omarchy-link
cargo fmt --check
cargo test --locked --offline
```

The integration tests consume `protocol/omarchy-link/v1/golden-frames.json` and `handshake-fixtures.json`, the same fixtures as the Swift host tests. The fake Swift host derives its allow-listed Capabilities from fixture Service Modes; the Rust guest accepts compatible additive v1 responses and treats typed incompatibility as Link-only unavailability. `GuestPeer` adds correlated Calendar and agenda results, cancellation, and content-free Invalidations. See the [wire contract and resource bounds](../../protocol/omarchy-link/v1/README.md).

The normal `make test` entry point runs these Rust tests offline alongside Swift tests. `OmarchyLinkLoopbackTests` starts `cargo run --locked --offline --example fake-peer` and exchanges actual framed bytes over anonymous pipes with the Swift fake host, under a 30-second deadline. The example is a test harness, not a supported CLI mode; its stdin/stdout must be connected to that harness. Socket ownership, the daemon, VM transport, and real Mac Service routing remain unimplemented.

## Development Calendar surface

A factory build compiles the broker and carries a standalone Quickshell Calendar surface, but does not add a desktop entry, menu item, service, shell plugin, or production launch path. Both commands fail closed unless the explicit development flag is present:

```sh
OMARCHY_LINK_DEVELOPMENT=1 omarchy-link demo-agenda \
  --date "$(date +%F)" --range seven-days

OMARCHY_LINK_DEVELOPMENT=1 omarchy-link-calendar-demo
```

The surface offers **Today** and **Next 7 days** ranges and refetches through `DevelopmentAgendaBroker` and `InventedCalendarHostAdapter` when a calendar filter changes. The broker negotiates an in-memory fake Link Session and accepts the adapter's Calendar responses through the same typed `GuestPeer` used by protocol tests. Event and calendar fixtures live only behind that adapter; the QML view parses broker JSON and contains none of them.

The surface also carries an editable invented create request. **Review event** opens a terminal that obtains a host-canonical Mutation Proposal and shows its exact title, start, end, and resolved calendar. Approval, rejection, and dismissal are one-shot outcomes, and changing the request starts with a new proposal. The broker refuses review while logind reports the session locked, when the Wayland review UI is unavailable, or when stdin/stdout are not a terminal. Those cases return typed `review.*` results; there is no perform route, and the CLI accepts no argument that approves a proposal.

For deterministic review evidence with the same invented records used by tests:

```sh
OMARCHY_LINK_DEVELOPMENT=1 \
OMARCHY_LINK_DEMO_DATE=2026-09-14 \
omarchy-link-calendar-demo
```

No command above contacts the Mac helper, constructs EventKit, asks for an Apple permission, reads Calendar data, or performs a host mutation. A compiling EventKit adapter exists only behind the injected Swift Calendar interface for a later real-service ticket.

To refresh dependencies deliberately, update the exact versions in `Cargo.toml`, review `Cargo.lock` and every source/license change, then run:

```sh
cargo vendor --locked vendor > .cargo/config.toml
```
