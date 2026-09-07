import Foundation

enum StartMenuPermissionAction: Equatable {
    case request
    case openSettings
}

struct StartMenuPermissionPresentation: Equatable {
    let detail: String
    let isGranted: Bool
    let actionTitle: String?
    let action: StartMenuPermissionAction?
}

struct StartMenuSharedFolderPresentation: Equatable {
    let detail: String
    let compactDetailLines: [String]?
    let isGranted: Bool
    let toggleActionTitle: String?
}

struct StartMenuPortForwardingPresentation: Equatable {
    let detail: String
    let compactDetailLines: [String]?
    let isGranted: Bool
    let grantedStatusLabel: String
}

enum StartMenuOmarchyLinkAvailability: Equatable {
    /// A persistent Workspace with a validated Link identity; choices persist
    /// for that Workspace and freeze when Omarchy starts.
    case workspace
    /// A disposable run; choices apply to this run only and are not saved.
    case ephemeral
    /// The Workspace identity is missing or invalid, so only Link is off.
    case unavailable
}

/// What the start menu knows about Omarchy Link for the upcoming launch.
/// nil at the window level means Link development mode is off and no Link row
/// is rendered at all.
struct StartMenuOmarchyLinkMenuState: Equatable {
    let availability: StartMenuOmarchyLinkAvailability
    let modes: OmarchyLinkServiceModes
    let calendarAuthorization: OmarchyLinkCalendarAuthorizationState
}

struct StartMenuOmarchyLinkServiceAction: Equatable {
    let service: OmarchyLinkMacService
    let title: String
}

struct StartMenuOmarchyLinkPresentation: Equatable {
    let detail: String
    let compactDetailLines: [String]?
    let isGranted: Bool
    let grantedStatusLabel: String
    let serviceActions: [StartMenuOmarchyLinkServiceAction]
    /// Non-fatal remediation when the Calendar Service Mode wants access the
    /// Apple grant does not provide. nil means nothing needs attention.
    let calendarAccessDetail: String?
    let calendarAccessActionTitle: String?
    let calendarAccessAction: StartMenuPermissionAction?
}

extension OmarchyLinkServiceMode {
    /// User-facing Service Mode names. These name a Try Omarchy choice, never
    /// an Apple permission or security entitlement.
    var menuDisplayName: String {
        switch self {
        case .off: "Off"
        case .read: "Read"
        case .readWrite: "Read & Write"
        }
    }

    /// One click advances a service to the next mode; the cycle covers every
    /// mode so nothing wider than Read & Write can ever be reached.
    var nextMenuChoice: OmarchyLinkServiceMode {
        switch self {
        case .off: .read
        case .read: .readWrite
        case .readWrite: .off
        }
    }
}

extension OmarchyLinkMacService {
    var menuDisplayName: String {
        switch self {
        case .calendar: "Calendar"
        case .messages: "Messages"
        case .notes: "Notes"
        }
    }
}

/// Pure presentation rules for the start menu. Keeping user-visible state out
/// of AppKit makes the important behavior testable without relying on window
/// positions, font metrics, run-loop timing, or the current display size.
enum StartMenuPresentation {
    static let incompatibleWorkspaceDetail = "The saved VM uses a storage or boot format this version can’t use, or its data folder contains multiple saved VMs. Reset Omarchy to create a compatible VM. Resetting permanently erases everything in the VM."

    static let bootRecoveryConfirmationTitle = "Prepare this saved VM once?"
    static let bootRecoveryConfirmationDetail = """
        Try Omarchy found an existing VM from an earlier app version. Before it starts, Try Omarchy will run a one-time, read-only recovery to pair that VM with its own kernel and startup files. The saved disk and all of its data remain intact.

        The factory image bundled with this app is ignored for this VM. Continuing does not reset the VM, upgrade Omarchy, or install system updates.
        """

