import Foundation

/// An edit applied to a list before the engine has confirmed it (M85 §09):
/// what the card and the panel draw from the moment the owner ticks, adds or
/// rewords, until the next pushed rev carries the engine's own state.
///
/// Pure, and placed by the engine's own rules (`Checklists.Ops`): an add goes
/// to the end of the section it names, right after the row it names, or with
/// neither to the end of the list's first group, the items above its first
/// heading or else its first section. An op that only the engine can work out,
/// a folder, a restore or a create, changes nothing here and is drawn when
/// the engine pushes it. An op the engine would refuse, such as a check of a
/// heading, changes nothing either: its refusal puts the row back anyway.
/// Removing the list is drawn when the engine pushes it too, within the
/// tenth of a second its window allows.
enum ChecklistDraft {
    /// A row an add made here, not yet given its id by the engine: drawn as
    /// sending and taking no edit until the push names it.
    static let localPrefix = "local:"

    static func localRowId(_ clientMsgId: String) -> String {
        localPrefix + clientMsgId
    }

    static func isLocal(_ rowId: String) -> Bool {
        rowId.hasPrefix(localPrefix)
    }

    /// The list with each edit applied in turn, oldest first.
    static func applying(_ edits: [ChecklistPendingEdit], to list: CompanionChecklistList) -> CompanionChecklistList {
        edits.reduce(list) { applying($1.op, id: $1.clientMsgId, to: $0) }
    }

    /// The list with one op applied, as the engine would apply it.
    static func applying(_ op: CompanionChecklistOp, id clientMsgId: String, to list: CompanionChecklistList) -> CompanionChecklistList {
        var rows = list.rows
        var title = list.title

        switch op {
        case .add(let text, let note, let place):
            let row = CompanionChecklistRow(rowId: localRowId(clientMsgId), kind: .item, text: text, done: false, note: note.flatMap { $0.isEmpty ? nil : $0 })
            rows.insert(row, at: index(for: place, in: rows))
        case .check(let rowId):
            rows = marking(rowId, done: true, in: rows)
        case .uncheck(let rowId):
            rows = marking(rowId, done: false, in: rows)
        case .edit(let rowId, let text, let note):
            rows = rows.map { row in
                guard row.rowId == rowId, row.kind == .item else { return row }

                let kept = note.map { $0.isEmpty ? nil : $0 } ?? row.note
                return CompanionChecklistRow(rowId: row.rowId, kind: row.kind, text: text ?? row.text, done: row.done, note: kept, doneAt: row.doneAt)
            }
        case .move(let rowId, let place, let toListId):
            rows = moving(rowId, to: place, leaving: toListId != nil, in: rows)
        case .section(let text, let afterId):
            let heading = CompanionChecklistRow(rowId: localRowId(clientMsgId), kind: .section, text: text, done: nil)
            let at = afterId.flatMap { id in rows.firstIndex { $0.rowId == id }.map { $0 + 1 } } ?? rows.count
            rows.insert(heading, at: at)
        case .remove(let rowId):
            rows.removeAll { $0.rowId == rowId }
        case .rename(let text):
            title = text
        case .clearDone:
            rows.removeAll(where: \.isDone)
        case .create, .folder, .restore, .removeList:
            break
        }

        return CompanionChecklistList(listId: list.listId, title: title, rev: list.rev, rows: rows, removed: list.removed, removedAt: list.removedAt)
    }

    /// Where an add, or a move within the list, lands among `rows`.
    static func index(for place: CompanionChecklistPlace?, in rows: [CompanionChecklistRow]) -> Int {
        switch place {
        case .section(let id)?:
            guard let heading = rows.firstIndex(where: { $0.rowId == id }) else { return firstGroupEnd(rows) }
            return sectionEnd(rows, heading)
        case .after(let id)?:
            guard let row = rows.firstIndex(where: { $0.rowId == id }) else { return firstGroupEnd(rows) }
            return row + 1
        case nil:
            return firstGroupEnd(rows)
        }
    }

    /// The end of the list's first group: the items above its first heading,
    /// or, where it opens with a heading, its first section.
    static func firstGroupEnd(_ rows: [CompanionChecklistRow]) -> Int {
        guard let first = rows.first else { return 0 }
        guard first.kind == .section else { return rows.firstIndex { $0.kind == .section } ?? rows.count }

        return sectionEnd(rows, 0)
    }

