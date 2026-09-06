import Foundation

enum OmarchyLinkProtocolError: LocalizedError, Equatable {
    case emptyFrame
    case frameTooLarge(Int)
    case invalidJSONObject
    case invalidMessage
    case resourceLimit
    case connectionClosed
    case truncatedFrame

    var errorDescription: String? {
        switch self {
        case .emptyFrame:
            "Omarchy Link frames cannot be empty"
        case .frameTooLarge(let size):
            "Omarchy Link frame is too large (\(size) bytes)"
        case .invalidJSONObject:
            "Omarchy Link payload must be one valid JSON object"
        case .invalidMessage:
            "Omarchy Link message does not match the protocol schema"
        case .resourceLimit:
            "Omarchy Link peer resource limit exceeded"
        case .connectionClosed:
            "Omarchy Link peer is closed"
        case .truncatedFrame:
            "Omarchy Link ended with an incomplete frame"
        }
    }
}

enum OmarchyLinkFrameCodec {
    static let headerByteCount = 4
    static let maximumPayloadBytes = 4 * 1024 * 1024

    static func encodeJSONObject(_ object: Any) throws -> Data {
        guard object is [String: Any], JSONSerialization.isValidJSONObject(object) else {
            throw OmarchyLinkProtocolError.invalidJSONObject
        }
        guard let payload = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        ) else {
            throw OmarchyLinkProtocolError.invalidJSONObject
        }
        return try encodePayload(payload)
    }

    static func decodeJSONObject(_ payload: Data) throws -> [String: Any] {
        try validatePayloadSize(payload.count)
        // JSONSerialization also auto-detects UTF-16/32. The wire requires
        // UTF-8; raw NUL is illegal JSON and excludes those encodings.
        guard !payload.contains(0), String(data: payload, encoding: .utf8) != nil,
              let object = try? JSONSerialization.jsonObject(with: payload),
              let dictionary = object as? [String: Any] else {
            throw OmarchyLinkProtocolError.invalidJSONObject
        }
        return dictionary
    }

    static func encodePayload(_ payload: Data) throws -> Data {
        try validatePayloadSize(payload.count)
        // Raw payload framing is intentionally internal to protocol tests and
        // the broker. Callers send objects through encodeJSONObject so an
        // invalid or scalar JSON root cannot enter the channel.
        _ = try decodeJSONObject(payload)

        var length = UInt32(payload.count).bigEndian
        var frame = Data(capacity: headerByteCount + payload.count)
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(payload)
        return frame
    }

    private static func validatePayloadSize(_ size: Int) throws {
        guard size > 0 else { throw OmarchyLinkProtocolError.emptyFrame }
        guard size <= maximumPayloadBytes else {
            throw OmarchyLinkProtocolError.frameTooLarge(size)
        }
    }
}

/// Incrementally extracts complete payloads so one read may contain a partial
/// frame or several frames. JSON is validated before a payload is returned.
struct OmarchyLinkFrameDecoder {
    private var buffer = Data()

    var bufferedByteCount: Int { buffer.count }

    mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        var payloads: [Data] = []

        while buffer.count >= OmarchyLinkFrameCodec.headerByteCount {
            let length = buffer.prefix(OmarchyLinkFrameCodec.headerByteCount).reduce(0) {
                ($0 << 8) | Int($1)
            }
            guard length > 0 else { throw OmarchyLinkProtocolError.emptyFrame }
            guard length <= OmarchyLinkFrameCodec.maximumPayloadBytes else {
                throw OmarchyLinkProtocolError.frameTooLarge(length)
            }

            let frameByteCount = OmarchyLinkFrameCodec.headerByteCount + length
            guard buffer.count >= frameByteCount else { break }
            let payload = buffer.subdata(
                in: OmarchyLinkFrameCodec.headerByteCount..<frameByteCount
            )
            _ = try OmarchyLinkFrameCodec.decodeJSONObject(payload)
            payloads.append(payload)
            buffer.removeSubrange(0..<frameByteCount)
        }

        return payloads
    }
}
