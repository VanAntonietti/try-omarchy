import Foundation
import Testing
@testable import OmarchyVMHelper

@Suite("Omarchy Link Calendar adapter")
struct OmarchyLinkCalendarAdapterTests {
    @Test("fake agenda Queries cross the injectable Calendar boundary")
    func queriesInjectedProvider() throws {
        let provider = RecordingCalendarProvider()
        var host = OmarchyLinkFakeHost(
            serviceModes: .init(calendar: .read, messages: .off, notes: .off),
            calendarProvider: provider
        )
        _ = try host.receive(hello())
        _ = try host.receive(try OmarchyLinkFrameCodec.encodeJSONObject([
            "type": "request",
            "id": "agenda",
            "method": "calendar.events.list",
            "params": [
                "start": "2026-09-14T00:00:00Z",
                "end": "2026-09-21T00:00:00Z",
                "calendarIds": ["invented-focus"],
            ],
        ]))

        let reply = try #require(try messages(host.complete("agenda")).first)
        #expect(provider.queries.count == 1)
        #expect(provider.queries.first?.calendarIDs == Set(["invented-focus"]))
        #expect(reply["type"] as? String == "response")
        #expect(reply["id"] as? String == "agenda")
        let result = try #require(reply["result"] as? [String: Any])
        let events = try #require(result["events"] as? [[String: Any]])
        let event = try #require(events.first)
        #expect(event["id"] as? String == "invented-planning")
        #expect(event["calendarId"] as? String == "invented-focus")
        #expect(event["title"] as? String == "Project Aurora planning")
        #expect(event["startsAt"] as? String == "2026-09-14T09:00:00Z")
        #expect(event["endsAt"] as? String == "2026-09-14T09:45:00Z")
        #expect(event["allDay"] as? Bool == false)
    }

    @Test("schema-invalid agenda ranges fail before reaching an adapter")
    func rejectsInvalidQuery() throws {
        let provider = RecordingCalendarProvider()
        var host = OmarchyLinkFakeHost(
            serviceModes: .init(calendar: .read, messages: .off, notes: .off),
            calendarProvider: provider
        )
        _ = try host.receive(hello())

        #expect(throws: OmarchyLinkProtocolError.invalidMessage) {
            try host.receive(try OmarchyLinkFrameCodec.encodeJSONObject([
                "type": "request",
                "id": "backwards",
                "method": "calendar.events.list",
                "params": [
                    "start": "2026-09-21T00:00:00Z",
                    "end": "2026-09-14T00:00:00Z",
                    "calendarIds": [],
                ],
            ]))
        }
        #expect(provider.queries.isEmpty)
    }

    @Test("the native EventKit adapter compiles behind the same replaceable boundary")
    func nativeAdapterConforms() {
        func acceptsCalendarProvider<T: OmarchyLinkCalendarProviding>(_: T.Type) {}
        acceptsCalendarProvider(EventKitOmarchyLinkCalendarAdapter.self)
    }

    private func hello() throws -> Data {
        try OmarchyLinkFrameCodec.encodeJSONObject([
            "type": "request", "id": "hello", "method": "session.hello",
            "params": [
                "client": ["name": "fake-guest", "version": "1"],
                "protocol": ["major": 1, "minor": 0],
            ],
        ])
    }

    private func messages(_ bytes: Data) throws -> [NSDictionary] {
        var decoder = OmarchyLinkFrameDecoder()
        return try decoder.append(bytes).map {
            NSDictionary(dictionary: try OmarchyLinkFrameCodec.decodeJSONObject($0))
        }
    }
}

private final class RecordingCalendarProvider: OmarchyLinkCalendarProviding {
    private(set) var queries: [OmarchyLinkCalendarQuery] = []

    func calendars() throws -> [OmarchyLinkCalendar] {
        [OmarchyLinkCalendar(id: "invented-focus", title: "Invented Focus")]
    }

    func events(matching query: OmarchyLinkCalendarQuery) throws -> [OmarchyLinkCalendarEvent] {
        queries.append(query)
        return [OmarchyLinkCalendarEvent(
            id: "invented-planning",
            calendarID: "invented-focus",
            title: "Project Aurora planning",
            startDate: try date("2026-09-14T09:00:00Z"),
            endDate: try date("2026-09-14T09:45:00Z"),
            isAllDay: false
        )]
    }

    private func date(_ value: String) throws -> Date {
        try #require(ISO8601DateFormatter().date(from: value))
    }
}
