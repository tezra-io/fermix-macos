import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A row's strip (M66 §3.2): its previews in one sideways row, then its
/// files' cards in another, then its links' cards (M72), each on the row's
/// side. A row with more than fits scrolls
/// sideways, by trackpad or a shifted wheel, by the arrows at its ends, or by
/// the arrow keys from tile to tile; a plain wheel still scrolls the
/// transcript. Nothing opens over the chat.
struct ChatStripView: View {
    let strip: ChatStrip
    /// Whether the row is the person's, drawn on the trailing side.
    let trailing: Bool
    /// The width the strip may take.
    let width: Double

    var body: some View {
        VStack(alignment: trailing ? .trailing : .leading, spacing: ChatMetrics.stripTopGap) {
            if !strip.previews.isEmpty {
                let tile = ChatStripFit.tileSize(width: ChatStripFit.itemWidth(count: strip.previews.count, width: width))
                ChatStripLane(items: strip.previews, itemWidth: tile.width, width: width, trailing: trailing) { item in
                    ChatPreviewTile(item: item, size: tile)
                }
            }

            if !strip.cards.isEmpty {
                let card = ChatStripFit.itemWidth(count: strip.cards.count, width: width)
                ChatStripLane(items: strip.cards, itemWidth: card, width: width, trailing: trailing) { item in
                    ChatCard(item: item, width: card)
                }
            }

            if !strip.links.isEmpty {
                ChatLinkLane(links: strip.links, width: width, trailing: trailing)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// One sideways row of a strip. While it fits it sits on the row's side, as
/// a row of words does; once it does not, it takes the whole width, starts at
/// its first item and scrolls. An end with more past it fades, and, under the
/// pointer, carries an arrow that moves the row on by what it shows.
///
/// A row that scrolls takes focus as a whole, whatever the keyboard
/// navigation setting: a click on its empty space or on an arrow gives it
/// focus, and then the left and right arrow keys move it by one item and
/// Escape lets it go. Its arrows stay out while it has focus, beside the
/// system's own focus ring, which the app never suppresses (redlines §9).
/// With keyboard navigation on, Tab also reaches each item, and while an item
/// has focus the arrow keys move focus from item to item instead, bringing
/// each into view. Neither ever takes an arrow key from anything else that
/// has focus, the composer among them.
///
/// A reply's place cards ride the same row (M72 §8.1), so it takes any item
/// known by a string.
struct ChatStripLane<Item: Identifiable, Tile: View>: View where Item.ID == String {
    let items: [Item]
    let itemWidth: Double
    let width: Double
    let trailing: Bool
    @ViewBuilder let tile: (Item) -> Tile

    @State private var position = ScrollPosition(idType: String.self, edge: .leading)
    @State private var scroll = ChatStripScroll(offset: 0, content: 0, container: 0)
    @State private var hovering = false
    /// The item with focus, under keyboard navigation.
    @FocusState private var focused: String?
    /// Whether the row itself has focus.
    @FocusState private var laneFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if ChatStripFit.rowWidth(count: items.count, itemWidth: itemWidth) <= width {
            row
                .frame(width: width, alignment: trailing ? .trailing : .leading)
        } else {
            let edges = ChatStripEdges(scroll)

            ScrollView(.horizontal) {
                row
                    .scrollTargetLayout()
                    .contentShape(Rectangle())
                    .onTapGesture { laneFocused = true }
            }
            .scrollIndicators(.never)
            .scrollPosition($position)
            .onScrollGeometryChange(for: ChatStripScroll.self, of: ChatStripScroll.init) { _, now in
                scroll = now
            }
            .mask { ChatStripFade(edges: edges) }
            .overlay(alignment: .leading) {
                arrow(forward: false, shown: (hovering || laneFocused) && edges.leading)
            }
            .overlay(alignment: .trailing) {
                arrow(forward: true, shown: (hovering || laneFocused) && edges.trailing)
            }
            .onHover { hovering = $0 }
            // A row takes focus the way a text field does, on a click and
            // whatever the keyboard navigation setting: a plain focusable
            // view on macOS takes it only with that setting on, which is
            // not the default. A tile with focus answers the keys first,
            // inside the row.
            .focusable(true, interactions: .edit)
            .focused($laneFocused)
            .onKeyPress(.leftArrow) { step(forward: false) }
            .onKeyPress(.rightArrow) { step(forward: true) }
            .onExitCommand { laneFocused = false }
            .frame(width: width)
        }
    }

    private var row: some View {
        HStack(spacing: ChatMetrics.stripGap) {
            ForEach(items) { item in
                tile(item)
                    .focused($focused, equals: item.id)
            }
        }
        .onKeyPress(.leftArrow) { move(by: -1) }
        .onKeyPress(.rightArrow) { move(by: 1) }
    }

    /// An end's arrow: a small round control in the secondary capsule's own
    /// fill and border. VoiceOver reaches every tile itself and is not shown
    /// it.
    private func arrow(forward: Bool, shown: Bool) -> some View {
        Button {
            laneFocused = true
            page(forward: forward)
        } label: {
            Image(systemName: forward ? "chevron.right" : "chevron.left")
        }
        .buttonStyle(ChatStripArrowStyle())
        .focusable(false)
        .padding(.horizontal, ChatMetrics.stripArrowInset)
        .opacity(shown ? 1 : 0)
        .allowsHitTesting(shown)
        .animation(Motion(reduceMotion: reduceMotion).animation(.stepCrossfade), value: shown)
        .accessibilityHidden(true)
    }

    /// Moves the row on by what it shows.
    private func page(forward: Bool) {
        slide(to: ChatStripEdges.page(from: scroll, forward: forward))
    }

    /// Moves the row on by one item and its gap.
    private func step(forward: Bool) -> KeyPress.Result {
        slide(to: ChatStripEdges.step(from: scroll, item: itemWidth, forward: forward))
        return .handled
    }

    private func slide(to offset: Double) {
        withAnimation(scrollAnimation) {
            position.scrollTo(x: offset)
        }
    }

    /// Moves focus to the item beside the focused one, the first and last
    /// holding at their end, and brings it into view.
    private func move(by step: Int) -> KeyPress.Result {
        guard let focused, let index = items.firstIndex(where: { $0.id == focused }) else { return .ignored }

        let next = items[ChatStripNavigation.index(from: index, by: step, count: items.count)].id
        self.focused = next
        withAnimation(scrollAnimation) {
            position.scrollTo(id: next)
        }
        return .handled
    }

    /// A scroll is travel, which Reduce Motion drops entirely rather than
    /// shortening, as it does an entrance's.
    private var scrollAnimation: Animation? {
        reduceMotion ? nil : MotionTable.spec(.stepCrossfade).animation
    }
}

/// Where a sideways row stands, read off its scroll geometry.
struct ChatStripScroll: Equatable {
    let offset: Double
    let content: Double
    let container: Double

    init(offset: Double, content: Double, container: Double) {
        self.offset = offset
        self.content = content
        self.container = container
    }

    init(_ geometry: ScrollGeometry) {
        offset = geometry.contentOffset.x
        content = geometry.contentSize.width
        container = geometry.containerSize.width
    }
}

/// Which ends of a sideways row have more past them, a point of slack at each
/// so a row resting at its end reads as there.
struct ChatStripEdges: Equatable {
    let leading: Bool
    let trailing: Bool

    static let slack: Double = 1

    init(leading: Bool, trailing: Bool) {
        self.leading = leading
        self.trailing = trailing
    }

    init(_ scroll: ChatStripScroll) {
        leading = scroll.offset > Self.slack
        trailing = scroll.offset + scroll.container < scroll.content - Self.slack
    }

    /// Where a page towards one end lands: one visible width along, and never
    /// past either end.
    static func page(from scroll: ChatStripScroll, forward: Bool) -> Double {
        along(scroll, by: forward ? scroll.container : -scroll.container)
    }

    /// Where a step of one item towards one end lands: the item and the gap
    /// after it along, and never past either end.
    static func step(from scroll: ChatStripScroll, item: Double, forward: Bool) -> Double {
        let distance = item + ChatMetrics.stripGap
        return along(scroll, by: forward ? distance : -distance)
    }

    private static func along(_ scroll: ChatStripScroll, by distance: Double) -> Double {
        min(max(scroll.offset + distance, 0), max(scroll.content - scroll.container, 0))
    }
}

/// Moving along a row by the arrow keys.
enum ChatStripNavigation {
    /// The item `step` along from `index`, held at the first and the last.
    static func index(from index: Int, by step: Int, count: Int) -> Int {
        min(max(index + step, 0), max(count - 1, 0))
    }
}

/// The mask a sideways row is drawn through, a strip's or a wide table's:
/// whole, but fading out at an end with more past it. A mask's colours are
/// only how much shows.
struct ChatStripFade: View {
    let edges: ChatStripEdges

    var body: some View {
        HStack(spacing: 0) {
            end(fades: edges.leading, from: .trailing, to: .leading)
            Rectangle()
            end(fades: edges.trailing, from: .leading, to: .trailing)
        }
    }

    @ViewBuilder
    private func end(fades: Bool, from: UnitPoint, to: UnitPoint) -> some View {
        if fades {
            LinearGradient(colors: [.black, .clear], startPoint: from, endPoint: to)
                .frame(width: ChatMetrics.stripFadeWidth)
        } else {
            Rectangle()
                .frame(width: ChatMetrics.stripFadeWidth)
        }
    }
}

/// An end's arrow: round, at the regular control's height, in the secondary
/// capsule's fill and border with an ink glyph, and the pressed fill while
/// held.
private struct ChatStripArrowStyle: ButtonStyle {
    @Environment(\.colorSchemeContrast) private var contrast

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .fermixType(Typography.style(.calloutSmall).weight(.semibold))
            .foregroundStyle(ButtonRecipe.secondaryLabel.color)
            .frame(width: HitTarget.rowAction, height: HitTarget.rowAction)
            .background(Circle().fill((configuration.isPressed ? Palette.base300 : ButtonRecipe.secondaryFill).color))
            .overlay(
                Circle().strokeBorder(
                    contrast == .increased
                        ? Palette.hairline(.standard, increaseContrast: true).color
                        : ButtonRecipe.secondaryBorder.color,
                    lineWidth: Stroke.hairline
                )
            )
    }
}

/// What a preview tile or a card has found of its file, read once it is on
/// screen, and, where the file opens outside Fermix, the app that takes it.
private struct ChatFileReading {
    var lookup: ChatFileLookup = .reading
    var hint: ChatTileHint?

    static func spoken(_ hint: ChatTileHint) -> String {
        switch hint {
        case .openIn(let app): return BrowserText.openIn(app)
        case .showInFinder: return ProductStrings[.browserShowInFinder]
        }
    }
}

/// A file the tile names, as its name says until the disk says more.
private struct ChatNamedFile {
    let file: URL

    var name: String {
        file.lastPathComponent
    }

    /// Its type as its name says it.
    var type: UTType {
        ChatPreviewPolicy.type(ofPath: file.path) ?? (file.hasDirectoryPath ? .folder : .data)
    }

    /// Its type as the disk says it, once the tile has read it.
    func type(_ reading: ChatFileReading) -> UTType {
        if case .found(let facts) = reading.lookup { return facts.type }

        return type
    }

    func family(_ reading: ChatFileReading) -> ChatFileFamily {
        if case .found(let facts) = reading.lookup { return ChatPreviewPolicy.family(of: facts) }

        return ChatPreviewPolicy.family(of: type)
    }
}

/// A phone-side file as its tile names it, from its row alone: the type the
/// policy reads there, and its name and label (`ChatPreviewPolicy`).
private struct ChatNamedRef {
    let ref: CompanionMediaRef

    var type: UTType {
        ChatPreviewPolicy.type(of: ref)
    }

    var family: ChatFileFamily {
        ChatPreviewPolicy.family(of: type)
    }

    var name: String {
        ChatPreviewPolicy.name(of: ref)
    }

    var label: String {
        ChatPreviewPolicy.label(of: ref)
    }
}

/// An item drawn by its content, by what it is: a file a path names, or a
/// phone-side file. A link is drawn from its address, as a card, and is never
/// among them.
private struct ChatPreviewTile: View {
    let item: ChatStripItem
    let size: CGSize

    var body: some View {
        switch item {
        case .file(let file): ChatFilePreviewTile(named: ChatNamedFile(file: file), size: size)
        case .media(let ref): ChatRefPreviewTile(named: ChatNamedRef(ref: ref), size: size)
        case .link: EmptyView()
        }
    }
}

/// A picture, a video's frame or a page Fermix made, filling its tile. It
/// reads what the file is once it is on screen, then where it goes outside
/// Fermix or its preview, asked again only where its last answer was not
/// final (`ChatPreviewOutcome.isFinal`).
private struct ChatFilePreviewTile: View {
    let named: ChatNamedFile
    let size: CGSize

    @State private var reading = ChatFileReading()
    @State private var outcome: ChatPreviewOutcome?
    @Environment(\.chatRows) private var rows
    @Environment(\.displayScale) private var scale
    @Environment(\.openURL) private var openURL

    var body: some View {
        let family = named.family(reading)

        ChatPreviewFace(
            size: size,
            state: ChatPreviewPolicy.state(of: reading.lookup, outcome: outcome),
            family: family,
            type: named.type(reading),
            name: named.name,
            label: ProductStrings.commaPair(named.name, ChatPreviewPolicy.kindWord(family)),
            hint: reading.hint,
            open: { openURL(named.file) },
            load: load
        )
    }

    private func load() async {
        guard let rows else { return }

        if reading.lookup == .reading {
            reading.lookup = await rows.media.lookUp(named.file, in: rows.visit)
        }
        guard case .found(let facts) = reading.lookup else { return }

        if ChatPreviewPolicy.family(of: facts) == .other {
            reading.hint = await rows.media.hint(for: facts.disk)
            return
        }
        guard ChatPreviewPolicy.drawsContent(facts), outcome?.isFinal != true else { return }

        let made = await rows.media.previews.preview(ChatPreviewRequest(facts, size: size, scale: scale))
        guard !Task.isCancelled else { return }

        outcome = made
        if made == .unplayable {
            reading.hint = await rows.media.hint(for: facts.disk)
        }
    }
}

/// A phone-side picture, video, PDF or document filling its tile (M66 §3.3,
/// decision 1). Its preview is made while it is on screen from the file the
/// engine grants for its ref, held only while the preview is made, and kept
/// by the ref, so a tile that comes back costs nothing. A ref whose bytes the
/// engine no longer has is Not available. A click opens the granted file in
/// the pane, as a file at that path would open.
private struct ChatRefPreviewTile: View {
    let named: ChatNamedRef
    let size: CGSize

    @State private var outcome: ChatPreviewOutcome?
    @State private var hint: ChatTileHint?
    @Environment(\.chatRows) private var rows
    @Environment(\.displayScale) private var scale

    var body: some View {
        ChatPreviewFace(
            size: size,
            state: ChatPreviewPolicy.state(of: outcome),
            family: named.family,
            type: named.type,
            name: named.name,
            label: named.label,
            hint: hint,
            open: open,
            load: load
        )
    }

    /// Through the one content link opener, which says whether the engine
    /// no longer has the file's bytes.
    private func open() {
        guard let rows else { return }

        Task {
            guard await rows.links.open(ref: named.ref.ref, named: named.name) == .missing else { return }

            outcome = .missing
        }
    }

    private func load() async {
        guard let rows, outcome?.isFinal != true else { return }

        let made = await rows.media.previews.preview(ChatPreviewRequest(named.ref, size: size, scale: scale))
        guard !Task.isCancelled else { return }

        outcome = made
        if made == .unplayable {
            hint = await rows.media.hint(for: ChatPreviewPolicy.facts(of: named.ref))
        }
    }
}

/// A preview tile's face and button, whatever its file (M66 §3.3): the
/// preview filling the tile edge to edge once it is made, a page keeping its
/// head in view and its name along its foot, a picture or a video carrying
/// no words, its name being in its tooltip and what VoiceOver reads. Until
/// the preview comes, and where it cannot, the tile shows its icon with its
/// name, at the same size: a preview tile stays one, so nothing moves.
///
/// It loads what it shows while it is on screen: leaving the screen cancels
/// that, and coming back asks again, which is the one retry a failed
/// preview has. It is one button with its label, Not available as its value,
/// and an Opens outside tile's hint.
private struct ChatPreviewFace: View {
    let size: CGSize
    let state: ChatTileState
    let family: ChatFileFamily
    let type: UTType
    let name: String
    let label: String
    let hint: ChatTileHint?
    let open: () -> Void
    let load: () async -> Void

    @State private var onScreen = false
    @State private var slow = false

    var body: some View {
        Button(action: open) {
            ChatTileFrame(size: size) {
                if case .ready(let preview?) = state {
                    ChatTilePicture(preview: preview, family: family, name: name)
                } else {
                    ChatTileIcon(type: type, state: state, slow: slow, name: name)
                }
            }
        }
        .buttonStyle(ChatTileButtonStyle())
        .onKeyPress(.return) {
            open()
            return .handled
        }
        .disabled(state == .notAvailable)
        .help(name)
        .accessibilityLabel(label)
        .accessibilityValue(state == .notAvailable ? ProductStrings[.chatTileNotAvailable] : "")
        .accessibilityHint(state == .opensOutside ? hint.map(ChatFileReading.spoken) ?? "" : "")
        .onScrollVisibilityChange(threshold: 0.01) { onScreen = $0 }
        .task(id: onScreen) {
            guard onScreen else { return }

            await load()
        }
        .task(id: onScreen) {
            guard onScreen else { return }

            try? await Task.sleep(for: ChatMetrics.tileProgressDelay)
            slow = !Task.isCancelled
        }
    }
}

/// Everything that draws no preview, as a compact card: a link, a file whose
/// content a tile does not draw (text, code, HTML, SVG, anything outside the
/// Fermix home), and a phone-side file of the same kinds.
private struct ChatCard: View {
    let item: ChatStripItem
    let width: Double

    var body: some View {
        switch item {
        case .media(let ref): ChatRefCard(named: ChatNamedRef(ref: ref), width: width)
        case .file(let file): ChatFileCard(named: ChatNamedFile(file: file), width: width)
        case .link(let link): ChatLinkCard(link: link)
        }
    }
}

/// A file as a card. It reads what the file is once it is on screen.
private struct ChatFileCard: View {
    let named: ChatNamedFile
    let width: Double

    @State private var reading = ChatFileReading()
    @State private var onScreen = false
    @Environment(\.chatRows) private var rows
    @Environment(\.openURL) private var openURL

    var body: some View {
        let kind = ChatPreviewPolicy.kindWord(named.family(reading))

        ChatFileCardButton(
            width: width,
            state: ChatPreviewPolicy.cardState(of: reading.lookup),
            type: named.type(reading),
            name: named.name,
            kind: kind,
            label: ProductStrings.commaPair(named.name, kind),
            hint: reading.hint,
            open: { openURL(named.file) }
        )
        .onScrollVisibilityChange(threshold: 0.01) { onScreen = $0 }
        .task(id: onScreen) {
            guard onScreen, let rows, reading.lookup == .reading else { return }

            reading.lookup = await rows.media.lookUp(named.file, in: rows.visit)
            guard case .found(let facts) = reading.lookup, ChatPreviewPolicy.family(of: facts) == .other else { return }

            reading.hint = await rows.media.hint(for: facts.disk)
        }
    }
}

/// A phone-side file whose content a tile does not draw, as a card. Nothing
/// is asked of the engine for it until it is clicked: a click opens the file
/// the engine grants in the pane, as a file at that path would open, and
/// where the engine no longer has its bytes the card says Not available.
private struct ChatRefCard: View {
    let named: ChatNamedRef
    let width: Double

    /// Whether a click found the file's bytes gone.
    @State private var gone = false
    @State private var hint: ChatTileHint?
    @Environment(\.chatRows) private var rows

    var body: some View {
        let state = ChatPreviewPolicy.cardState(of: named.ref, gone: gone)

        ChatFileCardButton(
            width: width,
            state: state,
            type: named.type,
            name: named.name,
            kind: ChatPreviewPolicy.kindWord(named.family),
            label: named.label,
            hint: hint,
            open: open
        )
        .task(id: state == .opensOutside) {
            guard let rows, state == .opensOutside else { return }

            hint = await rows.media.hint(for: ChatPreviewPolicy.facts(of: named.ref))
        }
    }

    /// Through the one content link opener, which says whether the engine
    /// no longer has the file's bytes.
    private func open() {
        guard let rows else { return }

        Task { gone = await rows.links.open(ref: named.ref.ref, named: named.name) == .missing }
    }
}

/// A file's card and button, whatever its file: its icon, its name, and its
/// kind, or "Not available" where it is gone. One the pane does not show
/// carries the pane's open-in-app glyph, and VoiceOver hears where it goes.
private struct ChatFileCardButton: View {
    let width: Double
    let state: ChatTileState
    let type: UTType
    let name: String
    let kind: String
    let label: String
    let hint: ChatTileHint?
    let open: () -> Void

    var body: some View {
        let missing = state == .notAvailable

        Button(action: open) {
            ChatCardFace(
                width: width,
                title: name,
                detail: missing ? ProductStrings[.chatTileNotAvailable] : kind,
                opensOutside: state == .opensOutside,
                titleTruncation: .middle
            ) {
                ChatCardIcon(type: type, dimmed: missing)
            }
        }
        .buttonStyle(ChatTileButtonStyle())
        .onKeyPress(.return) {
            open()
            return .handled
        }
        .disabled(missing)
        .accessibilityLabel(label)
        .accessibilityValue(missing ? ProductStrings[.chatTileNotAvailable] : "")
        .accessibilityHint(state == .opensOutside ? hint.map(ChatFileReading.spoken) ?? "" : "")
    }
}

/// A compact card's face: its icon, its title over one line of detail, and,
/// for a file the pane does not show, the pane's open-in-app glyph at its end.
/// A file's name is cut in its middle, where it is least itself; a page's
/// title at its end.
private struct ChatCardFace<Icon: View>: View {
    let width: Double
    let title: String
    let detail: String
    let opensOutside: Bool
    let titleTruncation: Text.TruncationMode
    @ViewBuilder let icon: Icon

    var body: some View {
        ChatTileFrame(size: CGSize(width: width, height: ChatMetrics.cardHeight)) {
            HStack(spacing: Spacing.s) {
                icon

                VStack(alignment: .leading, spacing: 0) {
                    Text(title)
                        .fermixType(Typography.style(.callout))
                        .foregroundStyle(Palette.ink.color)
                        .truncationMode(titleTruncation)
                    Text(detail)
                        .fermixType(Typography.style(.caption))
                        .foregroundStyle(Palette.secondary.color)
                        .truncationMode(.middle)
                }
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

                if opensOutside {
                    Image(systemName: "arrow.up.forward.app")
                        .fermixType(Typography.style(.calloutSmall))
                        .foregroundStyle(Palette.secondary.color)
                }
            }
            .padding(.horizontal, Spacing.s)
        }
    }
}

/// A file's icon on a card, by its type, dimmed where the file is not there.
private struct ChatCardIcon: View {
    let type: UTType
    let dimmed: Bool

    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(for: type))
            .resizable()
            .frame(width: ChatMetrics.cardIconSize, height: ChatMetrics.cardIconSize)
            .opacity(dimmed ? ButtonRecipe.disabledOpacity : 1)
            .accessibilityHidden(true)
    }
}

