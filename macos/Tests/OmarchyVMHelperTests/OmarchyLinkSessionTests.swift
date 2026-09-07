import Foundation
import Testing
@testable import OmarchyVMHelper

@Suite("Omarchy Link session negotiation")
struct OmarchyLinkSessionTests {
    @Test("a Swift host completes the shared all-off handshake")
    func completesAllOffHandshake() throws {
        let fixture = try loadHandshakeFixture()
        #expect(fixture["schemaVersion"] as? Int == 1)
        let cases = try #require(fixture["compatibleCases"] as? [[String: Any]])
        let testCase = try #require(cases.first)
        let modes = try serviceModes(from: testCase)
        let hello = try #require(testCase["hello"] as? [String: Any])
        let expected = try #require(testCase["expectedResponse"] as? [String: Any])

        var host = OmarchyLinkHostSession(developmentServiceModes: modes)
        let reply = host.receive(try jsonData(hello))

        #expect(
            reply.status == .available(
                OmarchyLinkNegotiatedSession(
                    protocolVersion: OmarchyLinkProtocolVersion(major: 1, minor: 0),
                    capabilities: []
                )
            )
        )
        let actual = try jsonObject(try reply.encodedMessage())
        #expect(actual == NSDictionary(dictionary: expected))
    }

    @Test("Service Modes expose only their named Capabilities across compatible v1 handshakes")
    func filtersCapabilitiesAndAcceptsAdditiveMinorVersions() throws {
        let fixture = try loadHandshakeFixture()
        let cases = try #require(fixture["compatibleCases"] as? [[String: Any]])

        for testCase in cases.dropFirst() {
            let modes = try serviceModes(from: testCase)
            let hello = try #require(testCase["hello"] as? [String: Any])
            let expected = try #require(testCase["expectedResponse"] as? [String: Any])
            let result = try #require(expected["result"] as? [String: Any])
            let expectedCapabilityNames = try #require(result["capabilities"] as? [String])
            let expectedCapabilities = try expectedCapabilityNames.map {
                try #require(OmarchyLinkCapability(rawValue: $0))
            }

            var host = OmarchyLinkHostSession(developmentServiceModes: modes)
            let reply = host.receive(try jsonData(hello))

            #expect(
                reply.status == .available(
                    OmarchyLinkNegotiatedSession(
                        protocolVersion: OmarchyLinkProtocolVersion(major: 1, minor: 0),
                        capabilities: expectedCapabilities
                    )
                ),
                "case: \(testCase["name"] as? String ?? "unnamed")"
            )
            let actual = try jsonObject(try reply.encodedMessage())
            #expect(
                actual == NSDictionary(dictionary: expected),
                "case: \(testCase["name"] as? String ?? "unnamed")"
            )
        }
    }

    @Test("unsupported or malformed hello makes only Link unavailable")
    func isolatesUnavailableHandshakesFromVMStartup() throws {
        let fixture = try loadHandshakeFixture()
        let cases = try #require(fixture["unavailableCases"] as? [[String: Any]])

        for testCase in cases {
            let modes = try serviceModes(from: testCase)
            let hello = try #require(testCase["hello"] as? [String: Any])
            let expected = try #require(testCase["expectedResponse"] as? [String: Any])

            var host = OmarchyLinkHostSession(developmentServiceModes: modes)
            let reply = host.receive(try jsonData(hello))
            let linkIsUnavailable: Bool
            if case .unavailable = reply.status {
                linkIsUnavailable = true
            } else {
                linkIsUnavailable = false
            }

            #expect(
                linkIsUnavailable,
                "case: \(testCase["name"] as? String ?? "unnamed")"
            )
            let actual = try jsonObject(try reply.encodedMessage())
            #expect(
                actual == NSDictionary(dictionary: expected),
                "case: \(testCase["name"] as? String ?? "unnamed")"
            )
        }
    }

    @Test("a Link Session cannot renegotiate after becoming available or unavailable")
    func handshakeStateIsTerminal() throws {
        let fixture = try loadHandshakeFixture()
        let compatibleCases = try #require(fixture["compatibleCases"] as? [[String: Any]])
        let unavailableCases = try #require(fixture["unavailableCases"] as? [[String: Any]])
        let compatible = try #require(compatibleCases.first)
        let unsupported = try #require(unavailableCases.first)
        let modes = try serviceModes(from: compatible)
        let hello = try #require(compatible["hello"] as? [String: Any])
        let unsupportedHello = try #require(unsupported["hello"] as? [String: Any])

        var availableHost = OmarchyLinkHostSession(developmentServiceModes: modes)
        let availableStatus = availableHost.receive(try jsonData(hello)).status
        let statusAfterAnotherHello = availableHost.receive(try jsonData(unsupportedHello)).status
        #expect(statusAfterAnotherHello == availableStatus)

        var unavailableHost = OmarchyLinkHostSession(developmentServiceModes: modes)
        let unavailableStatus = unavailableHost.receive(try jsonData(unsupportedHello)).status
        let statusAfterCompatibleHello = unavailableHost.receive(try jsonData(hello)).status
        #expect(statusAfterCompatibleHello == unavailableStatus)
    }

    @Test("an application request before hello receives a typed non-terminal failure")
    func requiresHandshakeFirst() throws {
        let fixture = try loadHandshakeFixture()
        let testCase = try #require(fixture["requestBeforeHandshake"] as? [String: Any])
        let modes = try serviceModes(from: testCase)
        let request = try #require(testCase["request"] as? [String: Any])
        let expected = try #require(testCase["expectedResponse"] as? [String: Any])

        var host = OmarchyLinkHostSession(developmentServiceModes: modes)
        let reply = host.receive(try jsonData(request))

        #expect(reply.status == .awaitingHandshake)
        let actual = try jsonObject(try reply.encodedMessage())
        #expect(actual == NSDictionary(dictionary: expected))
    }

    @Test("a Workspace-bound handshake rejects a missing guest identity before advertising Capabilities")
    func requiresWorkspaceIdentity() throws {
        let identity = try #require(OmarchyLinkWorkspaceIdentity(
            rawValue: "b1376985-1629-475e-bae7-9f63b075ad2f"
        ))
        var host = OmarchyLinkHostSession(
            serviceModes: OmarchyLinkServiceModes(calendar: .readWrite, messages: .read, notes: .read),
            workspaceIdentity: identity,
            calendarAuthorization: .authorized
        )
        let reply = host.receive(try workspaceHello(identity: nil))
        let failure = OmarchyLinkSessionFailure(
            code: .invalidWorkspaceIdentity,
            message: "Omarchy Link Workspace identity is missing or invalid"
        )
        #expect(reply.status == .unavailable(failure))
        #expect(reply.message == .error(id: "workspace-hello", failure: failure))
        // A corrected request cannot revive a failed Link Session.
        #expect(host.receive(try workspaceHello(identity: identity.rawValue)).status == reply.status)
    }

    @Test("a matching Workspace identity permits only the launch-fixed Capabilities")
    func acceptsMatchingWorkspaceIdentity() throws {
        let identity = try #require(OmarchyLinkWorkspaceIdentity(
            rawValue: "b1376985-1629-475e-bae7-9f63b075ad2f"
        ))
        var host = OmarchyLinkHostSession(
            serviceModes: OmarchyLinkServiceModes(calendar: .read, messages: .off, notes: .off),
            workspaceIdentity: identity,
            calendarAuthorization: .authorized
        )
        let reply = host.receive(try workspaceHello(identity: identity.rawValue))
        #expect(reply.status == .available(OmarchyLinkNegotiatedSession(
            protocolVersion: .current,
            capabilities: [.calendarList, .calendarEventList]
        )))
    }

    @Test("malformed or substituted guest identities cannot use another Workspace's Service Modes")
    func rejectsInvalidGuestIdentities() throws {
        let identity = try #require(OmarchyLinkWorkspaceIdentity(
            rawValue: "b1376985-1629-475e-bae7-9f63b075ad2f"
        ))
        let invalid: [Any] = [
            "", "not-a-uuid", identity.rawValue.uppercased(), identity.rawValue + "\n",
            // A valid identity from before Factory Reset, or another Workspace.
            "08512118-e49d-43a1-85b0-fc53428b4762",
            42, NSNull(), ["workspaceIdentity": identity.rawValue],
        ]
        for presented in invalid {
            var host = OmarchyLinkHostSession(
                serviceModes: OmarchyLinkServiceModes(calendar: .readWrite, messages: .readWrite, notes: .readWrite),
                workspaceIdentity: identity,
                calendarAuthorization: .authorized
            )
            let reply = host.receive(try workspaceHello(identity: presented))
            expectInvalidWorkspaceIdentity(reply)
        }
    }

    @Test("unvalidated host identity never falls back to the development handshake")
    func rejectsInvalidHostIdentities() throws {
        let invalid: [String?] = [
            nil, "", "not-a-uuid", "b1376985-1629-175e-bae7-9f63b075ad2f",
            "b1376985-1629-475e-7ae7-9f63b075ad2f",
            "B1376985-1629-475E-BAE7-9F63B075AD2F",
            "b1376985-1629-475e-bae7-9f63b075ad2f\n",
        ]
        for rawIdentity in invalid {
            let identity = rawIdentity.flatMap(OmarchyLinkWorkspaceIdentity.init(rawValue:))
            #expect(identity == nil)
            var host = OmarchyLinkHostSession(
                serviceModes: OmarchyLinkServiceModes(calendar: .readWrite, messages: .off, notes: .off),
                workspaceIdentity: identity,
                calendarAuthorization: .authorized
            )
            let reply = host.receive(try workspaceHello(identity: rawIdentity))
            expectInvalidWorkspaceIdentity(reply)
        }
    }

    private func expectInvalidWorkspaceIdentity(_ reply: OmarchyLinkHostReply) {
        guard case .unavailable(let failure) = reply.status else {
            Issue.record("Invalid Workspace identity advertised Capabilities")
            return
        }
        #expect(failure.code == .invalidWorkspaceIdentity)
    }

    private func workspaceHello(identity: Any?) throws -> Data {
        var parameters: [String: Any] = [
            "client": ["name": "test-owner-broker", "version": "0.0.1"],
            "protocol": ["major": 1, "minor": 0],
        ]
        parameters["workspaceIdentity"] = identity
        return try jsonData([
            "type": "request", "id": "workspace-hello", "method": "session.hello",
            "params": parameters,
        ])
    }

    private func loadHandshakeFixture() throws -> [String: Any] {
        let testFile = URL(fileURLWithPath: #filePath)
        let repository = testFile
            .deletingLastPathComponent() // OmarchyVMHelperTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // macos
            .deletingLastPathComponent() // repository
        let data = try Data(
            contentsOf: repository.appendingPathComponent(
                "protocol/omarchy-link/v1/handshake-fixtures.json"
            )
        )
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func serviceModes(from testCase: [String: Any]) throws -> OmarchyLinkServiceModes {
        let modes = try #require(testCase["serviceModes"] as? [String: String])
        return OmarchyLinkServiceModes(
            calendar: try #require(OmarchyLinkServiceMode(rawValue: modes["calendar"] ?? "")),
            messages: try #require(OmarchyLinkServiceMode(rawValue: modes["messages"] ?? "")),
            notes: try #require(OmarchyLinkServiceMode(rawValue: modes["notes"] ?? ""))
        )
    }

    private func jsonData(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func jsonObject(_ data: Data) throws -> NSDictionary {
        try #require(JSONSerialization.jsonObject(with: data) as? NSDictionary)
    }
}
