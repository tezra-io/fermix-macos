import Foundation
import Testing

@testable import FermixAppCore

/// Resolving the exactly-one engine tree the agent is allowed to use.
///
/// There is no search path, no download, and no substitution of the other
/// architecture's tree: absence is a hard failure that names the path.
@Suite("Engine resolution")
struct EngineResolutionTests {
    private let bundleRoot = URL(fileURLWithPath: "/Applications/Fermix.app")

    private func configuration() throws -> ProductConfiguration {
        try ProductConfiguration.decode(from: ProductFixture.json())
    }

    private func stagedProbe(architecture: String) -> StubEngineProbe {
        StubEngineProbe(
            directories: [
                "/Applications/Fermix.app/Contents/Resources/Engine/\(architecture)",
                "/Applications/Fermix.app/Contents/Resources/Tools"
            ],
            executables: [
                "/Applications/Fermix.app/Contents/Resources/Engine/\(architecture)/bin/fermix_app_engine"
            ]
        )
    }

    @Test("resolves exactly the tree published for the running architecture")
    func resolvesTheNativeEngineTree() throws {
        let resolver = EngineResolver(
            configuration: try configuration(),
            bundleRoot: bundleRoot,
            architecture: "arm64",
            probe: stagedProbe(architecture: "arm64")
        )

        #expect(
            try resolver.engineTree().path
                == "/Applications/Fermix.app/Contents/Resources/Engine/arm64"
        )
        #expect(
            try resolver.toolsDirectory().path
                == "/Applications/Fermix.app/Contents/Resources/Tools"
        )
        #expect(
            try resolver.engineExecutable().path
                == "/Applications/Fermix.app/Contents/Resources/Engine/arm64/bin/fermix_app_engine"
        )
    }

    /// The launcher must never reach for the other architecture's tree: on an
    /// arm64 host with only an x86_64 tree staged, resolution fails naming the
    /// arm64 path it looked at.
    @Test("never substitutes the other architecture's tree")
    func neverSubstitutesTheOtherArchitecture() throws {
        let resolver = EngineResolver(
            configuration: try configuration(),
            bundleRoot: bundleRoot,
            architecture: "arm64",
            probe: stagedProbe(architecture: "x86_64")
        )

        #expect(
            throws: EngineResolutionError.engineTreeMissing(
                "/Applications/Fermix.app/Contents/Resources/Engine/arm64"
            )
        ) {
            _ = try resolver.engineTree()
        }
    }

    @Test("an unpublished architecture is refused before any disk access")
    func unpublishedArchitectureIsRefused() throws {
        let resolver = EngineResolver(
            configuration: try configuration(),
            bundleRoot: bundleRoot,
            architecture: "riscv64",
            probe: StubEngineProbe(directories: [], executables: [])
        )

        #expect(throws: EngineResolutionError.unsupportedArchitecture("riscv64")) {
            _ = try resolver.engineTree()
        }
    }

    @Test("a missing tools directory is refused by path")
    func missingToolsDirectoryIsRefused() throws {
        let resolver = EngineResolver(
            configuration: try configuration(),
            bundleRoot: bundleRoot,
            architecture: "arm64",
            probe: StubEngineProbe(
                directories: ["/Applications/Fermix.app/Contents/Resources/Engine/arm64"],
                executables: []
            )
        )

        #expect(
            throws: EngineResolutionError.toolsDirectoryMissing(
                "/Applications/Fermix.app/Contents/Resources/Tools"
            )
        ) {
            _ = try resolver.toolsDirectory()
        }
    }

    /// A tree with no engine binary is a broken package, not a runtime
    /// condition to work around.
    @Test("an engine tree without its executable is refused by path")
    func missingExecutableIsRefused() throws {
        let resolver = EngineResolver(
            configuration: try configuration(),
            bundleRoot: bundleRoot,
            architecture: "arm64",
            probe: StubEngineProbe(
                directories: [
                    "/Applications/Fermix.app/Contents/Resources/Engine/arm64",
                    "/Applications/Fermix.app/Contents/Resources/Tools"
                ],
                executables: []
            )
        )

        #expect(
            throws: EngineResolutionError.engineExecutableMissing(
                "/Applications/Fermix.app/Contents/Resources/Engine/arm64/bin/fermix_app_engine"
            )
        ) {
            _ = try resolver.engineExecutable()
        }
    }
}
