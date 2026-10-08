import AppKit
import Foundation
import Testing

@testable import FermixAppCore

/// The Pet surface: a sidebar destination that configures and previews the
/// feature, plus the optional floating window. The audio and socket stack is
/// the proven one; what changed is that nothing about it runs until the user
/// starts a call.
@Suite("Pet surface")
@MainActor
struct PetSurfaceTests {
    private func harness() throws -> PetHarness {
        try PetHarness()
    }

    /// The floating window stays hidden until it is opened or enabled: a launch
    /// must not put a companion on screen nobody asked for.
    @Test("the floating window is hidden until it is opened")
    func hiddenUntilOpened() throws {
        let harness = try harness()

        #expect(!harness.windows.isPresented(.pet))
        #expect(!harness.model.floatingWindowShown)
    }

    @Test("the surface opens and closes the floating window through the coordinator")
    func togglesTheFloatingWindow() throws {
        let harness = try harness()

        harness.model.setFloatingWindow(true)
        #expect(harness.windows.isPresented(.pet))
        #expect(harness.model.floatingWindowShown)

        harness.model.setFloatingWindow(false)
        #expect(!harness.windows.isPresented(.pet))
        #expect(!harness.model.floatingWindowShown)
    }

    /// Microphone consent belongs to the first voice start, not to opening a
    /// screen. Rendering the surface must ask macOS for nothing.
    @Test("opening the Pet surface asks for no microphone permission")
    func noPermissionOnOpen() throws {
        let harness = try harness()

        harness.model.setFloatingWindow(true)
        _ = harness.model.presentation
        _ = harness.model.callActionTitle

        #expect(harness.engine.permissionRequests == 0)
    }

    /// A click while the daemon has not answered calls the start off, so the
    /// control says so: it was "Begin" through the whole handshake, and a
    /// second click began again.
    @Test("the call control ends a start the daemon has not answered")
    func controlEndsAPendingStart() throws {
        let harness = try harness()

        harness.model.toggleCall()
        #expect(harness.model.callActionTitle == ProductStrings[.petCallEnd])

        harness.model.toggleCall()
        #expect(harness.model.callActionTitle == ProductStrings[.petCallBegin])
        #expect(harness.call.voice.phase == .idle)
    }

    /// Voice that is not set up turns the call control into the way to set it
    /// up: one click opens Settings, Voice, and no call starts.
    @Test("with voice not set up the call control sets it up")
    func controlSetsUpVoice() throws {
        let harness = try harness()
        harness.readiness.voiceReadiness = .setupRequired

        #expect(harness.model.callActionTitle == "Set up voice")
        #expect(harness.model.callHelpText == "Set up voice")
        #expect(harness.model.callActionEnabled)

        harness.model.toggleCall()

        #expect(harness.voiceSetUps.count == 1)
        #expect(harness.call.voice.phase == .idle)
        #expect(harness.engine.permissionRequests == 0)
    }

    /// Degraded or unread voice offers nothing to click: the control is dimmed
    /// under its usual title, and the help says why in the app's own words.
    @Test(
        "with voice degraded or unread the call control does nothing and says why",
        arguments: [VoiceReadiness.degraded, .unknown]
    )
    func controlExplainsUnavailableVoice(readiness: VoiceReadiness) throws {
        let harness = try harness()
        harness.readiness.voiceReadiness = readiness

        #expect(harness.model.callActionTitle == ProductStrings[.petCallBegin])
        #expect(!harness.model.callActionEnabled)
        #expect(harness.model.callHelpText == readiness.sentence)
        #expect(
            harness.model.callHelpText
                == (readiness == .degraded ? "Voice is not available right now" : "Checking voice")
        )

        harness.model.toggleCall()

