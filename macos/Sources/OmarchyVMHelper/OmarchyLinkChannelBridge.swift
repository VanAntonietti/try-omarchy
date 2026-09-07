import Darwin
import EventKit
import Foundation

/// Production host endpoint for the private Omarchy Link virtio channel.
///
/// It negotiates exactly one Link Session bound to the launcher-validated
/// Workspace identity and the launch-frozen Service Modes. Advertised
/// Calendar Queries are served through the injected bounded adapter; every
/// other operation answers with typed `request.method_unavailable`, so no
/// host data outside the advertised Capabilities can cross this channel.
/// Framing, schema, and duplicate-identifier violations are terminal for the
/// channel and never represent a VM failure.
struct OmarchyLinkChannelHost {
    private var session: OmarchyLinkHostSession
    private let calendarProvider: (any OmarchyLinkCalendarProviding)?
    private var decoder = OmarchyLinkFrameDecoder()
    private var requestIDs = Set<String>()
    private var closed = false

    /// nil means no Calendar adapter is reachable for this Link Session; any
    /// advertised Calendar Query then answers with typed unavailability.
    init(
        serviceModes: OmarchyLinkServiceModes,
        workspaceIdentity: OmarchyLinkWorkspaceIdentity,
        calendarAuthorization: OmarchyLinkCalendarAuthorizationState,
        calendarProvider: (any OmarchyLinkCalendarProviding)? = nil
    ) {
        session = OmarchyLinkHostSession(
            serviceModes: serviceModes,
            workspaceIdentity: workspaceIdentity,
            calendarAuthorization: calendarAuthorization
        )
        self.calendarProvider = calendarProvider
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
        guard case .available(let negotiated) = session.status else {
            preconditionFailure("a negotiated session was checked above")
        }
        if method == OmarchyLinkCapability.calendarList.rawValue,
           negotiated.capabilities.contains(.calendarList) {
            guard let calendarProvider,
                  let calendars = try? OmarchyLinkCalendarWire.calendarObjects(
                      from: calendarProvider
                  ) else {
                return try serviceUnavailable(id)
            }
            return try OmarchyLinkFrameCodec.encodeJSONObject([
                "type": "response", "id": id, "result": ["calendars": calendars],
            ])
        }
        if method == OmarchyLinkCapability.calendarEventList.rawValue,
           negotiated.capabilities.contains(.calendarEventList) {
            // A malformed or unbounded Query is a protocol violation and
            // terminal for the channel; only adapter failure is a typed,
            // recoverable unavailability.
            let query = try OmarchyLinkCalendarWire.calendarQuery(
                envelope["params"] as? [String: Any] ?? [:]
            )
            guard let calendarProvider,
                  let events = try? OmarchyLinkCalendarWire.eventObjects(
                      from: calendarProvider,
                      matching: query
                  ) else {
                return try serviceUnavailable(id)
            }
            return try OmarchyLinkFrameCodec.encodeJSONObject([
                "type": "response", "id": id, "result": ["events": events],
            ])
        }
        return try OmarchyLinkFrameCodec.encodeJSONObject([
            "type": "error", "id": id,
            "error": [
                "code": "request.method_unavailable",
                "message": "The Capability is not available",
            ],
        ])
    }

    private func serviceUnavailable(_ id: String) throws -> Data {
        try OmarchyLinkFrameCodec.encodeJSONObject([
            "type": "error", "id": id,
            "error": [
                "code": "service.unavailable",
                "message": "The Calendar service is unavailable",
            ],
        ])
    }

    /// A content-free Invalidation for one Mac Service. Nothing is emitted
    /// before the handshake, after a terminal failure, or when the Link
    /// Session advertises no Capability for that service.
    func invalidate(_ service: OmarchyLinkMacService) throws -> Data {
        guard !closed, case .available(let negotiated) = session.status,
              negotiated.capabilities.contains(where: {
                  $0.rawValue.hasPrefix(service.rawValue + ".")
              }) else {
            return Data()
        }
        return try OmarchyLinkFrameCodec.encodeJSONObject([
            "type": "event", "event": "invalidation", "service": service.rawValue,
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
    private let hostLock = NSLock()
    private let stopLock = NSLock()
    private var stopped = false

    /// Serializes Invalidation bookkeeping; the emitted frames themselves go
    /// out under `hostLock` like every other channel write.
    private let invalidationQueue = DispatchQueue(label: "dev.tryomarchy.link.invalidation")
    private var invalidationThrottle = OmarchyLinkInvalidationThrottle(minimumInterval: 2)
    private var calendarChangeObserver: (any NSObjectProtocol)?

    init(
        targetPID: pid_t,
        socketPath: String,
        serviceModes: OmarchyLinkServiceModes,
        workspaceIdentity: OmarchyLinkWorkspaceIdentity,
        calendarAuthorization: OmarchyLinkCalendarAuthorizationState,
        calendarProvider: (any OmarchyLinkCalendarProviding)? = nil
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
            workspaceIdentity: workspaceIdentity,
            calendarAuthorization: calendarAuthorization,
            calendarProvider: calendarProvider
        )
        if calendarProvider != nil {
            observeCalendarChanges()
        }
    }

    deinit {
        if let calendarChangeObserver {
            NotificationCenter.default.removeObserver(calendarChangeObserver)
        }
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
                    hostLock.lock()
                    defer { hostLock.unlock() }
                    replies = try host.receive(Data(chunk[0..<count]))
                    if !replies.isEmpty {
                        try NativeBridgeSocket.writeAll(replies, to: descriptor, label: "Omarchy Link")
                    }
                } catch {
                    // Content-free status only; the VM keeps running.
                    fputs("[omarchy-link] \(error.localizedDescription); Omarchy Link is disabled\n", stderr)
                    return .linkDisabled
                }
                reportNegotiationOnce()
            } else if count == 0 {
                do {
                    hostLock.lock()
                    defer { hostLock.unlock() }
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

    /// Turns EventKit's content-free change notice into a bounded Calendar
    /// Invalidation on the channel. Bursts coalesce into one trailing frame;
    /// nothing is emitted before the handshake or when Calendar is off.
    private func observeCalendarChanges() {
        calendarChangeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.invalidationQueue.async { self.calendarDidChange() }
        }
    }

    private func calendarDidChange() {
        if invalidationThrottle.noteChange(at: Date()) {
            emitCalendarInvalidation()
        } else if let deadline = invalidationThrottle.flushDeadline {
            invalidationQueue.asyncAfter(
                deadline: .now() + max(0, deadline.timeIntervalSinceNow)
            ) { [weak self] in
                guard let self else { return }
                if self.invalidationThrottle.flush(at: Date()) {
                    self.emitCalendarInvalidation()
                }
            }
        }
    }

    private func emitCalendarInvalidation() {
        guard !hasStopped() else { return }
        hostLock.lock()
        defer { hostLock.unlock() }
        guard let frame = try? host.invalidate(.calendar), !frame.isEmpty else { return }
        try? NativeBridgeSocket.writeAll(frame, to: descriptor, label: "Omarchy Link")
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
