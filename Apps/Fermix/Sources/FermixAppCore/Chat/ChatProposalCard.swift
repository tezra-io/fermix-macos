import SwiftUI

/// A cue proposal waiting on the owner (M60 §4.7): a task under a mandate in
/// approve mode wants to run one call, and runs it only if the owner confirms.
///
/// Fermix's lines (the summary, the task, the watcher and the expiry) are
/// drawn as Fermix's. What a model or a stranger wrote, the call's arguments
/// and the item that led to it, is drawn only by `OutsideTextBlock`.
///
/// Deny and Confirm are drawn alike, and neither is the default button, so
/// Return does nothing on the card: an answer takes a click or a keypress on
/// a button itself. A press sends the proposal's id and the word, disables
/// both, and shows Running… for a confirm; the daemon's resolution replaces
/// the buttons with its sentence, and what the tool answered under it as
/// outside text. At its expiry on this Mac's clock the buttons go and the
/// card says nothing ran, until the daemon's resolution replaces that too.
///
/// VoiceOver reads the card as one group: the summary, the call, the item,
/// the expiry, then the buttons. The expiry is told when the card appears and
/// a minute before it, never every second.
struct ChatProposalCard: View {
    let card: CompanionProposalCard
    let decide: (String, CompanionProposalDecision) -> Void

    private let announcer: any AccessibilityAnnouncing = AppKitAccessibilityAnnouncer()

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            lead

            OutsideTextBlock(header: ProductStrings[.outsideCall], facts: [], text: proposal.outside.argsText, face: .code)
                .accessibilitySortPriority(4)

            if let cue = proposal.outside.cue {
                OutsideTextBlock(header: Self.itemHeader(of: proposal), facts: Self.facts(of: cue), text: cue.text ?? "", face: .item)
                    .accessibilitySortPriority(3)
            }

