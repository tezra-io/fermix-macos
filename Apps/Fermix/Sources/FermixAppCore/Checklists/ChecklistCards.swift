import Foundation

/// What a reply's lists card draws (M85 §08), as values: which card in the
/// timeline is live, and what a live one holds. Pure, so the rules are
/// tested without a view.
enum ChecklistCards {
    /// A one-list card's open items, at most.
    static let oneListRows = 4
    /// A card of several lists: rows a group, and groups a card, at most.
    static let groupRows = 3
    static let groupLists = 3

    /// The replies whose card is live, by seq: only the newest card that
    /// draws a given list is live (§08), so a card is live when no newer
    /// card draws any of the lists it draws. Every other card folds to one
    /// line, so a month of daily check-ins is thirty chips and one card, and
    /// no list is ever drawn live twice. A list a card of several only names
    /// past its three groups is not drawn there, so it does not count.
    static func live(in rows: [CompanionRow]) -> Set<Int> {
        var drawnNewer: Set<String> = []
        var live: Set<Int> = []

        for row in rows.reversed() {
            guard let refs = lists(of: row) else { continue }

            let ids = drawn(refs).map(\.listId)
            if drawnNewer.isDisjoint(with: ids) { live.insert(row.serverSeq) }
            drawnNewer.formUnion(ids)
        }

        return live
    }

    /// The lists a live card draws: a one-list card its one, a card of
    /// several its first three groups.
    static func drawn(_ refs: [CompanionChecklistRef]) -> [CompanionChecklistRef] {
        Array(refs.prefix(groupLists))
    }

    /// The lists a row's `checklists` block names, where it has one.
    static func lists(of row: CompanionRow) -> [CompanionChecklistRef]? {
        for block in row.blocks {
            if case .checklists(let refs) = block, !refs.isEmpty { return refs }
        }

        return nil
    }

    /// A one-list card's rows (§08): at most four open items, the ones the
    /// turn touched first, each part in the list's own order, and how many
    /// open items are left for "%d more". Expanded, the card holds every open
    /// item in the same order, so the first four stay where they were, and
    /// `fewer` says whether "Show less" has anything to fold. A row ticked
    /// here a moment ago (`settling`) keeps its place while it settles.
    static func oneList(
        _ list: CompanionChecklistList,
        touched: [String],
        settling: Set<String> = [],
        expanded: Bool = false
    ) -> (rows: [CompanionChecklistRow], more: Int, fewer: Bool) {
        let open = list.items.filter { !$0.isDone || settling.contains($0.rowId) }
        let touchedIds = Set(touched)
        let ordered = open.filter { touchedIds.contains($0.rowId) } + open.filter { !touchedIds.contains($0.rowId) }
        let rows = expanded ? ordered : Array(ordered.prefix(oneListRows))

        return (rows, open.count - rows.count, expanded && open.count > oneListRows)
    }

    /// One group of a card of several lists: the list's name and open count
    /// over the rows its turn touched, as they stand now, at most three. A
    /// row the turn ticked shows done, the card being a receipt of what
    /// happened; a row since removed is not drawn; a list the turn only
    /// read is its name line.
    struct Group: Equatable, Identifiable {
        let ref: CompanionChecklistRef
        let rows: [CompanionChecklistRow]

        var id: String { ref.listId }
    }

    /// The groups a card of several lists draws, at most three, and how many
    /// lists it names past them ("and %d more lists").
    static func groups(
        _ refs: [CompanionChecklistRef],
        lists: (String) -> CompanionChecklistList?
    ) -> (groups: [Group], moreLists: Int) {
        let shown = drawn(refs).map { ref in
            let rows = lists(ref.listId)?.rows ?? []
            let touched = ref.rows.compactMap { id in rows.first { $0.rowId == id && $0.kind == .item } }
            return Group(ref: ref, rows: Array(touched.prefix(groupRows)))
        }

        return (shown, max(0, refs.count - groupLists))
    }
}
