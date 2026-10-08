import Combine
import Foundation
import Testing

@testable import FermixAppCore

/// The call in the chat window (M56, in the owner's direction of 2026-10-03):
/// the call button at the toolbar's top right, and the pet floating at the
/// body's top right while a call is up.
///
/// Which state the box draws is `ChatCallBoxState`, proven here on
/// `PetHarness`'s fakes with no window; what only a view can show (its place
/// over the column, what it leaves out) is read off the source, as the
/// container rules are.
@Suite("Chat call box")
@MainActor
struct ChatCallBoxTests {
    private func state(_ harness: PetHarness) -> ChatCallBoxState? {
        ChatCallBoxState(voice: harness.call.voice, closed: harness.call.callBoxClosed)
    }

    /// A call `call_start` has gone out for, on a negotiated socket.
    private func liveCall() throws -> PetHarness {
        let harness = try PetHarness()
        harness.call.voiceNegotiated()
        harness.call.beginTestCall()
        return harness
    }

    private func deliver(_ harness: PetHarness, _ events: RealtimeServerEvent...) {
        for event in events {
            _ = harness.call.apply(event, audioIsPlaying: false)
        }
    }

    private static func text(of path: String) throws -> String {
        try #require(try SourceTree.swiftFiles(matching: path).first?.text)
    }

    // MARK: - When the box shows

    @Test("no call, no box")
    func idleDrawsNothing() throws {
        #expect(state(try PetHarness()) == nil)
    }

    /// From the click: the mascot stands in its idle pose while the daemon
    /// has not answered.
    @Test("the box shows from the click, with the mascot at rest")
    func startingShowsTheBox() throws {
        let harness = try PetHarness()
        harness.call.voiceNegotiated()
        harness.call.callStarting()

        #expect(state(harness) == .live)
        #expect(harness.model.expression == .idle)
    }

    @Test("the box stays through the call and while it is ending")
    func liveThroughTheCall() throws {
        let harness = try liveCall()
        deliver(harness, .state(.listening))
        #expect(state(harness) == .live)

        deliver(harness, .state(.speaking))
        #expect(state(harness) == .live)

        harness.call.callStopping()
        #expect(state(harness) == .live)
    }

    /// The owner's direction of 2026-10-04: after a call the pet stays in its
    /// idle pose "so that there will be a stop button which I can click to
    /// close". A call that ends without a control's click (the daemon's own
    /// last frame) keeps the box with the pet and its dock, whose one control
    /// is now Close, and says nothing: the bill a normal end settles is the
    /// Pet page's.
    @Test("a normal end keeps the box, with the idle pet, the dock's Close and no sentence")
    func normalEndKeepsTheBox() throws {
        let harness = try liveCall()
        deliver(harness, .state(.listening))
        harness.call.callStopping()
        deliver(harness, .usage(RealtimeUsage(voiceCostCents: 2.05, accounting: "complete")), .state(.idle))

        #expect(state(harness) == .ended)
        #expect(harness.model.expression == .idle)
        #expect(harness.model.stopAction(in: .callBox) == .close)
        #expect(harness.model.stopActionTitle(.close) == "Close")
        #expect(harness.model.settledBillText != nil)
    }

    /// The owner's direction of 2026-10-08: "the stop should basically close
    /// the mascot". One press ends the call through the gate and closes the
    /// box at once, while the call behind it is still ending; the call's
    /// facts stay for the Pet page, and the next call brings the box back.
    @Test("the dock's stop ends the call and closes the box in one press")
    func stopEndsAndCloses() throws {
        let harness = try liveCall()
        deliver(harness, .state(.listening))
        #expect(harness.model.stopAction(in: .callBox) == .end)
        #expect(harness.model.stopActionTitle(.end) == "End voice call")

        harness.model.stopClicked(in: .callBox)
        #expect(harness.call.voice.phase == .stopping)
        #expect(state(harness) == nil)

        deliver(harness, .usage(RealtimeUsage(voiceCostCents: 2.05, accounting: "complete")), .state(.idle))
        #expect(harness.call.voice.phase == .ended(.normal(settled: harness.call.voice.usage)))
        #expect(state(harness) == nil)
        #expect(harness.model.settledBillText != nil, "the cost stays on the Pet page")

        harness.model.mascotClicked()
        #expect(harness.call.voice.phase == .starting)
        #expect(state(harness) == .live)
    }

    /// The toolbar's call button and the menus end the call as the stop does:
    /// only the mascot's own click leaves the pet resting in the box.
    @Test("a call control's end closes the box too")
    func callControlEndCloses() throws {
        let harness = try liveCall()
        deliver(harness, .state(.listening))

        harness.gate.toggleCall()
        #expect(harness.call.voice.phase == .stopping)
        #expect(state(harness) == nil)
    }

