import Foundation
import Testing

@testable import FermixAppCore

/// The golden Groceries list (`checklist`, rev 7): Bread in the first group,
/// then Produce with Lemons, Basil done, and Rice.
private enum Groceries {
    static let id = "ck_4q8m2x7v1d"
    static let bread = "ci_8f3k2m9q1x"
    static let produce = "ci_5w7p0t4n6b"
    static let lemons = "ci_0r2y8e6u3g"
    static let basil = "ci_3h9d1v8r2k"
    static let rice = "ci_6j4c7x0m5s"

    static func list(rev: Int = 7, rows: [CompanionChecklistRow]? = nil) -> CompanionChecklistList {
        CompanionChecklistList(listId: id, title: "Groceries", rev: rev, rows: rows ?? [
            CompanionChecklistRow(rowId: bread, kind: .item, text: "Bread", done: false),
            CompanionChecklistRow(rowId: produce, kind: .section, text: "Produce", done: nil),
            CompanionChecklistRow(rowId: lemons, kind: .item, text: "Lemons", done: false, note: "The unwaxed ones"),
            CompanionChecklistRow(rowId: basil, kind: .item, text: "Basil", done: true, doneAt: "2031-06-02T14:00:00.000000Z"),
            CompanionChecklistRow(rowId: rice, kind: .item, text: "Rice", done: false)
        ])
    }

    static func texts(_ list: CompanionChecklistList?) -> [String] {
        list?.rows.map(\.text) ?? []
    }
}

/// One list as this Mac holds it (M85 §09): an edit drawn at once, the next
/// pushed rev confirming it, a stale push dropped, a refusal putting the row
/// back with the engine's sentence, and what an add made.
@Suite("Checklist state")
struct ChecklistStateTests {
    @Test("an edit is drawn at once, over the engine's list")
    func editIsDrawnAtOnce() {
        var state = ChecklistState()
        state.received(Groceries.list(), made: [:])

        state.edit(.check(rowId: Groceries.lemons), clientMsgId: "mac-1")

        #expect(state.shown?.rows.first { $0.rowId == Groceries.lemons }?.isDone == true)
        #expect(state.shown?.openCount == 2)
        #expect(state.engine?.rows.first { $0.rowId == Groceries.lemons }?.isDone == false, "the engine's own list is untouched")
    }

    @Test("an accepted edit is confirmed by the next list the engine sends, and one not yet accepted stays drawn over it")
    func pushConfirmsAcceptedEdits() {
        var state = ChecklistState()
        state.received(Groceries.list(), made: [:])
        state.edit(.check(rowId: Groceries.lemons), clientMsgId: "mac-1")
        state.edit(.rename(text: "Weekly groceries"), clientMsgId: "mac-2")
        state.accepted("mac-1")

        let pushed = Groceries.list(rev: 8).rows.map { row in
            row.rowId == Groceries.lemons ? CompanionChecklistRow(rowId: row.rowId, kind: .item, text: row.text, done: true, note: row.note) : row
        }
        state.received(Groceries.list(rev: 8, rows: pushed), made: [:])

        #expect(state.pending.map(\.clientMsgId) == ["mac-2"])
        #expect(state.shown?.title == "Weekly groceries")
        #expect(state.shown?.rows.first { $0.rowId == Groceries.lemons }?.isDone == true)
        #expect(state.unanswered.map(\.clientMsgId) == ["mac-2"])
    }

    @Test("a list whose rev is below the one shown is dropped")
    func staleRevIsDropped() {
        var state = ChecklistState()
        state.received(Groceries.list(rev: 8), made: [:])

        let taken = state.received(Groceries.list(rev: 7, rows: []), made: [:])

        #expect(!taken)
        #expect(state.engine?.rev == 8)
        #expect(state.shown?.rows.count == 5)
        let again = state.received(Groceries.list(rev: 8, rows: []), made: [:])
        #expect(again, "the same rev again is taken")
    }

