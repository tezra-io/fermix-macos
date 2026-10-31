import Foundation
import Testing

@testable import FermixAppCore

/// The Lists panel's own rules (M85 §09): whether it is open is remembered,
/// its width stays in its range, it shows the list asked for or the first,
/// its lines fold, and a move lands where the engine's ops can say.
@Suite("Checklist panel")
@MainActor
struct ChecklistPanelTests {
    private static func entry(_ id: String, _ title: String, folder: String? = nil, open: Int = 1) -> CompanionChecklistEntry {
        CompanionChecklistEntry(listId: id, title: title, folder: folder, open: open, done: 0, rev: 1)
    }

    private static func row(_ id: String, _ kind: CompanionChecklistRowKind = .item, done: Bool = false) -> CompanionChecklistRow {
        CompanionChecklistRow(rowId: id, kind: kind, text: id, done: kind == .item ? done : nil)
    }

    private static func panel(open: Bool? = nil, sent: @escaping (CompanionClientEvent) -> Bool = { _ in false }) -> (ChecklistPanelModel, FixtureChecklistPanelStore) {
        let store = FixtureChecklistPanelStore(open: false)
        store.panelOpen = open
        var issued = 0
        let library = ChecklistLibrary(send: sent, messageIds: {
            issued += 1
            return "mac-\(issued)"
        })
        return (ChecklistPanelModel(library: library, store: store), store)
    }

    @Test("whether the panel is open is remembered, and it starts closed for an owner who never opened it")
    func openIsRemembered() {
        let (fresh, _) = Self.panel()
        #expect(!fresh.isOpen)

        let (panel, store) = Self.panel(open: true)
        #expect(panel.isOpen)

        panel.hide()
        #expect(store.panelOpen == false)
        panel.show("ck_9t3k6w0p5h")
        #expect(store.panelOpen == true)
        #expect(panel.asked == "ck_9t3k6w0p5h")
        panel.toggle()
        #expect(!panel.isOpen)
    }

    @Test("the panel is 330 points wide and drags between 280 and 420")
    func widthStaysInItsRange() {
        let (panel, _) = Self.panel()
        #expect(panel.width == 330)

        panel.resize(to: 200)
        #expect(panel.width == 280)
        panel.resize(to: 900)
        #expect(panel.width == 420)
        panel.resize(to: 360)
        #expect(panel.width == 360)
    }

    @Test("the panel shows the list asked for while the index holds it, and the first list otherwise")
    func shownList() {
        let (panel, _) = Self.panel()
        let index = panel.library.index
        #expect(panel.shown(in: index) == nil, "nothing before the index arrives")

        index.show([Self.entry("ck_a", "Fermix", folder: "Projects"), Self.entry("ck_b", "Groceries")])
        #expect(panel.shown(in: index)?.listId == "ck_a")

        panel.select("ck_b")
        #expect(panel.shown(in: index)?.listId == "ck_b")

        index.show([Self.entry("ck_a", "Fermix", folder: "Projects")])
        #expect(panel.shown(in: index)?.listId == "ck_a", "a list the index no longer holds gives way to the first")
    }

    @Test("the picker names each folder over its lists in picker order, then the lists in no folder")
    func pickerOrder() {
        let folders = ChecklistFolders([
            Self.entry("ck_a", "Fermix", folder: "Projects"),
            Self.entry("ck_b", "Groceries"),
            Self.entry("ck_c", "Packing", folder: "Trips"),
            Self.entry("ck_d", "Portfolio site", folder: "Projects")
        ])

        #expect(folders.names == ["Projects", "Trips"])
        #expect(folders.folders.map { $0.lists.map(\.title) } == [["Fermix", "Portfolio site"], ["Packing"]])
        #expect(folders.loose.map(\.title) == ["Groceries"])
    }

