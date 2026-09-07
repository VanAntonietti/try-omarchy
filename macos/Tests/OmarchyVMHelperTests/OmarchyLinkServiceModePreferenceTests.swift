import Darwin
import Foundation
import Testing
@testable import OmarchyVMHelper

@Suite("Omarchy Link Service Mode preferences")
struct OmarchyLinkServiceModePreferenceTests {
    @Test("every Mac Service defaults to Off for a new Workspace")
    func defaultsToOff() throws {
        let fixture = DefaultsFixture()
        #expect(fixture.store.load(for: try identity()) == .allOff)
    }

    @Test("saved Service Modes come back for the same Workspace identity")
    func roundTripsModes() throws {
        let fixture = DefaultsFixture()
        let workspace = try identity()
        let modes = OmarchyLinkServiceModes(calendar: .read, messages: .off, notes: .readWrite)

        fixture.store.save(modes, for: workspace)

        #expect(fixture.store.load(for: workspace) == modes)
    }

    @Test("a replaced Workspace identity never inherits the old choices")
    func isolatesIdentities() throws {
        let fixture = DefaultsFixture()
        let before = try identity("11111111-2222-4333-8444-555555555555")
        let after = try identity("aaaaaaaa-bbbb-4ccc-9ddd-eeeeeeeeeeee")
        fixture.store.save(
            OmarchyLinkServiceModes(calendar: .readWrite, messages: .readWrite, notes: .readWrite),
            for: before
        )

        #expect(fixture.store.load(for: after) == .allOff)
    }

    @Test("malformed or future-schema state fails closed to Off")
    func failsClosedOnUnrecognizedState() throws {
        let fixture = DefaultsFixture()
        let workspace = try identity()

        fixture.defaults.set(Data("not json".utf8), forKey: OmarchyLinkServiceModePreferenceStore.key)
        #expect(fixture.store.load(for: workspace) == .allOff)

        let future = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": OmarchyLinkServiceModePreferenceStore.schemaVersion + 1,
            "workspaces": [
                workspace.rawValue: [
                    "calendar": "readWrite", "messages": "readWrite", "notes": "readWrite",
                    "updatedAt": 0,
                ],
            ],
        ])
        fixture.defaults.set(future, forKey: OmarchyLinkServiceModePreferenceStore.key)
        #expect(fixture.store.load(for: workspace) == .allOff)
    }

    @Test("an unrecognized stored mode value becomes Off, not a broader mode")
    func failsClosedOnUnknownMode() throws {
        let fixture = DefaultsFixture()
        let workspace = try identity()
        fixture.store.save(
            OmarchyLinkServiceModes(calendar: .read, messages: .read, notes: .read),
            for: workspace
        )
        let data = try #require(
            fixture.defaults.data(forKey: OmarchyLinkServiceModePreferenceStore.key)
        )
        var object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        var workspaces = try #require(object["workspaces"] as? [String: [String: Any]])
        workspaces[workspace.rawValue]?["calendar"] = "everything"
        object["workspaces"] = workspaces
        fixture.defaults.set(
            try JSONSerialization.data(withJSONObject: object),
            forKey: OmarchyLinkServiceModePreferenceStore.key
        )

        let loaded = fixture.store.load(for: workspace)

        #expect(loaded.calendar == .off)
        #expect(loaded.messages == .read)
        #expect(loaded.notes == .read)
    }

    @Test("stored Workspace entries stay bounded, keeping the most recent")
    func prunesOldestEntries() throws {
        var tick = Date(timeIntervalSince1970: 0)
        let fixture = DefaultsFixture(now: {
            tick.addTimeInterval(1)
            return tick
        })
        let cap = OmarchyLinkServiceModePreferenceStore.maximumWorkspaceEntries
        let oldest = try identity("00000000-0000-4000-8000-000000000000")
        fixture.store.save(
            OmarchyLinkServiceModes(calendar: .read, messages: .off, notes: .off),
            for: oldest
        )
        for index in 0..<cap {
            let suffix = String(format: "%012d", index + 1)
            fixture.store.save(
                OmarchyLinkServiceModes(calendar: .off, messages: .read, notes: .off),
                for: try identity("00000000-0000-4000-8000-\(suffix)")
            )
        }

        #expect(fixture.store.load(for: oldest) == .allOff)
        let newest = try identity("00000000-0000-4000-8000-\(String(format: "%012d", cap))")
        #expect(fixture.store.load(for: newest).messages == .read)
    }

    private func identity(
        _ rawValue: String = "0f0e0d0c-0b0a-4988-8776-655443322110"
    ) throws -> OmarchyLinkWorkspaceIdentity {
        try #require(OmarchyLinkWorkspaceIdentity(rawValue: rawValue))
    }

    private final class DefaultsFixture {
        let suiteName = "OmarchyLinkServiceModePreferenceTests.\(UUID().uuidString)"
        let defaults: UserDefaults
        let store: OmarchyLinkServiceModePreferenceStore

        init(now: @escaping () -> Date = Date.init) {
            defaults = UserDefaults(suiteName: suiteName)!
            defaults.removePersistentDomain(forName: suiteName)
            store = OmarchyLinkServiceModePreferenceStore(defaults: defaults, now: now)
        }

        deinit {
            defaults.removePersistentDomain(forName: suiteName)
        }
    }
}

@Suite("Omarchy Link Session Mode snapshot")
struct OmarchyLinkSessionModeSnapshotTests {
    private let workspace = OmarchyLinkWorkspaceIdentity(
        rawValue: "0f0e0d0c-0b0a-4988-8776-655443322110"
    )!

