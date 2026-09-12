import SwiftUI

/// The one shape every secret takes (M34 §5, §7.4).
///
/// `Stored` with `Replace…` and `Remove`, or `Add…`. The value itself exists
/// only inside the sheet's own state, for as long as the sheet is open: it is
/// never logged, never persisted, never put on the pasteboard, and a blank is
/// never sent.
///
/// This is the only file in the app that may contain a `SecureField`, and a
/// source gate says so.
struct SecretRow: View {
    let label: String
    /// The `secret.set` id, which is the descriptor row's own key.
    let identifier: String
    let present: Bool
    @ObservedObject var model: SettingsModel

    @State private var sheetShown = false
    @State private var removing = false

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: Spacing.xs) {
                if present {
                    Text(ProductStrings[.settingsSecretStored])
                        .foregroundStyle(Palette.secondary.color)

                    Button(ProductStrings[.settingsSecretReplace]) { sheetShown = true }
                    Button(ProductStrings[.settingsSecretRemove], action: remove)
                        .disabled(removing)
                } else {
                    Button(ProductStrings[.settingsSecretAdd]) { sheetShown = true }
                }
            }
        }
        .sheet(isPresented: $sheetShown) {
            SecretSheet(label: label, identifier: identifier, model: model) {
                sheetShown = false
            }
        }
    }

    private func remove() {
        removing = true
        Task {
            _ = await model.clearSecret(id: identifier)
            removing = false
        }
    }
}

/// The one secure input in the product.
///
/// Every sheet that takes a credential composes this, so `SecureField` has
/// exactly one call site and the source gate that says so stays true as more
/// sheets are added.
struct SecretInput: View {
    let label: String
    @Binding var value: String
    let onSubmit: () -> Void

    var body: some View {
        SecureField(label, text: $value, prompt: Text(ProductStrings[.settingsSecretPrompt]))
            .textFieldStyle(.roundedBorder)
            .labelsHidden()
            .accessibilityLabel(label)
            .onSubmit(onSubmit)
    }
}

/// The sheet a secret is typed into.
///
/// It stays open on a refusal, because `secret_store_failed` means the value
/// never reached the store and closing would lose what was typed. One default
/// button, Escape cancels, Cancel always present.
struct SecretSheet: View {
    let label: String
    let identifier: String
    @ObservedObject var model: SettingsModel
    let dismiss: () -> Void

    @State private var value = ""
    @State private var refusal: String?
    @State private var storing = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text(label)
                .fermixType(Typography.sheetTitle)
                .foregroundStyle(Palette.ink.color)

            SecretInput(label: label, value: $value, onSubmit: store)

            if let refusal {
                Text(refusal)
                    .fermixType(Typography.style(.calloutSmall))
                    .foregroundStyle(Palette.warning.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.updatesFrequently)
            }

            HStack(spacing: Spacing.s) {
                Spacer(minLength: 0)

                Button(ProductStrings[.settingsSheetCancel], action: dismiss)
                    .keyboardShortcut(.cancelAction)

                Button(ProductStrings[.settingsSecretStore], action: store)
                    .keyboardShortcut(.defaultAction)
                    // A blank is never sent: the button is the gate, so nothing
                    // downstream has to decide what an empty secret means.
                    .disabled(value.isEmpty || storing)
            }
        }
        .padding(WindowMetrics.contentPadding)
        .frame(width: SheetMetrics.credentialWidth)
    }

    private func store() {
        guard !value.isEmpty, !storing else { return }

        storing = true
        Task {
            let sentence = await model.setSecret(id: identifier, value: value)
            storing = false
            refusal = sentence

            guard sentence == nil else { return }

            // The value leaves this process the moment the store confirms it.
            value = ""
            dismiss()
        }
    }
}
