import SwiftUI

/// The chat surface's own measures (redlines §8 decision 36).
enum ChatMetrics {
    /// The reading column the transcript and the composer share, centred in
    /// the body however wide the window is.
    static let columnWidth: Double = 720
    /// The room a message the owner wrote leaves on its leading side, so the
    /// two sides of the conversation read as two sides.
    static let userRowLeadingRoom: Double = Spacing.xxl * 2
    /// How strongly a message the daemon has not accepted yet is drawn.
    static let sendingStrength: Double = 0.6
    /// The composer grows to this many lines and then scrolls inside itself.
    static let composerLines = 1...6
    /// The composer's inset around its line and its action, which makes it the
    /// in-window control height while it is one line: the regular action plus
    /// this above and below is extra large.
    static let composerInset = EdgeInsets(
        top: (HitTarget.button - HitTarget.rowAction) / 2,
        leading: Spacing.m,
        bottom: (HitTarget.button - HitTarget.rowAction) / 2,
        trailing: (HitTarget.button - HitTarget.rowAction) / 2
    )
    /// A message's own corners, and the approval card's.
    static let rowRadius: Double = 16
    /// How long typing in the search field pauses before the daemon is asked,
    /// so a word being typed is one search rather than one per letter.
    static let searchPause: Duration = .milliseconds(300)
}

/// Chat: the one conversation with Fermix (redlines §8 decision 36).
///
/// There is no session list and no new chat: the rail's first row opens the
/// companion timeline the phone shares. Everything drawn is the chat model's,
/// which the session writes; this view asks the session for everything it
/// wants done and derives nothing the daemon publishes.
///
/// Two states. With nothing in the timeline the composer stands in the middle
/// of the column under the mark and a greeting. With anything in it the
/// transcript takes the column and the composer sits on the bottom edge, and
/// it never goes back to the middle while the timeline has rows: rows only
/// ever arrive. The move between the two is one animation, the app's step
/// crossfade, and only the owner's own first message makes it: a transcript
/// read from the daemon simply appears.
///
/// Search is the daemon's, in the toolbar where Logs has its own, asked once
/// typing pauses or on Return. Its hits replace the transcript until one is
/// chosen; the transcript stays underneath so the reader's place survives a
/// search, and clearing the field returns to it.
struct ChatSurfaceView: View {
    let session: CompanionSession
    @ObservedObject var model: CompanionModel
    /// Read for the greeting's name, through the one settings model.
    let settings: SettingsModel
    /// Where a link in a reply opens.
    let links: ContentLinkOpener

    @State private var draft = ""
    @State private var query = ""
    @State private var resultsShown = false
    @State private var reveal: ChatReveal?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(session: CompanionSession, settings: SettingsModel, links: ContentLinkOpener) {
        self.session = session
        self.model = session.model
        self.settings = settings
        self.links = links
    }

    var body: some View {
        let items = ChatTimeline.items(of: model)

        column(items)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(ProductStrings[.sidebarChat])
            .searchable(text: $query, placement: .toolbar, prompt: ProductStrings[.chatSearchPrompt])
            .onSubmit(of: .search) { search() }
            .onChange(of: query) {
                guard query.isEmpty else { return }

                clearSearch()
            }
            .task(id: query) {
                guard !query.isEmpty else { return }

                try? await Task.sleep(for: ChatMetrics.searchPause)
                guard !Task.isCancelled else { return }

                search()
            }
            // The session connects the first time a surface asks and then stays
            // connected, so coming back to Chat asks nothing new.
            .task { session.connect() }
            // A link in a reply opens where the person's preference says,
            // through the one content link opener, never through SwiftUI's own
            // hop to the default browser.
            .environment(\.openURL, OpenURLAction { url in
                links.open(url)
                return .handled
            })
    }

    /// The transcript and the composer under it, or the composer alone in the
    /// middle. The composer is the same view in both, so it keeps its text and
    /// its focus as it moves.
    @ViewBuilder
    private func column(_ items: [ChatItem]) -> some View {
        let results = resultsShown ? model.search : nil
        let docked = !items.isEmpty || results != nil

        VStack(spacing: 0) {
            if docked {
                ZStack {
                    ChatTranscript(session: session, model: model, items: items, reveal: reveal)
                        .opacity(results == nil ? 1 : 0)
                        .allowsHitTesting(results == nil)
                        .accessibilityHidden(results != nil)

                    if let results {
                        ChatSearchResults(search: results, older: session.searchOlder, choose: choose)
                    }
                }
            } else {
                Spacer(minLength: 0)
                ChatGreetingView(settings: settings)
                    .padding(.bottom, Spacing.l)
            }

            ChatComposer(
                draft: $draft,
                connection: model.connection,
                turn: model.turn,
                send: send,
                cancel: session.cancel(clientMsgId:)
            )
            .frame(maxWidth: ChatMetrics.columnWidth)
            .padding(.horizontal, Spacing.l)
            .padding(.top, docked ? Spacing.xs : 0)
            .padding(.bottom, docked ? Spacing.m : 0)

            if !docked {
                Spacer(minLength: 0)
            }
        }
    }

    /// Sends the draft. The first message of an empty timeline is what docks
    /// the composer, and it is the one change here that animates.
    private func send() {
        let text = draft
        draft = ""
        withAnimation(Motion(reduceMotion: reduceMotion).animation(.stepCrossfade)) {
            session.send(text)
        }
    }

    /// Shows the hits for the query in the field, asking the daemon only for
    /// a query it has not answered: Return after choosing a hit brings the
    /// same hits back.
    private func search() {
        reveal = nil
        resultsShown = true
        guard model.search?.query != query else { return }

        session.search(query)
    }

    private func clearSearch() {
        reveal = nil
        resultsShown = false
        session.clearSearch()
    }

    /// A hit was chosen: back to the transcript, at that row.
    private func choose(_ hit: CompanionSearchHit) {
        resultsShown = false
        reveal = ChatReveal(hit)
    }
}
