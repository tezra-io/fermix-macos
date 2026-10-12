import Foundation
import UniformTypeIdentifiers

/// What the pane shows a file on this Mac as (plan §8.2, M66 §3.5), by the
/// type its extension names: pure, so the rule is provable without a file or
/// a view. A file whose type the Mac does not know as content may still read
/// as text, which only its bytes can say (`BrowserLocalFile`).
///
/// WebKit draws the first four itself: an image, a PDF and an HTML file as
/// they are, and text as plain text, which covers source code, scripts and
/// markdown. Showing a script runs nothing: a file tab runs no page script
/// and loads nothing from the network, and the person wants to read what the
/// agent wrote.
///
/// The pane draws the other two with what macOS has: sound and film on the
/// app's one player in AVKit's own view, and every other document of a named
/// family as Quick Look draws it. Neither is ever a type that runs.
public enum BrowserFileKind: Equatable, Sendable {
    case image
    case pdf
    case html
    case text
    /// Sound or film, in a media tab.
    case media
    /// A document, a spreadsheet, a presentation, rich text, a picture WebKit
    /// does not draw, or CSV, in a document tab.
    case document

    /// The largest file a tab reads whole before it draws it, 10 MB as Finder
    /// counts: text, which the pane reads itself, and CSV, which Quick Look's
    /// own service reads whole. A log that size is better read in an app made
    /// for it.
    public static let textSizeCap = 10_000_000

    /// The images WebKit draws itself, named rather than every image there
    /// is: a Photoshop file or a camera's raw file is an image too, and
    /// WebKit draws neither.
    public static let imageTypes: [UTType] = [
        .png, .jpeg, .gif, .webP, .heic, .heif, .tiff, .bmp, .svg, .ico
    ] + [UTType("public.avif")].compactMap { $0 }

    /// The kind a file of `type` shows as, or nil where its type says none.
    /// An image comes first, so an SVG draws as a picture rather than as the
    /// XML it is written in, and HTML before text, which it also is. CSV is
    /// text too, and Quick Look draws it as the table it is. Rich text is not
    /// text to the pane: what it holds is a word processor's markup, which
    /// Quick Look draws as the document it is.
    public init?(_ type: UTType) {
        if Self.imageTypes.contains(where: type.conforms) {
            self = .image
        } else if type.conforms(to: .pdf) {
            self = .pdf
        } else if type.conforms(to: .html) {
            self = .html
        } else if type.conforms(to: .commaSeparatedText) {
            self = .document
        } else if type.conforms(to: .text), !type.conforms(to: .rtf) {
            self = .text
        } else if BrowserLocalFile.isDocument(type) {
            self = type.conforms(to: .audiovisualContent) ? .media : .document
        } else {
            return nil
        }
    }

    /// Whether WebKit draws it, in a file page that may read what the tab
    /// grants; the pane's own viewers are granted nothing.
    public var drawnByWebKit: Bool {
        switch self {
        case .image, .pdf, .html, .text: return true
        case .media, .document: return false
        }
    }

    /// Whether a file of `type` shown as this is read whole before it is
    /// drawn, and so is held to `textSizeCap`.
    func readsWhole(_ type: UTType) -> Bool {
        self == .text || type.conforms(to: .commaSeparatedText)
    }
}
