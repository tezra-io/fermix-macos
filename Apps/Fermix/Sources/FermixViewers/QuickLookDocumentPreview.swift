import AppKit
import FermixAppCore
import QuickLookUI

/// Quick Look's own preview view, held open across the pane's window and
/// closed by its tab.
@MainActor
final class QuickLookDocumentPreview: BrowserDocumentPreview {
    private let preview: QLPreviewView

    init() {
        guard let preview = QLPreviewView(frame: .zero, style: .normal) else {
            preconditionFailure("Quick Look builds its preview view")
        }

        preview.shouldCloseWithWindow = false
        self.preview = preview
    }

    var view: NSView { preview }

    func show(_ file: URL) {
        preview.previewItem = file as NSURL
    }

    func close() {
        preview.close()
    }
}