    /// The mascot's click ends the call and keeps the box; while that call is
    /// still ending, the stop is already Close, never a dimmed control.
    @Test("the stop closes the box the mascot's click left, while the call ends and after")
    func closeAfterTheMascotsEnd() throws {
        let harness = try liveCall()
        deliver(harness, .state(.listening))

        harness.model.mascotClicked()
        #expect(harness.call.voice.phase == .stopping)
        #expect(state(harness) == .live)
        #expect(harness.model.stopAction(in: .callBox) == .close)

        harness.model.stopClicked(in: .callBox)
        #expect(harness.call.voice.phase == .stopping, "Close leaves the ending call alone")
        #expect(state(harness) == nil)

        harness.call.callEnded()
        #expect(state(harness) == nil)
    }

    @Test("a failure keeps the box with its one sentence, the vendor's detail after it, and Close")
    func failureKeepsTheBox() throws {
        let harness = try liveCall()
        deliver(
            harness,
            .state(.listening),
            .error(RealtimeServerError(
                reason: "cost_limit",
                kind: .costLimit,
                detail: "The voice session reached its spending limit."
            ))
        )

        #expect(state(harness) == .failed("The call reached its cost limit. The voice session reached its spending limit."))
        #expect(harness.model.stopAction(in: .callBox) == .close)
    }

    /// A version refusal or a socket that never opened is a start that failed
    /// before there was a call, and the box says so too.
    @Test("a failure before the call existed shows in the box")
    func failureBeforeTheCall() throws {
        let harness = try PetHarness()
        harness.call.callStarting()
        harness.call.voiceFailed(.versionUnsupported(direction: .clientTooOld, minimum: 2, maximum: 2))

        #expect(state(harness) == .failed(ProductStrings[.voiceStatusUpdateRequired]))
    }

    @Test("Close puts a failure away, and the next call replaces it")
    func closeAndTheNextCall() throws {
        let harness = try liveCall()
        deliver(harness, .error(RealtimeServerError(reason: "provider_disconnected", kind: .providerDisconnected)))
        #expect(state(harness) == .failed(ProductStrings[.voiceErrorProviderDisconnected]))

        harness.call.callStarting()
        #expect(state(harness) == .live)

        harness.call.voiceFailed(.socketPathUnavailable)
        harness.model.stopClicked(in: .callBox)
        #expect(state(harness) == nil)
        #expect(harness.call.voice.status.carriesItsOwnSentence, "the failure stays the Pet page's to say")
    }

    // MARK: - The mascot

    @Test("the intro plays for a live call and never for a failed one")
    func introOnlyForALiveCall() {
        #expect(ChatCallBox.playsIntro(live: true, introPlayed: false, reduceMotion: false))
        #expect(!ChatCallBox.playsIntro(live: true, introPlayed: true, reduceMotion: false))
        #expect(!ChatCallBox.playsIntro(live: true, introPlayed: false, reduceMotion: true))
        #expect(!ChatCallBox.playsIntro(live: false, introPlayed: false, reduceMotion: false))
    }

    @Test("the mascot moves only during a call, in a window on screen, without Reduce Motion")
    func animatesFollowsVisibilityAndReduceMotion() {
        #expect(ChatCallBox.animates(live: true, windowVisible: true, reduceMotion: false))
        #expect(!ChatCallBox.animates(live: true, windowVisible: false, reduceMotion: false))
        #expect(!ChatCallBox.animates(live: true, windowVisible: true, reduceMotion: true))
        #expect(!ChatCallBox.animates(live: false, windowVisible: true, reduceMotion: false))
    }

    /// The owner's direction of 2026-10-04: the box's pet behaves as the
    /// floating window's does, where "a tap on it goes to listening mode or
    /// idle mode". Its click is the call control's, through the gate, and its
    /// tooltip the control's: it ends the call that is up, the pet going to
    /// its idle pose in the box that stays, and a click on that idle pet
    /// begins the next call with the same pet, which does not hatch again
    /// (owner, 2026-10-08: "if its idle theres no point in rehatching").
    @Test("a click on the box's pet ends the call, and on the idle pet begins the next")
    func mascotClickTogglesTheCall() throws {
        let harness = try liveCall()
        deliver(harness, .state(.listening))
        let first = harness.call.voice.attempt
        harness.call.introShown()
        #expect(harness.model.expression == .listening)
        #expect(harness.model.callHelpText == "End voice call")

        harness.model.mascotClicked()
        #expect(harness.call.voice.phase == .stopping)
        harness.call.callEnded()
        #expect(state(harness) == .ended)
        #expect(harness.model.expression == .idle)
        #expect(harness.model.callHelpText == "Begin voice call")

        harness.model.mascotClicked()
        #expect(harness.call.voice.phase == .starting)
        #expect(state(harness) == .live)
        #expect(harness.call.voice.attempt == first + 1)
        #expect(harness.call.introPlayed, "the resting pet hatched again for the next call")

        // The click is the companion's, one view in both hosts, and the box
        // acts on the call through nothing of its own.
        let box = try Self.text(of: "Chat/ChatCallBox.swift")
        #expect(box.contains("host: .callBox"))
        #expect(!box.contains(".id(call.voice.attempt)"), "each call builds a new mascot again")
        #expect(!box.contains("toggleCall"), "the box acts on the call itself")
        #expect(!box.contains("onTapGesture"), "the box takes the mascot's click itself")
    }

