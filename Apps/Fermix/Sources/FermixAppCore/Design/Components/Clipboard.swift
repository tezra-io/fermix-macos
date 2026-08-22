import AppKit

/// The pasteboard, in one place.
///
/// Copying is the whole of the app's part in the CLI ritual and in the Logs
/// copy action, so it is worth having exactly one function that does it.
public enum Clipboard {
    public static func write(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
