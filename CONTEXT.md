# Omarchy Link

Omarchy Link lets a deliberately trusted Omarchy workspace use selected data and actions owned by the Mac that hosts Try Omarchy. It keeps host consent, guest access, and user-visible writes explicit rather than treating the VM as an automatic extension of macOS.

## Boundaries

**Hosting Mac**:
The Mac running Try Omarchy and owning the Calendar, Messages, Notes, and Contacts data exposed to a guest.
_Avoid_: Gateway Mac, remote Mac

**Workspace**:
One persistent Omarchy environment with its own identity and access choices. Resetting creates a new workspace even when it reuses the same storage location.
_Avoid_: Disk, folder, machine

**Owner**:
The first account provisioned in a workspace and the only guest account eligible to use Omarchy Link.
_Avoid_: Mac user, administrator

**Link Session**:
One launch of a workspace with an immutable set of service modes. It ends when that VM run ends.
_Avoid_: Login, connection

## Access

**Mac Service**:
A bounded area of host-owned data and behavior exposed through Omarchy Link, initially Calendar, Messages, or Notes.
_Avoid_: App, integration, provider

**Service Mode**:
The host user's per-workspace choice of Off, Read, or Read & Write for one Mac Service. A mode limits available capabilities; it is not an Apple permission grant.
_Avoid_: Permission, entitlement

**Capability**:
A named, typed operation the hosting Mac advertises for the current Link Session. Capabilities never include arbitrary host commands, queries, scripts, or file access.
_Avoid_: Command, endpoint

**Invalidation**:
A content-free notice that data behind a Mac Service may have changed and should be fetched again.
_Avoid_: Event, notification, update

## Actions and state

**Query**:
A read-only capability invocation that cannot change host data or Apple read state.
_Avoid_: Fetch command, sync

**Mutation Proposal**:
The hosting Mac's canonical description of one requested write, such as sending a message, creating an event, or appending to a note, before it is performed.
_Avoid_: Draft, command

**Review Interlock**:
The mandatory visible approval of one Mutation Proposal inside Omarchy. It prevents supported headless workflows from writing silently but is not a security boundary against a compromised Owner session.
_Avoid_: Authorization, Mac permission

**Sync Metadata**:
Bounded, non-content state needed for continuity, such as unread counts, timestamps, opaque identifiers, and deduplication keys.
_Avoid_: Cache, history
