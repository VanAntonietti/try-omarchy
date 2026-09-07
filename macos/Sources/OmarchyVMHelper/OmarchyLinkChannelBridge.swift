import Darwin
import Foundation

/// Production host endpoint for the private Omarchy Link virtio channel.
///
/// It negotiates exactly one Link Session bound to the launcher-validated
/// Workspace identity and the launch-frozen Service Modes, then answers every
/// operation with typed `request.method_unavailable`: no Mac Service adapter
/// is reachable through this channel yet, so no host data can cross it.
/// Framing, schema, and duplicate-identifier violations are terminal for the
/// channel and never represent a VM failure.
struct OmarchyLinkChannelHost {
    private var session: OmarchyLinkHostSession
    private var decoder = OmarchyLinkFrameDecoder()
    private var requestIDs = Set<String>()
    private var closed = false

    init(serviceModes: OmarchyLinkServiceModes, workspaceIdentity: OmarchyLinkWorkspaceIdentity) {
        session = OmarchyLinkHostSession(
            serviceModes: serviceModes,
            workspaceIdentity: workspaceIdentity
        )
    }

    var status: OmarchyLinkHostSessionStatus { session.status }

    mutating func receive(_ bytes: Data) throws -> Data {
        guard !closed else { throw OmarchyLinkProtocolError.connectionClosed }
        do {
            guard bytes.count <= 65536 else { throw OmarchyLinkProtocolError.resourceLimit }
            var replies = Data()
            for payload in try decoder.append(bytes) {
                replies.append(try receivePayload(payload))
            }
            return replies
        } catch {
            close()
            throw error
        }
    }

    private mutating func receivePayload(_ payload: Data) throws -> Data {
        let envelope = try OmarchyLinkFrameCodec.decodeJSONObject(payload)
        guard let id = envelope["id"] as? String, Self.validID(id),
              let type = envelope["type"] as? String, ["request", "cancel"].contains(type) else {
            throw OmarchyLinkProtocolError.invalidMessage
        }
        if type == "cancel" {
            // The closed cancellation schema cannot carry approval or content.
            guard Set(envelope.keys) == ["type", "id"] else {
                throw OmarchyLinkProtocolError.invalidMessage
            }
            // No work is ever pending on this channel, so cancellation of
            // unknown or completed work is the protocol's documented no-op.
            return Data()
        }
        guard !requestIDs.contains(id) else { throw OmarchyLinkProtocolError.invalidMessage }
        guard requestIDs.count < 1024 else { throw OmarchyLinkProtocolError.resourceLimit }
        requestIDs.insert(id)

        guard case .available = session.status else {
            return try OmarchyLinkFrameCodec.encodePayload(session.receive(payload).encodedMessage())
        }
        guard let method = envelope["method"] as? String, !method.isEmpty,
              envelope["params"] is [String: Any] else {
            throw OmarchyLinkProtocolError.invalidMessage
        }
        if method == "session.hello" {
            // One immutable Link Session per launch; renegotiation fails
            // without tearing the running session down.
            return try OmarchyLinkFrameCodec.encodePayload(session.receive(payload).encodedMessage())
        }
        return try OmarchyLinkFrameCodec.encodeJSONObject([
            "type": "error", "id": id,
            "error": [
                "code": "request.method_unavailable",
                "message": "The Capability is not available",
            ],
        ])
    }

    mutating func finish() throws {
        let incomplete = decoder.bufferedByteCount != 0
        close()
        if incomplete { throw OmarchyLinkProtocolError.truncatedFrame }
    }

    private mutating func close() {
        closed = true
        decoder = OmarchyLinkFrameDecoder()
        requestIDs.removeAll()
    }

    private static func validID(_ id: String) -> Bool {
        (1...64).contains(id.utf8.count) && id.utf8.allSatisfy { (0x21...0x7e).contains($0) }
    }
}

/// The launch-frozen Service Mode snapshot printed for the shell launcher.
/// The identity was already validated by the storage library under its
/// workspace lock; this only re-checks the canonical syntax and reads the
/// per-Workspace preference store exactly once.
enum OmarchyLinkSessionModeSnapshot {
    static func capture(
        identity rawIdentity: String,
        store: OmarchyLinkServiceModePreferenceStore = OmarchyLinkServiceModePreferenceStore()
    ) throws -> String {
        guard let identity = OmarchyLinkWorkspaceIdentity(rawValue: rawIdentity) else {
            throw HelperError.io("the Link Workspace identity is not a canonical UUID")
        }
        let modes = OmarchyLinkServiceModePolicy.sessionModes(
            access: .workspace(identity),
            store: store
        )
        return "calendar=\(modes.calendar.rawValue) messages=\(modes.messages.rawValue) notes=\(modes.notes.rawValue)"
    }