    @Test("a refused edit stops being drawn, and the row is the engine's again with the engine's sentence")
    func refusalPutsTheRowBack() {
        var state = ChecklistState()
        state.received(Groceries.list(), made: [:])
        state.edit(.check(rowId: Groceries.rice), clientMsgId: "mac-1")
        #expect(state.shown?.rows.last?.isDone == true)

        state.refused("mac-1", sentence: "That row is not in this list any more; pull the list again.")

        #expect(state.shown?.rows.last?.isDone == false)
        #expect(state.refusal == "That row is not in this list any more; pull the list again.")
        #expect(state.pending.isEmpty)

        state.edit(.uncheck(rowId: Groceries.basil), clientMsgId: "mac-2")
        #expect(state.refusal == nil, "the next edit clears the sentence")
    }

    @Test("an add is drawn under a local id until the list that names it in made arrives")
    func addIsNamedByMade() throws {
        var state = ChecklistState()
        state.received(Groceries.list(), made: [:])
        state.edit(.add(text: "Bread", note: nil, place: .after(Groceries.bread)), clientMsgId: "mac-22")

        let local = try #require(state.shown?.rows[1])
        #expect(local.text == "Bread")
        #expect(ChecklistState.isSending(local.rowId))

        var rows = Groceries.list().rows
        rows.insert(CompanionChecklistRow(rowId: "ci_9x9x9x9x9x", kind: .item, text: "Bread", done: false), at: 1)
        state.received(Groceries.list(rev: 8, rows: rows), made: ["mac-22": "ci_9x9x9x9x9x"])

        #expect(state.pending.isEmpty, "made confirms the add even before its accepted")
        #expect(state.shown?.rows.filter { $0.text == "Bread" }.count == 2)
        #expect(state.shown?.rows.contains { ChecklistState.isSending($0.rowId) } == false)
    }
}

/// An edit drawn before the engine answers lands where the engine would put
/// it (`Checklists.Ops`).
@Suite("Checklist draft")
struct ChecklistDraftTests {
    private func applying(_ op: CompanionChecklistOp, to list: CompanionChecklistList = Groceries.list()) -> CompanionChecklistList {
        ChecklistDraft.applying(op, id: "mac-1", to: list)
    }

