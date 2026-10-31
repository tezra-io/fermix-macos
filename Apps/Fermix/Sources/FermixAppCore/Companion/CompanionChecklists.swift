import Foundation

// MARK: - The owner's lists (version 6, M85)

/// Where an add or a move puts a row: at the end of a section, or right after
/// a row. The contract takes one of the two, never both, so they are cases of
/// one value; with neither the engine puts the row at the end of the list's
/// first group.
public enum CompanionChecklistPlace: Equatable, Sendable {
    /// At the end of the section this heading's `ci_` id names.
    case section(String)
    /// Right after the row this `ci_` id names.
    case after(String)
}

/// One op of `checklist_edit`: the model's ops by row id without its
/// `replace`, with `clear_done` and `restore`. Each case carries exactly the
/// fields the contract's op takes, so an op the engine would refuse for its
/// shape cannot be built.
public enum CompanionChecklistOp: Equatable, Sendable, Encodable {
    /// Makes a list, in a folder when one is named.
    case create(title: String, folder: String?)
    case add(text: String, note: String?, place: CompanionChecklistPlace?)
    case check(rowId: String)
    case uncheck(rowId: String)
    /// Changes an item's words, its note or both; an empty note clears it.
    case edit(rowId: String, text: String?, note: String?)
    /// Within the list, or to another list placed as an add is there.
    case move(rowId: String, place: CompanionChecklistPlace?, toListId: String?)
    /// A section heading, after a row that ends its section, or at the end.
    case section(text: String, afterId: String?)
    case remove(rowId: String)
    /// Puts the list in a folder; an empty name takes it out of its folder.
    case folder(String)
    case rename(text: String)
    case removeList
    case clearDone
    /// With a row, brings that removed row back; without one, the removed
    /// list itself, under `title` when given.
    case restore(rowId: String?, title: String?)

    /// The contract's word for the op.
    public var word: String {
        switch self {
        case .create: return "create"
        case .add: return "add"
        case .check: return "check"
        case .uncheck: return "uncheck"
        case .edit: return "edit"
        case .move: return "move"
        case .section: return "section"
        case .remove: return "remove"
        case .folder: return "folder"
        case .rename: return "rename"
        case .removeList: return "remove_list"
        case .clearDone: return "clear_done"
        case .restore: return "restore"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case op, title, folder, text, note
        case rowId = "row_id"
        case sectionId = "section_id"
        case afterId = "after_id"
        case toListId = "to_list_id"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(word, forKey: .op)

        switch self {
        case .create(let title, let folder):
            try container.encode(title, forKey: .title)
            try container.encodeIfPresent(folder, forKey: .folder)
        case .add(let text, let note, let place):
            try container.encode(text, forKey: .text)
            try container.encodeIfPresent(note, forKey: .note)
            try Self.encode(place, into: &container)
        case .check(let rowId), .uncheck(let rowId), .remove(let rowId):
            try container.encode(rowId, forKey: .rowId)
        case .edit(let rowId, let text, let note):
            try container.encode(rowId, forKey: .rowId)
            try container.encodeIfPresent(text, forKey: .text)
            try container.encodeIfPresent(note, forKey: .note)
        case .move(let rowId, let place, let toListId):
            try container.encode(rowId, forKey: .rowId)
            try Self.encode(place, into: &container)
            try container.encodeIfPresent(toListId, forKey: .toListId)
        case .section(let text, let afterId):
            try container.encode(text, forKey: .text)
            try container.encodeIfPresent(afterId, forKey: .afterId)
        case .folder(let folder):
            try container.encode(folder, forKey: .folder)
        case .rename(let text):
            try container.encode(text, forKey: .text)
        case .removeList, .clearDone:
            break
        case .restore(let rowId, let title):
            try container.encodeIfPresent(rowId, forKey: .rowId)
            try container.encodeIfPresent(title, forKey: .title)
        }
    }

    private static func encode(
        _ place: CompanionChecklistPlace?,
        into container: inout KeyedEncodingContainer<CodingKeys>
    ) throws {
        switch place {
        case .section(let id)?: try container.encode(id, forKey: .sectionId)
        case .after(let id)?: try container.encode(id, forKey: .afterId)
        case nil: break
        }
    }
}

/// One list in the index: its id, its title, its folder when it is in one,
/// how many of its items are open and done, and its rev, which moves with
/// every change to it.
public struct CompanionChecklistEntry: Equatable, Sendable, Decodable, Identifiable {
    public let listId: String
    public let title: String
    public let folder: String?
    public let open: Int
    public let done: Int
    public let rev: Int

