import Combine
import Foundation

/// One list as this Mac holds it (M85 §09), as a value: the engine's last
/// push, the edits sent and not yet confirmed, and the engine's sentence for
/// the last one it refused. No socket and no main actor, so every rule is a
/// step a test can take.
struct ChecklistState: Equatable, Sendable {
    /// The list as the engine last sent it, nil until a pull is answered.
    private(set) var engine: CompanionChecklistList?
    /// Oldest first, each applied over `engine` until a push confirms it.
    private(set) var pending: [ChecklistPendingEdit] = []
    /// The engine's sentence for the last edit it refused, until the next.
    private(set) var refusal: String?
    /// A pull was refused: the engine has no list with this id any more.
    private(set) var gone: String?

    /// What every view draws: the engine's list with every edit not yet
    /// confirmed applied over it, in the order they were made.
    var shown: CompanionChecklistList? {
        engine.map { ChecklistDraft.applying(pending, to: $0) }
    }

    /// An edit the owner made here: drawn at once, and sent.
    mutating func edit(_ op: CompanionChecklistOp, clientMsgId: String) {
        pending.append(ChecklistPendingEdit(clientMsgId: clientMsgId, op: op))
        refusal = nil
    }

    /// Whether an edit of this list waits on this id.
    func owns(_ clientMsgId: String) -> Bool {
        pending.contains { $0.clientMsgId == clientMsgId }
    }

    /// The engine took the edit. Its change is in the next list it sends.
    mutating func accepted(_ clientMsgId: String) {
        guard let index = pending.firstIndex(where: { $0.clientMsgId == clientMsgId }) else { return }

        pending[index].accepted = true
    }

    /// A list the engine sent: the answer to a pull, or a push after a
    /// change. One whose rev is below the one shown is dropped, so a late
    /// answer never takes back a change already drawn. Every edit the engine
    /// had accepted is in it, and so is every add it names in `made`; the
    /// rest stay applied over it. Answers whether the list was taken.
    @discardableResult
    mutating func received(_ list: CompanionChecklistList, made: [String: String]) -> Bool {
        if let engine, list.rev < engine.rev { return false }

        engine = list
        gone = nil
        pending.removeAll { $0.accepted || made[$0.clientMsgId] != nil }
        return true
    }

    /// The engine refused the edit: it changed nothing, so it stops being
    /// drawn and the row is the engine's again, with the engine's sentence.
    mutating func refused(_ clientMsgId: String, sentence: String) {
        pending.removeAll { $0.clientMsgId == clientMsgId }
        refusal = sentence
    }

    /// The engine has no list with this id: removed more than 30 days ago.
    mutating func pullRefused(_ sentence: String) {
        gone = sentence
    }

    /// The edits the engine has not answered, oldest first: the ones a new
    /// connection sends again.
    var unanswered: [ChecklistPendingEdit] {
        pending.filter { !$0.accepted }
    }

    /// Whether the row was made here and the engine has not named it yet.
    static func isSending(_ rowId: String) -> Bool {
        ChecklistDraft.isLocal(rowId)
    }
}

/// One list for every view that draws it (M85 §09): the card under a reply
/// and the panel beside the chat observe the same store, so they never
/// disagree. The library owns it and is its only writer.
@MainActor
public final class ChecklistStore: ObservableObject, Identifiable {
    public let listId: String
    @Published private(set) var state = ChecklistState()

    public nonisolated var id: String { listId }

    init(listId: String) {
        self.listId = listId
    }

    /// The list as drawn: the engine's, with the edits sent here applied.
    public var shown: CompanionChecklistList? { state.shown }
    public var refusal: String? { state.refusal }
    /// The list was removed: the engine says so, or no longer has it.
    public var isRemoved: Bool { state.gone != nil || state.shown?.removedAt != nil }

    func change(_ step: (inout ChecklistState) -> Void) {
        var next = state
        step(&next)
        guard next != state else { return }

        state = next
    }
}

