import AppKit
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
    /// Whether the row can be set up and switched on. The phone channel is not,
    /// until the phone app ships: its row says so and offers no controls.
    public let available: Bool

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
    /// The channels the pane shows but does not let anyone set up or switch on
    /// yet. The phone channel waits for the Fermix phone app; until it ships,
    /// a switch that registered a listener nobody can pair with would be a
    /// control that does nothing.
    public static let unavailable: Set<String> = ["mobile"]

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
        titledBy sections: [ManagementSettingsSection],
        imessage: IMessageChannelFacts
    ) -> [ChannelRowModel] {
        let titles = Dictionary(
            sections.compactMap { section in section.channelName.map { ($0, section.title) } },
            uniquingKeysWith: { first, _ in first }
        )

        return channels.map { channel in
            ChannelRowModel(
                name: channel.name,
                title: titles[channel.name] ?? channel.name,
                status: status(of: channel, imessage: imessage),
                enabled: channel.enabled,
                configured: channel.configured,
                available: !unavailable.contains(channel.name)
            )
        }
    }

    /// A switched-on iMessage row reads the helper's probe and nothing else
    /// (M54 §10.1); every other row, and iMessage switched off, reads the
    /// snapshot's own two facts.
    static func status(of channel: ManagementSetupChannel, imessage: IMessageChannelFacts) -> String {
        guard channel.name == IMessageChannelStatus.channel, channel.enabled else { return status(of: channel) }

        return IMessageChannelStatus.status(imessage.probe, refusal: imessage.refusal)
    }

    static func status(of channel: ManagementSetupChannel) -> String {
        guard !unavailable.contains(channel.name) else { return ProductStrings[.channelStatusUnavailable] }
        guard channel.enabled else { return ProductStrings[.channelStatusOff] }
        guard channel.configured else { return ProductStrings[.channelStatusNeedsSetup] }

        return ProductStrings[.channelStatusConnected]
    }
}

/// What the iMessage row's status is read from: the helper's probe, and the
/// daemon's sentence for a confirmation it refused, both from the one ledger.
public struct IMessageChannelFacts: Equatable, Sendable {
    public let probe: SettingsReadState<ManagementIMessagePermissions>
    public let refusal: String?

    public init(probe: SettingsReadState<ManagementIMessagePermissions>, refusal: String?) {
        self.probe = probe
        self.refusal = refusal
    }

    /// Nothing read yet.
    public static let unanswered = IMessageChannelFacts(probe: .unread, refusal: nil)
}

/// The iMessage row's truthful status (M54 §10.1).
///
/// `imessage.permissions.get` is the single source: the row reads Connected
/// only when the helper is installed, Full Disk Access is granted, the
/// Messages database is readable, Automation is granted, the confirmed
/// recipients are exactly the saved ones, Messages is signed in and Fermix runs
/// in the logged-in session. Otherwise it names the first thing missing, in
/// that order, which is the order a person fixes them in.
public enum IMessageChannelStatus {
    /// The channel's wire identifier, as `setup.state.get` publishes it.
    public static let channel = "imessage"

    /// One thing the probe says is missing.
    public enum Gap: Equatable, Sendable {
        case helperNotInstalled
        case fullDiskAccess
        case messagesData
        case automation
        case confirmation
        case signIn
        case userSession

        var titleKey: ProductStringKey {
            switch self {
            case .helperNotInstalled: return .channelStatusHelperNotInstalled
            case .fullDiskAccess: return .channelStatusNeedsFullDiskAccess
            case .messagesData: return .channelStatusMessagesDataUnreadable
            case .automation: return .channelStatusNeedsMessagesAutomation
            case .confirmation: return .channelStatusAwaitingConfirmation
            case .signIn: return .channelStatusMessagesNotSignedIn
            case .userSession: return .channelStatusNeedsUserSession
            }
        }
    }

    /// The first gap, or nil where nothing is missing.
    public static func firstGap(in probe: ManagementIMessagePermissions) -> Gap? {
        guard probe.installed else { return .helperNotInstalled }
        guard probe.fullDiskAccess == .granted else { return .fullDiskAccess }
        guard probe.db == .readable else { return .messagesData }
        guard probe.automation == .granted else { return .automation }
        guard IMessageRights.recipientsConfirmed(probe) else { return .confirmation }
        guard probe.signedIn == true else { return .signIn }
        guard probe.userSession == true else { return .userSession }

        return nil
    }

    /// The row's status. With no answer the row claims nothing: it is checking,
    /// or it carries the daemon's own sentence for why the probe could not run.
    /// A refused confirmation is the daemon's sentence where "Awaiting
    /// confirmation" would stand, and never stands over an earlier gap.
    public static func status(
        _ probe: SettingsReadState<ManagementIMessagePermissions>,
        refusal: String?
    ) -> String {
        switch probe {
        case .loaded(let answer):
            return sentence(for: firstGap(in: answer), refusal: refusal)
        case .unavailable(let sentence):
            return sentence
        case .requiresNewerEngine:
            return ProductStrings[.daemonErrorRequiresNewerEngine]
        case .unread, .loading:
            return ProductStrings[.channelStatusChecking]
        }
    }

