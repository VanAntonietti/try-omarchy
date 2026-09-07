import Foundation

enum OmarchyLinkMacService: String {
    case calendar
    case messages
    case notes
}

/// Invented data only. Work is queued until the harness explicitly completes it;
/// no VM transport or Mutation Proposal executor is connected.
struct OmarchyLinkFakeHost {
    enum Outcome: Equatable {
        case success
        case unavailable
    }

    private enum PendingWork {
        case calendars
        case events(OmarchyLinkCalendarQuery)
        case calendarCreateProposal(CalendarCreateRequest)
    }

    private struct CalendarCreateRequest {
        let title: String
        let startsAt: String
        let endsAt: String
        let calendarID: String
    }

    private var session: OmarchyLinkHostSession
    private let calendarProvider: any OmarchyLinkCalendarProviding
    private var decoder = OmarchyLinkFrameDecoder()
    private var pending: [String: PendingWork] = [:]
    private var requestIDs = Set<String>()
    private var closed = false

    init(
        serviceModes: OmarchyLinkServiceModes,
        calendarProvider: any OmarchyLinkCalendarProviding = InventedOmarchyLinkCalendarAdapter(),
        calendarAuthorization: OmarchyLinkCalendarAuthorizationState = .authorized
    ) {
        session = OmarchyLinkHostSession(
            developmentServiceModes: serviceModes,
            calendarAuthorization: calendarAuthorization
        )
        self.calendarProvider = calendarProvider
    }

    mutating func receive(_ bytes: Data) throws -> Data {
        guard !closed else { throw OmarchyLinkProtocolError.connectionClosed }
        do {
            guard bytes.count <= 65536 else { throw OmarchyLinkProtocolError.resourceLimit }
            return try receivePayloads(decoder.append(bytes))
        } catch {
            close()
            throw error
        }
    }

    private mutating func receivePayloads(_ payloads: [Data]) throws -> Data {
        var replies = Data()
        for payload in payloads { replies.append(try receivePayload(payload)) }
        return replies
    }

    private mutating func receivePayload(_ payload: Data) throws -> Data {
        let envelope = try OmarchyLinkFrameCodec.decodeJSONObject(payload)
        guard let id = envelope["id"] as? String, Self.validID(id),
              let type = envelope["type"] as? String, ["request", "cancel"].contains(type) else {
            throw OmarchyLinkProtocolError.invalidMessage
        }
        if type == "cancel" {
            guard Set(envelope.keys) == ["type", "id"] else {
                throw OmarchyLinkProtocolError.invalidMessage
            }
        } else {
            guard !requestIDs.contains(id) else { throw OmarchyLinkProtocolError.invalidMessage }
            guard requestIDs.count < 1024 else { throw OmarchyLinkProtocolError.resourceLimit }
            requestIDs.insert(id)
        }
        guard case .available(let negotiated) = session.status else {
            return try OmarchyLinkFrameCodec.encodePayload(session.receive(payload).encodedMessage())
        }
        if type == "cancel" {
            guard pending.removeValue(forKey: id) != nil else { return Data() }
            return try failure(id, code: "request.cancelled", message: "The request was cancelled")
        }
        guard let method = envelope["method"] as? String, !method.isEmpty,
              let parameters = envelope["params"] as? [String: Any] else {
            throw OmarchyLinkProtocolError.invalidMessage
        }
        if method == "session.hello" {
            return try OmarchyLinkFrameCodec.encodePayload(session.receive(payload).encodedMessage())
        }

        let work: PendingWork
        switch method {
        case OmarchyLinkCapability.calendarList.rawValue
            where negotiated.capabilities.contains(.calendarList):
            work = .calendars
        case OmarchyLinkCapability.calendarEventList.rawValue
            where negotiated.capabilities.contains(.calendarEventList):
            work = .events(try OmarchyLinkCalendarWire.calendarQuery(parameters))
        case OmarchyLinkCapability.calendarEventCreateProposal.rawValue
            where negotiated.capabilities.contains(.calendarEventCreateProposal):
            work = .calendarCreateProposal(try Self.calendarCreateRequest(parameters))
        default:
            return try failure(
                id,
                code: "request.method_unavailable",
                message: "The Capability is not available"
            )
        }
        guard pending.count < 32 else {
            return try failure(id, code: "request.busy", message: "Too many pending requests")
        }
        pending[id] = work
        return Data()
    }

