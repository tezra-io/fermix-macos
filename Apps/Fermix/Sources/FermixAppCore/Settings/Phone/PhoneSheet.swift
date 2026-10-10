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
        case .turnOn, .phones:
            // Not reached: pairing opens straight onto the window, and the
            // phones row changes the channel's connection rows.
            EmptyView()
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
            PhonePairedStep(name: name, heading: $headingFocused, done: model.dismiss)
        case .ended(let ending):
            PhoneEndedStep(ending: ending, heading: $headingFocused, done: model.dismiss, act: model.takeEndingAction)
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

/// Scan: the code on its card, the one line, and the daemon's own countdown.
///
/// The window is left out of screen sharing and recordings for as long as
/// this step is on screen (decision 5).
private struct PhoneScanStep: View {
    let scan: PhoneScan
    let heading: AccessibilityFocusState<Bool>.Binding
    let cancel: () -> Void

    private let announcer: any AccessibilityAnnouncing = AppKitAccessibilityAnnouncer()

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
    }

    private var countdown: String { PhoneWording.countdown(ttlMs: scan.ttlMs) }
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

/// Paired: the phone's name, and Done.
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
