import Foundation

/// Canonical random UUID used as the Service Mode key, never a factory digest
/// or storage path. Syntax alone does not validate host state: the launcher
/// must first verify the Workspace's disk binding before supplying this value.
struct OmarchyLinkWorkspaceIdentity: RawRepresentable, Equatable, Hashable {
    let rawValue: String

    init?(rawValue: String) {
        guard rawValue.range(
            of: "\\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\\z",
            options: .regularExpression
        ) != nil else { return nil }
        self.rawValue = rawValue
    }
}

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
    case calendarEventCreatePerform = "calendar.events.create.perform"
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

enum OmarchyLinkCalendarMutationPolicy {
    case unavailable
    case proposalOnly
    case reviewedCreate

    var capabilities: [OmarchyLinkCapability] {
        switch self {
        case .unavailable: []
        case .proposalOnly: [.calendarEventCreateProposal]
        case .reviewedCreate: [.calendarEventCreateProposal, .calendarEventCreatePerform]
        }
    }
}

struct OmarchyLinkNegotiatedSession: Equatable {
    let protocolVersion: OmarchyLinkProtocolVersion
    let capabilities: [OmarchyLinkCapability]
}

enum OmarchyLinkSessionFailureCode: String, Equatable {
    case handshakeAlreadyComplete = "session.handshake_already_complete"
    case handshakeRequired = "session.handshake_required"
    case invalidHandshake = "session.invalid_handshake"
    case invalidWorkspaceIdentity = "session.invalid_workspace_identity"
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
    private enum IdentityPolicy {
        case developmentFixture
        case workspace(OmarchyLinkWorkspaceIdentity?)
    }

    private let serviceModes: OmarchyLinkServiceModes
    private let calendarAuthorization: OmarchyLinkCalendarAuthorizationState
    private let identityPolicy: IdentityPolicy
    private let calendarMutationPolicy: OmarchyLinkCalendarMutationPolicy
    private(set) var status = OmarchyLinkHostSessionStatus.awaitingHandshake

    /// nil means the host could not validate Workspace state, not an opt-out.
    /// The Apple Calendar grant is captured once at launch and can only narrow
    /// what the Calendar Service Mode advertises.
    init(
        serviceModes: OmarchyLinkServiceModes,
        workspaceIdentity: OmarchyLinkWorkspaceIdentity?,
        calendarAuthorization: OmarchyLinkCalendarAuthorizationState,
        calendarMutationPolicy: OmarchyLinkCalendarMutationPolicy = .proposalOnly
    ) {
        self.serviceModes = serviceModes
        self.calendarAuthorization = calendarAuthorization
        self.calendarMutationPolicy = calendarMutationPolicy
        identityPolicy = .workspace(workspaceIdentity)
    }

    /// Invented-data fixtures predate Workspace identity and have no VM access.
    /// They behave as if Apple granted access by default because nothing here
    /// touches real Calendar data.
    init(
        developmentServiceModes: OmarchyLinkServiceModes,
        calendarAuthorization: OmarchyLinkCalendarAuthorizationState = .authorized
    ) {
        serviceModes = developmentServiceModes
        self.calendarAuthorization = calendarAuthorization
        identityPolicy = .developmentFixture
        calendarMutationPolicy = .proposalOnly
    }

    mutating func receive(_ payload: Data) -> OmarchyLinkHostReply {
        if status != .awaitingHandshake {
            return terminalReply(for: payload)
        }

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
        if case .workspace(let expectedIdentity) = identityPolicy {
            guard let expectedIdentity,
                  let hello = try? JSONDecoder().decode(WorkspaceHelloRequest.self, from: payload),
                  hello.params.workspaceIdentity == expectedIdentity.rawValue else {
                return makeUnavailable(
                    id: envelope.id,
                    code: .invalidWorkspaceIdentity,
                    message: "Omarchy Link Workspace identity is missing or invalid"
                )
            }
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
            capabilities: Self.capabilities(
                allowedBy: serviceModes,
                calendarAuthorization: calendarAuthorization,
                calendarMutationPolicy: calendarMutationPolicy
            )
        )
        status = .available(negotiated)
        return OmarchyLinkHostReply(
            status: status,
            message: .response(id: envelope.id, session: negotiated)
        )
    }

    private func terminalReply(for payload: Data) -> OmarchyLinkHostReply {
        let id = (try? JSONDecoder().decode(RequestEnvelope.self, from: payload))?.id
        let failure: OmarchyLinkSessionFailure
        switch status {
        case .available:
            failure = OmarchyLinkSessionFailure(
                code: .handshakeAlreadyComplete,
                message: "The Omarchy Link session handshake is already complete"
            )
        case .unavailable(let unavailableFailure):
            failure = unavailableFailure
        case .awaitingHandshake:
            preconditionFailure("terminalReply requires a completed handshake")
        }
        return OmarchyLinkHostReply(
            status: status,
            message: .error(id: id, failure: failure)
        )
    }

    private static func capabilities(
        allowedBy modes: OmarchyLinkServiceModes,
        calendarAuthorization: OmarchyLinkCalendarAuthorizationState,
        calendarMutationPolicy: OmarchyLinkCalendarMutationPolicy
    ) -> [OmarchyLinkCapability] {
        var capabilities: [OmarchyLinkCapability] = []

        // Calendar Capabilities require both the host user's Service Mode and
        // the Apple grant. Off advertises nothing even with a grant, and a
        // grant never widens a mode. A blocked grant leaves the other Mac
        // Services and the VM untouched.
        let calendarAccessible =
            OmarchyLinkCalendarAccessPolicy.allowsCalendarCapabilities(calendarAuthorization)
        if modes.calendar != .off, calendarAccessible {
            capabilities += [.calendarList, .calendarEventList]
            if modes.calendar == .readWrite {
                capabilities += calendarMutationPolicy.capabilities
            }
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

private struct WorkspaceHelloRequest: Decodable {
    let params: Parameters

    struct Parameters: Decodable {
        let workspaceIdentity: String
    }
}

private struct HelloRequest: Decodable {
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
