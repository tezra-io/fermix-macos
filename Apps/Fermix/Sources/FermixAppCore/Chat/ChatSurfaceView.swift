import SwiftUI

/// The chat surface's own measures (redlines §8 decision 36).
enum ChatMetrics {
    /// The reading column the messages and the composer share, centred in
    /// the body however wide the window is, so the composer's edges line up
    /// with the messages' (owner, 2026-11-02): the 48 em column the chat apps
    /// people know read at (owner, 2026-11-01: 720 read narrow).
    static let columnWidth: Double = 768
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
    /// The attach button's glyph, the composer's leading control.
    static let attachGlyph: Double = 14
    /// A file's chip over the composer's field: its picture or icon, square,
    /// and the widest its name runs before it is cut in the middle.
    static let attachChipThumb: Double = 32
    static let attachChipNameWidth: Double = 160
    /// The palette over the composer: as tall as this many commands, then it
    /// scrolls.
    static let paletteVisibleRows = 6
    static let paletteRowHeight: Double = 44
    /// The composer's inset around its line and its action, which makes it the
    /// in-window control height while it is one line: the regular action plus
    /// this above and below is extra large.
    static let composerInset = EdgeInsets(
        top: (HitTarget.button - HitTarget.rowAction) / 2,
        leading: Spacing.m,
        bottom: (HitTarget.button - HitTarget.rowAction) / 2,
        trailing: (HitTarget.button - HitTarget.rowAction) / 2
    )
    /// The same with the attach button at the leading edge, which sits in
    /// from it as the action does from the trailing one.
    static let composerAttachInset = EdgeInsets(
        top: composerInset.top,
        leading: composerInset.trailing,
        bottom: composerInset.bottom,
        trailing: composerInset.trailing
    )
    /// A message's own corners, the approval card's and the call box's, and
    /// a strip's tiles'.
    static let rowRadius: Double = 16
    /// A strip's tiles (M66 §3.2): 3:2, between 120 and 200 points wide, at
    /// most three of a row whole in the column, `stripGap` apart.
    static let stripTileAspect: Double = 3.0 / 2.0
    static let stripTileWidths: ClosedRange<Double> = 120 ... 200
    static let stripMostTiles = 3
    static let stripGap: Double = Spacing.xs
    /// Between a row's words, or its voice note, and its strip, and between
    /// the strip's previews and its cards.
    static let stripTopGap: Double = Spacing.xs
    /// How far a sideways row fades out at an end with more past it.
    static let stripFadeWidth: Double = Spacing.l
    /// How far a sideways row's arrow sits in from its edge.
    static let stripArrowInset: Double = Spacing.xs
    /// A preview tile's icon, where its preview is not drawn.
    static let tileIconSize: Double = 40
    /// How strongly the band under a page's name covers the page: enough
    /// that the name keeps its contrast on any page, little enough that the
    /// page still reads through it.
    static let tileScrimStrength: Double = 0.9
    /// A compact card: one line of name over one of detail beside its icon,
    /// as tall as a sidebar row with room for both lines.
    static let cardHeight: Double = 52
    static let cardIconSize: Double = 28
    /// A sound's player (M66 §3.4): its round play button, large, the
    /// system's own 28-point control, and the glyph in it.
    static let soundButton: Double = 28
    static let soundGlyph: Double = 11
    /// A play triangle's weight sits left of its own box, so it is drawn one
    /// point right to sit in the middle of the circle to the eye.
    static let soundPlayGlyphNudge: Double = 1
    /// The waveform beside the button, as tall as its loudest bar, which is
    /// also what a click or a drag on it lands in: thin rounded bars two
    /// points wide two points apart, the quietest never under a short line,
    /// and the resting bars, before the sound's levels are read, low and even.
    static let soundWaveHeight: Double = 22
    static let soundBarWidth: Double = 2
    static let soundBarGap: Double = 2
    static let soundBarMinimum: Double = 3
    static let soundRestingLevel: Float = 0.15
    /// As wide as a sound's player grows: a sound is a line, not a column.
    static let soundMaxWidth: Double = 320
    /// How strongly a tile is drawn while the pointer holds it down.
    static let tilePressedStrength: Double = 0.7
    /// How long a tile waits on its preview before it shows the quiet
    /// progress mark: a preview made in less never shows one.
    static let tileProgressDelay: Duration = .milliseconds(300)
    /// The newest button, the system's 28-point round control, and what it
    /// keeps from the transcript's foot.
    static let newestButton: Double = 28
    static let newestButtonGap: Double = Spacing.s
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
///
/// Where the daemon serves the owner's lists, the toolbar's Lists button
/// shows the Lists panel at the body's right (M85 §09), past a divider that
/// drags it between 280 and 420 points; the column and the call box take
/// what is left.
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
    /// The chat's media: each row's strip and the previews made for its
    /// tiles. Built once by the composition, so a preview made is still there
    /// when the person comes back to Chat (M66).
    let media: ChatMedia
    /// The app's one player, which a sound in a row plays on.
    let player: AppPlayer
    /// The toolbar's commands: "Show browser" (plan §4.10), the call and
    /// the Lists panel.
    let router: any CommandPerforming
    /// The Lists panel beside the chat, observed for whether it is open and
    /// how wide, and whether the daemon serves lists at all.
    @ObservedObject var lists: ChecklistPanelModel

