import SwiftUI

/// The chat surface's own measures (redlines §8 decision 36).
enum ChatMetrics {
    /// The reading column the transcript and the composer share, centred in
    /// the body however wide the window is.
    static let columnWidth: Double = 720
    /// The room the column keeps from the body's edges, the transcript's and
    /// the composer's alike, when the body is narrower than the column.
    static let columnGutter: Double = Spacing.l
    /// The call box: the pet's stage, with the box's own padding round it.
    static let callBoxWidth: Double = PetMetrics.stageSize.width + 2 * Spacing.s
    /// What the call box keeps from the body's top and trailing edges.
    static let callBoxInset: Double = Spacing.m
    /// The room a message the owner wrote leaves on its leading side, so the
    /// two sides of the conversation read as two sides.
    static let userRowLeadingRoom: Double = Spacing.xxl * 2
    /// The transcript's base rhythm: the gap inside one turn (a user's row and
    /// the reply that follows it), and the default gap between every other
    /// pair of adjacent rows.
    static let rowGap: Double = Spacing.m
    /// The gap between one turn and the next, added at the seam on top of
    /// `rowGap`'s base rhythm, so turns read apart from each other the way
    /// they do not read apart internally (owner: the transcript sits too
    /// close next to ChatGPT's, 2026-09-28).
    static let turnGap: Double = Spacing.xl
    /// The user chip's own padding: a shape, not bare text, so it wants more
    /// room than a reply's leading text needs (2026-09-28).
    static let userChipPadding = EdgeInsets(top: Spacing.s, leading: Spacing.m, bottom: Spacing.s, trailing: Spacing.m)
    /// The gap between the last row and the docked composer (2026-09-28).
    static let composerTopGap: Double = Spacing.s
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
    /// A message's own corners, the approval card's and the call box's, and
    /// a strip's tiles'.
    static let rowRadius: Double = 16
    /// A strip's tiles (M66 §3.2): 3:2, between 120 and 200 points wide, at
    /// most three to a row, `stripGap` apart.
    static let stripTileAspect: Double = 3.0 / 2.0
    static let stripTileWidths: ClosedRange<Double> = 120 ... 200
    static let stripMostTiles = 3
    static let stripGap: Double = Spacing.xs
    /// The room **+N** is counted at before it is drawn: the row capsule
    /// holding "+99", so the fit never has to measure the button.
    static let stripMoreWidth: Double = 56
    /// Between a row's words, or its voice note, and its strip.
    static let stripTopGap: Double = Spacing.xs
    /// How far a tile's picture sits in from the tile's edges. Its own
    /// corners are the tile's less this, so the two curves run parallel.
    static let tileInset: Double = Spacing.xs
    /// A tile's icon, where the icon is its picture.
    static let tileIconSize: Double = 40
    /// How strongly a tile is drawn while the pointer holds it down.
    static let tilePressedStrength: Double = 0.7
    /// How long a tile waits on its preview before it shows the quiet
    /// progress mark: a preview made in less never shows one.
    static let tileProgressDelay: Duration = .milliseconds(300)
    /// How long typing in the search field pauses before the daemon is asked,
    /// so a word being typed is one search rather than one per letter.
    static let searchPause: Duration = .milliseconds(300)

    /// The reading column inside a body this wide: the column's own width,
    /// or the body less its gutters where the body is narrower.
    static func column(inBody width: Double) -> Double {
        min(columnWidth, max(0, width - 2 * columnGutter))
    }
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
///
/// The call begins and ends from the toolbar's call button, at the
/// conversation's top right, and while it is up the pet floats at the body's
/// top right (`ChatCallBox`): nothing in the column moves for it, in either
/// state (M56; the owner's direction of 2026-10-03).
struct ChatSurfaceView: View {
    let session: CompanionSession
    @ObservedObject var model: CompanionModel
    /// The one call's facts. Held and not observed: the call box observes
    /// them, so a caption redraws the box and never this view or the
    /// transcript.
    let call: VoiceCallModel
    /// The call's façade, which the box's pet draws from: the same one the Pet
    /// page and the floating pet draw.
    let pet: PetFeatureModel
    /// The gate the toolbar's call button clicks through. Held and not
    /// observed: the button observes it where it stands in the toolbar, and
    /// the gate says only when its answer moves, so neither this view nor the
    /// button redraws for a caption.
    let gate: VoiceCallGate
    /// Read for the greeting's name, through the one settings model.
    let settings: SettingsModel
    /// Where a link in a reply opens.
    let links: ContentLinkOpener
    /// The chat's media: the Fermix home, each row's strip and the previews
    /// made for its tiles. Built once by the composition, so a preview made
    /// is still there when the person comes back to Chat (M66).
    let media: ChatMedia
    /// The toolbar's commands: "Show browser" (plan §4.10) and the call.
    let router: any CommandPerforming

    /// The text being written. The session holds it as well, so leaving Chat
    /// or opening Settings mid-call, which rebuilds this view, does not lose it.
    @State private var draft: String
    @State private var query = ""
    @State private var resultsShown = false
    @State private var reveal: ChatReveal?
    /// The body's width, which the reading column and every strip in it are
    /// fitted to. It starts at the width a full column takes, the usual
    /// window's, so the first frame is fitted already.
    @State private var bodyWidth = ChatMetrics.columnWidth + 2 * ChatMetrics.columnGutter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        session: CompanionSession,
        call: VoiceCallModel,
        pet: PetFeatureModel,
        gate: VoiceCallGate,
        settings: SettingsModel,
        links: ContentLinkOpener,
        media: ChatMedia,
        router: any CommandPerforming
    ) {
        self.session = session
        self.model = session.model
        self.call = call
        self.pet = pet
        self.gate = gate
        self.settings = settings
        self.links = links
        self.media = media
        self.router = router
        _draft = State(initialValue: session.draft)
    }

    var body: some View {
        let items = ChatTimeline.items(of: model)

        column(items)
            // Every row reads its media, its strip's width and whether its
            // strip is open from here: the transcript builds its rows with
            // nothing of their own to pass them (M66 §3.2).
            .environment(\.chatStrips, ChatStripContext(
                media: media,
                columnWidth: ChatMetrics.column(inBody: bodyWidth),
                openStrips: model.openStrips,
                toggle: { session.toggleStrip($0) }
            ))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onGeometryChange(for: Double.self) { proxy in
                proxy.size.width
            } action: { width in
                bodyWidth = width
            }
            // The call floats at the body's top right, in the margin beside
            // the centred column; only a body too narrow for that margin puts
            // it over the transcript's trailing edge (`ChatCallBox.overlapsColumn`).
            .overlay(alignment: .topTrailing) {
                ChatCallBox(call: call, pet: pet)
                    .padding(.top, ChatMetrics.callBoxInset)
                    .padding(.trailing, ChatMetrics.callBoxInset)
            }
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
            // The next visit reads the Fermix home again, as the browser
            // reads it at each open.
            .onDisappear { media.surfaceLeft() }
            // A link in a reply opens where the person's preference says,
            // through the one content link opener, never through SwiftUI's own
            // hop to the default browser.
            .environment(\.openURL, OpenURLAction { url in
                links.open(url)
                return .handled
            })
            .toolbar {
                SurfaceToolbar(spec: CommandTable.toolbar(for: .chat), router: router, follows: gate)
            }
            .onChange(of: draft) {
                session.draft = draft
            }
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
            .padding(.horizontal, ChatMetrics.columnGutter)
            .padding(.top, docked ? ChatMetrics.composerTopGap : 0)
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
