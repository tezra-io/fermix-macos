import Foundation
import UniformTypeIdentifiers

/// What the pane shows a file on this Mac as (plan §8.2), by the type its
/// extension names: pure, so the rule is provable without a file or a web
/// view.
///
/// WebKit draws all four itself, so a file tab needs no viewer of its own:
/// an image, a PDF and an HTML file as they are, and text as plain text,
/// which covers source code and markdown. Anything else is not the pane's to
/// show and goes to the app on the Mac that opens it.
public enum BrowserFileKind: Equatable, Sendable {
    case image
    case pdf
    case html
    case text

    /// The largest text file the pane shows, 10 MB as Finder counts: a file
    /// tab reads text whole before it draws it, and a log that size is better
    /// read in an app made for it.
    public static let textSizeCap = 10_000_000

    /// What runs when it is opened: an app, an executable and a script, and
    /// anything that conforms to one. Never a kind the pane shows, though a
    /// script is text too, and never opened at all (`BrowserLocalFile`).
    public static let runnableTypes: [UTType] = [
        .applicationBundle, .application, .executable, .unixExecutable, .script, .shellScript
    ]

    /// Text as the pane shows it: plain text, which source code and markdown
    /// conform to, and the three structured formats that do not.
    public static let textTypes: [UTType] = [.plainText, .json, .xml, .yaml]

    /// The kind a file of `type` shows as, or nil where the pane shows none.
    /// An image comes first, so an SVG draws as a picture rather than as the
    /// XML it is written in.
    public init?(_ type: UTType) {
        guard !Self.runs(type) else { return nil }

        if type.conforms(to: .image) {
            self = .image
        } else if type.conforms(to: .pdf) {
            self = .pdf
        } else if type.conforms(to: .html) {
            self = .html
        } else if Self.textTypes.contains(where: type.conforms) {
            self = .text
        } else {
            return nil
        }
    }

    public static func runs(_ type: UTType) -> Bool {
        runnableTypes.contains(where: type.conforms)
    }
}