/// The index of the owner's lists, in picker order, as the engine last sent
/// it (M85 §07), and whether the daemon serves lists at all: the Lists
/// button is drawn only where it does.
@MainActor
public final class ChecklistIndexStore: ObservableObject {
    /// The daemon's window reaches the version that brings lists.
    @Published public private(set) var served = false
    /// Nil until the index is answered.
    @Published public private(set) var entries: [CompanionChecklistEntry]?
    /// The engine's sentence for a refused pull of the index, or a refused
    /// new list, until the next one.
    @Published public private(set) var refusal: String?
    /// The list the newest create sent here made, with that create's id, so
    /// the panel shows it once it exists.
    @Published public private(set) var created: ChecklistCreated?

    init() {}

    public func entry(_ listId: String) -> CompanionChecklistEntry? {
        entries?.first { $0.listId == listId }
    }

    /// The folders in picker order, each with its lists, then the lists in
    /// no folder (M85 §09).
    public var folders: ChecklistFolders {
        ChecklistFolders(entries ?? [])
    }

    func serve(_ served: Bool) {
        if self.served != served { self.served = served }
    }

    func show(_ entries: [CompanionChecklistEntry]) {
        if self.entries != entries { self.entries = entries }
        if refusal != nil { refusal = nil }
    }

    func refuse(_ sentence: String?) {
        if refusal != sentence { refusal = sentence }
    }

    func made(_ created: ChecklistCreated) {
        self.created = created
    }
}

/// A create sent from here and the list it made.
public struct ChecklistCreated: Equatable, Sendable {
    public let clientMsgId: String
    public let listId: String
}

/// The picker's order (M85 §09): each folder as a heading over its lists, in
/// the order the index first names it, then the lists in no folder.
public struct ChecklistFolders: Equatable {
    public struct Folder: Equatable, Identifiable {
        public let name: String
        public let lists: [CompanionChecklistEntry]
        public var id: String { name }
    }

    public let folders: [Folder]
    public let loose: [CompanionChecklistEntry]

    init(_ entries: [CompanionChecklistEntry]) {
        var names: [String] = []
        for entry in entries {
            guard let folder = entry.folder, !names.contains(folder) else { continue }
            names.append(folder)
        }

        folders = names.map { name in Folder(name: name, lists: entries.filter { $0.folder == name }) }
        loose = entries.filter { $0.folder == nil }
    }

    /// The folder names, in picker order.
    public var names: [String] { folders.map(\.name) }
}

/// What a connection has asked about lists and not had answered, in the
/// order asked: the daemon answers each pull in the step that reads it, so
/// a refusal that names no edit answers the oldest pull out.
enum ChecklistPull: Equatable, Sendable {
    case index
    case list(String)
}

/// Every list this Mac draws, and the connection's share of them (M85 §07).
///
/// It mirrors what the engine holds for this connection: each list pulled,
/// in the order pulled, at most 16, a pull past that letting the oldest go.
/// A list is pulled when a card or the panel first draws it, and every list
/// held is pulled again at each handshake, after the index. An edit is drawn
/// at once and sent; one the engine has not answered when the connection
/// drops is sent again at the next handshake, in the order it was made, and
/// the engine's `client_msg_id` dedup makes it land once. The session feeds
/// it every list event and the answers to its edits, and nothing else writes
/// it.
@MainActor
public final class ChecklistLibrary {
    /// The most lists a connection holds (the contract's 16).
    static let heldLimit = 16

    public let index = ChecklistIndexStore()

    private var stores: [String: ChecklistStore] = [:]
    /// The lists the engine holds for this connection, or will once the
    /// next handshake pulls them again, oldest pull first.
    private var held: [String] = []
    /// The held lists pulled with their removed rows.
    private var withRemoved: Set<String> = []
    private var pullsOut: [ChecklistPull] = []
    /// Every edit sent and not yet answered, in the order made: a create
    /// names no list.
    private var unanswered: [ChecklistOutboxEntry] = []
    /// The creates the engine accepted, waiting for the push that says what
    /// each made.
    private var creating: Set<String> = []
    private var connected = false

