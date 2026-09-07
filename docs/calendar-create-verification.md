# Developer-gated Calendar creation (#12)

This is **not a release-ready write feature**. #13 owns per-session idempotency
keys, reconciliation, and removing the development gate. Use only disposable
new/reset Workspaces and invented events. Existing disks are not migrated.
The normal Calendar agenda remains read-only.

## Enable and use

1. Launch the hosting Mac app/helper with `OMARCHY_LINK_DEVELOPMENT=1` in its
   environment. Choose Calendar **Read & Write**, grant full Calendar access
   in the visible Mac start menu, and relaunch the Workspace. Off, Read, and
   a missing grant cannot create; the guest cannot request an Apple prompt.
2. In the Owner's graphical guest terminal, enable the guest broker gate for
   this run (no user data goes into these commands):

   ```sh
   export OMARCHY_LINK_DEVELOPMENT=1
   systemctl --user import-environment OMARCHY_LINK_DEVELOPMENT WAYLAND_DISPLAY
   systemctl --user restart omarchy-link.service
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
fail without a save. A save exception or lost execution result is uncertain.
Neither broker nor host automatically replays a create. Any retry starts with
new input, a new canonical proposal, and new visible review; inspect Calendar
first after uncertainty to avoid manually making a duplicate.

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
- Repeat with Off, Read, denied/revoked EventKit, no guest gate, missing display,
  and headless CLI output: no write. Other services and the VM stay usable.
- Check that the service, renderer, and launcher logs contain no invented
  titles, no content files were created, and no bar layout was changed.
- Delete disposable events/calendars, unset the guest development variable with
  `systemctl --user unset-environment OMARCHY_LINK_DEVELOPMENT`, restart the
  broker, and restart the Mac app without the development flag.

Record only platform versions and pass/fail, never personal Calendar payloads.
Automated Swift fake-store tests cover canonicalization, bounds, mode/gate
policy, changed destinations, one-shot execution, and uncertain saves. Rust
private-channel tests cover review, lock, missing UI, disconnect, and outcomes;
Python tests exercise the actual private review pipe with an invented renderer.
Real EventKit writes and Quickshell/Hyprlock behavior still require this manual run.
