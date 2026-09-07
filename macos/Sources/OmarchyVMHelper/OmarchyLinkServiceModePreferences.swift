import Foundation

extension OmarchyLinkServiceModes {
    /// A new Workspace exposes nothing until the host user chooses otherwise.
    static let allOff = OmarchyLinkServiceModes(calendar: .off, messages: .off, notes: .off)

    func mode(for service: OmarchyLinkMacService) -> OmarchyLinkServiceMode {
        switch service {
        case .calendar: calendar
        case .messages: messages
        case .notes: notes
        }
    }

    func updating(
        _ service: OmarchyLinkMacService,
        to mode: OmarchyLinkServiceMode
    ) -> OmarchyLinkServiceModes {
        OmarchyLinkServiceModes(
            calendar: service == .calendar ? mode : calendar,
            messages: service == .messages ? mode : messages,
            notes: service == .notes ? mode : notes
        )
    }
}

/// Per-Workspace Service Mode choices, keyed by the validated Link Workspace
/// identity. A Service Mode is the host user's Try Omarchy choice that limits
/// advertised Capabilities; it is not an Apple permission grant, so this store
/// never reads or writes macOS privacy state. Anything unrecognized loads as
/// Off rather than a broader mode.
struct OmarchyLinkServiceModePreferenceStore {
    static let key = "omarchyLinkServiceModes"
    static let schemaVersion = 1

    /// Factory Reset replaces a Workspace identity without notifying this
    /// store, so retain a bounded recent set instead of growing forever.
    static let maximumWorkspaceEntries = 32

    private let defaults: UserDefaults
    private let now: () -> Date

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.now = now
    }

    func load(for identity: OmarchyLinkWorkspaceIdentity) -> OmarchyLinkServiceModes {
        guard let entry = loadPayload()?.workspaces[identity.rawValue] else { return .allOff }
        return OmarchyLinkServiceModes(
            calendar: OmarchyLinkServiceMode(rawValue: entry.calendar) ?? .off,
            messages: OmarchyLinkServiceMode(rawValue: entry.messages) ?? .off,
            notes: OmarchyLinkServiceMode(rawValue: entry.notes) ?? .off
        )
    }

    func save(_ modes: OmarchyLinkServiceModes, for identity: OmarchyLinkWorkspaceIdentity) {
        var payload = loadPayload()
            ?? Payload(schemaVersion: Self.schemaVersion, workspaces: [:])
        payload.workspaces[identity.rawValue] = Entry(
            calendar: modes.calendar.rawValue,
            messages: modes.messages.rawValue,
            notes: modes.notes.rawValue,
            updatedAt: now()
        )
        if payload.workspaces.count > Self.maximumWorkspaceEntries {
            let retained = payload.workspaces
                .sorted { ($0.value.updatedAt, $0.key) > ($1.value.updatedAt, $1.key) }
                .prefix(Self.maximumWorkspaceEntries)
            payload.workspaces = Dictionary(
                uniqueKeysWithValues: retained.map { ($0.key, $0.value) }
            )
        }
        guard let data = try? JSONEncoder().encode(payload) else { return }
        defaults.set(data, forKey: Self.key)
    }

    private func loadPayload() -> Payload? {
        guard let data = defaults.data(forKey: Self.key),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.schemaVersion == Self.schemaVersion else {
            return nil
        }
        return payload
    }

    private struct Payload: Codable {
        let schemaVersion: Int
        var workspaces: [String: Entry]
    }

    private struct Entry: Codable {
        let calendar: String
        let messages: String
        let notes: String
        let updatedAt: Date
    }
}

/// How one launch obtains the Service Modes for its Link Session.
enum OmarchyLinkLaunchAccess: Equatable {
    /// A persistent Workspace whose Link identity validated on this host.
    case workspace(OmarchyLinkWorkspaceIdentity)

    /// An explicit one-run choice for an ephemeral launch. It never reads
    /// from or persists to stored preferences, so it cannot leak into a
    /// later launch.
    case ephemeral(OmarchyLinkServiceModes)

    /// Link is unavailable for this launch; nothing may be exposed.
    case unavailable
}

enum OmarchyLinkServiceModePolicy {
    /// The immutable Service Mode snapshot for one Link Session, captured
    /// once at launch. Callers hand this value to the session and never
    /// re-read the store while it runs, so a later preference change cannot
    /// expand a running session.
    static func sessionModes(
        access: OmarchyLinkLaunchAccess,
        store: OmarchyLinkServiceModePreferenceStore
    ) -> OmarchyLinkServiceModes {
        switch access {
        case .workspace(let identity):
            store.load(for: identity)
        case .ephemeral(let modes):
            modes
        case .unavailable:
            .allOff
        }
    }
}
