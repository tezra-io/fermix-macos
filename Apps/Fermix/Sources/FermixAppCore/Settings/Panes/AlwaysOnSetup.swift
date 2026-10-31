import SwiftUI

/// Moving the primary to a server (M75 §7, design §11): one section whose
/// content is the step the daemon's picture puts it at, beside the code this
/// pane holds and the move it asked for. On a desktop the same steps replace
/// the server, drawn from the server's own picture and reached through it.
struct AlwaysOnSetupSection: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var alwaysOn: AlwaysOnModel

    var body: some View {
        if let step = alwaysOn.setupStep {
            Section {
                if let picture = alwaysOn.setupPicture, let undone = AlwaysOnSetupStep.undoneMove(picture) {
                    CueStatusLine(text: undone, tone: .warn, attention: true)
                }
                if let notice = alwaysOn.moveNotice {
                    CueStatusLine(text: notice, tone: .neutral)
                }

                content(step)
            } header: {
                CuesSectionHeader(title: title(step), action: nil) {}
            }
        }
    }

    @ViewBuilder
    private func content(_ step: AlwaysOnSetupStep) -> some View {
        switch step {
        case .choose:
            if alwaysOn.replacesServer {
                AlwaysOnReplaceExplanation()
            }
            AlwaysOnChooseStep(alwaysOn: alwaysOn)
        case .code(let handout):
            AlwaysOnCodeStep(model: model, alwaysOn: alwaysOn, handout: handout)
        case .waiting:
            AlwaysOnWaitingLine(alwaysOn: alwaysOn)
            AlwaysOnNewCodeControl(alwaysOn: alwaysOn)
        case .review(let candidates):
            ForEach(candidates, id: \.candidateId) { candidate in
                AlwaysOnCandidateBlock(alwaysOn: alwaysOn, candidate: candidate)
            }
        case .moving(let move):
            AlwaysOnProgressLine(text: move.sentence)
            checkAgain
        case .restarting:
            AlwaysOnProgressLine(
                text: ProductStrings[alwaysOn.replacesServer ? .alwaysOnReplaceUnderWay : .alwaysOnMoveRestarting]
            )
            checkAgain
        }
    }

    /// A move the follow stopped watching before it ended: the way to watch
    /// it again.
    @ViewBuilder
    private var checkAgain: some View {
        if alwaysOn.followStopped {
            Button(ProductStrings[.alwaysOnWaitCheckAgain]) { alwaysOn.followAgain() }
                .buttonStyle(SecondaryButtonStyle(.row))
        }
    }

    private func title(_ step: AlwaysOnSetupStep) -> ProductStringKey {
        switch step {
        case .moving, .restarting: return .alwaysOnMoveTitle
        case .choose, .code, .waiting, .review: return alwaysOn.replacesServer ? .alwaysOnReplaceTitle : .alwaysOnSetupTitle
        }
    }
}

/// Where the server runs, and Get a code.
struct AlwaysOnChooseStep: View {
    @ObservedObject var alwaysOn: AlwaysOnModel

    var body: some View {
        Picker(ProductStrings[.alwaysOnSetupWhere], selection: $alwaysOn.destination) {
            ForEach(AlwaysOnDestination.allCases) { destination in
                Text(ProductStrings[destination.titleKey]).tag(destination)
            }
        }
        .pickerStyle(.radioGroup)

        HStack(spacing: Spacing.s) {
            Spacer(minLength: 0)
            PrimaryAction(ProductStrings[.alwaysOnSetupGetCode], size: .row) {
                Task { await alwaysOn.openEnrollment() }
            }
            .disabled(alwaysOn.isOpeningEnrollment)
        }

        if let refusal = alwaysOn.enrollRefusal {
            CueNote(text: refusal, attention: true)
        }
    }
}

/// The code, once, then what to do with it where the server runs, and the
/// wait for the server to check in.
struct AlwaysOnCodeStep: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var alwaysOn: AlwaysOnModel
    let handout: EnrollmentHandout

    @State private var guideRefusal: String?

    var body: some View {
        AlwaysOnCodeBlock(handout: handout)

        switch alwaysOn.destination {
        case .aws:
            CueNote(text: ProductStrings[.alwaysOnAWSSteps])
            Button(ProductStrings[.alwaysOnAWSOpenGuide]) { guideRefusal = model.openAlwaysOnGuide() }
                .buttonStyle(SecondaryButtonStyle(.row))
            if let guideRefusal {
                CueNote(text: guideRefusal, attention: true)
            }
        case .existingHost:
            CueNote(text: ProductStrings[.alwaysOnHostSteps])
            AlwaysOnCommandBlock()
        }

        AlwaysOnWaitingLine(alwaysOn: alwaysOn)
        AlwaysOnNewCodeControl(alwaysOn: alwaysOn)
    }
}

