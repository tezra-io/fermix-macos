import Combine
import Foundation
import Testing

@testable import FermixAppCore

/// The call in the chat window (M56, in the owner's direction of 2026-10-03):
/// the call button at the toolbar's top right, and the pet floating over the
/// column while a call is up.
///
/// Which state the box draws is `ChatCallBoxState`, proven here on
/// `PetHarness`'s fakes with no window; what only a view can show (its place
/// over the column, what it leaves out) is read off the source, as the
/// container rules are.
@Suite("Chat call box")
@MainActor
struct ChatCallBoxTests {
    private func state(_ harness: PetHarness) -> ChatCallBoxState? {
        ChatCallBoxState(voice: harness.call.voice)
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

    /// The bill a normal end settles stays on the Pet page; the box simply
    /// goes with the call.
    @Test("a normal end removes the box, and the bill stays on the Pet page")
    func normalEndRemovesTheBox() throws {
        let harness = try liveCall()
        deliver(harness, .state(.listening))
        harness.call.callStopping()
        deliver(harness, .usage(RealtimeUsage(voiceCostCents: 2.05, accounting: "complete")), .state(.idle))

        #expect(state(harness) == nil)
        #expect(harness.model.settledBillText != nil)
    }

    @Test("a failure keeps the box with its one sentence, the vendor's detail after it")
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

    @Test("Dismiss puts a failure away, and the next call replaces it")
    func dismissAndTheNextCall() throws {
        let harness = try liveCall()
        deliver(harness, .error(RealtimeServerError(reason: "provider_disconnected", kind: .providerDisconnected)))
        #expect(state(harness) == .failed(ProductStrings[.voiceErrorProviderDisconnected]))

        harness.call.callStarting()
        #expect(state(harness) == .live)

        harness.call.voiceFailed(.socketPathUnavailable)
        harness.call.dismissEnded()
        #expect(state(harness) == nil)
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

    @Test("a click on the mascot ends the call, and only ends it")
    func mascotClickEnds() throws {
        let harness = try PetHarness()
        harness.call.voiceNegotiated()
        harness.call.callStarting()

        ChatCallBox.endCall(through: harness.model)
        #expect(harness.call.voice.phase == .idle)

        // Nothing is up: a click on the mascot begins nothing.
        ChatCallBox.endCall(through: harness.model)
        #expect(harness.call.voice.phase == .idle)

        let box = try Self.text(of: "Chat/ChatCallBox.swift")
        #expect(box.contains("mascotClick: { Self.endCall(through: pet) }"))
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
        #expect(box.contains("ProductStrings[.voiceDismiss]"))

        let page = try Self.text(of: "Pet/PetSurfaceView.swift")
        for line in ["model.captionLine", "model.taskStatusText", "model.voiceCostText", "model.settledBillText"] {
            #expect(page.contains(line), "the Pet page lost \(line)")
        }
    }

    // MARK: - The box over the column

    @Test("the box floats over the column, never a sheet, a popover or room taken from the column")
    func boxIsAnOverlay() throws {
        let surface = try Self.text(of: "Chat/ChatSurfaceView.swift")
        #expect(surface.contains(".overlay(alignment: .top) {\n                ChatCallBox(call: call, pet: pet)"))
        #expect(surface.contains(".frame(maxWidth: ChatMetrics.columnWidth, alignment: .trailing)"))
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

    /// A caption arrives tens of times a turn: the box observes the call, and
    /// the chat surface observes only the gate, which says when its answer
    /// moves.
    @Test("the box observes the call, and the chat surface only the gate")
    func onlyTheBoxObservesTheCall() throws {
        let surface = try Self.text(of: "Chat/ChatSurfaceView.swift")
        #expect(surface.contains("let call: VoiceCallModel"))
        #expect(surface.contains("let pet: PetFeatureModel"))
        #expect(surface.contains("@ObservedObject var gate: VoiceCallGate"))
        #expect(!surface.contains("@ObservedObject var call"))
        #expect(!surface.contains("@ObservedObject var pet"))

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
        #expect(CommandTable.fillsWhenOn(.toggleVoiceCall))
        #expect(!CommandTable.fillsWhenOn(.pauseLogs))
        #expect(CommandTable.toolbarTitle(of: .toggleVoiceCall, isOn: false) == "Begin voice call")
        #expect(CommandTable.toolbarTitle(of: .toggleVoiceCall, isOn: true) == "End voice call")
    }

    /// The gate announces only a change of its answer, so the chat surface
    /// that observes it for its toolbar never redraws for a caption.
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
