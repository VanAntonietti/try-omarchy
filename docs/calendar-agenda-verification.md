# Calendar agenda: disposable-event verification (#11)

Run on a disposable **new/reset Workspace** on an Apple Silicon hosting Mac.
Existing persistent disks are not migrated. Do not use personal event titles,
calendars, screenshots, logs, or issue attachments as evidence.

1. In macOS Calendar, create two disposable calendars and invented events:
   one today, one tomorrow, one crossing midnight, one all-day, and one just
   outside the seven-day window. Record only pass/fail, not returned bodies.
2. Launch with Calendar Off. Open **Omarchy Link Calendar** explicitly through
   the Omarchy application launcher. Confirm no Calendar data appears and the
   VM remains usable. Repeat with the Apple grant denied; verify start-menu
   remediation, with no permission prompt from the guest.
3. Grant access in the Mac start menu, choose Read, and relaunch. Open the
   surface. Verify Today, Next 7 days, both individual calendar filters, empty
   results, and literal rendering of a title such as `<b>Invented</b>`.
   Confirm existing/customized bar layouts are unchanged. Repeat with Read &
   Write: the agenda is identical and no write control appears.
4. Compare the guest's local dates with the disposable event instants. Use a
   disposable guest time zone with a DST boundary when practical; automated
   model tests cover New York spring/fall transitions and Tokyo midnight.
5. While the surface is open, add/change/remove invented events in macOS.
   Verify Invalidations refresh the agenda, with bursts coalesced (no faster
   than one refresh per two seconds). The sixty-second fallback handles a
   date rollover even without an Invalidation. Leave the surface open overnight
   and confirm fresh Queries still work the following day; new host/guest peers
   negotiate monotonic IDs rather than exhausting the fixture request budget.
   Automated invented-data tests also exercise more than 1,023 Queries.
   If a dense agenda exceeds the local IPC budget, verify the surface reports
   unavailability with no stale events while retaining the calendar choices.
   Select a narrower calendar filter/date range and confirm it remains queryable;
   it must not silently truncate events or disable Link.
6. Lock using the normal Omarchy lock action (Hyprlock). Verify the sensitive
   window closes within the bounded status/probe latency (normally under one
   second). Unlock: the window must not reopen. Explicitly reopen and verify
   fresh data. Repeat while a Query is outstanding. A missing/unknown logind
   session or inactive session must also fail closed. Check this specifically
   under the factory's actual graphical-session setup: no live desktop test
   is replaced by the injected lock probe used in automated tests.
7. Stop the host Link bridge during a Query. The surface must close without
   keeping stale data; the VM keeps running. Reopening cannot silently replay
   writes (none are supported). Confirm broker/service and desktop-launcher
   logs contain no invented titles and that no content cache was created.
8. Remove the disposable events and calendars on the Mac. Restore any changed
   guest time-zone setting. Report only platform versions and pass/fail for
   each step. Never attach private payloads or screenshots of personal data.

Automated evidence: Rust Owner-local IPC/fake-host tests cover correlated
Queries, exact UTC bounds and filters, lock-before/lock-during-query refusal,
content-free Invalidations, disconnect failure, and quiet logs. Python tests
exercise the deterministic model and the actual private-pipe driver with an
invented broker, including narrowing an unavailable agenda using retained
calendar choices and clearing content on lock. Quickshell rendering, real
logind/Hyprlock behavior, and real
EventKit Invalidations require the manual run above.
