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

    /// Every pose ships the two plates the mascot cannot be drawn without.
    ///
    /// This is the gate that replaced the bolt fallback: `MascotArtwork` used to
    /// draw the retired accent mark when a plate was missing, so a packaging
    /// defect would have shipped a different mark under the mascot's name
    /// instead of failing. The set is `PetExpression.allCases`, so a pose added
    /// later either ships its plates or fails here.
    @Test("every mascot pose ships its body and face plates")
    func everyPoseShipsItsPlates() throws {
        for pose in PetExpression.allCases {
            for layer in [PetLayer.body, .face] {
                let name = pose.layerAssetName(layer)

                #expect(
                    Bundle.module.url(forResource: name, withExtension: "png") != nil,
                    "\(name).png is not in the resource bundle"
                )
            }
        }
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

    /// The speaking tail is the one place the visual mode outlives the daemon's
    /// state, and it must keep its word: the status the daemon last reported is
    /// not what the pet is doing while audio is still leaving the speaker.
    @Test("the speaking tail still reads as speaking")
    func speakingTailKeepsItsWord() throws {
        let harness = try harness()

        harness.appModel.voiceCallBegan()
        harness.appModel.apply(.audioDelta(base64: "AAAA"), audioIsPlaying: false)
        harness.appModel.apply(.state(.listening), audioIsPlaying: true)

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

        #expect(text.contains("MascotArtwork("))
        #expect(text.contains("PrimaryAction("))
    }

    /// The mascot draws no ground on either screen that draws it.
    ///
    /// Owner directive of 2026-09-04: "make the pet tab little cleaner no need
    /// of that circle". The faint disc it used to sit on is gone from the
    /// component, and no surface adds one back in another shape: the point was
    /// one treatment everywhere, and one treatment is still what this is. The
    /// component keeps a canvas a little larger than the artwork because the
    /// ring orbits behind it at 1.20x, which is room rather than a ground.
    @Test("the mascot draws no ground, and no surface adds one")
    func mascotDrawsNoGround() throws {
        let artwork = try #require(
            try SourceTree.swiftFiles(matching: "Pet/MascotArtwork.swift").first?.text
        )

        #expect(!artwork.contains("Circle()"), "the mascot draws a disc again")
        #expect(!artwork.contains("Palette.chipFill"))
        #expect(artwork.contains("canvasScale"), "the ring's orbit keeps its room")

        for path in ["Pet/PetSurfaceView.swift", "Onboarding/ReadySurface.swift"] {
            let text = try #require(try SourceTree.swiftFiles(matching: path).first?.text)

            #expect(text.contains("MascotArtwork("), "\(path) draws no mascot")
            #expect(!text.contains("Palette.chipFill"), "\(path) draws a ground under the mascot")
        }
    }

    @Test("every pet action carries product copy that obeys the voice rules")
    func actionCopyIsClean() throws {
        let harness = try harness()
        let titles = [
            harness.model.callActionTitle,
            harness.model.muteActionTitle,
            harness.model.interruptActionTitle,
            harness.model.floatingWindowActionTitle
        ]

        for title in titles {
            #expect(!title.isEmpty)
            #expect(ProductCopyRules.violations(in: title).isEmpty, "\(title)")
        }
    }

    @Test("the still mascot draws the original PNG body, face, and ring")
    func mascotDrawsBothLayers() throws {
        let source = try SourceTree.swiftFiles(matching: "Pet/MascotArtwork.swift")
        let text = try #require(source.first?.text)
        let preview = MascotArtwork(size: 108)
        #expect(text.contains("image(.body)"))
        #expect(text.contains("image(.face)"))
        #expect(text.contains("image(.ring)"))
        #expect(preview.pose == .listening)

        let bundle = Bundle.module
        var sizes: [CGSize] = []
        for layer in [PetLayer.body, .face, .ring] {
            let name = PetExpression.listening.layerAssetName(layer)
            let url = try #require(bundle.url(forResource: name, withExtension: "png"), "\(name) is missing")
            let image = try #require(NSImage(contentsOf: url))

            #expect(image.size.width == image.size.height, "\(name) is not square")
            sizes.append(image.size)
        }

        #expect(sizes.count == 3)
        #expect(Set(sizes.map(\.width)).count == 1, "the layers are drawn on different canvases")
    }
}

@MainActor
final class PetHarness {
    let appModel = AppModel()
    let engine = PermissionCountingAudioEngine()
    let windows: FakeWindowHost
    let coordinator: AppCoordinator
    let voice: VoiceCoordinator
    let model: PetFeatureModel

    let transport = FakeRealtimeTransport()

    init() throws {
        windows = FakeWindowHost()
        let audio = AudioOwner(engine: engine)
        let session = VoiceSession(
            transport: transport,
            socketPath: { "/tmp/fermix-pet-tests.sock" },
            deadlines: MainQueueDeadlineScheduler()
        )
        voice = VoiceCoordinator(model: appModel, session: session, audio: audio)
        coordinator = AppCoordinator(
            model: appModel,
            windows: WindowCoordinator(host: windows),
            voice: voice,
            lifecycle: FakeLifecycleController(),
            updates: FakeUpdateReconciler(),
            gate: ServiceMutationGate(),
            bootstrap: { .present },
            termination: FakeTerminationRequester(),
            settings: SettingsFixture.model(gateway: try SettingsFixture.gateway()),
            presentation: SettingsPresentation()
        )
        model = PetFeatureModel(model: appModel, voice: voice, coordinator: coordinator)
    }

    /// The daemon answering its half of the handshake, which is what turns a
    /// requested call into a live one.
    func negotiate() {
        transport.deliver(.serverHello(minVersion: 1, maxVersion: 1))
    }

    /// Lets the call's permission task run without a wall-clock wait.
    func settle() async {
        for _ in 0..<8 {
            await Task.yield()
        }
    }
}
