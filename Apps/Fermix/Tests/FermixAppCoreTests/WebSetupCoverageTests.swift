import Foundation
import Testing

@testable import FermixAppCore

/// Coverage of the browser door is a gate, not a claim (M34 §5, decision D5;
/// owner directive of 2026-09-03: "make sure all the options in the original
/// setup web is available in the macos app").
///
/// The unit is the web setup's own surface, field by field: 144 rows derived
/// from the engine's Setup LiveView — 75 fields, 41 actions and 28 sub-surfaces
/// across its twelve tabs — checked in beside this file. Every row is claimed by
/// a symbol this tree declares *in the file the claim names*, or carries an
/// explicit exemption with its reason. The test fails on an unclaimed row, on an
/// exemption with no reason, and on a claim whose named file does not declare
/// the symbol, so a surface nobody built cannot pass as covered — and neither
/// can one satisfied by a same-named declaration borrowed from elsewhere.
///
/// A claim may also name the golden fixture section and row key it renders, and
/// then both halves are proven: the surface exists in Swift, and the daemon data
/// it draws exists in the contract. A pane whose section the contract does not
/// publish renders empty, which is exactly the failure a symbol-only claim would
/// let through.
@Suite("Web setup coverage")
struct WebSetupCoverageTests {

    // MARK: - The table

    /// One row of the web setup's surface.
    struct Row: Decodable, Hashable {
        let tab: String
        let kind: String
        let name: String

        var identity: String { "\(tab)/\(kind)/\(name)" }
    }

    struct Claim: Decodable {
        let tab: String
        let kind: String
        let name: String
        /// The symbols that answer this row, each written `<file>#<symbol>` so
        /// the claim names a *place* and not just a name. A bare name would be
        /// satisfied by any declaration anywhere in the tree, which is how a
        /// claim on a type that has no such case passed as coverage.
        let symbols: [String]
        /// The golden fixture section this claim renders, where it renders one.
        let section: String?
        /// The row inside that section, where the claim names one.
        let rowKey: String?
        /// Whether the app answers only part of what the web row shows. A
        /// partial claim states the missing half in its note, so the table
        /// cannot read as complete where it is not.
        let partial: Bool?
        let note: String?

        private enum CodingKeys: String, CodingKey {
            case tab, kind, name, symbols, section, partial, note
            case rowKey = "row_key"
        }

        var identity: String { "\(tab)/\(kind)/\(name)" }
    }

    struct Exemption: Decodable {
        let tab: String
        let kind: String
        let name: String
        let reason: String

        var identity: String { "\(tab)/\(kind)/\(name)" }
    }

    // MARK: - Gates

    @Test("the checked-in table is the 144 rows the design publishes")
    func tableIsTheDesignsOwn() throws {
        let rows = try WebSetupCoverage.rows()

        #expect(rows.count == 144)
        #expect(rows.filter { $0.kind == "field" }.count == 75)
        #expect(rows.filter { $0.kind == "action" }.count == 41)
        #expect(rows.filter { $0.kind == "sub_surface" }.count == 28)
        #expect(Set(rows.map(\.tab)).count == 12)
        #expect(Set(rows.map(\.identity)).count == rows.count, "a row is identified once")
    }

    /// Every row is answered exactly once, by a claim or by an exemption. Both
    /// halves matter: an unanswered row is a surface nobody built, and a row
    /// answered twice is a claim and an excuse for the same thing.
    @Test("every row of the web setup is claimed or exempted, exactly once")
    func everyRowIsAnswered() throws {
        let rows = try WebSetupCoverage.rows()
        let claims = try WebSetupCoverage.claims()
        let exemptions = try WebSetupCoverage.exemptions()

        let claimed = Set(claims.map(\.identity))
        let exempt = Set(exemptions.map(\.identity))
        let answered = claimed.union(exempt)
        let published = Set(rows.map(\.identity))

        #expect(published.subtracting(answered).isEmpty, "unanswered: \(published.subtracting(answered).sorted())")
        #expect(answered.subtracting(published).isEmpty, "not in the table: \(answered.subtracting(published).sorted())")
        #expect(claimed.intersection(exempt).isEmpty, "claimed and exempted: \(claimed.intersection(exempt).sorted())")
        #expect(claims.count + exemptions.count == rows.count)
    }