    private static func sentence(for gap: Gap?, refusal: String?) -> String {
        guard let gap else { return ProductStrings[.channelStatusConnected] }
        guard gap == .confirmation, let refusal else { return ProductStrings[gap.titleKey] }

        return refusal
    }
}

/// Channels: a hand-built list over daemon-supplied credential rows (M34 §5.2).
///
/// The list, the status words and the enable toggle are the app's, and the
/// iMessage row's status is projected from the helper's probe (M54 §10.1); every field
/// inside a channel's sheet comes from `settings.get {channels.<name>}` and
/// nothing is enumerated in Swift, which is what stops this pane and the browser
/// door from disagreeing about what a channel needs.
struct ChannelsPane: View {
    @ObservedObject var model: SettingsModel
    /// The one ledger, whose iMessage probe is the iMessage row's status.
    @ObservedObject var permissions: PermissionLedger
    /// The Fermix Messages install the iMessage switch runs before its write.
    /// Owned here rather than by the row, so it outlives the row scrolling out
    /// of view.
    @StateObject private var imessageInstall: JobRunner
    @State private var editing: ChannelRowModel?

    init(model: SettingsModel) {
        self.model = model
        self.permissions = model.permissions
        _imessageInstall = StateObject(wrappedValue: model.makeJobRunner())
    }

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
        // The probe never prompts. It is read once the daemon has said the
        // channel exists, and again on every return to the app, which is when
        // a person comes back from System Settings.
        .task(id: model.publishesIMessage) { await model.refreshIMessagePermissions() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refreshIMessagePermissions() }
        }
    }

    private var rows: [ChannelRowModel] {
        ChannelRowProjection.rows(
            model.setupState.value?.channels ?? [],
            titledBy: model.sections(for: .channels),
            imessage: IMessageChannelFacts(probe: permissions.imessage, refusal: permissions.imessageRefusal)
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
                ChannelRow(row: row, model: model, install: imessageInstall) { editing = row }
            }
        }
    }
}

/// One channel: its status, its switch, and the way into its credentials.
///
/// The iMessage row's switch installs Fermix Messages before its write
/// (M54 §10.2), so that row also draws the install's progress, its Cancel and
/// the daemon's sentence for a run that ended badly, as the Meetings switch
/// does.
struct ChannelRow: View {
    let row: ChannelRowModel
    @ObservedObject var model: SettingsModel
    @ObservedObject var install: JobRunner
    let edit: () -> Void

    var body: some View {
        if installsHelper {
            VStack(alignment: .leading, spacing: SettingsRowMetrics.captionGap) {
                content

                if install.isRunning || install.failure != nil {
                    installRun
                }
            }
        } else {
            content
        }
    }

    /// Whether this row's switch runs the helper install. Only iMessage's does.
    private var installsHelper: Bool { row.name == IMessageChannelStatus.channel }

    /// The install under the switch, with the one control that stops it.
    private var installRun: some View {
        HStack(spacing: Spacing.s) {
            JobProgress(runner: install)

            if install.isRunning {
                Spacer(minLength: 0)

                Button(ProductStrings[.settingsJobCancel]) {
                    Task { await install.cancelJob() }
                }
                .accessibilityLabel(ProductStrings.commaPair(ProductStrings[.settingsJobCancel], row.title))
            }
        }
    }

    private var content: some View {
        LabeledContent {
            HStack(spacing: Spacing.xs) {
                Text(row.status)
                    .foregroundStyle(Palette.secondary.color)

                if row.available {
                    Button(row.configured ? ProductStrings[.channelManage] : ProductStrings[.channelSetUp], action: edit)
                        .accessibilityLabel(ProductStrings.commaPair(ProductStrings[.channelSetUp], row.title))
                }

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
                    // banner that is already explaining why (M34 §7.6). Nor
                    // while the switch's own install runs.
                    .disabled(
                        !row.available || toggleRow == nil || model.writesBlocked
                            || (installsHelper && install.isRunning)
                    )
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
        .task {
            guard row.available else { return }
            await model.loadChannelSection(row.name)
        }
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
                guard !installsHelper else {
                    await model.setIMessageEnabled(isOn, on: install)
                    return
                }

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
            .showsAmbientGround()
            .rowActions()
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
        .onExitCommand(perform: escape)
        .task { await model.loadChannelSection(row.name) }
    }

    /// Escape, by the rule the settings window and the provider sheet follow
    /// (M34 §3.1). A field being edited owns it first, which now includes a
    /// secret typed in its own row: the half-typed value is dropped and the
    /// sheet stays, and only Escape with nothing being edited closes it.
    private func escape() {
        guard model.editingRow == nil else {
            model.revertEdit()
            return
        }

        dismiss()
    }
}
