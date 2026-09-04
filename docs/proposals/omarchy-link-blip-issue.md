# Draft issue: support an Omarchy Link transport without changing Blip's SSH default

> Local draft only. Do not post until the Try Omarchy spike and both proposal texts have been reviewed.

## Summary

Would you be open to a small transport seam that lets Blip run inside Try Omarchy through a same-host **Omarchy Link** CLI, while preserving the existing SSH bridge as Blip's default and fully supported path?

Try Omarchy runs the Linux guest on the Mac that owns `chat.db` and Messages.app. Its native launcher can hold the TCC grants and expose narrowly typed Messages operations over an existing-style private virtio channel. Requiring Remote Login, an SSH key, and copied Mac tools inside this topology would duplicate a network boundary that the VM does not need.

## Proposed shape

- Keep today's SSH behavior and `blip-setup` flow unchanged by default.
- Introduce one tested command-runner/transport interface beneath collector/thread/send operations.
- Add an explicit `omarchy-link` transport that invokes a local guest CLI rather than `ssh` or Mac-side scripts.
- Let setup detect the packaged Try Omarchy capability and skip SSH key generation, Remote Login, and Mac tool installation only when that transport is explicitly selected.
- Preserve Blip's current stdin rules for message bodies and its no-body-on-disk/log invariants.
- Preserve push behavior by mapping Omarchy Link's content-free Messages invalidation stream to Blip's existing refresh trigger.
- Keep all existing fake bridge fixtures and tests; add transport contract tests without reading real `chat.db` or sending to a real contact.

The host API would remain narrower than the Mac tools: typed recent-conversation/thread/send operations only for the first slice, no arbitrary SQL, shell, AppleScript, or file access. Host service modes are Off / Read / Read & Write per Try Omarchy workspace. Sends to existing DMs/groups retain their iMessage/SMS/RCS route and still require a visible, canonical in-guest review interlock before the host executes them.

## Why collaborate rather than fork Blip outright

Blip already captures subtle invariants around unread ledgers, group GUIDs, self-thread echoes, delivery failures, and privacy. A transport seam keeps those fixes shared. Try Omarchy can reuse or adapt the narrow components it needs with exact commit provenance and MIT notices instead of silently copying a snapshot that drifts.

The Try Omarchy MVP does not ask Blip to take on Calendar or Notes, and it does not require the full Blip 2.3 feature set. SSH remains essential for ordinary Omarchy installations on separate Linux hardware.

## Non-goals

- Replacing or deprecating SSH.
- Moving `chat.db` parsing into the Linux client.
- Passing message bodies in argv or adding a plaintext cache.
- Making Blip responsible for Try Omarchy's macOS permissions UI.
- Adding attachments, new-recipient compose, search, link cards, tapbacks, or other feature work as part of the transport change.
- Claiming that guest confirmation protects against a compromised same-user/root session; Try Omarchy documents that trust boundary separately.

## Compatibility and fallback

The adapter should be opt-in and additive. If an upstream change cannot land on the Try Omarchy schedule, the fork would carry only a small checksum-pinned adapter patch, document it in provenance/notices, and remove it once an upstream release provides the seam.

The initial reference point is Blip 2.3.0 commit `ebd05cd1de75da673c8e9f440537da0568d6e574`; the pin would be refreshed before posting or implementation.

## Feedback requested

1. Would you prefer the seam at the current bridge-command runner, at the `imsg` shim boundary, or elsewhere?
2. Should `transport=omarchy-link` live in `bridge.conf`, or should packaged-environment detection select a separate config path?
3. Which Blip invariants/tests should Try Omarchy treat as mandatory for the reduced text-only slice?
4. Would you accept a transport PR before Try Omarchy ships the host capability, provided it is fixture-tested and leaves SSH behavior unchanged?

## Evidence before posting

- [ ] Try Omarchy cross-language protocol tests
- [ ] Fake-data Calendar proof for the generic channel
- [ ] Proposed Messages capability schema
- [ ] Blip runner seam sketch against current `main`
- [ ] Confirmation that no body enters argv, disk state, or logs
