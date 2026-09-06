# Omarchy Link protocol v1 scaffold

This directory holds implementation-neutral fixtures shared by the Swift host and Rust guest tests. It is evidence for a design proposal, not yet a supported release contract.

A frame is a four-byte unsigned big-endian payload length followed by one UTF-8 JSON object. Empty payloads and payloads larger than 4 MiB are rejected before JSON dispatch. The length counts bytes, not Unicode scalar values or characters.

The initial envelope vocabulary is:

- `request`: `id`, `method`, `params`
- `response`: `id`, `result`
- `error`: `id`, structured `error`
- `cancel`: the request identifier to cancel
- `event`: a typed, content-free invalidation or session event

`session.hello` must be the first accepted request. Its parameters name the guest client and the major/minor protocol version it supports. Peers with major version 1 negotiate the lower supported minor version and ignore unknown additive fields; another major or a malformed hello makes Link unavailable without failing the VM.

Workspace-bound sessions additionally require `params.workspaceIdentity`: the
exact lowercase UUIDv4 presented by the launcher as `tryomarchy.workspace_id`.
The host compares it with the identity validated against its selected Workspace
state, never a guest-selected state path or factory digest. Missing, malformed,
or mismatched values, including a valid identity from before Factory Reset,
make Link terminally unavailable with `session.invalid_workspace_identity`
before any Capabilities are advertised. Missing/unvalidated host identity also
fails closed. The unchanged invented-data fixtures use an explicitly named
development initializer; they do not establish a production identity bypass.
Older pre-Link persistent disks are not modified or given an identity. The live
broker/channel that will carry this handshake remains follow-up work.

The host derives advertised Capabilities from its launch-fixed Service Modes. Off advertises none, Read advertises only named queries, and Read & Write adds only named Mutation Proposal operations. Enabling reads will expose private Mac Service data to processes in the trusted Owner session and must be disclosed wherever real access is offered. Client-supplied fields cannot add Capabilities. The current fake policy is captured in `handshake-fixtures.json`; it exposes only Calendar, Messages, and Notes operations and no shell, SQL, file, script, or generic dispatch surface.

`session.handshake_required`, `session.handshake_already_complete`, `session.invalid_handshake`, `session.invalid_workspace_identity`, and `session.unsupported_protocol` are typed handshake failures. The Swift host and Rust guest consume the shared fixtures. The daemon, VM channel, and real Mac Service adapters remain unimplemented.

## Fake request lifecycle

`OmarchyLinkFakeHost` (Swift) and `GuestPeer` (Rust) now exchange framed messages after that handshake. The executable fake Capabilities are `calendar.calendars.list` and `calendar.events.list`, both gated by Calendar Read or Read & Write. Calendar-list success has a typed `result.calendars` array of `{ "id": "…", "title": "…" }`.

An agenda Query uses `calendar.events.list` with `{ "start": "<UTC RFC 3339>", "end": "<UTC RFC 3339>", "calendarIds": ["…"] }`. The end is exclusive, must follow the start by no more than eight days, and the optional filter is represented by an empty or unique list of opaque calendar identifiers. Success contains `result.events`; each event has `id`, `calendarId`, `title`, `startsAt`, `endsAt`, and `allDay`. The host adapter must return only events overlapping the requested range and matching that filter.

All current Calendar values are invented, never fetched from the hosting Mac. The Swift fake adapter and the Rust development-surface adapter sit behind replaceable Calendar interfaces. A native EventKit implementation compiles behind the Swift interface but no production route constructs it, requests Apple permission, or accesses Calendar. Unknown or disabled methods return `request.method_unavailable`; there is no generic dispatch or host-data Mutation Proposal executor.

Calendar Read & Write also enables `calendar.events.create.propose`. Its parameters are `{ "title": "…", "startsAt": "<UTC RFC 3339>", "endsAt": "<UTC RFC 3339>", "calendarId": "…" }`. The fake host trims surrounding title whitespace, validates the positive canonical time interval, resolves the opaque calendar identifier through the injected adapter, and returns `result.proposal` with an opaque ID, the fixed `calendar` / `event.create` operation identity, and the exact canonical title, timestamps, calendar ID, and calendar title that must be reviewed. Calendar Read and Off cannot submit this operation.

A proposal response does not execute anything. The development broker binds one Review Interlock to that immutable canonical proposal. It exposes no perform method through the CLI/API, and the CLI accepts no approval argument: its only approval path is the visible `demo-create` terminal review launched from the development Calendar surface. The review checks for a terminal, Wayland review UI, and unlocked logind session before displaying content and again before resolving the decision. Headless, missing-UI, and locked states resolve once with `review.headless`, `review.ui_unavailable`, or `review.session_locked`; rejection and terminal dismissal also consume the review. A second decision returns `review.already_resolved`, and changing a request creates a new proposal and Review Interlock. Every outcome records `performed: false` because this ticket deliberately has no host-data mutation executor.

