# Security policy

Please do not file a public issue for a suspected vulnerability. Use GitHub's
private vulnerability reporting or security-advisory flow for this repository
and include reproduction steps, affected versions, and the expected impact.

Only the current `main` branch is supported before the first stable release.
Security-sensitive areas include downloaded build inputs, artifact and manifest
validation, code signing, VM disk handling, the QEMU process boundary, and the
guest-to-host audio bridge, and the opt-in Omarchy Link channel.

Omarchy Link trusts the enabled Workspace's Owner session: enabled reads expose
private hosting Mac data to all Owner processes. Its mandatory visible Review
Interlock is not a security boundary against compromised same-user or guest-root
code. Service Modes default to Off, are separate from Apple grants, and reset
with the Workspace. Calendar content uses private IPC and memory, not request
logs or a persistent cache. Intended writes are saved to Calendar; deduplication
retains bounded in-memory identifiers/outcomes only. See
[Calendar safety and limitations](docs/calendar-create-verification.md).

The project will acknowledge a complete report as soon as practical, assess its
scope, and coordinate a fix and disclosure with the reporter.
