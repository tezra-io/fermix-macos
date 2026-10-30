import Darwin
import Foundation
import Testing

@testable import FermixAppCore

/// Settings > Browser > Website logins (M84 §11, D7, D8).
///
/// Everything above the keychain runs on `InMemoryLoginStore` or on a scripted
/// double, so the section's states, every save refusal and the sheet's
/// password handling are proven without a window and without the keychain.
@Suite("Website logins section")
@MainActor
struct WebsiteLoginsModelTests {
    @Test("the section is loading until the store answers")
    func loadingFirst() {
        let model = WebsiteLoginsModel(store: InMemoryLoginStore())

        #expect(model.state == .loading)
    }

    @Test("a store with logins lists them by site")
    func listsLogins() async throws {
        let store = InMemoryLoginStore()
        _ = try await store.add(site: "ledger.quillbank.example", username: "mira.okafor@example.com", password: LoginSecret("tangerine-lantern-42"))
        _ = try await store.add(site: "accounts.orchard.example", username: "mira-okafor", password: LoginSecret("copper-heron-7781"))
        let model = WebsiteLoginsModel(store: store)

        await model.refresh()

        guard case .listed(let logins) = model.state else {
            Issue.record("expected a list, got \(model.state)")
            return
        }
        #expect(logins.map(\.site) == ["accounts.orchard.example", "ledger.quillbank.example"])
        #expect(logins.map(\.username) == ["mira-okafor", "mira.okafor@example.com"])
    }

    @Test("an empty store is an empty list, which the section says in D8's words")
    func emptyList() async {
        let model = WebsiteLoginsModel(store: InMemoryLoginStore())

        await model.refresh()

        #expect(model.state == .listed([]))
        #expect(ProductStrings[.settingsBrowserLoginsEmpty] == "No logins yet. Add the sites you want the agent to sign in to.")
    }

    @Test("a build with no store says the logins need the released app")
    func noStore() async {
        let model = WebsiteLoginsModel(store: UnavailableLoginStore())

        await model.refresh()

        #expect(model.state == .unavailable(.noStore))
        #expect(LoginsUnavailable.noStore.sentence == "Website logins need the released Fermix app.")
    }

    @Test("a keychain refusal names its status")
    func keychainRefused() async {
        let store = ScriptedLoginStore(list: .failure(.unavailable(status: -25308)))
        let model = WebsiteLoginsModel(store: store)

        await model.refresh()

        #expect(model.state == .unavailable(.refused(status: -25308)))
        #expect(LoginsUnavailable.refused(status: -25308).sentence == "The keychain did not answer (-25308).")
    }

    @Test("a keychain that did not answer in time is its own state")
    func keychainTimedOut() async {
        let model = WebsiteLoginsModel(store: ScriptedLoginStore(list: .failure(.timedOut)))

        await model.refresh()

        #expect(model.state == .unavailable(.timedOut))
        #expect(LoginsUnavailable.timedOut.sentence == "The keychain did not answer in time.")
        #expect(LoginsUnavailable.timedOut.sentence != LoginsUnavailable.refused(status: -1).sentence)
    }

    /// Re-reading after a save or on coming back to the pane never puts the
    /// section back to loading: the list it has stays drawn until the new one
    /// replaces it, so nothing flashes.
    @Test("a re-read keeps the list it has until the new answer lands", .timeLimit(.minutes(1)))
    func reReadKeepsTheList() async throws {
        let store = HeldLoginStore()
        let first = try await store.inner.add(site: "ledger.quillbank.example", username: "mira-okafor", password: LoginSecret("tangerine-lantern-42"))
        let model = WebsiteLoginsModel(store: store)
        await store.release()
        await model.refresh()
        #expect(model.state == .listed([first]))

        await store.hold()
        let second = try await store.inner.add(site: "accounts.orchard.example", username: "mira-okafor", password: LoginSecret("copper-heron-7781"))
        let reading = Task { await model.refresh() }
        await store.arrivals(atLeast: 2)

        #expect(model.state == .listed([first]), "the old list stays while the store is answering")

        await store.release()
        await reading.value
        #expect(model.state == .listed([second, first]))
    }

