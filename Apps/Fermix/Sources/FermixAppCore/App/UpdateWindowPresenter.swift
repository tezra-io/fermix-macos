import AppKit
import Foundation

/// The update prompt's way onto the screen: the one update window, through
/// the window coordinator that owns every window this app opens.
@MainActor
final class UpdateWindowPresenter: UpdateWindowPresenting {
    private let windows: WindowCoordinator
    private let opener: any ExternalOpening

    init(windows: WindowCoordinator, opener: any ExternalOpening) {
        self.windows = windows
        self.opener = opener
    }

    var isAppActive: Bool { NSApp.isActive }

    /// Opens the window, or raises it where it is already open.
    func showUpdateWindow() {
        windows.show(.update)
    }

    func closeUpdateWindow() {
        windows.close(.update)
    }

    func requestAttention() {
        NSApp.requestUserAttention(.informationalRequest)
    }

    func open(_ url: URL) {
        _ = opener.open(url)
    }
}
