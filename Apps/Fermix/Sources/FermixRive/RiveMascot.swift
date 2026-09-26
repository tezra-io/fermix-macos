import AppKit
import FermixAppCore
import RiveRuntime
import SwiftUI

/// The mascot, drawn by the Rive runtime.
///
/// The only module in the repository that imports Rive. `FermixAppCore`
/// declares `MascotRendering` and imports nothing, because both executables
/// link that library and `FermixAgent` must never load an animation framework;
/// only the `Fermix` executable links this target, and `main.swift` hands the
/// renderer in, as it hands in the updater.
///
/// It decides nothing about the voice. The pose is `PetExpression`, which the
/// core resolves from the daemon's state, and the level is the core's own
/// audio level; this only plays them.
@MainActor
public final class RiveMascotRenderer: MascotRendering {
    public init() {}

    public func mascot(pose: PetExpression, level: @escaping @MainActor () -> Float, animates: Bool) -> AnyView {
        AnyView(RiveMascotView(pose: pose, level: level, animates: animates))
    }
}

/// One animated mascot.
///
/// Each view owns its own player: the companion and Ready can be on screen at
/// once, and one state machine cannot hold two poses.
private struct RiveMascotView: View {
    let pose: PetExpression
    let level: @MainActor () -> Float
    let animates: Bool

    @StateObject private var player = MascotPlayer()

    var body: some View {
        player.rive.view()
            // The surface around the mascot owns the click (the companion's
            // is the call); the animation publishes no listeners of its own.
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onAppear { player.show(pose: pose, animates: animates, level: level) }
            .onChange(of: pose) { _, pose in player.show(pose: pose, animates: animates, level: level) }
            .onChange(of: animates) { _, animates in player.show(pose: pose, animates: animates, level: level) }
            .onDisappear { player.stop() }
    }
}

/// The player behind one mascot: the Rive view model, the bound properties,
/// and the level sampler.
@MainActor
private final class MascotPlayer: ObservableObject {
    /// How often the level is read while it can move the mouth. It is the
    /// frame rate the animation is drawn at, so no frame reads a stale level
    /// and none is read twice.
    private static let framesPerSecond = 30
    /// How long a parked mascot plays after a pose change: the file blends
    /// between poses over 0.45 s, so this lets the new pose land before the
    /// loops stop.
    private static let settle: Duration = .milliseconds(600)
    /// Changes smaller than this are not written; the mouth cannot show them.
    private static let levelStep: Float = 0.01

    let rive: RiveViewModel
    /// Held strongly: the runtime keeps no reference to the bound instance,
    /// and a released one stops taking writes.
    private var bound: RiveDataBindingViewModel.Instance?
    private var pose: PetExpression?
    private var level: (@MainActor () -> Float)?
    private var writtenLevel: Float = 0
    private var sampler: Timer?
    private var parking: Task<Void, Never>?

    init() {
        rive = RiveViewModel(
            fileName: MascotAnimation.fileName,
            extension: MascotAnimation.fileExtension,
            in: MascotAnimation.bundle,
            stateMachineName: MascotAnimation.stateMachine,
            fit: .contain
        )
        rive.riveModel?.enableAutoBind { [weak self] instance in
            MainActor.assumeIsolated {
                guard let self else { return }

                self.bound = instance
                // The instance can arrive after the first pose did.
                if let pose = self.pose { self.write(pose: pose) }
            }
        }
    }

    func show(pose: PetExpression, animates: Bool, level: @escaping @MainActor () -> Float) {
        // The rate is the view's, and the view exists only once SwiftUI has
        // made it, which is after this player was built: set before that, the
        // view drew at the display's own rate.
        rive.riveView?.setPreferredFramesPerSecond(preferredFramesPerSecond: Self.framesPerSecond)

        let changed = pose != self.pose
        self.pose = pose
        self.level = level
        if changed { write(pose: pose) }

        play(animates: animates, poseChanged: changed)
        sample(while: animates && Self.listensToLevel(pose))
    }

    func stop() {
        parking?.cancel()
        sample(while: false)
        rive.pause()
    }

    // MARK: - Playback

    /// Animating plays the loops. Parked, the mascot still takes a new pose:
    /// it plays just long enough for the pose to land, then holds still.
    private func play(animates: Bool, poseChanged: Bool) {
        parking?.cancel()

        if animates || poseChanged {
            rive.play()
        }
        guard !animates else { return }

        parking = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.settle)
            guard !Task.isCancelled else { return }

            self?.rive.pause()
        }
    }

    private func write(pose: PetExpression) {
        bound?.enumProperty(fromPath: MascotAnimation.modeProperty)?.value = pose.rawValue
    }

    // MARK: - Level

    /// Only listening and speaking move with the voice; the other poses hold
    /// the level at rest.
    private static func listensToLevel(_ pose: PetExpression) -> Bool {
        pose == .listening || pose == .speaking
    }

    private func sample(while active: Bool) {
        guard active else {
            sampler?.invalidate()
            sampler = nil
            write(level: 0)
            return
        }
        guard sampler == nil else { return }

        let timer = Timer(timeInterval: 1.0 / Double(Self.framesPerSecond), repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let level = self.level else { return }

                self.write(level: level())
            }
        }
        // Common modes, so the mouth keeps moving while a menu is open or the
        // window is being dragged.
        RunLoop.main.add(timer, forMode: .common)
        sampler = timer
    }

    private func write(level: Float) {
        let level = min(max(level, 0), 1)
        guard abs(level - writtenLevel) >= Self.levelStep || (level == 0 && writtenLevel != 0) else { return }

        writtenLevel = level
        bound?.numberProperty(fromPath: MascotAnimation.levelProperty)?.value = level
    }
}