    /// Two reads in flight: the pane appearing and a save's re-read. Only the
    /// newest read's answer is drawn, so a slow first read cannot put back a
    /// list older than the one already shown.
    @Test("an older read that answers late is not drawn", .timeLimit(.minutes(1)))
    func staleReadIsDropped() async throws {
        let store = HeldLoginStore()
        let model = WebsiteLoginsModel(store: store)
        // Answers the empty list it read on arrival, once it is let go.
        let slow = Task { await model.refresh() }
        await store.arrivals(atLeast: 1)

        await store.stopHolding()
        let added = try await store.inner.add(site: "ledger.quillbank.example", username: "mira-okafor", password: LoginSecret("tangerine-lantern-42"))
        await model.refresh()
        #expect(model.state == .listed([added]))

        await store.release()
        await slow.value
        #expect(model.state == .listed([added]), "the older read's empty answer is not drawn")
    }

    /// Every keychain call is made off the main actor (M84 §6). The double is
    /// a plain `Sendable` struct rather than an actor, which is the shape a
    /// keychain store has, so where its methods run is decided by the caller.
    @Test("the section's store calls run off the main thread")
    func storeCallsLeaveTheMainThread() async {
        let threads = ThreadLog()
        let model = WebsiteLoginsModel(store: ThreadRecordingLoginStore(log: threads))

        await model.refresh()
        _ = await model.save(.add(site: "ledger.quillbank.example", username: "mira-okafor", password: LoginSecret("tangerine-lantern-42")))
        _ = await model.delete(SavedLogin(id: UUID(), site: "ledger.quillbank.example", username: "mira-okafor"))

        let calls = await threads.calls
        #expect(calls.count >= 3, "the double saw \(calls.count) calls")
        #expect(!calls.contains(true), "a store call ran on the main thread")
    }
}

@Suite("Website login sheet")
@MainActor
struct LoginSheetTests {
    // MARK: Adding

    @Test("a login that passes every rule is saved, listed, and its password dropped")
    func addSaves() async throws {
        let store = InMemoryLoginStore()
        let model = WebsiteLoginsModel(store: store)
        await model.refresh()
        var draft = LoginDraft(mode: .add)
        draft.site = "https://Ledger.QuillBank.example/sign-in"
        draft.username = "mira.okafor@example.com"
        draft.password = "tangerine-lantern-42"

        let request = try saving(&draft)
        draft.finishSave(await model.save(request))

        #expect(draft.password.isEmpty)
        #expect(draft.refusals.isEmpty)
        let listed = try await store.list()
        #expect(listed.map(\.site) == ["ledger.quillbank.example"])
        #expect(model.state == .listed(listed))
    }

    @Test("an address the rules refuse keeps every value and says why under the site")
    func siteRefused() async throws {
        let store = ScriptedLoginStore(list: .success([]))
        let model = WebsiteLoginsModel(store: store)
        await model.refresh()

        for site in ["localhost", "127.0.0.1", "intranet", "xn--fiqs8s.example"] {
            var draft = filledAddDraft(site: site)
            let draftRequest = try saving(&draft)
            draft.finishSave(await model.save(draftRequest))

            #expect(draft.refusals.site == "Use a site\u{2019}s address, like github.com.", "\(site)")
            #expect(draft.refusals.firstField == .site)
            expectKept(draft, site: site)
        }
        #expect(await store.writes == 0, "a refused login never reaches the store")
    }

    @Test("a site that already has a login is refused with the taken sentence")
    func siteTaken() async throws {
        let store = InMemoryLoginStore()
        _ = try await store.add(site: "ledger.quillbank.example", username: "mira-okafor", password: LoginSecret("tangerine-lantern-42"))
        let model = WebsiteLoginsModel(store: store)
        await model.refresh()
        var draft = filledAddDraft(site: "www.ledger.quillbank.example")

        let draftRequest = try saving(&draft)
        draft.finishSave(await model.save(draftRequest))

        #expect(draft.refusals.site == "You already have a login for this site. Edit that one.")
        expectKept(draft, site: "www.ledger.quillbank.example")
        #expect(try await store.list().count == 1)
    }

