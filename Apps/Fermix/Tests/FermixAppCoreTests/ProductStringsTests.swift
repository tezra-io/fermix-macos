import Foundation
import Testing

@testable import FermixAppCore

/// The copy gate.
///
/// The case set is derived from `ProductStringKey.allCases` and from the
/// shipped `Localizable.strings` itself, in both directions: a key added to
/// the enum without copy fails, and a line added to the catalogue without a
/// key fails. A hand-listed set of screens would rot the first time a screen
/// was added.
@Suite("Product strings")
struct ProductStringsTests {
    @Test("every declared key resolves to shipped copy")
    func everyKeyResolves() {
        for key in ProductStringKey.allCases {
            let value = ProductStrings[key]

            #expect(!value.isEmpty, "\(key.rawValue) is empty")
            #expect(value != key.rawValue, "\(key.rawValue) is missing from Localizable.strings")
        }
    }

    @Test("the shipped catalogue carries no key the app cannot reach")
    func catalogueHasNoOrphans() throws {
        let catalogue = try ProductStringsFixture.shippedCatalogue()
        let declared = Set(ProductStringKey.allCases.map(\.rawValue))
        let orphans = Set(catalogue.keys).subtracting(declared)

        #expect(orphans.isEmpty, "orphan keys: \(orphans.sorted())")
        #expect(catalogue.count == declared.count)
    }

    @Test("the catalogue is the only place product copy is written")
    func catalogueMatchesTheAccessor() throws {
        let catalogue = try ProductStringsFixture.shippedCatalogue()

        for key in ProductStringKey.allCases {
            #expect(ProductStrings[key] == catalogue[key.rawValue], "\(key.rawValue)")
        }
    }

    /// The separators are copy too, so a screen never writes an interpunct or
    /// a comma into a Swift literal.
    @Test("the shared separators compose two facts")
    func separators() {
        #expect(ProductStrings.middot("Running", "3 days") == "Running · 3 days")
        #expect(ProductStrings.commaPair("Telegram", "connected") == "Telegram, connected")
    }

    // MARK: - Copy rules

    @Test("no product string uses an em dash")
    func noEmDashes() {
        for key in ProductStringKey.allCases {
            #expect(!ProductStrings[key].contains("\u{2014}"), "\(key.rawValue)")
        }
    }

    @Test("no product string uses an exclamation mark")
    func noExclamationMarks() {
        for key in ProductStringKey.allCases {
            #expect(!ProductStrings[key].contains("!"), "\(key.rawValue)")
        }
    }

    @Test("no product string says please wait")
    func noPleaseWait() {
        for key in ProductStringKey.allCases {
            #expect(!ProductStrings[key].lowercased().contains("please wait"), "\(key.rawValue)")
        }
    }

    @Test("no product string carries the superseded FermixPet name")
    func noSupersededProductName() {
        for key in ProductStringKey.allCases {
            #expect(!ProductStrings[key].contains("FermixPet"), "\(key.rawValue)")
        }
    }

    @Test("no product string carries placeholder copy")
    func noPlaceholders() {
        for key in ProductStringKey.allCases {
            let value = ProductStrings[key].lowercased()

            for placeholder in ["lorem", "todo", "coming soon", "tbd", "placeholder", "xxx"] {
                #expect(!value.contains(placeholder), "\(key.rawValue) contains \(placeholder)")
            }
        }
    }

    @Test("every product string is sentence case")
    func sentenceCase() {
        for key in ProductStringKey.allCases {
            let offenders = ProductCopyRules.titleCaseOffenders(in: ProductStrings[key])

            #expect(offenders.isEmpty, "\(key.rawValue) capitalises \(offenders)")
        }
    }

    @Test("the rule set reports every violation in one pass")
    func rulesReportEveryViolation() {
        let violations = ProductCopyRules.violations(in: "Install FermixPet Now \u{2014} please wait!")

        #expect(violations.contains(.emDash))
        #expect(violations.contains(.exclamationMark))
        #expect(violations.contains(.pleaseWait))
        #expect(violations.contains(.supersededProductName))
        #expect(violations.contains(.titleCase))
    }

