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

    /// One dialect, US, in the app's own copy and in the contract the panes
    /// are rendered from. Mixed spellings read as two writers: the catalogue
    /// said `catalogue` while every other word in it was US, and the labels
    /// beside it said `Model behaviour` and `Summarise with`.
    ///
    /// The daemon's own vocabulary is not the app's dialect and is exempt: a
    /// status word the engine publishes (`cancelled`) is rendered as the engine
    /// wrote it, because it is a wire value and not a sentence this app chose.
    @Test("the app catalogue is written in one dialect")
    func oneDialect() {
        let british = [
            "behaviour", "catalogue", "colour", "organis", "summaris", "customis",
            "recognis", "personalis", "optimis", "analys", "licence", "favourite"
        ]

        for key in ProductStringKey.allCases {
            let value = ProductStrings[key].lowercased()

            for spelling in british {
                #expect(!value.contains(spelling), "\(key.rawValue) is written in British English")
            }
        }
    }

    /// macOS writes ID, and the operator is copying a value out of a vendor's
    /// console that writes it that way too.
    @Test("an identifier is spelled ID")
    func identifiersAreCapitalised() {
        for key in ProductStringKey.allCases {
            let words = ProductStrings[key].split { !$0.isLetter && !$0.isNumber }

            #expect(!words.contains("id"), "\(key.rawValue) spells ID in lower case")
            #expect(!words.contains("Id"), "\(key.rawValue) spells ID as a word")
        }
    }

    /// The removed em dashes left comma splices behind them. A colon is what
    /// the Doctor explainer's second half actually is: a definition of the
    /// first, not a second sentence pasted on with a comma.
    @Test("no product string joins two sentences with a comma")
    func noCommaSplices() {
        #expect(
            ProductStrings[.doctorBannerExplainer]
                == "Answers come from the running daemon: what it can actually see, not this window\u{2019}s environment."
        )
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

    /// M34 §14 decision 4 records exactly two exceptions: macOS menu titles and
    /// the section headers of a grouped `Form`. Everything else is sentence
    /// case, and the exception is a catalogue prefix rather than a list, so a
    /// key can only claim it by living in the section that owns it.
    @Test("every product string outside the two recorded sections is sentence case")
    func sentenceCase() {
        for key in ProductStringKey.allCases where !key.usesTitleCase {
            let offenders = ProductCopyRules.titleCaseOffenders(in: ProductStrings[key])

            #expect(offenders.isEmpty, "\(key.rawValue) capitalises \(offenders)")
        }
    }

    /// One scheme per window. Decision 4's section-header exception is
    /// withdrawn: it reached only Home's three headers by key prefix, while ten
    /// Settings headers and every daemon-owned section title were already
    /// sentence case, and mixed is the one outcome M34 §6 names as unacceptable.
    @Test("the one recorded exception is the menu titles")
    func titleCaseSections() {
        #expect(ProductStringKey.titleCasePrefixes == ["menuTitle."])

        let exempt = ProductStringKey.allCases.filter(\.usesTitleCase)
        #expect(!exempt.isEmpty)
        for key in exempt {
            #expect(key.rawValue.hasPrefix("menuTitle."), "\(key.rawValue)")
        }
    }

    /// The gate is by role, not by key prefix: every header a grouped `Form`
    /// draws is sentence case, whichever catalogue section its key lives in and
    /// whether the app or the daemon wrote it.
    ///
    /// Both spellings of a header count. A section that carries a footer cannot
    /// use `Section(title) { }` at all — SwiftUI has no such overload — so it
    /// writes its title inside a `header:` label, and a scan that saw only the
    /// first spelling would stop covering a section the moment it grew a
    /// footer.
    @Test("every section header a form draws is sentence case")
    func sectionHeadersAreSentenceCase() throws {
        let headers = try SourceTree.swiftFiles(under: "", excluding: false)
            .flatMap { file in Self.sectionHeaderKeys(in: file.text) }

        #expect(!headers.isEmpty, "the scan found no section headers at all")
        // The Providers pane's Primary section is written in the `header:`
        // spelling, so its presence proves the scan covers both.
        #expect(headers.contains("settingsPrimarySection"), "the scan missed a header: label")
        for name in Set(headers) {
            guard let key = ProductStringKey.allCases.first(where: { "\($0)" == name }) else { continue }

            #expect(!key.usesTitleCase, "\(key.rawValue) claims the title-case exception")
            #expect(ProductCopyRules.titleCaseOffenders(in: ProductStrings[key]).isEmpty, "\(key.rawValue)")
        }
    }

    /// Every `ProductStringKey` name a file uses as a section header, in both
    /// spellings: `Section(ProductStrings[.key])`, and the `header:` label a
    /// section with a footer has to use instead. The label's `Text` sits on its
    /// own line, so the scan opens on the label and reads the first key inside
    /// it.
    private static func sectionHeaderKeys(in text: String) -> [String] {
        var found: [String] = []
        var insideHeaderLabel = false

        for line in text.split(separator: "\n") {
            if let name = key(in: line, after: "Section(ProductStrings[.") { found.append(name) }

            if insideHeaderLabel, let name = key(in: line, after: "Text(ProductStrings[.") {
                found.append(name)
                insideHeaderLabel = false
            }
            if line.contains("header: {") { insideHeaderLabel = true }
        }

        return found
    }

    private static func key(in line: Substring, after marker: String) -> String? {
        guard let range = line.range(of: marker) else { return nil }
        let name = line[range.upperBound...].prefix { $0.isLetter || $0.isNumber }

        return name.isEmpty ? nil : String(name)
    }

    /// The exception has to be deliberate in both directions: a menu title in
    /// sentence case would read as an accident beside its neighbours.
    @Test("every menu title is really title case")
    func menuTitlesAreTitleCase() {
        let small: Set<String> = ["a", "an", "and", "as", "at", "for", "in", "of", "on", "or", "the", "to"]

        for key in ProductStringKey.allCases where key.rawValue.hasPrefix("menuTitle.") {
            let words = ProductStrings[key].split(separator: " ").map(String.init)

            #expect(!words.isEmpty, "\(key.rawValue)")
            for (index, word) in words.enumerated() {
                guard let first = word.first, first.isLetter else { continue }
                guard index > 0, small.contains(word.lowercased()) == false else { continue }
                // The command's own name is lower case wherever it is written,
                // including inside a menu title: `Add the fermix Command to
                // Terminal…` names a literal, not a word.
                guard word != CLILinkPlanner.commandName else { continue }

                #expect(first.isUppercase, "\(key.rawValue) lowercases \(word)")
            }
            #expect(words[0].first?.isUppercase == true, "\(key.rawValue)")
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
        for noun in ["Fermix", "Telegram", "Slack", "Discord", "ChatGPT", "Claude", "Codex", "Terminal", "Setup", "Doctor", "Realtime"] {
            #expect(ProductCopyRules.properNouns.contains(noun), "\(noun)")
        }

        #expect(!ProductCopyRules.properNouns.contains("Folder"))
        #expect(!ProductCopyRules.properNouns.contains("Now"))
    }

    /// A two-word product name is exempted as a phrase, never as its halves.
    /// Exempting the bare words would let every future string capitalise `Code`
    /// or `Meet` mid-sentence with the gate silent, which is how an allowlist
    /// rots into a rubber stamp.
    @Test("a product name is exempt as a phrase and its generic half is not")
    func properPhrasesDoNotExemptTheirWords() {
        #expect(ProductCopyRules.properPhrases == ["Claude Code", "Google Meet", "Setup Assistant"])
        #expect(ProductCopyRules.titleCaseOffenders(in: "Use Claude Code sign-in").isEmpty)
        #expect(ProductCopyRules.titleCaseOffenders(in: "The Google Meet account is signed in").isEmpty)
        #expect(ProductCopyRules.titleCaseOffenders(in: "Run the Setup Assistant to register it").isEmpty)

        #expect(ProductCopyRules.titleCaseOffenders(in: "Open the Meet window") == ["Meet"])
        #expect(ProductCopyRules.titleCaseOffenders(in: "Show the Code panel") == ["Code"])
        #expect(ProductCopyRules.titleCaseOffenders(in: "Ask the Assistant about it") == ["Assistant"])
        #expect(!ProductCopyRules.properNouns.contains("Code"))
        #expect(!ProductCopyRules.properNouns.contains("Meet"))
        #expect(!ProductCopyRules.properNouns.contains("Assistant"))

        // A phrase that ends a sentence still ends it, so the word after it is a
        // sentence start rather than an offender.
        #expect(ProductCopyRules.titleCaseOffenders(in: "Sign in to Google Meet. Fermix waits.").isEmpty)
    }

    // MARK: - The copy deck

    @Test("the welcome deck matches the redline")
    func welcomeDeck() {
        #expect(ProductStrings[.welcomeTitle] == "Welcome to Fermix")
        #expect(
            ProductStrings[.welcomeValue]
                == "An assistant that runs on this Mac and answers wherever you message it."
        )
        #expect(ProductStrings[.welcomeCTA] == "Set up Fermix")
        #expect(ProductStrings[.welcomeUseExistingHome] == "Use an existing Fermix home…")
    }

    @Test("the starting deck matches the redline")
    func startingDeck() {
        #expect(ProductStrings[.startingTitle] == "Starting Fermix")
        #expect(ProductStrings[.startingCaption] == "macOS may mention a new background item. That is Fermix.")
        #expect(ProductStrings[.startingRowService] == "Registering the background service")
        #expect(ProductStrings[.startingRowDaemon] == "Starting the daemon")
        #expect(ProductStrings[.startingRowAnswering] == "Checking it answers")
        #expect(ProductStrings[.startingRowReading] == "Reading what is already set up")
    }

    @Test("the applying deck matches the redline")
    func applyingDeck() {
        #expect(ProductStrings[.applyingTitle] == "Applying your setup")
        #expect(ProductStrings[.applyingRowSaving] == "Saving your setup")
        #expect(ProductStrings[.applyingRowRestarting] == "Restarting Fermix so your provider takes effect")
    }

    @Test("the about you deck matches the redline")
    func aboutYouDeck() {
        #expect(ProductStrings[.aboutYouTitle] == "About you")
        #expect(ProductStrings[.aboutYouSubcopy].contains("address you and to keep time straight"))
        #expect(ProductStrings[.aboutYouName] == "Your name")
        #expect(ProductStrings[.aboutYouTimezone] == "Time zone")
        #expect(ProductStrings[.aboutYouStyle] == "Style")
        #expect(ProductStrings[.aboutYouAssistantName] == "Call the assistant")
        #expect(
            [AssistantStyle.concise, .balanced, .detailed].map(\.title)
                == ["Concise", "Balanced", "Detailed"]
        )
    }

    @Test("connect AI commits to the browser handoff and never to a password")
    func connectAIDeck() {
        #expect(ProductStrings[.connectAITitle] == "Connect your AI")
        #expect(ProductStrings[.connectAISubcopy].contains("opens in your browser"))
        #expect(ProductStrings[.connectAISubcopy].contains("never sees your password"))
        #expect(ProductStrings[.connectAIKeyRowTitle] == "API key")
                // Not a vendor list: the picker inside the sheet is where the provider
        // is chosen, and a hand-written roster on the row went stale the moment
        // the engine published another provider (M34 §4).
        #expect(ProductStrings[.connectAIKeyRowHint] == "Any provider that takes a key.")
        #expect(ProductStrings[.connectAIConnectedTitle] == "Your AI is already connected")
        #expect(ProductStrings[.connectAIConnectedBody].contains("found a working setup in your home folder"))
    }

    /// M34 override 7: `ConnectChannel.dc.html` is not built, so no string in
    /// the product describes a channel step of the assistant.
    @Test("no string survives from the retired channel step")
    func noChannelStepCopy() {
        for key in ProductStringKey.allCases {
            #expect(!key.rawValue.hasPrefix("connectChannel."), "\(key.rawValue)")
        }
    }

    /// M34 override 2: the CLI row no longer promises a privileged action.
    @Test("the CLI row promises a copied command and not a password prompt")
    func readyCLIRow() {
                // No backticks: `Text(String)` parses no Markdown, so they were drawn.
        // The row sets the command in the mono face instead (redlines §5.5).
        #expect(ProductStrings[.readyCLITitle] == "Install the fermix command for Terminal")
        #expect(!ProductStrings[.readyCLITitle].contains("`"))
        #expect(ProductStrings[.readyCLIHint] == "Copies a Terminal command you run once")
        #expect(!ProductStrings[.readyCLIHint].lowercased().contains("password"))
        #expect(ProductStrings[.readyTitle] == "Fermix is live")
        #expect(ProductStrings[.readyStatus] == "Running, answers even when this window is closed")
        #expect(ProductStrings[.readyNextChannels] == "Connect Telegram, Slack or Discord")
        #expect(ProductStrings[.readyNextVoice] == "Turn on the voice companion")
        #expect(ProductStrings[.readyAttention] == "Some things still need attention")
    }

    /// Errors read: what happened, what is untouched, the one next action. The
    /// untouched half has two published spellings, because M34 §15.2 fixes the
    /// coexistence sentences verbatim and they say "nothing was changed".
    @Test("every boot failure names what happened, what is untouched, and one action")
    func bootFailureVariants() {
        for cause in BootFailureCause.allCases {
            let sentence = ProductStrings.bootFailure(cause)
            let untouched = ["hasn’t been touched", "nothing was changed"]

            #expect(!sentence.isEmpty, "\(cause)")
            #expect(untouched.contains { sentence.contains($0) }, "\(cause) omits the untouched promise")
            #expect(sentence.hasSuffix("."), "\(cause)")
        }

        #expect(ProductStrings.bootFailure(.timedOut).contains("90 seconds"))
        #expect(ProductStrings.bootFailure(.bindFailure).contains("port"))
        #expect(ProductStrings.bootFailure(.invalidPackage).contains("reinstall"))
    }

    /// The states Starting can end in, as one closed set: the M34 §4 causes, the
    /// 90-second timeout, the location refusal, and the five coexistence
    /// refusals of §15.2. Each is its own case because each has its own remedy;
    /// folding two of them would send the operator after the wrong one.
    @Test("the boot failure causes are the closed set M34 names")
    func bootFailureCauseSet() {
        #expect(
            Set(BootFailureCause.allCases) == [
                .timedOut, .approvalPending, .backgroundItemDisabled, .incompatibleVersion,
                .crashLoop, .bindFailure, .webUnavailable, .invalidPackage, .notInApplications,
                .legacyInstallPresent, .legacySystemInstallPresent, .foreignDaemonRunning,
                .preManagementDaemonRunning, .duplicateCopyPresent, .migrationHandoffInvalid,
                // Three kinds `invalidPackage` used to swallow. A malformed
                // `launcher.json`, an `SMAppService` refusal and a stalled
                // daemon are not a bad bundle, and sending any of them to
                // reinstall is the wrong remedy (M34 §15.2).
                .bootstrapRecordUnusable, .registrationFailed, .daemonUnresponsive,
                // A daemon that answers `hello` in management's own vocabulary
                // and does not identify itself. It is not the pre-management
                // daemon, so it must not be sent to the upgrade commands.
                .daemonRefusedIdentity
            ]
        )
    }

    /// The coexistence sentences are fixed by M34 §15.2, including the commands
    /// they name and the ones they deliberately do not.
    @Test("the coexistence refusals carry the design's own sentences")
    func coexistenceCopy() {
        let foreign = ProductStrings.bootFailure(.foreignDaemonRunning)
        #expect(foreign.contains("installed another way is using this home"))
        #expect(!foreign.contains("fermix stop"), "the right command depends on how that daemon was started")

        #expect(ProductStrings.bootFailure(.preManagementDaemonRunning).contains("brew upgrade fermix"))
        #expect(ProductStrings.bootFailure(.preManagementDaemonRunning).contains("fermix migrate-to-app"))

        // The neighbouring cause names none of them: it is read by a daemon
        // that already speaks management, where all three are the wrong remedy.
        let refused = ProductStrings.bootFailure(.daemonRefusedIdentity)
        #expect(!refused.contains("brew upgrade fermix"))
        #expect(!refused.contains("fermix migrate-to-app"))
        #expect(BootFailureCause.daemonRefusedIdentity.commands.isEmpty)

        // M34 §15.0's three commands, in order. Skipping `fermix restart` leaves
        // a pre-management daemon in memory that cannot answer `hello`, so the
        // migration walks straight back into the refusal it just read.
        let legacy = ProductStrings.bootFailure(.legacyInstallPresent)
        let steps = ["brew upgrade fermix", "fermix restart", "fermix migrate-to-app"]
        var searched = legacy.startIndex..<legacy.endIndex
        for step in steps {
            let found = legacy.range(of: step, range: searched)
            #expect(found != nil, "the legacy-install sentence names \(step), in order")
            guard let found else { break }

            searched = found.upperBound..<legacy.endIndex
        }

        #expect(
            ProductStrings.bootFailure(.legacySystemInstallPresent)
                .contains("sudo fermix service uninstall --system")
        )
        #expect(ProductStrings.bootFailure(.duplicateCopyPresent).contains("Applications folder"))
    }

    /// M34 §4 bans Start and Stop for the durable service.
    @Test("the service wording is enable and disable, never start or stop")
    func serviceWording() {
        // The menu titles are the one place the pair is written: the
        // sentence-case copies of them were drawn by nothing.
        #expect(ProductStrings[.menuTitleEnableService] == "Enable Background Service")
        #expect(ProductStrings[.menuTitleDisableService] == "Disable Background Service")

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
        // The support card is actions only: the button labels carry the whole
        // story, and the export-hint subtext line is gone.
        #expect(ProductStrings[.doctorSupportExport] == "Export support bundle")
        #expect(ProductStrings[.doctorSupportOpenLogFolder] == "Open log folder")
        #expect(!ProductStringKey.allCases.map(\.rawValue).contains("doctor.support.exportHint"))
    }

    /// M34 §3.3's own spellings, and the status item's four state lines.
    @Test("the menu deck matches the design")
    func menuDeck() {
        #expect(ProductStrings[.menuTitleQuit] == "Quit Fermix")
        #expect(ProductStrings[.menuTitleCheckForUpdates] == "Check for Updates…")
        #expect(ProductStrings[.menuTitleRestartDaemon] == "Restart Fermix…")
        #expect(ProductStrings[.menuTitleRunNetworkChecks] == "Run Network Checks…")
        #expect(ProductStrings[.daemonStateNotRunning] == "Fermix isn\u{2019}t running")
        #expect(ProductStrings[.statusMenuRestartPending] == "Restart to finish updating")
        #expect(ProductStrings[.statusMenuRunningFormat].contains("%@"))
    }

    /// M34 §6: no settings control is labelled Save, Apply or Submit. Every
    /// write is confirmed by the daemon rather than submitted by the operator,
    /// so a button spelled that way would be describing a flow the product does
    /// not have.
    @Test("no control is labelled Save, Apply or Submit")
    func noSubmitVerbs() {
        for key in ProductStringKey.allCases {
            let value = ProductStrings[key]

            #expect(value != "Save", "\(key.rawValue)")
            #expect(value != "Apply", "\(key.rawValue)")
            #expect(value != "Submit", "\(key.rawValue)")
        }
    }

    /// The Settings deck of the redline copy deck (§7), which is what the
    /// banners, the restart sheet and the secret rows read.
    @Test("the settings deck matches the redline")
    func settingsDeck() {
        #expect(ProductStrings[.settingsRestartTitle] == "Restart to apply")
        #expect(ProductStrings[.settingsRestartAction] == "Restart…")
        #expect(ProductStrings[.settingsRestartSheetTitle] == "Restart Fermix now?")
        #expect(ProductStrings[.settingsRestartNow] == "Restart now")
        #expect(ProductStrings[.settingsRestartWhenIdle] == "Restart when idle")
        #expect(ProductStrings[.settingsEngineSheetTitle] == "Finish updating Fermix")
        #expect(ProductStrings[.settingsExternalChangeTitle] == "Settings changed outside Fermix")
        #expect(ProductStrings[.settingsExternalChangeAction] == "Reload settings from disk")
        #expect(ProductStrings[.settingsSecretStored] == "Stored")
        #expect(ProductStrings[.settingsSecretReplace] == "Replace…")
        #expect(ProductStrings[.settingsSecretRemove] == "Remove")
        #expect(ProductStrings[.settingsSecretAdd] == "Add…")
        #expect(ProductStrings[.providerVerifyAndSave] == "Verify and save")
    }

    /// A poll that reached its cap stopped watching the job; it did not stop the
    /// job. `attach(kind:)` exists to pick that run up again, so the sentence
    /// must not tell the operator a long install was cancelled.
    @Test("a job that outran its poll is not reported as stopped")
    func timedOutJobCopy() {
        let sentence = ProductStrings[.settingsJobTimedOut]

        #expect(sentence.contains("still running"))
        for claim in ["it was stopped", "was cancelled", "gave up", "it failed"] {
            #expect(!sentence.lowercased().contains(claim), "\(claim)")
        }
        #expect(ProductCopyRules.violations(in: sentence).isEmpty)
    }

    /// The unreadable-file state is answered with Recovery and never with a
    /// reload, because the reload would re-run the read that just failed.
    @Test("the unreadable settings file offers recovery rather than a reload")
    func unreadableSettingsCopy() {
        #expect(ProductStrings[.settingsConfigUnreadableAction] != ProductStrings[.settingsExternalChangeAction])
        #expect(!ProductStrings[.settingsConfigUnreadableAction].lowercased().contains("reload"))
        #expect(ProductStrings[.settingsConfigUnreadableBody].contains("Nothing has been changed"))
    }

    /// The thirteen pane titles are M34 §5's own names, including the four the
    /// owner renamed (decision 8).
    @Test("the pane titles are the renamed surfaces")
    func paneTitles() {
        #expect(SettingsPane.personality.title == "Personality")
        #expect(SettingsPane.images.title == "Images")
        #expect(SettingsPane.integrations.title == "Integrations")
        #expect(SettingsPane.voice.title == "Voice")

        for pane in SettingsPane.allCases {
            #expect(ProductCopyRules.violations(in: pane.title).isEmpty, "\(pane.slug)")
        }
    }

    /// M34 §3.2 and §5.8: an Attention row and a Doctor row are read in a
    /// native window, so neither may carry a command line. The engine's own
    /// readiness sentences still say `Run mix fermix.setup …`, which is exactly
    /// what this keeps out of the app's catalogue.
    ///
    /// The case set is derived from the catalogue prefixes rather than listed,
    /// so a row added later is covered by construction.
    @Test("no attention or doctor string names a task, a config file, or an environment variable")
    func noCommandLinesInAttentionOrDoctorCopy() {
        for key in ProductStringKey.allCases
        where key.rawValue.hasPrefix("attention.") || key.rawValue.hasPrefix("doctor.") {
            #expect(!ProductCopyRules.namesACommandLine(ProductStrings[key]), "\(key.rawValue)")
        }
    }

    /// A gate that never fires is not a gate: the engine's own readiness
    /// sentences are exactly what it has to reject.
    @Test("the command-line rule fires on the engine's own sentences")
    func commandLineRuleFires() {
        let engineSentences = [
            "Run mix fermix.setup to finish configuring Fermix.",
            "Edit config.toml and restart.",
            "Set FERMIX_OPIK_ENABLED first.",
            "Export $FERMIX_HOME before starting."
        ]

        for sentence in engineSentences {
            #expect(ProductCopyRules.namesACommandLine(sentence), "\(sentence)")
        }
        #expect(!ProductCopyRules.namesACommandLine("Fermix has no working credential for this provider yet."))
    }

    /// The prefixes the rule above is written over have to name real copy, or
    /// the gate passes by scanning nothing.
    @Test("the attention and doctor prefixes cover real copy")
    func commandLineRuleIsNotVacuous() {
        let covered = ProductStringKey.allCases.filter {
            $0.rawValue.hasPrefix("attention.") || $0.rawValue.hasPrefix("doctor.")
        }

        #expect(covered.count > 20, "the command-line rule scanned \(covered.count) strings")
    }

    /// The Attention rows are the app's own words, because the engine's are
    /// command lines a native window must never render (M34 §3.2).
    @Test("the attention deck names the gap and never a terminal command")
    func attentionDeck() {
        #expect(ProductStrings[.attentionRestartTitle] == "Restart to apply your changes")
        #expect(ProductStrings[.attentionExternalChangeTitle] == "Settings changed outside Fermix")
        #expect(ProductStrings[.attentionActionReload] == "Reload settings from disk")
        #expect(ProductStrings[.attentionProviderCredentialsTitleFormat].contains("%@"))
        #expect(ProductStrings[.attentionChannelTitleFormat].contains("%@"))
    }

    /// The catalogue already spells an ellipsis with the character rather than
    /// three periods; the apostrophe is the other mark that has a typewriter
    /// spelling, and every contraction and possessive in the deck reads through
    /// the same one.
    @Test("no product string spells an apostrophe with a typewriter quote")
    func typographicApostrophes() throws {
        let shipped = try ProductStringsFixture.shippedCatalogue()
        let offenders = shipped.filter { $0.value.contains("'") }.keys.sorted()

        #expect(offenders.isEmpty, "\(offenders) use a straight apostrophe")
        // The rule is only worth having if the deck actually contracts, which
        // it does in every boot failure and half the refusals.
        #expect(shipped.values.contains { $0.contains("\u{2019}") })
    }

    /// A count of one reads as a count of one. The warning half of the banner
    /// already had its own sentence; the failing half formatted "1 checks
    /// failed" for the commonest Doctor result there is.
    @Test("a single failed check reads in the singular")
    func singularFailedCheck() {
        #expect(ProductStrings[.doctorBannerFailingOne] == "One check failed")
        #expect(!ProductStrings[.doctorBannerFailingOne].contains("%"))
        #expect(ProductStrings[.doctorBannerFailingFormat].contains("%lld"))
    }

    /// The Add an API key sheet says one sentence, and the vendor is inside it.
    /// Joined to the vendor with a comma it read as a fragment with no full
    /// stop: "OpenRouter, the key is stored in your keychain".
    @Test("the key sheet's sentence names the vendor and ends")
    func addKeySubcopyIsASentence() {
        let format = ProductStrings[.providerAddKeySubcopyFormat]

        #expect(format.contains("%@"))
        #expect(format.hasSuffix("."))
        #expect(format.hasPrefix("The key is stored"))
    }

    /// A permission's principal is drawn on its own line under the right it
    /// belongs to, so it starts like every other line on the surface.
    @Test("a permission principal is a noun phrase, not a clause fragment")
    func permissionPrincipals() {
        let principals: [ProductStringKey] = [
            .permissionPrincipalApp,
            .permissionPrincipalComputerUse,
            .permissionPrincipalAgent
        ]

        for key in principals {
            let value = ProductStrings[key]

            #expect(value.first?.isUppercase == true, "\(key.rawValue) begins lowercase")
            #expect(!value.lowercased().hasPrefix("the "), "\(key.rawValue) begins with an article")
        }
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
