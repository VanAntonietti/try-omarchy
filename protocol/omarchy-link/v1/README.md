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
Older pre-Link persistent disks are not modified or given an identity. The
private VM channel below now carries this handshake for a validated persistent
Workspace.

The host derives advertised Capabilities from its launch-fixed Service Modes. Off advertises none, Read advertises only named queries, and Read & Write adds only named Mutation Proposal operations. Calendar Capabilities additionally require the hosting Mac's full-access Apple Calendar grant, captured once per Link Session: without it the host advertises no Calendar Capability while the handshake, the VM, and unrelated Mac Services stay available, and the blocked grant is reported as content-free status. The grant never widens a mode and a mode is never inferred from the grant. Enabling reads will expose private Mac Service data to processes in the trusted Owner session and must be disclosed wherever real access is offered. Client-supplied fields cannot add Capabilities. The current fake policy is captured in `handshake-fixtures.json`; it exposes only Calendar, Messages, and Notes operations and no shell, SQL, file, script, or generic dispatch surface.

`session.handshake_required`, `session.handshake_already_complete`, `session.invalid_handshake`, `session.invalid_workspace_identity`, and `session.unsupported_protocol` are typed handshake failures. The Swift host and Rust guest consume the shared fixtures. The production channel serves Calendar list and bounded agenda Queries through a grant-gated EventKit adapter. Other operations answer with `request.method_unavailable`, except the explicitly developer-gated Calendar create flow below.

## The private VM channel

The launcher attaches one multiplexed virtio-serial port, `dev.tryomarchy.link`, only when a persistent Workspace identity validated under the storage lock; ephemeral runs and legacy or corrupt disks get no channel. The port is backed by a Unix socket inside the launcher's owned mode-0700 run directory, so the channel adds no host TCP listener, SSH dependency, or arbitrary command API. The supervised `--bridge-omarchy-link` helper verifies its target is the launcher's QEMU process and that the endpoint is a private owned socket before handling any protocol traffic.

The launcher captures the Workspace's Service Mode snapshot exactly once, before QEMU starts, and hands it to the bridge as fixed arguments: a later preference change cannot expand the running Link Session. The bridge negotiates one session per connection with the handshake above, bound to the validated Workspace identity. A second `session.hello` on the same connection fails with `session.handshake_already_complete` without tearing the session down (using a fresh request ID under the negotiated ID policy).

Production guests optionally send `params.requestIdPolicy: "monotonic-q"` in the first hello. Only a successful response echoing `result.requestIdPolicy: "monotonic-q"` enables it. Thereafter every request ID is `q` followed by a canonical decimal UInt32, strictly increasing from 1; cancellation still refers to the original request ID and does not advance the sequence. The host retains one high-water mark plus the bounded pre-handshake IDs, so duplicate/reordered requests fail closed without a session-long growing set. The guest stops before UInt32 exhaustion and retains the 32-in-flight limit. Missing or unknown policy fields preserve the legacy 1,024-ID host budget and 1,023-Query guest budget; old clients and hosts need not implement the extension. No request is replayed or automatically reconnected to reset an ID budget.

Failure stays isolated from VM availability. Malformed traffic, framing violations, or duplicate request identifiers disable Link for the rest of the session with a content-free status (the bridge exits with status 2 and is not restarted); a crashed bridge is restarted a bounded number of times; QEMU and the VM continue running in every case. Terminal handshake failures such as an invalid identity or an unsupported protocol major are reported once and are not retried by the guest, so a rejected client cannot spam the host's session budget.

Inside the guest, the Owner-local broker (`omarchy-link daemon`) reads the launcher-fixed `tryomarchy.workspace_id` kernel argument — exactly one canonical lowercase UUIDv4, anything else fails closed — opens `/dev/virtio-ports/dev.tryomarchy.link`, and performs the handshake. The negotiated protocol version and Capability names (or the typed failure reason) surface through the existing owner-only local socket as bounded, content-free status; transport loss reports `channel.closed` and is quietly retried. A newer compatible host serves an older persistent guest client through additive negotiation: the minor version negotiates down and unknown Capability names are carried opaquely rather than rejected.

## Fake request lifecycle

`OmarchyLinkFakeHost` (Swift) and `GuestPeer` (Rust) now exchange framed messages after that handshake. The executable fake Capabilities are `calendar.calendars.list` and `calendar.events.list`, both gated by Calendar Read or Read & Write. Calendar-list success has a typed `result.calendars` array of `{ "id": "…", "title": "…" }`.

