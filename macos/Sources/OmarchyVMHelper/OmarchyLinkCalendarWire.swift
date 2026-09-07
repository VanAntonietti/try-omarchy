import Foundation

/// The bounded Calendar Query wire schema shared by every Link host endpoint.
/// Parsing rejects anything outside explicit, canonical bounds, and
/// serialization emits only the normalized event fields the surface needs.
enum OmarchyLinkCalendarWire {
    /// Queries never exceed the seven-day agenda window plus one day of
    /// time-zone slack, so no request can sweep an unbounded date range.
    static let maximumQueryInterval: TimeInterval = 8 * 24 * 60 * 60

    static func calendarQuery(_ parameters: [String: Any]) throws -> OmarchyLinkCalendarQuery {
        guard let startValue = parameters["start"] as? String,
              let endValue = parameters["end"] as? String,
              let calendarIDs = parameters["calendarIds"] as? [String],
              calendarIDs.count <= 128,
              Set(calendarIDs).count == calendarIDs.count,
              calendarIDs.allSatisfy({ (1...64).contains($0.utf8.count) }),
              let start = canonicalDate(startValue),
              let end = canonicalDate(endValue),
              start < end,
              end.timeIntervalSince(start) <= maximumQueryInterval else {
            throw OmarchyLinkProtocolError.invalidMessage
        }
        return OmarchyLinkCalendarQuery(
            startDate: start,
            endDate: end,
            calendarIDs: Set(calendarIDs)
        )
    }

    static func canonicalDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: value), formatter.string(from: date) == value else {
            return nil
        }
        return date
    }

    static func calendarObjects(
        from provider: any OmarchyLinkCalendarProviding
    ) throws -> [[String: Any]] {
        let calendars = try provider.calendars()
        guard calendars.count <= 128,
              calendars.allSatisfy({
                  (1...64).contains($0.id.utf8.count)
                      && (1...256).contains($0.title.utf8.count)
              }) else {
            throw OmarchyLinkProtocolError.invalidMessage
        }
        return calendars.map { ["id": $0.id, "title": $0.title] }
    }

    static func eventObjects(
        from provider: any OmarchyLinkCalendarProviding,
        matching query: OmarchyLinkCalendarQuery
    ) throws -> [[String: Any]] {
        let events = try provider.events(matching: query)
        guard events.count <= 512,
              events.allSatisfy({ event in
                  (1...128).contains(event.id.utf8.count)
                      && (1...64).contains(event.calendarID.utf8.count)
                      && (1...512).contains(event.title.utf8.count)
                      && event.startDate < event.endDate
                      && event.startDate < query.endDate
                      && event.endDate > query.startDate
                      && (query.calendarIDs.isEmpty
                          || query.calendarIDs.contains(event.calendarID))
              }) else {
            throw OmarchyLinkProtocolError.invalidMessage
        }
        let formatter = ISO8601DateFormatter()
        return events
            .sorted { ($0.startDate, $0.id) < ($1.startDate, $1.id) }
            .map { event in
                [
                    "id": event.id,
                    "calendarId": event.calendarID,
                    "title": event.title,
                    "startsAt": formatter.string(from: event.startDate),
                    "endsAt": formatter.string(from: event.endDate),
                    "allDay": event.isAllDay,
                ]
            }
    }
}
