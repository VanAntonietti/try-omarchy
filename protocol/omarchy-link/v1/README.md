# Omarchy Link protocol v1 scaffold

This directory holds implementation-neutral fixtures shared by the Swift host and Rust guest tests. It is evidence for a design proposal, not yet a supported release contract.

A frame is a four-byte unsigned big-endian payload length followed by one UTF-8 JSON object. Empty payloads and payloads larger than 4 MiB are rejected before JSON dispatch. The length counts bytes, not Unicode scalar values or characters.

The initial envelope vocabulary is:

- `request`: `id`, `method`, `params`
- `response`: `id`, `result`
- `error`: `id`, structured `error`
- `cancel`: the request identifier to cancel
- `event`: a typed, content-free invalidation or session event

`session.hello` is the first request and negotiates protocol version and capabilities. Method schemas and stricter per-method limits will be added by the bounded Calendar spike; neither implementation may turn this transport into arbitrary host execution.