    private let send: (CompanionClientEvent) -> Bool
    private let messageIds: () -> String

    init(send: @escaping (CompanionClientEvent) -> Bool, messageIds: @escaping () -> String) {
        self.send = send
        self.messageIds = messageIds
    }

    /// The one store for this list, made the first time it is asked for.
    public func store(_ listId: String) -> ChecklistStore {
        if let store = stores[listId] { return store }

        let store = ChecklistStore(listId: listId)
        stores[listId] = store
        return store
    }

    // MARK: - What the views ask

    /// A card or the panel draws this list: it is pulled unless the engine
    /// holds it already, with its removed rows where Recently removed is
    /// shown. Asked before a handshake, it is pulled at the handshake.
    public func draw(_ listId: String, removed: Bool = false) {
        let holds = held.contains(listId) && (!removed || withRemoved.contains(listId))
        guard !holds else { return }

        hold(listId, removed: removed)
        pull(listId, removed: removed)
    }

    /// One edit of a list: drawn at once and sent. A text the engine would
    /// trim to nothing is no edit.
    public func edit(_ listId: String, _ op: CompanionChecklistOp) {
        guard Self.isSendable(op) else { return }

        let entry = ChecklistOutboxEntry(clientMsgId: messageIds(), listId: listId, op: op)
        store(listId).change { $0.edit(op, clientMsgId: entry.clientMsgId) }
        draw(listId)
        unanswered.append(entry)
        deliver(entry.event)
    }

    /// A new list, in a folder when one is named. It is drawn once the
    /// engine has made it: the index store then says what this create made,
    /// and the panel turns to it.
    @discardableResult
    public func create(title: String, folder: String?) -> String? {
        let op = CompanionChecklistOp.create(title: title, folder: folder)
        guard Self.isSendable(op) else { return nil }

        let entry = ChecklistOutboxEntry(clientMsgId: messageIds(), listId: nil, op: op)
        index.refuse(nil)
        unanswered.append(entry)
        deliver(entry.event)
        return entry.clientMsgId
    }

    /// A text the engine trims to nothing is refused, so it is not sent.
    private static func isSendable(_ op: CompanionChecklistOp) -> Bool {
        switch op {
        case .create(let words, _), .add(let words, _, _), .section(let words, _), .rename(let words):
            return !words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .edit(_, let text, let note):
            guard let text else { return note != nil }
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        default:
            return true
        }
    }

    // MARK: - The connection

    /// A handshake completed. A daemon whose window reaches lists is asked
    /// for the index, then for every list held, in the order they were
    /// pulled, then sent every edit it has not answered, in the order made.
    func negotiated(serves: Bool) {
        connected = true
        pullsOut = []
        index.serve(serves)

        pullIndex()
        for listId in held {
            pull(listId, removed: withRemoved.contains(listId))
        }
        for entry in unanswered {
            deliver(entry.event)
        }
    }

    /// The connection ended: nothing asked on it will be answered. What is
    /// held is kept, to be pulled again at the next handshake.
    func disconnected() {
        connected = false
        pullsOut = []
    }

    /// A list event, which only this owns.
    func receive(_ event: CompanionServerEvent) {
        switch event {
        case .checklists(_, let lists):
            answered(.index)
            index.show(lists)
        case .checklist(_, let list, let made):
            received(list, made: made)
        default:
            break
        }
    }

    /// An `accepted` for one of the edits sent here, or false for any other.
    func accepted(_ receipt: CompanionAccepted) -> Bool {
        guard let at = unanswered.firstIndex(where: { $0.clientMsgId == receipt.clientMsgId }) else { return false }

        let entry = unanswered.remove(at: at)
        guard let listId = entry.listId else {
            creating.insert(entry.clientMsgId)
            return true
        }

        store(listId).change { $0.accepted(entry.clientMsgId) }
        return true
    }

