import Foundation
import Testing
@testable import OmarchyVMHelper

@Suite("Calendar Mutation Proposals")
struct OmarchyLinkCalendarMutationTests {
    final class Store: OmarchyLinkCalendarCreating {
        var saved: [OmarchyLinkCalendarCreate] = []
        var writable = true
        var failAfterSave = false
        func writableCalendars() throws -> [OmarchyLinkCalendar] {
            writable ? [.init(id: "invented", title: "Invented Calendar")] : []
        }
        func create(_ event: OmarchyLinkCalendarCreate) throws {
            saved.append(event)
            if failAfterSave { throw OmarchyLinkProtocolError.invalidMessage }
        }
    }

    @Test("only a developer-gated Read & Write Link Session can propose and execute")
    func channelPolicy() throws {
        let configurations: [(Bool, OmarchyLinkCalendarAuthorizationState)] = [
            (false, .authorized), (true, .authorized), (true, .denied),
            (true, .notDetermined), (true, .restricted),
        ]
        for (enabled, authorization) in configurations {
            for mode in [OmarchyLinkServiceMode.off, .read, .readWrite] {
                let store = Store()
                let identity = OmarchyLinkWorkspaceIdentity(rawValue: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")!
                var host = OmarchyLinkChannelHost(
                    serviceModes: .init(calendar: mode, messages: .off, notes: .off),
                    workspaceIdentity: identity, calendarAuthorization: authorization,
                    calendarCreator: store, developmentCreates: enabled
                )
                func exchange(_ id: String, _ method: String, _ params: [String: Any]) throws -> [String: Any] {
                    var decoder = OmarchyLinkFrameDecoder()
                    let bytes = try host.receive(OmarchyLinkFrameCodec.encodeJSONObject([
                        "type": "request", "id": id, "method": method, "params": params,
                    ]))
                    return try OmarchyLinkFrameCodec.decodeJSONObject(decoder.append(bytes)[0])
                }
                let hello = try exchange("hello", "session.hello", [
                    "client": ["name": "test", "version": "1"],
                    "protocol": ["major": 1, "minor": 0], "workspaceIdentity": identity.rawValue,
                ])
                let capabilities = (hello["result"] as? [String: Any])?["capabilities"] as? [String] ?? []
                let canCreate = enabled && mode == .readWrite && authorization == .authorized
                #expect(capabilities.contains("calendar.events.create.perform") == canCreate)
                #expect(capabilities.contains("calendar.events.create.propose") == canCreate)
                let reply = try exchange("q1", "calendar.events.create.propose", [
                    "title": "Invented planning", "calendarId": "invented",
                    "startsAt": "2026-09-14T09:00:00Z", "endsAt": "2026-09-14T10:00:00Z",
                ])
                if canCreate {
                    let result = try #require(reply["result"] as? [String: Any])
                    let proposal = try #require(result["proposal"] as? [String: Any])
                    let id = try #require(proposal["id"] as? String)
                    let performed = try exchange("q2", "calendar.events.create.perform", ["proposalId": id])
                    #expect((performed["result"] as? [String: Any])?["outcome"] as? String == "succeeded")
                    #expect(store.saved.count == 1)
                } else {
                    #expect(reply["type"] as? String == "error")
                    #expect(store.saved.isEmpty)
                }
            }
        }
    }

    @Test("changed destinations fail before saving and uncertain saves are never replayed")
    func changedAndUncertain() throws {
        for uncertain in [false, true] {
            let store = Store()
            var mutations = OmarchyLinkCalendarMutations(provider: store)
            let proposal = try mutations.propose([
                "title": "Invented", "calendarId": "invented",
                "startsAt": "2026-09-14T09:00:00Z", "endsAt": "2026-09-14T10:00:00Z",
            ])
            store.writable = uncertain
            store.failAfterSave = uncertain
            #expect(mutations.perform(proposal.id) == (uncertain ? .uncertain : .failed))
            #expect(mutations.perform(proposal.id) == .failed)
            #expect(store.saved.count == (uncertain ? 1 : 0))
        }
    }

    @Test("unsupported fields and invalid bounds cannot become proposals")
    func invalidRequests() throws {
        let store = Store()
        var mutations = OmarchyLinkCalendarMutations(provider: store)
        let valid: [String: Any] = [
            "title": "Invented", "calendarId": "invented",
            "startsAt": "2026-09-14T09:00:00Z", "endsAt": "2026-09-14T10:00:00Z",
        ]
        for replacement: [String: Any] in [
            ["attendees": ["invented@example.invalid"]], ["recurrence": "daily"],
            ["title": "\u{001b}[31mhidden"], ["title": "  "], ["title": String(repeating: "a", count: 513)],
            ["endsAt": "2026-09-30T10:00:00Z"], ["endsAt": "2026-09-14T08:00:00Z"],
            ["calendarId": "missing"], ["startsAt": "2026-09-14T09:00:00+00:00"],
        ] {
            let request = valid.merging(replacement) { _, new in new }
            #expect(throws: OmarchyLinkProtocolError.invalidMessage) { _ = try mutations.propose(request) }
        }
        #expect(store.saved.isEmpty)
    }

    @Test("canonical proposal creates exactly the reviewed event once")
    func reviewedCreate() throws {
        let store = Store()
        var mutations = OmarchyLinkCalendarMutations(provider: store)
        let proposal = try mutations.propose([
            "title": "  Invented planning  ", "calendarId": "invented",
            "startsAt": "2026-09-14T09:00:00Z", "endsAt": "2026-09-14T10:00:00Z",
        ])
        #expect(proposal.title == "Invented planning")
        #expect(proposal.calendar.title == "Invented Calendar")
        #expect(store.saved.isEmpty)
        #expect(mutations.perform(proposal.id) == .succeeded)
        #expect(mutations.perform(proposal.id) == .failed)
        #expect(store.saved.count == 1)
        #expect(store.saved.first?.title == proposal.title)
    }
}