Each request has a unique, case-sensitive `id`. Replies echo it in either `response` with `result` or `error` with `{ "code": "…", "message": "…" }`. Multiple requests may be pending; completing one does not settle another, and replies may arrive out of order. The fake harness explicitly calls `complete(id, outcome)` to model delayed work without sleeps; completion can produce invented calendars, invented events, or `service.unavailable`. Error messages are fixed, content-free descriptions, not echoed parameters. A Rust caller receives typed results and failure codes (unrecognized future failure codes map to `Unknown`).

Cancellation is exactly `{ "type": "cancel", "id": "<request-id>" }`. For pending work the host removes the work and emits one terminal `request.cancelled` error with that request's ID. Subsequent completion cannot run it. Cancellation of unknown or already completed work is a no-op. The guest retains correlation until a terminal reply arrives: an already completed response may win the race. Cancellation never supplies approval, executes a write, or triggers automatic replay. Extra cancellation fields—including approval fields—are rejected, rather than interpreted as a Mutation Proposal approval.

An Invalidation is exactly `{ "type": "event", "event": "invalidation", "service": "calendar" }`, with service one of `calendar`, `messages`, or `notes`. It contains no request ID, object identifier, title, body, count, or other service content and cannot settle a request. The host emits it only for enabled services after negotiation. The guest rejects extra fields on Invalidations. These closed cancellation/Invalidation schemas are deliberate exceptions to ignoring additive fields: extensions must not sneak private content or approval into these safety envelopes. Ordinary request/response fields remain additive.

## Fake-peer bounds and failure policy

- Payloads are **1 byte through 4 MiB**, UTF-8 JSON objects. Empty or oversized lengths fail as soon as the four-byte header is present, without waiting for the body. Invalid JSON, non-object roots, invalid UTF-8, wrong-direction envelopes, and invalid required field types fail before Capability dispatch.
- Each `receive` call accepts at most **64 KiB**; callers split larger reads. A peer's framing staging buffer therefore never exceeds **4 MiB + 4 bytes + 64 KiB**. Parsing/output allocations are also bounded by these finite input sizes; this is not a total-heap quota. Partial frames are retained across calls. `finish` closes the peer, discards pending work, and reports a truncated header/body if any bytes remain.
- Request IDs are **1–64 printable ASCII bytes**, without spaces. Reusing an ID, even after completion, closes the peer so a late cancellation/reply cannot alias new work. The fake host remembers at most **1,024 request IDs**, including the handshake and rejected requests. Exhausting this fixture budget closes Link; a fresh fake peer is needed. This is not a production reconnection/replay policy.
- At most **32 Queries** may be pending. The host returns correlated `request.busy` for excess work. The Rust API prevents issuing more than 32 in-flight Queries or 1,023 application requests locally, without discarding existing work.
- Calendar results contain at most **128 calendars**; each has a nonempty ID up to **64 UTF-8 bytes** and nonempty title up to **256 UTF-8 bytes**. Agenda filters contain at most **128** unique calendar IDs. Agenda results contain at most **512 events**; event IDs are 1–128 bytes, calendar IDs are 1–64 bytes, titles are 1–512 bytes, and canonical UTC timestamps must form a positive interval. Calendar create requests and proposals use the same 64-byte calendar ID, 256-byte calendar title, and 512-byte event title bounds; proposal IDs are 1–128 bytes and their canonical UTC timestamps form a positive interval. Request error codes are **1–128 UTF-8 bytes**; messages are nonempty and at most **256 UTF-8 bytes**. Missing/wrongly typed results or unsolicited/duplicate terminal replies close the guest peer.
- Framing, schema, duplicate-ID, or inbound resource violations are terminal for that peer: it clears buffered and pending work, rejects later input, and never represents a VM startup failure. Method unavailability, service failure, busy, and cancellation are typed request-local failures. No content is logged or persisted by either peer.
- The in-memory peers do not own a clock or transport. A transport must call `finish` on EOF or its own deadline; an incomplete frame alone cannot be distinguished from a slow sender. The test pipe transport has a **30-second overall deadline**, with bounded readiness checks and forced child cleanup. Production transport deadlines belong to the later VM-channel ticket.

`make test` runs vendored Rust tests with `--locked --offline`, Swift protocol tests, and the actual Swift↔Rust fake-data pipe loopback. The loopback exchanges the handshake, concurrent Queries, a host-canonical Calendar Mutation Proposal, out-of-order success/failure, cancellation, and an Invalidation, including fragmented headers. It neither connects to a VM nor accesses Apple services.
