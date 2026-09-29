import AppKit
import SwiftUI

/// A model row typed with matching (owner, 2026-09-28: "no second popup for
/// the model, pattern matching in the same dropdown"). The field takes any
/// model the provider serves, and its one dropdown lists the daemon's
/// suggestions until something is typed, then the models the daemon's
/// listing matches to what was typed. It commits and reverts as a text row
/// does: on Enter, on losing focus, on the row going away, and Escape puts
/// the daemon's value back.
struct ModelTypeaheadRow: View {
    let row: ManagementSettingRow
    let section: String
    @ObservedObject var model: SettingsModel
    @StateObject private var matches: ModelMatches

    /// - Parameter provider: whose listing answers what is typed. A
    ///   descriptor row names a model and never the provider that serves it,
    ///   so the surface that knows says.
    init(row: ManagementSettingRow, section: String, provider: String, model: SettingsModel) {
        precondition(row.modelRowForm == .typeahead, "a typed model row has suggestions")
        self.row = row
        self.section = section
        _model = ObservedObject(wrappedValue: model)
        _matches = StateObject(wrappedValue: ModelMatches(
            suggestions: row.options.map(\.value),
            listing: { query in await model.models(provider: provider, live: true, query: query, cursor: nil) }
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsRowMetrics.captionGap) {
            LabeledContent {
                ModelComboBox(
                    label: row.label,
                    prompt: row.emptyValuePrompt,
                    value: value,
                    items: matches.items,
                    reverts: model.editReverts,
                    edited: { typed in matches.search(typed) },
                    began: { model.beginEditing(key) },
                    chosen: { item in submit(item) },
                    ended: { typed in
                        model.endEditing(key)
                        submit(typed)
                    }
                )
            } label: {
                DescriptorRowLabel(row.label, info: row.explanation)
            }
            if let footer = row.footer, !footer.isEmpty {
                Text(footer)
                    .fermixType(Typography.style(.calloutSmall))
                    .foregroundStyle(Palette.secondary.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let refusal = model.message(for: key) {
                Text(refusal)
                    .fermixType(Typography.style(.calloutSmall))
                    .foregroundStyle(Palette.warning.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .disabled(model.writesBlocked)
    }

    private var key: SettingsDraftKey { SettingsDraftKey(section: section, key: row.key) }
    private var value: String { DescriptorValue.text(model.value(of: row, in: section)) }

    /// The shared settings writer normalizes empty text; an unchanged value is
    /// not written.
    private func submit(_ typed: String) {
        guard let change = DescriptorTextDraft(text: typed).submission(comparedTo: value) else { return }
        Task { await model.apply(section: section, key: row.key, value: change) }
    }
}

/// What the dropdown lists: the daemon's suggestions while nothing is typed,
/// and the models its listing matches to what was typed, asked once the
/// typing has paused. A newer query supersedes an older one, and a refusal
/// leaves the last list standing rather than emptying the dropdown.
@MainActor
final class ModelMatches: ObservableObject {
    @Published private(set) var items: [String]

    private let suggestions: [String]
    private let listing: (String) async -> ModelListingOutcome
    private let debounce: Duration
    private var pending: Task<Void, Never>?

    init(
        suggestions: [String],
        debounce: Duration = .milliseconds(250),
        listing: @escaping (String) async -> ModelListingOutcome
    ) {
        self.suggestions = suggestions
        self.debounce = debounce
        self.listing = listing
        items = suggestions
    }

    func search(_ typed: String) {
        pending?.cancel()
        let query = typed.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            pending = nil
            items = suggestions
            return
        }
        pending = Task { [weak self, debounce, listing] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            let outcome = await listing(query)
            guard !Task.isCancelled, let self else { return }
            if case .page(let page) = outcome {
                self.items = page.models.map(\.id)
            }
        }
    }

    /// Waits for the query in flight, for a test that asked and wants the answer.
    func settle() async {
        await pending?.value
    }
}

/// The system's combo box, which is the one macOS control that types, matches
/// as it is typed and drops down a list: `completes` finishes what is typed
/// from the items, and the items are `ModelMatches`'s.
struct ModelComboBox: NSViewRepresentable {
    let label: String
    let prompt: String
    let value: String
    let items: [String]
    /// The settings model's revert count. A change while the field is being
    /// edited puts `value` back and ends the edit, as Escape on a text row does.
    let reverts: Int
    let edited: (String) -> Void
    let began: () -> Void
    let chosen: (String) -> Void
    let ended: (String) -> Void

    func makeNSView(context: Context) -> NSComboBox {
        let box = NSComboBox()
        box.completes = true
        box.isEditable = true
        box.numberOfVisibleItems = 10
        box.placeholderString = prompt
        box.stringValue = value
        box.delegate = context.coordinator
        box.setAccessibilityLabel(label)
        box.setContentHuggingPriority(.defaultLow, for: .horizontal)
        box.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return box
    }

    func updateNSView(_ box: NSComboBox, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        if coordinator.items != items {
            coordinator.items = items
            box.removeAllItems()
            box.addItems(withObjectValues: items)
        }
        if !coordinator.editing, box.stringValue != value {
            box.stringValue = value
        }
        if coordinator.reverts != reverts {
            coordinator.reverts = reverts
            if coordinator.editing {
                box.stringValue = value
                box.window?.makeFirstResponder(nil)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, NSComboBoxDelegate {
        var parent: ModelComboBox
        var items: [String] = []
        var editing = false
        var reverts: Int

        init(parent: ModelComboBox) {
            self.parent = parent
            reverts = parent.reverts
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            editing = true
            parent.began()
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let box = notification.object as? NSComboBox else { return }
            parent.edited(box.stringValue)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard editing, let box = notification.object as? NSComboBox else { return }
            editing = false
            parent.ended(box.stringValue)
        }

        /// A pick from the dropdown is the value, written at once; typing on
        /// after it is a new edit that the field's end commits.
        func comboBoxSelectionDidChange(_ notification: Notification) {
            guard let box = notification.object as? NSComboBox,
                  let item = box.objectValueOfSelectedItem as? String else { return }
            box.stringValue = item
            parent.chosen(item)
        }

        /// Escape puts the daemon's value back and ends the edit, which the
        /// end then finds nothing to write for (M34 §3.1).
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
            control.stringValue = parent.value
            control.window?.makeFirstResponder(nil)
            return true
        }
    }
}
