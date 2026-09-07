import AppKit

/// Shared identifier-based view lookup for start menu window tests, so
/// assertions bind to stable view identifiers rather than positions or fonts.
@MainActor
func descendant(withIdentifier identifier: String, in view: NSView) -> NSView? {
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
