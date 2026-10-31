#if DEBUG
import Foundation

/// The owner's lists, as the fixture daemon keeps them (M85): the engine's
/// one writer, replaced by a scripted one with the same answers. It serves
/// the index and whole lists, applies every op the contract publishes by row
/// id with the engine's placement rules (`ChecklistDraft`), names what an add
/// or a create made, keeps removed rows for Recently removed, and refuses a
/// row it no longer has with the engine's sentence. DEBUG only, as the
/// transport that drives it is.
final class FixtureChecklists {
    private struct Kept {
        var list: CompanionChecklistList
        var folder: String?
        var removed: [CompanionChecklistRow] = []
    }

    /// When every change is stamped: the fixture's own clock is not the
    /// owner's, so a removal reads the same in every capture.
    static let stamp = "2026-10-31T12:00:00.000000Z"
    static let missingRow = "That row is not in this list any more; pull the list again."
    static let missingList = "No list has that id; it may have been removed more than 30 days ago."

    private var kept: [String: Kept] = [:]
    /// Picker order: the order the lists were made in.
    private var order: [String] = []
    private var made = 0

    init(_ seeds: [FixtureChecklistScript.Seed]) {
        for seed in seeds {
            kept[seed.list.listId] = Kept(list: seed.list, folder: seed.folder)
            order.append(seed.list.listId)
        }
    }

    /// Every live list, in picker order.
    var index: [CompanionChecklistEntry] {
        order.compactMap { kept[$0] }.filter { $0.list.removedAt == nil }.map { kept in
            CompanionChecklistEntry(
                listId: kept.list.listId,
                title: kept.list.title,
                folder: kept.folder,
                open: kept.list.openCount,
                done: kept.list.doneCount,
                rev: kept.list.rev
            )
        }
    }

    /// A whole list, with its removed rows when asked, or nil for an id the
    /// daemon has no list for.
    func list(_ listId: String, removed: Bool) -> CompanionChecklistList? {
        guard let kept = kept[listId] else { return nil }

        let list = kept.list
        return CompanionChecklistList(
            listId: list.listId,
            title: list.title,
            rev: list.rev,
            rows: list.rows,
            removed: removed ? kept.removed : nil,
            removedAt: list.removedAt
        )
    }

    /// One edit: the lists it changed and what it made, or the engine's
    /// sentence for an edit it cannot take.
    func apply(_ op: CompanionChecklistOp, to listId: String?) -> Result<(changed: [String], made: String?), FixtureChecklistRefusal> {
        if case .create(let title, let folder) = op {
            let id = nextId("ck_fx")
            kept[id] = Kept(list: CompanionChecklistList(listId: id, title: title, rev: 1, rows: []), folder: folder)
            order.append(id)
            return .success(([id], id))
        }
        guard let listId, var list = kept[listId] else { return .failure(FixtureChecklistRefusal(Self.missingList)) }
        guard Self.rowsExist(op, in: list) else { return .failure(FixtureChecklistRefusal(Self.missingRow)) }

        var changed = [listId]
        var madeId: String?
        switch op {
        case .add, .section:
            let drafted = ChecklistDraft.applying(op, id: "fixture", to: list.list)
            let id = nextId("ci_fx")
            madeId = id
            list.list = renamed(drafted, local: ChecklistDraft.localRowId("fixture"), to: id)
        case .remove(let rowId):
            list = removing(list) { $0.rowId == rowId }
        case .clearDone:
            list = removing(list, where: \.isDone)
        case .folder(let folder):
            list.folder = folder.isEmpty ? nil : folder
        case .removeList:
            list.list = rebuilt(list.list, rows: list.list.rows, removedAt: Self.stamp)
        case .restore(let rowId, let title):
            list = restoring(list, rowId: rowId, title: title)
        case .move(let rowId, let place, let target?):
            guard var to = kept[target], let row = list.list.rows.first(where: { $0.rowId == rowId }) else {
                return .failure(FixtureChecklistRefusal(Self.missingList))
            }
            list.list = rebuilt(list.list, rows: list.list.rows.filter { $0.rowId != rowId })
            var rows = to.list.rows
            rows.insert(row, at: ChecklistDraft.index(for: place, in: rows))
            to.list = rebuilt(to.list, rows: rows)
            kept[target] = to
            changed.append(target)
        default:
            list.list = ChecklistDraft.applying(op, id: "fixture", to: list.list)
        }

        list.list = rebuilt(list.list, rows: list.list.rows, rev: list.list.rev + 1)
        kept[listId] = list
        return .success((changed, madeId))
    }

    // MARK: - Steps

    /// Whether every row an op names is in the list.
    private static func rowsExist(_ op: CompanionChecklistOp, in kept: Kept) -> Bool {
        let rows = Set(kept.list.rows.map(\.rowId))
        switch op {
        case .check(let id), .uncheck(let id), .remove(let id), .edit(let id, _, _), .move(let id, _, _):
            return rows.contains(id)
        case .restore(let id?, _):
            return kept.removed.contains { $0.rowId == id }
        default:
            return true
        }
    }

