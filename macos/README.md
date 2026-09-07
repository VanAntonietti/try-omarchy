# Native macOS app

This directory contains the Apple Silicon application layer:

- a Swift/AppKit lifecycle and permission helper;
- a pinned, patched QEMU ARM64 runtime using HVF and Cocoa/VirGL;
- persistent-disk, input, audio-device, camera, clipboard, shared-folder, signing, and DMG tooling.

Use the root Makefile for normal development:

```sh
make runtime   # macos/.build/qemu-gpu-runtime
make app       # dist/app.noindex/Try Omarchy.app
make run
make package   # signed and notarized dist/TryOmarchy.dmg
make release   # signed and notarized dist/TryOmarchy.dmg
make test
```

`make app` requires an existing `dist/guest/` and staged QEMU runtime. A full
`make build` creates both first.

The staged runtime is a complete, checksum-pinned Apple Silicon closure built
for macOS 15.0. Runtime and app assembly do not resolve libraries or `zstd`
from the host Homebrew prefix, so building on a newer macOS release cannot
silently raise the app's deployment target.

`make release` defaults to the maintainer's Developer ID Application identity
and `try-omarchy` notarytool profile. The app builder is also directly usable
for release signing and notarization:

```sh
macos/build-app.sh \
  --dmg \
  --guest-dir dist/guest \
  --sign-identity "Developer ID Application: Example (TEAMID)" \
  --notarize-profile try-omarchy
```

Local app builds are ad-hoc signed by default. To keep Accessibility and other
macOS privacy grants across rebuilds, use a stable Apple Development identity:

```sh
make run DEVELOPMENT_SIGN_IDENTITY="Apple Development: Your Name (TEAMID)"
```

`make package` uses `PACKAGE_SIGN_IDENTITY` and `PACKAGE_NOTARY_PROFILE`, which
default to the configured release credentials. It fails instead of producing
an unnotarized fallback.
Runtime caches are private to `macos/.build/`; user-facing output always goes
to `dist/`. The generated app lives inside `dist/app.noindex/`, which keeps a
development build from appearing beside an installed copy in Command-Space.

Normal app launches maintain one stable user VM disk under
`~/Library/Application Support/Try Omarchy/VM/v1`. Storage integration tests
and specialized development runs can opt into identity-keyed parallel disks by
setting `OMARCHY_QEMU_GPU_DEVELOPMENT_MULTI_DISK=1`; release behavior leaves it
unset. Each persistent disk keeps the identity of the factory that created it
and is paired with a private, validated boot kit containing that factory's
kernel, initramfs, and base command line. App updates reuse the disk and its
boot kit; the current bundled factory is selected only for a new, reset, or
ephemeral VM. This keeps an older root filesystem on its matching kernel-module
ABI and lets an existing VM launch without first materializing the new factory
disk.

### Omarchy Link Workspace identity

New persistent Workspaces also receive a random, lowercase UUIDv4, distinct
from the factory digest and storage path. It is the key for per-Workspace
Service Modes, not a secret or an Apple permission grant. Factory Reset creates
a different identity even with the same factory and folder; old identity-keyed
choices must not be carried forward. The live Link channel binds this
identity: the launcher passes it to the supervised `--bridge-omarchy-link`
helper together with the one-time Service Mode snapshot printed by
`--link-session-modes`, and the guest handshake must present the same value
before any Capability is advertised.

### Omarchy Link Service Modes

Per-Workspace Service Modes (Off, Read, or Read & Write for Calendar,
Messages, and Notes) persist in launcher `UserDefaults`, keyed by the
validated Workspace identity. Everything defaults to Off, and anything
unrecognized — a malformed payload, a future schema, or an unknown mode value —
loads as Off rather than a broader mode. A bounded number of recent Workspace
entries is retained; a Factory Reset changes the identity, so the reset
Workspace starts from all-Off regardless of old state.

With `OMARCHY_LINK_DEVELOPMENT=1` the start menu shows a development-only
Omarchy Link row that cycles each service's mode and states the trust
consequence: enabling Read or Read & Write exposes that service's private data
to every process in the trusted Owner session. The row presents Try Omarchy
choices, never Apple permissions; released builds render no Link row. An
invalid or missing Workspace identity shows the row as unavailable without
mode choices and without blocking the VM.

A Link Session receives one immutable Service Mode snapshot captured at
launch (`OmarchyLinkServiceModePolicy.sessionModes`); changing preferences
afterwards affects only the next launch. Ephemeral launches use explicit
one-run choices held in memory and never written to the store, so they cannot
persist to a later launch. Off advertises no Capability for that service, Read
advertises no mutation Capability, and Read & Write proposals still pass the
Review Interlock.

