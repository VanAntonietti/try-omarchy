# Omarchy Link guest broker

The compiled Owner-local broker/CLI carries bounded Calendar Queries over the private VM Link channel. Host Service Mode and EventKit grant jointly limit availability. Writes remain unavailable by default. A separately developer-gated real Calendar create flow uses a broker-owned visible review; the invented-data demos remain separate.

The dependency graph is exact-version locked and vendored. Tests therefore run without network access:

```sh
cd guest/omarchy-link
cargo fmt --check
cargo test --locked --offline
```

The integration tests consume `protocol/omarchy-link/v1/golden-frames.json` and `handshake-fixtures.json`, the same fixtures as the Swift host tests. The fake Swift host derives its allow-listed Capabilities from fixture Service Modes; the Rust guest accepts compatible additive v1 responses and treats typed incompatibility as Link-only unavailability. `GuestPeer` adds correlated Calendar and agenda results, cancellation, and content-free Invalidations. See the [wire contract and resource bounds](../../protocol/omarchy-link/v1/README.md).

The normal `make test` entry point runs these Rust tests offline alongside Swift tests. `OmarchyLinkLoopbackTests` starts `cargo run --locked --offline --example fake-peer` and exchanges actual framed bytes over anonymous pipes with the Swift fake host, under a 30-second deadline. The example is a test harness, not a supported CLI mode; its stdin/stdout must be connected to that harness. The production broker uses the same typed peer for Workspace-bound negotiation, Calendar Queries, and content-free Invalidations.

## Owner-local broker

New/reset factory Workspaces enable `omarchy-link.service` only for the first provisioned Owner (UID 1000). Existing persistent Workspaces are unsupported: no post-build installer injects the binary or service into them. The existing factory installer builds the exact locked, vendored Rust sources with `cargo build --frozen --release`; dependency provenance and licenses remain in `Cargo.lock`, `vendor/`, and the repository's third-party notices.

`omarchy-link status` reports negotiated host Capabilities, a content-free Calendar revision, and `contentAllowed` (active, unlocked Owner graphical session). Missing logind state or a running Hyprlock fails closed. The service owns `$XDG_RUNTIME_DIR/omarchy-link/socket` with mode 0600 inside a validated owned 0700 directory. Other accounts cannot traverse it; guest root and compromised Owner processes are outside this boundary. The daemon refuses to replace existing sockets. systemd removes its runtime directory on stop, allowing a clean restart. For manual daemon runs, use a fresh private runtime directory each time.

Local IPC is one length-prefixed JSON request/response per connection, bounded to 64 KiB and two-second read/write timeouts. `omarchy-link call` reads JSON only from stdin; no request body belongs in argv. Unknown methods and direct write execution return typed unavailability. The separately gated `calendar.create` workflow below can ask for visible review; it never accepts a client-supplied approval or replays a write. The broker stores no content or Sync Metadata on disk, emits no request logs, and its service disables output and core dumps. Calendar responses travel only in memory and over private IPC. Up to eight local clients are served concurrently so a Query does not block lock-status checks. Queries have a one-second response deadline and are checked for lock state both before submission and before returning content; timeouts request cancellation, and disconnects never replay a Query.

For an isolated invented-data socket demo, use a fresh 0700 `XDG_RUNTIME_DIR` and run `OMARCHY_LINK_DEVELOPMENT=1 omarchy-link daemon --development-fake`. From the same runtime directory, `status` identifies the invented adapter without claiming host availability. Submit `{"method":"calendar.agenda","date":"2026-09-14","range":"seven-days"}` on `call` stdin. The fake adapter cannot be enabled by a client request.

Disposable-Linux verification: confirm the Owner service starts, then attempt socket status and proposal requests from a second account; both must fail before reaching the broker. Stop/start the Owner service and verify status works again. No personal Apple data is needed. `scripts/verify-owner-broker-lima.sh` automates these checks in a throwaway Lima VM on the hosting Mac: it builds the locked, vendored sources with `cargo build --frozen --release`, installs the factory `omarchy-link.service` unit unchanged, and exercises the Owner and a second account (client refusal, kernel `EACCES` on a raw connect, daemon refusal for non-Owner uids, and a clean stop/start cycle). The same steps remain valid manually in a disposable new Workspace.