/// A tile's own shape: the chip's fill and the user chip's corners, at a size
/// it keeps from the moment it is drawn, whatever it is waiting for, so
/// nothing under it moves as previews arrive.
struct ChatTileFrame<Content: View>: View {
    let size: CGSize
    @ViewBuilder let content: Content

    @State private var hovering = false
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        content
            .frame(width: size.width, height: size.height)
            .background(shape.fill(Palette.chipFill.color))
            .clipShape(shape)
            .overlay(shape.strokeBorder(stroke.color, lineWidth: Stroke.hairline))
            .contentShape(shape)
            .onHover { hovering = $0 }
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: ChatMetrics.rowRadius, style: .continuous)
    }

    /// A faint edge at rest, so a white picture keeps its outline on the
    /// light ground, and the standard one under the pointer where a click
    /// does something.
    private var stroke: ThemedColor {
        Palette.hairline(hovering && isEnabled ? .standard : .faint, increaseContrast: contrast == .increased)
    }
}

/// A preview filling its tile: already cut to the tile's pixels, held at a
/// page's head or a picture's middle (`ChatPreviewCover`). Over it, a video's
/// play mark and length; a page's name along its foot and its page count in
/// the corner above, clear of the name; and a moving picture's mark, since it
/// never moves in the chat.
private struct ChatTilePicture: View {
    let preview: ChatPreview
    let family: ChatFileFamily
    let name: String

