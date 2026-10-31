import SwiftUI

/// Always On (M75 lean v1 §7): one sentence and at most one main action per
/// screen, the engine's words, Details for the expert and Learn more to the
/// docs. Which screen shows, and what it says, is `AlwaysOnPage`'s.
struct AlwaysOnPane: View {
    @ObservedObject var settings: SettingsModel
    @ObservedObject var model: AlwaysOnModel

    @State private var changing = false

    var body: some View {
        SettingsPaneForm(title: SettingsPane.alwaysOn.title) {
            switch model.page {
            case .reading:
                Section { ProgressView().controlSize(.small) } header: { AlwaysOnLead(model: model) }
            case .unreadable(let sentence):
                Section { CueNote(text: sentence, attention: true) } header: { AlwaysOnLead(model: model) }
            case .needsUpdate:
                Section { NewerEngineNotice(sentence: settings.newerEngineSentence) } header: { AlwaysOnLead(model: model) }
            case .screen(let screen):
                AlwaysOnScreenView(screen: screen, settings: settings, model: model) { changing = true }
            }
        }
        .task { await model.paneAppeared() }
        .onDisappear { model.paneDisappeared() }
        .sheet(isPresented: $changing) {
            AlwaysOnChangeSheet(model: model) { changing = false }
                .sheetGround()
        }
        .sheet(isPresented: replacing) {
            AlwaysOnReplaceSheet(model: model)
                .sheetGround()
        }
        .sheet(isPresented: asksPassphrase) {
            AlwaysOnMovePassphraseSheet(model: model)
                .sheetGround()
        }
    }

    private var replacing: Binding<Bool> {
        Binding(get: { model.replacing }, set: { if !$0 { model.closeReplace() } })
    }

    private var asksPassphrase: Binding<Bool> {
        Binding(get: { model.asksMovePassphrase }, set: { if !$0 { model.dismissMovePassphrase() } })
    }
}

/// The pane's lead: Learn more, to the Always On docs page, over every
/// screen.
struct AlwaysOnLead: View {
    @ObservedObject var model: AlwaysOnModel

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
            Spacer(minLength: Spacing.s)
            LinkButton(title: ProductStrings[.alwaysOnLearnMore], action: model.openGuide)
                .fermixType(Typography.style(.calloutSmall))
        }
        .textCase(nil)
    }
}

/// One screen: the sentence, what the screen holds, its one action, then
/// Details.
struct AlwaysOnScreenView: View {
    let screen: AlwaysOnScreen
    @ObservedObject var settings: SettingsModel
    @ObservedObject var model: AlwaysOnModel
    let change: () -> Void

    @State private var detailsShown = false

    var body: some View {
        Section {
            Text(sentence)
                .fermixType(Typography.style(.callout))
                .foregroundStyle(Palette.ink.color)
                .fixedSize(horizontal: false, vertical: true)

            if screen.showsProgress {
                ProgressView().progressViewStyle(.linear)
            }
            if let failure = readFailure {
                CueNote(text: failure, attention: true)
            }
            AlwaysOnScreenBody(screen: screen, model: model, newerEngine: settings.newerEngineSentence, change: change)
            AlwaysOnMainAction(action: screen.action, model: model)
        } header: {
            AlwaysOnLead(model: model)
        }

        if screen.asksPassphrase {
            AlwaysOnPassphraseSection(model: model)
        }
        if model.handout != nil || model.codeRefusal != nil {
            AlwaysOnOwnServerSection(model: model)
        }
        if AlwaysOnDetails.shows(screen) {
            Section {
                DisclosureGroup(ProductStrings[.alwaysOnDetails], isExpanded: $detailsShown) {
                    AlwaysOnDetails(screen: screen, model: model)
                }
            }
            if detailsShown {
                DescriptorForm(model: settings, sections: settings.sections(for: .alwaysOn))
            }
        }
    }

