import AppKit
import Testing
@testable import OmarchyVMHelper

@Suite("Start menu Omarchy Link row", .serialized)
@MainActor
struct StartMenuOmarchyLinkRowTests {
    @Test("released builds render no Omarchy Link row at all")
    func hiddenWithoutDevelopmentState() {
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
            linkState: { StartMenuOmarchyLinkMenuState(availability: .workspace, modes: modes) },
            setMode: { service, mode in
                recorded.append((service, mode))
                modes = modes.updating(service, to: mode)
            }
        )
        menu.prepareForPresentation(visibleFrame: NSRect(x: 0, y: 0, width: 1440, height: 900))
        defer { menu.dismiss() }

        let content = try #require(menu.window.contentView)
        let calendarButton = try #require(
            descendant(withIdentifier: "permission-action-link-0", in: content) as? NSButton
        )
        #expect(calendarButton.title == "Calendar: Off")

        calendarButton.performClick(nil)

        #expect(recorded.count == 1)
        #expect(recorded.first?.0 == .calendar)
        #expect(recorded.first?.1 == .read)
        let rerendered = try #require(menu.window.contentView)
        let updatedButton = try #require(
            descendant(withIdentifier: "permission-action-link-0", in: rerendered) as? NSButton
        )
        #expect(updatedButton.title == "Calendar: Read")
        let messagesButton = try #require(
            descendant(withIdentifier: "permission-action-link-1", in: rerendered) as? NSButton
        )
        #expect(messagesButton.title == "Messages: Off")
    }

    @Test("an unavailable Link renders no mode choices")
    func unavailableOffersNoChoices() throws {
        _ = NSApplication.shared
        let menu = makeMenu(
            linkState: {
                StartMenuOmarchyLinkMenuState(availability: .unavailable, modes: .allOff)
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

    private func descendant(withIdentifier identifier: String, in view: NSView) -> NSView? {
        if view.identifier?.rawValue == identifier {
            return view
        }
        for subview in view.subviews {
            if let match = descendant(withIdentifier: identifier, in: subview) {
                return match
            }
        }
        return nil
    }
}