    static func microphone(
        state: MicrophoneAuthorizationState,
        requestInFlight: Bool
    ) -> StartMenuPermissionPresentation {
        switch state {
        case .authorized:
            StartMenuPermissionPresentation(
                detail: "Apps in Omarchy can record from your Mac microphone.",
                isGranted: true,
                actionTitle: nil,
                action: nil
            )
        case .notDetermined:
            StartMenuPermissionPresentation(
                detail: "Optional. Speaker playback works without microphone access.",
                isGranted: false,
                actionTitle: requestInFlight ? "Waiting…" : "Allow…",
                action: .request
            )
        case .denied:
            StartMenuPermissionPresentation(
                detail: "Recording is off. Speaker playback will still work.",
                isGranted: false,
                actionTitle: "Open Settings",
                action: .openSettings
            )
        case .restricted:
            StartMenuPermissionPresentation(
                detail: "Recording is unavailable because of this Mac’s policy.",
                isGranted: false,
                actionTitle: nil,
                action: nil
            )
        }
    }

    static func camera(
        state: CameraAuthorizationState,
        requestInFlight: Bool
    ) -> StartMenuPermissionPresentation {
        switch state {
        case .authorized:
            StartMenuPermissionPresentation(
                detail: "Apps in Omarchy can use your Mac camera while they are recording.",
                isGranted: true,
                actionTitle: nil,
                action: nil
            )
        case .notDetermined:
            StartMenuPermissionPresentation(
                detail: "Optional. The camera turns on only while an Omarchy app uses it.",
                isGranted: false,
                actionTitle: requestInFlight ? "Waiting…" : "Allow…",
                action: .request
            )
        case .denied:
            StartMenuPermissionPresentation(
                detail: "The Mac camera is off inside Omarchy.",
                isGranted: false,
                actionTitle: "Open Settings",
                action: .openSettings
            )
        case .restricted:
            StartMenuPermissionPresentation(
                detail: "Camera access is unavailable because of this Mac’s policy.",
                isGranted: false,
                actionTitle: nil,
                action: nil
            )
        }
    }

    static func sharedFolder(
        state: SharedFolderMenuState
    ) -> StartMenuSharedFolderPresentation {
        let detail: String
        let compactDetailLines: [String]?
        if let problem = state.problem {
            detail = problem
            compactDetailLines = nil
        } else if let displayPath = state.displayPath, state.isEnabled {
            let guestPath = "~/\(SharedFolderPolicy.guestLinkName(state.path ?? displayPath))"
            detail = "Mac folder: \(displayPath). In Omarchy: \(guestPath)."
            compactDetailLines = [
                "Mac folder: \(displayPath)",
                "In Omarchy: \(guestPath)",
            ]
        } else if let displayPath = state.displayPath {
            detail = "Mac folder: \(displayPath). In Omarchy: Off."
            compactDetailLines = [
                "Mac folder: \(displayPath)",
                "In Omarchy: Off",
            ]
        } else {
            detail = "Optional. Pick a Mac folder to use inside Omarchy under the same name."
            compactDetailLines = nil
        }

        return StartMenuSharedFolderPresentation(
            detail: detail,
            compactDetailLines: compactDetailLines,
            isGranted: state.isEnabled && state.problem == nil,
            toggleActionTitle: state.path == nil ? nil : (state.isEnabled ? "Turn Off" : "Turn On")
        )
    }

    static func portForwarding(
        mappings: [PortForwardMapping]
    ) -> StartMenuPortForwardingPresentation {
        if mappings.isEmpty {
            return StartMenuPortForwardingPresentation(
                detail: "Optional. Reach services running in Omarchy at localhost on this Mac.",
                compactDetailLines: nil,
                isGranted: false,
                grantedStatusLabel: "●  0 Ports"
            )
        }
        if mappings.count == 1, let mapping = mappings.first {
            return StartMenuPortForwardingPresentation(
                detail: "localhost:\(mapping.hostPort) → "
                    + "Omarchy:\(mapping.guestPort) · \(mapping.protocol.displayName)",
                compactDetailLines: [
                    "Mac: localhost:\(mapping.hostPort)",
                    "Omarchy: port \(mapping.guestPort) · \(mapping.protocol.displayName)",
                ],
                isGranted: true,
                grantedStatusLabel: "●  1 Port"
            )
        }
        return StartMenuPortForwardingPresentation(
            detail: "\(mappings.count) localhost mappings. Available only on this Mac.",
            compactDetailLines: [
                "\(mappings.count) localhost mappings",
                "Available only on this Mac",
            ],
            isGranted: true,
            grantedStatusLabel: "●  \(mappings.count) Ports"
        )
    }

