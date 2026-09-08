import Testing
@testable import OmarchyVMHelper

@Suite("Start menu presentation")
struct StartMenuPresentationTests {
    @Test("the reset notice describes actual compatibility failures, not app updates")
    func incompatibleWorkspaceNotice() {
        let detail = StartMenuPresentation.incompatibleWorkspaceDetail
        #expect(detail.contains("storage or boot format"))
        #expect(detail.contains("multiple saved VMs"))
        #expect(detail.contains("permanently erases"))
        #expect(!detail.contains("different Try Omarchy build"))
    }

    @Test("boot recovery notice promises preservation and no automatic upgrade")
    func bootRecoveryNotice() {
        let detail = StartMenuPresentation.bootRecoveryConfirmationDetail
        #expect(detail.contains("one-time, read-only"))
        #expect(detail.contains("saved disk"))
        #expect(detail.contains("data remain intact"))
        #expect(detail.contains("factory image"))
        #expect(detail.contains("does not reset"))
        #expect(detail.contains("upgrade Omarchy"))
    }

    @Test("continuing the one-time prompt grants consent for only that launch")
    func bootRecoveryContinue() {
        var promptCount = 0
        let decision = BootRecoveryLaunchGate.decide(
            preflight: .requiresConfirmation,
            confirm: {
                promptCount += 1
                return true
            }
        )
        #expect(promptCount == 1)
        #expect(decision == .launch(allowBootRecovery: true))
    }

    @Test("cancelling the one-time prompt aborts launch")
    func bootRecoveryCancel() {
        var promptCount = 0
        let decision = BootRecoveryLaunchGate.decide(
            preflight: .requiresConfirmation,
            confirm: {
                promptCount += 1
                return false
            }
        )
        #expect(promptCount == 1)
        #expect(decision == .cancel)
    }

    @Test("a paired VM suppresses the prompt and launches without consent")
    func pairedVMSuppressesRecoveryPrompt() {
        var promptCount = 0
        let decision = BootRecoveryLaunchGate.decide(
            preflight: .notRequired,
            confirm: {
                promptCount += 1
                return true
            }
        )
        #expect(promptCount == 0)
        #expect(decision == .launch(allowBootRecovery: false))
    }

