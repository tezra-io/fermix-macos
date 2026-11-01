import SwiftUI

/// The lists a reply's turn read or changed, under its words (M85 §08). The
/// newest card that draws a list is live: one list's open items to tick,
/// reword and add to, or a group per list of the rows its turn touched. Any
/// older card folds to one line naming its lists with their open counts,
/// each a way into the panel. Every list is drawn as it stands now, from the
/// one store the panel draws too.
struct ChecklistCard: View {
    let refs: [CompanionChecklistRef]
    let live: Bool

    @Environment(\.chatRows) private var rows

    var body: some View {
        if let rows {
            if !live {
                ChecklistFoldedLine(refs: refs, panel: rows.lists, index: rows.lists.library.index)
            } else if refs.count == 1, let ref = refs.first {
                ChecklistOneListCard(
                    ref: ref,
                    panel: rows.lists,
                    store: rows.lists.library.store(ref.listId),
                    index: rows.lists.library.index
                )
            } else {
                ChecklistGroupedCard(refs: refs, panel: rows.lists)
            }
        }
    }
}

/// The soft panel a code block is drawn on, 12-point corners and no border.
private struct ChecklistCardGround: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, Spacing.s)
            .padding(.top, Spacing.s)
            .padding(.bottom, Spacing.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: ChecklistMetrics.cardRadius, style: .continuous)
                    .fill(Palette.chipFill.color)
            )
    }
}

/// A card's header: the list symbol, the list's title and its counts, and
/// the way into the panel.
private struct ChecklistCardHeader: View {
    let title: String
    let counts: String
    let open: () -> Void

    var body: some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: "checklist")
                .foregroundStyle(Palette.secondary.color)
                .accessibilityHidden(true)
            Text(title)
                .fermixType(Typography.style(.callout).weight(.semibold))
                .foregroundStyle(Palette.ink.color)
                .lineLimit(1)
            Text(counts)
                .fermixType(Typography.style(.calloutSmall))
                .foregroundStyle(Palette.secondary.color)
                .lineLimit(1)
            Spacer(minLength: 0)
            ChecklistIconButton(symbol: "sidebar.right", label: ProductStrings[.listsOpenList], action: open)
        }
    }
}