            footer
                .accessibilitySortPriority(1)
        }
        .padding(Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(Palette.chipFill.color))
        .overlay(shape.strokeBorder(Palette.hairline(.standard).color, lineWidth: Stroke.hairline))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(ProductStrings[.proposalTitle])
        .task(id: ProposalCountdown(id: card.id, asking: card.awaitsDecision)) {
            await tellExpiry()
        }
    }

    private var proposal: CompanionProposal { card.proposal }

    /// Fermix's lines, read as one block: the title with its mark, the
    /// summary, and the task, the watcher and the expiry under them.
    private var lead: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Label {
                Text(ProductStrings[.proposalTitle])
                    .fermixType(Typography.style(.headline))
                    .foregroundStyle(Palette.ink.color)
            } icon: {
                Image(systemName: "hand.raised")
                    .foregroundStyle(Palette.warning.color)
                    .accessibilityHidden(true)
            }
            .accessibilitySortPriority(6)

            Text(proposal.summary)
                .fermixType(Typography.style(.body))
                .foregroundStyle(Palette.ink.color)
                .textSelection(.enabled)
                .padding(.top, Spacing.xxs)
                .accessibilitySortPriority(5)

            Text(Self.facts(of: proposal))
                .fermixType(Typography.style(.calloutSmall))
                .foregroundStyle(Palette.secondary.color)
                .accessibilitySortPriority(2)
        }
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: ChatMetrics.rowRadius, style: .continuous)
    }

    /// Under the outside text: the buttons while the card asks, their answer
    /// on its way, the expiry, or the daemon's last word. A card the daemon
    /// does not say waits, in a state this build may not know, draws the
    /// daemon's own line for it and no button (M60 §4.9).
    @ViewBuilder
    private var footer: some View {
        switch card.standing {
        case .open:
            if card.awaitsDecision {
                buttons(running: false)
            } else if let status = proposal.statusSentence {
                Text(status)
                    .fermixType(Typography.style(.body))
                    .foregroundStyle(Palette.secondary.color)
            }
        case .answered(let decision):
            buttons(running: decision == .confirm)
        case .expired:
            Text(ProductStrings[.proposalExpired])
                .fermixType(Typography.style(.body))
                .foregroundStyle(Palette.secondary.color)
        case .resolved(let sentence, let resultText):
            Text(sentence)
                .fermixType(Typography.style(.body))
                .foregroundStyle(Palette.ink.color)
                .textSelection(.enabled)

            if let resultText {
                OutsideTextBlock(header: ProductStrings[.outsideResult], facts: [], text: resultText, face: .code)
            }
        }
    }

    /// Deny and Confirm, alike, enabled only while the card asks.
    private func buttons(running: Bool) -> some View {
        HStack(spacing: Spacing.xs) {
            Spacer(minLength: 0)

            if running {
                Text(ProductStrings[.proposalRunning])
                    .fermixType(Typography.style(.calloutSmall))
                    .foregroundStyle(Palette.secondary.color)
            }

            Group {
                Button(ProductStrings[.proposalDeny]) { decide(card.id, .deny) }
                Button(ProductStrings[.proposalConfirm]) { decide(card.id, .confirm) }
            }
            .buttonStyle(SecondaryButtonStyle(.row))
            .disabled(!card.awaitsDecision)
        }
    }

    /// The expiry, told to VoiceOver as the card appears asking, and again a
    /// minute before it. A card that stops asking cancels the wait.
    private func tellExpiry() async {
        guard card.awaitsDecision, let expiresAt = card.expiresAt else { return }

        announcer.announce(
            ProductStrings.commaPair(
                ProductStrings[.proposalTitle],
                String(format: ProductStrings[.proposalWaitsUntilFormat], CueTimes.time(expiresAt))
            )
        )

        let lastMinute = expiresAt.addingTimeInterval(-60).timeIntervalSinceNow
        guard lastMinute > 0 else { return }

        try? await Task.sleep(for: .seconds(lastMinute))
        guard !Task.isCancelled else { return }

        announcer.announce(ProductStrings[.proposalLastMinute])
    }

    // MARK: - Fermix's lines

    /// The task, the watcher where there is one, and when the card stops
    /// waiting: every one Fermix's record.
    static func facts(of proposal: CompanionProposal) -> String {
        let task = String(format: ProductStrings[.proposalTaskFormat], proposal.task.name ?? proposal.task.jobId)
        let watcher = proposal.watcher.map { String(format: ProductStrings[.proposalWatcherFormat], $0) }
        let waits = String(
            format: ProductStrings[.proposalWaitsUntilFormat],
            CompanionTime.date(proposal.expiresAt).map { CueTimes.time($0) } ?? proposal.expiresAt
        )

        return [watcher, waits].compactMap { $0 }.reduce(task) { ProductStrings.middot($0, $1) }
    }

    /// The item's header: the source Fermix received it from, and when, or,
    /// where its record names neither, only that it is the item.
    static func itemHeader(of proposal: CompanionProposal) -> String {
        guard let source = proposal.sourceRef, let receivedAt = proposal.receivedAt else {
            return ProductStrings[.outsideItemUnsourced]
        }

        let received = CompanionTime.date(receivedAt).map { CueTimes.time($0) } ?? receivedAt
        return String(format: ProductStrings[.outsideItemFormat], source, received)
    }

    /// The item's own fields, labelled. Their values are what the item said,
    /// its time too, which is the producer's claim, so they are set as the
    /// item wrote them and never read as dates.
    static func facts(of cue: CompanionProposalCue) -> [String] {
        [
            cue.type.map { String(format: ProductStrings[.outsideTypeFormat], $0) },
            cue.subject.map { String(format: ProductStrings[.outsideSubjectFormat], $0) },
            cue.occurredAt.map { String(format: ProductStrings[.outsideDatedFormat], $0) }
        ].compactMap { $0 }
    }
}

/// What the expiry's announcements wait on: the card, and whether it asks.
private struct ProposalCountdown: Equatable {
    let id: String
    let asking: Bool
}
