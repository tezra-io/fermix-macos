import Foundation
import Testing

@testable import FermixAppCore

@Suite("ProductConfiguration")
struct ProductConfigurationTests {
    @Test("the shipped configuration is readable from the application bundle")
    func shippedConfigurationIsReadable() throws {
        let configuration = try ProductConfiguration.bundled()

        #expect(configuration.schemaVersion == ProductConfiguration.supportedSchemaVersion)
        #expect(configuration.productName == "Fermix")
        #expect(configuration.bundleIdentifier == "io.tezra.FermixPet")
        #expect(configuration.guiExecutableName == "Fermix")
        #expect(configuration.agentExecutableName == "FermixAgent")
        #expect(configuration.agentServiceLabel == "io.tezra.FermixPet.agent")
        #expect(configuration.supportDirectoryName == "Fermix")
        #expect(configuration.minimumSystemVersion == "15.0")
        #expect(configuration.supportedArchitectures == ["arm64", "x86_64"])
    }

    /// The two identity values this library reads as constants, because the
    /// places that need them have nothing to hand an error back to. Both are
    /// the configuration's, so a bundle staged under the development overlay
    /// keeps its record in its own folder and parses its own url scheme
    /// instead of the installed app's.
    @Test("the identity read as a constant is the configured identity")
    func identityConstantsComeFromTheConfiguration() throws {
        let configuration = try ProductConfiguration.bundled()

        #expect(BootstrapLocation.directoryName == configuration.supportDirectoryName)
        #expect(AppRoute.scheme == configuration.urlScheme)
    }

    /// The support folder is a folder name, not a path: the record would
    /// otherwise land somewhere no other copy of this app looks.
    @Test("the support folder is one path component")
    func supportDirectoryIsOnePathComponent() throws {
        let name = try ProductConfiguration.bundled().supportDirectoryName

        #expect(!name.contains("/"))
        #expect(name != "." && name != "..")
    }

    /// The SwiftPM resource bundle name is derived from the package and target
    /// names, and four shell scripts copy and sign that directory by name. If
    /// either name changes, this is where it surfaces.
    @Test("the declared SwiftPM resource bundle is the one the build produces")
    func declaredResourceBundleMatchesTheBuild() throws {
        let configuration = try ProductConfiguration.bundled()
        let produced = Bundle.module.bundleURL.lastPathComponent

        #expect(configuration.swiftResourceBundleName == produced)
    }

    @Test("product copy carries no superseded product name")
    func microphoneCopyUsesTheProductName() throws {
        let configuration = try ProductConfiguration.bundled()

        #expect(configuration.microphoneUsageDescription.contains("Fermix "))
        #expect(!configuration.microphoneUsageDescription.contains("FermixPet"))
    }

    @Test("an unsupported schema version is refused")
    func unsupportedSchemaVersionIsRefused() {
        #expect(throws: ProductConfigurationError.unsupportedSchemaVersion(2)) {
            _ = try ProductConfiguration.decode(from: ProductFixture.json(schemaVersion: 2))
        }
    }

    @Test("an empty required field is refused by name")
    func emptyRequiredFieldIsRefused() {
        #expect(throws: ProductConfigurationError.emptyField("product_name")) {
            _ = try ProductConfiguration.decode(from: ProductFixture.json(productName: ""))
        }
    }

    @Test("an empty architecture list is refused")
    func emptyArchitectureListIsRefused() {
        #expect(throws: ProductConfigurationError.emptyField("supported_architectures")) {
            _ = try ProductConfiguration.decode(from: ProductFixture.json(architectures: []))
        }
    }

    @Test("an empty document is refused")
    func emptyDocumentIsRefused() {
        #expect(throws: ProductConfigurationError.empty) {
            _ = try ProductConfiguration.decode(from: Data())
        }
    }

    /// The build number is the app's release identity to Sparkle: a feed
    /// compares `CFBundleVersion` numerically, so a value that is not a
    /// positive integer makes every published update either invisible or
    /// permanently newer than itself. It is checked in rather than derived
    /// from the marketing version, and this is where a mistyped one is caught
    /// on the way into the app.
    @Test("the shipped build number is a positive integer")
    func shippedBuildNumberIsAPositiveInteger() throws {
        let configuration = try ProductConfiguration.bundled()

        let value = try #require(Int(configuration.buildNumber))
        #expect(value > 0)
        #expect(String(value) == configuration.buildNumber)
    }

    @Test(
        "a build number that is not a positive integer is refused",
        arguments: ["0", "-3", "1.2", "0x10", " 7", "7 ", "01", "one"]
    )
    func nonPositiveIntegerBuildNumberIsRefused(value: String) {
        #expect(throws: ProductConfigurationError.notAPositiveInteger("build_number")) {
            _ = try ProductConfiguration.decode(from: ProductFixture.json(buildNumber: value))
        }
    }
}