    /// A gate that never fires is not a gate. Each rule is driven with copy
    /// that must trip exactly it.
    @Test("each rule fires on copy that breaks only that rule")
    func rulesAreNotVacuous() {
        #expect(ProductCopyRules.violations(in: "Open Setup").isEmpty)
        #expect(ProductCopyRules.violations(in: "Run Doctor").isEmpty)
        #expect(ProductCopyRules.violations(in: "Restart daemon") == [])
        #expect(ProductCopyRules.violations(in: "Open the Log Folder") == [.titleCase])
        #expect(ProductCopyRules.violations(in: "Starting up \u{2014} nearly there") == [.emDash])
        #expect(ProductCopyRules.violations(in: "Fermix is live now") == [])
    }

    /// Sentence starts are exempt from the title-case rule, otherwise every
    /// second sentence in a two-sentence string would be reported.
    @Test("a word starting a sentence is not title case")
    func sentenceStartsAreExempt() {
        let copy = "Sign in with an account you already have. Sign-in opens in your browser."

        #expect(ProductCopyRules.titleCaseOffenders(in: copy).isEmpty)
    }

    @Test("an all-capitals section label is not title case")
    func sectionLabelsAreExempt() {
        #expect(ProductCopyRules.titleCaseOffenders(in: "LAST LOG LINES").isEmpty)
        #expect(ProductCopyRules.titleCaseOffenders(in: "NETWORK CHECKS").isEmpty)
    }

    /// The proper-noun list is the only hand-maintained part of the rule, so it
    /// is named, reviewable, and asserted.
    @Test("the proper nouns are the product, vendor, and macOS surface names")
    func properNouns() {
        for noun in ["Fermix", "Telegram", "Slack", "Discord", "ChatGPT", "Claude", "Codex", "Terminal", "Setup", "Doctor"] {
            #expect(ProductCopyRules.properNouns.contains(noun), "\(noun)")
        }

        #expect(!ProductCopyRules.properNouns.contains("Folder"))
        #expect(!ProductCopyRules.properNouns.contains("Now"))
    }

    // MARK: - The copy deck

    @Test("the welcome deck matches the redline")
    func welcomeDeck() {
        #expect(ProductStrings[.welcomeValue].hasPrefix("Your Mac's resident AI agent."))
        #expect(ProductStrings[.welcomeCTA] == "Set up Fermix")
        #expect(ProductStrings[.welcomeCaption] == "Takes about two minutes")
    }

    @Test("the activate deck matches the redline")
    func activateDeck() {
        #expect(ProductStrings[.activateHeadlineRegistering] == "Registering the service")
        #expect(ProductStrings[.activateHeadlineStarting] == "Starting the daemon")
        #expect(ProductStrings[.activateHeadlineAlmostReady] == "Almost ready")
        #expect(ProductStrings[.activateCaption] == "First start takes a little longer while Fermix unpacks.")
        #expect(ProductStrings[.activateMirrorChip] == "menu bar mirrors this state")
    }

    @Test("connect AI commits to the browser handoff and never to a password")
    func connectAIDeck() {
        #expect(ProductStrings[.connectAITitle] == "Connect your AI")
        #expect(ProductStrings[.connectAISubcopy].contains("opens in your browser"))
        #expect(ProductStrings[.connectAISubcopy].contains("never sees your password"))
        #expect(ProductStrings[.connectAIKeyRowTitle] == "Use an API key instead")
        #expect(ProductStrings[.connectAIKeyRowHint] == "OpenAI, Anthropic, xAI, OpenRouter, Ollama")
    }

    /// M34 override 1: no mock QR, and the pairing line must be true.
    @Test("the channel pairing line promises Setup rather than a code on screen")
    func connectChannelPairingIsTruthful() {
        let line = ProductStrings[.connectChannelPairing]

        #expect(line == "Pairing opens in Setup")
        #expect(!ProductStrings[.connectChannelPairingHint].lowercased().contains("scan"))
        #expect(ProductStrings[.connectChannelPairingHint].contains("Setup"))
    }

    /// M34 override 2: the CLI row no longer promises a privileged action.
    @Test("the CLI row promises a copied command and not a password prompt")
    func readyCLIRow() {
        #expect(ProductStrings[.readyCLITitle] == "Install the `fermix` command for Terminal")
        #expect(ProductStrings[.readyCLIHint] == "Copies a Terminal command you run once")
        #expect(!ProductStrings[.readyCLIHint].lowercased().contains("password"))
        #expect(ProductStrings[.readyTitle] == "Fermix is live")
        #expect(ProductStrings[.readyPill] == "Daemon running · responds even when this window is closed")
    }

