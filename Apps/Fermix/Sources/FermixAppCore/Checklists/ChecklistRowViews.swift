import SwiftUI

/// The circle an item is ticked with (M85 §09): an empty ring, then an ink
/// disc with the check knocked out of it, so the ground shows through the
/// check whatever it is drawn on, 17 points in the row action's
/// 24-point target. It fills in 120 ms, at once under Reduce Motion. The
/// toggle it styles is what VoiceOver reads: a checkbox named by its item.
struct ChecklistCircleStyle: ToggleStyle {
    /// A row made here that the engine has not named yet takes no tick.
    var sending = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        ZStack {
            Circle()
                .strokeBorder(Palette.faint.color, lineWidth: Stroke.heroBorder)
                .opacity(configuration.isOn ? 0 : 1)
            ZStack {
                Circle()
                    .fill(Palette.ink.color)
                Image(systemName: "checkmark")
                    .font(.system(size: ChecklistMetrics.circle * 0.5, weight: .bold))
                    .blendMode(.destinationOut)
            }
            .compositingGroup()
            .opacity(configuration.isOn ? 1 : 0)
        }
        .frame(width: ChecklistMetrics.circle, height: ChecklistMetrics.circle)
        .frame(width: ChecklistMetrics.target, height: ChecklistMetrics.target)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !sending else { return }

            configuration.isOn.toggle()
        }
        .animation(Motion(reduceMotion: reduceMotion).animation(.checklistTick), value: configuration.isOn)
    }
}

/// An item's words: struck through and faint once done, the strike drawn in
/// 180 ms, in the chat's reading face, as the reply's words are.
struct ChecklistWords: View {
    let text: String
    let done: Bool
    var type = ChatMetrics.readingType

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Text(text)
            .fermixType(type)
            .strikethrough(done, color: Palette.faint.color)
            .foregroundStyle((done ? Palette.faint : Palette.ink).color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .animation(Motion(reduceMotion: reduceMotion).animation(.checklistStrike), value: done)
    }
}

/// An item being reworded in place: its words, and in the panel its note
/// under them. Return saves, Escape puts the words back, and Tab moves from
/// the words to the note.
struct ChecklistRewording: View {
    let row: CompanionChecklistRow
    /// Whether the note is reworded here too: the panel's, never a card's.
    let withNote: Bool
    let save: (_ text: String, _ note: String?) -> Void
    let cancel: () -> Void

    @State private var text: String
    @State private var note: String
    @FocusState private var focused: Bool

    init(row: CompanionChecklistRow, withNote: Bool, save: @escaping (String, String?) -> Void, cancel: @escaping () -> Void) {
        self.row = row
        self.withNote = withNote
        self.save = save
        self.cancel = cancel
        _text = State(initialValue: row.text)
        _note = State(initialValue: row.note ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            TextField(ProductStrings[.listsAddItem], text: $text)
                .textFieldStyle(.plain)
                .fermixType(ChatMetrics.readingType)
                .foregroundStyle(Palette.ink.color)
                .focused($focused)
                .onSubmit(commit)

            if withNote {
                TextField(ProductStrings[.listsNotePrompt], text: $note, axis: .vertical)
                    .textFieldStyle(.plain)
                    .fermixType(Typography.style(.calloutSmall))
                    .foregroundStyle(Palette.secondary.color)
                    .onSubmit(commit)
            }
        }
        .onExitCommand { cancel() }
        .onAppear { focused = true }
    }

    /// Only what changed is sent, and a note emptied here is cleared.
    private func commit() {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let kept = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let changedNote = withNote && kept != (row.note ?? "") ? kept : nil

        save(words == row.text || words.isEmpty ? row.text : words, changedNote)
    }
}

/// One item as a card draws it (M85 §08): the circle and the words, without
/// its note, which the panel shows. A one-list card rewords on a
/// double-click; a card of several lists only ticks.
struct ChecklistCardItem: View {
    let row: CompanionChecklistRow
    let rewords: Bool
    let tick: (Bool) -> Void
    let reword: (String) -> Void

    @State private var rewording = false

    var body: some View {
        let sending = ChecklistState.isSending(row.rowId)

        HStack(alignment: .top, spacing: Spacing.xxs) {
            Toggle(isOn: Binding(get: { row.isDone }, set: tick)) {
                Text(row.text)
            }
            .toggleStyle(ChecklistCircleStyle(sending: sending))
            .accessibilityLabel(row.text)

            if rewording {
                ChecklistRewording(row: row, withNote: false, save: { text, _ in
                    rewording = false
                    if text != row.text { reword(text) }
                }, cancel: { rewording = false })
            } else {
                ChecklistWords(text: row.text, done: row.isDone)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        guard rewords, !sending else { return }

                        rewording = true
                    }
                    .accessibilityHidden(true)
            }
        }
        .opacity(sending ? ChatMetrics.sendingStrength : 1)
    }
}

/// The add field a one-list card and the panel end in: Return adds the item
/// and keeps the field for the next one.
struct ChecklistAddField: View {
    let add: (String) -> Void

    @State private var text = ""

    var body: some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: "plus")
                .foregroundStyle(Palette.faint.color)
                .accessibilityHidden(true)
            TextField(ProductStrings[.listsAddItem], text: $text)
                .textFieldStyle(.plain)
                .fermixType(Typography.style(.callout).weight(.regular))
                .onSubmit {
                    let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !words.isEmpty else { return }

                    add(words)
                    text = ""
                }
        }
        .frame(minHeight: ChecklistMetrics.target)
    }
}

/// Lines that wrap: a folded card's chips, one after another, onto as many
/// lines as the column needs.
struct ChecklistFlow: Layout {
    let spacing: Double

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arranged(subviews, width: proposal.width ?? .infinity)
        let width = rows.map { $0.last.map { $0.x + $0.size.width } ?? 0 }.max() ?? 0
        let height = rows.last.map { row in row.map { $0.y + $0.size.height }.max() ?? 0 } ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var index = 0
        for row in arranged(subviews, width: bounds.width) {
            for place in row {
                subviews[index].place(at: CGPoint(x: bounds.minX + place.x, y: bounds.minY + place.y), proposal: ProposedViewSize(place.size))
                index += 1
            }
        }
    }

    private func arranged(_ subviews: Subviews, width: Double) -> [[(x: Double, y: Double, size: CGSize)]] {
        var rows: [[(x: Double, y: Double, size: CGSize)]] = [[]]
        var x = 0.0
        var y = 0.0
        var lineHeight = 0.0

        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
            if x > 0, x + size.width > width {
                rows.append([])
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            rows[rows.count - 1].append((x, y, CGSize(width: min(size.width, width), height: size.height)))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }

        return rows
    }
}

/// How the lists' counts read: "6 open", "6 open · 2 done".
enum ChecklistWordsFor {
    static func open(_ count: Int) -> String {
        String(format: ProductStrings[.listsOpenFormat], count)
    }

    static func counts(open: Int, done: Int) -> String {
        ProductStrings.middot(self.open(open), String(format: ProductStrings[.listsDoneFormat], done))
    }

    /// "Fermix, list, 6 open": a card of one list, to VoiceOver.
    static func listLabel(_ title: String, open: Int) -> String {
        String(format: ProductStrings[.listsListLabelFormat], title, self.open(open))
    }

    /// "Fermix, Portfolio site, and Groceries, lists": a card of several.
    static func listsLabel(_ titles: [String]) -> String {
        String(format: ProductStrings[.listsListsLabelFormat], ListFormatter.localizedString(byJoining: titles))
    }
}
