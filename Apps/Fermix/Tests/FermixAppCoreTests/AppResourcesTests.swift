import Foundation
import Testing

@testable import FermixAppCore

@Suite("Packaged app resources")
struct AppResourcesTests {
    @Test("an app loads the resource bundle named by its own Info.plist")
    func packagedResources() throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let app = try application(in: temporary.url, name: "Owned.bundle", resourcePresent: true)

        let resources = try AppResources.resolve(mainBundleURL: app) {
            Issue.record("a packaged app must not read the SwiftPM build directory")
            return Bundle.module
        }

        #expect(resources.bundleURL.path == app.appendingPathComponent("Contents/Resources/Owned.bundle").path)
        let marker = try #require(resources.url(forResource: "identity", withExtension: "txt"))
        #expect(try String(contentsOf: marker, encoding: .utf8) == "packaged")
    }

    @Test("the packaged agent resolves the enclosing app's resources")
    func packagedAgentResources() throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let app = try application(in: temporary.url, name: "Owned.bundle", resourcePresent: true)
        let executableDirectory = app.appendingPathComponent("Contents/MacOS")
        let resources = try AppResources.resolve(mainBundleURL: executableDirectory) { Bundle.module }

        #expect(resources.bundleURL.path == app.appendingPathComponent("Contents/Resources/Owned.bundle").path)
    }

    @Test("missing packaged resources fail even when the build directory exists")
    func missingResources() throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let app = try application(in: temporary.url, name: "Missing.bundle", resourcePresent: false)

        #expect(throws: AppResourceError.missingResourceBundle("Missing.bundle")) {
            try AppResources.resolve(mainBundleURL: app) { Bundle.module }
        }
    }

    @Test("a missing or escaping resource name is refused")
    func invalidResourceName() throws {
        for name in [nil, "../Elsewhere.bundle"] as [String?] {
            let temporary = try TemporaryDirectory()
            defer { temporary.remove() }
            let app = try application(in: temporary.url, name: name, resourcePresent: false)

            #expect(throws: AppResourceError.missingBundleName) {
                try AppResources.resolve(mainBundleURL: app) { Bundle.module }
            }
        }
    }

    @Test("an unbundled SwiftPM executable uses its module resource bundle")
    func unbundledResources() throws {
        let resources = try AppResources.resolve(mainBundleURL: Bundle.module.bundleURL) { Bundle.module }
        #expect(resources.bundleURL == Bundle.module.bundleURL)
    }

    @Test("a SwiftPM helper inside Xcode uses the module bundle")
    func toolchainResources() throws {
        let helper = URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer/Toolchains/usr/bin")
        let resources = try AppResources.resolve(mainBundleURL: helper) { Bundle.module }
        #expect(resources.bundleURL == Bundle.module.bundleURL)
    }

    private func application(in directory: URL, name: String?, resourcePresent: Bool) throws -> URL {
        let app = directory.appendingPathComponent("Example.app")
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        var info = ["CFBundleIdentifier": "test.resources.\(UUID().uuidString)", "CFBundlePackageType": "APPL"]
        info["FermixResourceBundleName"] = name
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        guard resourcePresent, let name else { return app }

        let resources = contents.appendingPathComponent("Resources/\(name)")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try Data("packaged".utf8).write(to: resources.appendingPathComponent("identity.txt"))
        return app
    }
}
