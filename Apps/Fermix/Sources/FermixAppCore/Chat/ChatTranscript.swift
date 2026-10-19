import SwiftUI

/// The transcript: every item in reading order, the newest at the bottom edge.
///
/// It keeps three promises by watching which items are on screen:
/// - A reader at the bottom stays there as rows arrive and a reply grows.
/// - Reaching the top reads the page before the oldest held row, and the
///   reader keeps their place when it lands: the newest row stays on the bottom
///   edge if it was there, and otherwise the row that was at the top stays at
///   the top.
/// - A held row changing height in place, read again with more in it, leaves
///   the reader where they were by the same rule.
/// - The newest row on screen, in a window that is in front, is read, and the
///   session moves the read frontier the phone shares.
/// - The session is told which held rows are on screen whenever that set
///   changes, so a row that may have changed while chat was disconnected is
///   read again as it comes into view (M66 §3.6).
///
/// A search hit is revealed the way scrolling up reads: page by page until its
/// row is held, then scrolled to the middle with its matches marked.
struct ChatTranscript: View {
    let session: CompanionSession
    @ObservedObject var model: CompanionModel
    let items: [ChatItem]
    /// The hit the reader chose, whose row is marked while the search stands.
    let reveal: ChatReveal?

    /// The items on screen, as the scroll view last reported them.
    @State private var visible: Set<ChatItemID> = []
    /// The held rows on screen, as the session was last told them.
    @State private var rowsOnScreen = ChatRowsOnScreen()
    /// Whether the reader is on the bottom edge. The transcript opens there,
    /// and it stays true until the reader scrolls away from it.
    @State private var atBottom = true
    /// Whether the reader is moving the transcript themselves, by trackpad,
    /// wheel or scroller, so nothing pulls it back under them meanwhile.
    @State private var readerScrolling = false
    /// Where the reader was when older rows were asked for.
    @State private var place: ChatPlace?
    /// A chosen hit whose row is not on screen yet.
    @State private var revealing: ChatReveal?
    @Environment(\.appearsActive) private var appearsActive

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: ChatMetrics.rowGap) {
                    if model.hasOlder {
                        ChatOlderMarker().id(ChatItemID.older)
                    }

                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        let previous = index > 0 ? items[index - 1] : nil
                        let opensNewTurn = ChatTimeline.opensNewTurn(after: previous, before: item)

                        ChatItemView(item: item, marked: marked(item), answer: session.answerApproval)
                            .padding(.top, opensNewTurn ? ChatMetrics.turnGap - ChatMetrics.rowGap : 0)
                            .id(item.id)
                    }
                }
                .scrollTargetLayout()
                .frame(maxWidth: ChatMetrics.columnWidth)
                .padding(.horizontal, ChatMetrics.columnGutter)
                .padding(.vertical, Spacing.m)
                .frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.bottom)
            .scrollIndicators(.never)
            .paneScrollEdges()
            .onScrollPhaseChange { _, phase in
                readerScrolling = ChatFollow.isReadersOwn(phase)
            }
            .onScrollGeometryChange(for: ChatViewport.self, of: ChatViewport.init) { before, now in
                // The layout moved under a reader on the bottom edge: a reply
                // grew or took the place of its thinking line, the composer
                // grew a line, or the column narrowed beside the browser pane
                // and the rows rewrapped. They stay there.
                if ChatFollow.keepsBottom(readerAtBottom: atBottom, readerScrolling: readerScrolling, before: before, now: now),
                   let newest = items.last {
                    proxy.scrollTo(newest.id, anchor: .bottom)
                    return
                }

                atBottom = now.atBottom
            }
            .onScrollTargetVisibilityChange(idType: ChatItemID.self, threshold: 0.01) { ids in
                visible = Set(ids)
                reportRowsOnScreen()
                readOlderAtTheTop()
                markNewestSeen()
            }
            .onDisappear {
                visible = []
                reportRowsOnScreen()
            }
            .onChange(of: items.last) {
                follow(proxy)
            }
            .onChange(of: model.rows.first?.serverSeq) {
                pageArrived(proxy)
            }
            .onChange(of: model.reshape) {
                reshaped(proxy)
            }
            .onChange(of: reveal) {
                revealing = reveal
                advanceReveal(proxy)
            }
            .onChange(of: appearsActive) {
                markNewestSeen()
            }
        }
    }

    /// The terms to mark in an item: the chosen hit's, on its own row.
    private func marked(_ item: ChatItem) -> [String] {
        guard let reveal, item.id == .row(reveal.serverSeq) else { return [] }

        return reveal.terms
    }

    /// The newest item changed or grew. Sending it carries the reader to the
    /// bottom edge regardless of where they were reading, and once there the
    /// turn it starts keeps following as it grows; otherwise a reader already
    /// on the bottom edge is kept there, and one who scrolled away keeps their
    /// place.
    private func follow(_ proxy: ScrollViewProxy) {
        guard let newest = items.last else { return }

        let sent = newest.isPending
        if sent { atBottom = true }
        guard ChatFollow.follows(atBottom: atBottom, sent: sent) else { return }

        proxy.scrollTo(newest.id, anchor: .bottom)
    }

    /// Tells the session the held rows on screen, only when they changed.
    private func reportRowsOnScreen() {
        guard let seqs = rowsOnScreen.update(visible) else { return }

        session.rowsOnScreen(seqs)
    }

    private func readOlderAtTheTop() {
        guard model.hasOlder, visible.contains(.older), revealing == nil else { return }

        place = ChatPlace(atBottom: atBottom, visible: visible, items: items)
        session.pullOlder()
    }

    /// A page landed below the rows held: put the reader back, or carry on
    /// towards a chosen hit.
    private func pageArrived(_ proxy: ScrollViewProxy) {
        guard revealing == nil else {
            advanceReveal(proxy)
            return
        }
        guard let place else { return }

        self.place = nil
        hold(place, proxy)
    }

    /// Held rows changed height in place (M66 §3.8). The items on screen are
    /// still the ones read before the change, which is not laid out yet, so
    /// the reader's place is taken from them and held across it. A reveal
    /// under way scrolls to its hit instead.
    private func reshaped(_ proxy: ScrollViewProxy) {
        guard revealing == nil, let place = ChatPlace(atBottom: atBottom, visible: visible, items: items) else { return }

        hold(place, proxy)
    }

    private func hold(_ place: ChatPlace, _ proxy: ScrollViewProxy) {
        switch place {
        case .newest(let id): proxy.scrollTo(id, anchor: .bottom)
        case .top(let id): proxy.scrollTo(id, anchor: .top)
        }
    }

    private func advanceReveal(_ proxy: ScrollViewProxy) {
        guard let target = revealing else { return }

        switch target.step(rows: model.rows, hasOlder: model.hasOlder) {
        case .scroll(let id):
            revealing = nil
            atBottom = false
            proxy.scrollTo(id, anchor: .center)
        case .readOlder:
            session.pullOlder()
        case .unreachable:
            revealing = nil
        }
    }

    private func markNewestSeen() {
        guard appearsActive, model.cursor > 0, visible.contains(.row(model.cursor)) else { return }

        session.newestRowSeen()
    }
}

