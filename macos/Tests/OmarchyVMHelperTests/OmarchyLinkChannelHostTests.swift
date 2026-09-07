import Foundation
import Testing
@testable import OmarchyVMHelper

@Suite("Omarchy Link production channel host")
struct OmarchyLinkChannelHostTests {
    private static let identity = OmarchyLinkWorkspaceIdentity(
        rawValue: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
    )!
    private static let modes = OmarchyLinkServiceModes(
        calendar: .readWrite, messages: .read, notes: .off
    )

    private func makeHost(
        modes: OmarchyLinkServiceModes = OmarchyLinkChannelHostTests.modes
    ) -> OmarchyLinkChannelHost {
        OmarchyLinkChannelHost(
            serviceModes: modes,
            workspaceIdentity: Self.identity,
            calendarAuthorization: .authorized
        )
    }

    private func frame(_ object: [String: Any]) throws -> Data {
        try OmarchyLinkFrameCodec.encodeJSONObject(object)
    }

    private func hello(
        id: String = "hello-1",
        identity: String? = OmarchyLinkChannelHostTests.identity.rawValue,
        minor: Int = 0
    ) throws -> Data {
        var params: [String: Any] = [
            "client": ["name": "omarchy-link", "version": "0.0.1"],
            "protocol": ["major": 1, "minor": minor],
        ]
        if let identity { params["workspaceIdentity"] = identity }
        return try frame([
            "type": "request", "id": id, "method": "session.hello", "params": params,
        ])
    }

    private func decodeReplies(_ data: Data) throws -> [[String: Any]] {
        var decoder = OmarchyLinkFrameDecoder()
        return try decoder.append(data).map { try OmarchyLinkFrameCodec.decodeJSONObject($0) }
    }

