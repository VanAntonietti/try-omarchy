import Foundation

enum OmarchyLinkMacService: String {
    case calendar
    case messages
    case notes
}

/// Invented data only. Work is queued until the harness explicitly completes it;
/// no Apple adapter, VM transport, or Mutation Proposal executor is connected.
struct OmarchyLinkFakeHost {
    enum Outcome {
        case success
        case unavailable
    }

    private var session: OmarchyLinkHostSession
    private var decoder = OmarchyLinkFrameDecoder()
    private var pending = Set<String>()
    private var requestIDs = Set<String>()
    private var closed = false

    init(serviceModes: OmarchyLinkServiceModes) {
        session = OmarchyLinkHostSession(serviceModes: serviceModes)
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
            guard pending.remove(id) != nil else { return Data() }
            return try failure(id, code: "request.cancelled", message: "The request was cancelled")
        }
        guard let method = envelope["method"] as? String, !method.isEmpty,
              envelope["params"] is [String: Any] else {
            throw OmarchyLinkProtocolError.invalidMessage
        }
        if method == "session.hello" {
            return try OmarchyLinkFrameCodec.encodePayload(session.receive(payload).encodedMessage())
        }
        guard method == OmarchyLinkCapability.calendarList.rawValue,
              negotiated.capabilities.contains(.calendarList) else {
            return try failure(id, code: "request.method_unavailable", message: "The Capability is not available")
        }
        guard pending.count < 32 else {
            return try failure(id, code: "request.busy", message: "Too many pending requests")
        }
        pending.insert(id)
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
        guard pending.remove(id) != nil else { return Data() }
        switch outcome {
        case .success:
            return try OmarchyLinkFrameCodec.encodeJSONObject([
                "type": "response", "id": id,
                "result": ["calendars": [["id": "invented-calendar", "title": "Invented Calendar"]]],
            ])
        case .unavailable:
            return try failure(id, code: "service.unavailable", message: "The fake Calendar service is unavailable")
        }
    }

    private func failure(_ id: String, code: String, message: String) throws -> Data {
        try OmarchyLinkFrameCodec.encodeJSONObject([
            "type": "error", "id": id, "error": ["code": code, "message": message],
        ])
    }
}
