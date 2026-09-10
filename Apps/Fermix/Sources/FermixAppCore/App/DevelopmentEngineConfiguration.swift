#if DEBUG
import Foundation

/// The staged development bundle uses the production background lifecycle on
/// its isolated home and port. Only installed-copy preflights are skipped.
extension AppEnvironment {
    static func developmentEngine(updater: any UpdaterDriving) -> AppEnvironment {
        do {
            try DevelopmentEngineRegistration.validate(
                location: BootstrapLocation.currentAccount(),
                bundleURL: Bundle.main.bundleURL,
                product: ProductConfiguration.bundled()
            )
        } catch {
            preconditionFailure("invalid development bundle: \(error)")
        }
        return onThisMac(activation: .developmentBackgroundService, updater: updater)
    }
}

enum DevelopmentEngineRegistration {
    enum Refusal: Error, Equatable {
        case developmentHomeRequired
        case developmentPortRequired
    }

    /// Validate before registering or exposing the service switches. The dev
    /// flag alone must never launch an agent on the production port or home.
    static func validate(
        location: BootstrapLocation,
        bundleURL: URL,
        product: ProductConfiguration
    ) throws {
        let home = try BootstrapStore(location: location).load().fermixHome
        let expected = location.homeDirectory.appendingPathComponent(".fermix-macos", isDirectory: true)
        guard home.standardizedFileURL == expected.standardizedFileURL else {
            throw Refusal.developmentHomeRequired
        }

        let plist = bundleURL.appendingPathComponent(
            "Contents/Library/LaunchAgents/\(product.agentServiceLabel).plist"
        )
        let data = try Data(contentsOf: plist)
        let contents = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        let variables = contents?["EnvironmentVariables"] as? [String: String]
        guard variables?["PORT"] == "4530" else { throw Refusal.developmentPortRequired }
    }


}
#endif
