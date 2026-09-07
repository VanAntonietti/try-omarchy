import EventKit
import Foundation

/// The Apple EventKit grant observed for this app, captured once per Link
/// Session. It can only narrow what a Calendar Service Mode advertises; the
/// grant never widens a mode and a mode is never inferred from the grant.
enum OmarchyLinkCalendarAuthorizationState: Equatable {
    case authorized
    case denied
    case restricted
    case notDetermined
}

/// Reads and requests the macOS Calendar grant. Reading the status never
/// prompts; the request path is reachable only from the visible start-menu
/// action.
enum OmarchyLinkCalendarAccessPreflight {
    static func authorizationState() -> OmarchyLinkCalendarAuthorizationState {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            return .authorized
        case .writeOnly:
            // Link's Calendar Queries read events, so write-only access cannot
            // support any advertised Calendar Capability. Remediation matches
            // denied: the user upgrades the grant in System Settings.
            return .denied
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .restricted
        }
    }

    static func requestFullAccess(completion: @escaping (Bool) -> Void) {
        let store = EKEventStore()
        store.requestFullAccessToEvents { granted, _ in
            // Keep the store alive until the request resolves.
            _ = store
            completion(granted)
        }
    }
}

/// Pure policy for the joint (Service Mode × Apple grant) Calendar decision.
enum OmarchyLinkCalendarAccessPolicy {
    /// Whether the current grant can support any Calendar Capability at all.
    static func allowsCalendarCapabilities(
        _ authorization: OmarchyLinkCalendarAuthorizationState
    ) -> Bool {
        authorization == .authorized
    }

    /// Content-free bridge status when the launch-fixed Calendar mode wants
    /// access the Apple grant does not provide. nil means nothing to report.
    /// The condition is never fatal: the VM and other Mac Services continue.
    static func launchWarning(
        mode: OmarchyLinkServiceMode,
        authorization: OmarchyLinkCalendarAuthorizationState
    ) -> String? {
        guard mode != .off else { return nil }
        switch authorization {
        case .authorized:
            return nil
        case .notDetermined:
            return "Calendar is on for this Link Session, but macOS Calendar access was never requested, so no Calendar Capabilities are advertised. The VM and other Mac Services are unaffected."
        case .denied:
            return "Calendar is on for this Link Session, but macOS Calendar access is turned off for Try Omarchy, so no Calendar Capabilities are advertised. The VM and other Mac Services are unaffected."
        case .restricted:
            return "Calendar is on for this Link Session, but macOS Calendar access is restricted by this Mac\u{2019}s policy, so no Calendar Capabilities are advertised. The VM and other Mac Services are unaffected."
        }
    }
}