    /// The choose screen says the choice: the engine's recommendation, or the
    /// owner's own once changed. Every other screen says the engine's.
    private var sentence: String {
        guard screen.kind == .choose, let options = model.options.value else { return screen.sentence }
        guard let pick = model.chosen, pick != options.recommended, let offer = options.offer(pick) else {
            return options.sentence
        }

        return AlwaysOnPrices.choice(offer, in: options)
    }

    /// A read that failed after one that answered: the screen stays as it was
    /// and says so.
    private var readFailure: String? {
        guard case .unavailable(let sentence)? = model.readFailure else { return nil }

        return sentence
    }
}

/// What a screen holds between its sentence and its action.
struct AlwaysOnScreenBody: View {
    let screen: AlwaysOnScreen
    @ObservedObject var model: AlwaysOnModel
    /// What an engine without the Hetzner provisioner is told, in place of
    /// the paste field.
    let newerEngine: String
    let change: () -> Void

    var body: some View {
        if screen.tokenField, model.servesHetzner {
            AlwaysOnTokenField(model: model, steps: screen.steps)
        } else if screen.tokenField {
            NewerEngineNotice(sentence: newerEngine)
        }
        if screen.kind == .token {
            ForEach(screen.alternatives, id: \.self) { alternative in
                AlwaysOnLinkAction(action: alternative, model: model)
            }
        }
        if screen.kind == .choose {
            LinkButton(title: ProductStrings[.alwaysOnChange], action: change)
                .fermixType(Typography.style(.calloutSmall))
                .disabled(model.options.value == nil)
        }
        if screen.kind == .ready {
            ForEach(model.readiness(on: screen), id: \.id) { item in
                CueNote(text: item.sentence, attention: item.status == .block)
            }
        }
    }
}

/// The one main action, its progress while it waits on the daemon, and the
/// daemon's refusal or note under it.
struct AlwaysOnMainAction: View {
    let action: ManagementHomeAction?
    @ObservedObject var model: AlwaysOnModel

    var body: some View {
        if let action {
            HStack(spacing: Spacing.s) {
                PrimaryAction(action.label, size: .row) {
                    Task { await model.perform(action) }
                }
                .disabled(model.working != nil)

                if model.working == action.id {
                    ProgressView().controlSize(.small)
                }
            }
        }
        if let refusal = model.refusal {
            CueNote(text: refusal, attention: true)
        }
        if let notice = model.notice {
            CueNote(text: notice)
        }
    }
}

/// An action offered as a link: the token screen's own-server link, and the
/// other actions Details offers.
struct AlwaysOnLinkAction: View {
    let action: ManagementHomeAction
    @ObservedObject var model: AlwaysOnModel

    var body: some View {
        HStack(spacing: Spacing.s) {
            LinkButton(title: action.label) {
                Task { await model.perform(action) }
            }
            .fermixType(Typography.style(.calloutSmall))
            .disabled(model.working != nil || model.gettingCode)

            if model.working == action.id || (action.id == .ownServer && model.gettingCode) {
                ProgressView().controlSize(.small)
            }
        }
    }
}

/// The paste field, checked as soon as a token is pasted, and "How to get
/// one" with the engine's steps.
struct AlwaysOnTokenField: View {
    @ObservedObject var model: AlwaysOnModel
    let steps: [String]

    @State private var token = ""

    /// A token is at least this long, so a change that adds this much at once
    /// was pasted.
    static let pasted = 16