The locked storage transaction writes one host-owned extended attribute,
`dev.tryomarchy.workspace-identity`, on the mode-0700 Workspace directory. Its
exact record is `v1:<uuid>:<volume-uuid>:<directory-inode>:<disk-inode>`.
The persistent volume UUID and both file identities are checked on every
selection; mount-time device numbers are deliberately not persisted, so
rebooting or reconnecting the same drive does not invalidate identity. The
record is written only in a new disk's staging directory, flushed with that
disk, then published by the existing atomic directory rename. Reset detaches the old directory and
its identity together. Interrupted staging/discarded directories are reclaimed,
never adopted as another Workspace's identity.

The signed native helper's local-only `--workspace-binding DIRECTORY` operation
supplies the stable binding. Its `--sync-storage PATH` operation performs checked
`fsync` and `F_FULLFSYNC` barriers on files and directories; `/bin/sync` alone is
not a durability guarantee. Storage flushes staged file contents and the
identity-bearing directory before publication, and the parent directory after
publication or reset detachment. A storage durability error aborts that storage
transaction rather than claiming success. Neither helper operation is exposed
through Link. To run a storage test file independently, first build the helper
with `swift build --package-path macos --disable-sandbox`; tests select that
local debug executable, while the signed launcher supplies its bundled helper.

An app update or same-volume folder rename retains identity. Copying/cloning
host state, replacing its disk or directory, moving it across volumes, losing
extended attributes, or substituting another Workspace's record disables Link
without blocking the VM. Missing or malformed state is never auto-repaired;
Factory Reset is the supported way to obtain a new identity. This guards
against accidental state substitution, not a compromised hosting Mac user who
can rewrite all host-owned state.

Storage selection exposes `QEMU_LINK_WORKSPACE_IDENTITY` and the corresponding
`tryomarchy.workspace_id=<uuid>` kernel token only after host validation. The
token presents identity without modifying guest disk contents. A Workspace-bound
host handshake requires the broker to echo it as `params.workspaceIdentity`
before advertising Capabilities. A mismatch makes that Link Session unavailable;
only explicit invented-data fixtures bypass this check. There is still no live
broker/channel consuming the token or accessing Mac Services.

**Existing persistent disks are not retrofitted:** no identity or guest
components are injected, even if they came from the current factory. They boot
without the token and remain usable without Link. Ephemeral launches likewise
receive no persistent identity or inherited Service Mode key in this slice.

### Older boot-kit migration

Schema-2 disks created before boot kits use a one-time preserving migration.
The first launcher pass reports that consent is required and exits before QEMU
starts. The start menu then explains that the disk and data stay intact, the
new factory is ignored for this VM, and the operation neither resets nor
upgrades Omarchy. **Cancel** returns to the menu; **Continue** authorizes only
that retry. The recovery-capable initramfs then attaches the old disk read-only,
exports its installed `/boot/Image`, `/boot/initramfs-linux.img`, and recorded
base command line over a private 9p share, and powers off without entering the
old userspace. The launcher validates and atomically stages that boot kit before
the normal launch. Unsupported storage or boot ABIs, and ambiguous multiple
legacy disks, still use the user-facing, confirmed Reset Omarchy flow.
That destructive flow keeps **Reset** disabled until the user types
`Try Omarchy` exactly in a native sheet. Cancelling or dismissing the sheet
returns control without invoking the storage reset.

The start menu can move that workspace to any APFS folder the user picks; the
folder is used exactly as chosen, never with a folder created inside it — a
folder with other files already in it, or a drive's top level, is refused
instead of restructured. The choice is stored in `UserDefaults` and published
to the launcher as `OMARCHY_QEMU_GPU_STATE_ROOT`. An inherited value of that
variable still wins, so the development and test override keeps working
unchanged. Reset composes its environment exactly as a launch does, so it
always erases the workspace the user is actually running.

Port forwarding is one versioned generic mapping list. The editor's **Add SSH**
action only inserts the ordinary TCP `2222 → 22` preset; users may edit it like
any other mapping. The signed shell parser remains the sole QEMU `hostfwd`
builder and derives boot-scoped sshd intent only from a fully valid TCP mapping
to guest port 22. No SSH-specific preference, port probe, status code, or
parallel forwarding path exists.

Ad-hoc signing identifies one exact build, so macOS intentionally invalidates
its privacy grants when that build is replaced. The app's **Open Settings**
action repairs a stale Accessibility entry and registers the installed build,
but a stable Apple Development or Developer ID signature is required for the
grant to survive future updates.

See the root `README.md`, `docs/architecture.md`, and `docs/releasing.md` for the
supported platform, runtime boundaries, and distribution checklist.