    func invalidate(_ service: OmarchyLinkMacService) throws -> Data {
        guard !closed, case .available(let negotiated) = session.status,
              negotiated.capabilities.contains(where: { $0.rawValue.hasPrefix(service.rawValue + ".") }) else {
            return Data()
        }
        return try OmarchyLinkFrameCodec.encodeJSONObject([
            "type": "event", "event": "invalidation", "service": service.rawValue,
        ])
    }

    mutating func finish() throws {
        let incomplete = decoder.bufferedByteCount != 0
        close()
        if incomplete { throw OmarchyLinkProtocolError.truncatedFrame }
    }

    private mutating func close() {
        closed = true
        decoder = OmarchyLinkFrameDecoder()
        pending.removeAll()
        requestIDs.removeAll()
    }

    private static func validID(_ id: String) -> Bool {
        (1...64).contains(id.utf8.count) && id.utf8.allSatisfy { (0x21...0x7e).contains($0) }
    }

    mutating func complete(_ id: String, outcome: Outcome = .success) throws -> Data {
        guard let work = pending.removeValue(forKey: id) else { return Data() }
        guard outcome == .success else {
            return try failure(
                id,
                code: "service.unavailable",
                message: "The fake Calendar service is unavailable"
            )
        }
        do {
            let result: [String: Any]
            switch work {
            case .calendars:
                result = ["calendars": try calendarObjects()]
            case .events(let query):
                result = ["events": try eventObjects(matching: query)]
            case .calendarCreateProposal(let request):
                result = ["proposal": try calendarCreateProposal(request, requestID: id)]
            }
            return try OmarchyLinkFrameCodec.encodeJSONObject([
                "type": "response", "id": id, "result": result,
            ])
        } catch {
            return try failure(
                id,
                code: "service.unavailable",
                message: "The fake Calendar service is unavailable"
            )
        }
    }

    private func calendarObjects() throws -> [[String: Any]] {
        try OmarchyLinkCalendarWire.calendarObjects(from: calendarProvider)
    }

    private func eventObjects(matching query: OmarchyLinkCalendarQuery) throws -> [[String: Any]] {
        try OmarchyLinkCalendarWire.eventObjects(from: calendarProvider, matching: query)
    }

    private func calendarCreateProposal(
        _ request: CalendarCreateRequest,
        requestID: String
    ) throws -> [String: Any] {
        let calendars = try calendarProvider.calendars()
        guard let calendar = calendars.first(where: { $0.id == request.calendarID }),
              (1...256).contains(calendar.title.utf8.count) else {
            throw OmarchyLinkProtocolError.invalidMessage
        }
        return [
            "id": "calendar-proposal-\(requestID)",
            "service": "calendar",
            "operation": "event.create",
            "title": request.title,
            "startsAt": request.startsAt,
            "endsAt": request.endsAt,
            "calendar": ["id": calendar.id, "title": calendar.title],
        ]
    }

    private static func calendarCreateRequest(
        _ parameters: [String: Any]
    ) throws -> CalendarCreateRequest {
        guard let requestedTitle = parameters["title"] as? String,
              let startValue = parameters["startsAt"] as? String,
              let endValue = parameters["endsAt"] as? String,
              let calendarID = parameters["calendarId"] as? String else {
            throw OmarchyLinkProtocolError.invalidMessage
        }
        let title = requestedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...512).contains(title.utf8.count),
              (1...64).contains(calendarID.utf8.count),
              let start = OmarchyLinkCalendarWire.canonicalDate(startValue),
              let end = OmarchyLinkCalendarWire.canonicalDate(endValue),
              start < end else {
            throw OmarchyLinkProtocolError.invalidMessage
        }
        return CalendarCreateRequest(
            title: title,
            startsAt: startValue,
            endsAt: endValue,
            calendarID: calendarID
        )
    }

    private func failure(_ id: String, code: String, message: String) throws -> Data {
        try OmarchyLinkFrameCodec.encodeJSONObject([
            "type": "error", "id": id, "error": ["code": code, "message": message],
        ])
    }
}
