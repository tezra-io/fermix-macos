import AppKit
import Foundation

/// The pane's own two viewers (M66 §3.5), for the files WebKit does not
/// draw: AVKit's view of the app's one player, and Quick Look's view of a
/// document. Behind a seam, because both frameworks are GUI-only
/// (`FermixViewers`, which `main.swift` hands in) and so that a test never
/// builds either; the pages over them (`BrowserMediaPage`,
/// `BrowserDocumentPage`) are the product's own in tests too.
@MainActor
public protocol BrowserViewerMaking {
    func mediaSurface(_ player: AppPlayer) -> any BrowserMediaSurface
    func documentPreview() -> any BrowserDocumentPreview
}
