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

The host derives advertised Capabilities from its launch-fixed Service Modes. Off advertises none, Read advertises only named queries, and Read & Write adds only named Mutation Proposal operations. Enabling reads will expose private Mac Service data to processes in the trusted Owner session and must be disclosed wherever real access is offered. Client-supplied fields cannot add Capabilities. The current fake policy is captured in `handshake-fixtures.json`; it exposes only Calendar, Messages, and Notes operations and no shell, SQL, file, script, or generic dispatch surface.

`session.handshake_required`, `session.handshake_already_complete`, `session.invalid_handshake`, and `session.unsupported_protocol` are typed handshake failures. The Swift host and Rust guest consume the shared fixtures. The daemon, VM channel, and real Mac Service adapters remain unimplemented.

## Fake request lifecycle

`OmarchyLinkFakeHost` (Swift) and `GuestPeer` (Rust) now exchange framed messages after that handshake. The only executable fake Capability is `calendar.calendars.list`, gated by Calendar Read or Read & Write. Its request has object `params` (currently empty), and success has a typed `result.calendars` array of `{ "id": "invented-calendar", "title": "Invented Calendar" }`. These values are invented, never fetched from the hosting Mac. The broader handshake advertisement remains the policy fixture from #2; advertised but not yet implemented methods return `request.method_unavailable`, as do unknown or disabled methods. There is no generic dispatch or Mutation Proposal executor.

Each request has a unique, case-sensitive `id`. Replies echo it in either `response` with `result` or `error` with `{ "code": "…", "message": "…" }`. Multiple requests may be pending; completing one does not settle another, and replies may arrive out of order. The fake harness explicitly calls `complete(id, outcome)` to model delayed work without sleeps; completion can produce invented calendars or `service.unavailable`. Error messages are fixed, content-free descriptions, not echoed parameters. A Rust caller receives typed results and failure codes (unrecognized future failure codes map to `Unknown`).

Cancellation is exactly `{ "type": "cancel", "id": "<request-id>" }`. For pending work the host removes the work and emits one terminal `request.cancelled` error with that request's ID. Subsequent completion cannot run it. Cancellation of unknown or already completed work is a no-op. The guest retains correlation until a terminal reply arrives: an already completed response may win the race. Cancellation never supplies approval, executes a write, or triggers automatic replay. Extra cancellation fields—including approval fields—are rejected, rather than interpreted as a Mutation Proposal approval.

An Invalidation is exactly `{ "type": "event", "event": "invalidation", "service": "calendar" }`, with service one of `calendar`, `messages`, or `notes`. It contains no request ID, object identifier, title, body, count, or other service content and cannot settle a request. The host emits it only for enabled services after negotiation. The guest rejects extra fields on Invalidations. These closed cancellation/Invalidation schemas are deliberate exceptions to ignoring additive fields: extensions must not sneak private content or approval into these safety envelopes. Ordinary request/response fields remain additive.

## Fake-peer bounds and failure policy

- Payloads are **1 byte through 4 MiB**, UTF-8 JSON objects. Empty or oversized lengths fail as soon as the four-byte header is present, without waiting for the body. Invalid JSON, non-object roots, invalid UTF-8, wrong-direction envelopes, and invalid required field types fail before Capability dispatch.
- Each `receive` call accepts at most **64 KiB**; callers split larger reads. A peer's framing staging buffer therefore never exceeds **4 MiB + 4 bytes + 64 KiB**. Parsing/output allocations are also bounded by these finite input sizes; this is not a total-heap quota. Partial frames are retained across calls. `finish` closes the peer, discards pending work, and reports a truncated header/body if any bytes remain.
- Request IDs are **1–64 printable ASCII bytes**, without spaces. Reusing an ID, even after completion, closes the peer so a late cancellation/reply cannot alias new work. The fake host remembers at most **1,024 request IDs**, including the handshake and rejected requests. Exhausting this fixture budget closes Link; a fresh fake peer is needed. This is not a production reconnection/replay policy.
- At most **32 Queries** may be pending. The host returns correlated `request.busy` for excess work. The Rust API prevents issuing more than 32 in-flight Queries or 1,023 application requests locally, without discarding existing work.
- Calendar results contain at most **128 calendars**; each has a nonempty ID up to **64 UTF-8 bytes** and nonempty title up to **256 UTF-8 bytes**. Request error codes are **1–128 UTF-8 bytes**; messages are nonempty and at most **256 UTF-8 bytes**. Missing/wrongly typed results or unsolicited/duplicate terminal replies close the guest peer.
- Framing, schema, duplicate-ID, or inbound resource violations are terminal for that peer: it clears buffered and pending work, rejects later input, and never represents a VM startup failure. Method unavailability, service failure, busy, and cancellation are typed request-local failures. No content is logged or persisted by either peer.
- The in-memory peers do not own a clock or transport. A transport must call `finish` on EOF or its own deadline; an incomplete frame alone cannot be distinguished from a slow sender. The test pipe transport has a **30-second overall deadline**, with bounded readiness checks and forced child cleanup. Production transport deadlines belong to the later VM-channel ticket.

`make test` runs vendored Rust tests with `--locked --offline`, Swift protocol tests, and the actual Swift↔Rust fake-data pipe loopback. The loopback exchanges the handshake, concurrent Queries, out-of-order success/failure, cancellation, and an Invalidation, including fragmented headers. It neither connects to a VM nor accesses Apple services.