/// Whether the newest item's arrival carries the reader to the bottom edge.
enum ChatFollow {
    /// True once they sent it themselves: sending means they want to see it
    /// and the reply that follows, wherever they were reading. Otherwise true
    /// only when they were on the bottom edge already, so a row arriving
    /// while they read up the transcript does not move them.
    static func follows(atBottom: Bool, sent: Bool) -> Bool {
        sent || atBottom
    }

    /// Whether a reader is put back on the bottom edge after the transcript
    /// changed under them. A scroll view keeps its top where it was, so when
    /// its content grows taller (a reply streams in, or replaces its thinking
    /// line) or the transcript grows shorter (the composer takes a line) or
    /// narrower (the browser pane opens and its rows rewrap), the newest rows
    /// slide out of view below.
    ///
    /// A row's arrival is followed when it lands, but a row is drawn after
    /// that, often taller than the scroll to it assumed, and a reply keeps
    /// growing after it, so only the change it makes to the content, read
    /// once it is laid out, keeps the reader there.
    ///
    /// Only a reader who was on the bottom edge, and never while they are
    /// scrolling themselves, when the rows coming into view are measured and
    /// change the content's height under their hand. A search hit the
    /// transcript scrolls to takes the reader off the bottom edge itself.
    ///
    /// Where the reader was is the transcript's own record of it rather than
    /// the reading before this one: the browser pane opens over a run of
    /// sizes, and after the first of them the previous reading is already off
    /// the bottom edge.
    static func keepsBottom(readerAtBottom: Bool, readerScrolling: Bool, before: ChatViewport, now: ChatViewport) -> Bool {
        readerAtBottom && !readerScrolling
            && (now.size != before.size || now.contentHeight != before.contentHeight)
    }