    @Test("a blank username is refused in D8's words")
    func usernameRequired() async throws {
        let model = WebsiteLoginsModel(store: InMemoryLoginStore())
        await model.refresh()
        var draft = filledAddDraft(site: "ledger.quillbank.example")
        draft.username = "   "

        let draftRequest = try saving(&draft)
        draft.finishSave(await model.save(draftRequest))

        #expect(draft.refusals.username == "Enter the username you sign in with.")
        #expect(draft.refusals.firstField == .username)
        #expect(draft.username == "   ")
        #expect(draft.password == "tangerine-lantern-42")
    }

    @Test("a password under eight characters is refused, and the copy says the rule's own number")
    func passwordTooShort() async throws {
        let model = WebsiteLoginsModel(store: InMemoryLoginStore())
        await model.refresh()
        var draft = filledAddDraft(site: "ledger.quillbank.example")
        draft.password = "seven77"

        let draftRequest = try saving(&draft)
        draft.finishSave(await model.save(draftRequest))

        #expect(draft.refusals.password == "Fermix needs a password of at least 8 characters.")
        #expect(draft.refusals.firstField == .password)
        #expect(draft.password == "seven77")
        #expect(LoginStoreRules.minimumPasswordLength == 8, "the sentence names 8")
    }

    /// The reviewed mockup's refused add: the site is taken and the password
    /// is short, and both say so at once, with focus going to the first.
    @Test("every refusal is shown at once, and focus goes to the first refused field")
    func everyRefusalAtOnce() async throws {
        let store = InMemoryLoginStore()
        _ = try await store.add(site: "ledger.quillbank.example", username: "mira-okafor", password: LoginSecret("tangerine-lantern-42"))
        let model = WebsiteLoginsModel(store: store)
        await model.refresh()
        var draft = filledAddDraft(site: "ledger.quillbank.example")
        draft.username = ""
        draft.password = "short"

        let draftRequest = try saving(&draft)
        draft.finishSave(await model.save(draftRequest))

        #expect(draft.refusals.site != nil)
        #expect(draft.refusals.username != nil)
        #expect(draft.refusals.password != nil)
        #expect(draft.refusals.firstField == .site)
    }

    @Test("a refusal only the store can make keeps the values and says why under the form")
    func storeRefusalKeepsValues() async throws {
        let cases: [(LoginStoreError, String)] = [
            (.unavailable(status: -25308), "The keychain did not answer (-25308)."),
            (.unavailable(status: nil), "Website logins need the released Fermix app."),
            (.timedOut, "The keychain did not answer in time."),
            (.full, "Fermix keeps up to \(LoginStoreRules.maximumLogins) logins. Delete one to add another.")
        ]

        for (error, sentence) in cases {
            let model = WebsiteLoginsModel(store: ScriptedLoginStore(list: .success([]), write: error))
            await model.refresh()
            var draft = filledAddDraft(site: "ledger.quillbank.example")

            let draftRequest = try saving(&draft)
            draft.finishSave(await model.save(draftRequest))

            #expect(draft.refusals.general == sentence, "\(error)")
            #expect(draft.refusals.firstField == nil)
            expectKept(draft, site: "ledger.quillbank.example")
            #expect(draft.phase == .editing)
        }
    }

    @Test("typing in a refused field takes its refusal away")
    func typingClearsTheFieldsRefusal() async throws {
        let model = WebsiteLoginsModel(store: InMemoryLoginStore())
        await model.refresh()
        var draft = filledAddDraft(site: "localhost")
        draft.password = "short"
        let draftRequest = try saving(&draft)
        draft.finishSave(await model.save(draftRequest))

        draft.site = "ledger.quillbank.example"
        draft.edited(.site)

        #expect(draft.refusals.site == nil)
        #expect(draft.refusals.password != nil, "only the field typed in loses its refusal")
    }

    // MARK: Saving