An agenda Query uses `calendar.events.list` with `{ "start": "<UTC RFC 3339>", "end": "<UTC RFC 3339>", "calendarIds": ["…"] }`. The end is exclusive, must follow the start by no more than eight days, and the optional filter is represented by an empty or unique list of opaque calendar identifiers. Success contains `result.events`; each event has `id`, `calendarId`, `title`, `startsAt`, `endsAt`, and `allDay`. The host adapter must return only events overlapping the requested range and matching that filter.

The fake lifecycle uses invented Calendar values behind replaceable Swift and Rust adapters. Separately, the production channel constructs EventKit only when Calendar Service Mode and the launch-captured Apple grant allow Queries; the adapter itself never prompts. Production Calendar response envelopes are capped conservatively at 64 KiB to fit Owner-local IPC. Oversized or invalid adapter results return content-free `service.unavailable`, never a truncated agenda or a channel failure. Unknown or disabled methods return `request.method_unavailable`; there is no generic dispatch. Host-data execution is restricted to the developer-gated Calendar flow below.

Calendar Read & Write also enables `calendar.events.create.propose`. Its parameters are `{ "title": "…", "startsAt": "<UTC RFC 3339>", "endsAt": "<UTC RFC 3339>", "calendarId": "…" }`. The fake host trims surrounding title whitespace, validates the positive canonical time interval, resolves the opaque calendar identifier through the injected adapter, and returns `result.proposal` with an opaque ID, the fixed `calendar` / `event.create` operation identity, and the exact canonical title, timestamps, calendar ID, and calendar title that must be reviewed. Calendar Read and Off cannot submit this operation.

A proposal response does not execute anything. The development broker binds one Review Interlock to that immutable canonical proposal. It exposes no perform method through the CLI/API, and the CLI accepts no approval argument: its only approval path is the visible `demo-create` terminal review launched from the development Calendar surface. The review checks for a terminal, Wayland review UI, and unlocked logind session before displaying content and again before resolving the decision. Headless, missing-UI, and locked states resolve once with `review.headless`, `review.ui_unavailable`, or `review.session_locked`; rejection and terminal dismissal also consume the review. A second decision returns `review.already_resolved`, and changing a request creates a new proposal and Review Interlock. Every outcome records `performed: false` because this ticket deliberately has no host-data mutation executor.

Each request has a unique, case-sensitive `id`. Replies echo it in either `response` with `result` or `error` with `{ "code": "…", "message": "…" }`. Multiple requests may be pending; completing one does not settle another, and replies may arrive out of order. The fake harness explicitly calls `complete(id, outcome)` to model delayed work without sleeps; completion can produce invented calendars, invented events, or `service.unavailable`. Error messages are fixed, content-free descriptions, not echoed parameters. A Rust caller receives typed results and failure codes (unrecognized future failure codes map to `Unknown`).

Cancellation is exactly `{ "type": "cancel", "id": "<request-id>" }`. For pending work the host removes the work and emits one terminal `request.cancelled` error with that request's ID. Subsequent completion cannot run it. Cancellation of unknown or already completed work is a no-op. The guest retains correlation until a terminal reply arrives: an already completed response may win the race. Cancellation never supplies approval, executes a write, or triggers automatic replay. Extra cancellation fields—including approval fields—are rejected, rather than interpreted as a Mutation Proposal approval.

An Invalidation is exactly `{ "type": "event", "event": "invalidation", "service": "calendar" }`, with service one of `calendar`, `messages`, or `notes`. It contains no request ID, object identifier, title, body, count, or other service content and cannot settle a request. The host emits it only for enabled services after negotiation. The guest rejects extra fields on Invalidations. These closed cancellation/Invalidation schemas are deliberate exceptions to ignoring additive fields: extensions must not sneak private content or approval into these safety envelopes. Ordinary request/response fields remain additive.

## Developer-gated real Calendar creation (#12)

The production channel advertises `calendar.events.create.propose` and the additive
`calendar.events.create.perform` only with hosting Mac development enablement,
Calendar Read & Write, full EventKit access, and an injected creating adapter.
The fake fixture policy above remains unchanged. The real proposal uses the same
four-field schema, but rejects extra fields and control characters, limits duration
to eight days, and resolves only writable calendars. At most 32 proposals are held;
they expire after 120 seconds and are cleared when the connection closes.

