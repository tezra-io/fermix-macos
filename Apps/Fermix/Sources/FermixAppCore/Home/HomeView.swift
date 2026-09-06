import SwiftUI

/// Home: status and controls in one native grouped form.
///
/// The artboard's hero card and section cards are not drawn: every box here is
/// a `Form` section the system draws. Every row is derived from `hello`,
/// `overview.get` and `setup.state.get`, so nothing can show a gap the daemon
/// did not report.
struct HomeView: View {
    @ObservedObject var model: HomeModel
    /// The one settings model, which is what the Restart sheet reads: the
    /// daemon's own reasons and the count of work a restart would interrupt.
    @ObservedObject var settings: SettingsModel
    let router: any CommandPerforming

    var body: some View {
        Form {
            background
            attention
            runtime
        }
        .formStyle(.grouped)
        .navigationTitle(ProductStrings[.sidebarHome])
        .toolbar {
            SurfaceToolbar(
                spec: CommandTable.toolbar(for: .home, condition: model.toolbarCondition),
                router: router
            )
        }
        .task { await model.refresh() }
    }

    /// Two registrations and one way in, all independent of each other. M34 §4:
    /// the durable state is the registration, so the wording is enable or
    /// disable and never start or stop.
    private var background: some View {
        Section(ProductStrings[.sectionHeaderBackground]) {
            LabeledContent(ProductStrings[.homeStatusLabel]) {
                Text(model.snapshot.statusTitle)
                    .foregroundStyle(Palette.secondary.color)
                    .accessibilityAddTraits(.updatesFrequently)
            }

            Toggle(
                ProductStrings[.homeRunInBackground],
                isOn: Binding(
                    get: { model.backgroundServiceEnabled },
                    set: { model.setBackgroundService($0) }
                )
            )
            .disabled(model.transactionInFlight)

            Toggle(
                ProductStrings[.homeOpenAtLogin],
                isOn: Binding(
                    get: { model.openAtLogin },
                    set: { model.setOpenAtLogin($0) }
                )
            )

            // A way in rather than a registration: hiding the item stops
            // nothing, and reopening Fermix from the Dock brings the window
            // back whether it is on the bar or not.
            Toggle(
                ProductStrings[.homeShowInMenuBar],
                isOn: Binding(
                    get: { model.menuBarItemShown },
                    set: { model.setMenuBarItemShown($0) }
                )
            )

            // The sentence the status item's own hint row also carries. With
            // the item off the bar and no window on screen this app has no
            // Dock tile, so how to get it back has to be written down.
            Text(ProductStrings[.statusMenuHideHint])
                .fermixType(Typography.style(.calloutSmall))
                .foregroundStyle(Palette.secondary.color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var attention: some View {
        Section(ProductStrings[.sectionHeaderAttention]) {
            let rows = model.snapshot.attention.displayRows

            if rows.isEmpty {
                EmptyState(model: model.snapshot.attentionEmpty)
            } else {
                ForEach(rows) { row in
                    AttentionRowView(row: row) { model.perform($0) }
                }
            }

            if let message = model.actionMessage {
                Text(message)
                    .fermixType(Typography.style(.calloutSmall))
                    .foregroundStyle(Palette.warning.color)
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
    }

    @ViewBuilder
    private var runtime: some View {
        Section(ProductStrings[.sectionHeaderRuntime]) {
            if model.snapshot.runtime.isEmpty {
                EmptyState(model: model.snapshot.runtimeEmpty)
            } else {
                ForEach(model.snapshot.runtime) { row in
                    LabeledContent {
                        Text(row.detail)
                            .foregroundStyle(Palette.secondary.color)
                    } label: {
                        Text(row.title)
                    }
                }
            }
        }
    }
}

/// One Attention row: what the gap is, what it means, and at most one thing to
/// do about it.
struct AttentionRowView: View {
    let row: AttentionRow
    let perform: (AttentionAction) -> Void

    var body: some View {
        LabeledContent {
            if let action = row.action {
                Button(action.title) { perform(action) }
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)

                if !row.body.isEmpty {
                    Text(row.body)
                        .fermixType(Typography.style(.calloutSmall))
                        .foregroundStyle(Palette.secondary.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