    /// Return in a field and the default button both reach the save, and a
    /// person presses Return twice. One write goes out.
    @Test("a second save while one is in flight sends nothing", .timeLimit(.minutes(1)))
    func oneSaveAtATime() async throws {
        let store = HeldLoginStore()
        await store.release()
        let model = WebsiteLoginsModel(store: store)
        await model.refresh()
        await store.hold()
        var draft = filledAddDraft(site: "ledger.quillbank.example")

        let request = try saving(&draft)
        #expect(draft.phase == .saving)
        #expect(draft.isBusy)
        let second = draft.beginSave()
        #expect(second == nil, "a second press while saving sends nothing")

        let saving = Task { await model.save(request) }
        await store.arrivals(atLeast: 2)
        #expect(await store.adds == 1)

        await store.release()
        draft.finishSave(await saving.value)
        #expect(draft.phase == .finished)
        #expect(await store.adds == 1)
    }

    // MARK: Editing

    @Test("editing fixes the site, fills the username and starts with no password")
    func editStartsFromTheLogin() {
        let login = SavedLogin(id: UUID(), site: "ledger.quillbank.example", username: "mira-okafor")
        let draft = LoginDraft(mode: .edit(login))

        #expect(draft.site == "ledger.quillbank.example")
        #expect(draft.username == "mira-okafor")
        #expect(draft.password.isEmpty)
        #expect(ProductStrings[.settingsBrowserLoginKeepPassword] == "Leave empty to keep the saved password.")
    }

    @Test("an edit with the password left empty keeps the saved password")
    func emptyPasswordKeepsTheOld() async throws {
        let store = InMemoryLoginStore()
        let saved = try await store.add(site: "ledger.quillbank.example", username: "mira-okafor", password: LoginSecret("tangerine-lantern-42"))
        let model = WebsiteLoginsModel(store: store)
        await model.refresh()
        var draft = LoginDraft(mode: .edit(saved))
        draft.username = "mira.okafor@example.com"

        let request = try saving(&draft)
        #expect(request == .edit(saved, username: "mira.okafor@example.com", password: nil), "an empty field sends no password")
        draft.finishSave(await model.save(request))

        #expect(draft.refusals.isEmpty)
        #expect(try await store.password(for: saved.id) == LoginSecret("tangerine-lantern-42"))
        #expect(try await store.list().first?.username == "mira.okafor@example.com")
    }

    @Test("an edit with a new password replaces it")
    func newPasswordReplaces() async throws {
        let store = InMemoryLoginStore()
        let saved = try await store.add(site: "ledger.quillbank.example", username: "mira-okafor", password: LoginSecret("tangerine-lantern-42"))
        let model = WebsiteLoginsModel(store: store)
        await model.refresh()
        var draft = LoginDraft(mode: .edit(saved))
        draft.password = "copper-heron-7781"

        let draftRequest = try saving(&draft)
        draft.finishSave(await model.save(draftRequest))

        #expect(draft.password.isEmpty)
        #expect(try await store.password(for: saved.id) == LoginSecret("copper-heron-7781"))
    }

    @Test("an edit with a short password is refused and the saved one stays")
    func editShortPasswordRefused() async throws {
        let store = InMemoryLoginStore()
        let saved = try await store.add(site: "ledger.quillbank.example", username: "mira-okafor", password: LoginSecret("tangerine-lantern-42"))
        let model = WebsiteLoginsModel(store: store)
        await model.refresh()
        var draft = LoginDraft(mode: .edit(saved))
        draft.password = "short"

        let draftRequest = try saving(&draft)
        draft.finishSave(await model.save(draftRequest))

        #expect(draft.refusals.password == "Fermix needs a password of at least 8 characters.")
        #expect(draft.password == "short")
        #expect(try await store.password(for: saved.id) == LoginSecret("tangerine-lantern-42"))
    }

    // MARK: Deleting

    @Test("delete asks first, and keeping the login goes back to the edit")
    func deleteAsksFirst() {
        let login = SavedLogin(id: UUID(), site: "ledger.quillbank.example", username: "mira-okafor")
        var draft = LoginDraft(mode: .edit(login))
        draft.password = "half-typed"

        draft.askDelete()
        #expect(draft.phase == .confirmingDelete)
        #expect(LoginDraft.deleteQuestion(for: login) == "Delete the login for ledger.quillbank.example?")
        #expect(ProductStrings[.settingsBrowserLoginDeleteBody] == "The agent can no longer sign in there.")

        draft.keepLogin()
        #expect(draft.phase == .editing)
        #expect(draft.password == "half-typed", "going back loses nothing")
    }

