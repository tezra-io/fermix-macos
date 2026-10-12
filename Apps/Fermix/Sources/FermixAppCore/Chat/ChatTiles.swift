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

/// A row's strip (M66 §3.2): its tiles side by side on the row's side, as
/// many as fit up to three, and **+N** after the last when it has more. Open,
/// it shows every tile in rows of the same tiles, built only then, and
/// **Show fewer** at the end of the last row. Nothing scrolls sideways and
/// nothing opens over the chat.
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
        let shown = open ? strip.items : Array(strip.items.prefix(fit.shown))

        ChatStripRows(perRow: fit.shown, trailing: trailing, endsWithControl: fit.more > 0) {
            ForEach(shown) { item in
                ChatTile(item: item, size: fit.tileSize, media: context.media)
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

/// The strip's rows: tiles left to right, `perRow` to a row, then the control
/// at the end of the last row where it fits and on a row of its own where it
/// does not. Each row sits on the strip's side, and each item is centred on
/// its row's height.
struct ChatStripRows: Layout {
    let perRow: Int
    let trailing: Bool
    /// Whether the last subview is **+N** or **Show fewer** rather than a tile.
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
        let tiles = endsWithControl ? sizes.count - 1 : sizes.count
        var rows = stride(from: 0, to: tiles, by: max(perRow, 1)).map { Array($0 ..< min($0 + perRow, tiles)) }
        guard endsWithControl, let control = sizes.indices.last else { return rows }

        let last = rows.last ?? []
        let room = width ?? .infinity
        if !last.isEmpty, self.width(of: last, sizes: sizes) + ChatMetrics.stripGap + sizes[control].width <= room {
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

/// One tile, drawn by what it shows.
private struct ChatTile: View {
    let item: ChatStripItem
    let size: CGSize
    let media: ChatMedia

    var body: some View {
        switch item {
        case .media(let ref): ChatRefTile(ref: ref, size: size)
        case .file(let file): ChatFileTile(file: file, size: size, media: media)
        case .link(let link): ChatLinkTile(link: link, size: size)
        }
    }
}

/// A file a path in the text names (M66 §3.3). It reads what the file is
/// once it is on screen, and asks for its preview while it stays there:
/// leaving the screen cancels the ask, and coming back asks again, which is
/// the one retry a failed preview has. It keeps its size throughout.
private struct ChatFileTile: View {
    let file: URL
    let size: CGSize
    let media: ChatMedia

    @State private var lookup: ChatFileLookup = .reading
    @State private var outcome: ChatPreviewOutcome?
    @State private var hint: ChatTileHint?
    @State private var onScreen = false
    @State private var slow = false
    @Environment(\.displayScale) private var scale
    @Environment(\.openURL) private var openURL

    var body: some View {
        let state = ChatPreviewPolicy.state(of: lookup, outcome: outcome)

        Button { openURL(file) } label: {
            ChatTileFrame(size: size, name: name) {
                switch state {
                case .ready(let preview?):
                    ChatTilePicture(preview: preview, family: family)
                default:
                    ChatTileIcon(type: type, state: state, slow: slow)
                }
            }
        }
        .buttonStyle(ChatTileButtonStyle())
        .disabled(state == .notAvailable)
        .accessibilityLabel(ProductStrings.commaPair(name, ChatPreviewPolicy.kindWord(family)))
        .accessibilityValue(state == .notAvailable ? ProductStrings[.chatTileNotAvailable] : "")
        .accessibilityHint(state == .opensOutside ? hint.map(Self.spoken) ?? "" : "")
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

    private var name: String {
        file.lastPathComponent
    }

    /// The file's type as the disk says once it is read, and as its name
    /// says until then.
    private var type: UTType {
        if case .found(let facts) = lookup { return facts.type }

        return ChatPreviewPolicy.type(ofPath: file.path) ?? (file.hasDirectoryPath ? .folder : .data)
    }

    private var family: ChatFileFamily {
        if case .found(let facts) = lookup { return ChatPreviewPolicy.family(of: facts) }

        return ChatPreviewPolicy.family(of: type)
    }

    /// What the file is, then where it goes outside Fermix or its preview.
    /// A preview that came to an end is not asked for again; one that failed
    /// or was let go is, and the previews decide whether it has a try left.
    private func load() async {
        if lookup == .reading {
            lookup = await media.lookUp(file)
        }
        guard case .found(let facts) = lookup else { return }

        if ChatPreviewPolicy.family(of: facts) == .other {
            hint = await media.hint(for: facts)
            return
        }
        guard ChatPreviewPolicy.drawsContent(facts), !Self.ended(outcome) else { return }

        let made = await media.previews.preview(ChatPreviewRequest(facts, size: size, scale: scale))
        guard !Task.isCancelled else { return }

        outcome = made
        if made == .unplayable {
            hint = await media.hint(for: facts)
        }
    }

    private static func ended(_ outcome: ChatPreviewOutcome?) -> Bool {
        switch outcome {
        case .made?, .iconOnly?, .unplayable?: return true
        case .failed?, .dropped?, nil: return false
        }
    }

    private static func spoken(_ hint: ChatTileHint) -> String {
        switch hint {
        case .openIn(let app): return BrowserText.openIn(app)
        case .showInFinder: return ProductStrings[.browserShowInFinder]
        }
    }
}

/// A file the row refers to by ref. Its bytes are in the engine's media
/// store, which no request on either socket returns yet, so it is Not
/// available: its icon by its type, its name, and no click.
private struct ChatRefTile: View {
    let ref: CompanionMediaRef
    let size: CGSize

    var body: some View {
        let type = UTType(mimeType: ref.mime) ?? .data
        let kind = ChatPreviewPolicy.kindWord(ChatPreviewPolicy.family(of: type))
        let name = ref.filename ?? kind

        Button {} label: {
            ChatTileFrame(size: size, name: name) {
                ChatTileIcon(type: type, state: .notAvailable, slow: false)
            }
        }
        .buttonStyle(ChatTileButtonStyle())
        .disabled(true)
        .accessibilityLabel(ProductStrings.commaPair(name, kind))
        .accessibilityValue(ProductStrings[.chatTileNotAvailable])
    }
}

/// A web address (M66 §3.3): with the preview the engine stored for it, its
/// site over its title; without one, its host over its path, read from the
/// address alone. Nothing is fetched to draw it. A click opens the address
/// as the text wrote it, where the person's preference says.
private struct ChatLinkTile: View {
    let link: ChatStripLink
    let size: CGSize

    @Environment(\.openURL) private var openURL

    var body: some View {
        Button { openURL(link.address) } label: {
            ChatTileFrame(size: size, name: nil) {
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Image(systemName: "link")
                        .fermixType(Typography.style(.callout))
                        .foregroundStyle(Palette.secondary.color)
                    Spacer(minLength: 0)
                    lines
                }
                .padding(Spacing.s)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(ChatTileButtonStyle())
        .accessibilityLabel(ProductStrings.commaPair(name, ProductStrings[.chatKindLink]))
    }

    @ViewBuilder
    private var lines: some View {
        if let preview = link.preview {
            Text(preview.site)
                .fermixType(Typography.style(.caption))
                .foregroundStyle(Palette.secondary.color)
                .lineLimit(1)
            Text(preview.title)
                .fermixType(Typography.style(.callout))
                .foregroundStyle(Palette.ink.color)
                .lineLimit(2)
        } else {
            Text(host)
                .fermixType(Typography.style(.callout))
                .foregroundStyle(Palette.ink.color)
                .lineLimit(1)
            if !path.isEmpty {
                Text(path)
                    .fermixType(Typography.style(.caption))
                    .foregroundStyle(Palette.secondary.color)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private var host: String {
        link.address.host(percentEncoded: false) ?? link.address.absoluteString
    }

    /// The address's path, where it has more of one than `/`.
    private var path: String {
        let path = link.address.path(percentEncoded: false)
        return path == "/" ? "" : path
    }

    private var name: String {
        link.preview?.title ?? host + path
    }
}

/// A tile's own shape: the chip's fill and the user chip's corners, at a size
/// it keeps from the moment it is drawn, whatever it is waiting for, so
/// nothing under it moves as previews arrive. A file's name runs along its
/// foot, cut in the middle.
private struct ChatTileFrame<Content: View>: View {
    let size: CGSize
    let name: String?
    @ViewBuilder let content: Content

    @State private var hovering = false
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let name {
                Text(name)
                    .fermixType(Typography.style(.calloutSmall))
                    .foregroundStyle(Palette.secondary.color)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, Spacing.s)
                    .padding(.vertical, Spacing.xs)
            }
        }
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

/// A tile's preview: the picture whole and uncropped inside the tile, its
/// corners following the tile's, with what is written over it: a video's play
/// mark and length, a PDF's page count, and a moving picture's mark, since it
/// never moves in the chat. The marks sit in the corners of the picture's
/// place, not of the picture: a portrait page fitted into a landscape tile is
/// too narrow to carry them.
private struct ChatTilePicture: View {
    let preview: ChatPreview
    let family: ChatFileFamily

    @Environment(\.displayScale) private var scale

    var body: some View {
        Image(decorative: preview.image, scale: scale)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: ChatMetrics.rowRadius - ChatMetrics.tileInset, style: .continuous))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay { marks }
            .padding([.top, .horizontal], ChatMetrics.tileInset)
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
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        case .animated?:
            ChatTileBadge { Image(systemName: "livephoto") }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        case nil:
            EmptyView()
        }
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

/// A tile with its icon for its picture: by its type or its place, while its
/// preview is made, where it failed, where it opens outside Fermix, or where
/// it is not there. Loading shows a quiet progress mark once it has taken
/// long enough to notice; Opens outside shows the pane's own open-in-app
/// glyph; Not available says so under a dimmed icon.
private struct ChatTileIcon: View {
    let type: UTType
    let state: ChatTileState
    let slow: Bool

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
