// swift-tools-version: 6.0

import PackageDescription

// Product identity, layout, and versions live in
// Sources/FermixAppCore/Resources/Product.json, which Swift and the release
// scripts both read. The manifest deliberately does not read it: SwiftPM
// caches a manifest by its own contents, so editing only Product.json would be
// served a stale platform floor. `scripts/check_product_config.sh` gates the
// one value restated here against that file instead.
let package = Package(
    name: "Fermix",
    // Product copy ships as a real localization, so `Localizable.strings` is
    // resolved through the same bundle machinery a translated build would use
    // rather than through a private catalogue format.
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Fermix", targets: ["Fermix"]),
        .executable(name: "FermixAgent", targets: ["FermixAgent"]),
        .library(name: "FermixAppCore", targets: ["FermixAppCore"])
    ],
    targets: [
        // Everything the product does: views, voice, and the typed product
        // configuration. Both executables are thin mains over this library.
        .target(
            name: "FermixAppCore",
            // The mark master is a generator input, not a runtime resource: the
            // three state rasters sit beside it and shipping both would put two
            // representations of one image in the bundle.
            exclude: ["Resources/MenuBarTemplate/FermixMarkMaster.png"],
            resources: [
                // The vendored wire contracts keep their directory layout: the
                // management and realtime trees each carry a PROTOCOL.md and a
                // protocol.schema.json, and `.process` flattens resources into
                // the bundle root, where those names would collide. `.copy`
                // preserves `Contracts/<protocol>/…` so both survive. The rest
                // is enumerated because one rule per file is the only way to
                // mix `.copy` and `.process` under a shared parent directory.
                .copy("Resources/Contracts"),
                // Vendor marks keep their providers/ and channels/ split and
                // their PROVENANCE.json sibling, so the record travels with
                // the files it describes. `.copy` for the same reason as the
                // contracts: `.process` would flatten both directories into
                // the bundle root.
                .copy("Resources/VendorMarks"),
                .process("Resources/AppIcon"),
                // The templates are processed, not copied: `.process` is what
                // pairs each state's raster with its @2x sibling for NSImage,
                // and the trailing "Template" in the name is what makes macOS
                // tint it for the current menu bar appearance.
                .process("Resources/MenuBarTemplate"),
                .process("Resources/PetExpressions"),
                .process("Resources/FermixPet.icns"),
                .process("Resources/Product.json"),
                // The canonical wordmark SVG. `FermixWordmark` draws a 1:1
                // path port of it rather than loading it (NSImage cannot tint
                // a currentColor SVG); the file ships as the reference asset
                // the port is reviewed against.
                .copy("Resources/Wordmark"),
                // The whole copy deck. `.process` on the `.lproj` is what puts
                // it where `Bundle.module.localizedString` looks.
                .process("Resources/en.lproj")
            ]
        ),
        // The GUI. Its Info.plist is linked into __TEXT,__info_plist so a plain
        // `swift build` yields a binary carrying the product's real identity;
        // that plist is generated from Product.json, never hand-written.
        .executableTarget(
            name: "Fermix",
            dependencies: ["FermixAppCore"],
            exclude: ["Info.plist", "Fermix.entitlements"],
            linkerSettings: [
                .unsafeFlags(
                    [
                        "-Xlinker", "-sectcreate",
                        "-Xlinker", "__TEXT",
                        "-Xlinker", "__info_plist",
                        "-Xlinker", "Sources/Fermix/Info.plist"
                    ],
                    .when(platforms: [.macOS])
                )
            ]
        ),
        // The daemon launcher that SMAppService.agent registers.
        .executableTarget(
            name: "FermixAgent",
            dependencies: ["FermixAppCore"]
        ),
        .testTarget(
            name: "FermixAppCoreTests",
            dependencies: ["FermixAppCore"],
            // The web-setup coverage table, its claims and its exemptions are
            // test *inputs*, read off disk beside the test that reads them,
            // exactly as the source-scan gates read the tree. They must never
            // ship inside a bundle, so they are excluded rather than declared
            // as resources.
            // The cross-repo golden the migration handoff is pinned against is
            // a test input too: it is the engine's own record, read off disk
            // beside the test that replays it.
            exclude: ["WebSetup", "Fixtures"]
        )
    ],
    swiftLanguageModes: [.v5]
)
