import AppKit
import FermixAppCore

/// The pane's own two viewers as macOS draws them (M66 §3.5): AVKit's player
/// view on the app's one player, and Quick Look's preview view. No renderer
/// or codec ships with the app: both are the system's.
///
/// The only module that imports AVKit and QuickLookUI. `FermixAppCore`
/// declares `BrowserViewerMaking` and imports neither, because both
/// executables link that library and `FermixAgent` shows no viewer; only the
/// `Fermix` executable links this target, and `main.swift` hands the viewers
/// in, as it hands in the browser's engine.
public struct SystemBrowserViewers: BrowserViewerMaking {
    public init() {}

    public func mediaSurface(_ player: AppPlayer) -> any BrowserMediaSurface {
        AVKitMediaSurface(player: player)
    }

    public func documentPreview() -> any BrowserDocumentPreview {
        QuickLookDocumentPreview()
    }
}
