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

The host derives advertised Capabilities from its launch-fixed Service Modes. Off advertises none, Read advertises only named queries, and Read & Write adds only named Mutation Proposal operations. Client-supplied fields cannot add Capabilities. The current fake policy is captured in `handshake-fixtures.json`; it exposes only Calendar, Messages, and Notes operations and no shell, SQL, file, script, or generic dispatch surface.

`session.handshake_required`, `session.handshake_already_complete`, `session.invalid_handshake`, and `session.unsupported_protocol` are typed handshake failures. The Swift host and Rust guest consume the shared fixtures, but the daemon, VM channel, and real Mac Service adapters remain unimplemented.