    /// Whether the transcript is moving because the reader is moving it, by
    /// trackpad, wheel or scroller, rather than by a scroll of its own.
    static func isReadersOwn(_ phase: ScrollPhase) -> Bool {
        phase == .tracking || phase == .interacting || phase == .decelerating
    }
}

/// The transcript's size, its content's height and whether its reader is on
/// the bottom edge, read together off one scroll geometry, so a change in one
/// is never judged against a stale reading of another.
struct ChatViewport: Equatable {
    let size: CGSize
    let contentHeight: Double
    let atBottom: Bool

    init(size: CGSize, contentHeight: Double, atBottom: Bool) {
        self.size = size
        self.contentHeight = contentHeight
        self.atBottom = atBottom
    }

    /// The bottom edge carries some slack, so a reader a few points short of
    /// it still counts as there.
    init(_ geometry: ScrollGeometry) {
        size = geometry.containerSize
        contentHeight = geometry.contentSize.height
        atBottom = geometry.visibleRect.maxY >= geometry.contentSize.height - Spacing.l
    }
}

/// The held rows on screen, as the transcript last reported them to the
/// session. Scrolling changes which items are visible far more often than it
/// changes which rows are, so only a change of the rows is a report.
struct ChatRowsOnScreen: Equatable {
    private(set) var seqs: Set<Int> = []

    /// The rows to report for the items now on screen, or nil when they are
    /// the rows reported last.
    mutating func update(_ visible: Set<ChatItemID>) -> Set<Int>? {
        let rows = Set(visible.compactMap { id -> Int? in
            guard case .row(let seq) = id else { return nil }

            return seq
        })
        guard rows != seqs else { return nil }

        seqs = rows
        return rows
    }
}

/// Where the reader was, as the one item a page landing, or a held row
/// changing height, must not move. An item's id is its row's seq, so a row
/// history brings again is the same item before and after.
enum ChatPlace: Equatable {
    /// The reader was on the bottom edge: the newest item stays there.
    case newest(ChatItemID)
    /// They were not: the first item on screen stays at the top.
    case top(ChatItemID)

    init?(atBottom: Bool, visible: Set<ChatItemID>, items: [ChatItem]) {
        if atBottom, let newest = items.last?.id {
            self = .newest(newest)
        } else if let first = items.first(where: { visible.contains($0.id) }) {
            self = .top(first.id)
        } else {
            return nil
        }
    }
}

/// The top of the held rows while older ones exist. Reaching it reads them,
/// so it draws what is happening there.
private struct ChatOlderMarker: View {
    var body: some View {
        ActivityMark()
            .frame(maxWidth: .infinity)
            .padding(.vertical, Spacing.xs)
    }
}
