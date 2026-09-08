import AppKit
import Testing
@testable import OmarchyVMHelper

@Suite("Start menu Omarchy Link row", .serialized)
@MainActor
struct StartMenuOmarchyLinkRowTests {
    @Test("a window without a Link state provider omits the row")
    func hiddenWithoutStateProvider() {
        _ = NSApplication.shared
        let menu = makeMenu(linkState: { nil }, setMode: { _, _ in })
        menu.prepareForPresentation(visibleFrame: NSRect(x: 0, y: 0, width: 1440, height: 900))
        defer { menu.dismiss() }

        let content = menu.window.contentView!
        #expect(descendant(withIdentifier: "permission-row-link", in: content) == nil)
    }

    @Test("one click advances exactly one Service Mode and re-renders")
    func cyclesOneServiceMode() throws {
        _ = NSApplication.shared
        var modes = OmarchyLinkServiceModes.allOff
        var recorded: [(OmarchyLinkMacService, OmarchyLinkServiceMode)] = []
        let menu = makeMenu(
            linkState: {
                StartMenuOmarchyLinkMenuState(
                    availability: .workspace,
                    modes: modes,
                    calendarAuthorization: .authorized
                )
            },
            setMode: { service, mode in
                recorded.append((service, mode))
                modes = modes.updating(service, to: mode)
            }
        )
        menu.prepareForPresentation(visibleFrame: NSRect(x: 0, y: 0, width: 1440, height: 900))
        defer { menu.dismiss() }

        let content = try #require(menu.window.contentView)
        let calendarButton = try #require(
            descendant(withIdentifier: "permission-action-link", in: content) as? NSButton
        )
        #expect(calendarButton.title == "Calendar: Off")

        calendarButton.performClick(nil)

        #expect(recorded.count == 1)
        #expect(recorded.first?.0 == .calendar)
        #expect(recorded.first?.1 == .read)
        let rerendered = try #require(menu.window.contentView)
        let updatedButton = try #require(
            descendant(withIdentifier: "permission-action-link", in: rerendered) as? NSButton
        )
        #expect(updatedButton.title == "Calendar: Read")
        #expect(descendant(withIdentifier: "permission-action-link-1", in: rerendered) == nil)
    }

    @Test("an unavailable Link renders no mode choices")
    func unavailableOffersNoChoices() throws {
        _ = NSApplication.shared
        let menu = makeMenu(
            linkState: {
                StartMenuOmarchyLinkMenuState(
                    availability: .unavailable,
                    modes: .allOff,
                    calendarAuthorization: .authorized
                )
            },
            setMode: { _, _ in Issue.record("unavailable Link must not accept mode changes") }
        )
        menu.prepareForPresentation(visibleFrame: NSRect(x: 0, y: 0, width: 1440, height: 900))
        defer { menu.dismiss() }

        let content = try #require(menu.window.contentView)
        #expect(descendant(withIdentifier: "permission-row-link", in: content) != nil)
        #expect(descendant(withIdentifier: "permission-action-link", in: content) == nil)
        #expect(descendant(withIdentifier: "permission-action-link-0", in: content) == nil)
    }

    @Test("a denied Apple grant renders remediation without hiding mode choices")
    func deniedGrantRendersRemediationAction() throws {
        _ = NSApplication.shared
        let menu = makeMenu(
            linkState: {
                StartMenuOmarchyLinkMenuState(
                    availability: .workspace,
                    modes: OmarchyLinkServiceModes(calendar: .read, messages: .off, notes: .off),
                    calendarAuthorization: .denied
                )
            },
            setMode: { _, _ in }
        )
        menu.prepareForPresentation(visibleFrame: NSRect(x: 0, y: 0, width: 1440, height: 900))
        defer { menu.dismiss() }

        let content = try #require(menu.window.contentView)
        // The Calendar Service Mode button stays, and remediation follows.
        let calendarButton = try #require(
            descendant(withIdentifier: "permission-action-link-0", in: content) as? NSButton
        )
        #expect(calendarButton.title == "Calendar: Read")
        let remediationButton = try #require(
            descendant(withIdentifier: "permission-action-link-1", in: content) as? NSButton
        )
        #expect(remediationButton.title == "Open Settings")
    }

    private func makeMenu(
        linkState: @escaping () -> StartMenuOmarchyLinkMenuState?,
        setMode: @escaping (OmarchyLinkMacService, OmarchyLinkServiceMode) -> Void
    ) -> StartMenuWindow {
        StartMenuWindow(
            accessibilityStatus: { true },
            microphoneStatus: { .authorized },
            cameraStatus: { .authorized },
            requestAccessibility: {},
            requestMicrophone: { completion in completion(true) },
            requestCamera: { completion in completion(true) },
            canResetStorage: true,
            storageLocation: { nil },
            storageLocationURL: { nil },
            storageSpaceEstimate: { nil },
            storageLocationStatus: { .defaultLocation },
            validateStorageLocation: { _ in nil },
            chooseStorageLocation: { _ in nil },
            useDefaultStorageLocation: {},
            resetStorage: {},
            sharedFolderStatus: { .disabled },
            chooseSharedFolder: { _ in nil },
            setSharedFolderEnabled: { _ in },
            portForwardingStatus: { [] },
            immersiveMode: { true },
            setImmersiveMode: { _ in },
            omarchyLinkStatus: linkState,
            setOmarchyLinkMode: setMode,
            launch: {}
        )
    }
}