/// A small icon button in a 24-point target: the card's way into the panel,
/// and the panel's own controls.
struct ChecklistIconButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .foregroundStyle(Palette.secondary.color)
                .frame(width: ChecklistMetrics.target, height: ChecklistMetrics.target)
                .background(
                    RoundedRectangle(cornerRadius: Radius.iconTileSmall, style: .continuous)
                        .fill(hovering ? Palette.chipFill.color : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

/// A reply's card of one list (M85 §08): at most four open items, the ones
/// its turn touched first, then "%d more", which grows the card in place to
/// every open item until "Show less", and an add field. The header's button
/// opens the panel, where sections, order and Done live. A tick keeps its row in place for a moment, so a mis-tick is
/// easy to undo, then folds it away. Done items are counted, not shown.
private struct ChecklistOneListCard: View {
    let ref: CompanionChecklistRef
    let panel: ChecklistPanelModel
    @ObservedObject var store: ChecklistStore
    /// Observed for whether it still names the list.
    @ObservedObject var index: ChecklistIndexStore

    @State private var settling: Set<String> = []
    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        content
            .modifier(ChecklistCardGround())
            .accessibilityElement(children: .contain)
            .accessibilityLabel(ChecklistWordsFor.listLabel(store.shown?.title ?? ref.title, open: store.shown?.openCount ?? 0))
            .onAppear { panel.library.draw(ref.listId) }
    }

    @ViewBuilder
    private var content: some View {
        let list = store.shown
        VStack(alignment: .leading, spacing: 0) {
            ChecklistCardHeader(
                title: list?.title ?? ref.title,
                counts: list.map { ChecklistWordsFor.counts(open: $0.openCount, done: $0.doneCount) } ?? "",
                open: { panel.show(ref.listId) }
            )
            .padding(.bottom, Spacing.xxs)

            if store.isRemoved || index.lacks(ref.listId) {
                ChecklistCardSentence(text: ProductStrings[.listsListRemoved])
            } else if let list {
                let card = ChecklistCards.oneList(list, touched: ref.rows, settling: settling, expanded: expanded)
                ForEach(card.rows) { row in
                    ChecklistCardItem(
                        row: row,
                        rewords: true,
                        tick: { tick(row, $0) },
                        reword: { panel.library.edit(ref.listId, .edit(rowId: row.rowId, text: $0, note: nil)) }
                    )
                }
                if let refusal = store.refusal {
                    ChecklistCardSentence(text: refusal)
                }
                footer(more: card.more, fewer: card.fewer)
            }
        }
    }

    private func footer(more: Int, fewer: Bool) -> some View {
        HStack(spacing: Spacing.xs) {
            ChecklistAddField { panel.library.edit(ref.listId, .add(text: $0, note: nil, place: nil)) }
            if more > 0 {
                footerButton(String(format: ProductStrings[.listsMoreFormat], more), expands: true)
            } else if fewer {
                footerButton(ProductStrings[.listsShowLess], expands: false)
            }
        }
        .padding(.top, Spacing.xxs)
        .overlay(alignment: .top) { ChecklistHairline() }
        .padding(.top, Spacing.xxs)
    }

    private func footerButton(_ title: String, expands: Bool) -> some View {
        Button(title) {
            withAnimation(Motion(reduceMotion: reduceMotion).animation(.checklistStrike)) { expanded = expands }
        }
        .buttonStyle(.plain)
        .fermixType(Typography.style(.calloutSmall))
        .foregroundStyle(Palette.secondary.color)
    }

    private func tick(_ row: CompanionChecklistRow, _ done: Bool) {
        if done, !reduceMotion { settle(row.rowId) }
        panel.library.edit(ref.listId, done ? .check(rowId: row.rowId) : .uncheck(rowId: row.rowId))
    }

    /// The row keeps its place for 700 ms, then folds away.
    private func settle(_ rowId: String) {
        settling.insert(rowId)
        Task { @MainActor in
            try? await Task.sleep(for: ChecklistMetrics.settle)
            withAnimation(Motion(reduceMotion: reduceMotion).animation(.checklistStrike)) {
                _ = settling.remove(rowId)
            }
        }
    }
}

/// A reply's card of several lists (M85 §08): a group per list, the list's
/// name and open count over the rows its turn touched, at most three lists
/// and three rows each, then how many more lists it named. It ticks only:
/// an add field here would not know which list it adds to.
private struct ChecklistGroupedCard: View {
    let refs: [CompanionChecklistRef]
    let panel: ChecklistPanelModel

    var body: some View {
        let shown = ChecklistCards.drawn(refs)
        let more = refs.count - shown.count

        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(shown.enumerated()), id: \.element.listId) { offset, ref in
                ChecklistGroup(ref: ref, panel: panel, store: panel.library.store(ref.listId), index: panel.library.index, first: offset == 0)
            }
            if more > 0 {
                Text(String(format: ProductStrings[.listsMoreListsFormat], more))
                    .fermixType(Typography.style(.calloutSmall))
                    .foregroundStyle(Palette.secondary.color)
                    .padding(.top, Spacing.xs)
            }
        }
        .modifier(ChecklistCardGround())
        .accessibilityElement(children: .contain)
        .accessibilityLabel(ChecklistWordsFor.listsLabel(refs.map(\.title)))
    }
}

/// One list of a card of several: its name line opens it in the panel, and
/// under it the rows the turn touched, as they stand now. A row the turn
/// ticked shows struck through, so the card is a receipt of what happened.
private struct ChecklistGroup: View {
    let ref: CompanionChecklistRef
    let panel: ChecklistPanelModel
    @ObservedObject var store: ChecklistStore
    /// Observed for whether it still names the list.
    @ObservedObject var index: ChecklistIndexStore
    let first: Bool

    @State private var hovering = false

