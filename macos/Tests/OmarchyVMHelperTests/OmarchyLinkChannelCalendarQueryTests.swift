import Foundation
import Testing
@testable import OmarchyVMHelper

/// The production channel host answers Calendar Queries through the injected
/// bounded adapter. Every test uses invented adapters; no EventKit store or
/// personal Calendar data is reachable from this suite.
@Suite("Omarchy Link production channel Calendar Queries")
struct OmarchyLinkChannelCalendarQueryTests {
    private static let identity = OmarchyLinkWorkspaceIdentity(
        rawValue: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
    )!

    private struct StubCalendarAdapter: OmarchyLinkCalendarProviding {
        var stubbedCalendars: [OmarchyLinkCalendar] = [
            OmarchyLinkCalendar(id: "cal-work", title: "Work"),
            OmarchyLinkCalendar(id: "cal-home", title: "Home"),
        ]
        var stubbedEvents: [OmarchyLinkCalendarEvent] = []
        var lastQuery: (OmarchyLinkCalendarQuery) -> Void = { _ in }

        func calendars() throws -> [OmarchyLinkCalendar] { stubbedCalendars }

        func events(matching query: OmarchyLinkCalendarQuery) throws -> [OmarchyLinkCalendarEvent] {
            lastQuery(query)
            return stubbedEvents.filter { event in
                event.startDate < query.endDate
                    && event.endDate > query.startDate
                    && (query.calendarIDs.isEmpty || query.calendarIDs.contains(event.calendarID))
            }
        }
    }

    private func makeNegotiatedHost(
        adapter: (any OmarchyLinkCalendarProviding)?,
        calendarMode: OmarchyLinkServiceMode = .read,
        requestIDPolicy: String = "legacy"
    ) throws -> OmarchyLinkChannelHost {
        var host = OmarchyLinkChannelHost(
            serviceModes: OmarchyLinkServiceModes(
                calendar: calendarMode, messages: .off, notes: .off
            ),
            workspaceIdentity: Self.identity,
            calendarAuthorization: .authorized,
            calendarProvider: adapter
        )
        let hello = try frame([
            "type": "request", "id": "hello-1", "method": "session.hello",
            "params": [
                "client": ["name": "omarchy-link", "version": "0.0.1"],
                "protocol": ["major": 1, "minor": 0],
                "workspaceIdentity": Self.identity.rawValue,
                "requestIdPolicy": requestIDPolicy,
            ],
        ])
        _ = try host.receive(hello)
        return host
    }

    private func frame(_ object: [String: Any]) throws -> Data {
        try OmarchyLinkFrameCodec.encodeJSONObject(object)
    }

    private func singleReply(
        from host: inout OmarchyLinkChannelHost,
        for request: [String: Any]
    ) throws -> [String: Any] {
        var decoder = OmarchyLinkFrameDecoder()
        let payloads = try decoder.append(try host.receive(try frame(request)))
        try #require(payloads.count == 1)
        return try OmarchyLinkFrameCodec.decodeJSONObject(payloads[0])
    }

    @Test("an advertised calendar list Query answers with the adapter's normalized calendars")
    func servesCalendarList() throws {
        var host = try makeNegotiatedHost(adapter: StubCalendarAdapter())
        let reply = try singleReply(from: &host, for: [
            "type": "request", "id": "q1", "method": "calendar.calendars.list", "params": [:],
        ])
        #expect(reply["type"] as? String == "response")
        #expect(reply["id"] as? String == "q1")
        let result = try #require(reply["result"] as? [String: Any])
        let calendars = try #require(result["calendars"] as? [[String: Any]])
        #expect(calendars.count == 2)
        #expect(calendars[0]["id"] as? String == "cal-work")
        #expect(calendars[0]["title"] as? String == "Work")
        #expect(Set(calendars[0].keys) == ["id", "title"])
        guard case .available = host.status else {
            Issue.record("a served Query must keep the Link Session available")
            return
        }
    }

    @Test("an agenda Query with an explicit bounded range answers normalized events")
    func servesBoundedEventList() throws {
        var adapter = StubCalendarAdapter()
        adapter.stubbedEvents = [
            OmarchyLinkCalendarEvent(
                id: "event-standup",
                calendarID: "cal-work",
                title: "Standup",
                startDate: date("2026-09-14T09:00:00Z"),
                endDate: date("2026-09-14T09:15:00Z"),
                isAllDay: false
            ),
            OmarchyLinkCalendarEvent(
                id: "event-errand",
                calendarID: "cal-home",
                title: "Errand",
                startDate: date("2026-09-16T17:00:00Z"),
                endDate: date("2026-09-16T18:00:00Z"),
                isAllDay: false
            ),
        ]
        var host = try makeNegotiatedHost(adapter: adapter)
        let reply = try singleReply(from: &host, for: [
            "type": "request", "id": "q2", "method": "calendar.events.list",
            "params": [
                "start": "2026-09-14T00:00:00Z",
                "end": "2026-09-21T00:00:00Z",
                "calendarIds": ["cal-work"],
            ],
        ])
        let result = try #require(reply["result"] as? [String: Any])
        let events = try #require(result["events"] as? [[String: Any]])
        #expect(events.count == 1)
        #expect(events[0]["id"] as? String == "event-standup")
        #expect(events[0]["calendarId"] as? String == "cal-work")
        #expect(events[0]["title"] as? String == "Standup")
        #expect(events[0]["startsAt"] as? String == "2026-09-14T09:00:00Z")
        #expect(events[0]["endsAt"] as? String == "2026-09-14T09:15:00Z")
        #expect(events[0]["allDay"] as? Bool == false)
        #expect(Set(events[0].keys) == ["id", "calendarId", "title", "startsAt", "endsAt", "allDay"])
    }