    var body: some View {
        LabeledContent(ProductStrings[.alwaysOnTokenField]) {
            SecretInput(label: ProductStrings[.alwaysOnTokenField], value: $token, onSubmit: check)
                .onChange(of: token) { before, after in
                    guard after.count - before.count >= Self.pasted else { return }

                    check()
                }
        }
        .disabled(model.checkingToken)

        if model.checkingToken {
            HStack(spacing: Spacing.xs) {
                ProgressView().controlSize(.small)
                CueNote(text: ProductStrings[.alwaysOnTokenChecking])
            }
        }
        if let refusal = model.tokenRefusal {
            CueNote(text: refusal, attention: true)
        }
        if !steps.isEmpty {
            DisclosureGroup(ProductStrings[.alwaysOnHowToGetOne]) {
                AlwaysOnSteps(steps: steps)
                LinkButton(title: ProductStrings[.alwaysOnOpenHetzner], action: model.openHetznerConsole)
            }
            .fermixType(Typography.style(.calloutSmall))
        }
    }

    private func check() {
        let pasted = token
        Task {
            await model.checkToken(pasted)
            if model.tokenRefusal == nil { token = "" }
        }
    }
}

/// The engine's steps, numbered.
struct AlwaysOnSteps: View {
    let steps: [String]

    var body: some View {
        ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
            HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                Image(systemName: "\(index + 1).circle")
                    .foregroundStyle(Palette.secondary.color)
                    .accessibilityHidden(true)
                CueNote(text: step)
            }
        }
    }
}

/// The recovery passphrase, typed twice, while the server starts and none is
/// set (§2 step 4).
struct AlwaysOnPassphraseSection: View {
    @ObservedObject var model: AlwaysOnModel

    @State private var passphrase = ""
    @State private var again = ""

    var body: some View {
        Section(ProductStrings[.alwaysOnPassphraseTitle]) {
            CueNote(text: ProductStrings[.alwaysOnPassphraseBody])
            AlwaysOnPassphraseFields(passphrase: $passphrase, again: $again)

            HStack(spacing: Spacing.s) {
                // Not the default button: the screen's own action, Cancel,
                // keeps Return.
                Button(ProductStrings[.alwaysOnPassphraseSave]) {
                    let typed = (passphrase, again)
                    Task {
                        if await model.setPassphrase(typed.0, again: typed.1) {
                            passphrase = ""
                            again = ""
                        }
                    }
                }
                .buttonStyle(SecondaryButtonStyle(.row))
                .disabled(passphrase.isEmpty || again.isEmpty || model.settingPassphrase)

                if model.settingPassphrase { ProgressView().controlSize(.small) }
            }
            if let refusal = model.passphraseRefusal {
                CueNote(text: refusal, attention: true)
            }
        }
    }
}

/// The passphrase, and the same again, each in the one secure input.
struct AlwaysOnPassphraseFields: View {
    @Binding var passphrase: String
    @Binding var again: String

    var body: some View {
        LabeledContent(ProductStrings[.alwaysOnPassphraseField]) {
            SecretInput(label: ProductStrings[.alwaysOnPassphraseField], value: $passphrase, onSubmit: {}, prompt: "")
        }
        LabeledContent(ProductStrings[.alwaysOnPassphraseAgain]) {
            SecretInput(label: ProductStrings[.alwaysOnPassphraseAgain], value: $again, onSubmit: {}, prompt: "")
        }
    }
}

/// The command for a server of the owner's own, with its code inside, shown
/// once and copied for this Mac only.
struct AlwaysOnOwnServerSection: View {
    @ObservedObject var model: AlwaysOnModel

    @State private var copy = CueSecretCopy()

    var body: some View {
        Section {
            if let handout = model.handout {
                CueNote(text: String(format: ProductStrings[.alwaysOnOwnServerFormat], AlwaysOnFormat.time(handout.expiresAt)))
                Text(AlwaysOnLinks.ownServerCommand(code: handout.code))
                    .fermixType(Typography.style(.mono))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Button(ProductStrings[.alwaysOnCopyCommand]) {
                    copy.copy(AlwaysOnLinks.ownServerCommand(code: handout.code), on: .system)
                }
                .buttonStyle(SecondaryButtonStyle(.row))
            }
            if let refusal = model.codeRefusal {
                CueNote(text: refusal, attention: true)
            }
        }
        .onDisappear { copy.takeBack(on: .system) }
    }
}
