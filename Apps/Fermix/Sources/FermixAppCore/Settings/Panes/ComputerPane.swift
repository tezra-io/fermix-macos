import SwiftUI

/// Computer: the daemon's own sections, the two rights the helper needs, and
/// the native application picker (M34 §5.5).
///
/// The permission rows read the one ledger, so this pane and Permissions cannot
/// disagree. Nothing here prompts on render: `Grant…` is an explicit action and
/// it runs as a job, because the dialogs it raises wait for a person.
struct ComputerPane: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var permissions: PermissionLedger
    @StateObject private var grant: JobRunner
    @State private var picking: PickerRequest?

    init(model: SettingsModel) {
        self.model = model
        self.permissions = model.permissions
        _grant = StateObject(wrappedValue: model.makeJobRunner())
    }

    var body: some View {
        SettingsPaneForm(title: SettingsPane.computer.title) {
            if model.requiresNewerEngine {
                NewerEngineSection(sentence: model.newerEngineSentence)
            } else {
                sections
                rights
            }
        }
        .sheet(item: $picking) { request in
            InstalledAppsSheet(request: request, model: model) { picking = nil }
        }
        // Through the model, so a refusal from the helper's probe records the
        // N-1 window here exactly as it does on Permissions.
        .task { await model.refreshPermissions() }
    }

    /// Every section the daemon assigned to this pane. The one specialisation is
    /// the list row, which this pane draws as a native picker: that is a
    /// pane-level choice of editor, not a second copy of the row's definition.
    @ViewBuilder
    private var sections: some View {
        ForEach(model.sections(for: .computer), id: \.id) { section in
            DescriptorSection(model: model, section: section) { row in
                guard case .list = row.kind else { return nil }

                return AnyView(
                    InstalledAppsRow(row: row, section: section.id, model: model) { request in
                        picking = request
                    }
                )
            }
        }
    }

    /// The helper's two rights, from the one ledger.
    @ViewBuilder
    private var rights: some View {
        Section(ProductStrings[.computerRightsSection]) {
            ForEach(helperRows) { row in
                PermissionRow(row: row, permissions: permissions, model: model, grant: grant)
            }

            JobRow(
                title: ProductStrings[.computerGrantTitle],
                actionTitle: ProductStrings[.computerGrantAction],
                kind: .computerUseGrant,
                runner: grant
            ) {
                await model.startComputerUseGrant(on: grant)
            }
        }
    }

    private var helperRows: [PermissionRowModel] {
        permissions.rows.filter { $0.right == .screenRecording || $0.right == .inputControl }
    }
}

/// The list row this pane draws itself: the count, and the way into the picker.
struct InstalledAppsRow: View {
    let row: ManagementSettingRow
    let section: String
    @ObservedObject var model: SettingsModel
    let present: (PickerRequest) -> Void

    var body: some View {
        LabeledContent(row.label) {
            HStack(spacing: Spacing.xs) {
                Text(String(format: ProductStrings[.computerAppsCountFormat], chosen.count))
                    .foregroundStyle(Palette.secondary.color)

                Button(ProductStrings[.computerAppsChoose]) {
                    present(PickerRequest(section: section, key: row.key, chosen: Set(chosen)))
                }
                .accessibilityLabel(ProductStrings.commaPair(ProductStrings[.computerAppsChoose], row.label))
            }
        }
    }

    private var chosen: [String] {
        DescriptorValue.list(model.value(of: row, in: section))
    }
}

/// Which row the picker is editing.
struct PickerRequest: Identifiable, Equatable {
    let section: String
    let key: String
    let chosen: Set<String>

    var id: String { "\(section)/\(key)" }
}

/// The native application picker (M34 §5.5).
///
/// The list is this Mac's, the write is the daemon's, and the default button
/// says how many are chosen and what the limit is, so an over-wide selection is
/// legible before the daemon refuses it.
struct InstalledAppsSheet: View {
    let request: PickerRequest
    @ObservedObject var model: SettingsModel
    let dismiss: () -> Void

    @State private var apps: [InstalledApp] = []
    @State private var selected: Set<String> = []
    @State private var query = ""

    /// Injected so a test never reads the operator's own `/Applications`.
    var source: any InstalledAppsEnumerating = SystemInstalledApps()

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text(ProductStrings[.computerAppsTitle])
                .fermixType(Typography.sheetTitle)
                .foregroundStyle(Palette.ink.color)

            TextField(
                ProductStrings[.computerAppsTitle],
                text: $query,
                prompt: Text(ProductStrings[.computerAppsSearchPrompt])
            )
            .labelsHidden()

            List(matching, id: \.id) { app in
                Toggle(app.name, isOn: binding(app))
            }
            .frame(maxHeight: .infinity)

            Text(InstalledAppsSelection.summary(selected))
                .fermixType(Typography.style(.calloutSmall))
                .foregroundStyle(Palette.secondary.color)

            HStack(spacing: Spacing.s) {
                Spacer(minLength: 0)

                Button(ProductStrings[.settingsSheetCancel], action: dismiss)
                    .keyboardShortcut(.cancelAction)

                Button(ProductStrings[.settingsSheetDone], action: commit)
                    .keyboardShortcut(.defaultAction)
                    // Done writes the list, and the daemon refuses a write while
                    // the settings file has changed outside Fermix (M34 §7.6):
                    // the sheet would otherwise close on a write that never
                    // happened.
                    .disabled(!InstalledAppsSelection.isSendable(selected) || model.writesBlocked)
            }
        }
        .padding(WindowMetrics.contentPadding)
        .frame(width: SheetMetrics.pickerSize.width, height: SheetMetrics.pickerSize.height)
        .onAppear {
            apps = source.installedApps()
            selected = request.chosen
        }
    }

    private var matching: [InstalledApp] {
        guard !query.isEmpty else { return apps }

        return apps.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private func binding(_ app: InstalledApp) -> Binding<Bool> {
        Binding(
            get: { selected.contains(app.bundleIdentifier) },
            set: { isOn in
                guard isOn else {
                    selected.remove(app.bundleIdentifier)
                    return
                }

                selected.insert(app.bundleIdentifier)
            }
        )
    }

    private func commit() {
        Task {
            await model.apply(
                section: request.section,
                key: request.key,
                value: .list(selected.sorted())
            )
            dismiss()
        }
    }
}
