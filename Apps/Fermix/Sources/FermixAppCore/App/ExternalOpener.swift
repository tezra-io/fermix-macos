import AppKit
import Foundation

/// Handing a url to the system browser, behind a seam.
///
/// Two hops the app makes into a browser, and no others. A provider sign-in,
/// because RFC 8252 requires the external browser and the credential must never
/// cross this process. And the prior installer Recovery offers after an update
/// that did not finish (M34 §6, R4), because this app downloads nothing itself.
public protocol ExternalOpening: Sendable {
    func open(_ url: URL) -> Bool
}

/// The production opener: the user's default browser, through the workspace.
public struct WorkspaceExternalOpener: ExternalOpening {
    public init() {}

    public func open(_ url: URL) -> Bool {
        NSWorkspace.shared.open(url)
    }
}

/// The one directory dialog the app raises, behind a seam (M34 §4).
///
/// Welcome's `Use an existing Fermix home…` is the only place a person picks a
/// path, and the value goes straight to `BootstrapStore`, which validates it.
@MainActor
public struct OpenPanelDirectoryChooser: DirectoryChoosing {
    public init() {}

    public func chooseDirectory(prompt: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = prompt
        panel.message = prompt

        guard panel.runModal() == .OK else { return nil }

        return panel.url
    }
}