`calendar.events.create.perform` accepts exactly `{"proposalId":"…"}` and returns
`result.outcome` equal to `succeeded`, `failed`, or `uncertain`. The host removes
the proposal before any save, rechecks the exact destination and current grant,
and invokes EventKit once. Unknown, expired, or consumed proposals cannot save.
A save exception is conservatively uncertain. Success means EventKit save, not
cloud delivery. Neither end replays execution after timeout or disconnect.

These methods are private **host-channel** operations, not Owner-local approval
APIs. The separately gated Owner broker accepts `calendar.create` with the four
fields, obtains the canonical proposal, and launches its own visible Quickshell
review using private pipes. Only the renderer's one-shot approval lets the broker
submit the proposal ID, while the same host connection and active unlocked Owner
session remain usable. Local `call` cannot approve/perform, and the supported
`create-calendar` CLI refuses headless output. Review times out after 110 seconds;
execution has a one-second response deadline and a lost result is uncertain.
The local create response timeout is 125 seconds rather than the Query timeout.
New idempotency keys and reconciliation are deferred to #13; every manual retry
must obtain a fresh canonical proposal and review. See
[setup and disposable verification](../../../docs/calendar-create-verification.md).

## Fake-peer bounds and failure policy

- Payloads are **1 byte through 4 MiB**, UTF-8 JSON objects. Empty or oversized lengths fail as soon as the four-byte header is present, without waiting for the body. Invalid JSON, non-object roots, invalid UTF-8, wrong-direction envelopes, and invalid required field types fail before Capability dispatch.
- Each `receive` call accepts at most **64 KiB**; callers split larger reads. A peer's framing staging buffer therefore never exceeds **4 MiB + 4 bytes + 64 KiB**. Parsing/output allocations are also bounded by these finite input sizes; this is not a total-heap quota. Partial frames are retained across calls. `finish` closes the peer, discards pending work, and reports a truncated header/body if any bytes remain.
- Request IDs are **1–64 printable ASCII bytes**, without spaces. Reusing an ID, even after completion, closes the peer so a late cancellation/reply cannot alias new work. The fake host remembers at most **1,024 request IDs**, including the handshake and rejected requests. Exhausting this fixture budget closes Link; a fresh fake peer is needed. This is not a production reconnection/replay policy.
- At most **32 Queries** may be pending. The host returns correlated `request.busy` for excess work. The Rust API prevents issuing more than 32 in-flight Queries or 1,023 application requests locally, without discarding existing work.
- Calendar results contain at most **128 calendars**; each has a nonempty ID up to **64 UTF-8 bytes** and nonempty title up to **256 UTF-8 bytes**. Agenda filters contain at most **128** unique calendar IDs. Agenda results contain at most **512 events**; event IDs are 1–128 bytes, calendar IDs are 1–64 bytes, titles are 1–512 bytes, and canonical UTC timestamps must form a positive interval. Calendar create requests and proposals use the same 64-byte calendar ID, 256-byte calendar title, and 512-byte event title bounds; proposal IDs are 1–128 bytes and their canonical UTC timestamps form a positive interval. Request error codes are **1–128 UTF-8 bytes**; messages are nonempty and at most **256 UTF-8 bytes**. Missing/wrongly typed results or unsolicited/duplicate terminal replies close the guest peer.
- Framing, schema, duplicate-ID, or inbound resource violations are terminal for that peer: it clears buffered and pending work, rejects later input, and never represents a VM startup failure. Method unavailability, service failure, busy, and cancellation are typed request-local failures. No content is logged or persisted by either peer.
- The in-memory peers do not own a clock or transport. A transport must call `finish` on EOF or its own deadline; an incomplete frame alone cannot be distinguished from a slow sender. The test pipe transport has a **30-second overall deadline**, with bounded readiness checks and forced child cleanup. The VM channel's supervision (bounded bridge restarts, guest reconnect backoff) is described above; per-request deadlines belong to the later Mac Service adapter tickets.

`make test` runs vendored Rust tests with `--locked --offline`, Swift protocol tests, and the actual Swift↔Rust fake-data pipe loopback. The loopback exchanges the handshake, concurrent Queries, a host-canonical Calendar Mutation Proposal, out-of-order success/failure, cancellation, and an Invalidation, including fragmented headers. It neither connects to a VM nor accesses Apple services.