    /// Service Modes are user-visible trust choices, so the wording must say
    /// what an enabled read exposes and must never present the mode as an
    /// Apple permission or security entitlement.
    static func omarchyLink(
        modes: OmarchyLinkServiceModes,
        availability: StartMenuOmarchyLinkAvailability,
        calendarAuthorization: OmarchyLinkCalendarAuthorizationState
    ) -> StartMenuOmarchyLinkPresentation {
        if availability == .unavailable {
            let lines = [
                "Omarchy Link is unavailable because this VM has no valid Workspace identity.",
                "Omarchy still starts and runs without it.",
            ]
            return StartMenuOmarchyLinkPresentation(
                detail: lines.joined(separator: " "),
                compactDetailLines: lines,
                isGranted: false,
                grantedStatusLabel: "\u{25cf}  0 On",
                serviceActions: [],
                calendarAccessDetail: nil,
                calendarAccessActionTitle: nil,
                calendarAccessAction: nil
            )
        }

        let calendarAccess = calendarAccessRemediation(
            mode: modes.calendar,
            authorization: calendarAuthorization
        )

        let exposure = "Turning on Read or Read & Write exposes that service\u{2019}s "
            + "private data to every process in the trusted Owner session inside Omarchy."
        let persistence = availability == .ephemeral
            ? "Choices for this disposable VM apply to this run only and are not saved."
            : "Choices freeze when Omarchy starts; a change applies to the next launch."
        let boundary = "These are Try Omarchy choices, separate from what macOS allows this app to access."
        let lines = [exposure, persistence, boundary]

        let services: [OmarchyLinkMacService] = [.calendar, .messages, .notes]
        let enabledCount = services.count { modes.mode(for: $0) != .off }
        return StartMenuOmarchyLinkPresentation(
            detail: lines.joined(separator: " "),
            compactDetailLines: lines,
            isGranted: enabledCount > 0,
            grantedStatusLabel: "\u{25cf}  \(enabledCount) On",
            serviceActions: services.map { service in
                StartMenuOmarchyLinkServiceAction(
                    service: service,
                    title: "\(service.menuDisplayName): \(modes.mode(for: service).menuDisplayName)"
                )
            },
            calendarAccessDetail: calendarAccess?.detail,
            calendarAccessActionTitle: calendarAccess?.actionTitle,
            calendarAccessAction: calendarAccess?.action
        )
    }

    /// Accurate per-grant remediation, shown only when the Calendar Service
    /// Mode is on but the Apple grant blocks it. Every state is non-fatal:
    /// the VM and the other Mac Services stay available, and the wording must
    /// distinguish the Try Omarchy choice from the macOS grant.
    private static func calendarAccessRemediation(
        mode: OmarchyLinkServiceMode,
        authorization: OmarchyLinkCalendarAuthorizationState
    ) -> (detail: String, actionTitle: String?, action: StartMenuPermissionAction?)? {
        guard mode != .off else { return nil }
        switch authorization {
        case .authorized:
            return nil
        case .notDetermined:
            return (
                detail: "Calendar is on for Omarchy Link, but this Mac hasn\u{2019}t been asked for Calendar access yet. Calendar stays unavailable inside Omarchy until it is allowed; everything else still works.",
                actionTitle: "Allow Calendar\u{2026}",
                action: .request
            )
        case .denied:
            return (
                detail: "macOS Calendar access is turned off for Try Omarchy, so Calendar is unavailable inside Omarchy. Everything else still works. Turn it on in System Settings > Privacy & Security > Calendars.",
                actionTitle: "Open Settings",
                action: .openSettings
            )
        case .restricted:
            return (
                detail: "macOS Calendar access is restricted by this Mac\u{2019}s policy, so Calendar is unavailable inside Omarchy. Everything else still works.",
                actionTitle: nil,
                action: nil
            )
        }
    }

    static func immersiveDetail(isEnabled: Bool) -> String {
        isEnabled
            ? "Omarchy opens Full Screen with the Mac menu bar and Dock hidden."
            : "Omarchy opens in a window with the Mac menu bar and Dock available."
    }
}