    @Test("a list removed from the panel is offered back, and Undo restores it and shows it")
    func removedListComesBack() throws {
        var sent: [CompanionClientEvent] = []
        let (panel, _) = Self.panel { sent.append($0); return true }
        let fermix = Self.entry("ck_9t3k6w0p5h", "Fermix")
        panel.library.negotiated(serves: true)

        panel.remove(fermix)
        #expect(panel.removedList == fermix)

        panel.restore(fermix)
        #expect(panel.removedList == nil)
        #expect(panel.asked == fermix.listId)
        #expect(sent.suffix(2) == [
            .checklistEdit(clientMsgId: "mac-1", profileId: "main", listId: fermix.listId, op: .removeList),
            .checklistEdit(clientMsgId: "mac-2", profileId: "main", listId: fermix.listId, op: .restore(rowId: nil, title: nil))
        ])
    }

    @Test("the lines are each section under its heading, a folded one without its items, then the Done fold, closed until opened")
    func lines() {
        let list = CompanionChecklistList(listId: "ck_a", title: "Fermix", rev: 1, rows: [
            Self.row("loose"),
            Self.row("active", .section),
            Self.row("a"),
            Self.row("b", done: true),
            Self.row("later", .section),
            Self.row("c")
        ])

        let closed = ChecklistLine.lines(of: list, folded: [], doneOpen: false, settling: [], removedShown: false)
        #expect(closed.map(\.id) == ["loose", "heading:active", "a", "heading:later", "c", "done"])

        let folded = ChecklistLine.lines(of: list, folded: ["later"], doneOpen: true, settling: [], removedShown: false)
        #expect(folded.map(\.id) == ["loose", "heading:active", "a", "heading:later", "done", "b"])

        let settling = ChecklistLine.lines(of: list, folded: [], doneOpen: false, settling: ["b"], removedShown: false)
        #expect(settling.map(\.id) == ["loose", "heading:active", "a", "b", "heading:later", "c"], "a row ticked a moment ago keeps its place")
    }

    @Test("a move lands after the line above it, a heading putting it first in its section, and the top of a headless first group is no move")
    func moves() {
        let list = CompanionChecklistList(listId: "ck_a", title: "Fermix", rev: 1, rows: [
            Self.row("loose"),
            Self.row("active", .section),
            Self.row("a"),
            Self.row("b"),
            Self.row("later", .section),
            Self.row("c"),
            Self.row("gone", done: true)
        ])
        let lines = ChecklistLine.lines(of: list, folded: [], doneOpen: true, settling: [], removedShown: false)

        #expect(ChecklistMoves.place(before: 3, in: lines, moving: "c") == .after("a"))
        #expect(ChecklistMoves.place(before: 2, in: lines, moving: "b") == .after("active"))
        #expect(ChecklistMoves.place(before: 0, in: lines, moving: "a") == nil)
        #expect(ChecklistMoves.place(before: lines.count, in: lines, moving: "a") == .after("c"), "below the open lines, after the last of them")

        #expect(ChecklistMoves.step("b", up: true, in: lines) == .after("active"))
        #expect(ChecklistMoves.step("c", up: true, in: lines) == .after("b"), "up past a heading ends the section above")
        #expect(ChecklistMoves.step("a", up: false, in: lines) == .after("b"))
        #expect(ChecklistMoves.step("b", up: false, in: lines) == .after("later"), "down past a heading starts the section below")
        #expect(ChecklistMoves.step("c", up: false, in: lines) == nil)
        #expect(ChecklistMoves.step("loose", up: true, in: lines) == nil)
    }

    @Test("a card's counts and names read as the copy deck says, to the eye and to VoiceOver")
    func words() {
        #expect(ChecklistWordsFor.counts(open: 6, done: 2) == "6 open · 2 done")
        #expect(ChecklistWordsFor.listLabel("Fermix", open: 6) == "Fermix, list, 6 open")
        #expect(ChecklistWordsFor.listsLabel(["Fermix", "Portfolio site", "Groceries"]).hasSuffix(", lists"))
        #expect(ChecklistWordsFor.listsLabel(["Fermix", "Portfolio site", "Groceries"]).hasPrefix("Fermix, Portfolio site"))
    }
}
