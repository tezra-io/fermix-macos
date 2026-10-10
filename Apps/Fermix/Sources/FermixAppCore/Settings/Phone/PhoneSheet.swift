import SwiftUI

/// The Phone sheet (M60 §3.3).
///
/// One sheet at the width every credential sheet has, titled with the daemon's
/// section title, that changes in place: each step is drawn inside it and none
/// is a sheet of its own. It raises nothing over itself, no alert, no
/// popover and no second sheet.
///
/// A step's one primary action is the monochrome capsule and takes Return.
/// Compare has none: Approve and Deny are drawn alike and neither takes Return,
/// so Return approves nothing (decision 7).
struct PhoneSheet: View {
    @ObservedObject var model: PhonePairingModel
    @ObservedObject var settings: SettingsModel
    let title: String

    /// Where VoiceOver goes when the step changes: the new step's heading (§7).
    @AccessibilityFocusState private var headingFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text(title)
                .fermixType(Typography.sheetTitle)
                .foregroundStyle(Palette.ink.color)

            step
        }
        .padding(WindowMetrics.contentPadding)
        .frame(width: SheetMetrics.credentialWidth)
        .onExitCommand(perform: escape)
        // Every way out arrives here, Cancel, Done, Escape and the window
        // closing alike, so the window the sheet was showing is cancelled
        // whichever one it was.
        .onDisappear { model.closed() }
        .onChange(of: PhoneStepKind(model.step)) { headingFocused = true }
    }

    @ViewBuilder
    private var step: some View {
        switch model.step {
        case .waiting:
            PhoneWaitingStep()
        case .turnOn(let turnOn):
            PhoneTurnOnStep(
                turnOn: turnOn,
                settings: settings,
                heading: $headingFocused,
                cancel: model.dismiss,
                act: model.turnOn
            )
        case .scan(let scan):
            PhoneScanStep(scan: scan, heading: $headingFocused, cancel: model.dismiss)
        case .compare(let compare):
            PhoneCompareStep(
                compare: compare,
                deciding: model.isDeciding,
                heading: $headingFocused,
                deny: model.deny,
                approve: model.approve
            )
        case .paired(let name):
            PhonePairedStep(name: name, heading: $headingFocused, done: model.showPhones)
        case .ended(let ending):
            PhoneEndedStep(ending: ending, heading: $headingFocused, done: model.dismiss, act: model.takeEndingAction)
        case .phones:
            PhonePhonesStep(model: model, settings: settings, done: model.dismiss)
        }
    }

    /// Escape, by the rule every settings sheet follows (M34 §3.1): a field
    /// being edited owns it first, and only Escape with nothing being edited
    /// closes the sheet.
    private func escape() {
        guard settings.editingRow == nil else {
            settings.revertEdit()
            return
        }

        model.dismiss()
    }
}

/// Which step is showing, apart from what it carries: a countdown that moves
/// is not a new step, and VoiceOver stays where it is.
private enum PhoneStepKind: Equatable {
    case waiting, turnOn, scan, compare, paired, ended, phones

    init(_ step: PhoneSheetStep) {
        switch step {
        case .waiting: self = .waiting
        case .turnOn: self = .turnOn
        case .scan: self = .scan
        case .compare: self = .compare
        case .paired: self = .paired
        case .ended: self = .ended
        case .phones: self = .phones
        }
    }
}

/// The trailing row of a step's buttons, where macOS puts them.
private struct PhoneButtons<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: Spacing.s) {
            Spacer(minLength: 0)

            content
        }
    }
}

/// A step's lead line, which is the heading VoiceOver is moved to.
private struct PhoneLead: View {
    let text: String
    let heading: AccessibilityFocusState<Bool>.Binding

    var body: some View {
        Text(text)
            .fermixType(Typography.style(.bodyCompact))
            .foregroundStyle(Palette.ink.color)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
            .accessibilityFocused(heading)
    }
}

/// A line the daemon or the app adds under a lead, in the secondary colour.
private struct PhoneNote: View {
    let text: String

