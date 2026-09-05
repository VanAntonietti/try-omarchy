import Foundation
import Testing
@testable import OmarchyVMHelper

@Suite("Omarchy Link protocol")
struct OmarchyLinkProtocolTests {
    @Test("Swift framing matches the implementation-neutral v1 golden cases")
    func goldenFrames() throws {
        let fixture = try loadFixture()
        #expect(fixture["schemaVersion"] as? Int == 1)
        #expect(
            fixture["maximumFrameBytes"] as? Int
                == OmarchyLinkFrameCodec.maximumPayloadBytes
        )
        let cases = try #require(fixture["cases"] as? [[String: Any]])

        for testCase in cases {
            let payload = try #require(testCase["payload"] as? [String: Any])
            let expectedHex = try #require(testCase["frameHex"] as? String)
            let frame = try OmarchyLinkFrameCodec.encodeJSONObject(payload)
            #expect(hex(frame) == expectedHex)

            var decoder = OmarchyLinkFrameDecoder()
            #expect(try decoder.append(frame.prefix(3)).isEmpty)
            let decodedPayloads = try decoder.append(frame.dropFirst(3))
            let decodedPayload = try #require(decodedPayloads.first)
            #expect(decodedPayloads.count == 1)
            #expect(decoder.bufferedByteCount == 0)
            #expect(
                NSDictionary(dictionary: try OmarchyLinkFrameCodec.decodeJSONObject(decodedPayload))
                    == NSDictionary(dictionary: payload)
            )
        }
    }

    @Test("framing rejects empty, oversized, scalar, and malformed JSON payloads")
    func rejectsInvalidFrames() throws {
        #expect(throws: OmarchyLinkProtocolError.emptyFrame) {
            try OmarchyLinkFrameCodec.encodePayload(Data())
        }
        #expect(throws: OmarchyLinkProtocolError.frameTooLarge(
            OmarchyLinkFrameCodec.maximumPayloadBytes + 1
        )) {
            try OmarchyLinkFrameCodec.encodePayload(
                Data(repeating: 0, count: OmarchyLinkFrameCodec.maximumPayloadBytes + 1)
            )
        }
        for invalid in ["[]", "true", "not json"] {
            #expect(throws: OmarchyLinkProtocolError.invalidJSONObject) {
                try OmarchyLinkFrameCodec.encodePayload(Data(invalid.utf8))
            }
        }

        var emptyDecoder = OmarchyLinkFrameDecoder()
        #expect(throws: OmarchyLinkProtocolError.emptyFrame) {
            try emptyDecoder.append(Data(repeating: 0, count: 4))
        }

        let oversized = UInt32(OmarchyLinkFrameCodec.maximumPayloadBytes + 1).bigEndian
        var oversizedHeader = Data()
        withUnsafeBytes(of: oversized) { oversizedHeader.append(contentsOf: $0) }
        var oversizedDecoder = OmarchyLinkFrameDecoder()
        #expect(throws: OmarchyLinkProtocolError.frameTooLarge(
            OmarchyLinkFrameCodec.maximumPayloadBytes + 1
        )) {
            try oversizedDecoder.append(oversizedHeader)
        }
    }

    private func loadFixture() throws -> [String: Any] {
        let testFile = URL(fileURLWithPath: #filePath)
        let repository = testFile
            .deletingLastPathComponent() // OmarchyVMHelperTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // macos
            .deletingLastPathComponent() // repository
        let data = try Data(
            contentsOf: repository.appendingPathComponent(
                "protocol/omarchy-link/v1/golden-frames.json"
            )
        )
        return try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
