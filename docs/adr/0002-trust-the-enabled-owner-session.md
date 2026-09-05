---
status: proposed
---

# Trust the enabled Owner session

When the Mac user enables a Mac Service for a workspace, Omarchy Link treats processes running as that workspace's Owner as trusted to query the service and submit Mutation Proposals. Every supported write still passes through a canonical, visible Review Interlock with no supported headless bypass, but that interlock is a safety control rather than a defense against compromised same-user or root code in the guest.

## Considered options

Native Mac approval for every operation would create a stronger guest/host boundary but make routine messaging, calendar, and note capture cross desktops twice. Per-client guest tokens would imply isolation a mutable guest cannot guarantee. Treating enablement as blanket write approval would allow agents and accidental commands to mutate host data invisibly.

## Consequences

Service modes default to Off, are bound to a host-validated workspace identity, and reset when the workspace does. Documentation must state that enabled reads expose private data to the Owner session. The guest broker must mediate writes, show host-canonical targets and content, refuse them while locked or without its review UI, never replay them automatically, and require a fresh review after uncertain or conflicting outcomes.
