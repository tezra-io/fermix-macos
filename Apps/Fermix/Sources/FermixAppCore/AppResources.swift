import Foundation

/// Packaged apps read only their own resources. SwiftPM's generated accessor
/// otherwise reaches an absolute build-directory path after missing this layout.
enum AppResources {
    static var bundle: Bundle {
        do {
            return try resolve(mainBundleURL: Bundle.main.bundleURL) { Bundle.module }
        } catch {
            fatalError("Fermix could not load its packaged resources: \(error)")
        }
    }

    static func resolve(mainBundleURL: URL, moduleBundle: () -> Bundle) throws -> Bundle {
        guard mainBundleURL.isFileURL else { throw AppResourceError.invalidApplicationBundle }
        let components = mainBundleURL.pathComponents
        guard let end = components.lastIndex(where: { $0.hasSuffix(".app") }) else {
            return moduleBundle()
        }
        let tail = components.dropFirst(end + 1)
        guard tail.isEmpty || tail.starts(with: ["Contents", "MacOS"]) else {
            return moduleBundle()
        }

        let applicationURL = URL(fileURLWithPath: NSString.path(withComponents: Array(components[...end])))
        guard let application = Bundle(url: applicationURL) else {
            throw AppResourceError.invalidApplicationBundle
        }
        guard let name = application.object(forInfoDictionaryKey: "FermixResourceBundleName") as? String,
              !name.isEmpty, !name.contains("/"), name.hasSuffix(".bundle") else {
            throw AppResourceError.missingBundleName
        }
        guard let resources = application.resourceURL,
              let bundle = Bundle(url: resources.appendingPathComponent(name, isDirectory: true)) else {
            throw AppResourceError.missingResourceBundle(name)
        }

        return bundle
    }
}

enum AppResourceError: Error, Equatable {
    case invalidApplicationBundle
    case missingBundleName
    case missingResourceBundle(String)
}