        #expect(harness.voiceSetUps.count == 0)
        #expect(harness.call.voice.phase == .idle)
    }

    /// A call that is up is always the control's to end, whatever the last
    /// overview said.
    @Test("a call that is up ends whatever readiness says")
    func controlEndsWhateverReadinessSays() throws {
        let harness = try harness()
        harness.call.beginTestCall()
        harness.readiness.voiceReadiness = .degraded

        #expect(harness.model.callActionTitle == ProductStrings[.petCallEnd])
        #expect(harness.model.callActionEnabled)
        #expect(harness.model.callHelpText == ProductStrings[.petCallEnd])
    }

    /// The Pet page redraws when readiness moves, as it does for the call.
    @Test("a readiness change redraws the pet")
    func readinessChangeRedraws() throws {
        let harness = try harness()
        var redraws = 0
        let subscription = harness.model.objectWillChange.sink { _ in redraws += 1 }
        defer { subscription.cancel() }

        harness.readiness.voiceReadiness = .degraded

        #expect(redraws == 1)
    }

    @Test("starting a call is the first and only thing that asks for the microphone")
    func permissionAtFirstCall() async throws {
        let harness = try harness()

        // Pressing the button records the intent and drives the handshake;
        // nothing reaches the microphone before the daemon has answered.
        harness.model.toggleCall()
        #expect(harness.engine.permissionRequests == 0)

        harness.negotiate()
        await harness.settle()

        #expect(harness.engine.permissionRequests == 1)
    }

    /// Animation costs frames, and an occluded, minimized, or off-Space window
    /// costs none.
    @Test("a hidden window pauses the animation timeline")
    func hiddenWindowPausesAnimation() throws {
        let harness = try harness()

        harness.model.setWindowVisible(false)
        #expect(!harness.model.windowVisible)

        harness.model.setWindowVisible(true)
        #expect(harness.model.windowVisible)
    }

    @Test("the surface names the voice state in words, not only in the mascot")
    func stateIsReadable() throws {
        let harness = try harness()

        #expect(!harness.model.accessibilityValue.isEmpty)
        #expect(harness.model.statusText == ProductStrings[.voiceStatusOffline])
    }

    /// A Mac with no microphone is the case this pins.
    ///
    /// `VoiceStatus(mode:)` answers `.offline` for `.error`, so a surface that
    /// rebuilds its words from the mode tells the owner "Not connected" — a
    /// healthy disconnection — while the engine is refusing for a reason it has
    /// already put into a sentence. On 2026-09-12 that is exactly what a Mac
    /// mini, which ships no microphone at all, reported: the pet went to the
    /// error tint and said nothing that named the cause.
    @Test("a capture failure reaches the surface in its own words")
    func captureFailureIsReadable() async throws {
        let harness = try harness()
        harness.engine.permissionError = CaptureError.noInputDevice

        harness.model.toggleCall()
        harness.negotiate()
        await harness.settle()

        #expect(harness.model.statusText == ProductStrings[.voiceErrorNoInputDevice])
        #expect(harness.model.accessibilityValue == ProductStrings[.voiceErrorNoInputDevice])
        #expect(harness.model.statusText != ProductStrings[.voiceStatusOffline])
    }

    /// The floating window draws the mascot and the controls and has room for
    /// no sentence, so the tooltip is where a failure becomes readable without
    /// opening the app. It says the action while there is an action to take.
    @Test("the floating pet offers the failure as its tooltip")
    func floatingPetTooltipCarriesTheFailure() async throws {
        let harness = try harness()

        #expect(harness.model.callHelpText == harness.model.callActionTitle)

        harness.engine.permissionError = CaptureError.noInputDevice
        harness.model.toggleCall()
        harness.negotiate()
        await harness.settle()

        #expect(harness.model.callHelpText == ProductStrings[.voiceErrorNoInputDevice])
    }

    // MARK: - The mascot's click

    /// The mascot's click is the call control's, through the gate, wherever
    /// the pet is drawn (owner, 2026-09-25: "the click on the mascot leads to
    /// enabling or disabling it"; 2026-10-04: the chat's box does the same as
    /// the floating window). With no call up it begins one; through a start
    /// or a call it ends it, and the pet goes to its idle pose, resting in the
    /// chat's box rather than closing it (owner, 2026-10-08: "Only clicking
    /// on the pet goes to idle").
    @Test("a click on the pet's mascot begins a call while none is up and ends the one that is, in both hosts")
    func mascotClickTogglesTheCall() throws {
        let harness = try harness()
        harness.call.voiceNegotiated()
        #expect(harness.model.callHelpText == "Begin voice call")

        harness.model.mascotClicked()
        #expect(harness.call.voice.phase == .starting)
        #expect(harness.model.callHelpText == "End voice call")

        // A start the daemon has not answered is called off like a call.
        harness.model.mascotClicked()
        #expect(harness.call.voice.phase == .idle)

        harness.model.mascotClicked()
        harness.call.callStarted()
        _ = harness.call.apply(.state(.listening), audioIsPlaying: false)
        #expect(harness.model.expression == .listening)

        harness.model.mascotClicked()
        #expect(harness.call.voice.phase == .stopping)
        harness.call.callEnded()
        #expect(harness.model.expression == .idle)
        #expect(!harness.call.callBoxClosed)

        // One companion draws the pet in both hosts, and its whole frame is
        // the mascot's click and the call control's tooltip: the click is the
        // same in both, so no host has a rule of its own.
        let pet = try #require(try SourceTree.swiftFiles(matching: "Pet/PetView.swift").first?.text)
        #expect(pet.contains(".onTapGesture { model.mascotClicked() }"))
        #expect(pet.contains(".help(model.callHelpText)"))
        let model = try #require(try SourceTree.swiftFiles(matching: "Pet/PetFeatureModel.swift").first?.text)
        #expect(model.contains("public func mascotClicked() {"), "a host's click has a rule of its own again")
    }

    /// Outside a call the mascot's click is the call control's, whatever the
    /// gate makes of it: Settings, Voice where voice is not set up, nothing
    /// where it is degraded, and the next call after a failure.
    @Test("outside a call the pet's mascot clicks through the gate")
    func mascotClicksThroughTheGate() async throws {
        let setUp = try harness()
        setUp.readiness.voiceReadiness = .setupRequired
        #expect(setUp.model.callHelpText == "Set up voice")
        setUp.model.toggleCall()
        #expect(setUp.voiceSetUps.count == 1)
        #expect(setUp.call.voice.phase == .idle)

        let degraded = try harness()
        degraded.readiness.voiceReadiness = .degraded
        #expect(degraded.model.callHelpText == "Voice is not available right now")
        degraded.model.toggleCall()
        #expect(degraded.call.voice.phase == .idle)

        let failed = try harness()
        failed.engine.permissionError = CaptureError.noInputDevice
        failed.model.toggleCall()
        failed.negotiate()
        await failed.settle()
        #expect(failed.model.callHelpText == ProductStrings[.voiceErrorNoInputDevice])

        failed.model.toggleCall()
        #expect(failed.call.voice.phase == .starting)
    }

    // MARK: - The dock

    /// The dock's call control is a stop (owner, 2026-10-04: "I prefer it was
    /// a stop button"): one control, the filled square in ink, in both hosts.
    /// It ends a start or a call. Once the call is ending or over it is the
    /// chat box's Close; the floating window has nothing to close, so there
    /// it is dimmed while the call ends and offers nothing after. It never
    /// begins a call.
    @Test("the dock's one control is the stop: it ends a call in both hosts, and closes only the chat's box")
    func dockControlIsTheStop() throws {
        let harness = try harness()
        let model = harness.model

        func offers(_ box: PetStopAction?, _ window: PetStopAction?, _ phase: String) {
            #expect(model.stopAction(in: .callBox) == box, "\(phase)")
            #expect(model.stopAction(in: .floatingWindow) == window, "\(phase)")
        }

        #expect(PetDockSymbol.stop == PetDockSymbol(name: "stop", filled: true, tint: Palette.ink))
        offers(nil, nil, "idle")

        harness.call.voiceNegotiated()
        harness.call.callStarting()
        offers(.end, .end, "starting")

        harness.call.callStarted()
        _ = harness.call.apply(.state(.speaking), audioIsPlaying: false)
        offers(.end, .end, "active")

        harness.call.callStopping()
        offers(.close, .ending, "stopping")

        harness.call.callEnded()
        offers(.close, nil, "ended")

        harness.call.beginTestCall()
        harness.call.voiceFailed(.socketPathUnavailable)
        offers(.close, nil, "failed")

        #expect(model.stopActionTitle(.end) == ProductStrings[.petCallEnd])
        #expect(model.stopActionTitle(.ending) == ProductStrings[.petCallEnd])
        #expect(model.stopActionTitle(.close) == "Close")
        for action in [PetStopAction.end, .ending, .close] {
            let title = model.stopActionTitle(action)
            #expect(ProductCopyRules.violations(in: title).isEmpty, "\(title)")
            #expect(!title.localizedCaseInsensitiveContains("stop"), "\(title) says Stop, the service's word")
        }

        let dock = try #require(try SourceTree.swiftFiles(matching: "Pet/PetView.swift").first?.text)
        #expect(!dock.contains("Palette.accent"), "the dock draws the accent again")
        #expect(!dock.contains("callSymbol"), "the dock draws the toolbar's phone again")
        #expect(dock.contains("PetControlButton(symbol: .stop"))
        #expect(dock.contains(".disabled(action == .ending)"))
    }

    /// The stop never begins a call: a click on it with nothing to end or
    /// close changes nothing, on either host.
    @Test("a click on the stop with nothing to end or close does nothing")
    func stopNeverBegins() throws {
        let harness = try harness()
        harness.call.voiceNegotiated()

        harness.model.stopClicked(in: .floatingWindow)
        harness.model.stopClicked(in: .callBox)
        #expect(harness.call.voice.phase == .idle)

        harness.call.beginTestCall()
        harness.model.stopClicked(in: .floatingWindow)
        #expect(harness.call.voice.phase == .stopping)

        // The floating window has nothing to close once the call is over.
        harness.call.callEnded()
        harness.model.stopClicked(in: .floatingWindow)
        #expect(harness.call.voice.phase == .ended(.normal(settled: nil)))
    }

    /// The floating window's dock comes with a call: at rest its one control
    /// has nothing to do, so the pointer reveals no empty dock, and the
    /// hidden dock keeps the stop's room so a call that begins moves nothing.
    @Test("the floating window's dock rests hidden and keeps the stop's room")
    func floatingDockRestsHidden() throws {
        let text = try #require(try SourceTree.swiftFiles(matching: "Pet/PetView.swift").first?.text)

        #expect(text.contains("guard model.stopAction(in: .floatingWindow) != nil else { return false }"))
        #expect(text.contains(".hidden()"))
    }

    /// Mute keeps its drawing, and interrupt is the silenced speaker: never
    /// the stop's square, so the two cannot be confused.
    @Test("mute keeps its slashed microphone and its warning tint, and interrupt is the silenced speaker")
    func dockMuteAndInterruptSymbols() throws {
        let harness = try harness()
        harness.call.beginTestCall()

        #expect(PetDockSymbol.mute(harness.model) == PetDockSymbol(name: "mic.slash", filled: false, tint: Palette.ink))

        harness.call.voiceMuted(true)
        #expect(PetDockSymbol.mute(harness.model) == PetDockSymbol(name: "mic.slash", filled: true, tint: Palette.warning))

        #expect(PetDockSymbol.interrupt == PetDockSymbol(name: "speaker.slash", filled: false, tint: Palette.ink))
        #expect(!PetDockSymbol.interrupt.name.hasPrefix("stop"))
        #expect(harness.model.interruptActionTitle == "Interrupt reply")
    }

    /// The speaking tail is the one place the visual mode outlives the daemon's
    /// state, and it must keep its word: the status the daemon last reported is
    /// not what the pet is doing while audio is still leaving the speaker.
    @Test("the speaking tail still reads as speaking")
    func speakingTailKeepsItsWord() throws {
        let harness = try harness()

        harness.call.beginTestCall()
        harness.call.apply(.audioDelta(base64: RelayedAudio.voice(1)), audioIsPlaying: false)
        harness.call.apply(.state(.listening), audioIsPlaying: true)

        #expect(harness.model.visualMode == .speaking)
        #expect(harness.model.statusText == ProductStrings[.voiceStatusSpeaking])
    }

    /// M34 §6: the pet surface is restyled off the deleted card and titlebar
    /// primitives, onto a grouped `Form` the system draws.
    @Test("the pet surface is a grouped form and draws no container of its own")
    func petSurfaceIsAGroupedForm() throws {
        let view = try SourceTree.swiftFiles(matching: "Pet/PetSurfaceView.swift")
        let text = try #require(view.first?.text)

        #expect(text.contains(".formStyle(.grouped)"))
        #expect(!text.contains("Card {"), "the pet surface still draws a card")
        #expect(!text.contains("SurfaceTitlebar("), "the pet surface still draws a titlebar")
        #expect(text.contains(".navigationTitle("), "the pet surface has no window title")
    }

    /// The preview and the call controls survive the restyle: M34 §6 keeps
    /// both, and only the box around them is gone.
    @Test("the preview and the call controls survive the restyle")
    func previewAndControlsSurvive() throws {
        let view = try SourceTree.swiftFiles(matching: "Pet/PetSurfaceView.swift")
        let text = try #require(view.first?.text)

        #expect(text.contains("PetMark()"))
        #expect(text.contains("PrimaryAction("))
    }

    /// The floating companion is dragged from anywhere on it, not only from the
    /// few points of padding the mascot's own click leaves unclaimed, and the
    /// first press drags even while another app is active. Both are one line
    /// each and both are easy to lose in a restyle, so they are asserted.
    @Test("the floating companion states its window drag and takes it from an inactive app")
    func companionIsDraggedFromAnywhere() throws {
        let view = try SourceTree.swiftFiles(matching: "Pet/PetView.swift")
        let text = try #require(view.first?.text)

        #expect(text.contains(".simultaneousGesture(WindowDragGesture())"))
        #expect(text.contains(".allowsWindowActivationEvents(true)"))
        // The click is still the mascot's, beside the drag rather than under it.
        #expect(text.contains(".onTapGesture { model.mascotClicked() }"))
        #expect(text.contains("host: .floatingWindow"))
    }

    /// The mascot draws no ground on either screen that draws it.
    ///
    /// Owner directive of 2026-09-04: "make the pet tab little cleaner no need
    /// of that circle". The faint disc it used to sit on is gone from the
    /// component, and no surface adds one back in another shape: the point was
    /// one treatment everywhere, and one treatment is still what this is. The
    /// component keeps the canvas the painted mascot and its orbit had, which is
    /// room rather than a ground.
    @Test("the mascot draws no ground, and no surface adds one")
    func mascotDrawsNoGround() throws {
        let artwork = try #require(
            try SourceTree.swiftFiles(matching: "Pet/MascotArtwork.swift").first?.text
        )

        #expect(!artwork.contains("Circle()"), "the mascot draws a disc again")
        #expect(!artwork.contains("Palette.chipFill"))
        #expect(artwork.contains("canvasScale"), "Ready's layout keeps the room the mascot had")

        // Each screen draws its own mascot and neither puts a ground under it.
        // Ready draws the animated mascot; the Pet surface draws the one-ink
        // mark in its place (owner, 2026-09-20: "replacing the blue actual
        // mascot in the pet page with monochrome").
        for (path, mascot) in [("Pet/PetSurfaceView.swift", "PetMark()"), ("Onboarding/ReadySurface.swift", "MascotArtwork(")] {
            let text = try #require(try SourceTree.swiftFiles(matching: path).first?.text)

            #expect(text.contains(mascot), "\(path) draws no mascot")
            #expect(!text.contains("Palette.chipFill"), "\(path) draws a ground under the mascot")
        }

        let pet = try #require(try SourceTree.swiftFiles(matching: "Pet/PetSurfaceView.swift").first?.text)
        #expect(!pet.contains("MascotArtwork("), "the Pet surface draws the painted mascot again")
    }

    /// The Live rows are drawn from what the daemon actually sent: no caption,
    /// no line; no delegation, no status; no reported cost, no figure.
    @Test("the live call rows say only what the daemon reported")
    func liveRowsFollowTheDaemon() throws {
        let harness = try harness()

        #expect(harness.model.captionLine == nil)
        #expect(harness.model.taskStatusText == nil)
        #expect(harness.model.voiceCostText == nil)
        #expect(!harness.model.showsCancelTask)

        harness.call.voiceNegotiated()
        harness.call.beginTestCall()
        _ = harness.call.apply(
            .caption(RealtimeCaption(speaker: .user, delta: "what is ", startMs: 0, endMs: 440)),
            audioIsPlaying: false
        )
        _ = harness.call.apply(
            .task(RealtimeTask(delegationId: "dg_01H9", revision: 1, status: .running)),
            audioIsPlaying: false
        )
        _ = harness.call.apply(.usage(RealtimeUsage(voiceCostCents: 5.35)), audioIsPlaying: false)

        #expect(harness.model.captionLine?.hasSuffix("what is ") == true)
        #expect(harness.model.taskStatusText == ProductStrings[.voiceTaskRunning])
        #expect(harness.model.voiceCostText?.isEmpty == false)
        #expect(harness.model.showsCancelTask)
    }

    /// The line names whoever last spoke and shows that speaker's running
    /// text, not the last fragment alone ("You: what is ").
    @Test("the caption line is the running text of the speaker that last grew")
    func captionLineFollowsTheLastSpeaker() throws {
        let harness = try harness()
        harness.call.voiceNegotiated()
        harness.call.beginTestCall()

        for (speaker, delta) in [(RealtimeCaptionSpeaker.user, "what is "), (.user, "the time"), (.assistant, "It is ")] {
            _ = harness.call.apply(.caption(RealtimeCaption(speaker: speaker, delta: delta, startMs: 0, endMs: 1)), audioIsPlaying: false)
        }
        #expect(harness.model.captionLine == "Fermix: It is ")

        _ = harness.call.apply(.caption(RealtimeCaption(speaker: .user, delta: "?", startMs: 0, endMs: 1)), audioIsPlaying: false)
        #expect(harness.model.captionLine == "You: what is the time?")
    }

    /// One line of a running text: the speaker's name leads it and the newest
    /// words end it, so what does not fit is cut from the middle.
    @Test("the caption line keeps its speaker and its newest words")
    func captionLineKeepsBothEnds() throws {
        let text = try #require(try SourceTree.swiftFiles(matching: "Pet/PetSurfaceView.swift").first?.text)

        #expect(text.contains(".truncationMode(.middle)"))
    }

    /// Cancelling is offered for work that is running, and for nothing else: a
    /// finished delegation has nothing left to call off.
    @Test("a finished task offers no cancel")
    func aFinishedTaskOffersNoCancel() throws {
        let harness = try harness()
        harness.call.voiceNegotiated()
        harness.call.beginTestCall()

        _ = harness.call.apply(
            .task(RealtimeTask(delegationId: "dg_01H9", revision: 1, status: .completed)),
            audioIsPlaying: false
        )

        #expect(!harness.model.showsCancelTask)
        #expect(harness.model.taskStatusText == ProductStrings[.voiceTaskCompleted])
    }

    /// The daemon's summary of the work is drawn beside its status word: a
    /// terminal word alone says that something finished, not what.
    @Test("the task line carries the daemon's summary beside the status word")
    func taskLineCarriesTheSummary() throws {
        let harness = try harness()
        harness.call.voiceNegotiated()
        harness.call.beginTestCall()

        _ = harness.call.apply(
            .task(RealtimeTask(delegationId: "dg_01H9", revision: 1, status: .running, summary: "Checking the lease")),
            audioIsPlaying: false
        )

        #expect(
            harness.model.taskStatusText
                == ProductStrings.middot(ProductStrings[.voiceTaskRunning], "Checking the lease")
        )
    }

    /// The pet decides nothing about the call: cancelling reaches the daemon as
    /// the delegation the daemon itself named.
    @Test("cancelling a task sends the daemon that delegation")
    func cancelSendsTheDelegation() async throws {
        let harness = try harness()

        harness.model.toggleCall()
        harness.negotiate()
        await harness.settle()

        _ = harness.call.apply(
            .task(RealtimeTask(delegationId: "dg_01H9", revision: 1, status: .running)),
            audioIsPlaying: false
        )
        harness.model.cancelTask()

        #expect(try harness.socket.sentObjects().contains(wireObject(.taskCancel(delegationId: "dg_01H9"))))
    }

    /// With no delegation there is nothing to cancel, and an invented one would
    /// be a frame about work that does not exist.
    @Test("cancelling with no task sends nothing")
    func cancelWithoutATaskSendsNothing() async throws {
        let harness = try harness()

        harness.model.toggleCall()
        harness.negotiate()
        await harness.settle()
        let before = harness.socket.sent.count

        harness.model.cancelTask()

        #expect(harness.socket.sent.count == before)
    }

    /// The live rows belong to a live call: a surface that kept drawing the
    /// last call's caption would be reporting a call that is over. What the
    /// call cost outlives it: the daemon settles the bill after the hang-up,
    /// and that bill is drawn once the call has ended (M56 §4.2).
    @Test("the live call rows are drawn while a call is up, and the bill after it ends")
    func liveRowsAreGatedOnACall() throws {
        let view = try SourceTree.swiftFiles(matching: "Pet/PetSurfaceView.swift")
        let text = try #require(view.first?.text)

        #expect(text.contains("if model.callActive {"))
        #expect(text.contains("liveCall"))
        #expect(text.contains("model.settledBillText"))
    }

    /// The settled bill arrives after `call_stop`, so a surface that drew cost
    /// only during the call never drew the one figure that is final.
    @Test("the settled bill is drawn in the ended state, and not into the next call")
    func settledBillIsDrawnAfterTheCall() throws {
        let harness = try harness()
        harness.call.voiceNegotiated()
        harness.call.beginTestCall()
        _ = harness.call.apply(.usage(RealtimeUsage(voiceCostCents: 4, accounting: "running")), audioIsPlaying: false)
        #expect(harness.model.settledBillText == nil)

        harness.call.callStopping()
        _ = harness.call.apply(.usage(RealtimeUsage(voiceCostCents: 12.5, accounting: "complete")), audioIsPlaying: false)
        _ = harness.call.apply(.state(.idle), audioIsPlaying: false)

        #expect(harness.model.callActive == false)
        #expect(harness.model.voiceCostText == nil)
        #expect(
            harness.model.settledBillText
                == String(format: ProductStrings[.voiceCostSettledFormat], CurrencyFormat.wholeCents(12.5))
        )

        harness.call.callStarting()
        #expect(harness.model.settledBillText == nil)
    }

    @Test("every pet action carries product copy that obeys the voice rules")
    func actionCopyIsClean() throws {
        let harness = try harness()
        let titles = [
            harness.model.callActionTitle,
            harness.model.muteActionTitle,
            harness.model.interruptActionTitle,
            harness.model.cancelTaskActionTitle,
            harness.model.floatingWindowActionTitle
        ]

        for title in titles {
            #expect(!title.isEmpty)
            #expect(ProductCopyRules.violations(in: title).isEmpty, "\(title)")
        }
    }

    /// Ready's still mascot is the one animation, in the awake pose, not a
    /// painting composed beside it: the app shows one character everywhere.
    @Test("the still mascot draws the one animation, awake")
    func stillMascotIsTheAnimation() throws {
        let text = try #require(try SourceTree.swiftFiles(matching: "Pet/MascotArtwork.swift").first?.text)

        #expect(text.contains("mascot?.mascot(pose: pose"))
        #expect(!text.contains("NSImage"), "the still mascot draws a painting again")
        #expect(MascotArtwork(size: 108).pose == .listening)
    }
}