    @Test("a Link Session keeps its snapshot when preferences expand afterwards")
    func laterPreferenceChangesCannotExpandARunningSession() throws {
        let fixture = DefaultsFixture()
        fixture.store.save(
            OmarchyLinkServiceModes(calendar: .read, messages: .off, notes: .off),
            for: workspace
        )
        let snapshot = OmarchyLinkServiceModePolicy.sessionModes(
            access: .workspace(workspace),
            store: fixture.store
        )
        var session = OmarchyLinkHostSession(
            serviceModes: snapshot,
            workspaceIdentity: workspace
        )

        fixture.store.save(
            OmarchyLinkServiceModes(calendar: .readWrite, messages: .readWrite, notes: .readWrite),
            for: workspace
        )
        let reply = session.receive(try hello())

        #expect(reply.status == .available(OmarchyLinkNegotiatedSession(
            protocolVersion: OmarchyLinkProtocolVersion(major: 1, minor: 0),
            capabilities: [.calendarList, .calendarEventList]
        )))
    }

    @Test("an ephemeral run uses its one-run choice without persisting it")
    func ephemeralChoicesAreOneRunOnly() {
        let fixture = DefaultsFixture()
        let oneRun = OmarchyLinkServiceModes(calendar: .off, messages: .read, notes: .off)

        let snapshot = OmarchyLinkServiceModePolicy.sessionModes(
            access: .ephemeral(oneRun),
            store: fixture.store
        )

        #expect(snapshot == oneRun)
        #expect(fixture.defaults.data(
            forKey: OmarchyLinkServiceModePreferenceStore.key
        ) == nil)
        #expect(fixture.store.load(for: workspace) == .allOff)
    }

    @Test("an unavailable Link exposes nothing")
    func unavailableExposesNothing() {
        let fixture = DefaultsFixture()
        fixture.store.save(
            OmarchyLinkServiceModes(calendar: .readWrite, messages: .readWrite, notes: .readWrite),
            for: workspace
        )

        let snapshot = OmarchyLinkServiceModePolicy.sessionModes(
            access: .unavailable,
            store: fixture.store
        )

        #expect(snapshot == .allOff)
    }

    private func hello() throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "type": "request",
            "id": "hello-1",
            "method": "session.hello",
            "params": [
                "client": ["name": "tests", "version": "1.0"],
                "protocol": ["major": 1, "minor": 0],
                "workspaceIdentity": workspace.rawValue,
            ],
        ])
    }

    private final class DefaultsFixture {
        let suiteName = "OmarchyLinkSessionModeSnapshotTests.\(UUID().uuidString)"
        let defaults: UserDefaults
        let store: OmarchyLinkServiceModePreferenceStore

        init() {
            defaults = UserDefaults(suiteName: suiteName)!
            defaults.removePersistentDomain(forName: suiteName)
            store = OmarchyLinkServiceModePreferenceStore(defaults: defaults)
        }

        deinit {
            defaults.removePersistentDomain(forName: suiteName)
        }
    }
}

@Suite("Omarchy Link Workspace identity preflight")
struct OmarchyLinkWorkspaceIdentityPreflightTests {
    @Test("a matching host-owned record yields the Workspace identity")
    func readsValidRecord() throws {
        let workspace = try WorkspaceFixture()
        let uuid = "0f0e0d0c-0b0a-4988-8776-655443322110"
        try workspace.writeIdentityRecord(uuid: uuid)

        let identity = WorkspaceStorage.linkWorkspaceIdentity(directory: workspace.path)

        #expect(identity?.rawValue == uuid)
    }

    @Test("a missing record disables Link rather than inventing one")
    func missingRecordYieldsNil() throws {
        let workspace = try WorkspaceFixture()
        #expect(WorkspaceStorage.linkWorkspaceIdentity(directory: workspace.path) == nil)
    }

    @Test("malformed or substituted records fail closed")
    func rejectsBadRecords() throws {
        let workspace = try WorkspaceFixture()
        let binding = try WorkspaceStorage.binding(directory: workspace.path)

        for record in [
            "",
            "v1",
            "v2:0f0e0d0c-0b0a-4988-8776-655443322110:\(binding)",
            "v1:not-a-uuid:\(binding)",
            "v1:0F0E0D0C-0B0A-4988-8776-655443322110:\(binding)",
            "v1:0f0e0d0c-0b0a-4988-8776-655443322110:other-binding",
            "v1:0f0e0d0c-0b0a-4988-8776-655443322110:\(binding):extra",
        ] {
            try workspace.writeRawRecord(record)
            #expect(
                WorkspaceStorage.linkWorkspaceIdentity(directory: workspace.path) == nil,
                "record: \(record)"
            )
        }
    }

    private struct WorkspaceFixture {
        let path: String

        init() throws {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("link-workspace-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let disk = directory.appendingPathComponent("rootfs.ext4", isDirectory: false)
            FileManager.default.createFile(
                atPath: disk.path,
                contents: Data("disk".utf8),
                attributes: [.posixPermissions: 0o600]
            )
            path = directory.path
        }

        func writeIdentityRecord(uuid: String) throws {
            let binding = try WorkspaceStorage.binding(directory: path)
            try writeRawRecord("v1:\(uuid):\(binding)")
        }

        func writeRawRecord(_ record: String) throws {
            let bytes = Array(record.utf8)
            guard setxattr(
                path,
                WorkspaceStorage.linkWorkspaceIdentityAttribute,
                bytes,
                bytes.count,
                0,
                XATTR_NOFOLLOW
            ) == 0 else {
                throw HelperError.io("cannot write test identity record")
            }
        }
    }
}
