import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// What a row's media reads from the chat surface. The transcript builds each
/// row with nothing of its own to hand it, so the surface sets this in the
/// environment once for every row.
struct ChatStripContext: Equatable, Sendable {
    let media: ChatMedia
    /// The reading column's width, which a strip fits its tiles to.
    let columnWidth: Double
    /// The rows whose strip shows every item.
    let openStrips: Set<Int>
    /// **+N** and **Show fewer**: the session's own toggle.
    let toggle: @MainActor @Sendable (Int) -> Void

    /// The toggle is the session's for the surface's whole life, so two
    /// contexts are the same when the rest is: a keystroke in the composer
    /// redraws the surface, and must not redraw every row with it.
    static func == (lhs: ChatStripContext, rhs: ChatStripContext) -> Bool {
        lhs.media === rhs.media && lhs.columnWidth == rhs.columnWidth && lhs.openStrips == rhs.openStrips
    }
}

extension EnvironmentValues {
    /// The chat surface's media for its rows. Absent where no chat surface
    /// hosts a row, which is to say in tests.
    var chatStrips: ChatStripContext? {
        get { self[ChatStripContextKey.self] }
        set { self[ChatStripContextKey.self] = newValue }
    }
}

private struct ChatStripContextKey: EnvironmentKey {
    static let defaultValue: ChatStripContext? = nil
}

/// A row's strip (M66 §3.2): its previews first, in rows of as many as fit
/// up to three, then its cards in rows of the same width, and **+N** after
/// the last when it has more than three. Folded, it shows three items at
/// most, previews first; open, every item, built only then, and **Show
/// fewer** at the end. Nothing scrolls sideways and nothing opens over the
/// chat.
struct ChatStripView: View {
    let strip: ChatStrip
    let seq: Int
    /// Whether the row is the person's, drawn on the trailing side.
    let trailing: Bool
    /// The width the strip may take.
    let width: Double
    let context: ChatStripContext