    public var id: String { listId }

    public init(listId: String, title: String, folder: String?, open: Int, done: Int, rev: Int) {
        self.listId = listId
        self.title = title
        self.folder = folder
        self.open = open
        self.done = done
        self.rev = rev
    }

    private enum CodingKeys: String, CodingKey {
        case title, folder, open, done, rev
        case listId = "list_id"
    }
}

/// What a row is, in the contract's word. A word this build does not know
/// keeps its own, and its row is drawn as nothing.
public enum CompanionChecklistRowKind: Equatable, Sendable, Decodable {
    case item
    case section
    case unrecognized(String)

    public init(wireValue: String) {
        switch wireValue {
        case "item": self = .item
        case "section": self = .section
        default: self = .unrecognized(wireValue)
        }
    }

    public init(from decoder: Decoder) throws {
        self.init(wireValue: try decoder.singleValueContainer().decode(String.self))
    }
}

/// One row of a list: an item, with whether it is done and its note and
/// when it was done where it has them, or a section heading, which has
/// none of the three. A removed row carries when it was removed. `rowId` is
/// stable for the row's life, across moves and edits.
public struct CompanionChecklistRow: Equatable, Sendable, Decodable, Identifiable {
    public let rowId: String
    public let kind: CompanionChecklistRowKind
    public let text: String
    public let done: Bool?
    public let note: String?
    public let doneAt: String?
    public let removedAt: String?

    public var id: String { rowId }

    public init(
        rowId: String,
        kind: CompanionChecklistRowKind,
        text: String,
        done: Bool?,
        note: String? = nil,
        doneAt: String? = nil,
        removedAt: String? = nil
    ) {
        self.rowId = rowId
        self.kind = kind
        self.text = text
        self.done = done
        self.note = note
        self.doneAt = doneAt
        self.removedAt = removedAt
    }

    /// Whether the row is an item that is done. A heading never is.
    public var isDone: Bool { kind == .item && done == true }

    private enum CodingKeys: String, CodingKey {
        case kind, text, done, note
        case rowId = "row_id"
        case doneAt = "done_at"
        case removedAt = "removed_at"
    }
}

/// A whole list, its rows in order. `removed` holds the rows removed in the
/// last 30 days, newest first, only when the pull asked for them, and
/// `removedAt` is set only on a list that was itself removed and is not yet
/// swept.
public struct CompanionChecklistList: Equatable, Sendable, Decodable, Identifiable {
    public let listId: String
    public let title: String
    public let rev: Int
    public let rows: [CompanionChecklistRow]
    public let removed: [CompanionChecklistRow]?
    public let removedAt: String?

    public var id: String { listId }

    public init(
        listId: String,
        title: String,
        rev: Int,
        rows: [CompanionChecklistRow],
        removed: [CompanionChecklistRow]? = nil,
        removedAt: String? = nil
    ) {
        self.listId = listId
        self.title = title
        self.rev = rev
        self.rows = rows
        self.removed = removed
        self.removedAt = removedAt
    }

    private enum CodingKeys: String, CodingKey {
        case title, rev, rows, removed
        case listId = "list_id"
        case removedAt = "removed_at"
    }
}

/// One list a reply's turn read or changed, as its `checklists` block names
/// it: its id, its title when the turn ended, and the ids of the rows the
/// turn added or changed, none for a list it only read. Ids and the title
/// only: the rows are drawn as they stand now.
public struct CompanionChecklistRef: Equatable, Hashable, Sendable, Decodable {
    public let listId: String
    public let title: String
    public let rows: [String]

    public init(listId: String, title: String, rows: [String]) {
        self.listId = listId
        self.title = title
        self.rows = rows
    }

    private enum CodingKeys: String, CodingKey {
        case title, rows
        case listId = "list_id"
    }
}
