import AppKit
import SwiftUI

/// The system's own search field, for a search that belongs to a list on the
/// page rather than to the toolbar.
///
/// SwiftUI draws a search field only through `searchable`, which places it in
/// a sidebar or the toolbar. The settings pane list is neither since settings
/// moved inside the window's frame, and a field in the toolbar read as a search
/// of the page rather than of the list it filters (owner, 2026-09-25). This is
/// `NSSearchField` itself, so the capsule, the magnifier, the clear button and
/// Escape clearing it are the system's.
struct SearchField: NSViewRepresentable {
    @Binding var text: String
    let prompt: String

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = prompt
        field.delegate = context.coordinator
        // The clear button sends the action rather than a text change.
        field.target = context.coordinator
        field.action = #selector(Coordinator.searched(_:))
        field.setAccessibilityLabel(prompt)

        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.text = $text
        if field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }

            text.wrappedValue = field.stringValue
        }

        @objc func searched(_ field: NSSearchField) {
            text.wrappedValue = field.stringValue
        }
    }
}
