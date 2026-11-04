import SwiftUI

/// Always On (Always On setup §8.3): the engine's summary drawn as it is, one
/// sentence and at most one main action per screen, Details for the expert.
/// Which screen shows is `AlwaysOnPage`'s; what a press does is the model's.
struct AlwaysOnPane: View {
    @ObservedObject var settings: SettingsModel
    @ObservedObject var model: AlwaysOnModel

    var body: some View {
        SettingsPaneForm(title: SettingsPane.alwaysOn.title) {
            switch model.page {
            case .reading:
                Section { ProgressView().controlSize(.small) }
            case .unreadable(let sentence):
                Section { CueNote(text: sentence, attention: true) }
            case .needsUpdate:
                Section { NewerEngineNotice(sentence: settings.newerEngineSentence) }
            case .restarting:
                AlwaysOnRestartingSection(model: model)
            case .screen(let screen):
                AlwaysOnScreenView(screen: screen, settings: settings, model: model)
            }
        }
        .task { await model.paneAppeared() }
        .onDisappear { model.paneDisappeared() }
        .sheet(item: sheet) { ask in
            AlwaysOnAskContent(model: model, ask: ask)
                .sheetGround()
        }
        .alert(confirming?.label ?? "", isPresented: confirmShown, presenting: confirming) { action in
            let title = action.label
            Button(title) {
                Task { await model.accept(action) }
            }
            Button(ProductStrings[.settingsSheetCancel], role: .cancel) { model.dismissAsk() }
        } message: { action in
            Text(action.confirm ?? "")
        }
    }

    /// The press whose needs a sheet collects.
    private var sheet: Binding<AlwaysOnAsk?> {
        Binding(
            get: { model.asking?.isSheet == true ? model.asking : nil },
            set: { if $0 == nil, model.asking?.isSheet == true { model.dismissAsk() } }
        )
    }

    /// The action whose confirm is asked, for one that collects nothing.
    private var confirming: ManagementHomeAction? {
        guard case .confirm(let action)? = model.asking else { return nil }

        return action
    }

    private var confirmShown: Binding<Bool> {
        Binding(
            get: { confirming != nil },
            set: { if !$0, confirming != nil { model.dismissAsk() } }
        )
    }
}

/// While the engine restarts to carry out this app's own Move now: the
/// app's one word of its own, and why the engine is not answering yet.
struct AlwaysOnRestartingSection: View {
    @ObservedObject var model: AlwaysOnModel

    var body: some View {
        Section {
            Text(ProductStrings[.lifecycleRestarting])
                .fermixType(Typography.style(.callout))
                .foregroundStyle(Palette.ink.color)
            ProgressView().progressViewStyle(.linear)
            if case .unavailable(let sentence)? = model.readFailure {
                CueNote(text: sentence)
            }
        }
    }
}

/// One screen: the sentence, the step in hand, the engine's other sentences,
/// the one action and the others, then Details.
struct AlwaysOnScreenView: View {
    let screen: AlwaysOnScreen
    @ObservedObject var settings: SettingsModel
    @ObservedObject var model: AlwaysOnModel

    @State private var detailsShown = false

