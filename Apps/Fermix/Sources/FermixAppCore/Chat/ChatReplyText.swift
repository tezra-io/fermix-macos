import AppKit
import SwiftUI

/// What Fermix wrote, as one text the system's text view draws
/// (`ChatReplyDocument`), for what a reader does with it: a selection runs
/// from its first word to its last, across paragraphs, lists, tables and
/// code alike, with the system's own menu of Copy, Look Up and Translate; a
/// link names where it goes while the pointer rests on it and opens through
/// the chat's check (`ChatLinkGuard`); and each code block's Copy shows
/// while the pointer is over the block.
///
/// Compared by what it draws, so a turn still being written draws again
/// only when its words change, and then sets again only the block it is
/// writing (`ChatReplyComposer`).
struct ChatReplyText: View, Equatable {
    /// The blocks as they were parsed, nothing coloured.
    let blocks: [ReplyBlock]
    /// Words to mark, where the reader was sent here by a search.
    let marked: [String]
    let titles: ChatLinkTitles
    /// Who wrote it, which VoiceOver names it by.
    let speaker: String?

    @ScaledMetric(relativeTo: .body) private var size = ChatMetrics.readingType.size
    @Environment(\.chatRows) private var rows

    static func == (lhs: ChatReplyText, rhs: ChatReplyText) -> Bool {
        lhs.blocks == rhs.blocks && lhs.marked == rhs.marked && lhs.titles == rhs.titles && lhs.speaker == rhs.speaker
    }