    @Test("an add goes to the end of its section, right after its row, or to the end of the first group")
    func addPlacement() {
        #expect(Groceries.texts(applying(.add(text: "Milk", note: nil, place: .section(Groceries.produce))))
            == ["Bread", "Produce", "Lemons", "Basil", "Rice", "Milk"])
        #expect(Groceries.texts(applying(.add(text: "Milk", note: nil, place: .after(Groceries.lemons))))
            == ["Bread", "Produce", "Lemons", "Milk", "Basil", "Rice"])
        #expect(Groceries.texts(applying(.add(text: "Milk", note: nil, place: nil)))
            == ["Bread", "Milk", "Produce", "Lemons", "Basil", "Rice"], "the items above the first heading")

        let headed = Groceries.list(rows: Array(Groceries.list().rows.dropFirst()))
        #expect(Groceries.texts(applying(.add(text: "Milk", note: nil, place: nil), to: headed))
            == ["Produce", "Lemons", "Basil", "Rice", "Milk"], "or else the first section")
        #expect(Groceries.texts(applying(.add(text: "Milk", note: nil, place: nil), to: Groceries.list(rows: []))) == ["Milk"])
    }

    @Test("a move within the list lands as an add would, and a move to another list leaves it")
    func movePlacement() {
        #expect(Groceries.texts(applying(.move(rowId: Groceries.bread, place: .section(Groceries.produce), toListId: nil)))
            == ["Produce", "Lemons", "Basil", "Rice", "Bread"])
        #expect(Groceries.texts(applying(.move(rowId: Groceries.rice, place: .after(Groceries.produce), toListId: nil)))
            == ["Bread", "Produce", "Rice", "Lemons", "Basil"])
        #expect(Groceries.texts(applying(.move(rowId: Groceries.rice, place: nil, toListId: "ck_9t3k6w0p5h")))
            == ["Bread", "Produce", "Lemons", "Basil"])
        #expect(Groceries.texts(applying(.move(rowId: Groceries.produce, place: nil, toListId: "ck_9t3k6w0p5h")))
            == Groceries.texts(Groceries.list()), "a heading is not moved")
    }

    @Test("check, edit, remove, rename and clear done change what they name, and the engine's ops change nothing here")
    func otherOps() {
        #expect(applying(.check(rowId: Groceries.produce)) == Groceries.list(), "a heading is never done")
        #expect(applying(.uncheck(rowId: Groceries.basil)).doneCount == 0)

        let reworded = applying(.edit(rowId: Groceries.lemons, text: "Limes", note: "")).rows[2]
        #expect(reworded.text == "Limes")
        #expect(reworded.note == nil, "an empty note clears it")
        #expect(applying(.edit(rowId: Groceries.lemons, text: nil, note: "Two")).rows[2].text == "Lemons")

        #expect(Groceries.texts(applying(.remove(rowId: Groceries.bread))) == ["Produce", "Lemons", "Basil", "Rice"])
        #expect(applying(.rename(text: "Weekly")).title == "Weekly")
        #expect(Groceries.texts(applying(.clearDone)) == ["Bread", "Produce", "Lemons", "Rice"])
        #expect(Groceries.texts(applying(.section(text: "Dairy", afterId: nil))).last == "Dairy")

        for op: CompanionChecklistOp in [.folder("Home"), .removeList, .restore(rowId: Groceries.basil, title: nil)] {
            #expect(applying(op) == Groceries.list(), "\(op.word) is drawn when the engine pushes it")
        }
    }

    @Test("a list reads as the model's checklist text, each section under its heading")
    func markdown() {
        #expect(Groceries.list().markdown == """
        # Groceries
        - [ ] Bread

        ## Produce
        - [ ] Lemons
          The unwaxed ones
        - [x] Basil
        - [ ] Rice
        """)
    }

    @Test("a list's sections are its first group and each heading with its items")
    func sections() {
        let sections = ChecklistSection.sections(of: Groceries.list().rows)

        #expect(sections.map { $0.heading?.text } == [nil, "Produce"])
        #expect(sections.map { $0.items.map(\.text) } == [["Bread"], ["Lemons", "Basil", "Rice"]])
    }
}

private typealias E = CompanionEvents

/// The lists over a session on the real adapter (M85 §07): the index pulled
/// at each handshake, a list pulled when it is drawn, the engine's holding
/// mirrored, edits answered and sent again, and refusals kept apart from the
/// chat's.
@Suite("Checklist library")
@MainActor
struct ChecklistLibraryTests {
    private let socket = FakeCompanionSocket()
    private let scheduler = ManualDeadlineScheduler()
    private let session: CompanionSession

    init() {
        var issued = 0
        session = CompanionSession(
            transport: CompanionSocketClient(lines: socket),
            socketPath: { "/tmp/fermix-test/companion.sock" },
            deadlines: scheduler,
            messageIds: {
                issued += 1
                return "mac-\(issued)"
            }
        )
    }

    private var lists: ChecklistLibrary { session.lists }

    private func connected() {
        session.connect()
        socket.deliver(E.hello())
    }

    /// The lines sent after the hello and the newest page.
    private func listLines() throws -> [NSDictionary] {
        try Array(socket.sentObjects().dropFirst(2))
    }

    private func wire(_ events: CompanionClientEvent...) throws -> [NSDictionary] {
        try events.map(wireObject(companion:))
    }

    /// The daemon's index, naming these lists.
    private func index(_ ids: String...) {
        socket.deliver(.checklists(profileId: Self.main, lists: ids.map {
            CompanionChecklistEntry(listId: $0, title: $0 == Groceries.id ? "Groceries" : $0, folder: nil, open: 0, done: 0, rev: 1)
        }))
    }

    /// The list pulls sent, by list id, in order.
    private func pulls() throws -> [String] {
        try socket.sentObjects().compactMap { $0["type"] as? String == "checklist_pull" ? $0["list_id"] as? String : nil }
    }

    private static let main = CompanionProtocol.profileId

    private static func refusal(_ message: String, clientMsgId: String? = nil) -> CompanionServerEvent {
        .error(CompanionServerError(
            reason: "request_failed",
            message: message,
            field: nil,
            event: nil,
            clientMsgId: clientMsgId,
            direction: nil,
            clientVersion: nil,
            minVersion: nil,
            maxVersion: nil,
            ref: nil
        ))
    }

    @Test("a daemon that serves lists is asked for the index after the catch-up read, and the index is shown")
    func indexOnHandshake() throws {
        connected()

        #expect(lists.index.served)
        #expect(try listLines() == wire(.checklistsPull(profileId: Self.main)))

        let entry = CompanionChecklistEntry(listId: Groceries.id, title: "Groceries", folder: nil, open: 3, done: 1, rev: 7)
        socket.deliver(.checklists(profileId: Self.main, lists: [entry]))
        #expect(lists.index.entries == [entry])
    }

    @Test("a list is pulled once when it is first drawn, and the push lands in its one store")
    func drawPullsOnce() throws {
        connected()
        index(Groceries.id)

        lists.draw(Groceries.id)
        lists.draw(Groceries.id)
        socket.deliver(.checklist(profileId: Self.main, list: Groceries.list()))

        #expect(try listLines() == wire(
            .checklistsPull(profileId: Self.main),
            .checklistPull(profileId: Self.main, listId: Groceries.id)
        ))
        #expect(lists.store(Groceries.id) === lists.store(Groceries.id))
        #expect(lists.store(Groceries.id).shown == Groceries.list())

        lists.draw(Groceries.id, removed: true)
        #expect(try listLines().last == wireObject(companion: .checklistPull(profileId: Self.main, listId: Groceries.id, removed: true)))
    }

    @Test("past sixteen lists the oldest pulled is let go, and drawing it again pulls it again")
    func holdingMirrorsTheEngine() throws {
        connected()
        let ids = (0..<17).map { String(format: "ck_%010d", $0) }
        socket.deliver(.checklists(profileId: Self.main, lists: ids.map {
            CompanionChecklistEntry(listId: $0, title: $0, folder: nil, open: 0, done: 0, rev: 1)
        }))

        ids.forEach { lists.draw($0) }
        lists.draw(ids[1])
        lists.draw(ids[0])

        let pulled = try listLines().compactMap { $0["list_id"] as? String }
        #expect(pulled == ids + [ids[0]], "the first was let go when the seventeenth was pulled; the second is still held")
    }

    /// Every pull makes its list the newest held, as the engine's
    /// `Checklists.hold` does, the pull a refused edit sends again included:
    /// otherwise the two let go of different lists past sixteen, and the one
    /// the app thinks it still holds hears nothing more.
    @Test("a list pulled again after a refused edit is the newest held, so the seventeenth lets go of the same list the engine does")
    func refusalPullIsTheNewestHeld() throws {
        connected()
        let ids = (1...17).map { String(format: "ck_%010d", $0) }
        socket.deliver(.checklists(profileId: Self.main, lists: ids.map {
            CompanionChecklistEntry(listId: $0, title: $0, folder: nil, open: 0, done: 0, rev: 1)
        }))

        ids.prefix(16).forEach { lists.draw($0) }
        lists.edit(ids[0], .rename(text: "Weekly"))
        socket.deliver(Self.refusal("That list is gone.", clientMsgId: "mac-1"))
        lists.draw(ids[16])
        lists.draw(ids[1])
        lists.draw(ids[0])

        let pulled = try listLines().compactMap { $0["type"] as? String == "checklist_pull" ? $0["list_id"] as? String : nil }
        #expect(pulled == Array(ids.prefix(16)) + [ids[0], ids[16], ids[1]], "the engine let the second go; the first, pulled again, is held")
    }

    @Test("what is drawn before the handshake is pulled once the index answers, and only if the index holds it")
    func drawBeforeHandshake() throws {
        lists.draw(Groceries.id)
        lists.draw("ck_0000000000")
        #expect(socket.sent.isEmpty)

        connected()
        #expect(try listLines() == wire(.checklistsPull(profileId: Self.main)), "no list is pulled before the index says it lives")

        index(Groceries.id)
        #expect(try listLines() == wire(
            .checklistsPull(profileId: Self.main),
            .checklistPull(profileId: Self.main, listId: Groceries.id)
        ))
    }

    @Test("an edit is drawn at once and sent, its accepted is the lists' and not the chat's, and the push confirms it")
    func editRoundTrip() throws {
        connected()
        index(Groceries.id)
        lists.draw(Groceries.id)
        socket.deliver(.checklist(profileId: Self.main, list: Groceries.list()))

        lists.edit(Groceries.id, .check(rowId: Groceries.lemons))

        #expect(try listLines().last == wireObject(companion: .checklistEdit(
            clientMsgId: "mac-1",
            profileId: Self.main,
            listId: Groceries.id,
            op: .check(rowId: Groceries.lemons)
        )))
        #expect(lists.store(Groceries.id).shown?.openCount == 2)

        socket.deliver(E.accepted("mac-1", duplicate: false))
        #expect(lists.store(Groceries.id).state.pending.first?.accepted == true)

        socket.deliver(.checklist(profileId: Self.main, list: Groceries.list(rev: 8)))
        #expect(lists.store(Groceries.id).state.pending.isEmpty)
        #expect(session.model.lastError == nil)
    }

    @Test("a refused edit puts the row back with the engine's sentence and pulls the list again, and the chat says nothing")
    func refusedEdit() throws {
        connected()
        index(Groceries.id)
        lists.draw(Groceries.id)
        socket.deliver(.checklist(profileId: Self.main, list: Groceries.list()))
        lists.edit(Groceries.id, .check(rowId: Groceries.basil))

        socket.deliver(Self.refusal("That row is not in this list any more; pull the list again.", clientMsgId: "mac-1"))

        #expect(lists.store(Groceries.id).refusal == "That row is not in this list any more; pull the list again.")
        #expect(lists.store(Groceries.id).shown == Groceries.list())
        #expect(try listLines().last == wireObject(companion: .checklistPull(profileId: Self.main, listId: Groceries.id)))
        #expect(session.model.lastError == nil)
    }

    /// A refusal that names no request is never the lists': read_state and
    /// cancel on a device-role engine, a failed history read or search, and
    /// a cancel of a task that is not running all send one, and each is the
    /// chat's, whatever list pull is out.
    @Test("a refusal that names no request is the chat's even while a list pull is out")
    func idlessRefusalIsTheChats() {
        connected()
        index(Groceries.id)
        lists.draw(Groceries.id)

        socket.deliver(Self.refusal("history is unreadable"))

        #expect(session.model.lastError != nil)
        #expect(!lists.store(Groceries.id).isRemoved)
        #expect(lists.index.refusal == nil)
    }

    /// The index holds every live list, so a list it does not name is drawn
    /// as removed and never pulled: a pull of one swept away would be
    /// refused with no request named. A list the index names later, one the
    /// model made in the turn the card is drawn for, is pulled then.
    @Test("a list the loaded index does not name is never pulled, and is pulled once the index names it")
    func listMissingFromTheIndex() throws {
        connected()
        index()

        lists.draw(Groceries.id)
        #expect(try pulls().isEmpty)
        #expect(lists.index.lacks(Groceries.id), "drawn as removed")

        index(Groceries.id)
        #expect(try pulls() == [Groceries.id])
        #expect(!lists.index.lacks(Groceries.id))
    }

    @Test("an edit the engine never answered is sent again at the next handshake, and the held list is pulled once the index answers")
    func unansweredEditsAreResent() throws {
        connected()
        index(Groceries.id)
        lists.draw(Groceries.id)
        socket.deliver(.checklist(profileId: Self.main, list: Groceries.list()))
        lists.edit(Groceries.id, .check(rowId: Groceries.lemons))
        lists.edit(Groceries.id, .rename(text: "Weekly"))
        socket.deliver(E.accepted("mac-1", duplicate: false))

        socket.fail(.peerClosed)
        scheduler.fireAll()
        socket.deliver(E.hello())
        index(Groceries.id)

        let lastThree = try Array(socket.sentObjects().suffix(3))
        #expect(lastThree == (try wire(
            .checklistEdit(clientMsgId: "mac-2", profileId: Self.main, listId: Groceries.id, op: .rename(text: "Weekly")),
            .checklistsPull(profileId: Self.main),
            .checklistPull(profileId: Self.main, listId: Groceries.id)
        )))
        #expect(lists.store(Groceries.id).shown?.title == "Weekly")
    }

    /// An add the engine applied whose accepted was lost is sent again
    /// before anything is pulled, so its duplicate accepted arrives before
    /// the list it is in, which then confirms it: never drawn twice.
    @Test("a handshake sends the edits it never had answered before it pulls, so an add already applied is drawn once")
    func resendBeforePulling() throws {
        connected()
        index(Groceries.id)
        lists.draw(Groceries.id)
        socket.deliver(.checklist(profileId: Self.main, list: Groceries.list()))
        lists.edit(Groceries.id, .add(text: "Milk", note: nil, place: nil))

        socket.fail(.peerClosed)
        scheduler.fireAll()
        let before = try socket.sentObjects().count
        socket.deliver(E.hello())

        let add = CompanionClientEvent.checklistEdit(
            clientMsgId: "mac-1",
            profileId: Self.main,
            listId: Groceries.id,
            op: .add(text: "Milk", note: nil, place: nil)
        )
        #expect(try Array(socket.sentObjects().dropFirst(before + 1)) == wire(add, .checklistsPull(profileId: Self.main)), "after the catch-up read")

        socket.deliver(E.accepted("mac-1", duplicate: true))
        index(Groceries.id)
        var rows = Groceries.list().rows
        rows.insert(CompanionChecklistRow(rowId: "ci_9x9x9x9x9x", kind: .item, text: "Milk", done: false), at: 1)
        socket.deliver(.checklist(profileId: Self.main, list: Groceries.list(rev: 8, rows: rows)))

        #expect(lists.store(Groceries.id).shown?.rows.filter { $0.text == "Milk" }.count == 1)
    }

    @Test("a create says what it made once the engine pushes the new list, which is held from then on")
    func createIsNamedByMade() throws {
        connected()

        let clientMsgId = lists.create(title: "Packing", folder: "Trips")
        socket.deliver(E.accepted("mac-1", duplicate: false))
        let packing = CompanionChecklistList(listId: "ck_2b7n5r8c3j", title: "Packing", rev: 1, rows: [])
        socket.deliver(.checklist(profileId: Self.main, list: packing, made: ["mac-1": "ck_2b7n5r8c3j"]))

        #expect(clientMsgId == "mac-1")
        #expect(lists.index.created == ChecklistCreated(clientMsgId: "mac-1", listId: "ck_2b7n5r8c3j"))
        #expect(lists.store("ck_2b7n5r8c3j").shown == packing)

        lists.draw("ck_2b7n5r8c3j")
        #expect(try listLines().count == 2, "the engine holds a list its create made, so drawing it pulls nothing")
    }

    private func reconnected() {
        socket.fail(.peerClosed)
        scheduler.fireAll()
        socket.deliver(E.hello())
    }

    private func packingIndex(_ title: String = "Packing") {
        socket.deliver(.checklists(profileId: Self.main, lists: [
            CompanionChecklistEntry(listId: "ck_2b7n5r8c3j", title: title, folder: "Trips", open: 0, done: 0, rev: 1)
        ]))
    }

    /// The connection drops inside the window after the create was
    /// accepted, so the push that names what it made never comes. The index
    /// of the next connection holds the new list's title, which no other
    /// live list may hold, and that is the list it made.
    @Test("a create accepted just before the connection dropped is found in the next index by its title, pulled and shown")
    func createFoundByTitleAfterADrop() throws {
        connected()
        index()
        lists.create(title: "Packing", folder: "Trips")
        socket.deliver(E.accepted("mac-1", duplicate: false))

        reconnected()
        packingIndex()

        #expect(lists.index.created == ChecklistCreated(clientMsgId: "mac-1", listId: "ck_2b7n5r8c3j"))
        #expect(try pulls() == ["ck_2b7n5r8c3j"])
        #expect(lists.creating.isEmpty)
    }

    /// The accepted is lost with the connection; the create sent again is a
    /// duplicate, which the engine sends to no one, so only the index can
    /// say what it made, whatever the case of its title.
    @Test("a create whose accepted was lost comes back duplicate, and the index names what it made, its title compared case-blind")
    func duplicateCreateFoundByTitle() throws {
        connected()
        index()
        lists.create(title: "packing", folder: "Trips")

        reconnected()
        socket.deliver(E.accepted("mac-1", duplicate: true))
        packingIndex()

        #expect(lists.index.created == ChecklistCreated(clientMsgId: "mac-1", listId: "ck_2b7n5r8c3j"))
        #expect(try pulls() == ["ck_2b7n5r8c3j"])
        #expect(lists.creating.isEmpty)
    }

    @Test("a create the next connection's index cannot name is let go, and a later index does not turn the panel to it")
    func createNeverOutlivesAReconnect() throws {
        connected()
        index()
        lists.create(title: "Packing", folder: "Trips")
        socket.deliver(E.accepted("mac-1", duplicate: false))

        reconnected()
        index()
        #expect(lists.creating.isEmpty)

        packingIndex()
        #expect(lists.index.created == nil)
    }

    /// The engine holds the list a create makes from the moment it applies
    /// it, so with sixteen held it lets the oldest go then, before the push
    /// that names the new list.
    @Test("a create the engine applied counts among the sixteen held before its push names it")
    func createIsHeldFromItsAccepted() throws {
        connected()
        let ids = (1...16).map { String(format: "ck_%010d", $0) }
        socket.deliver(.checklists(profileId: Self.main, lists: ids.map {
            CompanionChecklistEntry(listId: $0, title: $0, folder: nil, open: 0, done: 0, rev: 1)
        }))
        ids.forEach { lists.draw($0) }

        lists.create(title: "Packing", folder: nil)
        socket.deliver(E.accepted("mac-1", duplicate: false))
        lists.draw(ids[0])
        let packing = CompanionChecklistList(listId: "ck_2b7n5r8c3j", title: "Packing", rev: 1, rows: [])
        socket.deliver(.checklist(profileId: Self.main, list: packing, made: ["mac-1": "ck_2b7n5r8c3j"]))
        lists.draw("ck_2b7n5r8c3j")

        #expect(try pulls() == ids + [ids[0]], "the first was let go when the engine held the new list")
    }

    /// A row added here has no id the engine knows until a push names it,
    /// so no op that names it, as its row or as its place, is ever sent.
    @Test("an op that names a row the engine has not named yet is neither drawn nor sent")
    func opsNamingASendingRowAreRefused() throws {
        connected()
        index(Groceries.id)
        lists.draw(Groceries.id)
        socket.deliver(.checklist(profileId: Self.main, list: Groceries.list()))
        lists.edit(Groceries.id, .add(text: "Milk", note: nil, place: nil))
        let local = try #require(lists.store(Groceries.id).shown?.rows.first { ChecklistState.isSending($0.rowId) }?.rowId)
        let sent = try socket.sentObjects().count

        for op: CompanionChecklistOp in [
            .check(rowId: local),
            .uncheck(rowId: local),
            .edit(rowId: local, text: "Oat milk", note: nil),
            .remove(rowId: local),
            .move(rowId: local, place: .after(Groceries.bread), toListId: nil),
            .move(rowId: Groceries.rice, place: .after(local), toListId: nil),
            .add(text: "Eggs", note: nil, place: .after(local)),
            .add(text: "Eggs", note: nil, place: .section(local)),
            .section(text: "Dairy", afterId: local)
        ] {
            lists.edit(Groceries.id, op)
        }

        #expect(try socket.sentObjects().count == sent)
        #expect(lists.store(Groceries.id).state.pending.count == 1, "only the add itself")
    }

    @Test("a blank text is no edit and no new list")
    func blankTextIsNoEdit() throws {
        connected()
        index(Groceries.id)
        lists.draw(Groceries.id)

        lists.edit(Groceries.id, .add(text: "  ", note: nil, place: nil))
        #expect(lists.create(title: " ", folder: nil) == nil)

        #expect(try listLines().count == 2)
    }
}
