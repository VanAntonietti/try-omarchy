import EventKit
import Foundation

struct OmarchyLinkCalendar: Equatable {
    let id: String
    let title: String
}

struct OmarchyLinkCalendarEvent: Equatable {
    let id: String
    let calendarID: String
    let title: String
    let startDate: Date
    let endDate: Date
    let isAllDay: Bool
}

struct OmarchyLinkCalendarQuery: Equatable {
    let startDate: Date
    let endDate: Date
    let calendarIDs: Set<String>
}

/// The host protocol depends on this bounded interface, not EventKit itself.
/// Tests and the development surface use invented implementations.
protocol OmarchyLinkCalendarProviding {
    func calendars() throws -> [OmarchyLinkCalendar]
    func events(matching query: OmarchyLinkCalendarQuery) throws -> [OmarchyLinkCalendarEvent]
}

/// Invented records only. Nothing here asks for Calendar access or constructs
/// an EventKit store.
struct InventedOmarchyLinkCalendarAdapter: OmarchyLinkCalendarProviding {
    func calendars() -> [OmarchyLinkCalendar] {
        [
            OmarchyLinkCalendar(id: "invented-focus", title: "Invented Focus"),
            OmarchyLinkCalendar(id: "invented-personal", title: "Invented Personal"),
        ]
    }

    func events(matching query: OmarchyLinkCalendarQuery) -> [OmarchyLinkCalendarEvent] {
        Self.events.filter { event in
            event.startDate < query.endDate
                && event.endDate > query.startDate
                && (query.calendarIDs.isEmpty || query.calendarIDs.contains(event.calendarID))
        }
    }

    private static let events = [
        event(
            id: "invented-planning",
            calendarID: "invented-focus",
            title: "Project Aurora planning",
            start: "2026-09-14T09:00:00Z",
            end: "2026-09-14T09:45:00Z"
        ),
        event(
            id: "invented-lunch",
            calendarID: "invented-personal",
            title: "Lunch with Morgan",
            start: "2026-09-14T12:30:00Z",
            end: "2026-09-14T13:30:00Z"
        ),
        event(
            id: "invented-review",
            calendarID: "invented-focus",
            title: "Design review",
            start: "2026-09-15T15:00:00Z",
            end: "2026-09-15T16:00:00Z"
        ),
        event(
            id: "invented-reminder",
            calendarID: "invented-personal",
            title: "Dentist reminder",
            start: "2026-09-17T08:30:00Z",
            end: "2026-09-17T09:00:00Z"
        ),
        event(
            id: "invented-wrap",
            calendarID: "invented-focus",
            title: "Weekly wrap-up",
            start: "2026-09-20T00:00:00Z",
            end: "2026-09-21T00:00:00Z",
            isAllDay: true
        ),
    ]

    private static func event(
        id: String,
        calendarID: String,
        title: String,
        start: String,
        end: String,
        isAllDay: Bool = false
    ) -> OmarchyLinkCalendarEvent {
        let formatter = ISO8601DateFormatter()
        return OmarchyLinkCalendarEvent(
            id: id,
            calendarID: calendarID,
            title: title,
            startDate: formatter.date(from: start)!,
            endDate: formatter.date(from: end)!,
            isAllDay: isAllDay
        )
    }
}

/// The production Calendar boundary behind the Link channel bridge. It is
/// instantiated only when the launch-frozen Calendar mode and the Apple grant
/// jointly allow Calendar Capabilities, and it deliberately contains no
/// permission-request API: reading through an unauthorized store never
/// prompts.
final class EventKitOmarchyLinkCalendarAdapter: OmarchyLinkCalendarProviding, OmarchyLinkCalendarCreating {
    private let eventStore: EKEventStore
    // Only identifiers from uncertain saves, never proposal/event content.
    private var uncertainEventIDs: [String: String] = [:]

    init(eventStore: EKEventStore) {
        self.eventStore = eventStore
    }

    func writableCalendars() throws -> [OmarchyLinkCalendar] {
        guard OmarchyLinkCalendarAccessPreflight.authorizationState() == .authorized else {
            throw OmarchyLinkProtocolError.invalidMessage
        }
        return eventStore.calendars(for: .event)
            .filter(\.allowsContentModifications)
            .map { OmarchyLinkCalendar(id: $0.calendarIdentifier, title: $0.title) }
    }

    func create(_ proposal: OmarchyLinkCalendarCreate) throws {
        guard OmarchyLinkCalendarAccessPreflight.authorizationState() == .authorized,
              let calendar = eventStore.calendar(withIdentifier: proposal.calendar.id),
              calendar.allowsContentModifications,
              calendar.title == proposal.calendar.title else {
            throw OmarchyLinkProtocolError.invalidMessage
        }
        let event = EKEvent(eventStore: eventStore)
        event.calendar = calendar
        event.title = proposal.title
        event.startDate = proposal.startDate
        event.endDate = proposal.endDate
        event.isAllDay = false
        do {
            try eventStore.save(event, span: .thisEvent, commit: true)
        } catch {
            if let identifier = event.eventIdentifier, !identifier.isEmpty,
               uncertainEventIDs.count < 1024 {
                uncertainEventIDs[proposal.id] = identifier
            }
            throw error
        }
    }

    func confirmsCreate(_ proposalID: String) -> Bool {
        guard OmarchyLinkCalendarAccessPreflight.authorizationState() == .authorized,
              let identifier = uncertainEventIDs[proposalID] else { return false }
        // A fresh store avoids treating the failed save's in-memory EKEvent as
        // persistence evidence. Never search by title/time or issue another save.
        guard EKEventStore().event(withIdentifier: identifier) != nil else { return false }
        uncertainEventIDs.removeValue(forKey: proposalID)
        return true
    }

    func calendars() -> [OmarchyLinkCalendar] {
        eventStore.calendars(for: .event)
            .map {
                OmarchyLinkCalendar(
                    id: $0.calendarIdentifier,
                    title: $0.title
                )
            }
            .sorted { ($0.title, $0.id) < ($1.title, $1.id) }
    }

    func events(matching query: OmarchyLinkCalendarQuery) -> [OmarchyLinkCalendarEvent] {
        let selectedCalendars: [EKCalendar]?
        if query.calendarIDs.isEmpty {
            selectedCalendars = nil
        } else {
            selectedCalendars = eventStore.calendars(for: .event).filter {
                query.calendarIDs.contains($0.calendarIdentifier)
            }
        }
        let predicate = eventStore.predicateForEvents(
            withStart: query.startDate,
            end: query.endDate,
            calendars: selectedCalendars
        )
        return eventStore.events(matching: predicate)
            .compactMap { event in
                guard let title = event.title, !title.isEmpty else { return nil }
                return OmarchyLinkCalendarEvent(
                    id: event.calendarItemIdentifier,
                    calendarID: event.calendar.calendarIdentifier,
                    title: title,
                    startDate: event.startDate,
                    endDate: event.endDate,
                    isAllDay: event.isAllDay
                )
            }
            .sorted { ($0.startDate, $0.id) < ($1.startDate, $1.id) }
    }
}