    /// The text being written. The session holds it as well, so leaving Chat
    /// or opening Settings mid-call, which rebuilds this view, does not lose it.
    @State private var draft: String
    @State private var query = ""
    @State private var resultsShown = false
    /// Whether a file is being dragged over the chat, which the composer
    /// shows by its border.
    @State private var dropping = false
    @State private var reveal: ChatReveal?
    /// The body's width, which the reading column and every strip in it are
    /// fitted to. It starts at the width a full column takes, the usual
    /// window's, so the first frame is fitted already.
    @State private var bodyWidth = ChatMetrics.columnWidth + 2 * ChatMetrics.columnGutter
    /// The Fermix home as this visit read it, as the surface appeared, and
    /// forgotten with the surface, so the next visit reads it again.
    @State private var visit: ChatVisit?
    /// The one place the chat shows on a reply's map, forgotten with the
    /// surface as the visit is.
    @StateObject private var places: ChatPlaceSelection
    /// The check every link in the chat opens through, and the link it holds
    /// back while the chat asks about it.
    @StateObject private var linkGuard: ChatLinkGuard
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        session: CompanionSession,
        call: VoiceCallModel,
        pet: PetFeatureModel,
        gate: VoiceCallGate,
        settings: SettingsModel,
        links: ContentLinkOpener,
        media: ChatMedia,
        player: AppPlayer,
        router: any CommandPerforming,
        lists: ChecklistPanelModel
    ) {
        self.session = session
        self.model = session.model
        self.call = call
        self.pet = pet
        self.gate = gate
        self.settings = settings
        self.links = links
        self.media = media
        self.player = player
        self.router = router
        self.lists = lists
        _draft = State(initialValue: session.draft)
        _places = StateObject(wrappedValue: ChatPlaceSelection(links: links))
        _linkGuard = StateObject(wrappedValue: ChatLinkGuard(links: links))
    }

    var body: some View {
        let items = ChatTimeline.items(of: model)

        HStack(spacing: 0) {
            conversation(items)

            if lists.isOpen, lists.served {
                ChecklistPanelEdge(panel: lists)
                ChecklistPanel(panel: lists, index: lists.library.index)
            }
        }
            // Every row reads its media, the player, the opener, the place
            // shown, the home, its strip's width and the lists from here: the
            // transcript builds its rows with nothing of their own to pass
            // them (M66 §3.2).
            .environment(\.chatRows, ChatRowContext(
                media: media,
                player: player,
                links: links,
                places: places,
                linkGuard: linkGuard,
                visit: visit,
                columnWidth: ChatMetrics.column(inBody: bodyWidth),
                lists: lists
            ))
            .navigationTitle(ProductStrings[.sidebarChat])
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
            // The session connects at launch and then stays connected, so
            // coming back to Chat asks nothing new; after a refusal it tries
            // once more.
            .task { session.connect() }
            // The Fermix home is read as the surface appears, as the browser
            // reads it at each open: on appearing rather than in a task,
            // which starts a turn later and would draw the rows once without
            // it.
            .onAppear { visit = media.surfaceEntered() }
            // A link in a reply opens where the person's preference says,
            // through the one content link opener, never through SwiftUI's own
            // hop to the default browser, and only once the chat's check has
            // passed it (`ChatLinkGuard`).
            .environment(\.openURL, OpenURLAction { url in
                linkGuard.open(url)
                return .handled
            })
            .alert(
                ProductStrings[.chatLinkHeldTitle],
                isPresented: Binding(get: { linkGuard.held != nil }, set: { if !$0 { linkGuard.dismiss() } }),
                presenting: linkGuard.held
            ) { _ in
                // Return keeps the link closed: opening it is the choice
                // made on purpose.
                Button(ProductStrings[.chatLinkOpenAnyway]) { linkGuard.openHeld() }
                Button(ProductStrings[.chatLinkCancel], role: .cancel) { linkGuard.dismiss() }
                    .keyboardShortcut(.defaultAction)
            } message: { held in
                Text(ChatLinkCautionWords.sentence(held.caution))
            }
            .toolbar {
                SurfaceToolbar(spec: CommandTable.toolbar(for: .chat, condition: toolbarCondition), router: router, follows: gate)
                ToolbarSearch(text: $query, prompt: ProductStrings[.chatSearchPrompt], submit: search)
            }
            .onChange(of: draft) {
                session.draft = draft
            }
    }

    /// Chat's toolbar asks the daemon one thing: whether it serves lists.
    private var toolbarCondition: ToolbarCondition {
        ToolbarCondition(setupComplete: ToolbarCondition.unknown.setupComplete, reconcilePending: false, listsServed: lists.served)
    }

    /// The conversation: the column, as wide as the body less the panel, with
    /// the call box at its own top right.
    private func conversation(_ items: [ChatItem]) -> some View {
        column(items)
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
                attachments: session.attachments,
                commands: model.commands,
                dropping: dropping,
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
        // A file dropped anywhere on the conversation joins the message,
        // where the engine takes files.
        .dropDestination(for: URL.self) { files, _ in
            guard session.attachments.inbox != nil, model.connection.acceptsMessages else { return false }

            session.attachments.add(files)
            return files.contains(where: \.isFileURL)
        } isTargeted: { over in
            dropping = over && session.attachments.inbox != nil
        }
    }

    /// Sends the draft and the files it carries. The first message of an
    /// empty timeline is what docks the composer, and it is the one change
    /// here that animates.
    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : draft
        let files = session.attachments.take()
        draft = ""
        withAnimation(Motion(reduceMotion: reduceMotion).animation(.stepCrossfade)) {
            session.send(text, attachments: files)
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
