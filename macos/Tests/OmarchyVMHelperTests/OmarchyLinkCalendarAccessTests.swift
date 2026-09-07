import Foundation
import Testing
@testable import OmarchyVMHelper

/// Ticket coverage: the Calendar Service Mode and the injected Apple grant
/// jointly determine advertised Calendar Capabilities. No test here touches
/// EventKit or personal Calendar data.
@Suite("Omarchy Link Calendar access policy")
struct OmarchyLinkCalendarAccessTests {
    private static let identity = OmarchyLinkWorkspaceIdentity(
        rawValue: "b1376985-1629-475e-bae7-9f63b075ad2f"
    )!

    private static let grantStates: [OmarchyLinkCalendarAuthorizationState] = [
        .authorized, .denied, .restricted, .notDetermined,
    ]

    @Test("Off advertises no Calendar Capability even with a full Apple grant")
    func offAdvertisesNothingRegardlessOfGrant() throws {
        for authorization in Self.grantStates {
            let capabilities = try negotiatedCapabilities(
                modes: OmarchyLinkServiceModes(calendar: .off, messages: .off, notes: .off),
                calendarAuthorization: authorization
            )
            #expect(capabilities.isEmpty, "grant: \(authorization)")
        }
    }

    @Test("Read and Read & Write expose only their named Calendar Capabilities")
    func modesNeverWidenThroughTheGrant() throws {
        let readCapabilities = try negotiatedCapabilities(
            modes: OmarchyLinkServiceModes(calendar: .read, messages: .off, notes: .off),
            calendarAuthorization: .authorized
        )
        #expect(readCapabilities == [.calendarList, .calendarEventList])

        let readWriteCapabilities = try negotiatedCapabilities(
            modes: OmarchyLinkServiceModes(calendar: .readWrite, messages: .off, notes: .off),
            calendarAuthorization: .authorized
        )
        #expect(readWriteCapabilities == [
            .calendarList,
            .calendarEventCreateProposal,
            .calendarEventList,
        ])
    }

    @Test("an unavailable Apple grant advertises no Calendar Capability for any mode")
    func blockedGrantAdvertisesNoCalendarCapability() throws {
        for mode in [OmarchyLinkServiceMode.read, .readWrite] {
            for authorization in Self.grantStates where authorization != .authorized {
                let capabilities = try negotiatedCapabilities(
                    modes: OmarchyLinkServiceModes(calendar: mode, messages: .off, notes: .off),
                    calendarAuthorization: authorization
                )
                #expect(capabilities.isEmpty, "mode: \(mode), grant: \(authorization)")
            }
        }
    }

    @Test("a blocked Calendar grant leaves unrelated Mac Services and the session available")
    func blockedGrantIsolatesOnlyCalendar() throws {
        let capabilities = try negotiatedCapabilities(
            modes: OmarchyLinkServiceModes(calendar: .readWrite, messages: .read, notes: .readWrite),
            calendarAuthorization: .denied
        )
        #expect(!capabilities.contains { $0.rawValue.hasPrefix("calendar.") })
        #expect(capabilities.contains(.messageConversationList))
        #expect(capabilities.contains(.noteAppendProposal))
    }

    @Test("the development fixture behaves as granted without touching EventKit")
    func developmentFixtureDefaultsToGranted() throws {
        var host = OmarchyLinkHostSession(
            developmentServiceModes: OmarchyLinkServiceModes(
                calendar: .read, messages: .off, notes: .off
            )
        )
        let reply = host.receive(try hello(identity: nil))
        #expect(reply.status == .available(OmarchyLinkNegotiatedSession(
            protocolVersion: .current,
            capabilities: [.calendarList, .calendarEventList]
        )))
    }

    @Test("only a full-access grant supports Calendar Capabilities")
    func onlyFullAccessAllowsCapabilities() {
        #expect(OmarchyLinkCalendarAccessPolicy.allowsCalendarCapabilities(.authorized))
        for state in Self.grantStates where state != .authorized {
            #expect(!OmarchyLinkCalendarAccessPolicy.allowsCalendarCapabilities(state))
        }
    }

    @Test("the bridge warning names the blocked grant without failing anything")
    func launchWarningIsAccurateAndNonFatal() {
        // Off wants nothing, so nothing needs reporting even when denied.
        for state in Self.grantStates {
            #expect(OmarchyLinkCalendarAccessPolicy.launchWarning(
                mode: .off, authorization: state
            ) == nil)
        }
        for mode in [OmarchyLinkServiceMode.read, .readWrite] {
            #expect(OmarchyLinkCalendarAccessPolicy.launchWarning(
                mode: mode, authorization: .authorized
            ) == nil)
            for state in Self.grantStates where state != .authorized {
                let warning = OmarchyLinkCalendarAccessPolicy.launchWarning(
                    mode: mode, authorization: state
                )
                #expect(warning?.contains("no Calendar Capabilities are advertised") == true)
                #expect(warning?.contains("The VM and other Mac Services are unaffected") == true)
            }
        }
        // The three blocked grants read differently so remediation is precise.
        let warnings = [
            OmarchyLinkCalendarAuthorizationState.notDetermined, .denied, .restricted,
        ].compactMap {
            OmarchyLinkCalendarAccessPolicy.launchWarning(mode: .read, authorization: $0)
        }
        #expect(Set(warnings).count == 3)
    }

    private func negotiatedCapabilities(
        modes: OmarchyLinkServiceModes,
        calendarAuthorization: OmarchyLinkCalendarAuthorizationState
    ) throws -> [OmarchyLinkCapability] {
        var host = OmarchyLinkHostSession(
            serviceModes: modes,
            workspaceIdentity: Self.identity,
            calendarAuthorization: calendarAuthorization
        )
        let reply = host.receive(try hello(identity: Self.identity.rawValue))
        guard case .available(let negotiated) = reply.status else {
            Issue.record("the handshake must succeed; a blocked grant is not a session failure")
            return []
        }
        return negotiated.capabilities
    }

    private func hello(identity: String?) throws -> Data {
        var parameters: [String: Any] = [
            "client": ["name": "test-owner-broker", "version": "0.0.1"],
            "protocol": ["major": 1, "minor": 0],
        ]
        if let identity { parameters["workspaceIdentity"] = identity }
        return try JSONSerialization.data(
            withJSONObject: [
                "type": "request", "id": "hello-1", "method": "session.hello",
                "params": parameters,
            ],
            options: [.sortedKeys]
        )
    }
}