## Calendar surface

For a new/reset Workspace, enable Calendar **Read** or **Read & Write** and grant Calendar access in the Mac start menu, then explicitly open **Omarchy Link Calendar** from the Omarchy application launcher (or run `omarchy-link-calendar` inside the Owner's Wayland session). No bar layout, shortcut, or autostart surface is installed.

Today and Next 7 days use local midnight boundaries and the guest's `/etc/localtime` zone rules, including DST transitions. Calendar filtering uses opaque identifiers. Only read Queries are exposed; no create button is present. The Python standard-library driver exchanges bounded JSON with the compiled broker; Quickshell renders host text as plain text. Content is never written to files, argv, or logs. The launcher disables core dumps and discards Quickshell diagnostic output.

The surface polls content-free status every 250 ms (plus bounded IPC/probe latency). On lock, inactive/unknown session state, Hyprlock, or channel loss, its content process exits, the window closes, and late results cannot reopen it. Unlock requires explicitly reopening the surface. Content-free Invalidations coalesce into at most one refresh per two seconds; a sixty-second fallback refresh covers date rollover. There is at most one outstanding agenda refresh and no persistent content cache. Production peers negotiate monotonic Query identifiers, retaining only a high-water mark on the host so normal periodic refreshes do not exhaust the development fixture's lifetime budget. Older hosts that do not acknowledge this additive extension retain the 1,023-Query limit. Dense results exceeding the 64 KiB local IPC budget report Calendar unavailability without truncating events; choose a narrower date range or calendar filter.

Local read requests are `{"method":"calendar.calendars.list"}` and `{"method":"calendar.events.list","start":"2026-09-14T00:00:00Z","end":"2026-09-15T00:00:00Z","calendarIds":[]}`. Use the `call` command's stdin only; its stdout contains private data, so do not redirect it into logs. Unknown methods and direct write execution remain unavailable. Test-only `OMARCHY_LINK_UNLOCKED_FILE` is honored exclusively by the explicitly gated development daemon.

See [disposable-event verification](../../docs/calendar-agenda-verification.md) before release. Existing persistent disks are not upgraded or modified.

## Developer-gated real Calendar create

See [Calendar create setup and disposable verification](../../docs/calendar-create-verification.md).
Both hosting Mac and guest broker must explicitly enable `OMARCHY_LINK_DEVELOPMENT=1`;
Calendar must be Read & Write with full EventKit access. From an Owner graphical
terminal, `omarchy-link create-calendar` reads the four-field JSON request from
stdin, then the broker opens its own Quickshell Review Interlock. No body belongs
in argv or files. The ordinary `call` CLI cannot approve or execute a proposal.
The agenda UI stays unchanged and no bar layout is rewritten.

Canonical content crosses only private pipes and a mode-0600 temporary Unix
socket in a private runtime directory; the pathname contains no content.
Lock, missing UI, rejection, and host channel loss abort review. Proposal IDs
are one-shot, session-local, and expiring. After submission, unproven outcomes
are explicitly uncertain, with no automatic replay. Per-session idempotency
keys and reconciliation remain #13, so this flow is not release-ready.

## Development Calendar surface

The separate invented-data surface and both commands below still fail closed unless the explicit development flag is present:

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

No command above contacts the Mac helper, constructs EventKit, asks for an Apple permission, reads Calendar data, or performs a host mutation. The production surface above instead uses the host's grant-gated EventKit adapter behind the injected Swift Calendar interface.

To refresh dependencies deliberately, update the exact versions in `Cargo.toml`, review `Cargo.lock` and every source/license change, then run:

```sh
cargo vendor --locked vendor > .cargo/config.toml
```