    var body: some View {
        let list = store.shown
        let group = ChecklistCards.groups([ref]) { _ in list }.groups.first
        let removed = store.isRemoved || index.lacks(ref.listId)

        VStack(alignment: .leading, spacing: 0) {
            Button { panel.show(ref.listId) } label: {
                HStack(spacing: Spacing.xs) {
                    Text(list?.title ?? ref.title)
                        .fermixType(Typography.style(.callout).weight(.semibold))
                        .foregroundStyle(Palette.ink.color)
                        .underline(hovering)
                    if removed {
                        Text(ProductStrings[.listsListRemoved])
                            .fermixType(Typography.style(.calloutSmall))
                            .foregroundStyle(Palette.secondary.color)
                    } else if let list {
                        Text(ChecklistWordsFor.open(list.openCount))
                            .fermixType(Typography.style(.calloutSmall))
                            .foregroundStyle(Palette.secondary.color)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: Typography.style(.caption).size, weight: .semibold))
                        .foregroundStyle(Palette.faint.color)
                }
                .frame(minHeight: ChecklistMetrics.target)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .accessibilityLabel(ChecklistWordsFor.listLabel(list?.title ?? ref.title, open: list?.openCount ?? 0))

            if !removed {
                ForEach(group?.rows ?? []) { row in
                    ChecklistCardItem(
                        row: row,
                        rewords: false,
                        tick: { done in panel.library.edit(ref.listId, done ? .check(rowId: row.rowId) : .uncheck(rowId: row.rowId)) },
                        reword: { _ in }
                    )
                }
            }
        }
        .padding(.top, first ? 0 : Spacing.xs)
        .overlay(alignment: .top) {
            if !first { ChecklistHairline() }
        }
        .padding(.bottom, Spacing.xxs)
        .onAppear { panel.library.draw(ref.listId) }
    }
}

/// An older card, folded to one line (M85 §08): each list it drew, with its
/// open count as the index has it now, a way into the panel. A list since
/// removed reads so.
private struct ChecklistFoldedLine: View {
    let refs: [CompanionChecklistRef]
    let panel: ChecklistPanelModel
    @ObservedObject var index: ChecklistIndexStore

    var body: some View {
        ChecklistFlow(spacing: Spacing.xs) {
            ForEach(refs, id: \.listId) { ref in
                ChecklistChip(ref: ref, entry: index.entry(ref.listId), removed: index.lacks(ref.listId)) {
                    panel.show(ref.listId)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One list on a folded line: the list symbol, its name and its open count,
/// on the soft fill, and the way to it.
private struct ChecklistChip: View {
    let ref: CompanionChecklistRef
    let entry: CompanionChecklistEntry?
    let removed: Bool
    let open: () -> Void

    var body: some View {
        if removed {
            Text(ProductStrings[.listsListRemoved])
                .fermixType(Typography.style(.calloutSmall))
                .foregroundStyle(Palette.secondary.color)
                .modifier(ChecklistChipGround())
        } else {
            Button(action: open) {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: "checklist")
                        .foregroundStyle(Palette.secondary.color)
                    Text(entry?.title ?? ref.title)
                        .fermixType(Typography.style(.calloutSmall).weight(.semibold))
                        .foregroundStyle(Palette.ink.color)
                    if let entry {
                        Text(ChecklistWordsFor.open(entry.open))
                            .fermixType(Typography.style(.calloutSmall))
                            .foregroundStyle(Palette.secondary.color)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: Typography.style(.caption).size, weight: .semibold))
                        .foregroundStyle(Palette.faint.color)
                }
                .modifier(ChecklistChipGround())
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(ChecklistWordsFor.listLabel(entry?.title ?? ref.title, open: entry?.open ?? 0))
        }
    }
}

private struct ChecklistChipGround: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.vertical, Spacing.xxs + Spacing.xxs / 2)
            .padding(.horizontal, Spacing.s - Spacing.xxs / 2)
            .background(
                RoundedRectangle(cornerRadius: Radius.controlCompact, style: .continuous)
                    .fill(Palette.chipFill.color)
            )
    }
}

/// A sentence inside a card: the engine's for an edit it refused, or that
/// the list was removed.
private struct ChecklistCardSentence: View {
    let text: String

    var body: some View {
        Text(text)
            .fermixType(Typography.style(.calloutSmall))
            .foregroundStyle(Palette.secondary.color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, Spacing.xxs)
    }
}

/// The hairline between a card's groups and over its add field.
struct ChecklistHairline: View {
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Rectangle()
            .fill(Palette.hairline(.faint, increaseContrast: contrast == .increased).color)
            .frame(height: Stroke.hairline)
            .accessibilityHidden(true)
    }
}