    // MARK: - One pet, two hosts

    /// The box is the pet the floating window draws: one view, hosted twice.
    /// The window keeps its drag; the box has none.
    @Test("the box and the floating window host the one pet view")
    func onePetTwoHosts() throws {
        let files = try SourceTree.swiftFiles(under: "", excluding: false)
        let owners = files.filter { $0.text.contains("struct PetCompanion: View") }
        #expect(owners.count == 1)
        #expect(owners.first?.path.hasSuffix("Pet/PetView.swift") == true)

        let window = try Self.text(of: "Pet/PetView.swift")
        let box = try Self.text(of: "Chat/ChatCallBox.swift")
        #expect(window.contains("PetCompanion("))
        #expect(box.contains("PetCompanion("))
        #expect(window.contains(".simultaneousGesture(WindowDragGesture())"))
        #expect(!box.contains("WindowDragGesture"))
        #expect(!box.contains(".mascot("), "the box asks the renderer itself instead of hosting the pet")
    }

    /// The mascot's animation is the status: what the call says in words is
    /// the Pet page's, and only a failure's sentence is the box's.
    @Test("the box carries no status word, caption, task or cost")
    func boxCarriesNoLines() throws {
        let box = try Self.text(of: "Chat/ChatCallBox.swift")

        for line in ["statusText", "captionLine", "taskStatusText", "voiceCostText", "settledBillText", "cancelTask"] {
            #expect(!box.contains(line), "the box draws \(line)")
        }
        // Its one control is the dock's: the stop, which is Close once the
        // call is over.
        #expect(!box.contains("Button("), "the box draws a button of its own beside the dock's")
        #expect(box.contains("dock: .shown"))

        let page = try Self.text(of: "Pet/PetSurfaceView.swift")
        for line in ["model.captionLine", "model.taskStatusText", "model.voiceCostText", "model.settledBillText"] {
            #expect(page.contains(line), "the Pet page lost \(line)")
        }
    }

    // MARK: - The box over the column

    /// The owner's rule: the box stands at the body's extreme right, in the
    /// margin beside the centred column, and reaches over the transcript only
    /// where that margin cannot hold it.
    @Test("the box stands clear of the column where the margin holds it, and overlaps where it cannot")
    func placement() {
        let box = ChatMetrics.callBoxWidth
        let inset = ChatMetrics.callBoxInset
        let column = ChatMetrics.columnWidth
        #expect(box == 156)
        #expect(inset == 16)

        // A wide window: a 1440 point window's body leaves a 334 point margin.
        #expect(!ChatCallBox.overlapsColumn(box: box, body: 1_388, column: column, inset: inset))
        // The margin exactly holds the box and its inset.
        #expect(!ChatCallBox.overlapsColumn(box: box, body: column + 2 * (box + inset), column: column, inset: inset))
        // A point less, and the box reaches over the column's edge.
        #expect(ChatCallBox.overlapsColumn(box: box, body: column + 2 * (box + inset) - 2, column: column, inset: inset))
        // The default window's 988 point body leaves 134.
        #expect(ChatCallBox.overlapsColumn(box: box, body: 988, column: column, inset: inset))
        // Beside the browser pane the body is 480 and the column 432: 24 left.
        #expect(ChatCallBox.overlapsColumn(box: box, body: 480, column: column, inset: inset))
    }

    @Test("the box floats at the body's top right, never a sheet, a popover or room taken from the column")
    func boxIsAnOverlay() throws {
        let surface = try Self.text(of: "Chat/ChatSurfaceView.swift")
        #expect(surface.contains(".overlay(alignment: .topTrailing) {\n                ChatCallBox(call: call, pet: pet)"))
        #expect(surface.contains(".padding(.top, ChatMetrics.callBoxInset)"))
        #expect(surface.contains(".padding(.trailing, ChatMetrics.callBoxInset)"))
        // On the body, not the column: nothing narrows it to the column's width.
        #expect(!surface.contains(".frame(maxWidth: ChatMetrics.columnWidth, alignment: .trailing)"))
        for presentation in [".sheet(", ".popover(", ".safeAreaInset(", ".fullScreenCover("] {
            #expect(!surface.contains(presentation), "the chat surface presents with \(presentation)")
        }
        // Nothing in the column moves for a call: the empty state docks for
        // rows and search alone.
        #expect(surface.contains("let docked = !items.isEmpty || results != nil\n"))

        let box = try Self.text(of: "Chat/ChatCallBox.swift")
        for presentation in [".sheet(", ".popover(", "PrimaryAction(", ".keyboardShortcut("] {
            #expect(!box.contains(presentation), "the box carries \(presentation)")
        }
    }