    @Test("a confirmed delete removes the login from the store and the list")
    func confirmedDeleteRemoves() async throws {
        let store = InMemoryLoginStore()
        let saved = try await store.add(site: "ledger.quillbank.example", username: "mira-okafor", password: LoginSecret("tangerine-lantern-42"))
        let model = WebsiteLoginsModel(store: store)
        await model.refresh()
        var draft = LoginDraft(mode: .edit(saved))

        draft.askDelete()
        let begun = draft.beginDelete()
        let login = try #require(begun)
        #expect(draft.phase == .deleting)
        let again = draft.beginDelete()
        #expect(again == nil, "a second press while deleting sends nothing")
        draft.finishDelete(refusal: await model.delete(login))

        #expect(draft.phase == .finished)
        #expect(try await store.list().isEmpty)
        #expect(model.state == .listed([]))
    }

    @Test("a delete the store refuses says why and stays on the question")
    func refusedDeleteSaysWhy() async throws {
        let model = WebsiteLoginsModel(store: ScriptedLoginStore(list: .success([]), write: .notFound))
        await model.refresh()
        let login = SavedLogin(id: UUID(), site: "ledger.quillbank.example", username: "mira-okafor")
        var draft = LoginDraft(mode: .edit(login))
        draft.askDelete()

        let begun = draft.beginDelete()
        draft.finishDelete(refusal: await model.delete(try #require(begun)))

        #expect(draft.phase == .confirmingDelete)
        #expect(draft.deleteRefusal == "This login is no longer saved.")
    }

    // MARK: The password

    @Test("the password is dropped on save, cancel and close, and kept on a refusal")
    func passwordLifetime() async throws {
        let model = WebsiteLoginsModel(store: InMemoryLoginStore())
        await model.refresh()

        var saved = filledAddDraft(site: "ledger.quillbank.example")
        let savedRequest = try saving(&saved)
        saved.finishSave(await model.save(savedRequest))
        #expect(saved.password.isEmpty, "save")

        var cancelled = filledAddDraft(site: "accounts.orchard.example")
        cancelled.clearPassword()
        #expect(cancelled.password.isEmpty, "cancel")
        #expect(cancelled.site == "accounts.orchard.example", "cancel drops only the password")

        var closed = filledAddDraft(site: "accounts.orchard.example")
        closed.clearPassword()
        #expect(closed.password.isEmpty, "close")

        var refused = filledAddDraft(site: "localhost")
        let refusedRequest = try saving(&refused)
        refused.finishSave(await model.save(refusedRequest))
        #expect(refused.password == "tangerine-lantern-42", "a refusal keeps it")
    }

    /// Cancel, Escape and the sheet going away all go through the one call
    /// that drops the password, and the sheet types it only into the one
    /// secure input the product has.
    @Test("the sheet drops the password on cancel and close, through SecretInput")
    func sheetWiring() throws {
        let sheet = try #require(try SourceTree.swiftFiles(matching: "Settings/Panes/LoginSheet.swift").first?.text)

        #expect(sheet.contains("SecretInput("))
        #expect(!sheet.contains("SecureField"))
        #expect(sheet.contains(".onDisappear"))
        #expect(sheet.components(separatedBy: "clearPassword()").count - 1 >= 2, "cancel and close both drop the password")
    }

    /// "Paste the value" is the prompt for a key someone copies from a
    /// vendor's console, not for a password someone types. The login sheet's
    /// field passes an empty prompt, since its label already says Password,
    /// and every other secure input keeps the shared one.
    @Test("the login sheet's password field does not say Paste the value")
    func passwordFieldPrompt() throws {
        let row = try #require(try SourceTree.swiftFiles(matching: "Settings/Rows/SecretRow.swift").first?.text)
        let sheet = try #require(try SourceTree.swiftFiles(matching: "Settings/Panes/LoginSheet.swift").first?.text)

        #expect(row.contains("SecureField(label, text: $value, prompt: Text(prompt))"), "the secure input draws the prompt it is given")
        #expect(SecretInput(label: "Key", value: .constant(""), onSubmit: {}).prompt == ProductStrings[.settingsSecretPrompt])
        #expect(ProductStrings[.settingsSecretPrompt] == "Paste the value")

        let calls = sheet.components(separatedBy: "\n").filter { $0.contains("SecretInput(") }
        #expect(calls.count == 1)
        #expect(calls.allSatisfy { $0.contains("prompt: \"\"") }, "the login sheet's secure input passes an empty prompt")
    }

    // MARK: Helpers

    private func filledAddDraft(site: String) -> LoginDraft {
        var draft = LoginDraft(mode: .add)
        draft.site = site
        draft.username = "mira-okafor"
        draft.password = "tangerine-lantern-42"
        return draft
    }

    private func expectKept(_ draft: LoginDraft, site: String, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(draft.site == site, sourceLocation: sourceLocation)
        #expect(draft.username == "mira-okafor", sourceLocation: sourceLocation)
        #expect(draft.password == "tangerine-lantern-42", sourceLocation: sourceLocation)
    }
}

/// What the logins surface may never do, and where it sits (M84 §6, §11, D7).
@Suite("Website logins source gates")
struct WebsiteLoginsSourceGateTests {
    private static let files = ["Settings/Panes/WebsiteLoginsSection.swift", "Settings/Panes/LoginSheet.swift"]

    private func surface() throws -> [SourceTree.File] {
        let found = try Self.files.flatMap { try SourceTree.swiftFiles(matching: $0) }
        #expect(found.count == Self.files.count, "the gate is reading \(found.map(\.path))")
        return found
    }

    /// The pane draws the logins in `DescriptorPane`'s app-owned slot, and
    /// that slot sits beside the daemon branch rather than inside it, so a
    /// daemon too old for the descriptor form still shows the logins.
    @Test("the logins show while the pane needs a newer engine")
    func loginsIgnoreTheDaemonBranch() throws {
        let text = try #require(try SourceTree.swiftFiles(matching: "Settings/Panes/SettingsPaneView.swift").first?.text)

        #expect(text.contains("case .browser:\n            BrowserPane(model: model)"))
        #expect(text.contains("appOwned: {\n                WebsiteLoginsSection("))

        let form = try #require(Self.formClosure(of: "struct DescriptorPane<", in: text))
        let depths = Self.braceDepths(of: ["if model.requiresNewerEngine", "appOwned"], in: form)
        #expect(depths["if model.requiresNewerEngine"] == 0)
        #expect(depths["appOwned"] == 0, "the app-owned slot is drawn in both branches")
    }

    @Test("no reveal, copy or export, and no password read")
    func neverShowsAPassword() throws {
        for file in try surface() {
            for forbidden in ["password(for:", "withValue", "NSPasteboard", "Clipboard", "fileExporter", "ShareLink", "textSelection(.enabled)"] {
                #expect(!file.text.contains(forbidden), "\(file.path) uses \(forbidden)")
            }
        }
    }

    @Test("nothing reaches the daemon and nothing is logged")
    func staysInTheApp() throws {
        for file in try surface() {
            for forbidden in ["gateway", "DaemonQuerying", "setSecret", "AppLog", "logger", "print("] {
                #expect(!file.text.contains(forbidden), "\(file.path) uses \(forbidden)")
            }
        }
    }

    /// The text of the closure `SettingsPaneForm(title: pane.title) {` opens
    /// inside the named declaration, without its braces.
    private static func formClosure(of declaration: String, in text: String) -> Substring? {
        guard let start = text.range(of: declaration),
              let open = text.range(of: "SettingsPaneForm(title: pane.title) {", range: start.upperBound..<text.endIndex)
        else { return nil }

        var depth = 1
        var index = open.upperBound
        while index < text.endIndex {
            if text[index] == "{" { depth += 1 }
            if text[index] == "}" { depth -= 1 }
            if depth == 0 { return text[open.upperBound..<index] }
            index = text.index(after: index)
        }

        return nil
    }

    /// The brace depth, inside the closure, of the line each marker starts on.
    private static func braceDepths(of markers: [String], in body: Substring) -> [String: Int] {
        var depths: [String: Int] = [:]
        var depth = 0

        for line in body.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // `} else {` belongs to the depth its `if` opened at.
            let lineDepth = trimmed.hasPrefix("}") ? depth - 1 : depth
            for marker in markers where trimmed.hasPrefix(marker) && depths[marker] == nil {
                depths[marker] = lineDepth
            }
            depth += line.filter { $0 == "{" }.count - line.filter { $0 == "}" }.count
        }

        return depths
    }
}

@Suite("Website logins copy")
struct WebsiteLoginsCopyTests {
    /// M84 §11's table, and D8's two sentences, exactly.
    @Test("the logins deck matches the design")
    func deck() {
        let deck: [(ProductStringKey, String)] = [
            (.settingsBrowserLoginsSection, "Website logins"),
            (.settingsBrowserLoginsFooter, "The agent signs in with these after you approve each one. It never sees the passwords."),
            (.settingsBrowserLoginsUnavailable, "Website logins need the released Fermix app."),
            (.settingsBrowserLoginsAdd, "Add login…"),
            (.settingsBrowserLoginsEdit, "Edit…"),
            (.settingsBrowserLoginSite, "Site"),
            (.settingsBrowserLoginSiteHint, "Use the address of the sign-in page, like accounts.google.com."),
            (.settingsBrowserLoginUsername, "Username"),
            (.settingsBrowserLoginPassword, "Password"),
            (.settingsBrowserLoginKeepPassword, "Leave empty to keep the saved password."),
            (.settingsBrowserLoginDeleteTitle, "Delete the login for %@?"),
            (.settingsBrowserLoginDeleteBody, "The agent can no longer sign in there."),
            (.settingsBrowserLoginSiteRefused, "Use a site\u{2019}s address, like github.com."),
            (.settingsBrowserLoginSiteTaken, "You already have a login for this site. Edit that one."),
            (.settingsBrowserLoginTooShort, "Fermix needs a password of at least 8 characters."),
            (.settingsBrowserLoginStoreUnavailable, "The keychain did not answer (%@)."),
            (.settingsBrowserLoginsEmpty, "No logins yet. Add the sites you want the agent to sign in to."),
            (.settingsBrowserLoginUsernameRequired, "Enter the username you sign in with.")
        ]

        for (key, value) in deck {
            #expect(ProductStrings[key] == value, "\(key.rawValue)")
        }
    }

