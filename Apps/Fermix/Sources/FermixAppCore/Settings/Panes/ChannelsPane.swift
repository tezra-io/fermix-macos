import SwiftUI

/// One channel row: where it stands, and whether it can be switched on.
public struct ChannelRowModel: Identifiable, Equatable, Sendable {
    public let name: String
    /// The daemon's own spelling of this channel, from the section index. It is
    /// not derived from the wire identifier: raising the first letter of
    /// `whatsapp` produces `Whatsapp`, which sat beside WhatsApp's own mark
    /// once the official one shipped. The daemon already publishes `WhatsApp`
    /// under `channels.whatsapp`, and one spelling with one owner is the point.
    public let title: String
    public let status: String
    public let enabled: Bool
    public let configured: Bool

    public var id: String { name }
    public var accessibilityLabel: String { ProductStrings.commaPair(title, status) }
}

/// Turning `setup.state.get.channels` into rows (M34 §5.2).
public enum ChannelRowProjection {
    /// The answer key a channel's enable toggle writes.
    ///
    /// M34 §5.2 publishes the shape `<name>_enabled`, which is the contract's
    /// own spelling; it is written once here so no pane composes a key of its
    /// own, and a row that does not exist in the descriptor simply has no
    /// toggle rather than a write the daemon would refuse.
    public static func enabledKey(for channel: String) -> String {
        precondition(!channel.isEmpty, "a channel is named")

        return "\(channel)_enabled"
    }

    /// The section that holds a channel's credential rows.
    public static func sectionId(for channel: String) -> String {
        ManagementSettingsSection.channelPrefix + channel
    }

    /// The rows, titled by the daemon's own section index.
    ///
    /// A channel the daemon named in `setup.state` but published no section for
    /// shows its wire identifier, in the lower case the daemon wrote it: that
    /// is visibly the identifier rather than a spelling this app invented, and
    /// it is the only fact available when the two answers disagree.
    public static func rows(
        _ channels: [ManagementSetupChannel],
        titledBy sections: [ManagementSettingsSection]
    ) -> [ChannelRowModel] {
        let titles = Dictionary(
            sections.compactMap { section in section.channelName.map { ($0, section.title) } },
            uniquingKeysWith: { first, _ in first }
        )

        return channels.map { channel in
            ChannelRowModel(
                name: channel.name,
                title: titles[channel.name] ?? channel.name,
                status: status(of: channel),
                enabled: channel.enabled,
                configured: channel.configured
            )
        }
    }

    static func status(of channel: ManagementSetupChannel) -> String {
        guard channel.enabled else { return ProductStrings[.channelStatusOff] }
        guard channel.configured else { return ProductStrings[.channelStatusNeedsSetup] }

        return ProductStrings[.channelStatusConnected]
    }
}

/// Channels: a hand-built list over daemon-supplied credential rows (M34 §5.2).
///
/// The list, the status words and the enable toggle are the app's; every field
/// inside a channel's sheet comes from `settings.get {channels.<name>}` and
/// nothing is enumerated in Swift, which is what stops this pane and the browser
/// door from disagreeing about what a channel needs.
struct ChannelsPane: View {
    @ObservedObject var model: SettingsModel
    @State private var editing: ChannelRowModel?

    var body: some View {
        SettingsPaneForm(title: SettingsPane.channels.title) {
            if model.requiresNewerEngine {
                NewerEngineSection(sentence: model.newerEngineSentence)
            } else {
                channels
                DescriptorForm(model: model, sections: otherSections)
            }
        }
        .sheet(item: $editing) { row in
            ChannelSheet(row: row, model: model) { editing = nil }
        }
    }

    private var rows: [ChannelRowModel] {
        ChannelRowProjection.rows(
            model.setupState.value?.channels ?? [],
            titledBy: model.sections(for: .channels)
        )
    }

    /// Sections of this pane that are not one channel's credentials, which the
    /// list renders through its own sheet.
    private var otherSections: [ManagementSettingsSection] {
        model.sections(for: .channels).filter { $0.channelName == nil }
    }

    @ViewBuilder
    private var channels: some View {
        Section(ProductStrings[.settingsChannelsSection]) {
            ForEach(rows) { row in
                ChannelRow(row: row, model: model) { editing = row }
            }
        }
    }
}