    static func parse(
        calendar: String,
        messages: String,
        notes: String
    ) -> OmarchyLinkServiceModes? {
        guard let calendar = OmarchyLinkServiceMode(rawValue: calendar),
              let messages = OmarchyLinkServiceMode(rawValue: messages),
              let notes = OmarchyLinkServiceMode(rawValue: notes) else {
            return nil
        }
        return OmarchyLinkServiceModes(calendar: calendar, messages: messages, notes: notes)
    }
}

/// Supervised sibling process that carries one Link Session over QEMU's
/// private virtio-serial chardev socket. Bridge failure is isolated from VM
/// availability: the launcher only ever restarts or disables this process.
final class OmarchyLinkChannelBridge {
    /// Exit status the launcher treats as "Link is disabled for the rest of
    /// this session"; any other failure may be restarted a bounded number of
    /// times.
    static let disabledExitStatus: Int32 = 2

    enum Outcome {
        /// The peer closed the channel without a protocol violation.
        case endOfStream
        /// Malformed traffic or an incompatible peer; do not restart.
        case linkDisabled
    }

    private let descriptor: Int32
    private var host: OmarchyLinkChannelHost
    private let stopLock = NSLock()
    private var stopped = false

    init(
        targetPID: pid_t,
        socketPath: String,
        serviceModes: OmarchyLinkServiceModes,
        workspaceIdentity: OmarchyLinkWorkspaceIdentity
    ) throws {
        guard let processIdentity = KernelProcessIdentity.capture(processIdentifier: targetPID),
              processIdentity.isQEMUSystemProcess else {
            throw HelperError.io("Omarchy Link bridge target is not a QEMU system process")
        }
        descriptor = try NativeBridgeSocket.connectSecure(
            path: socketPath,
            label: "Omarchy Link bridge"
        )
        host = OmarchyLinkChannelHost(
            serviceModes: serviceModes,
            workspaceIdentity: workspaceIdentity
        )
    }

    deinit {
        stop()
    }

    func run() throws -> Outcome {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = chunk.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            if count > 0 {
                let replies: Data
                do {
                    replies = try host.receive(Data(chunk[0..<count]))
                } catch {
                    // Content-free status only; the VM keeps running.
                    fputs("[omarchy-link] \(error.localizedDescription); Omarchy Link is disabled\n", stderr)
                    return .linkDisabled
                }
                if !replies.isEmpty {
                    try NativeBridgeSocket.writeAll(replies, to: descriptor, label: "Omarchy Link")
                }
                reportNegotiationOnce()
            } else if count == 0 {
                do {
                    try host.finish()
                } catch {
                    fputs("[omarchy-link] \(error.localizedDescription); Omarchy Link is disabled\n", stderr)
                    return .linkDisabled
                }
                return .endOfStream
            } else if errno != EINTR {
                if hasStopped() { return .endOfStream }
                throw HelperError.io("cannot read the guest Omarchy Link channel")
            }
        }
    }

    func stop() {
        stopLock.lock()
        guard !stopped else {
            stopLock.unlock()
            return
        }
        stopped = true
        stopLock.unlock()
        Darwin.shutdown(descriptor, SHUT_RDWR)
        Darwin.close(descriptor)
    }

    private func hasStopped() -> Bool {
        stopLock.lock()
        defer { stopLock.unlock() }
        return stopped
    }

    private var reportedStatus = false
    private func reportNegotiationOnce() {
        guard !reportedStatus else { return }
        switch host.status {
        case .awaitingHandshake:
            return
        case .available(let negotiated):
            reportedStatus = true
            fputs(
                "[omarchy-link] Link Session v\(negotiated.protocolVersion.major).\(negotiated.protocolVersion.minor) negotiated with \(negotiated.capabilities.count) Capabilities.\n",
                stderr
            )
        case .unavailable(let failure):
            reportedStatus = true
            fputs("[omarchy-link] Omarchy Link is unavailable: \(failure.code.rawValue)\n", stderr)
        }
    }
}