    private func removing(_ kept: Kept, where gone: (CompanionChecklistRow) -> Bool) -> Kept {
        var kept = kept
        let removed = kept.list.rows.filter { $0.kind == .item && gone($0) }.map { row in
            CompanionChecklistRow(rowId: row.rowId, kind: row.kind, text: row.text, done: row.done, note: row.note, doneAt: row.doneAt, removedAt: Self.stamp)
        }
        kept.removed = removed.reversed() + kept.removed
        kept.list = rebuilt(kept.list, rows: kept.list.rows.filter { !($0.kind == .item && gone($0)) })
        return kept
    }

    private func restoring(_ kept: Kept, rowId: String?, title: String?) -> Kept {
        var kept = kept
        guard let rowId else {
            kept.list = rebuilt(CompanionChecklistList(listId: kept.list.listId, title: title ?? kept.list.title, rev: kept.list.rev, rows: kept.list.rows), rows: kept.list.rows)
            return kept
        }
        guard let row = kept.removed.first(where: { $0.rowId == rowId }) else { return kept }

        kept.removed.removeAll { $0.rowId == rowId }
        var rows = kept.list.rows
        rows.insert(
            CompanionChecklistRow(rowId: row.rowId, kind: row.kind, text: row.text, done: row.done, note: row.note, doneAt: row.doneAt),
            at: ChecklistDraft.firstGroupEnd(rows)
        )
        kept.list = rebuilt(kept.list, rows: rows)
        return kept
    }

    private func renamed(_ list: CompanionChecklistList, local: String, to id: String) -> CompanionChecklistList {
        rebuilt(list, rows: list.rows.map { row in
            guard row.rowId == local else { return row }

            return CompanionChecklistRow(rowId: id, kind: row.kind, text: row.text, done: row.done, note: row.note)
        })
    }

    private func rebuilt(
        _ list: CompanionChecklistList,
        rows: [CompanionChecklistRow],
        rev: Int? = nil,
        removedAt: String? = nil
    ) -> CompanionChecklistList {
        CompanionChecklistList(listId: list.listId, title: list.title, rev: rev ?? list.rev, rows: rows, removedAt: removedAt ?? list.removedAt)
    }

    private func nextId(_ prefix: String) -> String {
        made += 1
        return prefix + String(format: "%08d", made)
    }
}

/// The engine's sentence for an edit it cannot take.
struct FixtureChecklistRefusal: Error, Equatable {
    let sentence: String

    init(_ sentence: String) {
        self.sentence = sentence
    }
}

/// The lists the lists timeline holds, and its rows: the M85 plan's own
/// sample conversation. Yesterday's reply drew Fermix alone; today's ticked
/// one item and filed three across Fermix, Portfolio site and Groceries, so
/// yesterday's card folds; and the newest reply added two things to Packing,
/// whose card is live with its add field.
enum FixtureChecklistScript {
    struct Seed {
        let list: CompanionChecklistList
        let folder: String?
    }

    static let fermix = "ck_9t3k6w0p5h"
    static let portfolio = "ck_5r0t3v8b2c"
    static let groceries = "ck_4q8m2x7v1d"
    static let packing = "ck_2b7n5r8c3j"

    static let seeds: [Seed] = [
        Seed(list: CompanionChecklistList(listId: fermix, title: "Fermix", rev: 12, rows: [
            section("ci_fm0active", "Active"),
            item("ci_fm0logins", "Website logins in the Mac keychain", note: "S1 built; the profile and the pin bump are left"),
            item("ci_fm00lists", "Lists on the Mac and Android"),
            item("ci_fm000cues", "Cue setup on the Mac", note: "Waits on companion protocol 5"),
            item("ci_fm0pairng", "Phone pairing over iroh", done: true),
            item("ci_fm00links", "Links inline with a safety check", done: true),
            section("ci_fm00later", "Later"),
            item("ci_fm00voice", "Local voice with Dessa"),
            item("ci_fm000push", "Push gateway for Android"),
            item("ci_fm00pages", "Pages: reports drawn in the chat")
        ]), folder: "Projects"),
        Seed(list: CompanionChecklistList(listId: portfolio, title: "Portfolio site", rev: 4, rows: [
            item("ci_pf000case", "Case study for the pricing page"),
            item("ci_pf00contc", "Contact form"),
            item("ci_pf00hostg", "Move hosting off the old server"),
            item("ci_pf00headx", "New headshot", done: true)
        ]), folder: "Projects"),
        Seed(list: CompanionChecklistList(listId: groceries, title: "Groceries", rev: 7, rows: [
            section("ci_gr0produc", "Produce"),
            item("ci_gr00oatml", "Oat milk, 2 litres"),
            item("ci_gr0lemons", "Lemons"),
            item("ci_gr00basil", "Basil", done: true),
            section("ci_gr0pantry", "Pantry"),
            item("ci_gr0coffee", "Coffee beans", note: "The Ethiopian one from the Saturday market"),
            item("ci_gr000rice", "Rice", done: true),
            item("ci_gr0chickp", "Chickpeas, two tins"),
            section("ci_gr0househ", "Household"),
            item("ci_gr000soap", "Dish soap"),
            item("ci_gr000bags", "Bin bags", done: true)
        ]), folder: nil),
        Seed(list: CompanionChecklistList(listId: packing, title: "Packing", rev: 3, rows: [
            item("ci_pk0passpt", "Passport", done: true),
            item("ci_pk0chargr", "Phone charger"),
            item("ci_pk00boots", "Hiking boots"),
            item("ci_pk0sunscr", "Sunscreen"),
            item("ci_pk00rainj", "Rain jacket"),
            item("ci_pk000book", "A book for the train"),
            item("ci_pk0adaptr", "Plug adapter")
        ]), folder: "Trips")
    ]

