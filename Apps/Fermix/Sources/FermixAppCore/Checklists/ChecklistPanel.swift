import AppKit
import SwiftUI

/// The Lists panel, right of the chat (M85 §09): one whole list, its
/// sections folding and its done items folded at the foot, with the picker
/// over it and the add field pinned under it. It draws the list from the
/// same store a reply's card does.
struct ChecklistPanel: View {
    @ObservedObject var panel: ChecklistPanelModel
    @ObservedObject var index: ChecklistIndexStore

    var body: some View {
        Group {
            if let entry = panel.shown(in: index) {
                ChecklistPanelList(panel: panel, index: index, entry: entry, store: panel.library.store(entry.listId))
                    .id(entry.listId)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ChecklistPanelHeader(panel: panel, index: index, entry: nil, list: nil)
                    Text(index.refusal ?? (index.entries == nil ? "" : ProductStrings[.listsNone]))
                        .fermixType(Typography.style(.calloutSmall))
                        .foregroundStyle(Palette.secondary.color)
                        .padding(.horizontal, Spacing.m)
                        .padding(.top, Spacing.xs)
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(width: panel.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .bottom) {
            if let removed = panel.removedList {
                ChecklistUndoLine(text: removed.title) { panel.restore(removed) }
                    .padding(.horizontal, Spacing.s)
                    .padding(.vertical, Spacing.xxs)
                    .background(
                        RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                            .fill(Palette.floatingFill.color)
                    )
                    .padding(.horizontal, Spacing.s)
                    .padding(.bottom, HitTarget.button + Spacing.m * 2)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(ProductStrings[.listsTitle])
    }
}

/// "Removed %@." with Undo beside it: what a removal says for a moment.
private struct ChecklistUndoLine: View {
    let text: String
    let undo: () -> Void

    var body: some View {
        HStack(spacing: Spacing.xs) {
            Text(String(format: ProductStrings[.listsRemovedFormat], text))
                .fermixType(Typography.style(.calloutSmall))
                .foregroundStyle(Palette.secondary.color)
                .lineLimit(1)
            Spacer(minLength: 0)
            Button(ProductStrings[.listsUndo], action: undo)
                .buttonStyle(SecondaryButtonStyle(.row))
        }
    }
}

/// What the header's one field is naming, while it names something: a new
/// list, this list's new title, or a new folder for it.
enum ChecklistNaming: Equatable {
    case newList
    case rename
    case newFolder
}

/// The panel's header (M85 §09): the picker, which is the list's own title,
/// with each folder a heading over its lists and their open counts, then the
/// lists in no folder, then New list; under it the folder and the counts; a
/// ⋯ menu; and the hide button. A name is typed into the title's own place.
private struct ChecklistPanelHeader: View {
    @ObservedObject var panel: ChecklistPanelModel
    @ObservedObject var index: ChecklistIndexStore
    let entry: CompanionChecklistEntry?
    let list: CompanionChecklistList?
    var removedShown: Binding<Bool>?
    var copy: () -> Void = {}

    @State private var naming: ChecklistNaming?
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            HStack(spacing: Spacing.xxs) {
                if let naming {
                    ChecklistNameField(naming: naming, title: list?.title ?? "", commit: name, cancel: { self.naming = nil })
                } else {
                    picker
                }
                Spacer(minLength: 0)
                if let entry, list?.removedAt == nil {
                    more(entry)
                }
                ChecklistIconButton(symbol: "sidebar.right", label: ProductStrings[.listsHidePanel]) { panel.hide() }
            }

            if let entry, let list {
                Text(subline(entry, list))
                    .fermixType(Typography.style(.calloutSmall))
                    .foregroundStyle(Palette.secondary.color)
                    .lineLimit(1)
            }
            if let refusal = index.refusal, entry != nil {
                Text(refusal)
                    .fermixType(Typography.style(.calloutSmall))
                    .foregroundStyle(Palette.secondary.color)
            }
        }
        .padding(.leading, Spacing.m)
        .padding(.trailing, Spacing.s)
        .padding(.top, Spacing.s)
        .padding(.bottom, Spacing.xs)
    }

    private var picker: some View {
        let folders = index.folders

        return Menu {
            ForEach(folders.folders) { folder in
                Section(folder.name) {
                    ForEach(folder.lists) { pick($0) }
                }
            }
            Section {
                ForEach(folders.loose) { pick($0) }
            }
            Section {
                Button(ProductStrings[.listsNewList]) { naming = .newList }
            }
        } label: {
            HStack(spacing: Spacing.xxs) {
                Text(list?.title ?? entry?.title ?? ProductStrings[.listsTitle])
                    .fermixType(Typography.style(.body).weight(.semibold))
                    .foregroundStyle(Palette.ink.color)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: Typography.style(.caption).size, weight: .semibold))
                    .foregroundStyle(Palette.secondary.color)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(list?.title ?? ProductStrings[.listsTitle])
    }

    /// A list in the picker, checked where it is the one shown, with its
    /// open count.
    private func pick(_ choice: CompanionChecklistEntry) -> some View {
        Toggle(isOn: Binding(get: { choice.listId == entry?.listId }, set: { _ in panel.select(choice.listId) })) {
            Text(choice.title)
        }
        .badge(choice.open)
    }

    private func more(_ entry: CompanionChecklistEntry) -> some View {
        Menu {
            Button(ProductStrings[.listsRenameList]) { naming = .rename }
            Menu(ProductStrings[.listsMoveToFolder]) {
                ForEach(index.folders.names, id: \.self) { folder in
                    Toggle(folder, isOn: Binding(get: { entry.folder == folder }, set: { _ in edit(.folder(folder)) }))
                }
                Section {
                    Toggle(ProductStrings[.listsNoFolder], isOn: Binding(get: { entry.folder == nil }, set: { _ in edit(.folder("")) }))
                    Button(ProductStrings[.listsNewFolder]) { naming = .newFolder }
                }
            }
            Button(ProductStrings[.listsCopyAsText], action: copy)
            Button(ProductStrings[.listsClearDone]) { edit(.clearDone) }
                .disabled((list?.doneCount ?? 0) == 0)
            if let removedShown {
                Toggle(ProductStrings[.listsRecentlyRemoved], isOn: removedShown)
            }
            Section {
                Button(ProductStrings[.listsRemoveList]) { removeList(entry) }
            }
        } label: {
            Image(systemName: "ellipsis")
                .foregroundStyle(Palette.secondary.color)
                .frame(width: ChecklistMetrics.target, height: ChecklistMetrics.target)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(ProductStrings[.toolbarMore])
        .accessibilityLabel(ProductStrings[.toolbarMore])
    }

    /// "Projects · 6 open · 2 done", or the counts alone in no folder.
    private func subline(_ entry: CompanionChecklistEntry, _ list: CompanionChecklistList) -> String {
        let counts = ChecklistWordsFor.counts(open: list.openCount, done: list.doneCount)
        guard let folder = entry.folder else { return counts }

        return ProductStrings.middot(folder, counts)
    }

    private func edit(_ op: CompanionChecklistOp) {
        guard let entry else { return }

        panel.library.edit(entry.listId, op)
    }

    /// The list goes, and Undo or ⌘Z brings it back.
    private func removeList(_ entry: CompanionChecklistEntry) {
        panel.remove(entry)
        undoManager?.registerUndo(withTarget: panel) { panel in panel.restore(entry) }
    }

    private func name(_ text: String) {
        let naming = self.naming
        self.naming = nil

        switch naming {
        case .newList: panel.library.create(title: text, folder: nil)
        case .rename: edit(.rename(text: text))
        case .newFolder: edit(.folder(text))
        case nil: break
        }
    }
}

/// The header's field for a name: Return keeps it, Escape leaves it.
private struct ChecklistNameField: View {
    let naming: ChecklistNaming
    let title: String
    let commit: (String) -> Void
    let cancel: () -> Void

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(prompt, text: $text)
            .textFieldStyle(.plain)
            .fermixType(Typography.style(.body).weight(.semibold))
            .focused($focused)
            .onSubmit {
                let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !words.isEmpty else { return cancel() }

                commit(words)
            }
            .onExitCommand { cancel() }
            .onAppear {
                text = naming == .rename ? title : ""
                focused = true
            }
            .frame(minHeight: ChecklistMetrics.target)
    }

    private var prompt: String {
        ProductStrings[naming == .newFolder ? .listsFolderNamePrompt : .listsListNamePrompt]
    }
}

/// One line of the panel's list, in the order drawn: a section's heading,
/// an open item, the Done fold and the done items under it, and Recently
/// removed with its rows.
enum ChecklistLine: Identifiable, Equatable {
    case heading(CompanionChecklistRow, folded: Bool)
    case item(CompanionChecklistRow)
    case doneHeading(count: Int, open: Bool)
    case done(CompanionChecklistRow)
    case removedHeading
    case removed(CompanionChecklistRow)

    var id: String {
        switch self {
        case .heading(let row, _): return "heading:" + row.rowId
        case .item(let row), .done(let row): return row.rowId
        case .doneHeading: return "done"
        case .removedHeading: return "removed"
        case .removed(let row): return "removed:" + row.rowId
        }
    }

    /// The panel's lines (M85 §09): each section under its heading with its
    /// open items, or none while it is folded; then every done item, under
    /// a Done fold that is closed until opened. A row ticked a moment ago
    /// keeps its place while it settles.
    static func lines(
        of list: CompanionChecklistList,
        folded: Set<String>,
        doneOpen: Bool,
        settling: Set<String>,
        removedShown: Bool
    ) -> [ChecklistLine] {
        var lines: [ChecklistLine] = []
        for section in ChecklistSection.sections(of: list.rows) {
            if let heading = section.heading {
                lines.append(.heading(heading, folded: folded.contains(heading.rowId)))
                if folded.contains(heading.rowId) { continue }
            }
            lines += section.items.filter { !$0.isDone || settling.contains($0.rowId) }.map(ChecklistLine.item)
        }

        let done = list.items.filter { $0.isDone && !settling.contains($0.rowId) }
        if !done.isEmpty {
            lines.append(.doneHeading(count: done.count, open: doneOpen))
            if doneOpen { lines += done.map(ChecklistLine.done) }
        }
        if removedShown, let removed = list.removed, !removed.isEmpty {
            lines.append(.removedHeading)
            lines += removed.filter { $0.kind == .item }.map(ChecklistLine.removed)
        }

        return lines
    }

    /// The item a line draws, where it draws one that can be edited.
    var editable: CompanionChecklistRow? {
        switch self {
        case .item(let row), .done(let row): return row
        case .heading, .doneHeading, .removedHeading, .removed: return nil
        }
    }
}

/// Where a row lands, by the engine's ops, for a place in the panel's lines.
enum ChecklistMoves {
    /// The place right before line `destination`: after the line above it,
    /// a heading putting the row first in its section. Nil where no op can
    /// say it, the very top of a list whose first group has no heading, and
    /// in the done or removed lines below the open ones.
    static func place(before destination: Int, in lines: [ChecklistLine], moving rowId: String) -> CompanionChecklistPlace? {
        let above = lines[..<min(destination, lines.count)].reversed().first { line in
            line.id != rowId
        }

        switch above {
        case .heading(let row, _)?, .item(let row)?:
            return .after(row.rowId)
        case .doneHeading?, .done?, .removedHeading?, .removed?:
            let lastOpen = lines.last { line in
                if case .item(let row) = line { return row.rowId != rowId }
                if case .heading = line { return true }
                return false
            }
            switch lastOpen {
            case .item(let row)?, .heading(let row, _)?: return .after(row.rowId)
            default: return nil
            }
        case nil:
            return nil
        }
    }

    /// One step up or down among the open lines: past the line above or
    /// below, a heading included, so a row crosses into the next section.
    static func step(_ rowId: String, up: Bool, in lines: [ChecklistLine]) -> CompanionChecklistPlace? {
        guard let at = lines.firstIndex(where: { $0.id == rowId }) else { return nil }

        if up {
            guard at > 0 else { return nil }
            return place(before: at - 1, in: lines, moving: rowId)
        }
        guard at + 1 < lines.count else { return nil }

        switch lines[at + 1] {
        case .heading(let row, _), .item(let row): return .after(row.rowId)
        case .doneHeading, .done, .removedHeading, .removed: return nil
        }
    }
}

/// The panel with a list: its header, its lines and the add field.
private struct ChecklistPanelList: View {
    let panel: ChecklistPanelModel
    @ObservedObject var index: ChecklistIndexStore
    let entry: CompanionChecklistEntry
    @ObservedObject var store: ChecklistStore

    @State private var selection: String?
    @State private var folded: Set<String> = []
    @State private var doneOpen = false
    @State private var removedShown = false
    @State private var settling: Set<String> = []
    @State private var rewording: String?
    @State private var removedLine: ChecklistRemoval?
    @Environment(\.undoManager) private var undoManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let list = store.shown

        VStack(alignment: .leading, spacing: 0) {
            ChecklistPanelHeader(
                panel: panel,
                index: index,
                entry: entry,
                list: list,
                removedShown: $removedShown,
                copy: { if let list { Clipboard.write(list.markdown) } }
            )

            if store.isRemoved {
                removedList
            } else if let list {
                lines(list)
                foot(list)
            } else {
                Spacer(minLength: 0)
            }
        }
        .onAppear { panel.library.draw(entry.listId) }
        .onChange(of: removedShown) {
            guard removedShown else { return }

            panel.library.draw(entry.listId, removed: true)
        }
        .background(alignment: .topLeading) { shortcuts }
    }

    // MARK: - The lines

    private func lines(_ list: CompanionChecklistList) -> some View {
        let lines = ChecklistLine.lines(of: list, folded: folded, doneOpen: doneOpen, settling: settling, removedShown: removedShown)

        return List(selection: $selection) {
            ForEach(lines) { line in
                row(line)
                    .listRowSeparator(.hidden)
                    .moveDisabled(!Self.movable(line))
            }
            .onMove { from, to in
                guard let moved = from.first.map({ lines[$0] }), let row = moved.editable else { return }
                guard let place = ChecklistMoves.place(before: to, in: lines, moving: row.rowId) else { return }

                edit(.move(rowId: row.rowId, place: place, toListId: nil))
            }
        }
        .listStyle(.plain)
        .showsAmbientGround()
        .scrollIndicators(.never)
        .contextMenu(forSelectionType: String.self) { ids in
            if let row = editableRow(ids.first, in: lines), !ChecklistState.isSending(row.rowId) {
                rowMenu(row, lines: lines)
            }
        } primaryAction: { ids in
            if let row = editableRow(ids.first, in: lines), !ChecklistState.isSending(row.rowId) {
                rewording = row.rowId
            }
        }
        .onDeleteCommand { if let row = editableRow(selection, in: lines) { remove(row) } }
        .onKeyPress(.space) {
            guard rewording == nil, let row = editableRow(selection, in: lines) else { return .ignored }

            tick(row, !row.isDone)
            return .handled
        }
        .onKeyPress(.return) {
            guard rewording == nil, let row = editableRow(selection, in: lines), !ChecklistState.isSending(row.rowId) else {
                return .ignored
            }

            rewording = row.rowId
            return .handled
        }
    }

    @ViewBuilder
    private func row(_ line: ChecklistLine) -> some View {
        switch line {
        case .heading(let heading, let isFolded):
            ChecklistFoldHeading(title: heading.text, open: !isFolded) {
                if isFolded { folded.remove(heading.rowId) } else { folded.insert(heading.rowId) }
            }
        case .item(let row), .done(let row):
            ChecklistPanelItem(
                row: row,
                rewording: rewording == row.rowId,
                tick: { tick(row, $0) },
                save: { text, note in
                    rewording = nil
                    if text != row.text || note != nil { edit(.edit(rowId: row.rowId, text: text == row.text ? nil : text, note: note)) }
                },
                cancel: { rewording = nil },
                remove: { remove(row) },
                step: { up in step(row, up: up) }
            )
            .tag(row.rowId)
        case .doneHeading(let count, let open):
            ChecklistFoldHeading(title: ProductStrings.middot(ProductStrings[.listsDone], String(count)), open: open) {
                doneOpen.toggle()
            }
        case .removedHeading:
            ChecklistFoldHeading(title: ProductStrings[.listsRecentlyRemoved], open: true) { removedShown = false }
        case .removed(let row):
            HStack(spacing: Spacing.xs) {
                ChecklistWords(text: row.text, done: false, type: Typography.style(.callout).weight(.regular))
                    .foregroundStyle(Palette.secondary.color)
                Button(ProductStrings[.listsRestore]) { edit(.restore(rowId: row.rowId, title: nil)) }
                    .buttonStyle(SecondaryButtonStyle(.row))
            }
        }
    }

    @ViewBuilder
    private func rowMenu(_ row: CompanionChecklistRow, lines: [ChecklistLine]) -> some View {
        let others = (index.entries ?? []).filter { $0.listId != entry.listId }
        let folders = ChecklistFolders(others)

        Menu(ProductStrings[.listsMoveToList]) {
            ForEach(folders.folders) { folder in
                Section(folder.name) {
                    ForEach(folder.lists) { target in
                        Button(target.title) { edit(.move(rowId: row.rowId, place: nil, toListId: target.listId)) }
                    }
                }
            }
            Section {
                ForEach(folders.loose) { target in
                    Button(target.title) { edit(.move(rowId: row.rowId, place: nil, toListId: target.listId)) }
                }
            }
        }
        .disabled(others.isEmpty)
        Button(ProductStrings[.listsMoveUp]) { step(row, up: true) }
        Button(ProductStrings[.listsMoveDown]) { step(row, up: false) }
        Section {
            Button(ProductStrings[.listsRemove]) { remove(row) }
        }
    }

    // MARK: - The foot

    private func foot(_ list: CompanionChecklistList) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            if let refusal = store.refusal {
                Text(refusal)
                    .fermixType(Typography.style(.calloutSmall))
                    .foregroundStyle(Palette.secondary.color)
            }
            if let removedLine {
                ChecklistUndoLine(text: removedLine.text) { undo(removedLine) }
            }
            ChecklistAddField { add($0, in: list) }
                .padding(.horizontal, Spacing.s - Spacing.xxs)
                .frame(minHeight: HitTarget.rowAction + Spacing.xs)
                .background(
                    RoundedRectangle(cornerRadius: Radius.controlCompact, style: .continuous)
                        .fill(Palette.chipFill.color)
                )
        }
        .padding(.horizontal, Spacing.s)
        .padding(.top, Spacing.s)
        .padding(.bottom, Spacing.m)
        .overlay(alignment: .top) { ChecklistHairline() }
    }

    /// The list, removed: it says so, and Undo brings it back.
    private var removedList: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(ProductStrings[.listsListRemoved])
                .fermixType(Typography.style(.calloutSmall))
                .foregroundStyle(Palette.secondary.color)
            if store.shown?.removedAt != nil {
                Button(ProductStrings[.listsUndo]) { edit(.restore(rowId: nil, title: nil)) }
                    .buttonStyle(SecondaryButtonStyle(.row))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.m)
        .padding(.top, Spacing.xs)
    }

    /// ⌥⌘↑ and ⌥⌘↓ move the selected item, and ⌘Z takes back a removal
    /// through the window's own Undo.
    private var shortcuts: some View {
        ZStack {
            Button(ProductStrings[.listsMoveUp]) { stepSelected(up: true) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            Button(ProductStrings[.listsMoveDown]) { stepSelected(up: false) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
        }
        .buttonStyle(.plain)
        .frame(width: 0, height: 0)
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: - Edits

    /// An open item the engine has named moves; a heading, a done item and a
    /// row still being sent do not.
    private static func movable(_ line: ChecklistLine) -> Bool {
        guard case .item(let row) = line else { return false }

        return !ChecklistState.isSending(row.rowId)
    }

    private func edit(_ op: CompanionChecklistOp) {
        panel.library.edit(entry.listId, op)
    }

    private func editableRow(_ id: String?, in lines: [ChecklistLine]) -> CompanionChecklistRow? {
        guard let id else { return nil }

        return lines.first { $0.id == id }?.editable
    }

    /// The selected row's section takes the new item; with none selected,
    /// or one in the first group, the first group does.
    private func add(_ text: String, in list: CompanionChecklistList) {
        let section = selection.flatMap { id in
            ChecklistSection.sections(of: list.rows).first { $0.items.contains { $0.rowId == id } }?.heading
        }
        edit(.add(text: text, note: nil, place: section.map { .section($0.rowId) }))
    }

    private func tick(_ row: CompanionChecklistRow, _ done: Bool) {
        guard !ChecklistState.isSending(row.rowId) else { return }

        if done, !reduceMotion {
            settling.insert(row.rowId)
            Task { @MainActor in
                try? await Task.sleep(for: ChecklistMetrics.settle)
                withAnimation(Motion(reduceMotion: reduceMotion).animation(.checklistStrike)) {
                    _ = settling.remove(row.rowId)
                }
            }
        }
        edit(done ? .check(rowId: row.rowId) : .uncheck(rowId: row.rowId))
    }

    private func step(_ row: CompanionChecklistRow, up: Bool) {
        guard let list = store.shown, !ChecklistState.isSending(row.rowId) else { return }

        let lines = ChecklistLine.lines(of: list, folded: folded, doneOpen: false, settling: [], removedShown: false)
        guard let place = ChecklistMoves.step(row.rowId, up: up, in: lines) else { return }

        edit(.move(rowId: row.rowId, place: place, toListId: nil))
    }

    private func stepSelected(up: Bool) {
        guard let id = selection, let row = store.shown?.items.first(where: { $0.rowId == id }), !row.isDone else { return }

        step(row, up: up)
    }

    /// A removal says what it removed, with Undo, for a moment, and ⌘Z
    /// takes it back as well; Recently removed keeps it for 30 days.
    private func remove(_ row: CompanionChecklistRow) {
        guard !ChecklistState.isSending(row.rowId) else { return }

        let removal = panel.remove(row, from: entry.listId)
        removedLine = removal
        undoManager?.registerUndo(withTarget: panel) { panel in panel.takeBack(removal) }
        Task { @MainActor in
            try? await Task.sleep(for: ChecklistMetrics.undoLine)
            if removedLine == removal { removedLine = nil }
        }
    }

    private func undo(_ removal: ChecklistRemoval) {
        removedLine = nil
        panel.takeBack(removal)
    }
}

/// A fold's heading: a section's, Done's, or Recently removed's, its chevron
/// turning as it opens.
private struct ChecklistFoldHeading: View {
    let title: String
    let open: Bool
    let toggle: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: Spacing.xxs) {
                Image(systemName: "chevron.down")
                    .font(.system(size: Typography.style(.caption).size, weight: .semibold))
                    .rotationEffect(.degrees(open ? 0 : -90))
                    .animation(Motion(reduceMotion: reduceMotion).animation(.checklistStrike), value: open)
                Text(title)
                    .fermixType(Typography.style(.calloutSmall).weight(.semibold))
                Spacer(minLength: 0)
            }
            .foregroundStyle(Palette.secondary.color)
            .frame(minHeight: ChecklistMetrics.target)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

/// An item in the panel: the circle, its words and its note, or the two
/// being reworded. VoiceOver reads the circle as a checkbox named by the
/// item, and the row carries Remove, Move up and Move down.
private struct ChecklistPanelItem: View {
    let row: CompanionChecklistRow
    let rewording: Bool
    let tick: (Bool) -> Void
    let save: (String, String?) -> Void
    let cancel: () -> Void
    let remove: () -> Void
    let step: (Bool) -> Void

    var body: some View {
        let sending = ChecklistState.isSending(row.rowId)

        HStack(alignment: .top, spacing: Spacing.xxs) {
            Toggle(isOn: Binding(get: { row.isDone }, set: tick)) {
                Text(row.text)
            }
            .toggleStyle(ChecklistCircleStyle(sending: sending))
            .accessibilityLabel(row.text)

            if rewording {
                ChecklistRewording(row: row, withNote: true, save: save, cancel: cancel)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ChecklistWords(text: row.text, done: row.isDone)
                    if let note = row.note {
                        Text(note)
                            .fermixType(Typography.style(.calloutSmall))
                            .foregroundStyle(Palette.secondary.color)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityHidden(true)
            }
        }
        .opacity(sending ? ChatMetrics.sendingStrength : 1)
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: ProductStrings[.listsRemove], remove)
        .accessibilityAction(named: ProductStrings[.listsMoveUp]) { step(true) }
        .accessibilityAction(named: ProductStrings[.listsMoveDown]) { step(false) }
    }
}

/// The divider between the chat and the panel: a hairline, and a grip
/// wider than it that drags the panel between 280 and 420 points.
struct ChecklistPanelEdge: View {
    let panel: ChecklistPanelModel

    @State private var start: Double?
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Rectangle()
            .fill(Palette.hairline(.faint, increaseContrast: contrast == .increased).color)
            .frame(width: Stroke.hairline)
            .frame(maxHeight: .infinity)
            .overlay {
                Color.clear
                    .frame(width: ChecklistMetrics.grip)
                    .contentShape(Rectangle())
                    .pointerStyle(.frameResize(position: .leading))
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { drag in
                                let from = start ?? panel.width
                                start = from
                                panel.resize(to: from - drag.translation.width)
                            }
                            .onEnded { _ in start = nil }
                    )
            }
            .accessibilityHidden(true)
    }
}
