import Foundation

/// The single checked-in product configuration, decoded.
///
/// `Product.json` is the one source of truth for product identity, layout, and
/// versions. Swift reads it through this type; the shell scripts read the same
/// file through `scripts/product_config.sh`. Nothing restates these values.
public struct ProductConfiguration: Decodable, Equatable, Sendable {
    /// The only schema this build understands. A different value is a hard
    /// failure, never a best-effort decode.
    public static let supportedSchemaVersion = 1

    public let schemaVersion: Int
    public let productName: String
    public let bundleIdentifier: String
    /// The url scheme the app registers, and the one `AppRoute` parses.
    public let urlScheme: String
    public let appBundleName: String
    public let guiExecutableName: String
    public let agentExecutableName: String
    public let agentServiceLabel: String
    public let minimumSystemVersion: String
    public let supportedArchitectures: [String]
    public let marketingVersion: String
    public let buildNumber: String
    public let iconFile: String
    public let swiftResourceBundleName: String
    public let engineRelativePath: String
    public let toolsRelativePath: String
    public let microphoneUsageDescription: String

    /// Decode and validate a product configuration document.
    public static func decode(from data: Data) throws -> ProductConfiguration {
        guard !data.isEmpty else { throw ProductConfigurationError.empty }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let configuration = try decoder.decode(ProductConfiguration.self, from: data)
        try configuration.validate()
        return configuration
    }

    /// Read the copy embedded in this module's resource bundle.
    public static func bundled() throws -> ProductConfiguration {
        guard let url = AppResources.bundle.url(forResource: "Product", withExtension: "json") else {
            throw ProductConfigurationError.resourceMissing
        }
        return try decode(from: Data(contentsOf: url))
    }

    private func validate() throws {
        guard schemaVersion == Self.supportedSchemaVersion else {
            throw ProductConfigurationError.unsupportedSchemaVersion(schemaVersion)
        }
        for (name, value) in requiredValues where value.isEmpty {
            throw ProductConfigurationError.emptyField(name)
        }
        guard !supportedArchitectures.isEmpty else {
            throw ProductConfigurationError.emptyField("supported_architectures")
        }
        guard !supportedArchitectures.contains(where: \.isEmpty) else {
            throw ProductConfigurationError.emptyField("supported_architectures")
        }
    }

    private var requiredValues: [(String, String)] {
        [
            ("product_name", productName),
            ("bundle_identifier", bundleIdentifier),
            ("url_scheme", urlScheme),
            ("app_bundle_name", appBundleName),
            ("gui_executable_name", guiExecutableName),
            ("agent_executable_name", agentExecutableName),
            ("agent_service_label", agentServiceLabel),
            ("minimum_system_version", minimumSystemVersion),
            ("marketing_version", marketingVersion),
            ("build_number", buildNumber),
            ("icon_file", iconFile),
            ("swift_resource_bundle_name", swiftResourceBundleName),
            ("engine_relative_path", engineRelativePath),
            ("tools_relative_path", toolsRelativePath),
            ("microphone_usage_description", microphoneUsageDescription)
        ]
    }
}

public enum ProductConfigurationError: Error, Equatable {
    case empty
    case resourceMissing
    case unsupportedSchemaVersion(Int)
    case emptyField(String)

    public var message: String {
        switch self {
        case .empty:
            return "product configuration document is empty"
        case .resourceMissing:
            return "Product.json is missing from the application resource bundle"
        case .unsupportedSchemaVersion(let found):
            return "product configuration schema \(found) is not supported "
                + "(this build reads \(ProductConfiguration.supportedSchemaVersion))"
        case .emptyField(let name):
            return "product configuration field \(name) is empty"
        }
    }
}
