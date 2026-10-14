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

    /// The types the pasteboard community agreed on for a secret: clipboard
    /// managers and history tools skip an item that carries them.
    private static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    private static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    /// Copies a secret for this Mac only: kept off Universal Clipboard, marked
    /// so clipboard history leaves it out, and answered with the pasteboard's
    /// change count, which is what `withdraw` takes it back by.
    public static func writeSecret(_ text: String) -> Int {
        let pasteboard = NSPasteboard.general
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        pasteboard.setString(text, forType: .string)
        pasteboard.setString("", forType: concealed)
        pasteboard.setString("", forType: transient)

        return pasteboard.changeCount
    }

    /// Takes a secret back off the pasteboard, unless something has been
    /// copied over it since, which is then the person's and stays.
    public static func withdraw(_ changeCount: Int) {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount == changeCount else { return }

        pasteboard.clearContents()
    }
}
