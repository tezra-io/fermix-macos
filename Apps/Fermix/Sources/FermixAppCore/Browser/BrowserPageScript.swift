import Foundation

/// The page script the browser target runs in its own content world
/// (`Resources/Browser/ax_snapshot.js`).
///
/// It ships in the app's one resource bundle, as the mascot's animation does,
/// because that bundle is the one the staging, signing and verification
/// scripts carry; the browser target reads it from here.
public enum BrowserPageScript {
    public static let resourceName = "ax_snapshot"
    public static let resourceExtension = "js"

    /// The global the script installs itself as, once per document.
    public static let global = "__fermixPage"

    /// The script's text.
    public static func source() throws -> String {
        guard let url = AppResources.bundle.url(forResource: resourceName, withExtension: resourceExtension) else {
            throw BrowserPageDriveError.script("the page script is missing from the app's resources")
        }

        return try String(contentsOf: url, encoding: .utf8)
    }
}