/// One channel: its status, its switch, and the way into its credentials.
struct ChannelRow: View {
    let row: ChannelRowModel
    @ObservedObject var model: SettingsModel
    let edit: () -> Void

    var body: some View {
        LabeledContent {
            HStack(spacing: Spacing.xs) {
                Text(row.status)
                    .foregroundStyle(Palette.secondary.color)

                Button(row.configured ? ProductStrings[.channelManage] : ProductStrings[.channelSetUp], action: edit)
                    .accessibilityLabel(ProductStrings.commaPair(ProductStrings[.channelSetUp], row.title))

                // Stated, not inherited: a `Toggle` nested inside a row's
                // trailing content is outside the grouped form's own row
                // context, so it falls back to a checkbox while every other
                // on-off control in the app is a switch.
                Toggle(row.title, isOn: enabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    // Until the daemon has named the enable row, and never
                    // while writes are refused: the write path returns without
                    // writing, so the switch would flip and snap back under the
                    // banner that is already explaining why (M34 §7.6).
                    .disabled(toggleRow == nil || model.writesBlocked)
                    .accessibilityLabel(ProductStrings.commaPair(ProductStrings[.channelEnable], row.title))
            }
        } label: {
            HStack(spacing: Spacing.xs) {
                VendorMarkView(
                    mark: VendorMarks.mark(.channel, row.name),
                    kind: .channel,
                    size: SettingsRowMetrics.markSize
                )

                Text(row.title)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(row.accessibilityLabel)
        }
        .task { await model.loadChannelSection(row.name) }
    }

    /// The descriptor's own enable row. Absent until the channel's section has
    /// been read, which is why the switch is disabled rather than guessing.
    private var toggleRow: ManagementSettingRow? {
        let section = ChannelRowProjection.sectionId(for: row.name)
        let key = ChannelRowProjection.enabledKey(for: row.name)

        return model.section(section).value?.rows.first { $0.key == key && $0.kind == .toggle }
    }

    private var enabled: Binding<Bool> {
        Binding(get: { row.enabled }, set: { isOn in
            guard let toggleRow else { return }

            Task {
                await model.apply(
                    section: ChannelRowProjection.sectionId(for: row.name),
                    key: toggleRow.key,
                    value: .flag(isOn)
                )
            }
        })
    }
}

/// A channel's credentials, from its own descriptor section.
///
/// Secret rows first and plain fields after, which is the order M34 §5.2 asks
/// for; the rows themselves, their labels and their footers are the daemon's.
///
/// The sheet's primary is `Done` rather than §5.2's `Enable Telegram`: the quirk
/// that verb exists to fix — a token silently flipping `enabled` — is fixed on
/// the row instead, where the enable switch is the daemon's own toggle row and
/// pausing a channel is not deleting it. Two ways to answer the same key would
/// be the second path, so the enable row is filtered out of this sheet and the
/// footer names the switch that is left to throw. The `How to get this` link §5.2 also names is not built:
/// no field on the wire carries a per-channel help URL, and inventing one here
/// would be app-authored vocabulary for a surface §5.2 keeps daemon-supplied.
struct ChannelSheet: View {
    let row: ChannelRowModel
    @ObservedObject var model: SettingsModel
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text(row.title)
                .fermixType(Typography.sheetTitle)
                .foregroundStyle(Palette.ink.color)

            // The same grouped form the pane draws, so a row does not change
            // shape between the list and the sheet.
            Form {
                Section {
                    DescriptorRows(
                        model: model,
                        section: ChannelRowProjection.sectionId(for: row.name),
                        // The switch lives on the list row. Drawn here as well,
                        // one key had two controls in two places, which is the
                        // duplication this file's own rule forbids.
                        excluding: [ChannelRowProjection.enabledKey(for: row.name)]
                    )
                } footer: {
                    Text(ProductStrings[.channelSheetFooter])
                        .fermixType(Typography.style(.calloutSmall))
                        .foregroundStyle(Palette.secondary.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: Spacing.s) {
                Spacer(minLength: 0)

                // One button. Every field commits as it is edited, so a
                // `Cancel` beside it would promise an undo the sheet cannot
                // give: leaving is the whole of finishing.
                Button(ProductStrings[.settingsSheetDone], action: dismiss)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(WindowMetrics.contentPadding)
        .frame(width: SheetMetrics.credentialWidth)
        .onExitCommand(perform: dismiss)
        .task { await model.loadChannelSection(row.name) }
    }
}
