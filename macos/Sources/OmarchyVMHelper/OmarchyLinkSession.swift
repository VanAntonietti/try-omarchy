import Foundation

enum OmarchyLinkServiceMode: String, Equatable {
    case off
    case read
    case readWrite
}

struct OmarchyLinkServiceModes: Equatable {
    let calendar: OmarchyLinkServiceMode
    let messages: OmarchyLinkServiceMode
    let notes: OmarchyLinkServiceMode
}

struct OmarchyLinkProtocolVersion: Codable, Equatable {
    static let current = OmarchyLinkProtocolVersion(major: 1, minor: 0)

    let major: Int
    let minor: Int
}

enum OmarchyLinkCapability: String, CaseIterable, Equatable {
    case calendarList = "calendar.calendars.list"
    case calendarEventCreateProposal = "calendar.events.create.propose"
    case calendarEventList = "calendar.events.list"
    case messageConversationList = "messages.conversations.list"
    case messageSendProposal = "messages.send.propose"
    case messageThreadList = "messages.thread.list"
    case messageUnreadGet = "messages.unread.get"
    case noteAppendProposal = "notes.append.propose"
    case noteCreateProposal = "notes.create.propose"
    case noteFolderList = "notes.folders.list"
    case noteGet = "notes.get"
    case noteRecentList = "notes.recent.list"
    case noteSearch = "notes.search"
}

struct OmarchyLinkNegotiatedSession: Equatable {
    let protocolVersion: OmarchyLinkProtocolVersion
    let capabilities: [OmarchyLinkCapability]
}

enum OmarchyLinkSessionFailureCode: String, Equatable {
    case handshakeRequired = "session.handshake_required"
    case invalidHandshake = "session.invalid_handshake"
    case unsupportedProtocol = "session.unsupported_protocol"
}

struct OmarchyLinkSessionFailure: Equatable {
    let code: OmarchyLinkSessionFailureCode
    let message: String
}

enum OmarchyLinkHostSessionStatus: Equatable {
    case awaitingHandshake
    case available(OmarchyLinkNegotiatedSession)
    case unavailable(OmarchyLinkSessionFailure)
}

enum OmarchyLinkSessionMessage: Equatable {
    case response(id: String, session: OmarchyLinkNegotiatedSession)
    case error(id: String?, failure: OmarchyLinkSessionFailure)

    func encoded() throws -> Data {
        let object: [String: Any]
        switch self {
        case .response(let id, let session):
            object = [
                "type": "response",
                "id": id,
                "result": [
                    "protocol": [
                        "major": session.protocolVersion.major,
                        "minor": session.protocolVersion.minor,
                    ],
                    "server": [
                        "name": "try-omarchy-host",
                        "version": "0.0.1",
                    ],
                    "capabilities": session.capabilities.map(\.rawValue),
                ],
            ]
        case .error(let id, let failure):
            object = [
                "type": "error",
                "id": id ?? NSNull(),
                "error": [
                    "code": failure.code.rawValue,
                    "message": failure.message,
                ],
            ]
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}

struct OmarchyLinkHostReply: Equatable {
    let status: OmarchyLinkHostSessionStatus
    let message: OmarchyLinkSessionMessage

    func encodedMessage() throws -> Data {
        try message.encoded()
    }
}

struct OmarchyLinkHostSession {
    private let serviceModes: OmarchyLinkServiceModes
    private(set) var status = OmarchyLinkHostSessionStatus.awaitingHandshake

    init(serviceModes: OmarchyLinkServiceModes) {
        self.serviceModes = serviceModes
    }

    mutating func receive(_ payload: Data) -> OmarchyLinkHostReply {
        guard let envelope = try? JSONDecoder().decode(RequestEnvelope.self, from: payload),
              envelope.type == "request",
              !envelope.id.isEmpty,
              !envelope.method.isEmpty else {
            return makeUnavailable(
                id: nil,
                code: .invalidHandshake,
                message: "The Omarchy Link session handshake is malformed"
            )
        }
        guard envelope.method == "session.hello" else {
            let failure = OmarchyLinkSessionFailure(
                code: .handshakeRequired,
                message: "session.hello must be the first accepted request"
            )
            return OmarchyLinkHostReply(
                status: status,
                message: .error(id: envelope.id, failure: failure)
            )
        }
        guard let hello = try? JSONDecoder().decode(HelloRequest.self, from: payload),
              !hello.params.client.name.isEmpty,
              !hello.params.client.version.isEmpty,
              hello.params.protocolVersion.major >= 0,
              hello.params.protocolVersion.minor >= 0 else {
            return makeUnavailable(
                id: envelope.id,
                code: .invalidHandshake,
                message: "The Omarchy Link session handshake is malformed"
            )
        }
        guard hello.params.protocolVersion.major == OmarchyLinkProtocolVersion.current.major else {
            return makeUnavailable(
                id: envelope.id,
                code: .unsupportedProtocol,
                message: "Omarchy Link protocol major \(hello.params.protocolVersion.major) is unsupported"
            )
        }

        let negotiated = OmarchyLinkNegotiatedSession(
            protocolVersion: OmarchyLinkProtocolVersion(
                major: OmarchyLinkProtocolVersion.current.major,
                minor: min(
                    hello.params.protocolVersion.minor,
                    OmarchyLinkProtocolVersion.current.minor
                )
            ),
            capabilities: Self.capabilities(allowedBy: serviceModes)
        )
        status = .available(negotiated)
        return OmarchyLinkHostReply(
            status: status,
            message: .response(id: hello.id, session: negotiated)
        )
    }

    private static func capabilities(
        allowedBy modes: OmarchyLinkServiceModes
    ) -> [OmarchyLinkCapability] {
        var capabilities: [OmarchyLinkCapability] = []

        if modes.calendar != .off {
            capabilities += [.calendarList, .calendarEventList]
        }
        if modes.calendar == .readWrite {
            capabilities.append(.calendarEventCreateProposal)
        }
        if modes.messages != .off {
            capabilities += [.messageConversationList, .messageThreadList, .messageUnreadGet]
        }
        if modes.messages == .readWrite {
            capabilities.append(.messageSendProposal)
        }
        if modes.notes != .off {
            capabilities += [
                .noteFolderList,
                .noteGet,
                .noteRecentList,
                .noteSearch,
            ]
        }
        if modes.notes == .readWrite {
            capabilities += [.noteAppendProposal, .noteCreateProposal]
        }

        return capabilities.sorted { $0.rawValue < $1.rawValue }
    }

    private mutating func makeUnavailable(
        id: String?,
        code: OmarchyLinkSessionFailureCode,
        message: String
    ) -> OmarchyLinkHostReply {
        let failure = OmarchyLinkSessionFailure(code: code, message: message)
        status = .unavailable(failure)
        return OmarchyLinkHostReply(
            status: status,
            message: .error(id: id, failure: failure)
        )
    }
}

private struct RequestEnvelope: Decodable {
    let type: String
    let id: String
    let method: String
}

private struct HelloRequest: Decodable {
    let type: String
    let id: String
    let method: String
    let params: Parameters

    struct Parameters: Decodable {
        let client: Client
        let protocolVersion: OmarchyLinkProtocolVersion

        enum CodingKeys: String, CodingKey {
            case client
            case protocolVersion = "protocol"
        }
    }

    struct Client: Decodable {
        let name: String
        let version: String
    }
}