    /// A caption arrives tens of times a turn: the box observes the call, the
    /// toolbar's call button the gate, and the chat surface neither.
    @Test("the box observes the call, and the chat surface observes no part of it")
    func onlyTheBoxObservesTheCall() throws {
        let surface = try Self.text(of: "Chat/ChatSurfaceView.swift")
        #expect(surface.contains("let call: VoiceCallModel"))
        #expect(surface.contains("let pet: PetFeatureModel"))
        #expect(surface.contains("let gate: VoiceCallGate"))
        #expect(!surface.contains("@ObservedObject var call"))
        #expect(!surface.contains("@ObservedObject var pet"))
        #expect(!surface.contains("@ObservedObject var gate"))

        let box = try Self.text(of: "Chat/ChatCallBox.swift")
        #expect(box.contains("@ObservedObject var call: VoiceCallModel"))
    }

    /// The composer is the chat's own again: the call control is the toolbar's.
    @Test("the composer carries no call control")
    func composerHasNoCallControl() throws {
        let composer = try Self.text(of: "Chat/ChatComposer.swift")

        #expect(!composer.contains("toggleCall"))
        #expect(!composer.contains("PetFeatureModel"))
        #expect(composer.contains(".disabled(connection != .connected)"))
    }

    // MARK: - The toolbar's call button

    @Test("Chat's toolbar carries the call beside Show browser, as a phone filled while a call is up")
    func toolbarCarriesTheCall() {
        #expect(CommandTable.toolbar(for: .chat).secondary == [.showBrowser, .toggleVoiceCall])
        #expect(CommandTable.symbol(of: .toggleVoiceCall) == "phone")
        #expect(CommandTable.symbol(of: .toggleVoiceCall) == CommandTable.callSymbol)
        #expect(CommandTable.fillsWhenOn(.toggleVoiceCall))
        #expect(!CommandTable.fillsWhenOn(.pauseLogs))
        #expect(CommandTable.toolbarTitle(of: .toggleVoiceCall, isOn: false) == "Begin voice call")
        #expect(CommandTable.toolbarTitle(of: .toggleVoiceCall, isOn: true) == "End voice call")
    }

    /// The window's toolbar is AppKit's, bridged from SwiftUI, and it keeps a
    /// control as it first drew it: the chat redrawing left the call button
    /// dimmed under "Checking voice" once voice was ready, and filled after
    /// the call ended. So the button observes the gate where it stands.
    @Test("the toolbar's call button follows the gate where it stands")
    func toolbarFollowsTheGate() throws {
        let surface = try Self.text(of: "Chat/ChatSurfaceView.swift")
        #expect(surface.contains("SurfaceToolbar(spec: CommandTable.toolbar(for: .chat), router: router, follows: gate)"))

        let toolbar = try Self.text(of: "Design/Components/SurfaceToolbar.swift")
        #expect(toolbar.contains("Following(followed: follows) { button(command) }"))
        #expect(toolbar.contains("@ObservedObject var followed: Followed"))
    }

    /// The gate announces only a change of its answer, so the call button that
    /// follows it never redraws for a caption.
    @Test("the gate announces a change only when its answer moves")
    func gateAnnouncesItsAnswerOnly() throws {
        let harness = try PetHarness()
        harness.call.voiceNegotiated()
        let gate = VoiceCallGate(call: harness.call, voice: harness.voice, readiness: harness.readiness, setUpVoice: {})
        var changes = 0
        let subscription = gate.objectWillChange.sink { _ in changes += 1 }
        defer { subscription.cancel() }

        harness.call.beginTestCall()
        #expect(gate.action == .end)
        #expect(changes == 1)

        deliver(harness, .state(.listening), .caption(RealtimeCaption(speaker: .user, delta: "hello", startMs: 0, endMs: 1)))
        harness.readiness.voiceReadiness = .degraded
        #expect(changes == 1)

        deliver(harness, .error(RealtimeServerError(reason: "provider_disconnected", kind: .providerDisconnected)))
        #expect(gate.action == .unavailable)
        #expect(changes == 2)

        harness.readiness.voiceReadiness = .setupRequired
        #expect(gate.action == .setUp)
        #expect(changes == 3)
    }
}
