import Foundation

struct OmarchyLinkCalendarCreate {
    let id: String
    let title: String
    let startDate: Date
    let endDate: Date
    let calendar: OmarchyLinkCalendar

    var object: [String: Any] {
        let formatter = ISO8601DateFormatter()
        return [
            "id": id, "service": "calendar", "operation": "event.create",
            "title": title, "startsAt": formatter.string(from: startDate),
            "endsAt": formatter.string(from: endDate),
            "calendar": ["id": calendar.id, "title": calendar.title],
        ]
    }
}

protocol OmarchyLinkCalendarCreating {
    func writableCalendars() throws -> [OmarchyLinkCalendar]
    func create(_ event: OmarchyLinkCalendarCreate) throws
    /// Positive evidence for this exact save only; absence is not proof of failure.
    func confirmsCreate(_ proposalID: String) -> Bool
}

enum OmarchyLinkCalendarCreateOutcome: String {
    case succeeded, failed, uncertain
}

/// Session-local, expiring proposals. The proposal ID is the idempotency key.
/// Consume before touching EventKit; neither errors nor lost responses authorize
/// a second save. Completed entries contain only bounded Sync Metadata.
struct OmarchyLinkCalendarMutations {
    let provider: any OmarchyLinkCalendarCreating
    private var pending: [String: (OmarchyLinkCalendarCreate, Date)] = [:]
    private var completed: [String: OmarchyLinkCalendarCreateOutcome] = [:]

    init(provider: any OmarchyLinkCalendarCreating) { self.provider = provider }

    mutating func propose(_ parameters: [String: Any]) throws -> OmarchyLinkCalendarCreate {
        pending = pending.filter { $0.value.1 > Date() }
        // Reserve an outcome slot for every proposal. Never evict an accepted
        // key during the session: budget exhaustion disables new writes only.
        guard completed.count + pending.count < 1024 else {
            throw OmarchyLinkProtocolError.resourceLimit
        }
        guard pending.count < 32,
              Set(parameters.keys) == ["title", "startsAt", "endsAt", "calendarId"],
              let rawTitle = parameters["title"] as? String,
              rawTitle.utf8.count <= 512,
              let calendarID = parameters["calendarId"] as? String,
              (1...64).contains(calendarID.utf8.count),
              let start = parameters["startsAt"] as? String,
              let end = parameters["endsAt"] as? String,
              let startDate = OmarchyLinkCalendarWire.canonicalDate(start),
              let endDate = OmarchyLinkCalendarWire.canonicalDate(end),
              startDate < endDate,
              endDate.timeIntervalSince(startDate) <= 8 * 24 * 60 * 60 else {
            throw OmarchyLinkProtocolError.invalidMessage
        }
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !title.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0)
        }) else { throw OmarchyLinkProtocolError.invalidMessage }
        let calendars = try provider.writableCalendars()
        guard calendars.count <= 128,
              let calendar = calendars.first(where: { $0.id == calendarID }),
              (1...256).contains(calendar.title.utf8.count) else {
            throw OmarchyLinkProtocolError.invalidMessage
        }
        let proposal = OmarchyLinkCalendarCreate(
            id: UUID().uuidString.lowercased(), title: title,
            startDate: startDate, endDate: endDate, calendar: calendar
        )
        pending[proposal.id] = (proposal, Date().addingTimeInterval(120))
        return proposal
    }

    mutating func perform(_ id: String) -> OmarchyLinkCalendarCreateOutcome {
        let outcome: OmarchyLinkCalendarCreateOutcome
        if let recorded = completed[id] {
            outcome = recorded
        } else {
            guard pending[id] != nil else { return .failed }
            outcome = consume(id)
        }
        let reconciled = outcome == .uncertain && provider.confirmsCreate(id) ? .succeeded : outcome
        completed[id] = reconciled
        return reconciled
    }

    private mutating func consume(_ id: String) -> OmarchyLinkCalendarCreateOutcome {
        guard let (proposal, expiry) = pending.removeValue(forKey: id), expiry > Date() else {
            return .failed
        }
        do {
            guard try provider.writableCalendars().contains(proposal.calendar) else {
                return .failed
            }
        } catch { return .failed }
        do {
            try provider.create(proposal)
            return .succeeded
        } catch {
            // A save error need not prove that the store was untouched.
            return .uncertain
        }
    }
}
