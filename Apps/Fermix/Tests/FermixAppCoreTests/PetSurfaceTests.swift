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
    private func harness() -> PetHarness {
        PetHarness()
    }

    /// The floating window stays hidden until it is opened or enabled: a launch
    /// must not put a companion on screen nobody asked for.
    @Test("the floating window is hidden until it is opened")
    func hiddenUntilOpened() {
        let harness = harness()

        #expect(!harness.windows.isPresented(.pet))
        #expect(!harness.model.floatingWindowShown)
    }

    @Test("the surface opens and closes the floating window through the coordinator")
    func togglesTheFloatingWindow() {
        let harness = harness()

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
    func noPermissionOnOpen() {
        let harness = harness()

        harness.model.setFloatingWindow(true)
        _ = harness.model.presentation
        _ = harness.model.callActionTitle

        #expect(harness.engine.permissionRequests == 0)
    }

    @Test("starting a call is the first and only thing that asks for the microphone")
    func permissionAtFirstCall() async {
        let harness = harness()

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
    func hiddenWindowPausesAnimation() {
        let harness = harness()

        harness.model.setWindowVisible(false)
        #expect(!harness.model.windowVisible)

        harness.model.setWindowVisible(true)
        #expect(harness.model.windowVisible)
    }

    @Test("the surface names the voice state in words, not only in the mascot")
    func stateIsReadable() {
        let harness = harness()

        #expect(!harness.model.accessibilityValue.isEmpty)
        #expect(harness.model.statusText == harness.model.presentation.accessibilityLabel)
    }

    @Test("every pet action carries product copy that obeys the voice rules")
    func actionCopyIsClean() {
        let harness = harness()
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

    init() {
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
            bootstrap: { .present },
            termination: FakeTerminationRequester()
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