    @Environment(\.displayScale) private var scale

    var body: some View {
        Image(decorative: preview.image, scale: scale)
            .resizable()
            .overlay { marks }
            .overlay(alignment: .bottom) {
                if family == .pdf || family == .document {
                    ChatTileCaption(name: name)
                }
            }
    }

    @ViewBuilder
    private var marks: some View {
        if family == .video {
            Image(systemName: "play.fill")
                .fermixType(Typography.style(.callout))
                .padding(Spacing.xs)
                .background(Circle().fill(Palette.cardFill.color))
                .foregroundStyle(Palette.ink.color)
        }

        switch preview.detail {
        case .length(let seconds)?:
            ChatTileBadge { Text(Duration.seconds(seconds).formatted(.time(pattern: .minuteSecond))).monospacedDigit() }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        case .pages(let count)?:
            ChatTileBadge { Text(ChatPreviewPolicy.pages(count)) }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        case .animated?:
            ChatTileBadge { Image(systemName: "livephoto") }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        case nil:
            EmptyView()
        }
    }
}

/// A file's name along a tile's foot, on a quiet band of the card's fill that
/// keeps the name's contrast over whatever is under it.
private struct ChatTileCaption: View {
    let name: String

    var body: some View {
        Text(name)
            .fermixType(Typography.style(.calloutSmall))
            .foregroundStyle(Palette.ink.color)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, Spacing.s)
            .padding(.vertical, Spacing.xxs)
            .frame(maxWidth: .infinity)
            .background(Palette.cardFill.color.opacity(ChatMetrics.tileScrimStrength))
            .accessibilityHidden(true)
    }
}

