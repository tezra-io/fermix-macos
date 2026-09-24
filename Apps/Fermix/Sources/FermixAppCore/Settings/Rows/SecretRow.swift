import SwiftUI

/// The one shape every secret takes (M34 §5, §7.4).
///
/// A credential is typed in the row that owns it. An absent secret is the
/// secure field itself with `Store` beside it; a stored one reads `Stored` with
/// `Replace…` and `Remove`, and `Replace…` swaps the value column for that same
/// field in place. A sheet here stacked on whichever sheet the row was already
/// inside, which put a key three windows deep (owner report of 2026-09-20): a
/// popup never raises a second popup, so this row presents nothing.
///
/// This is the only file in the app that may contain a `SecureField`, and a
/// source gate says so. A second gate says it presents nothing.
struct SecretRow: View {
    let label: String
    /// The `secret.set` id, which is the descriptor row's own key.
    let identifier: String
    let present: Bool
    @ObservedObject var model: SettingsModel
    /// The row's longer explanation, drawn behind the (i) beside the label.
    var info: String?

    @State private var replacing = false
    @State private var removing = false
    @State private var refusal: String?

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsRowMetrics.captionGap) {
            LabeledContent {
                if present, !replacing {
                    stored
                } else {
                    entry
                }
            } label: {
                DescriptorRowLabel(label, info: info)
            }

            if let refusal {
                Text(refusal)
                    .fermixType(Typography.style(.calloutSmall))
                    .foregroundStyle(Palette.warning.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
    }

    private var stored: some View {
        HStack(spacing: Spacing.xs) {
            Text(ProductStrings[.settingsSecretStored])
                .foregroundStyle(Palette.secondary.color)

            // Named with the row they belong to. A pane with several stored
            // secrets, which the sandbox's name rows made ordinary, read to
            // VoiceOver as a column of identical `Replace…` and `Remove`.
            Button(ProductStrings[.settingsSecretReplace], action: replace)
                .accessibilityLabel(ProductStrings.commaPair(ProductStrings[.settingsSecretReplace], label))
            Button(ProductStrings[.settingsSecretRemove], action: remove)
                .accessibilityLabel(ProductStrings.commaPair(ProductStrings[.settingsSecretRemove], label))
        }
        .disabled(removing)
    }

    private var entry: some View {
        SecretEntry(
            label: label,
            identifier: identifier,
            model: model,
            refusal: $refusal,
            // A stored secret only draws the field because somebody asked for
            // it, so the field takes the focus they were about to give it. An
            // absent one is simply there, and taking focus on sight would move
            // the cursor every time a pane opened.
            focusesOnAppear: present,
            // Only a stored secret has a state to go back to.
            cancel: present ? { replacing = false } : nil,
            stored: { replacing = false }
        )
    }

    private func replace() {
        refusal = nil
        replacing = true
    }

    private func remove() {
        removing = true
        Task {
            refusal = await model.clearSecret(id: identifier)
            removing = false
        }
    }
}

/// Typing one secret in place: the secure input, the button that stores it, and
/// `Cancel` where there is a state to go back to.
///
/// The value exists only inside this view's own state, for as long as it is
/// being typed. It is never logged, never persisted, never put on the
/// pasteboard, and a blank is never sent. It is dropped the moment the daemon
/// confirms it, on `Cancel`, on Escape, and when the view goes away. A refusal
/// keeps it, because `secret_store_failed` means the value never reached the
/// store and dropping it would make the person type it again.
///
/// Only the daemon's sentence is handed up, so the row can state it under the
/// whole row rather than inside the value column.
struct SecretEntry: View {
    let label: String
    let identifier: String
    @ObservedObject var model: SettingsModel
    @Binding var refusal: String?
    var focusesOnAppear = false
    var cancel: (() -> Void)?
    var stored: () -> Void = {}

    @State private var draft = SecretDraft()
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: Spacing.xs) {
            SecretInput(label: label, value: $draft.value, prompted: cancel == nil, onSubmit: store)
                .focused($focused)

            if draft.storing {
                ProgressView().controlSize(.small).accessibilityHidden(true)
            }

            if cancel != nil {
                Button(ProductStrings[.settingsSheetCancel], action: abandon)
                    .accessibilityLabel(ProductStrings.commaPair(ProductStrings[.settingsSheetCancel], label))
            }

            Button(ProductStrings[.settingsSecretStore], action: store)
                // A blank is never sent: the button is the gate, so nothing
                // downstream has to decide what an empty secret means.
                .disabled(!draft.canStore)
                .accessibilityLabel(ProductStrings.commaPair(ProductStrings[.settingsSecretStore], label))
        }
        .disabled(draft.storing)
        .onAppear {
            guard focusesOnAppear else { return }

            // A turn later, because the field takes the place of the button
            // that asked for it. AppKit hands the first responder on when that
            // button leaves the window, and focus asked for in the same turn
            // lost to it: `Replace…` left the cursor in the pane's first field.
            DispatchQueue.main.async { focused = true }
        }
        .onChange(of: focused) { _, isFocused in claimEscape(isFocused) }
        .onChange(of: model.editReverts) { _, _ in
            guard focused else { return }

            abandon()
        }
        .onDisappear(perform: leave)
    }

    /// Escape ownership is keyed the way a draft is. A secret is addressed by
    /// its `secret.set` id and belongs to no section, so the key names that
    /// method family instead; the ids are one namespace, so two rows cannot
    /// share a key.
    private var escapeKey: SettingsDraftKey {
        SettingsDraftKey(section: "secret", key: identifier)
    }

    /// While the field is focused it owns Escape, which the window asks it for
    /// through the shared model exactly as it asks a text row (M34 §3.1).
    private func claimEscape(_ isFocused: Bool) {
        guard isFocused else {
            model.endEditing(escapeKey)
            return
        }

        model.beginEditing(escapeKey)
    }

    private func store() {
        guard let value = draft.beginStoring() else { return }

        Task {
            let sentence = await model.setSecret(id: identifier, value: value)
            draft.finish(refusal: sentence)
            refusal = sentence

            guard sentence == nil else {
                // The field was disabled while the daemon answered, which gave
                // up its focus; the value is still there to correct.
                focused = true
                return
            }

            stored()
        }
    }

    /// `Cancel` and Escape. Nothing was sent, so there is nothing to undo.
    private func abandon() {
        draft.discard()
        refusal = nil
        focused = false
        cancel?()
    }

    /// The view can go away with the field still focused: a closed sheet, a
    /// pane left behind. A claim nobody released would swallow the next Escape.
    private func leave() {
        draft.discard()
        model.endEditing(escapeKey)
    }
}

