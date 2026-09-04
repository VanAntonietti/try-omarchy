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

        var host = OmarchyLinkHostSession(serviceModes: modes)
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

            var host = OmarchyLinkHostSession(serviceModes: modes)
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

            var host = OmarchyLinkHostSession(serviceModes: modes)
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

    @Test("an application request before hello receives a typed non-terminal failure")
    func requiresHandshakeFirst() throws {
        let fixture = try loadHandshakeFixture()
        let testCase = try #require(fixture["requestBeforeHandshake"] as? [String: Any])
        let modes = try serviceModes(from: testCase)
        let request = try #require(testCase["request"] as? [String: Any])
        let expected = try #require(testCase["expectedResponse"] as? [String: Any])

        var host = OmarchyLinkHostSession(serviceModes: modes)
        let reply = host.receive(try jsonData(request))

        #expect(reply.status == .awaitingHandshake)
        let actual = try jsonObject(try reply.encodedMessage())
        #expect(actual == NSDictionary(dictionary: expected))
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