    @Test("the recovery handshake retries at most once per confirmation")
    func bootRecoveryHandshakeIsBounded() {
        let consentRequired = VMExitPresentationDecision.make(
            status: VMExitPresentationDecision.bootRecoveryConsentRequiredStatus,
            reachedVirtualMachineStart: false,
            wasStopping: false
        )
        #expect(BootRecoveryChildExitGate.decide(
            presentation: consentRequired,
            launchWasAuthorized: false
        ) == .requestConfirmation)

        let accepted = BootRecoveryLaunchGate.decide(
            preflight: .requiresConfirmation,
            confirm: { true }
        )
        #expect(accepted == .launch(allowBootRecovery: true))
        #expect(BootRecoveryChildExitGate.decide(
            presentation: consentRequired,
            launchWasAuthorized: true
        ) == .reportFailure)

        let recoveryFailed = VMExitPresentationDecision.make(
            status: VMExitPresentationDecision.bootRecoveryFailedStatus,
            reachedVirtualMachineStart: false,
            wasStopping: false
        )
        #expect(BootRecoveryChildExitGate.decide(
            presentation: recoveryFailed,
            launchWasAuthorized: true
        ) == .reportFailure)
        #expect(BootRecoveryLaunchGate.decide(
            preflight: .requiresConfirmation,
            confirm: { false }
        ) == .cancel)
    }

    @Test("microphone permission states offer only valid actions")
    func microphoneStates() {
        let authorized = StartMenuPresentation.microphone(
            state: .authorized,
            requestInFlight: false
        )
        #expect(authorized.isGranted)
        #expect(authorized.action == nil)
        #expect(authorized.actionTitle == nil)

        let undecided = StartMenuPresentation.microphone(
            state: .notDetermined,
            requestInFlight: false
        )
        #expect(!undecided.isGranted)
        #expect(undecided.action == .request)
        #expect(undecided.actionTitle == "Allow…")
        #expect(undecided.detail.contains("Optional"))

        let waiting = StartMenuPresentation.microphone(
            state: .notDetermined,
            requestInFlight: true
        )
        #expect(waiting.action == .request)
        #expect(waiting.actionTitle == "Waiting…")

        let denied = StartMenuPresentation.microphone(
            state: .denied,
            requestInFlight: false
        )
        #expect(denied.action == .openSettings)
        #expect(denied.actionTitle == "Open Settings")
        #expect(denied.detail.contains("Speaker playback will still work"))

        let restricted = StartMenuPresentation.microphone(
            state: .restricted,
            requestInFlight: false
        )
        #expect(!restricted.isGranted)
        #expect(restricted.action == nil)
        #expect(restricted.actionTitle == nil)
    }

    @Test("camera permission states keep camera access optional and recoverable")
    func cameraStates() {
        let authorized = StartMenuPresentation.camera(
            state: .authorized,
            requestInFlight: false
        )
        #expect(authorized.isGranted)
        #expect(authorized.action == nil)

        let undecided = StartMenuPresentation.camera(
            state: .notDetermined,
            requestInFlight: false
        )
        #expect(undecided.action == .request)
        #expect(undecided.actionTitle == "Allow…")
        #expect(undecided.detail.contains("Optional"))

        let waiting = StartMenuPresentation.camera(
            state: .notDetermined,
            requestInFlight: true
        )
        #expect(waiting.actionTitle == "Waiting…")

        let denied = StartMenuPresentation.camera(
            state: .denied,
            requestInFlight: false
        )
        #expect(denied.action == .openSettings)
        #expect(denied.actionTitle == "Open Settings")

        let restricted = StartMenuPresentation.camera(
            state: .restricted,
            requestInFlight: false
        )
        #expect(!restricted.isGranted)
        #expect(restricted.action == nil)
    }

    @Test("shared folder states distinguish absent, disabled, enabled, and broken shares")
    func sharedFolderStates() {
        let absent = StartMenuPresentation.sharedFolder(state: .disabled)
        #expect(!absent.isGranted)
        #expect(absent.compactDetailLines == nil)
        #expect(absent.toggleActionTitle == nil)

        let disabled = StartMenuPresentation.sharedFolder(
            state: SharedFolderMenuState(
                path: "/Users/test/Projects/demo",
                displayPath: "~/Projects/demo",
                isEnabled: false,
                problem: nil
            )
        )
        #expect(!disabled.isGranted)
        #expect(disabled.compactDetailLines == [
            "Mac folder: ~/Projects/demo",
            "In Omarchy: Off",
        ])
        #expect(disabled.toggleActionTitle == "Turn On")

        let enabled = StartMenuPresentation.sharedFolder(
            state: SharedFolderMenuState(
                path: "/Users/test/Projects/demo",
                displayPath: "~/Projects/demo",
                isEnabled: true,
                problem: nil
            )
        )
        #expect(enabled.isGranted)
        #expect(enabled.compactDetailLines == [
            "Mac folder: ~/Projects/demo",
            "In Omarchy: ~/demo",
        ])
        #expect(enabled.toggleActionTitle == "Turn Off")

        let broken = StartMenuPresentation.sharedFolder(
            state: SharedFolderMenuState(
                path: "/Volumes/Missing/demo",
                displayPath: "/Volumes/Missing/demo",
                isEnabled: true,
                problem: "The selected folder is unavailable."
            )
        )
        #expect(!broken.isGranted)
        #expect(broken.detail == "The selected folder is unavailable.")
        #expect(broken.compactDetailLines == nil)
        #expect(broken.toggleActionTitle == "Turn Off")
    }

    @Test("port summary covers empty, single, and multiple mappings")
    func portForwardingStates() {
        let empty = StartMenuPresentation.portForwarding(mappings: [])
        #expect(!empty.isGranted)
        #expect(empty.compactDetailLines == nil)

        let single = StartMenuPresentation.portForwarding(mappings: [
            PortForwardMapping(hostPort: 2222, guestPort: 22, protocol: .tcp),
        ])
        #expect(single.isGranted)
        #expect(single.grantedStatusLabel == "●  1 Port")
        #expect(single.compactDetailLines == [
            "Mac: localhost:2222",
            "Omarchy: port 22 · TCP",
        ])

        let multiple = StartMenuPresentation.portForwarding(mappings: [
            PortForwardMapping(hostPort: 8080, guestPort: 3000, protocol: .tcp),
            PortForwardMapping(hostPort: 5353, guestPort: 5353, protocol: .udp),
        ])
        #expect(multiple.isGranted)
        #expect(multiple.grantedStatusLabel == "●  2 Ports")
        #expect(multiple.compactDetailLines == [
            "2 localhost mappings",
            "Available only on this Mac",
        ])
    }

    @Test("Omarchy Link explains Owner-session read exposure without claiming an Apple permission")
    func omarchyLinkWorkspaceGuidance() {
        let presentation = StartMenuPresentation.omarchyLink(
            modes: OmarchyLinkServiceModes(calendar: .read, messages: .off, notes: .readWrite),
            availability: .workspace,
            calendarAuthorization: .authorized
        )

        #expect(presentation.detail.contains("private data"))
        #expect(presentation.detail.contains("trusted Owner session"))
        #expect(presentation.detail.contains("next launch"))
        #expect(presentation.detail.contains("separate from"))
        #expect(!presentation.detail.localizedCaseInsensitiveContains("entitlement"))
        #expect(presentation.isGranted)
        #expect(presentation.grantedStatusLabel == "\u{25cf}  1 On")
        #expect(presentation.serviceActions == [
            StartMenuOmarchyLinkServiceAction(service: .calendar, title: "Calendar: Read"),
        ])
        for action in presentation.serviceActions {
            #expect(!action.title.localizedCaseInsensitiveContains("permission"))
        }
    }

    @Test("an ephemeral run explains that Calendar is unavailable without offering mode choices")
    func omarchyLinkEphemeralGuidance() {
        let presentation = StartMenuPresentation.omarchyLink(
            modes: .allOff,
            availability: .ephemeral,
            calendarAuthorization: .authorized
        )

        #expect(presentation.detail.contains("unavailable"))
        #expect(presentation.detail.contains("disposable"))
        #expect(presentation.detail.contains("still starts"))
        #expect(!presentation.isGranted)
        #expect(presentation.serviceActions.isEmpty)
        #expect(presentation.calendarAccessAction == nil)
    }

    @Test("an invalid Workspace identity disables Link choices, not the VM")
    func omarchyLinkUnavailableGuidance() {
        let presentation = StartMenuPresentation.omarchyLink(
            modes: .allOff,
            availability: .unavailable,
            calendarAuthorization: .denied
        )

        #expect(presentation.detail.contains("unavailable"))
        #expect(presentation.detail.contains("still starts"))
        #expect(!presentation.isGranted)
        #expect(presentation.serviceActions.isEmpty)
        // No mode can be chosen, so no Calendar remediation applies either.
        #expect(presentation.calendarAccessDetail == nil)
        #expect(presentation.calendarAccessAction == nil)
    }

    @Test("each Apple Calendar grant state gets accurate non-fatal remediation")
    func omarchyLinkCalendarGrantRemediation() {
        let readModes = OmarchyLinkServiceModes(calendar: .read, messages: .off, notes: .off)

        let granted = StartMenuPresentation.omarchyLink(
            modes: readModes, availability: .workspace, calendarAuthorization: .authorized
        )
        #expect(granted.calendarAccessDetail == nil)
        #expect(granted.calendarAccessActionTitle == nil)
        #expect(granted.calendarAccessAction == nil)

        let notDetermined = StartMenuPresentation.omarchyLink(
            modes: readModes, availability: .workspace, calendarAuthorization: .notDetermined
        )
        #expect(notDetermined.calendarAccessDetail?.contains("hasn\u{2019}t been asked") == true)
        #expect(notDetermined.calendarAccessDetail?.contains("everything else still works") == true)
        #expect(notDetermined.calendarAccessActionTitle == "Allow Calendar\u{2026}")
        #expect(notDetermined.calendarAccessAction == .request)

        let denied = StartMenuPresentation.omarchyLink(
            modes: readModes, availability: .workspace, calendarAuthorization: .denied
        )
        #expect(denied.calendarAccessDetail?.contains("turned off for Try Omarchy") == true)
        #expect(denied.calendarAccessDetail?.contains("System Settings") == true)
        #expect(denied.calendarAccessActionTitle == "Open Settings")
        #expect(denied.calendarAccessAction == .openSettings)

        let restricted = StartMenuPresentation.omarchyLink(
            modes: readModes, availability: .workspace, calendarAuthorization: .restricted
        )
        #expect(restricted.calendarAccessDetail?.contains("restricted") == true)
        #expect(restricted.calendarAccessActionTitle == nil)
        #expect(restricted.calendarAccessAction == nil)

        // Mode choices survive every grant state: remediation never removes
        // the user's Service Mode controls or claims the VM is affected.
        for presentation in [notDetermined, denied, restricted] {
            #expect(presentation.serviceActions.count == 1)
            #expect(presentation.calendarAccessDetail?.localizedCaseInsensitiveContains("permission") != true)
        }
    }

    @Test("a Calendar mode of Off asks for no Calendar remediation")
    func omarchyLinkOffModeNeedsNoRemediation() {
        for state in [
            OmarchyLinkCalendarAuthorizationState.authorized, .denied, .restricted, .notDetermined,
        ] {
            let presentation = StartMenuPresentation.omarchyLink(
                modes: .allOff, availability: .workspace, calendarAuthorization: state
            )
            #expect(presentation.calendarAccessDetail == nil, "grant: \(state)")
            #expect(presentation.calendarAccessAction == nil, "grant: \(state)")
        }
    }

    @Test("cycling a Service Mode never skips or invents a mode")
    func omarchyLinkModeCycle() {
        #expect(OmarchyLinkServiceMode.off.nextMenuChoice == .read)
        #expect(OmarchyLinkServiceMode.read.nextMenuChoice == .readWrite)
        #expect(OmarchyLinkServiceMode.readWrite.nextMenuChoice == .off)
    }

    @Test("immersive guidance distinguishes windowed and fullscreen launch")
    func immersiveGuidance() {
        #expect(StartMenuPresentation.immersiveDetail(isEnabled: true)
            == "Omarchy opens Full Screen with the Mac menu bar and Dock hidden.")
        #expect(StartMenuPresentation.immersiveDetail(isEnabled: false)
            == "Omarchy opens in a window with the Mac menu bar and Dock available.")
    }
}