    @Test("every logins string keeps the copy rules")
    func copyRules() {
        let keys = ProductStringKey.allCases.filter { $0.rawValue.hasPrefix("settings.browser.login") }

        #expect(keys.count >= 18, "the scan found \(keys.count) keys")
        for key in keys {
            #expect(ProductCopyRules.violations(in: ProductStrings[key]).isEmpty, "\(key.rawValue)")
            #expect(!ProductStrings[key].contains("'"), "\(key.rawValue) uses a typewriter apostrophe")
        }
    }

    /// Nothing offers to show, copy or export a saved password (M84 §11).
    @Test("no logins string offers to reveal, copy or export")
    func noRevealVerbs() {
        for key in ProductStringKey.allCases where key.rawValue.hasPrefix("settings.browser.login") {
            let words = ProductStrings[key].lowercased()
            for verb in ["show password", "reveal", "copy", "export", "import"] {
                #expect(!words.contains(verb), "\(key.rawValue) offers \(verb)")
            }
        }
    }
}

/// Starts a draft's save and hands back its request, failing the test when
/// the draft sends nothing. Bound outside the macro, which captures its
/// expression in a closure that cannot mutate the draft.
private func saving(_ draft: inout LoginDraft, sourceLocation: SourceLocation = #_sourceLocation) throws -> LoginSaveRequest {
    let request = draft.beginSave()
    return try #require(request, sourceLocation: sourceLocation)
}

// MARK: - Doubles

/// A store whose list answer and whose every write are scripted, counting the
/// writes that reached it.
actor ScriptedLoginStore: LoginStore {
    private let listAnswer: Result<[SavedLogin], LoginStoreError>
    private let writeError: LoginStoreError?
    private(set) var writes = 0

    init(list: Result<[SavedLogin], LoginStoreError>, write: LoginStoreError? = nil) {
        listAnswer = list
        writeError = write
    }

    func list() async throws -> [SavedLogin] { try listAnswer.get() }

    func add(site: String, username: String, password: LoginSecret) async throws -> SavedLogin {
        writes += 1
        if let writeError { throw writeError }
        return SavedLogin(id: UUID(), site: site, username: username)
    }

    func update(id: UUID, username: String, password: LoginSecret?) async throws -> SavedLogin {
        writes += 1
        if let writeError { throw writeError }
        return SavedLogin(id: id, site: "ledger.quillbank.example", username: username)
    }

    func delete(id: UUID) async throws {
        writes += 1
        if let writeError { throw writeError }
    }

    func login(forHost host: String) async throws -> SavedLogin? { nil }

    func password(for id: UUID) async throws -> LoginSecret { throw LoginStoreError.notFound }
}

/// An in-memory store whose calls wait, while it is holding, until the test
/// releases them, and which tells the test each call has arrived. Arrival is
/// an event the test waits for, never a time.
actor HeldLoginStore: LoginStore {
    let inner = InMemoryLoginStore()
    private var holding = true
    private var heldCalls: [CheckedContinuation<Void, Never>] = []
    private var arrived = 0
    private var arrivalWaiters: [(count: Int, waiter: CheckedContinuation<Void, Never>)] = []
    private(set) var adds = 0

    func hold() { holding = true }

    /// New calls go straight through; calls already held stay held.
    func stopHolding() { holding = false }

    func release() {
        holding = false
        heldCalls.forEach { $0.resume() }
        heldCalls.removeAll()
    }

    func arrivals(atLeast count: Int) async {
        guard arrived < count else { return }
        await withCheckedContinuation { arrivalWaiters.append((count, $0)) }
    }

    private func enter() async {
        arrived += 1
        let ready = arrivalWaiters.filter { $0.count <= arrived }
        arrivalWaiters.removeAll { $0.count <= arrived }
        ready.forEach { $0.waiter.resume() }
        guard holding else { return }
        await withCheckedContinuation { heldCalls.append($0) }
    }

    /// The list as it stood when the call arrived, so a call held across a
    /// change answers what it read.
    func list() async throws -> [SavedLogin] {
        let read = try await inner.list()
        await enter()
        return read
    }

    func add(site: String, username: String, password: LoginSecret) async throws -> SavedLogin {
        adds += 1
        await enter()
        return try await inner.add(site: site, username: username, password: password)
    }

    func update(id: UUID, username: String, password: LoginSecret?) async throws -> SavedLogin {
        await enter()
        return try await inner.update(id: id, username: username, password: password)
    }

    func delete(id: UUID) async throws {
        await enter()
        try await inner.delete(id: id)
    }

    func login(forHost host: String) async throws -> SavedLogin? { try await inner.login(forHost: host) }

    func password(for id: UUID) async throws -> LoginSecret { try await inner.password(for: id) }
}

/// Whether each store call ran on the main thread.
actor ThreadLog {
    private(set) var calls: [Bool] = []

    func note(_ onMain: Bool) { calls.append(onMain) }
}

/// A plain `Sendable` store, the shape a keychain store has: its methods are
/// nonisolated, so the thread they run on is the caller's choice.
struct ThreadRecordingLoginStore: LoginStore {
    let log: ThreadLog

    func list() async throws -> [SavedLogin] {
        let onMain = pthread_main_np() != 0
        await log.note(onMain)
        return []
    }

    func add(site: String, username: String, password: LoginSecret) async throws -> SavedLogin {
        let onMain = pthread_main_np() != 0
        await log.note(onMain)
        return SavedLogin(id: UUID(), site: site, username: username)
    }

    func update(id: UUID, username: String, password: LoginSecret?) async throws -> SavedLogin {
        let onMain = pthread_main_np() != 0
        await log.note(onMain)
        return SavedLogin(id: id, site: "ledger.quillbank.example", username: username)
    }

    func delete(id: UUID) async throws {
        let onMain = pthread_main_np() != 0
        await log.note(onMain)
    }

    func login(forHost host: String) async throws -> SavedLogin? { nil }

    func password(for id: UUID) async throws -> LoginSecret { throw LoginStoreError.notFound }
}
