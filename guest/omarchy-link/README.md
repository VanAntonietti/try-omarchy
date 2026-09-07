# Omarchy Link guest scaffold

This is the proposed compiled guest broker/CLI. It contains the shared v1 frame codec, typed fake-data request peer with Link Session negotiation, an invented Calendar agenda model, and a development-only Calendar Mutation Proposal Review Interlock. It cannot access host data. The Owner-local daemon and stdin-only `call` command work without a host transport.

The dependency graph is exact-version locked and vendored. Tests therefore run without network access:

```sh
cd guest/omarchy-link
cargo fmt --check
cargo test --locked --offline
```

The integration tests consume `protocol/omarchy-link/v1/golden-frames.json` and `handshake-fixtures.json`, the same fixtures as the Swift host tests. The fake Swift host derives its allow-listed Capabilities from fixture Service Modes; the Rust guest accepts compatible additive v1 responses and treats typed incompatibility as Link-only unavailability. `GuestPeer` adds correlated Calendar and agenda results, cancellation, and content-free Invalidations. See the [wire contract and resource bounds](../../protocol/omarchy-link/v1/README.md).

The normal `make test` entry point runs these Rust tests offline alongside Swift tests. `OmarchyLinkLoopbackTests` starts `cargo run --locked --offline --example fake-peer` and exchanges actual framed bytes over anonymous pipes with the Swift fake host, under a 30-second deadline. The example is a test harness, not a supported CLI mode; its stdin/stdout must be connected to that harness. VM transport and real Mac Service routing remain unimplemented.

## Owner-local broker

New/reset factory Workspaces enable `omarchy-link.service` only for the first provisioned Owner (UID 1000). Existing persistent Workspaces are unsupported: no post-build installer injects the binary or service into them. The existing factory installer builds the exact locked, vendored Rust sources with `cargo build --frozen --release`; dependency provenance and licenses remain in `Cargo.lock`, `vendor/`, and the repository's third-party notices.

`omarchy-link status` reports host Link unavailable until the private VM channel is implemented. The service owns `$XDG_RUNTIME_DIR/omarchy-link/socket` with mode 0600 inside a validated owned 0700 directory. Other accounts cannot traverse it; guest root and compromised Owner processes are outside this boundary. The daemon refuses to replace existing sockets. systemd removes its runtime directory on stop, allowing a clean restart. For manual daemon runs, use a fresh private runtime directory each time.

Local IPC is one length-prefixed JSON request/response per connection, bounded to 64 KiB and two-second read/write timeouts. `omarchy-link call` reads JSON only from stdin; no request body belongs in argv. Unknown methods and all writes return typed unavailability and are never replayed. The broker stores no content or Sync Metadata on disk, emits no request logs, and its service disables output and core dumps. No real private content is available in this slice.

For an isolated invented-data socket demo, use a fresh 0700 `XDG_RUNTIME_DIR` and run `OMARCHY_LINK_DEVELOPMENT=1 omarchy-link daemon --development-fake`. From the same runtime directory, `status` identifies the invented adapter without claiming host availability. Submit `{"method":"calendar.agenda","date":"2026-09-14","range":"seven-days"}` on `call` stdin. The fake adapter cannot be enabled by a client request.

Disposable-Linux verification: confirm the Owner service starts, then attempt socket status and proposal requests from a second account; both must fail before reaching the broker. Stop/start the Owner service and verify status works again. No personal Apple data is needed. `scripts/verify-owner-broker-lima.sh` automates these checks in a throwaway Lima VM on the hosting Mac: it builds the locked, vendored sources with `cargo build --frozen --release`, installs the factory `omarchy-link.service` unit unchanged, and exercises the Owner and a second account (client refusal, kernel `EACCES` on a raw connect, daemon refusal for non-Owner uids, and a clean stop/start cycle). The same steps remain valid manually in a disposable new Workspace.

## Development Calendar surface

A factory build compiles the broker and carries a standalone Quickshell Calendar surface, but does not add a Calendar desktop entry, menu item, shell plugin, or real-service launch path. Both commands fail closed unless the explicit development flag is present:

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