    var body: some View {
        Section {
            Text(screen.sentence)
                .fermixType(Typography.style(.callout))
                .foregroundStyle(Palette.ink.color)
                .fixedSize(horizontal: false, vertical: true)

            if screen.showsBar {
                ProgressView().progressViewStyle(.linear)
            }
            if let progress = screen.progress {
                CueNote(text: progress)
            }
            if case .unavailable(let failure)? = model.readFailure {
                CueNote(text: failure, attention: true)
            }
            ForEach(screen.notes, id: \.self) { CueNote(text: $0) }
            ForEach(screen.readiness, id: \.id) { item in
                CueNote(text: item.sentence, attention: item.status == .block)
            }
            AlwaysOnMainAction(screen: screen, model: model)
            ForEach(screen.alternatives, id: \.key) { alternative in
                AlwaysOnLinkAction(action: alternative, model: model)
            }
        }

        if let code = model.ownServer {
            AlwaysOnOwnServerSection(model: model, code: code)
        }
        if screen.hasDetails {
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
}

/// The one main action, or the token field in its place while a token is
/// asked for, and the engine's refusal or note under it.
struct AlwaysOnMainAction: View {
    let screen: AlwaysOnScreen
    @ObservedObject var model: AlwaysOnModel

    var body: some View {
        if model.asking?.isField == true, let target = screen.tokenTarget(picked: model.picked) {
            AlwaysOnTokenStep(model: model, target: target, state: screen.state)
        } else if let action = screen.action {
            HStack(spacing: Spacing.s) {
                PrimaryAction(action.label, size: .row) {
                    Task { await model.press(action) }
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

/// An action offered as a link: the screen's alternatives and the actions
/// Details offers.
struct AlwaysOnLinkAction: View {
    let action: ManagementHomeAction
    @ObservedObject var model: AlwaysOnModel

    var body: some View {
        HStack(spacing: Spacing.s) {
            LinkButton(title: action.label) {
                Task { await model.press(action) }
            }
            .fermixType(Typography.style(.calloutSmall))
            .disabled(model.working != nil)

            if model.working == action.id {
                ProgressView().controlSize(.small)
            }
        }
    }
}

/// The token step: the pick where the summary lists more than one provider,
/// then that provider's field.
struct AlwaysOnTokenStep: View {
    @ObservedObject var model: AlwaysOnModel
    let target: AlwaysOnTokenTarget
    let state: ManagementHomeSummaryState

    var body: some View {
        switch target {
        case .provider(let provider):
            AlwaysOnTokenField(model: model, provider: provider, saysSentence: state != .connect)
                .id(provider.id)
        case .pick(let providers):
            CueNote(text: ProductStrings[.alwaysOnProviderChoose])
            ForEach(providers, id: \.id) { provider in
                LinkButton(title: provider.name) { model.pick(provider: provider) }
                    .fermixType(Typography.style(.callout))
            }
        }
    }
}

/// One provider's token screen in the engine's words: its sentence, the
/// paste field under its label, sent as soon as a token is pasted, "How to
/// get one" with its steps and its console, and its part of the docs.
struct AlwaysOnTokenField: View {
    @ObservedObject var model: AlwaysOnModel
    let provider: ManagementHomeSummaryProvider
    /// `connect`'s own sentence is the provider's, so it is not said twice.
    let saysSentence: Bool

    @State private var token = ""

    /// A token is at least this long, so a change that adds this much at once
    /// was pasted.
    static let pasted = 16

    var body: some View {
        if saysSentence {
            CueNote(text: provider.sentence)
        }
        LabeledContent(provider.tokenLabel) {
            SecretInput(label: provider.tokenLabel, value: $token, onSubmit: submit)
                .onChange(of: token) { before, after in
                    guard after.count - before.count >= Self.pasted else { return }

                    submit()
                }
        }
        .disabled(model.working != nil)

        if model.working == .pasteToken {
            HStack(spacing: Spacing.xs) {
                ProgressView().controlSize(.small)
                CueNote(text: String(format: ProductStrings[.alwaysOnTokenCheckingFormat], provider.name))
            }
        }
        DisclosureGroup(ProductStrings[.alwaysOnHowToGetOne]) {
            AlwaysOnSteps(steps: provider.steps)
            LinkButton(title: String(format: ProductStrings[.alwaysOnOpenConsoleFormat], provider.name)) {
                model.open(provider.consoleUrl)
            }
        }
        .fermixType(Typography.style(.calloutSmall))
        HStack(spacing: Spacing.s) {
            LinkButton(title: ProductStrings[.alwaysOnLearnMore]) { model.open(provider.docsUrl) }
            LinkButton(title: ProductStrings[.settingsSheetCancel], action: model.dismissAsk)
                .disabled(model.working != nil)
        }
        .fermixType(Typography.style(.calloutSmall))
    }

    private func submit() {
        let pasted = token
        Task {
            await model.submitToken(pasted, for: provider)
            if model.refusal == nil { token = "" }
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

/// What Details holds: the engine's lines, each as it finished it, what lives
/// on the server, and on `on` the actions it offers.
struct AlwaysOnDetails: View {
    let screen: AlwaysOnScreen
    @ObservedObject var model: AlwaysOnModel

    var body: some View {
        ForEach(screen.lines, id: \.self) { line in
            LabeledContent(line.label) {
                Text(line.value)
                    .textSelection(.enabled)
            }
            .fermixType(Typography.style(.calloutSmall))
        }
        if let data = screen.data {
            CueNote(text: data)
        }
        ForEach(screen.detailActions, id: \.key) { action in
            AlwaysOnLinkAction(action: action, model: model)
        }
    }
}

/// A server of the owner's own: the command it runs, which carries no code,
/// and the code it asks for as it first boots, shown once and copied for
/// this Mac only, until when it works.
struct AlwaysOnOwnServerSection: View {
    @ObservedObject var model: AlwaysOnModel
    let code: ManagementOwnServerCode

    @State private var copy = CueSecretCopy()

    var body: some View {
        Section {
            CueNote(text: String(format: ProductStrings[.alwaysOnOwnServerFormat], AlwaysOnFormat.time(code.expiresAt)))
            Text(code.command)
                .fermixType(Typography.style(.mono))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Button(ProductStrings[.alwaysOnCopyCommand]) { Clipboard.write(code.command) }
                .buttonStyle(SecondaryButtonStyle(.row))
            Text(code.code)
                .fermixType(Typography.style(.mono))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Button(ProductStrings[.alwaysOnCopyCode]) { copy.copy(code.code, on: .system) }
                .buttonStyle(SecondaryButtonStyle(.row))
        }
        .onDisappear { copy.takeBack(on: .system) }
    }
}

/// The one time the pane formats itself: until when the code for a server
/// of the owner's own works, which `own_server` answers as a time.
enum AlwaysOnFormat {
    static func time(_ text: String) -> String {
        guard let date = ManagementCueTime.date(text) else { return text }

        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