    @Test("the handshake binds the validated Workspace identity and frozen Service Modes")
    func negotiatesBoundSession() throws {
        var host = makeHost()
        let replies = try decodeReplies(try host.receive(try hello()))
        #expect(replies.count == 1)
        let result = try #require(replies[0]["result"] as? [String: Any])
        #expect(replies[0]["type"] as? String == "response")
        #expect(replies[0]["id"] as? String == "hello-1")
        #expect(
            result["capabilities"] as? [String] == [
                "calendar.calendars.list",
                "calendar.events.create.propose",
                "calendar.events.list",
                "messages.conversations.list",
                "messages.thread.list",
                "messages.unread.get",
            ]
        )
        guard case .available(let negotiated) = host.status else {
            Issue.record("expected an available session")
            return
        }
        #expect(negotiated.protocolVersion == OmarchyLinkProtocolVersion(major: 1, minor: 0))
    }

    @Test("a newer compatible client negotiates down to the host minor version")
    func negotiatesLowerMinor() throws {
        var host = makeHost()
        let replies = try decodeReplies(try host.receive(try hello(minor: 9)))
        let result = try #require(replies[0]["result"] as? [String: Any])
        let version = try #require(result["protocol"] as? [String: Any])
        #expect(version["minor"] as? Int == 0)
    }

    @Test("a missing or foreign Workspace identity makes Link terminally unavailable")
    func rejectsWrongIdentity() throws {
        for wrong in [nil, "11111111-2222-4333-8444-555555555555"] {
            var host = makeHost()
            let replies = try decodeReplies(try host.receive(try hello(identity: wrong)))
            let error = try #require(replies[0]["error"] as? [String: Any])
            #expect(error["code"] as? String == "session.invalid_workspace_identity")
            guard case .unavailable = host.status else {
                Issue.record("expected a terminally unavailable session")
                return
            }
            // Later traffic keeps reporting the same terminal failure.
            let later = try decodeReplies(try host.receive(try hello(id: "hello-2")))
            let laterError = try #require(later[0]["error"] as? [String: Any])
            #expect(laterError["code"] as? String == "session.invalid_workspace_identity")
        }
    }

    @Test("another protocol major disables Link without failing the VM")
    func rejectsIncompatibleMajor() throws {
        var host = makeHost()
        let payload = try frame([
            "type": "request", "id": "hello-1", "method": "session.hello",
            "params": [
                "client": ["name": "omarchy-link", "version": "0.0.1"],
                "protocol": ["major": 2, "minor": 0],
                "workspaceIdentity": Self.identity.rawValue,
            ],
        ])
        let replies = try decodeReplies(try host.receive(payload))
        let error = try #require(replies[0]["error"] as? [String: Any])
        #expect(error["code"] as? String == "session.unsupported_protocol")
    }

    @Test("operations without a served adapter answer with typed unavailability, never host data")
    func unservedMethodsAreUnavailable() throws {
        var host = makeHost()
        _ = try host.receive(try hello())
        for method in ["calendar.events.create.propose", "host.shell"] {
            let request = try frame([
                "type": "request", "id": "r-\(method)", "method": method, "params": [:],
            ])
            let replies = try decodeReplies(try host.receive(request))
            let error = try #require(replies[0]["error"] as? [String: Any])
            #expect(replies[0]["id"] as? String == "r-\(method)")
            #expect(error["code"] as? String == "request.method_unavailable")
        }
        // Advertised Calendar Queries stay data-free when no adapter was
        // injected for this Link Session.
        let request = try frame([
            "type": "request", "id": "r-cal", "method": "calendar.calendars.list", "params": [:],
        ])
        let replies = try decodeReplies(try host.receive(request))
        let error = try #require(replies[0]["error"] as? [String: Any])
        #expect(error["code"] as? String == "service.unavailable")
    }

    @Test("a second handshake cannot renegotiate the running Link Session")
    func rejectsRenegotiation() throws {
        var host = makeHost()
        _ = try host.receive(try hello())
        let replies = try decodeReplies(try host.receive(try hello(id: "hello-2")))
        let error = try #require(replies[0]["error"] as? [String: Any])
        #expect(error["code"] as? String == "session.handshake_already_complete")
        guard case .available = host.status else {
            Issue.record("renegotiation must not tear down the session")
            return
        }
    }

    @Test("cancellation of unknown work is a safe no-op")
    func ignoresUnknownCancellation() throws {
        var host = makeHost()
        _ = try host.receive(try hello())
        let reply = try host.receive(try frame(["type": "cancel", "id": "missing"]))
        #expect(reply.isEmpty)
    }

    @Test("frames may be split and coalesced across channel reads")
    func handlesFragmentedFrames() throws {
        var host = makeHost()
        let helloFrame = try hello()
        #expect(try host.receive(helloFrame.prefix(3)).isEmpty)
        var data = try host.receive(helloFrame.dropFirst(3))
        let request = try frame([
            "type": "request", "id": "r1", "method": "notes.get", "params": [:],
        ])
        data.append(try host.receive(request))
        let replies = try decodeReplies(data)
        #expect(replies.count == 2)
        #expect(replies[0]["type"] as? String == "response")
        #expect(replies[1]["type"] as? String == "error")
    }

    @Test("malformed traffic closes the channel host terminally")
    func malformedTrafficIsTerminal() throws {
        var host = makeHost()
        _ = try host.receive(try hello())
        #expect(throws: OmarchyLinkProtocolError.self) {
            _ = try host.receive(Data([0, 0, 0, 0]))
        }
        #expect(throws: OmarchyLinkProtocolError.connectionClosed) {
            _ = try host.receive(try hello(id: "hello-3"))
        }
    }

    @Test("a duplicate request identifier is a terminal protocol violation")
    func duplicateIDIsTerminal() throws {
        var host = makeHost()
        _ = try host.receive(try hello())
        let request = try frame([
            "type": "request", "id": "r1", "method": "notes.get", "params": [:],
        ])
        _ = try host.receive(request)
        #expect(throws: OmarchyLinkProtocolError.invalidMessage) {
            _ = try host.receive(request)
        }
    }

    @Test("the launch snapshot round-trips through the shell as three fixed tokens")
    func modeSnapshotRoundTrips() throws {
        let defaults = try #require(UserDefaults(suiteName: "omarchy-link-channel-tests"))
        defaults.removePersistentDomain(forName: "omarchy-link-channel-tests")
        let store = OmarchyLinkServiceModePreferenceStore(defaults: defaults)
        store.save(Self.modes, for: Self.identity)

        let line = try OmarchyLinkSessionModeSnapshot.capture(
            identity: Self.identity.rawValue,
            store: store
        )
        #expect(line == "calendar=readWrite messages=read notes=off")
        #expect(
            OmarchyLinkSessionModeSnapshot.parse(
                calendar: "readWrite", messages: "read", notes: "off"
            ) == Self.modes
        )
        #expect(OmarchyLinkSessionModeSnapshot.parse(
            calendar: "everything", messages: "read", notes: "off"
        ) == nil)
        // An unknown Workspace exposes nothing.
        let unknown = try OmarchyLinkSessionModeSnapshot.capture(
            identity: "11111111-2222-4333-8444-555555555555",
            store: store
        )
        #expect(unknown == "calendar=off messages=off notes=off")
        #expect(throws: (any Error).self) {
            _ = try OmarchyLinkSessionModeSnapshot.capture(identity: "not-a-uuid", store: store)
        }
        defaults.removePersistentDomain(forName: "omarchy-link-channel-tests")
    }

    @Test("finish reports a truncated frame left on the wire")
    func finishReportsTruncation() throws {
        var host = makeHost()
        _ = try host.receive(try hello().prefix(5))
        #expect(throws: OmarchyLinkProtocolError.truncatedFrame) {
            try host.finish()
        }
    }
}