    @Test("every boot failure names what happened, what is untouched, and one action")
    func bootFailureVariants() {
        for cause in BootFailureCause.allCases {
            let sentence = ProductStrings.bootFailure(cause)

            #expect(!sentence.isEmpty, "\(cause)")
            #expect(sentence.contains("hasn't been touched"), "\(cause) omits the untouched promise")
            #expect(sentence.hasSuffix("."), "\(cause)")
        }

        #expect(ProductStrings.bootFailure(.timedOut).contains("90 seconds"))
        #expect(ProductStrings.bootFailure(.bindFailure).contains("port"))
        #expect(ProductStrings.bootFailure(.invalidPackage).contains("reinstall"))
    }

    /// The seven M34 causes, the 90-second timeout, and the two preflight
    /// refusals (non-Applications bundle; recognized Homebrew install) are
    /// exactly the states Activate can end in.
    @Test("the boot failure causes are the seven M34 states, the timeout, and the two refusals")
    func bootFailureCauseSet() {
        #expect(BootFailureCause.allCases.count == 10)
        #expect(BootFailureCause.allCases.contains(.notInApplications))
        #expect(BootFailureCause.allCases.contains(.legacyInstallPresent))
        #expect(BootFailureCause.allCases.contains(.approvalPending))
        #expect(BootFailureCause.allCases.contains(.backgroundItemDisabled))
        #expect(BootFailureCause.allCases.contains(.incompatibleVersion))
        #expect(BootFailureCause.allCases.contains(.crashLoop))
        #expect(BootFailureCause.allCases.contains(.bindFailure))
        #expect(BootFailureCause.allCases.contains(.webUnavailable))
        #expect(BootFailureCause.allCases.contains(.invalidPackage))
    }

    /// M34 §4 bans Start and Stop for the durable service.
    @Test("the service wording is enable and disable, never start or stop")
    func serviceWording() {
        #expect(ProductStrings[.serviceEnable] == "Enable background service")
        #expect(ProductStrings[.serviceDisable] == "Disable background service")

        // The ban is on the verb, so the test reads the first word rather than
        // searching for a substring: "Restart daemon" contains "start daemon".
        for key in ProductStringKey.allCases {
            let firstWord = ProductStrings[key].split(separator: " ").first.map(String.init) ?? ""

            #expect(firstWord != "Start", "\(key.rawValue)")
            #expect(firstWord != "Stop", "\(key.rawValue)")
        }
    }

    /// The daemon is named once per screen and referred to plainly afterwards,
    /// so no single string may introduce it twice.
    @Test("no single string names the Fermix daemon twice")
    func daemonNamedOnce() {
        for key in ProductStringKey.allCases {
            let occurrences = ProductStrings[key].components(separatedBy: "Fermix daemon").count - 1

            #expect(occurrences <= 1, "\(key.rawValue)")
        }
    }

    @Test("the doctor deck names the daemon as the source of truth")
    func doctorDeck() {
        #expect(ProductStrings[.doctorBannerExplainer].contains("running daemon"))
        #expect(ProductStrings[.doctorNetworkBody].contains("30 seconds"))
        // The support card says what the bundle contains before the operator
        // exports it, and names the daemon as the thing that builds it.
        #expect(ProductStrings[.doctorSupportExportHint].contains("the daemon builds"))
        #expect(ProductStrings[.doctorSupportExport] == "Export support bundle")
        #expect(ProductStrings[.doctorSupportOpenLogFolder] == "Open log folder")
    }

    @Test("the menu bar deck states the quit consequence in line")
    func menuBarDeck() {
        #expect(ProductStrings[.menuQuit] == "Quit Fermix")
        #expect(ProductStrings[.menuQuitHint] == "daemon keeps running")
        #expect(ProductStrings[.menuUpdatesHint] == "Up to date")
    }
}

/// Reads the shipped catalogue straight out of the resource bundle, so the
/// gate runs against the bytes the app ships rather than a copy in the test.
enum ProductStringsFixture {
    static func shippedCatalogue() throws -> [String: String] {
        guard let url = ProductStrings.catalogueURL else {
            throw ProductStringsFixtureError.catalogueMissing
        }

        guard let contents = NSDictionary(contentsOf: url) as? [String: String] else {
            throw ProductStringsFixtureError.catalogueUnreadable
        }

        return contents
    }
}

enum ProductStringsFixtureError: Error {
    case catalogueMissing
    case catalogueUnreadable
}
