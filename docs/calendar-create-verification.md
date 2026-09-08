# Opt-in Calendar creation

Core + Calendar is available without a development flag for **new/reset
Workspaces** built with the current guest image. Existing persistent disks are
not migrated; app updates do not inject a new broker into them. Ephemeral runs
have no Link channel. The normal Calendar agenda remains read-only; creation
uses the separate visible workflow below. Use disposable calendars and invented
events for verification.

## Enable and use

1. Launch the hosting Mac app normally. For a new/reset Workspace, first start
   it once to provision its identity, then shut it down. In the Mac start menu,
   choose Calendar **Read & Write**, use **Allow Calendar…** to grant full
   Calendar access, and start the Workspace again. Off, Read, and a missing
   grant cannot create; the guest cannot request an Apple prompt. Denied access
   is remediated in System Settings > Privacy & Security > Calendars. A grant
   does not widen a Service Mode, and a reset returns every mode to Off.
2. In the Owner's graphical guest terminal, check the normally enabled broker:

   ```sh
   omarchy-link status
   ```

   Status must advertise `calendar.events.create.perform`. The user service
   must have a usable Wayland environment and active, unlocked logind session.
   Missing Quickshell or an inaccessible display fails closed.
3. Inspect `calendar.calendars.list` using `omarchy-link call` stdin and choose
   a disposable writable calendar ID. Do not redirect private results to disk
   or logs. Read-only destinations are rejected by the host.
4. Run `omarchy-link create-calendar` in that graphical terminal. Paste one
   JSON object into the **running command's stdin**, then press Ctrl-D:

   ```json
   {"title":"Invented disposable event","startsAt":"2026-09-14T09:00:00Z","endsAt":"2026-09-14T10:00:00Z","calendarId":"CHOSEN-DISPOSABLE-ID"}
   ```

   Substitute the date and ID only in the command's stdin, not in shell
   arguments, shell history, scripts, temporary files, or issue reports.
   Timestamps must be canonical UTC instants; title is trimmed and bounded to
   512 UTF-8 bytes, control characters are rejected, and duration is at most
   eight days. Only these four fields are accepted.
5. The **broker-owned Quickshell window** displays the exact host-canonical
   title, UTC start/end, calendar name, and calendar ID as plain text. Approve
   once or reject. The terminal reports `succeeded`, `failed`, or `uncertain`;
   `succeeded` means EventKit saved the event, not cloud delivery. No attendee,
   invitation, recurrence, update, or delete operation is supported.

The generic `call` CLI cannot approve or execute. `create-calendar` refuses
headless output. Local IPC accepts a create request but exposes no perform or
approval method: the broker itself launches and monitors the fixed renderer.
This Review Interlock remains a safety control, **not** isolation from a
compromised Owner or guest root. Enabling a Mac Service trusts the Owner session.

The review has a 110-second deadline; host proposals expire after 120 seconds
and at most 32 are held in memory. Only one guest review is active at a time.
Creation consumes a proposal before EventKit. Changed/unwritable destinations
fail without a save. A save exception is reconciled only if EventKit supplied an exact event identifier
and a fresh store can find that event. No title/time matching or second save is
used; absent evidence, revoked access, or a lost execution result stays explicitly
`uncertain`. Neither broker nor host automatically replays a create.

The host-issued proposal ID is the per-session idempotency key. Repeating an
accepted key returns its recorded outcome (or positively reconciled success),
never another save. Wire request IDs must still be fresh. At most 1,024 completed
or reserved outcomes are retained in memory; exhaustion refuses new proposals
without evicting accepted keys or disabling reads. Only IDs and outcomes remain
after execution, not titles or event content. Pending proposals and outcome
metadata are discarded when the host channel ends; they are not persisted or
transferred to a restarted bridge. An old proposal cannot execute in a fresh
session. This does **not** prove an earlier uncertain write never happened.

Any user retry after uncertainty or conflict starts with a new canonical proposal
and new visible review; inspect Calendar first to avoid manually making a
duplicate. Do not treat a new session as permission to retry silently.

## Privacy and trust

Enabling Calendar Read or Read & Write exposes private Calendar data to **every
process in the trusted Owner session**, not just this UI. The Review Interlock
is mandatory for supported writes, but does not defend against compromised
same-user or root guest code. Lock or missing graphical-session state fails
closed. Try Omarchy keeps Calendar content in memory/private IPC only, with no
content cache, request-body logging, or proposal files; the intended created
event is of course saved in Calendar. Do not redirect CLI read results to logs.
Only content-free status and bounded, in-memory Sync Metadata are retained.

## Disposable verification (manual, not replaced by automated tests)

- Approve an invented event and confirm exactly one event with the displayed
  title, instants, and destination exists on the Mac. Try literal `<b>` text.
- Reject, dismiss, close, and let a review expire: no event is created.
- Lock with Hyprlock while the window is open, including just before approval.
  The window and its content process must close promptly; unlock must not
  reopen it. Test inactive and unknown logind state too.
- Remove the selected disposable calendar or make it unwritable during review:
  no event is created. A rename also requires a new proposal.
- Stop the host bridge during review: no execution. Stop it after approval:
  report uncertainty when a result cannot be proven; never replay on reconnect.
- Verify creation works with no development variable in either process. Repeat
  with Off, Read, denied/revoked EventKit, missing display, and headless CLI
  output: no write. The VM stays usable.
- Check that the service, renderer, and launcher logs contain no invented
  titles, no content files were created, and no bar layout was changed.
- Retry after conflict or uncertainty: require a fresh canonical review. Reject
  that review and confirm no second event appears. Start a fresh Link Session
  and confirm no old create is replayed.
- Delete disposable events/calendars and return Calendar to Off for the next
  launch.

Record only platform versions and pass/fail, never personal Calendar payloads.
Automated Swift fake-store tests cover canonicalization, bounds, mode/grant
policy, changed destinations, duplicate suppression, uncertainty/reconciliation,
discarded results, and fresh sessions. Rust private-channel tests cover fresh
review after conflict/uncertainty, late results, reconnect without replay, lock,
missing UI, and no-flag CLI availability;
Python tests exercise the actual private review pipe with an invented renderer.
Real EventKit writes and Quickshell/Hyprlock behavior still require this manual run.
