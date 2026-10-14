import AppKit
import Foundation

/// What a document tab draws, behind a seam so a test never builds Quick
/// Look's view.
@MainActor
public protocol BrowserDocumentPreview: AnyObject {
    var view: NSView { get }
    func show(_ file: URL)
    /// Lets go, for good, of what the preview holds.
    func close()
}

/// A document tab's page (M66 §3.5): a document, a spreadsheet, a
/// presentation, rich text, a picture WebKit does not draw, or CSV, as Quick
/// Look draws it, packages among them.
///
/// Quick Look is handed the file's address and nothing more: no folder is
/// granted, and no web view is involved. The preview is closed when the tab
/// closes, since the pane's window, which Quick Look would otherwise wait
/// for, outlives every tab.
@MainActor
final class BrowserDocumentPage: BrowserPage {
    weak var events: (any BrowserPageEvents)?

    private let preview: any BrowserDocumentPreview

    init(preview: any BrowserDocumentPreview) {
        self.preview = preview
    }

    var view: NSView { preview.view }

    func loadFile(_ url: URL, as kind: BrowserFileKind, readAccess: URL) {
        preview.show(url)
    }

    func close() {
        preview.close()
    }

    /// A document tab loads no address, keeps no history, and finds and
    /// zooms nothing: Quick Look's view carries its own scrolling and zoom.
    func load(_ url: URL) {}
    func back() {}
    func forward() {}
    func reload() {}
    func stop() {}
    func find(_ text: String) {}
    func zoom(_ zoom: BrowserZoom) {}
}