    var body: some View {
        Text(text)
            .fermixType(Typography.style(.calloutSmall))
            .foregroundStyle(Palette.secondary.color)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Waiting on the daemon: reading the channel, or opening a window.
private struct PhoneWaitingStep: View {
    var body: some View {
        ProgressView()
            .controlSize(.small)
            .frame(maxWidth: .infinity, minHeight: HitTarget.button)
            .accessibilityHidden(true)
    }
}

/// Turn on: shown while the channel is not running (§3.3). What the switch
/// does, in the daemon's own footer for it; what a restart would interrupt,
/// as the Restart sheet says it; and the one button that says it restarts.
private struct PhoneTurnOnStep: View {
    let turnOn: PhoneTurnOn
    @ObservedObject var settings: SettingsModel
    let heading: AccessibilityFocusState<Bool>.Binding
    let cancel: () -> Void
    let act: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            if let footer {
                PhoneLead(text: footer, heading: heading)
            }

            RestartInFlightLine(count: settings.conversationsInFlight)
            progress

            if let refusal = turnOn.refusal {
                Text(refusal)
                    .fermixType(Typography.style(.calloutSmall))
                    .foregroundStyle(Palette.warning.color)
                    .fixedSize(horizontal: false, vertical: true)
            }

            PhoneButtons {
                Button(ProductStrings[.settingsSheetCancel], action: cancel)
                    .buttonStyle(SecondaryButtonStyle(.row))

                PrimaryAction(ProductStrings[turnOn.actionKey], size: .row, action: act)
                    .disabled(turnOn.progress != .idle)
            }
        }
        .task {
            await settings.loadChannelSection(PhoneChannel.name)
            await settings.readConversationsInFlight()
        }
    }

    /// The daemon's own footer for the channel's switch.
    private var footer: String? {
        settings.section(PhoneChannel.section).value?.rows
            .first { $0.key == PhoneChannel.switchKey }?
            .footer
    }

    @ViewBuilder
    private var progress: some View {
        switch turnOn.progress {
        case .idle:
            EmptyView()
        case .applying:
            ProgressView()
                .controlSize(.small)
                .accessibilityHidden(true)
        case .restarting:
            HStack(spacing: Spacing.xs) {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)

                Text(ProductStrings[.lifecycleRestarting])
                    .fermixType(Typography.style(.calloutSmall))
                    .foregroundStyle(Palette.secondary.color)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.updatesFrequently)
        }
    }
}

/// Scan: the code on its card, the one line, and the daemon's own countdown.
///
/// The window is left out of screen sharing and recordings for as long as
/// this step is on screen (decision 5). For a phone or an emulator that cannot
/// scan, "Can't scan the code?" shows the link itself, with Copy; a copy is
/// taken back off the pasteboard when Scan leaves, however the window ended.
private struct PhoneScanStep: View {
    let scan: PhoneScan
    let heading: AccessibilityFocusState<Bool>.Binding
    let cancel: () -> Void

    private let announcer: any AccessibilityAnnouncing = AppKitAccessibilityAnnouncer()
    @State private var showsLink = false
    /// The pasteboard's change count from this step's copy, while it has one.
    @State private var copied: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            PhoneLead(text: ProductStrings[.phoneScanLine], heading: heading)

            PairingCodeCard(code: scan.code)
                .frame(maxWidth: .infinity)

            Text(countdown)
                .fermixType(Typography.style(.calloutSmall))
                .foregroundStyle(Palette.secondary.color)
                .monospacedDigit()
                .frame(maxWidth: .infinity)

            if showsLink {
                PhoneLinkRow(link: scan.link.text, copy: copy)
            } else {
                Button(ProductStrings[.phoneScanCantScan]) { showsLink = true }
                    .buttonStyle(.link)
            }