    /// A refusal of one of the edits sent here, or, when it names no request
    /// and no media ref, of the oldest pull out; false for any other. A
    /// refused edit's list is pulled again, as the contract asks.
    func refused(_ error: CompanionServerError) -> Bool {
        let sentence = error.message ?? String(format: ProductStrings[.companionErrorRefusedFormat], error.reason)

        if let clientMsgId = error.clientMsgId {
            return refusedEdit(clientMsgId, sentence: sentence)
        }
        guard error.reason == Self.requestFailed, error.ref == nil, !pullsOut.isEmpty else { return false }

        switch pullsOut.removeFirst() {
        case .index:
            index.refuse(sentence)
        case .list(let listId):
            held.removeAll { $0 == listId }
            withRemoved.remove(listId)
            store(listId).change { $0.pullRefused(sentence) }
        }
        return true
    }

    private static let requestFailed = "request_failed"

    private func refusedEdit(_ clientMsgId: String, sentence: String) -> Bool {
        guard let at = unanswered.firstIndex(where: { $0.clientMsgId == clientMsgId }) else { return false }

        let entry = unanswered.remove(at: at)
        guard let listId = entry.listId else {
            index.refuse(sentence)
            return true
        }

        store(listId).change { $0.refused(clientMsgId, sentence: sentence) }
        pull(listId, removed: withRemoved.contains(listId))
        return true
    }

    // MARK: - The wire

    private func received(_ list: CompanionChecklistList, made: [String: String]) {
        answered(.list(list.listId))

        for (clientMsgId, madeId) in made where creating.remove(clientMsgId) != nil {
            hold(madeId, removed: false)
            index.made(ChecklistCreated(clientMsgId: clientMsgId, listId: madeId))
        }

        store(list.listId).change { $0.received(list, made: made) }
    }

    /// Mirrors the engine's holding: the list becomes the newest pulled, and
    /// past 16 the oldest is let go, so nothing more of it arrives until it
    /// is drawn again.
    private func hold(_ listId: String, removed: Bool) {
        held.removeAll { $0 == listId }
        held.append(listId)
        if removed { withRemoved.insert(listId) } else { withRemoved.remove(listId) }

        while held.count > Self.heldLimit {
            withRemoved.remove(held.removeFirst())
        }
    }

    private func pullIndex() {
        guard deliver(.checklistsPull(profileId: CompanionProtocol.profileId)) else { return }

        pullsOut.append(.index)
    }

    private func pull(_ listId: String, removed: Bool) {
        guard deliver(.checklistPull(profileId: CompanionProtocol.profileId, listId: listId, removed: removed)) else { return }

        pullsOut.append(.list(listId))
    }

    private func answered(_ pull: ChecklistPull) {
        guard let at = pullsOut.firstIndex(of: pull) else { return }

        pullsOut.remove(at: at)
    }

    /// Sends on a negotiated connection to a daemon that serves lists, and
    /// says whether it did. Nothing is sent otherwise: what is drawn
    /// meanwhile is pulled, and what is edited sent, at the next handshake.
    @discardableResult
    private func deliver(_ event: CompanionClientEvent) -> Bool {
        guard connected, index.served else { return false }

        return send(event)
    }
}

/// An edit sent and not yet answered, as it goes on the wire every time it
/// is sent: the engine applies one `client_msg_id` once.
struct ChecklistOutboxEntry: Equatable, Sendable {
    let clientMsgId: String
    /// Nil for a create.
    let listId: String?
    let op: CompanionChecklistOp

    var event: CompanionClientEvent {
        .checklistEdit(clientMsgId: clientMsgId, profileId: CompanionProtocol.profileId, listId: listId, op: op)
    }
}