/// A small fact over a picture, on the card's own fill so it reads over
/// whatever the picture holds.
private struct ChatTileBadge<Label: View>: View {
    @ViewBuilder let label: Label

    var body: some View {
        label
            .fermixType(Typography.style(.caption))
            .foregroundStyle(Palette.ink.color)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, Spacing.xs)
            .padding(.vertical, Spacing.xxs)
            .background(Capsule().fill(Palette.cardFill.color))
            .padding(Spacing.xs)
            .accessibilityHidden(true)
    }
}

/// A preview tile with its icon for its picture: while its preview is made,
/// where it failed or is not drawn, where it opens outside Fermix, or where
/// it is not there; with its name along its foot as a page's has. Loading
/// shows a quiet progress mark once it has taken long enough to notice;
/// Opens outside shows the pane's own open-in-app glyph; Not available says
/// so under a dimmed icon.
private struct ChatTileIcon: View {
    let type: UTType
    let state: ChatTileState
    let slow: Bool
    let name: String

    var body: some View {
        VStack(spacing: Spacing.xxs) {
            Image(nsImage: NSWorkspace.shared.icon(for: type))
                .resizable()
                .frame(width: ChatMetrics.tileIconSize, height: ChatMetrics.tileIconSize)
                .opacity(state == .notAvailable ? ButtonRecipe.disabledOpacity : 1)

            if state == .notAvailable {
                Text(ProductStrings[.chatTileNotAvailable])
                    .fermixType(Typography.style(.caption))
                    .foregroundStyle(Palette.secondary.color)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topTrailing) {
            corner.padding(Spacing.xs)
        }
        .overlay(alignment: .bottom) {
            ChatTileCaption(name: name)
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var corner: some View {
        if state == .opensOutside {
            Image(systemName: "arrow.up.forward.app")
                .fermixType(Typography.style(.calloutSmall))
                .foregroundStyle(Palette.secondary.color)
        } else if state == .loading, slow {
            ActivityMark()
        }
    }
}

/// A tile's press: it dims while held, and nothing else, since the tile draws
/// its own rest and hover.
struct ChatTileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? ChatMetrics.tilePressedStrength : 1)
    }
}