/// The enrollment code, shown once (§7.1): in a monospaced block that is not
/// selectable and is never an accessibility value, with Copy code and the
/// line that says it is shown once. Copy keeps it to this Mac and out of
/// clipboard history, and the code is taken back off the pasteboard and
/// forgotten when this block leaves the pane.
struct AlwaysOnCodeBlock: View {
    let handout: EnrollmentHandout

    @State private var copied = CueSecretCopy()

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsRowMetrics.entryGap) {
            HStack(alignment: .top, spacing: Spacing.s) {
                Text(handout.code)
                    .fermixType(Typography.style(.monoLog))
                    .foregroundStyle(Palette.ink.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(ProductStrings[.alwaysOnCodeAccessibility])

                Button(ProductStrings[.alwaysOnCodeCopy]) { copied.copy(handout.code, on: .system) }
            }
            .padding(Spacing.xs)
            .background(Palette.chipFill.color, in: RoundedRectangle(cornerRadius: Radius.controlCompact, style: .continuous))

            CueNote(text: ProductStrings[.alwaysOnCodeOnce], attention: true)
            CueNote(text: String(format: ProductStrings[.alwaysOnCodeExpiresFormat], expiry))
        }
        .onDisappear { copied.takeBack(on: .system) }
    }

    private var expiry: String {
        ManagementCueTime.date(handout.expiresAt).map { CueTimes.time($0) } ?? handout.expiresAt
    }
}

/// The one command an existing server runs, with Copy command. It carries no
/// code: the script it fetches asks for the code without echo.
struct AlwaysOnCommandBlock: View {
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
            Text(ProductStrings[.alwaysOnHostCommand])
                .fermixType(Typography.style(.monoLog))
                .foregroundStyle(Palette.ink.color)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(ProductStrings[.alwaysOnHostCopyCommand]) { Clipboard.write(ProductStrings[.alwaysOnHostCommand]) }
        }
        .padding(Spacing.xs)
        .background(Palette.chipFill.color, in: RoundedRectangle(cornerRadius: Radius.controlCompact, style: .continuous))
    }
}

/// The wait for a server to check in, while the pane follows the window, and
/// the way to look again once the follow ran out.
struct AlwaysOnWaitingLine: View {
    @ObservedObject var alwaysOn: AlwaysOnModel

    var body: some View {
        if alwaysOn.followStopped {
            HStack(spacing: Spacing.s) {
                CueNote(text: ProductStrings[.alwaysOnWaitStopped])
                Spacer(minLength: Spacing.s)
                Button(ProductStrings[.alwaysOnWaitCheckAgain]) { alwaysOn.followAgain() }
                    .buttonStyle(SecondaryButtonStyle(.row))
            }
        } else {
            AlwaysOnProgressLine(text: ProductStrings[.alwaysOnWaitChecking])
        }
    }
}

/// A new window, which replaces the one open and its code.
struct AlwaysOnNewCodeControl: View {
    @ObservedObject var alwaysOn: AlwaysOnModel

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsRowMetrics.captionGap) {
            Button(ProductStrings[.alwaysOnSetupNewCode]) { Task { await alwaysOn.openEnrollment() } }
                .buttonStyle(SecondaryButtonStyle(.row))
                .disabled(alwaysOn.isOpeningEnrollment)

            if let refusal = alwaysOn.enrollRefusal {
                CueNote(text: refusal, attention: true)
            }
        }
    }
}

/// A line that moves by itself: a small spinner and the sentence.
struct AlwaysOnProgressLine: View {
    let text: String

    var body: some View {
        HStack(spacing: Spacing.s) {
            ProgressView().controlSize(.small).accessibilityHidden(true)
            CueNote(text: text)
                .accessibilityAddTraits(.updatesFrequently)
        }
    }
}