            PhoneButtons {
                Button(ProductStrings[.settingsSheetCancel], action: cancel)
                    .buttonStyle(SecondaryButtonStyle(.row))
            }
        }
        .background(ScreenCaptureExclusion())
        // The countdown is spoken when Scan appears and once more at the last
        // ten seconds, never every second (§7).
        .onAppear { announcer.announce(countdown) }
        .onChange(of: PhoneWording.isFinalCountdown(ttlMs: scan.ttlMs)) { _, final in
            guard final else { return }

            announcer.announce(countdown)
        }
        .onDisappear(perform: withdrawCopy)
    }

    private var countdown: String { PhoneWording.countdown(ttlMs: scan.ttlMs) }

    private func copy() {
        copied = Clipboard.writeSecret(scan.link.text)
    }

    private func withdrawCopy() {
        guard let copied else { return }

        Clipboard.withdraw(copied)
        self.copied = nil
    }
}

/// The pairing link as text, selectable, with Copy: the command row the
/// coexistence instructions draw, held to three lines, since a long link
/// would otherwise make the sheet scroll.
private struct PhoneLinkRow: View {
    let link: String
    let copy: () -> Void

    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.s) {
            Text(link)
                .fermixType(Typography.style(.mono))
                .foregroundStyle(Palette.ink.color)
                .lineLimit(3)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(ProductStrings[.phoneScanLinkLabel])

            Button(ProductStrings[.phoneScanCopyLink], action: copy)
                .buttonStyle(SecondaryButtonStyle(.row))
        }
        .padding(.horizontal, Spacing.s)
        .padding(.vertical, Spacing.xs)
        .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Palette.cardFill.color))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(
                Palette.hairline(.standard, increaseContrast: contrast == .increased).color,
                lineWidth: 1
            )
        )
    }
}

/// Compare: the phone, its six digits large and grouped as the phone draws
/// them, and the decision, with neither answer the default.
private struct PhoneCompareStep: View {
    let compare: PhoneCompare
    let deciding: Bool
    let heading: AccessibilityFocusState<Bool>.Binding
    let deny: () -> Void
    let approve: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                PhoneLead(
                    text: String(format: ProductStrings[.phoneCompareHeadingFormat], compare.deviceName),
                    heading: heading
                )

                PhoneNote(text: compare.model)
            }

            Text(PhoneWording.grouped(compare.digits))
                .fermixType(Typography.style(.display))
                .monospacedDigit()
                .foregroundStyle(Palette.ink.color)
                .frame(maxWidth: .infinity)
                .accessibilityLabel(PhoneWording.spoken(compare.digits, from: compare.deviceName))

            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(ProductStrings[.phoneCompareLine])
                    .fermixType(Typography.style(.bodyCompact))
                    .foregroundStyle(Palette.ink.color)
                    .fixedSize(horizontal: false, vertical: true)

                // The daemon's own words about the phone's hardware, as
                // written.
                PhoneNote(text: compare.hardware)
            }

            PhoneButtons {
                Button(ProductStrings[.phoneCompareDeny], action: deny)
                    .buttonStyle(SecondaryButtonStyle(.row))

                Button(ProductStrings[.phoneCompareApprove], action: approve)
                    .buttonStyle(SecondaryButtonStyle(.row))
            }
            .disabled(deciding)
        }
    }
}

/// Phones: each paired phone with Forget asked in its own row, Pair another
/// phone under them, then the channel's connection rows exactly as the daemon
/// publishes them, drawn by the one descriptor renderer (§3.3). The switch
/// stays on the Channels row, so it is not drawn twice.
private struct PhonePhonesStep: View {
    @ObservedObject var model: PhonePairingModel
    @ObservedObject var settings: SettingsModel
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            // The same grouped form the pane draws, so a row does not change
            // shape between the pane and the sheet.
            Form {
                Section {
                    phones

                    Button(ProductStrings[pairTitle], action: model.pairAnother)
                        .disabled(model.forgetting.forgetting != nil)
                }

                Section {
                    DescriptorRows(
                        model: settings,
                        section: PhoneChannel.section,
                        excluding: [PhoneChannel.switchKey]
                    )
                }
            }
            .formStyle(.grouped)
            .showsAmbientGround()
            .rowActions()
            .fixedSize(horizontal: false, vertical: true)

