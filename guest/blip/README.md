# Pinned Blip runner seam (#14)

This is a **staged, fixture-tested adapter**, not a released Messages surface.
It carries a temporary patch against `nixfred/blip` commit
`f06f7deae0cf1dd4218966e95c1c8de15e9111c3`. The archive, patch, and MIT license
identities are in `pin.json`; the original archive and Fred Nix's license are
retained in `upstream/`. No upstream issue or PR has been posted by this change.

The shared `bridge/linux/blip-shim` selects the transport below Blip's existing
collector, thread, send queue, and QML call sites. Absent `transport=`, SSH is
still the default. Its dedicated-key confinement, `ssh -n` probe, stdin handling,
Remote Login instructions, and normal setup path are unchanged. An unknown
transport fails closed; Link failure never falls back to SSH.

## Prepare and verify

Prerequisites: Python 3.12+, Bun 1.4.2, Bash 4.4+, and `patch`. Typechecking uses
exact development dependencies in `package.json` and `bun.lock`:

```sh
cd guest/blip
bun install --frozen-lockfile
bun run typecheck
cd ../..
python3 guest/blip/prepare.py --output .build/blip-review
python3 guest/blip/test.py
make test-blip-linux
make test
```

Preparation is offline and refuses an existing output directory, altered
archive/license/patch, or inexact patch application. It stages before publishing
and writes `TRY-OMARCHY-PROVENANCE.json`, including the project adapter's SHA-256.
The resulting source tree is the component build; there is no new factory
package or host binary in this ticket. Do not copy it into an existing Workspace.

`make test` runs the adapter's process-boundary tests and typecheck in addition
to the existing project suites. `make test-blip-linux` builds a disposable image
and runs those tests, the unchanged upstream Bun and Python bridge fixtures,
and shellcheck with networking disabled. The image build downloads test-only
packages; it does not produce factory artifacts. The upstream suite requires
Linux (`/proc/self/fd`) and starts with `TZ=UTC`; macOS failures in those fixtures
are not evidence of a transport regression. No real Messages database, contact,
message send, desktop, or Apple permission is used. No QML files are modified.

## Explicit selection and activation gate

In a future supported **new/reset** Workspace, the prepared source's command is:

```sh
scripts/blip-setup --transport=omarchy-link
```

It first checks the local `omarchy-link status` response. Only a compatible,
available, unlocked Owner session with all three Messages read Capabilities and
`blipAdapterVersion: 1` can proceed. It installs the same shims plus
`blip-link.ts`, retains the upstream `bin_dir` policy and unrelated preferences,
writes a mode-0600 `bridge.conf`, and sets `transport=omarchy-link` and
`push_read=off`. It does not generate keys, probe SSH, install Mac scripts,
request permissions, add a widget, or rewrite bar layouts. Existing unrelated
executables and per-file symlinks are refused, not replaced. Running the normal
SSH setup explicitly selects SSH again; user preferences remain preserved.

**The current production broker does not advertise this adapter version or
implement its Messages calls. Setup and direct use therefore fail closed today.**
The version field is a guest-packaging compatibility gate, not a new generic
host Capability and not a security credential. Do not add it to production status
merely because the shim is installed. Issues #15-19 must first provide the typed
host operations, visible write review, and the reduced text-only UI policy:
no private notification previews, persistent private group metadata, attachment
or link-preview fetching, new-recipient compose, or content retained after lock
or surface close. Existing upstream SSH behavior intentionally remains intact.
The broader upstream UI has different privacy policies and is **not approved for
live Link data** by this seam alone.

## Adapter v1 contract for the later Messages slice

This section specifies the fixture-tested **guest CLI compatibility contract**,
not a claim that the host wire protocol already implements these payloads.
The guest broker must translate and validate these typed requests; there is no
arbitrary SQL, AppleScript, shell, file, or remote-tool forwarding route.

`omarchy-link status` must return `available`, `hostAvailable`, and
`contentAllowed` as `true`, `blipAdapterVersion` as `1`, and a `capabilities` array
containing `messages.conversations.list`, `messages.thread.list`, and
`messages.unread.get`. Writes additionally require `messages.send.propose`.
`messagesRevision` is a nonnegative safe integer changed by content-free Messages
Invalidations. No body, title, handle, or count is part of a watch notification.

| Blip shim invocation | Local CLI request |
| --- | --- |
| `imsg --json recent N` | `omarchy-link call` stdin: `{"method":"messages.conversations.list","view":"recent","limit":N}` |
| `imsg --json chats N` | Same method, `view: "chats"` |
| `imsg --json groups` | Same method, `view: "groups", limit: 300` |
| `imsg --json [--rich] thread --chat ID N` | `omarchy-link call` stdin: `{"method":"messages.thread.list","conversationId":ID,"limit":N}` |
| `imsg-send --to ID` or `--chat-id ID`, with `--text-stdin` | `omarchy-link create-message` stdin: `{"conversationId":ID,"text":TEXT}` |
| `imsg watch` | Poll content-free status every 250 ms; emit `ready`, `changed`, or `hb` for the existing debounce/refresh consumer |

Read replies are `{"rows":[...]}` in the pinned Blip fixtures' shapes (recent
messages, chats, group metadata, or thread messages). The future guest mapper
must preserve identity/alias, sender/self, UTC ordering, unread, and failure/echo
semantics required by those fixtures. It must omit rich media/active content.
Read limits are 1-8192 rows, responses at most 64 KiB, and per-CLI calls at most
two seconds. Results exceeding the requested row count are rejected, not silently
truncated. Status is rechecked before content leaves the adapter. A locked,
unavailable, or incompatible session terminates the watcher; reopening and
clearing UI content remain the later surface's responsibility.

The send CLI must canonicalize an **existing** conversation on the hosting Mac
and obtain a fresh visible Review Interlock. `--to` is never authorization to
compose to a new recipient, and `--chat-id` must not execute an arbitrary host
identifier. `--service` becomes an `expectedService` check, not a route override.
The adapter ignores `--yes`/`--keep-dashes` for authorization and never forwards
approval. Text is exact UTF-8, at most 16 KiB, stdin-only; empty, oversized,
invalid UTF-8, file, and argv-body requests are refused. Review has a 120-second
client deadline. Only `{"outcome":"accepted"}` yields exit zero and the literal
`accepted`; it never claims delivery. Other outcomes, errors, and disconnects
are nonzero, without replay. A new attempt must be canonicalized and reviewed
again; inspect Messages after any uncertain result. #18 owns one-shot execution
and #19 owns delivery reconciliation.

Adapter diagnostics are fixed content-free strings; child stderr is discarded.
No request/response is stored or logged. Core dumps are disabled by the shim.
`imsg-read`, Contacts, attachments, search, and other unsupported calls always
fail locally, even if a user changes Blip preferences. Thus this transport cannot
push Apple read state or emit a read receipt through those tools.

## Refresh and removal

To refresh, review the upstream diff and its fixtures, download the exact new
commit archive, update source/license identities together, rebase the two-file
patch without fuzz or offsets, and update `patchSha256`. Review `blip-link.ts`
against the actual guest CLI contract before advancing the adapter version.
Run both test entry points and retain all upstream licenses/provenance.

Remove this temporary patch and archive when a reviewed upstream release offers
the equivalent explicit local transport seam. Replace the pin with that release,
retain the process-boundary/privacy tests and guest mapping, and verify SSH
fixtures and setup again. Do not carry a parallel UI/state fork forward.