@MainActor
final class PetHarness {
    let appModel = AppModel()
    let call = VoiceCallModel()
    let engine = PermissionCountingAudioEngine()
    let windows: FakeWindowHost
    let coordinator: AppCoordinator
    let voice: VoiceCoordinator
    let model: PetFeatureModel
    /// The gate every call control but the mascot clicks through.
    let gate: VoiceCallGate

    let socket = FakeRealtimeSocket()
    /// The stopping call's wait for the daemon's last frame.
    let callDeadlines = ManualDeadlineScheduler()
    /// What the last overview said about voice: ready, unless a case says not.
    let readiness = FakeVoiceReadiness()
    /// Every time the gate opened Settings, Voice.
    let voiceSetUps = SetUpRecorder()

    init() throws {
        windows = FakeWindowHost()
        let audio = AudioOwner(engine: engine, deadlines: ManualDeadlineScheduler())
        let session = VoiceSession(
            transport: RealtimeSocketClient(lines: socket),
            socketPath: { "/tmp/fermix-pet-tests.sock" },
            deadlines: MainQueueDeadlineScheduler()
        )
        voice = VoiceCoordinator(model: call, session: session, audio: audio, deadlines: callDeadlines)
        coordinator = AppCoordinator(
            model: appModel,
            windows: WindowCoordinator(host: windows),
            voice: voice,
            lifecycle: FakeLifecycleController(),
            updates: FakeUpdateReconciler(),
            gate: ServiceMutationGate(),
            bootstrap: { .present },
            registrationBuild: { .thisBuild },
            termination: FakeTerminationRequester(),
            hostQuitting: ImmediateHostQuitting(),
            settings: SettingsFixture.model(gateway: try SettingsFixture.gateway()),
            presentation: SettingsPresentation(),
            announcer: RecordingAnnouncer()
        )
        gate = VoiceCallGate(
            call: call,
            voice: voice,
            readiness: readiness,
            setUpVoice: { [voiceSetUps] in voiceSetUps.count += 1 }
        )
        model = PetFeatureModel(call: call, voice: voice, gate: gate, coordinator: coordinator)
    }

    /// Counts the gate's trips to Settings, Voice.
    final class SetUpRecorder {
        var count = 0
    }

    /// The daemon answering its half of the handshake, which is what turns a
    /// requested call into a live one.
    func negotiate() {
        socket.deliver(.serverHello(minVersion: 1, maxVersion: 2))
    }

    /// Lets the call's permission task run without a wall-clock wait.
    func settle() async {
        for _ in 0..<8 {
            await Task.yield()
        }
    }
}
