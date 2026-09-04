# Draft issue: Omarchy Link — opt-in Calendar, Messages, and Notes from the hosting Mac

> Local draft only. Do not post until the bounded spike evidence has been added and reviewed.

## Summary

I would like feedback on **Omarchy Link**, an opt-in path for guest-native Omarchy surfaces to use selected Calendar, Messages, and Notes capabilities from the same Mac that is already hosting Try Omarchy.

This is a large behavioral and trust-boundary change, so I am opening a design discussion before proposing production behavior. The first implementation would be a developer-only core + Calendar spike. Messages and Notes would remain later, independently reviewable phases.

## User problem

Try Omarchy makes Omarchy a convincing second desktop on an Apple Silicon Mac, but everyday workflows still jump back to macOS for an upcoming event, an iMessage, or a note. Blip demonstrates that a Linux UI can be useful without reimplementing Apple's cloud protocols: the Mac remains the authority and Linux is a client.

Blip uses SSH because its normal Linux and Mac machines are separate. Try Omarchy already has a private same-host integration pattern for clipboard and camera, so requiring Remote Login, an SSH key, and installed Mac scripts would add avoidable setup and privilege.

## Proposed boundary

- One supervised `omarchy-vm-helper --bridge-omarchy-link` mode connects to one private `dev.tryomarchy.services` virtio-serial port.
- The wire format is bounded, length-prefixed UTF-8 JSON with request IDs, typed errors, cancellation, a version/capability handshake, and content-free invalidation events.
- Host methods are explicitly allow-listed and typed. There is no arbitrary SQL, AppleScript, shell, Shortcuts, file, or network-listener API.
- A first-user systemd service in the guest owns the port and multiplexes a mode-0600 local socket for the bar, focused windows, and CLI/SDK clients.
- Protocol v1 evolves additively. A missing or incompatible bridge disables Omarchy Link only; it never prevents the VM from starting.

The macOS adapters would be native Swift so the distributed app does not depend on Xcode Command Line Tools or a user-installed Python runtime:

- Calendar: EventKit.
- Messages reads: read-only `chat.db` access; Messages writes: parameterized Apple Events.
- Notes reads and writes: parameterized Apple Events only, avoiding a broad Full Disk Access requirement for Notes and never touching `NoteStore.sqlite`.
- Contact display names: optional Contacts framework access, with raw handles as the fallback.

## Consent and threat model

Each service has a per-workspace mode: **Off**, **Read**, or **Read & Write**. Defaults are Off. Modes are fixed for one VM launch and keyed to a random host-validated workspace identity; reset creates a new identity and returns all modes to Off. Ephemeral access is separately opted into for one run.

An enabled service deliberately trusts the first provisioned Omarchy user session. Any process running as that user can query data exposed by the enabled mode and can submit a write proposal. That risk must be stated in the start menu and documentation.

Writes are narrower than that trust:

- Every send/create/append becomes a canonical mutation proposal naming its exact recipient, calendar, or Notes folder and exact content.
- A one-shot guest review UI must approve that proposal. Supported CLI/API calls cannot bypass it, and locked/headless sessions fail closed.
- The review is a mandatory safety interlock, not a claimed security boundary against compromised same-user or guest-root code.
- Writes are never replayed automatically after disconnects. Per-session idempotency keys suppress accidental duplicate submissions, uncertain outcomes are reconciled where possible, and a retry requires a fresh review.

Private bodies remain memory-only in the guest and out of logs. Only bounded content-free sync metadata may persist. Locking Omarchy closes sensitive surfaces, clears content memory, and pauses content queries. Opening a Messages thread updates only Omarchy's local read state; it never changes Apple's read state or emits a read receipt.

## Permission matrix

