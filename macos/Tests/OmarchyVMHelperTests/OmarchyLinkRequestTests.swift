import Foundation
import Testing
@testable import OmarchyVMHelper

@Suite("Omarchy Link fake request lifecycle")
struct OmarchyLinkRequestTests {
    @Test("concurrent Queries complete out of order with their own typed results or errors")
    func correlatesConcurrentRequests() throws {
        var host = try readyHost()
        #expect(try host.receive(request("first") + request("second")).isEmpty)

        let second = try messages(host.complete("second", outcome: .unavailable))
        #expect(second == [["type": "error", "id": "second", "error": [
            "code": "service.unavailable", "message": "The fake Calendar service is unavailable",
        ]]])
        let first = try messages(host.complete("first"))
        #expect(first == [["type": "response", "id": "first", "result": [
            "calendars": [
                ["id": "invented-focus", "title": "Invented Focus"],
                ["id": "invented-personal", "title": "Invented Personal"],
            ],
        ]]])
        #expect(try host.complete("first").isEmpty)
    }

    @Test("the fake host returns the exact canonical Calendar Mutation Proposal")
    func canonicalizesCalendarMutationProposal() throws {
        var host = try readyHost(calendar: .readWrite)
        let request = try frame([
            "type": "request",
            "id": "create",
            "method": "calendar.events.create.propose",
            "params": [
                "title": "  Invented planning session  ",
                "startsAt": "2026-09-18T14:00:00Z",
                "endsAt": "2026-09-18T15:00:00Z",
                "calendarId": "invented-focus",
            ],
        ])

        #expect(try host.receive(request).isEmpty)
        let reply = try #require(try messages(host.complete("create")).first)
        #expect(reply == [
            "type": "response",
            "id": "create",
            "result": [
                "proposal": [
                    "id": "calendar-proposal-create",
                    "service": "calendar",
                    "operation": "event.create",
                    "title": "Invented planning session",
                    "startsAt": "2026-09-18T14:00:00Z",
                    "endsAt": "2026-09-18T15:00:00Z",
                    "calendar": [
                        "id": "invented-focus",
                        "title": "Invented Focus",
                    ],
                ],
            ],
        ])
    }

    @Test("cancellation settles only pending work and cannot approve a Mutation Proposal")
    func cancelsPendingWork() throws {
        var host = try readyHost()
        _ = try host.receive(request("cancel-me") + request("finish-me"))
        let cancelled = try messages(host.receive(frame(["type": "cancel", "id": "cancel-me"])))
        #expect(cancelled == [["type": "error", "id": "cancel-me", "error": [
            "code": "request.cancelled", "message": "The request was cancelled",
        ]]])
        #expect(try host.complete("cancel-me").isEmpty)
        #expect(try messages(host.complete("finish-me")).count == 1)
        #expect(try host.receive(frame(["type": "cancel", "id": "finish-me"])).isEmpty)
        #expect(try host.receive(frame(["type": "cancel", "id": "unknown"])).isEmpty)
        #expect(throws: OmarchyLinkProtocolError.invalidMessage) {
            try host.receive(frame(["type": "cancel", "id": "proposal", "approved": true]))
        }
    }

    @Test("dispatch requires an enabled, implemented Capability and object parameters")
    func allowListsDispatch() throws {
        for mode in [OmarchyLinkServiceMode.off, .read, .readWrite] {
            var host = try readyHost(calendar: mode)
            for method in ["shell.exec", "sql.query", "calendar.events.create.perform", "proposal.approve"] {
                let reply = try messages(host.receive(frame([
                    "type": "request", "id": method, "method": method, "params": [:],
                ])))
                #expect(reply.first?["id"] as? String == method)
                #expect((reply.first?["error"] as? [String: String])?["code"] == "request.method_unavailable")
                #expect(try host.complete(method).isEmpty)
            }
            if mode == .off {
                let reply = try messages(host.receive(request("disabled")))
                #expect((reply.first?["error"] as? [String: String])?["code"] == "request.method_unavailable")
                #expect(try host.complete("disabled").isEmpty)
            }
        }
        var host = try readyHost()
        #expect(throws: OmarchyLinkProtocolError.invalidMessage) {
            try host.receive(frame(["type": "request", "id": "bad", "method": "calendar.calendars.list", "params": []]))
        }
    }

    @Test("invalid input closes only the Link peer and discards unfinished work within fixed bounds")
    func rejectsInvalidInput() throws {
        let malformed = Data([0, 0, 0, 1, 123])
        let oversized = Data([0, 64, 0, 1]) // 4 MiB + 1; no body needs to arrive
        let cases: [(Data, OmarchyLinkProtocolError)] = [
            (Data([0, 0, 0, 0]), .emptyFrame),
            (oversized, .frameTooLarge(4 * 1024 * 1024 + 1)),
            (malformed, .invalidJSONObject),
            (try frame([:]), .invalidMessage),
            (try frame(["type": "response", "id": "wrong-direction", "result": [:]]), .invalidMessage),
            (try request(""), .invalidMessage),
            (try request(String(repeating: "x", count: 65)), .invalidMessage),
            (try request("pending"), .invalidMessage), // duplicate request identifier
            (Data(repeating: 0, count: 65537), .resourceLimit),
        ]
        for (bytes, failure) in cases {
            var host = try readyHost()
            _ = try host.receive(request("pending"))
            #expect(throws: failure) { try host.receive(bytes) }
            #expect(try host.complete("pending").isEmpty)
            #expect(throws: OmarchyLinkProtocolError.connectionClosed) { try host.receive(request("later")) }
        }
        var host = try readyHost()
        _ = try host.receive(Data([0, 0, 0]))
        #expect(throws: OmarchyLinkProtocolError.truncatedFrame) { try host.finish() }
    }

    @Test("pending work and remembered request identifiers have finite budgets")
    func boundsRequestState() throws {
        var host = try readyHost()
        for id in 1...32 { #expect(try host.receive(request("q\(id)")).isEmpty) }
        let busy = try messages(host.receive(request("overflow")))
        #expect((busy.first?["error"] as? [String: String])?["code"] == "request.busy")
        #expect(try host.complete("overflow").isEmpty)
        _ = try host.complete("q1")
        #expect(try host.receive(request("next")).isEmpty)
        // The hello, 32 queued requests, overflow, and next consumed 35 IDs.
        for id in 36...1024 { _ = try host.receive(request("q\(id)")) }
        #expect(throws: OmarchyLinkProtocolError.resourceLimit) { try host.receive(request("too-many")) }
        #expect(try host.complete("next").isEmpty)
    }

    @Test("Invalidations carry only a Mac Service, not private content or request identifiers")
    func emitsContentFreeInvalidation() throws {
        var host = try readyHost()
        #expect(try messages(host.invalidate(.calendar)) == [[
            "type": "event", "event": "invalidation", "service": "calendar",
        ]])
        #expect(try host.invalidate(.messages).isEmpty)
        try host.finish()
        #expect(try host.invalidate(.calendar).isEmpty)
    }

    @Test("fragmented requests accept exactly 4 MiB of UTF-8 JSON and reject other encodings")
    func boundsFragmentedPayloads() throws {
        var host = try readyHost()
        let prefix = "{\"type\":\"request\",\"id\":\"large\",\"method\":\"calendar.calendars.list\",\"params\":{},\"future\":\""
        let suffix = "\"}"
        let padding = String(repeating: "x", count: 4 * 1024 * 1024 - prefix.utf8.count - suffix.utf8.count)
        let bytes = Data([0, 64, 0, 0]) + Data((prefix + padding + suffix).utf8)
        for offset in stride(from: 0, to: bytes.count, by: 65536) {
            #expect(try host.receive(bytes.subdata(in: offset..<min(offset + 65536, bytes.count))).isEmpty)
        }
        #expect(try messages(host.complete("large")).count == 1)
        let utf16 = try #require("{\"type\":\"cancel\",\"id\":\"none\"}".data(using: .utf16LittleEndian))
        var length = UInt32(utf16.count).bigEndian
        let header = withUnsafeBytes(of: &length) { Data($0) }
        #expect(throws: OmarchyLinkProtocolError.invalidJSONObject) { try host.receive(header + utf16) }
    }

    private func readyHost(calendar: OmarchyLinkServiceMode = .read) throws -> OmarchyLinkFakeHost {
        var host = OmarchyLinkFakeHost(serviceModes: .init(calendar: calendar, messages: .off, notes: .off))
        _ = try host.receive(frame([
            "type": "request", "id": "hello", "method": "session.hello",
            "params": ["client": ["name": "fake-guest", "version": "1"],
                       "protocol": ["major": 1, "minor": 0]],
        ]))
        return host
    }

    private func request(_ id: String) throws -> Data {
        try frame(["type": "request", "id": id, "method": "calendar.calendars.list", "params": [:]])
    }

    private func frame(_ object: [String: Any]) throws -> Data {
        try OmarchyLinkFrameCodec.encodeJSONObject(object)
    }

    private func messages(_ bytes: Data) throws -> [NSDictionary] {
        var decoder = OmarchyLinkFrameDecoder()
        return try decoder.append(bytes).map {
            NSDictionary(dictionary: try OmarchyLinkFrameCodec.decodeJSONObject($0))
        }
    }
}
