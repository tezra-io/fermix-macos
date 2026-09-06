import AppKit
import Foundation
import Testing

@testable import FermixAppCore

/// The mark table against its own record.
///
/// `Resources/VendorMarks/PROVENANCE.json` is the authority for what may be
/// drawn and how: it is what the offline gate checks bytes against, and it is
/// what an owner reads to answer whether a vendor's mark is being used the way
/// that vendor allows. `VendorMarks.all` is what the app actually draws. Two
/// records that can disagree is exactly how a mark ends up shipped under one
/// vendor's terms and drawn under another's, so this reads the JSON and proves
/// they say the same thing about every key, treatment, plate and file.
@Suite("Vendor marks")
struct VendorMarkTests {
    /// The checked-in provenance record, read from the source tree.
    static func record() throws -> [String: Any] {
        let url = SourceTree.root
            .appendingPathComponent("Resources/VendorMarks/PROVENANCE.json")
        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data)

        return try #require(object as? [String: Any])
    }

    static func marks() throws -> [[String: Any]] {
        try #require(try record()["marks"] as? [[String: Any]])
    }

    @Test("every recorded mark is in the table, and the table invents none")
    func rosterAgrees() throws {
        let recorded = try Self.marks().map { mark in
            "\(mark["kind"] as? String ?? "?"):\(mark["key"] as? String ?? "?")"
        }
        let drawn = VendorMarks.all.map { "\($0.kind.rawValue):\($0.key)" }

        #expect(Set(recorded) == Set(drawn), "recorded \(recorded.sorted()) drawn \(drawn.sorted())")
        #expect(drawn.count == Set(drawn).count, "a key is in the table twice")
    }

    @Test("the treatment and the plate of every mark are the recorded ones")
    func treatmentsAgree() throws {
        for entry in try Self.marks() {
            let kindName = try #require(entry["kind"] as? String)
            let kind = try #require(VendorMark.Kind(rawValue: kindName))
            let key = try #require(entry["key"] as? String)
            let mark = try #require(VendorMarks.mark(kind, key), "\(kindName):\(key) is not in the table")
            let treatment = try #require(entry["treatment"] as? String)

            if treatment == "vendor_text_with_symbol" {
                #expect(mark.treatment == .textWithSymbol, "\(key) ships no file")
                continue
            }

            #expect(mark.treatment != .textWithSymbol, "\(key) records a file and must draw one")
            let plate = try #require(entry["plate"] as? String)
            #expect(mark.plate == VendorMark.Plate(rawValue: plate), "\(key) plate")
        }
    }

    /// The files the table names are the files the record pins, by path. A
    /// table pointing at a name nobody recorded would draw a mark with no
    /// provenance at all, which is the one thing section 7 forbids outright.
    @Test("every file the table draws is a file the record pins")
    func assetPathsAgree() throws {
        for entry in try Self.marks() {
            let kindName = try #require(entry["kind"] as? String)
            let kind = try #require(VendorMark.Kind(rawValue: kindName))
            let key = try #require(entry["key"] as? String)
            let mark = try #require(VendorMarks.mark(kind, key))
            let recorded = Set(
                (entry["assets"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String }
            )
            let drawn = Set([mark.asset(dark: false), mark.asset(dark: true)]
                .compactMap { $0?.recordedPath })

            #expect(drawn.isSubset(of: recorded), "\(key) draws \(drawn) but the record pins \(recorded)")
            if !recorded.isEmpty {
                #expect(!drawn.isEmpty, "\(key) ships files and draws none")
            }
        }
    }

    /// A record and a table that agree about a file that is not in the bundle
    /// still draws nothing. Loading is the half neither JSON nor Swift can
    /// prove on its own.
    @Test("every mark the table draws loads out of the resource bundle")
    @MainActor
    func everyMarkLoads() throws {
        for mark in VendorMarks.all {
            for dark in [false, true] {
                guard let asset = mark.asset(dark: dark) else { continue }

                let image = VendorMarkLoader.image(asset)
                #expect(image != nil, "\(mark.kind):\(mark.key) \(asset.recordedPath) did not load")
                #expect(image?.size.width ?? 0 > 0, "\(asset.recordedPath) has no size")
                #expect(image?.tiffRepresentation?.isEmpty == false, "\(asset.recordedPath) cannot render")
            }
        }
    }

    @Test("vendor SVGs contain no HTML drawing that AppKit silently omits")
    func svgUsesImagePrimitives() throws {
        for mark in VendorMarks.all {
            for dark in [false, true] {
                guard let asset = mark.asset(dark: dark), asset.fileExtension == "svg" else { continue }
                let url = SourceTree.root.appendingPathComponent("Resources/VendorMarks/\(asset.recordedPath)")
                let text = try String(contentsOf: url, encoding: .utf8)
                #expect(!text.contains("<foreignObject"), "\(asset.recordedPath) needs a vendor-supplied raster")
            }
        }
    }

    @Test("OpenAI, Codex and xAI rows draw official assets")
    func browserProviderMarks() throws {
        for key in ["openai", "openai_codex", "xai"] {
            let mark = try #require(VendorMarks.mark(.provider, key))
            #expect(mark.asset(dark: false) != nil, "\(key) has no official mark")
            #expect(mark.asset(dark: true) != nil, "\(key) has no dark appearance mark")
        }
    }

    @Test("Google sign-in client has its own recorded identity")
    func googleClientMark() {
        #expect(VendorMarks.all.contains { $0.kind.rawValue == "oauth_client" && $0.key == "google" })
        #expect(VendorMarks.oauthClient("google")?.kind == .oauthClient)
        #expect(VendorMarks.integration("google") == nil, "a shared Google client is not a plugin")
    }

    @Test("every reported sign-in client resolves a recorded mark")
    func everyReportedClientHasAMark() throws {
        let catalog: ManagementPluginCatalog = try FakeDaemonGateway.fixtureResult(
            named: "plugins_list", as: ManagementPluginCatalog.self
        )
        for client in catalog.oauthClients {
            #expect(VendorMarks.oauthClient(client.provider)?.asset(dark: false) != nil)
        }
        for key in ["github", "notion", "x", "slack"] {
            #expect(VendorMarks.oauthClient(key) == VendorMarks.mark(.plugin, key))
        }
        #expect(VendorMarks.oauthClient("unknown") == nil)
    }

    /// Every plugin the daemon itself reports has a mark, derived from the
    /// daemon's own answer rather than from a list kept by hand here.
    ///
    /// This is the defect the hand-kept list could not see. The roster was
    /// written against `priv/plugins/index.json`, the catalog a machine
    /// installs FROM; `Registry.list` also unions in `priv/plugins/catalog.json`,
    /// the three plugins the engine ships INSIDE itself, so google_calendar,
    /// gmail and google_drive are installed on a machine that added nothing and
    /// every one of them drew the puzzle-piece tile under the default Installed
    /// pill. Reading the contract fixture is what makes the case set the
    /// daemon's rather than this file's.
    @Test("every plugin the daemon reports draws a recorded mark")
    func everyReportedPluginHasAMark() throws {
        let catalog: ManagementPluginCatalog = try FakeDaemonGateway.fixtureResult(
            named: "plugins_list",
            as: ManagementPluginCatalog.self
        )

        #expect(!catalog.plugins.isEmpty, "the fixture publishes no plugins to check")
        for plugin in catalog.plugins {
            #expect(
                VendorMarks.integration(plugin.name) != nil,
                "\(plugin.name) has no mark and would draw the generic tile"
            )
        }
    }

    /// Every feature row the Integrations page can draw has one too, so a
    /// driver added later either joins the record or fails here.
    @Test("every native driver feature draws a recorded mark")
    func everyFeatureHasAMark() {
        for feature in IntegrationFeature.rows(nil) {
            #expect(VendorMarks.integration(feature.id) != nil, "\(feature.id) has no mark")
        }
    }

    /// A mark's bytes are the format its name claims.
    ///
    /// `whatsapp-color.png` shipped WebP bytes under a PNG name for a day: the
    /// sha256 matched, the record was false, and ImageIO decoded it anyway, so
    /// nothing on either side of the pipeline noticed. The offline gate now
    /// checks this too; it is asserted here as well because the gate runs on a
    /// tree and this runs on what the bundle actually ships.
    @Test("every mark the table draws is the format its name claims")
    @MainActor
    func assetFormatsAreTrue() throws {
        let magic: [String: [(bytes: [UInt8], offset: Int?)]] = [
            "png": [([0x89, 0x50, 0x4E, 0x47], 0)],
            "webp": [([0x52, 0x49, 0x46, 0x46], 0), ([0x57, 0x45, 0x42, 0x50], 8)],
            "svg": [(Array("<svg".utf8), nil), (Array("<?xml".utf8), 0)]
        ]

        for mark in VendorMarks.all {
            for dark in [false, true] {
                guard let asset = mark.asset(dark: dark) else { continue }

                let url = try #require(
                    Bundle.module.url(
                        forResource: asset.name,
                        withExtension: asset.fileExtension,
                        subdirectory: "VendorMarks/\(asset.directory)"
                    ),
                    "\(asset.recordedPath) is not in the bundle"
                )
                let head = Array(try Data(contentsOf: url).prefix(512))
                let signatures = try #require(
                    magic[asset.fileExtension],
                    "\(asset.recordedPath) has an extension no mark format uses"
                )
                let matched = signatures.contains { signature in
                    guard let offset = signature.offset else {
                        return head.indices.contains { start in
                            start + signature.bytes.count <= head.count
                                && Array(head[start..<start + signature.bytes.count]) == signature.bytes
                        }
                    }

                    return head.count >= offset + signature.bytes.count
                        && Array(head[offset..<offset + signature.bytes.count]) == signature.bytes
                }

                #expect(matched, "\(asset.recordedPath) is not \(asset.fileExtension)")
            }
        }
    }

    /// There are two plates, and a mark with a single dark ink is not given a
    /// third one.
    ///
    /// A light plate under GitHub's and Notion's dark glyphs shipped on
    /// 2026-09-03 and failed both ways: `markPlate` was `#f6f7f9`, which is the
    /// light appearance's own `base100`, so on light the plate was invisible
    /// and the glyphs floated bare, and on dark the two squares were the
    /// brightest objects on the page. GitHub publishes both inks, and Notion's
    /// mark already carries its own white page.
    @Test("there is no plate that paints a light ground under a dark ink")
    func noLightPlate() throws {
        #expect(VendorMark.Plate.allCases.map(\.rawValue).sorted() == ["bleed", "neutral"])

        let github = try #require(VendorMarks.mark(.plugin, "github"))
        #expect(github.asset(dark: false)?.name == "github-black")
        #expect(github.asset(dark: true)?.name == "github-white")
        #expect(github.plate == .neutral)

        #expect(VendorMarks.mark(.plugin, "notion")?.plate == .neutral)

        let palette = try #require(
            try SourceTree.swiftFiles(matching: "Design/Tokens/Palette.swift").first?.text
        )
        #expect(!palette.contains("markPlate"), "the light plate's token outlived the plate")
    }

    /// A mark whose file carries its own ground fills the tile; one drawn on
    /// transparency is inset on the app's own. Telegram's roundel is the case
    /// that separates them: inset, it drew an 11-point blue disc inside a
    /// 20-point grey one.
    @Test("a mark that carries its own ground bleeds rather than being inset")
    func groundedMarksBleed() throws {
        #expect(VendorMarks.mark(.channel, "telegram")?.plate == .bleed)
        #expect(VendorMarks.mark(.channel, "whatsapp")?.plate == .bleed)
        for key in ["gmail", "google_calendar", "google_drive"] {
            #expect(VendorMarks.mark(.plugin, key)?.plate == .bleed, "\(key)")
        }
    }

    /// One neutral symbol per kind, so a fallback carries no invented vendor
    /// identity. The strings are the record's own.
    @Test("the neutral symbols are the record's, one per kind")
    func neutralSymbols() {
        #expect(VendorMark.Kind.provider.neutralSymbol == "cpu")
        #expect(VendorMark.Kind.channel.neutralSymbol == "bubble.left.and.bubble.right")
        #expect(VendorMark.Kind.plugin.neutralSymbol == "puzzlepiece.extension")
        #expect(VendorMark.Kind.feature.neutralSymbol == "puzzlepiece.extension")
    }

    /// The Integrations page draws plugins and the three native driver features
    /// in one list and a row carries only its name, so the lookup reads both
    /// rosters. A name in neither has no logo, which is the neutral symbol.
    @Test("an integration row resolves against plugins and then features")
    func integrationLookup() {
        #expect(VendorMarks.integration("github")?.kind == .plugin)
        #expect(VendorMarks.integration("meetings")?.kind == .feature)
        #expect(VendorMarks.integration("computer_use")?.kind == .feature)
        // The catalog entry with no logo of its own takes Fermix's own mark.
        #expect(VendorMarks.integration("computer_use_sidecar")?.kind == .plugin)
        #expect(VendorMarks.integration("nothing_ships_this") == nil)
    }

    /// Discord and Slack are each both a channel and a plugin, with different
    /// art: the channel ships the vendor's own kit and the plugin ships the
    /// catalog's logo. A lookup that ignored the kind would draw one for the
    /// other, which is why identity is the pair.
    @Test("a vendor that is both a channel and a plugin keeps two marks")
    func kindIsPartOfIdentity() throws {
        for key in ["discord", "slack"] {
            let channel = try #require(VendorMarks.mark(.channel, key))
            let plugin = try #require(VendorMarks.mark(.plugin, key))

            #expect(channel.asset(dark: false) != plugin.asset(dark: false), "\(key)")
        }
    }

    /// The one mark with two published inks draws the vendor's own choice per
    /// appearance rather than one file tinted, because recolouring is what
    /// OpenRouter's brand page asks callers not to do.
    @Test("a mark with two published inks resolves by appearance")
    func appearancePair() throws {
        let mark = try #require(VendorMarks.mark(.provider, "openrouter"))

        #expect(mark.asset(dark: false)?.name == "openrouter-grape")
        #expect(mark.asset(dark: true)?.name == "openrouter-volt")
    }

    /// Marks are decorative wherever they are drawn: the row around one carries
    /// the name, so nothing is spoken twice. Nothing in the shipping sources
    /// may read copy off a mark.
    @Test("a mark carries no copy of its own")
    func marksCarryNoCopy() throws {
        let deck = ProductStringKey.allCases.map(\.rawValue)

        let leftovers = deck.filter { $0.hasPrefix("vendor.") }

        #expect(leftovers.isEmpty, "\(leftovers)")
    }
}