    @Test("an unbounded or malformed agenda range is a terminal protocol violation")
    func rejectsUnboundedRanges() throws {
        let invalidParameters: [[String: Any]] = [
            // More than the seven-day agenda window plus time-zone slack.
            [
                "start": "2026-09-14T00:00:00Z", "end": "2026-09-23T00:00:01Z",
                "calendarIds": [String](),
            ],
            // Missing explicit bounds.
            ["start": "2026-09-14T00:00:00Z", "calendarIds": [String]()],
            // Reversed bounds.
            [
                "start": "2026-09-15T00:00:00Z", "end": "2026-09-14T00:00:00Z",
                "calendarIds": [String](),
            ],
            // Non-canonical timestamps cannot smuggle ambiguous instants.
            [
                "start": "2026-09-14", "end": "2026-09-15T00:00:00Z",
                "calendarIds": [String](),
            ],
        ]
        for parameters in invalidParameters {
            var host = try makeNegotiatedHost(adapter: StubCalendarAdapter())
            #expect(throws: OmarchyLinkProtocolError.invalidMessage) {
                _ = try host.receive(try frame([
                    "type": "request", "id": "q-bad", "method": "calendar.events.list",
                    "params": parameters,
                ]))
            }
        }
    }

    @Test("agenda bounds are exact instants across time-zone day boundaries")
    func honorsTimeZoneDayBoundaries() throws {
        // A guest at UTC+13 asks for its local 2026-09-14 through seven days:
        // both bounds are explicit UTC instants at local midnight.
        let rangeStart = "2026-09-13T11:00:00Z"
        let rangeEnd = "2026-09-20T11:00:00Z"
        var adapter = StubCalendarAdapter()
        adapter.stubbedEvents = [
            // Ends exactly at the range start: no overlap, excluded.
            OmarchyLinkCalendarEvent(
                id: "event-before",
                calendarID: "cal-work",
                title: "Yesterday late meeting",
                startDate: date("2026-09-13T10:00:00Z"),
                endDate: date(rangeStart),
                isAllDay: false
            ),
            // Straddles the local-midnight boundary: overlaps, included.
            OmarchyLinkCalendarEvent(
                id: "event-straddle",
                calendarID: "cal-work",
                title: "Overnight maintenance",
                startDate: date("2026-09-13T10:30:00Z"),
                endDate: date("2026-09-13T11:30:00Z"),
                isAllDay: false
            ),
            // Starts exactly at the range end: no overlap, excluded.
            OmarchyLinkCalendarEvent(
                id: "event-after",
                calendarID: "cal-work",
                title: "Next week kickoff",
                startDate: date(rangeEnd),
                endDate: date("2026-09-20T12:00:00Z"),
                isAllDay: false
            ),
        ]
        var observedQuery: OmarchyLinkCalendarQuery?
        let capture = QueryCapture()
        adapter.lastQuery = { capture.query = $0 }
        var host = try makeNegotiatedHost(adapter: adapter)
        let reply = try singleReply(from: &host, for: [
            "type": "request", "id": "q3", "method": "calendar.events.list",
            "params": ["start": rangeStart, "end": rangeEnd, "calendarIds": [String]()],
        ])
        observedQuery = capture.query
        let result = try #require(reply["result"] as? [String: Any])
        let events = try #require(result["events"] as? [[String: Any]])
        #expect(events.map { $0["id"] as? String } == ["event-straddle"])
        // The adapter received the guest's exact instants, not a re-derived
        // host-local day boundary.
        let query = try #require(observedQuery)
        #expect(query.startDate == date(rangeStart))
        #expect(query.endDate == date(rangeEnd))
    }

    @Test("Off and an absent grant answer Calendar Queries with typed unavailability")
    func refusesUnadvertisedCalendarQueries() throws {
        for (mode, authorization): (OmarchyLinkServiceMode, OmarchyLinkCalendarAuthorizationState)
            in [(.off, .authorized), (.read, .denied)] {
            var host = OmarchyLinkChannelHost(
                serviceModes: OmarchyLinkServiceModes(
                    calendar: mode, messages: .off, notes: .off
                ),
                workspaceIdentity: Self.identity,
                calendarAuthorization: authorization,
                calendarProvider: StubCalendarAdapter()
            )
            _ = try host.receive(try frame([
                "type": "request", "id": "hello-1", "method": "session.hello",
                "params": [
                    "client": ["name": "omarchy-link", "version": "0.0.1"],
                    "protocol": ["major": 1, "minor": 0],
                    "workspaceIdentity": Self.identity.rawValue,
                ],
            ]))
            for method in ["calendar.calendars.list", "calendar.events.list"] {
                let reply = try singleReply(from: &host, for: [
                    "type": "request", "id": "q-\(method)", "method": method, "params": [:],
                ])
                let error = try #require(reply["error"] as? [String: Any])
                #expect(error["code"] as? String == "request.method_unavailable")
            }
        }
    }

    @Test("an adapter failure is a typed unavailability that keeps the Link Session alive")
    func adapterFailureIsRecoverable() throws {
        struct FailingCalendarAdapter: OmarchyLinkCalendarProviding {
            struct Unavailable: Error {}
            func calendars() throws -> [OmarchyLinkCalendar] { throw Unavailable() }
            func events(
                matching query: OmarchyLinkCalendarQuery
            ) throws -> [OmarchyLinkCalendarEvent] { throw Unavailable() }
        }
        var host = try makeNegotiatedHost(adapter: FailingCalendarAdapter())
        let reply = try singleReply(from: &host, for: [
            "type": "request", "id": "q-fail", "method": "calendar.calendars.list", "params": [:],
        ])
        let error = try #require(reply["error"] as? [String: Any])
        #expect(error["code"] as? String == "service.unavailable")
        guard case .available = host.status else {
            Issue.record("adapter failure must not tear the Link Session down")
            return
        }
        // The next Query still reaches the host normally.
        let next = try singleReply(from: &host, for: [
            "type": "request", "id": "q-next", "method": "calendar.calendars.list", "params": [:],
        ])
        #expect((next["error"] as? [String: Any])?["code"] as? String == "service.unavailable")
    }

    @Test("negotiated monotonic Query IDs permit long-lived agendas without permitting replay")
    func longLivedAgenda() throws {
        var host = try makeNegotiatedHost(
            adapter: StubCalendarAdapter(), requestIDPolicy: "monotonic-q"
        )
        for index in 1...1030 {
            let reply = try singleReply(from: &host, for: [
                "type": "request", "id": "q\(index)",
                "method": "calendar.calendars.list", "params": [:],
            ])
            #expect(reply["type"] as? String == "response")
        }
        #expect(throws: OmarchyLinkProtocolError.invalidMessage) {
            _ = try host.receive(try frame([
                "type": "request", "id": "q1", "method": "calendar.calendars.list", "params": [:],
            ]))
        }
    }

    @Test("an agenda exceeding the frame budget fails without disabling subsequent Queries")
    func oversizedAgendaIsRecoverable() throws {
        var adapter = StubCalendarAdapter()
        adapter.stubbedEvents = (0..<128).map { index in
            OmarchyLinkCalendarEvent(
                id: "invented-\(index)", calendarID: "cal-work",
                title: String(repeating: "x", count: 512),
                startDate: date("2026-09-14T09:00:00Z"),
                endDate: date("2026-09-14T10:00:00Z"), isAllDay: false
            )
        }
        var host = try makeNegotiatedHost(adapter: adapter)
        let reply = try singleReply(from: &host, for: [
            "type": "request", "id": "large", "method": "calendar.events.list",
            "params": ["start": "2026-09-14T00:00:00Z", "end": "2026-09-15T00:00:00Z",
                       "calendarIds": [String]()],
        ])
        #expect(reply["type"] as? String == "error")
        #expect((reply["error"] as? [String: Any])?["code"] as? String == "service.unavailable")
        let next = try singleReply(from: &host, for: [
            "type": "request", "id": "after-large", "method": "calendar.calendars.list",
            "params": [:],
        ])
        #expect(next["type"] as? String == "response")
    }

    @Test("a Calendar Invalidation is a content-free event only when Calendar is advertised")
    func emitsContentFreeInvalidation() throws {
        var host = try makeNegotiatedHost(adapter: StubCalendarAdapter())
        var decoder = OmarchyLinkFrameDecoder()
        let payloads = try decoder.append(try host.invalidate(.calendar))
        try #require(payloads.count == 1)
        let event = try OmarchyLinkFrameCodec.decodeJSONObject(payloads[0])
        #expect(event["type"] as? String == "event")
        #expect(event["event"] as? String == "invalidation")
        #expect(event["service"] as? String == "calendar")
        #expect(Set(event.keys) == ["type", "event", "service"])

        // Before the handshake or with Calendar off, nothing is emitted.
        var unnegotiated = OmarchyLinkChannelHost(
            serviceModes: OmarchyLinkServiceModes(calendar: .read, messages: .off, notes: .off),
            workspaceIdentity: Self.identity,
            calendarAuthorization: .authorized,
            calendarProvider: StubCalendarAdapter()
        )
        #expect(try unnegotiated.invalidate(.calendar).isEmpty)
        var off = try makeNegotiatedHost(adapter: StubCalendarAdapter(), calendarMode: .off)
        #expect(try off.invalidate(.calendar).isEmpty)
    }

    private final class QueryCapture: @unchecked Sendable {
        var query: OmarchyLinkCalendarQuery?
    }

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }
}
