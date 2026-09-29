import SwiftUI

/// The transcript: every item in reading order, the newest at the bottom edge.
///
/// It keeps three promises by watching which items are on screen:
/// - A reader at the bottom stays there as rows arrive and a reply grows.
/// - Reaching the top reads the page before the oldest held row, and the
///   reader keeps their place when it lands: the newest row stays on the bottom
///   edge if it was there, and otherwise the row that was at the top stays at
///   the top.
/// - The newest row on screen, in a window that is in front, is read, and the
///   session moves the read frontier the phone shares.
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
    /// Whether the reader is on the bottom edge. The transcript opens there,
    /// and it stays true until the reader scrolls away from it.
    @State private var atBottom = true
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
                .padding(.horizontal, Spacing.l)
                .padding(.vertical, Spacing.m)
                .frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.bottom)
            .scrollIndicators(.never)
            .paneScrollEdges()
            .onScrollGeometryChange(for: Bool.self, of: ChatTranscript.isAtBottom) { _, now in
                atBottom = now
            }
            .onScrollTargetVisibilityChange(idType: ChatItemID.self, threshold: 0.01) { ids in
                visible = Set(ids)
                readOlderAtTheTop()
                markNewestSeen()
            }
            .onChange(of: items.last) {
                follow(proxy)
            }
            .onChange(of: model.rows.first?.serverSeq) {
                pageArrived(proxy)
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

    /// The newest item changed or grew. A reader on the bottom edge is kept
    /// there; one who scrolled away keeps their place.
    private func follow(_ proxy: ScrollViewProxy) {
        guard atBottom, let newest = items.last else { return }

        proxy.scrollTo(newest.id, anchor: .bottom)
    }

    /// The bottom edge, with some slack so a reader a few points short of it
    /// still counts as there.
    private static func isAtBottom(_ geometry: ScrollGeometry) -> Bool {
        geometry.visibleRect.maxY >= geometry.contentSize.height - Spacing.l
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

/// Where the reader was, as the one item a page landing must not move.
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