    var body: some View {
        let fit = ChatStripFit.of(count: strip.items.count, width: width)
        let open = fit.more > 0 && context.openStrips.contains(seq)
        let count = open ? strip.items.count : fit.shown
        let previews = Array(strip.previews.prefix(count))
        let cards = Array(strip.cards.prefix(count - previews.count))

        ChatStripRows(perRow: fit.shown, groups: [previews.count, cards.count], trailing: trailing, endsWithControl: fit.more > 0) {
            ForEach(previews, id: \.self) { file in
                ChatPreviewTile(named: ChatNamedFile(file: file), size: fit.tileSize, media: context.media)
            }
            ForEach(cards) { item in
                ChatCard(item: item, width: fit.tileWidth, media: context.media)
            }

            if fit.more > 0 {
                control(open: open, more: fit.more)
            }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func control(open: Bool, more: Int) -> some View {
        if open {
            Button(ProductStrings[.chatStripShowFewer]) { context.toggle(seq) }
                .buttonStyle(SecondaryButtonStyle(.row))
        } else {
            Button(String(format: ProductStrings[.chatStripMoreFormat], more)) { context.toggle(seq) }
                .buttonStyle(SecondaryButtonStyle(.row))
                .accessibilityLabel(String(format: ProductStrings[.chatStripMoreSpokenFormat], more))
        }
    }
}

/// The strip's rows: each group (the previews, then the cards) left to
/// right, `perRow` to a row, no row holding two groups, then the control at
/// the end of the last row where it fits and on a row of its own where it
/// does not. Each row sits on the strip's side, and each item is centred on
/// its row's height.
struct ChatStripRows: Layout {
    let perRow: Int
    /// How many subviews each group has, in order.
    let groups: [Int]
    let trailing: Bool
    /// Whether the last subview is **+N** or **Show fewer** rather than an
    /// item.
    let endsWithControl: Bool

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let room = proposal.width.map(Double.init)
        let rows = rows(of: sizes, width: room)
        let widest = rows.map { width(of: $0, sizes: sizes) }.max() ?? 0
        let height = rows.map { height(of: $0, sizes: sizes) }.reduce(0, +) + Double(max(rows.count - 1, 0)) * ChatMetrics.stripGap

        return CGSize(width: room ?? widest, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        var top = bounds.minY
        for row in rows(of: sizes, width: bounds.width) {
            let rowHeight = height(of: row, sizes: sizes)
            var leading = trailing ? bounds.maxX - width(of: row, sizes: sizes) : bounds.minX
            for index in row {
                let size = sizes[index]
                subviews[index].place(
                    at: CGPoint(x: leading, y: top + (rowHeight - size.height) / 2),
                    proposal: ProposedViewSize(size)
                )
                leading += size.width + ChatMetrics.stripGap
            }
            top += rowHeight + ChatMetrics.stripGap
        }
    }

    /// The subviews' indices row by row.
    func rows(of sizes: [CGSize], width: Double?) -> [[Int]] {
        var rows: [[Int]] = []
        var start = 0
        for count in groups {
            let end = start + count
            rows += stride(from: start, to: end, by: max(perRow, 1)).map { Array($0 ..< min($0 + perRow, end)) }
            start = end
        }
        guard endsWithControl, let control = sizes.indices.last else { return rows }

        if let last = rows.last, self.width(of: last, sizes: sizes) + ChatMetrics.stripGap + sizes[control].width <= width ?? .infinity {
            rows[rows.count - 1].append(control)
        } else {
            rows.append([control])
        }
        return rows
    }

    private func width(of row: [Int], sizes: [CGSize]) -> Double {
        row.map { sizes[$0].width }.reduce(0, +) + Double(max(row.count - 1, 0)) * ChatMetrics.stripGap
    }

    private func height(of row: [Int], sizes: [CGSize]) -> Double {
        row.map { sizes[$0].height }.max() ?? 0
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

/// A picture, a video's frame or a page Fermix made, filling its tile edge to
/// edge (M66 §3.3). A page keeps its head in view and its name along its foot;
/// a picture or a video carries no words, its name being in its tooltip and
/// what VoiceOver reads. Until the preview comes, and where it cannot, the
/// tile shows its icon with its name, at the same size: a preview tile stays
/// one, so nothing moves. It reads what the file is once it is on screen and
/// asks for its preview while it stays there: leaving the screen cancels the
/// ask, and coming back asks again, which is the one retry a failed preview
/// has.
private struct ChatPreviewTile: View {
    let named: ChatNamedFile
    let size: CGSize
    let media: ChatMedia

    @State private var reading = ChatFileReading()
    @State private var outcome: ChatPreviewOutcome?
    @State private var onScreen = false
    @State private var slow = false
    @Environment(\.displayScale) private var scale
    @Environment(\.openURL) private var openURL

    var body: some View {
        let state = ChatPreviewPolicy.state(of: reading.lookup, outcome: outcome)
        let family = named.family(reading)

        Button { openURL(named.file) } label: {
            ChatTileFrame(size: size) {
                if case .ready(let preview?) = state {
                    ChatTilePicture(preview: preview, family: family, name: named.name)
                } else {
                    ChatTileIcon(type: named.type(reading), state: state, slow: slow, name: named.name)
                }
            }
        }
        .buttonStyle(ChatTileButtonStyle())
        .disabled(state == .notAvailable)
        .help(named.name)
        .accessibilityLabel(ProductStrings.commaPair(named.name, ChatPreviewPolicy.kindWord(family)))
        .accessibilityValue(state == .notAvailable ? ProductStrings[.chatTileNotAvailable] : "")
        .accessibilityHint(state == .opensOutside ? reading.hint.map(ChatFileReading.spoken) ?? "" : "")
        .onScrollVisibilityChange(threshold: 0.01) { onScreen = $0 }
        .task(id: onScreen) {
            guard onScreen else { return }

            await load(named.file)
        }
        .task(id: onScreen) {
            guard onScreen else { return }

            try? await Task.sleep(for: ChatMetrics.tileProgressDelay)
            slow = !Task.isCancelled
        }
    }

    /// What the file is, then where it goes outside Fermix or its preview.
    /// A preview that came to an end is not asked for again; one that failed
    /// or was let go is, and the previews decide whether it has a try left.
    private func load(_ file: URL) async {
        if reading.lookup == .reading {
            reading.lookup = await media.lookUp(file)
        }
        guard case .found(let facts) = reading.lookup else { return }

        if ChatPreviewPolicy.family(of: facts) == .other {
            reading.hint = await media.hint(for: facts)
            return
        }
        guard ChatPreviewPolicy.drawsContent(facts), !Self.ended(outcome) else { return }

        let made = await media.previews.preview(ChatPreviewRequest(facts, size: size, scale: scale))
        guard !Task.isCancelled else { return }

        outcome = made
        if made == .unplayable {
            reading.hint = await media.hint(for: facts)
        }
    }

    private static func ended(_ outcome: ChatPreviewOutcome?) -> Bool {
        switch outcome {
        case .made?, .iconOnly?, .unplayable?: return true
        case .failed?, .dropped?, nil: return false
        }
    }
}

/// Everything that draws no preview, as a compact card: a link, a file whose
/// content a tile does not draw (text, code, HTML, SVG, anything outside the
/// Fermix home), and a phone's file whose bytes are not in the app's hands.
private struct ChatCard: View {
    let item: ChatStripItem
    let width: Double
    let media: ChatMedia

    var body: some View {
        switch item {
        case .media(let ref): ChatRefCard(ref: ref, width: width)
        case .file(let file): ChatFileCard(named: ChatNamedFile(file: file), width: width, media: media)
        case .link(let link): ChatLinkCard(link: link, width: width)
        }
    }
}

/// A file as a card: its icon, its name, and its kind, or "Not available"
/// where it is gone. One the pane does not show carries the pane's
/// open-in-app glyph. It reads what the file is once it is on screen.
private struct ChatFileCard: View {
    let named: ChatNamedFile
    let width: Double
    let media: ChatMedia

    @State private var reading = ChatFileReading()
    @State private var onScreen = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        let state = ChatPreviewPolicy.cardState(of: reading.lookup)
        let kind = ChatPreviewPolicy.kindWord(named.family(reading))
        let missing = state == .notAvailable

        Button { openURL(named.file) } label: {
            ChatCardFace(
                width: width,
                title: named.name,
                detail: missing ? ProductStrings[.chatTileNotAvailable] : kind,
                opensOutside: state == .opensOutside,
                titleTruncation: .middle
            ) {
                ChatCardIcon(type: named.type(reading), dimmed: missing)
            }
        }
        .buttonStyle(ChatTileButtonStyle())
        .disabled(missing)
        .accessibilityLabel(ProductStrings.commaPair(named.name, kind))
        .accessibilityValue(missing ? ProductStrings[.chatTileNotAvailable] : "")
        .accessibilityHint(state == .opensOutside ? reading.hint.map(ChatFileReading.spoken) ?? "" : "")
        .onScrollVisibilityChange(threshold: 0.01) { onScreen = $0 }
        .task(id: onScreen) {
            guard onScreen, reading.lookup == .reading else { return }

            reading.lookup = await media.lookUp(named.file)
            guard case .found(let facts) = reading.lookup, ChatPreviewPolicy.family(of: facts) == .other else { return }

            reading.hint = await media.hint(for: facts)
        }
    }
}

/// A file the row refers to by ref. Its bytes are in the engine's media
/// store, which no request on either socket returns yet, so it is Not
/// available: its icon by its type, its name, and no click.
private struct ChatRefCard: View {
    let ref: CompanionMediaRef
    let width: Double

    var body: some View {
        let type = UTType(mimeType: ref.mime) ?? .data
        let kind = ChatPreviewPolicy.kindWord(ChatPreviewPolicy.family(of: type))
        let name = ref.filename ?? kind

        Button {} label: {
            ChatCardFace(width: width, title: name, detail: ProductStrings[.chatTileNotAvailable], opensOutside: false, titleTruncation: .middle) {
                ChatCardIcon(type: type, dimmed: true)
            }
        }
        .buttonStyle(ChatTileButtonStyle())
        .disabled(true)
        .accessibilityLabel(ProductStrings.commaPair(name, kind))
        .accessibilityValue(ProductStrings[.chatTileNotAvailable])
    }
}

/// A web address (M66 §3.3): with the preview the engine stored for it, its
/// title over its site; without one, its host over its path, read from the
/// address alone. Nothing is fetched to draw it. A click opens the address
/// as the text wrote it, where the person's preference says.
private struct ChatLinkCard: View {
    let link: ChatStripLink
    let width: Double

    @Environment(\.openURL) private var openURL

    var body: some View {
        Button { openURL(link.address) } label: {
            ChatCardFace(width: width, title: title, detail: detail, opensOutside: false, titleTruncation: .tail) {
                Image(systemName: "link")
                    .fermixType(Typography.style(.calloutSmall))
                    .foregroundStyle(Palette.secondary.color)
                    .frame(width: ChatMetrics.cardIconSize, height: ChatMetrics.cardIconSize)
                    .background(Circle().fill(Palette.monoDisc.color))
            }
        }
        .buttonStyle(ChatTileButtonStyle())
        .help(link.address.absoluteString)
        .accessibilityLabel(ProductStrings.commaPair(title, ProductStrings[.chatKindLink]))
    }

    private var title: String {
        link.preview?.title ?? host
    }

    /// The stored preview's site, or the address's path, or the kind's word
    /// for an address that is only its host.
    private var detail: String {
        if let site = link.preview?.site { return site }

        return path.isEmpty ? ProductStrings[.chatKindLink] : path
    }

    private var host: String {
        link.address.host(percentEncoded: false) ?? link.address.absoluteString
    }

    /// The address's path, where it has more of one than `/`.
    private var path: String {
        let path = link.address.path(percentEncoded: false)
        return path == "/" ? "" : path
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
private struct ChatTileFrame<Content: View>: View {
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
private struct ChatTileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? ChatMetrics.tilePressedStrength : 1)
    }
}