    static let rows: [CompanionTimelineRow] = [
        FixtureCompanionScript.row(1, "user", "What is left on Fermix?", clientMsgId: "fixture-msg-1"),
        FixtureCompanionScript.row(
            2,
            "assistant",
            "Six are open on Fermix, and the keychain logins are closest to done.",
            inReplyTo: "fixture-msg-1",
            blocks: [.checklists([CompanionChecklistRef(listId: fermix, title: "Fermix", rows: [])])]
        ),
        FixtureCompanionScript.row(
            3,
            "user",
            "Pairing over iroh shipped, tick it. Add lists for the Mac and Android, a contact form for the portfolio, and lemons.",
            clientMsgId: "fixture-msg-3"
        ),
        FixtureCompanionScript.row(
            4,
            "assistant",
            "Ticked pairing over iroh and filed three: one each in Fermix, Portfolio site and Groceries.",
            inReplyTo: "fixture-msg-3",
            blocks: [.checklists([
                CompanionChecklistRef(listId: fermix, title: "Fermix", rows: ["ci_fm00lists", "ci_fm0pairng"]),
                CompanionChecklistRef(listId: portfolio, title: "Portfolio site", rows: ["ci_pf00contc"]),
                CompanionChecklistRef(listId: groceries, title: "Groceries", rows: ["ci_gr0lemons"])
            ])]
        ),
        FixtureCompanionScript.row(5, "user", "Add sunscreen and a rain jacket for the trip.", clientMsgId: "fixture-msg-5"),
        FixtureCompanionScript.row(
            6,
            "assistant",
            "Added both to Packing.",
            inReplyTo: "fixture-msg-5",
            blocks: [.checklists([CompanionChecklistRef(listId: packing, title: "Packing", rows: ["ci_pk0sunscr", "ci_pk00rainj"])])]
        )
    ]

    private static func item(_ id: String, _ text: String, note: String? = nil, done: Bool = false) -> CompanionChecklistRow {
        CompanionChecklistRow(rowId: id, kind: .item, text: text, done: done, note: note, doneAt: done ? FixtureChecklists.stamp : nil)
    }

    private static func section(_ id: String, _ text: String) -> CompanionChecklistRow {
        CompanionChecklistRow(rowId: id, kind: .section, text: text, done: nil)
    }
}

extension CompanionChecklistOp {
    /// The op a client line carries, read back by the fixture daemon; nil
    /// for an op it does not know.
    init?(fixtureLine op: [String: Any]) {
        let text = op["text"] as? String
        let rowId = op["row_id"] as? String
        let place: CompanionChecklistPlace? = (op["section_id"] as? String).map(CompanionChecklistPlace.section)
            ?? (op["after_id"] as? String).map(CompanionChecklistPlace.after)

        switch op["op"] as? String {
        case "create": self = .create(title: op["title"] as? String ?? "", folder: op["folder"] as? String)
        case "add": self = .add(text: text ?? "", note: op["note"] as? String, place: place)
        case "check": self = .check(rowId: rowId ?? "")
        case "uncheck": self = .uncheck(rowId: rowId ?? "")
        case "edit": self = .edit(rowId: rowId ?? "", text: text, note: op["note"] as? String)
        case "move": self = .move(rowId: rowId ?? "", place: place, toListId: op["to_list_id"] as? String)
        case "section": self = .section(text: text ?? "", afterId: op["after_id"] as? String)
        case "remove": self = .remove(rowId: rowId ?? "")
        case "folder": self = .folder(op["folder"] as? String ?? "")
        case "rename": self = .rename(text: text ?? "")
        case "remove_list": self = .removeList
        case "clear_done": self = .clearDone
        case "restore": self = .restore(rowId: rowId, title: op["title"] as? String)
        default: return nil
        }
    }
}
#endif
