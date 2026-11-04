import SwiftUI

/// The sheet a press collects its action's needs in: the recovery
/// passphrase. It ends with the action's confirm, in the engine's words,
/// above the action's own label, so pressing it is accepting the confirm and
/// the passphrase never waits behind a second question.
struct AlwaysOnAskContent: View {
    @ObservedObject var model: AlwaysOnModel
    let ask: AlwaysOnAsk

    var body: some View {
        switch ask {
        case .passphrase(let action, let twice):
            AlwaysOnPassphraseSheet(model: model, action: action, twice: twice)
        case .confirm:
            EmptyView()
        }
    }
}

/// The recovery passphrase (`needs` `new_recovery_passphrase` or
/// `recovery_passphrase`): typed twice, and the two compared here, where none
/// is set; once where one is, which the engine checks. It lives in this
/// sheet until the one press sends it.
struct AlwaysOnPassphraseSheet: View {
    @ObservedObject var model: AlwaysOnModel
    let action: ManagementHomeAction
    let twice: Bool

    @State private var passphrase = ""
    @State private var again = ""
    @State private var mismatch = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text(ProductStrings[.alwaysOnPassphraseTitle])
                .fermixType(Typography.style(.headline))
            CuesPageForm {
                Section {
                    CueNote(text: ProductStrings[twice ? ProductStringKey.alwaysOnPassphraseBody : .alwaysOnPassphraseOnceBody])
                    LabeledContent(ProductStrings[.alwaysOnPassphraseField]) {
                        SecretInput(label: ProductStrings[.alwaysOnPassphraseField], value: $passphrase, onSubmit: {}, prompt: "")
                    }
                    if twice {
                        LabeledContent(ProductStrings[.alwaysOnPassphraseAgain]) {
                            SecretInput(label: ProductStrings[.alwaysOnPassphraseAgain], value: $again, onSubmit: {}, prompt: "")
                        }
                    }
                    if mismatch {
                        CueNote(text: ProductStrings[.alwaysOnPassphraseMismatch], attention: true)
                    }
                    if let confirm = action.confirm {
                        CueNote(text: confirm)
                    }
                }
            }
            HStack(spacing: Spacing.s) {
                Spacer()
                if model.working == action.id { ProgressView().controlSize(.small) }
                Button(ProductStrings[.settingsSheetCancel], action: model.dismissAsk)
                    .buttonStyle(SecondaryButtonStyle(.row))
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.working != nil)
                PrimaryAction(action.label, size: .row, action: submit)
                    .disabled(passphrase.isEmpty || (twice && again.isEmpty) || model.working != nil)
            }
        }
        .padding(WindowMetrics.contentPadding)
        .frame(width: SheetMetrics.credentialWidth)
    }

    private func submit() {
        let typed = (passphrase, again)
        mismatch = twice && typed.0 != typed.1
        guard !mismatch else { return }

        Task { _ = await model.submitPassphrase(typed.0, again: twice ? typed.1 : nil) }
    }
}