    /// The index after the last row of the section whose heading is at
    /// `heading`: the next heading's, or the list's end.
    static func sectionEnd(_ rows: [CompanionChecklistRow], _ heading: Int) -> Int {
        rows[(heading + 1)...].firstIndex { $0.kind == .section } ?? rows.count
    }

    private static func marking(_ rowId: String, done: Bool, in rows: [CompanionChecklistRow]) -> [CompanionChecklistRow] {
        rows.map { row in
            guard row.rowId == rowId, row.kind == .item else { return row }

            return CompanionChecklistRow(rowId: row.rowId, kind: row.kind, text: row.text, done: done, note: row.note, doneAt: done ? row.doneAt : nil)
        }
    }

    /// A move within the list takes the row out and puts it where an add
    /// would land in what is left; a move to another list takes it out.
    private static func moving(
        _ rowId: String,
        to place: CompanionChecklistPlace?,
        leaving: Bool,
        in rows: [CompanionChecklistRow]
    ) -> [CompanionChecklistRow] {
        guard let at = rows.firstIndex(where: { $0.rowId == rowId }), rows[at].kind == .item else { return rows }

        var rest = rows
        let row = rest.remove(at: at)
        guard !leaving else { return rest }
        guard place != nil else { return rows }

        rest.insert(row, at: index(for: place, in: rest))
        return rest
    }
}

extension CompanionChecklistOp {
    /// Every row the op names, as the row it acts on or as its place.
    var namedRows: [String] {
        switch self {
        case .check(let rowId), .uncheck(let rowId), .remove(let rowId), .edit(let rowId, _, _):
            return [rowId]
        case .move(let rowId, let place, _):
            return [rowId] + place.map(Self.row).map { [$0] }.orEmpty
        case .add(_, _, let place):
            return place.map(Self.row).map { [$0] }.orEmpty
        case .section(_, let afterId):
            return afterId.map { [$0] }.orEmpty
        case .restore(let rowId, _):
            return rowId.map { [$0] }.orEmpty
        case .create, .folder, .rename, .removeList, .clearDone:
            return []
        }
    }

    private static func row(_ place: CompanionChecklistPlace) -> String {
        switch place {
        case .section(let id), .after(let id): return id
        }
    }
}

private extension Optional where Wrapped == [String] {
    var orEmpty: [String] { self ?? [] }
}

/// One edit this Mac sent and the engine has not yet confirmed with a push:
/// applied over the engine's list until then.
struct ChecklistPendingEdit: Equatable, Sendable {
    let clientMsgId: String
    let op: CompanionChecklistOp
    /// The engine answered `accepted`: it holds the change, and the next list
    /// it sends carries it.
    var accepted = false
}

/// The parts a list is drawn in (M85 §09): its first group, the items above
/// its first heading, then each section under its heading. Done items stay
/// where the engine keeps them; whoever draws decides where they show.
struct ChecklistSection: Equatable, Identifiable {
    /// Nil for the first group, which has no heading.
    let heading: CompanionChecklistRow?
    let items: [CompanionChecklistRow]

    var id: String { heading?.rowId ?? "" }

    static func sections(of rows: [CompanionChecklistRow]) -> [ChecklistSection] {
        var sections: [ChecklistSection] = []
        var heading: CompanionChecklistRow?
        var items: [CompanionChecklistRow] = []

        for row in rows {
            switch row.kind {
            case .section:
                if heading != nil || !items.isEmpty { sections.append(ChecklistSection(heading: heading, items: items)) }
                heading = row
                items = []
            case .item:
                items.append(row)
            case .unrecognized:
                continue
            }
        }
        if heading != nil || !items.isEmpty { sections.append(ChecklistSection(heading: heading, items: items)) }

        return sections
    }
}

extension CompanionChecklistList {
    /// The items, open and done, without the headings.
    var items: [CompanionChecklistRow] { rows.filter { $0.kind == .item } }
    var openCount: Int { items.filter { !$0.isDone }.count }
    var doneCount: Int { items.filter(\.isDone).count }

    /// The list as text, the way the model reads it: each section under its
    /// heading, each item a checkbox line with its note under it.
    var markdown: String {
        var lines = ["# \(title)"]
        for section in ChecklistSection.sections(of: rows) {
            if let heading = section.heading { lines += ["", "## \(heading.text)"] }
            for item in section.items {
                lines.append("- [\(item.isDone ? "x" : " ")] \(item.text)")
                if let note = item.note { lines += note.split(separator: "\n", omittingEmptySubsequences: false).map { "  \($0)" } }
            }
        }

        return lines.joined(separator: "\n")
    }
}