/// What is being typed into one secret field, and whether it is on its way to
/// the daemon.
///
/// A value rather than loose state, so the rules are written once and proven
/// without a window: a blank is never sent, a second Return while one store is
/// in flight sends nothing, a refusal keeps what was typed, and a confirmation
/// drops it.
struct SecretDraft {
    var value = ""
    private(set) var storing = false

    var canStore: Bool { !value.isEmpty && !storing }

    /// The value to send, or nil where there is nothing to send.
    mutating func beginStoring() -> String? {
        guard canStore else { return nil }

        storing = true
        return value
    }

    /// The daemon answered. The value leaves this process the moment the store
    /// confirms it, and stays for another attempt where it refused.
    mutating func finish(refusal: String?) {
        storing = false
        guard refusal == nil else { return }

        value = ""
    }

    mutating func discard() {
        value = ""
    }
}

/// The one secure input in the product.
///
/// Everything that takes a credential composes this, so `SecureField` has
/// exactly one call site and the source gate that says so stays true as more
/// surfaces are added. It carries the chrome a text row's field does, so it
/// fills the value column the form laid out and reads as the same kind of box.
struct SecretInput: View {
    let label: String
    @Binding var value: String
    /// Whether the empty field says what to do with it. It does wherever the
    /// field is simply there, because the words are what mark it as the place
    /// to type. A field that appeared focused because somebody asked for it
    /// needs no invitation, and beside `Cancel` and `Store` in a sheet's value
    /// column it has no room for one: the words clipped to `Paste the val`.
    var prompted = true
    let onSubmit: () -> Void

    var body: some View {
        SecureField(label, text: $value, prompt: prompted ? Text(ProductStrings[.settingsSecretPrompt]) : nil)
            .settingsTextField()
            .labelsHidden()
            .accessibilityLabel(label)
            .onSubmit(onSubmit)
    }
}