| Service mode | macOS access | Behavior when unavailable |
| --- | --- | --- |
| Calendar Read | EventKit calendar access | Calendar capability unavailable; VM still starts |
| Calendar Read & Write | Same EventKit grant; host mode additionally allows creation | Writes remain unavailable unless the mode allows them |
| Messages Read | Manual Full Disk Access for the signed Try Omarchy app | Messages capability unavailable with exact remediation |
| Messages Read & Write | Full Disk Access + Automation → Messages | Reads may remain available if only Automation is missing |
| Messages names (optional) | Contacts | Raw phone/email handles when denied |
| Notes Read / Read & Write | Automation → Notes | Notes capability unavailable with exact remediation |

The production start menu would show each mode, current grant status, and precise remediation. Optional-service failure must never become a VM availability failure.

## Narrow MVP

The overall MVP is complete only when all three slices work, but each phase must be independently releasable and documented:

1. **Core + Calendar:** today's/next-seven-days agenda, calendar filtering, and create with title/start/end/calendar. No attendee invitations, recurrence editing, update, or delete.
2. **Messages + Blip adapter:** unread badge, recent conversations, text threads, and text sends to existing DMs/groups using their existing iMessage/SMS/RCS route. No attachments, search, tapbacks, previews, or guest notifications. A send is first reported as accepted by Messages and then reconciled against `chat.db` instead of claiming immediate delivery.
3. **Notes:** recent notes/folders, title search, sanitized body display without embedded attachments, create, and conflict-checked append. Authoring is plain text escaped into safe Notes HTML; the quick-capture target is an existing folder chosen by the user.

Clients would be installed as a Try-Omarchy-specific guest package and exposed through the Omarchy menu. Users explicitly add the Calendar, Messages, or Notes bar widget they want; existing/customized bar layouts are never rewritten.

## Existing VM and update behavior

The current app correctly does not inject new factory files into an existing persistent disk. The first Omarchy Link release would therefore support new/reset VMs and document that limitation. Designing a reviewed in-guest migration channel is a separate problem; this proposal does not smuggle one in through a post-build installer.

Once Link exists on a persistent disk, additive protocol capability negotiation lets a newer host app continue serving that older guest client.

## Bounded first spike

Before any release-default UI or factory behavior, an explicit development flag would enable:

- the cross-language frame codec and capability-policy tests;
- fake host/guest loopback tests using invented data;
- a compiling EventKit adapter behind an injected interface;
- a minimal seven-day agenda/create QML proof;
- unit tests and a fake-data screenshot/demo.

No personal Calendar data belongs in tests, screenshots, logs, or issue output. A manual live test, later, would use clearly labeled disposable events.

## Non-goals

- Remote Mac support in the MVP.
- A generic macOS automation gateway or MCP server.
- Host network listeners.
- Apple-data SQLite writes.
- Message attachments/search/tapbacks, Calendar CRUD/recurrence/attendees, or a full rich Notes editor.
- Automatic Apple read-state changes.
- A migration mechanism for existing guest disks.
- Default global shortcuts or silently modified bar layouts.

## Relationship to existing work

This is not QEMU Guest Agent: QGA gives the host a root-capable command path into the guest, while Omarchy Link exposes a small set of user-enabled host service methods to one guest user and no arbitrary execution in either direction.

Blip is MIT-licensed and contains hard-won Messages UI/state invariants. I plan to ask its maintainers about a transport adapter that preserves SSH as the default. Any reused source will retain traceable provenance, exact pins/hashes, and notices. If upstream support is delayed, a minimal checksum-pinned adapter patch would be temporary and called out explicitly.

## Feedback requested

1. Does this local, typed virtio channel fit Try Omarchy's existing host-integration direction?
2. Is the documented “enabled Owner session” trust boundary acceptable if every supported write still has a non-headless guest review interlock?
3. Is core + Calendar the right first reviewable slice?
4. Should Try-Omarchy-specific clients remain guest overlays/packages, or is there a preferred boundary with upstream Omarchy's plugin tree?
5. What additional evidence would you want before a production-facing start-menu permission design?

## Evidence before posting

- [ ] Cross-language golden frame tests
- [ ] Capability/mode policy tests
- [ ] Fake host/guest loopback test
- [ ] Compiling EventKit adapter behind a fakeable boundary
- [ ] Fake-data Calendar demo/screenshot
- [ ] `make test` result