/// A server that checked in: its name and system, the instance facts it
/// reported about itself marked as unverified, and the way to move to it,
/// which shows the daemon's readiness report and asks for the recovery
/// passphrase, and starts only while nothing in the report blocks.
struct AlwaysOnCandidateBlock: View {
    @ObservedObject var alwaysOn: AlwaysOnModel
    let candidate: ManagementCandidate

    @State private var entry = RecoveryPassphraseEntry()

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsRowMetrics.captionGap) {
            Text(candidate.name)
                .fermixType(Typography.style(.callout).weight(.medium))
                .foregroundStyle(Palette.ink.color)

            fact(.alwaysOnCandidateSystem, ProductStrings.commaPair(candidate.os, candidate.arch))
            if let instance = candidate.instance {
                instanceFacts(instance)
            }
            CueNote(text: String(format: ProductStrings[.alwaysOnCandidateWaitsFormat], waits))

            if alwaysOn.chosenCandidate == candidate.candidateId {
                AlwaysOnReadinessReport(readiness: alwaysOn.readiness)
                RecoveryPassphraseForm(
                    entry: $entry,
                    busy: alwaysOn.isStartingMove,
                    blocked: !alwaysOn.mayStartMove,
                    action: .alwaysOnMoveStart
                ) {
                    entry.clear()
                    alwaysOn.withdrawChoice()
                } submit: { passphrase in
                    Task { await alwaysOn.startMove(passphrase: passphrase) }
                }
            } else {
                HStack {
                    Spacer(minLength: 0)
                    Button(ProductStrings[.alwaysOnCandidateChoose]) {
                        Task { await alwaysOn.choose(candidate: candidate.candidateId) }
                    }
                    .buttonStyle(SecondaryButtonStyle(.row))
                    .accessibilityLabel(ProductStrings.commaPair(ProductStrings[.alwaysOnCandidateChoose], candidate.name))
                }
            }

            if let refusal = alwaysOn.moveRefusal, alwaysOn.chosenCandidate == candidate.candidateId {
                CueNote(text: refusal, attention: true)
            }
        }
        .onDisappear { entry.clear() }
    }

    @ViewBuilder
    private func instanceFacts(_ instance: ManagementCandidateInstance) -> some View {
        if let provider = instance.provider { fact(.alwaysOnCandidateProvider, provider) }
        if let id = instance.instanceId { fact(.alwaysOnCandidateInstance, id) }
        if let region = instance.region { fact(.alwaysOnCandidateRegion, region) }
        if let account = instance.accountId { fact(.alwaysOnCandidateAccount, account) }
        CueNote(text: ProductStrings[.alwaysOnCandidateUnverified], attention: true)
    }

    private func fact(_ label: ProductStringKey, _ value: String) -> some View {
        LabeledContent(ProductStrings[label]) {
            Text(value)
                .foregroundStyle(Palette.secondary.color)
                .textSelection(.enabled)
        }
    }

    private var waits: String {
        ManagementCueTime.date(candidate.expiresAt).map { CueTimes.time($0) } ?? candidate.expiresAt
    }
}

/// The daemon's readiness report for the chosen server, between reviewing it
/// and starting the move: each fact in its own words after its dot, and a
/// line saying the move waits while any of them blocks.
struct AlwaysOnReadinessReport: View {
    let readiness: SettingsReadState<ManagementMoveReadiness>

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsRowMetrics.captionGap) {
            Text(ProductStrings[.alwaysOnReadinessTitle])
                .fermixType(Typography.style(.callout).weight(.medium))
                .foregroundStyle(Palette.ink.color)

            content
        }
    }

    @ViewBuilder
    private var content: some View {
        switch readiness {
        case .unread, .loading:
            AlwaysOnProgressLine(text: ProductStrings[.alwaysOnReadinessChecking])
        case .requiresNewerEngine:
            CueNote(text: ProductStrings[.daemonErrorRequiresNewerEngine], attention: true)
        case .unavailable(let sentence):
            CueNote(text: sentence, attention: true)
        case .loaded(let report):
            ForEach(Array(report.items.enumerated()), id: \.offset) { _, item in
                CueStatusLine(
                    text: item.sentence,
                    tone: AlwaysOnReadinessProjection.tone(item),
                    attention: item.status == .block
                )
            }
            if !report.ready {
                CueNote(text: ProductStrings[.alwaysOnReadinessBlocked], attention: true)
            }
        }
    }
}