    /// Every symbol a claim names is declared in the file the claim names.
    ///
    /// The file half is what makes this a gate. Against the whole tree joined
    /// together, a claim is satisfied by any `case`, `func` or `var` of that
    /// name anywhere — which is how a Doctor claim on a grant the projection
    /// cannot produce passed as coverage. Bound to a place, a symbol borrowed
    /// from an unrelated type fails.
    @Test("every claimed symbol is declared in the file the claim names")
    func claimedSymbolsExist() throws {
        let files = try SourceTree.swiftFiles(under: "", excluding: false)

        for claim in try WebSetupCoverage.claims() {
            #expect(!claim.symbols.isEmpty, "\(claim.identity) claims nothing")

            for entry in claim.symbols {
                guard let site = WebSetupCoverage.site(of: entry) else {
                    Issue.record("\(claim.identity) claims \(entry), which names no file")
                    continue
                }

                let candidates = files.filter { $0.path.hasSuffix("/" + site.file) }
                #expect(candidates.count == 1, "\(claim.identity) names \(site.file), matched by \(candidates.count) files")

                guard let text = candidates.first?.text else { continue }

                #expect(
                    WebSetupCoverage.declares(site.symbol, in: text),
                    "\(claim.identity) claims \(entry), which that file does not declare"
                )
            }
        }
    }

    /// A claim that answers only part of its web row says which part is
    /// missing. Without this the table reads as complete where it is not: two
    /// Doctor summary panels are one count each in the app and four facts each
    /// in the browser door.
    @Test("every partial claim states what it does not cover")
    func partialClaimsSayWhatIsMissing() throws {
        let partial = try WebSetupCoverage.claims().filter { $0.partial == true }

        #expect(!partial.isEmpty, "the field is read, not skipped")
        for claim in partial {
            #expect(
                (claim.note?.count ?? 0) >= 60,
                "\(claim.identity) is partial with no sentence saying what is not covered"
            )
            #expect(claim.note?.hasPrefix("Partial.") == true, "\(claim.identity) does not open by saying so")
        }
    }

    /// A claim that names daemon data names data the contract publishes. This is
    /// the half a symbol-only claim cannot see: a pane whose section the daemon
    /// never publishes renders an empty form, and its Swift symbol is still
    /// there.
    @Test("every claimed section and row key is published by the vendored contract")
    func claimedFixtureDataExists() throws {
        let inventory = try FakeDaemonGateway.fixtureResult(
            named: "settings_sections",
            as: ManagementSettingsInventory.self
        )
        let published = Set(inventory.sections.map(\.id))

        for claim in try WebSetupCoverage.claims() {
            guard let section = claim.section else { continue }

            #expect(published.contains(section), "\(claim.identity) renders \(section), which is not published")

            let rows = try FakeDaemonGateway.fixtureResult(
                selecting: ["section": section],
                as: ManagementSettingsSectionRows.self
            )
            #expect(rows.id == section)

            guard let key = claim.rowKey else { continue }

            #expect(
                rows.rows.contains { $0.key == key },
                "\(claim.identity) renders \(section)/\(key), which the section does not carry"
            )
        }
    }

    /// An exemption states its reason, and the reason is one of the two kinds
    /// the design allows: a web-only mechanic, or a daemon-side job the app
    /// starts with one button.
    @Test("every exemption carries a reason")
    func exemptionsCarryReasons() throws {
        let exemptions = try WebSetupCoverage.exemptions()

        #expect(!exemptions.isEmpty, "the file is read, not skipped")
        for exemption in exemptions {
            #expect(
                exemption.reason.count >= 40,
                "\(exemption.identity) is exempted with no reason worth reading"
            )
            #expect(
                exemption.reason.hasPrefix("Web-only mechanic.")
                    || exemption.reason.hasPrefix("Daemon-side job."),
                "\(exemption.identity) is exempted for a reason the design does not allow"
            )
        }
    }

    /// The three sub-surfaces the first implementation slices left unbuilt are
    /// rows in the table like any other, and this slice builds them rather than
    /// exempting them (M34 §5).
    @Test("the workspace sheet, the OAuth client sheet and the provider sub-page are built")
    func thePreviouslyUnbuiltSurfacesAreBuilt() throws {
        let files = try SourceTree.swiftFiles(under: "", excluding: false)
        let text = files.map(\.text).joined(separator: "\n")

        for symbol in ["WorkspaceSheet", "OAuthClientSheet", "ProviderDetailSheet"] {
            #expect(WebSetupCoverage.declares(symbol, in: text), "\(symbol) is not declared")
        }

        let exempted = try WebSetupCoverage.exemptions().map(\.identity)
        #expect(!exempted.contains { $0.hasPrefix("plugins/sub_surface/resource_picker_modal") })
        #expect(!exempted.contains { $0.hasPrefix("plugins/sub_surface/oauth_client_modal") })
    }
}

/// Reads the three checked-in files.
///
/// They live beside the test rather than in the resource bundle, resolved from
/// this file's own compile-time path, exactly as the source-scan gates resolve
/// the tree: the table is a test input and must never ship inside the app.
enum WebSetupCoverage {
    enum Defect: Error, Equatable {
        case unreadable(String)
    }

    static var directory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("WebSetup", isDirectory: true)
    }

    static func rows() throws -> [WebSetupCoverageTests.Row] {
        try read("web-setup-coverage.json")
    }

    static func claims() throws -> [WebSetupCoverageTests.Claim] {
        try read("claims.json")
    }

    static func exemptions() throws -> [WebSetupCoverageTests.Exemption] {
        try read("exemptions.json")
    }

    private static func read<Value: Decodable>(_ name: String) throws -> [Value] {
        let url = directory.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else {
            throw Defect.unreadable(url.path)
        }

        return try JSONDecoder().decode([Value].self, from: data)
    }

    /// The file and the symbol a claim entry names, written `<file>#<symbol>`.
    /// An entry in any other shape names no place, and the gate refuses it
    /// rather than falling back to a tree-wide search.
    static func site(of entry: String) -> (file: String, symbol: String)? {
        let halves = entry.components(separatedBy: "#")
        guard halves.count == 2, !halves[0].isEmpty, !halves[1].isEmpty else { return nil }

        return (halves[0], halves[1])
    }

    /// Whether the tree declares this symbol.
    ///
    /// A declaration rather than a mention: a claim satisfied by the symbol
    /// appearing in a comment would be no gate at all. The keywords are the ones
    /// this codebase declares things with, and the boundaries stop `apply` from
    /// matching `applySettings`.
    static func declares(_ symbol: String, in text: String) -> Bool {
        let keywords = ["struct", "enum", "class", "protocol", "extension", "func", "var", "let", "case"]
        let pattern = "(?<![A-Za-z0-9_])(\(keywords.joined(separator: "|")))\\s+\(symbol)(?![A-Za-z0-9_])"
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return false }

        return expression.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text)) > 0
    }
}
