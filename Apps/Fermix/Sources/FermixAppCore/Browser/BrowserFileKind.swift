import Foundation
import UniformTypeIdentifiers

/// What the pane shows a file on this Mac as (plan §8.2), by the type its
/// extension names: pure, so the rule is provable without a file or a web
/// view. A file whose type the Mac does not know as content may still read
/// as text, which only its bytes can say (`BrowserLocalFile`).
///
/// WebKit draws all four itself, so a file tab needs no viewer of its own:
/// an image, a PDF and an HTML file as they are, and text as plain text,
/// which covers source code, scripts and markdown. Showing a script runs
/// nothing: a file tab runs no page script and loads nothing from the
/// network, and the person wants to read what the agent wrote.
public enum BrowserFileKind: Equatable, Sendable {
    case image
    case pdf
    case html
    case text

    /// The largest text file the pane shows, 10 MB as Finder counts: a file
    /// tab reads text whole before it draws it, and a log that size is better
    /// read in an app made for it.
    public static let textSizeCap = 10_000_000

    /// The images WebKit draws itself, named rather than every image there
    /// is: a Photoshop file or a camera's raw file is an image too, and
    /// WebKit draws neither.
    public static let imageTypes: [UTType] = [
        .png, .jpeg, .gif, .webP, .heic, .heif, .tiff, .bmp, .svg, .ico
    ] + [UTType("public.avif")].compactMap { $0 }

    /// The kind a file of `type` shows as, or nil where its type says none.
    /// An image comes first, so an SVG draws as a picture rather than as the
    /// XML it is written in, and HTML before text, which it also is. Rich
    /// text is not text to the pane: what it holds is a word processor's
    /// markup.
    public init?(_ type: UTType) {
        if Self.imageTypes.contains(where: type.conforms) {
            self = .image
        } else if type.conforms(to: .pdf) {
            self = .pdf
        } else if type.conforms(to: .html) {
            self = .html
        } else if type.conforms(to: .text), !type.conforms(to: .rtf) {
            self = .text
        } else {
            return nil
        }
    }
}