            PhoneButtons {
                PrimaryAction(ProductStrings[.settingsSheetDone], size: .row, action: done)
            }
        }
        .task { await settings.loadChannelSection(PhoneChannel.name) }
    }

    @ViewBuilder
    private var phones: some View {
        switch model.devices {
        case .loaded(let answer):
            ForEach(answer.devices, id: \.deviceId) { device in
                PhoneDeviceRow(
                    device: device,
                    forgetting: model.forgetting,
                    ask: { model.askToForget(device.deviceId) },
                    withdraw: model.withdrawForget,
                    forget: model.forget
                )
            }
        case .unread, .loading:
            ProgressView()
                .controlSize(.small)
                .accessibilityHidden(true)
        case .requiresNewerEngine:
            PhoneNote(text: ProductStrings[.daemonErrorRequiresNewerEngine])
        case .unavailable(let sentence):
            PhoneNote(text: sentence)
        }
    }

    /// Another phone once one is paired, and a phone while none is.
    private var pairTitle: ProductStringKey {
        model.devices.value?.devices.isEmpty == false ? .phonePairAnother : .phonePair
    }
}

/// One paired phone: its name, its model and when it was last seen, and
/// Forget, which asks in the row before it forgets anything.
private struct PhoneDeviceRow: View {
    let device: ManagementMobileDevice
    let forgetting: PhoneForgetting
    let ask: () -> Void
    let withdraw: () -> Void
    let forget: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsRowMetrics.captionGap) {
            LabeledContent {
                HStack(spacing: Spacing.xs) {
                    if forgetting.asking == device.deviceId {
                        Button(ProductStrings[.phoneForgetConfirm], action: forget)
                            .accessibilityLabel(ProductStrings.commaPair(ProductStrings[.phoneForgetConfirm], device.name))

                        Button(ProductStrings[.settingsSheetCancel], action: withdraw)
                    } else {
                        Button(ProductStrings[.phoneForget], action: ask)
                            .accessibilityLabel(ProductStrings.commaPair(ProductStrings[.phoneForget], device.name))
                    }
                }
                .disabled(forgetting.forgetting != nil)
            } label: {
                VStack(alignment: .leading, spacing: SettingsRowMetrics.captionGap) {
                    Text(device.name)

                    Text(detail)
                        .fermixType(Typography.style(.calloutSmall))
                        .foregroundStyle(Palette.secondary.color)
                }
            }

            if let refusal = forgetting.refusals[device.deviceId] {
                Text(refusal)
                    .fermixType(Typography.style(.calloutSmall))
                    .foregroundStyle(Palette.warning.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The model, and when the phone was last seen where the daemon says so.
    private var detail: String {
        guard let seen = PhoneWording.seen(device.lastSeen, now: Date()) else { return device.model }

        return ProductStrings.middot(device.model, seen)
    }
}

/// Paired: the phone's name, and Done, which goes on to the phones.
private struct PhonePairedStep: View {
    let name: String
    let heading: AccessibilityFocusState<Bool>.Binding
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            PhoneLead(text: String(format: ProductStrings[.phonePairedFormat], name), heading: heading)

            PhoneButtons {
                PrimaryAction(ProductStrings[.settingsSheetDone], size: .row, action: done)
            }
        }
    }
}

/// Ended: one sentence, and the one way on.
private struct PhoneEndedStep: View {
    let ending: PhoneEnding
    let heading: AccessibilityFocusState<Bool>.Binding
    let done: () -> Void
    let act: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            PhoneLead(text: ending.sentence, heading: heading)

            PhoneButtons {
                Button(ProductStrings[.settingsSheetDone], action: done)
                    .buttonStyle(SecondaryButtonStyle(.row))

                PrimaryAction(ProductStrings[ending.actionKey], size: .row, action: act)
            }
        }
    }
}