    var body: some View {
        let check = rows?.linkGuard

        ChatReplyTextRepresentable(
            blocks: blocks,
            marked: marked,
            titles: titles,
            style: ChatProseStyle(size: size),
            label: ChatSpeaker.name(role: speaker)
        ) { url, caution in
            check?.open(url, caution: caution)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The system's text view in the transcript: as wide as the column gives it
/// and as tall as its lines wrap to there.
private struct ChatReplyTextRepresentable: NSViewRepresentable {
    let blocks: [ReplyBlock]
    let marked: [String]
    let titles: ChatLinkTitles
    let style: ChatProseStyle
    let label: String
    let open: (URL, LinkCaution?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(open: open)
    }

    func makeNSView(context: Context) -> ChatReplyTextView {
        let view = ChatReplyTextView()
        view.delegate = context.coordinator
        return view
    }

    func updateNSView(_ view: ChatReplyTextView, context: Context) {
        context.coordinator.open = open
        view.show(context.coordinator.composer.document(blocks, marked: marked, titles: titles, style: style))
        view.setAccessibilityLabel(label)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: ChatReplyTextView, context: Context) -> CGSize? {
        view.size(fitting: proposal.width)
    }

    /// Sets the reply's blocks, and opens a clicked link through the chat's
    /// check with the caution its words carry.
    final class Coordinator: NSObject, NSTextViewDelegate {
        var open: (URL, LinkCaution?) -> Void
        @MainActor let composer = ChatReplyComposer()

        init(open: @escaping (URL, LinkCaution?) -> Void) {
            self.open = open
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = link as? URL else { return false }

            let caution = textView.textStorage?.attribute(.chatLinkCaution, at: charIndex, effectiveRange: nil) as? LinkCaution
            open(url, caution)
            return true
        }
    }
}

/// A text view that only shows a reply: selectable, never editable, on no
/// background of its own, with no inset, laid out by TextKit 1 so its height
/// at a width is exact and its tables and code blocks are text blocks. It is
/// measured by a second layout of the same words, so SwiftUI asking its
/// size at one width never moves the lines it draws at another.
final class ChatReplyTextView: NSTextView {
    private let measuring = NSLayoutManager()
    private let measuringContainer = NSTextContainer()
    /// The last width it was measured at, and its size there.
    private var measured: (width: CGFloat, size: CGSize)?
    /// The pieces it shows, so a document that changed only in its last
    /// block replaces only that block's words.
    private var shown: [NSAttributedString] = []
    /// Each code block's Copy, in reading order.
    private var copies: [ChatCodeCopy] = []
    private var hoverArea: NSTrackingArea?

    init() {
        let storage = NSTextStorage()
        let layout = ChatReplyLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        measuringContainer.lineFragmentPadding = 0
        measuring.addTextContainer(measuringContainer)
        storage.addLayoutManager(measuring)
        super.init(frame: .zero, textContainer: container)

        isEditable = false
        isSelectable = true
        isRichText = true
        drawsBackground = false
        textContainerInset = .zero
        isVerticallyResizable = false
        isHorizontallyResizable = false
        displaysLinkToolTips = false
        linkTextAttributes = [.cursor: NSCursor.pointingHand]
        isAutomaticLinkDetectionEnabled = false
        isAutomaticDataDetectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        usesFontPanel = false
        allowsUndo = false
        writingToolsBehavior = .none
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        preconditionFailure("the text view is made in code")
    }

    /// The reply to show. Only the pieces from the first one that changed
    /// are set again, the line feed after the last one left out.
    func show(_ document: ChatReplyDocument) {
        guard let storage = textStorage else { return }

        let same = zip(shown, document.pieces).prefix { $0 === $1 }.count
        guard same < max(shown.count, document.pieces.count) else { return }

        // The replacement starts at the line feed that ended the last piece
        // kept, which the text left out while that piece was the last.
        let kept = shown.prefix(same).reduce(0) { $0 + $1.length }
        let start = same == 0 ? 0 : kept - 1
        let replacement = NSMutableAttributedString()
        if same > 0 {
            let last = document.pieces[same - 1]
            replacement.append(last.attributedSubstring(from: NSRange(location: last.length - 1, length: 1)))
        }
        document.pieces[same...].forEach(replacement.append)
        if replacement.length > 0, replacement.string.hasSuffix("\n") {
            replacement.deleteCharacters(in: NSRange(location: replacement.length - 1, length: 1))
        }

        storage.replaceCharacters(in: NSRange(location: start, length: storage.length - start), with: replacement)
        shown = document.pieces
        measured = nil
        place(document.codes)
        needsLayout = true
    }

    /// Its size at a width: the width it is given, or its widest line where
    /// it is given none, and the height its lines wrap to.
    func size(fitting width: CGFloat?) -> CGSize {
        let bound = width.map { $0.isFinite ? max(0, $0) : .greatestFiniteMagnitude } ?? .greatestFiniteMagnitude
        if let measured, measured.width == bound { return measured.size }

        let used = laidOut(at: bound)
        let size = CGSize(width: bound == .greatestFiniteMagnitude ? ceil(used.width) : bound, height: ceil(used.height))
        measured = (bound, size)
        return size
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    /// The words' extent at a width, a block's padding under its last line
    /// included.
    private func laidOut(at width: CGFloat) -> CGRect {
        measuringContainer.size = NSSize(width: width, height: .greatestFiniteMagnitude)
        measuring.ensureLayout(for: measuringContainer)
        return measuring.usedRect(for: measuringContainer)
    }

    // MARK: - Code blocks' Copy

    /// One Copy for each code block, made or reused in reading order.
    private func place(_ codes: [ChatReplyDocument.Code]) {
        while copies.count > codes.count {
            copies.removeLast().host.removeFromSuperview()
        }
        for (index, code) in codes.enumerated() {
            if index < copies.count {
                copies[index].block = code.block
                copies[index].state.text = code.text
            } else {
                let copy = ChatCodeCopy(block: code.block, text: code.text)
                addSubview(copy.host)
                copies.append(copy)
            }
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard let layout = layoutManager, let container = textContainer, !copies.isEmpty else { return }

        layout.ensureLayout(for: container)
        let side = ChatMetrics.actionSize
        for copy in copies {
            guard let frame = blockFrame(copy.block, in: layout) else {
                copy.host.isHidden = true
                continue
            }
            let inset = ChatMetrics.codeCopyInset
            let header = copy.block.width(for: .padding, edge: .minY)
            copy.host.isHidden = false
            copy.host.frame = NSRect(x: frame.maxX - inset - side, y: frame.minY + (header - side) / 2, width: side, height: side)
        }
    }

    /// Where a code block's fill is drawn, in this view, as a layout
    /// manager laid it out.
    private func blockFrame(_ block: NSTextBlock, in layout: NSLayoutManager) -> NSRect? {
        guard let storage = textStorage, let range = range(of: block, in: storage) else { return nil }

        let glyph = layout.glyphIndexForCharacter(at: range.location)
        let bounds = layout.boundsRect(for: block, at: glyph, effectiveRange: nil)
        guard !bounds.isEmpty else { return nil }

        return ChatCodeTextBlock.filled(bounds, block: block)
    }

    /// The characters a text block holds.
    private func range(of block: NSTextBlock, in storage: NSTextStorage) -> NSRange? {
        var found: NSRange?
        storage.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
            guard let style = value as? NSParagraphStyle, style.textBlocks.contains(where: { $0 === block }) else { return }

            found = range
            stop.pointee = true
        }
        return found
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        hover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        hover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hover(at: nil)
    }

    /// Shows the Copy of the code block under the pointer, and hides every
    /// other.
    private func hover(at point: NSPoint?) {
        guard let layout = layoutManager else { return }

        for copy in copies {
            let over = point.flatMap { point in blockFrame(copy.block, in: layout).map { $0.contains(point) } } ?? false
            if copy.state.shown != over { copy.state.shown = over }
        }
    }

    // MARK: - Copying

    /// Writes the selection as the system does, with its plain text read as
    /// a person would paste it: a table's cells a tab apart, a task's box as
    /// markdown writes it, and no caution marks.
    override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        guard super.writeSelection(to: pboard, types: types) else { return false }
        guard types.contains(where: Self.plainTypes.contains), let storage = textStorage else { return true }

        let plain = selectedRanges.map { ChatReplyPlainText.text(of: storage, in: $0.rangeValue) }.joined(separator: "\n")
        pboard.setString(plain, forType: .string)
        return true
    }

    /// Plain text by either of its names: the text system still writes the
    /// legacy one.
    private static let plainTypes: Set<NSPasteboard.PasteboardType> = [.string, NSPasteboard.PasteboardType("NSStringPboardType")]
}

/// A reply's text as plain text: each stretch marked with what it is copied
/// as (`chatPlain`) is that, and every other stretch its own characters.
enum ChatReplyPlainText {
    static func text(of text: NSAttributedString, in range: NSRange) -> String {
        var plain = ""
        text.enumerateAttribute(.chatPlain, in: range) { value, run, _ in
            plain += (value as? String) ?? (text.string as NSString).substring(with: run)
        }
        return plain
    }
}

/// Draws inline code's fill as a rounded box a little wider than its words
/// and as tall as its face, rather than the line's whole height.
final class ChatReplyLayoutManager: NSLayoutManager {
    override func fillBackgroundRectArray(_ rectArray: UnsafePointer<NSRect>, count rectCount: Int, forCharacterRange charRange: NSRange, color: NSColor) {
        guard let storage = textStorage, let container = textContainers.first, charRange.location < storage.length,
              storage.attribute(.chatCodeSpan, at: charRange.location, effectiveRange: nil) != nil,
              let fill = storage.attribute(.backgroundColor, at: charRange.location, effectiveRange: nil) as? NSColor, fill == color,
              let font = storage.attribute(.font, at: charRange.location, effectiveRange: nil) as? NSFont
        else {
            super.fillBackgroundRectArray(rectArray, count: rectCount, forCharacterRange: charRange, color: color)
            return
        }

        color.setFill()
        let outset = 2.0
        for rect in UnsafeBufferPointer(start: rectArray, count: rectCount) {
            let glyph = glyphIndex(for: NSPoint(x: rect.midX, y: rect.midY), in: container)
            let line = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let baseline = line.minY + location(forGlyphAt: glyph).y
            let box = NSRect(
                x: rect.minX - outset,
                y: baseline - font.ascender - outset,
                width: rect.width + 2 * outset,
                height: font.ascender - font.descender + 2 * outset
            )
            NSBezierPath(roundedRect: box, xRadius: Radius.iconTileSmall / 1.5, yRadius: Radius.iconTileSmall / 1.5).fill()
        }
    }
}

/// A code block's Copy over its corner: the message's own Copy
/// (`ChatCopyAction`), shown while the pointer is over the block.
@MainActor
private final class ChatCodeCopy {
    var block: ChatCodeTextBlock
    let state: ChatCodeCopyState
    let host: NSHostingView<ChatCodeCopyButton>

    init(block: ChatCodeTextBlock, text: String) {
        self.block = block
        state = ChatCodeCopyState(text: text)
        host = NSHostingView(rootView: ChatCodeCopyButton(state: state))
        // The text view places it; it never sizes itself.
        host.sizingOptions = []
    }
}

@MainActor
@Observable
final class ChatCodeCopyState {
    var text: String
    var shown = false

    init(text: String) {
        self.text = text
    }
}

struct ChatCodeCopyButton: View {
    let state: ChatCodeCopyState

    var body: some View {
        ChatCopyAction(text: state.text, shown: state.shown, label: .chatCodeCopy)
    }
}
