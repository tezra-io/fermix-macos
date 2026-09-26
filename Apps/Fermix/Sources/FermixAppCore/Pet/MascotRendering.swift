import Foundation
import SwiftUI

/// Draws the mascot, behind a seam.
///
/// The animation runtime lives on the other side of it. `FermixAppCore`
/// declares this and imports nothing, because both executables link this
/// library and `FermixAgent` must never load an animation framework, for the
/// same reason it never loads Sparkle (M34 §6). The GUI executable hands in the
/// one implementation, `FermixRive`, exactly as it hands in the updater.
@MainActor
public protocol MascotRendering: AnyObject {
    /// The mascot in `pose`, reading `level` for how loud the voice is.
    ///
    /// The pose changes a few times a turn and arrives through SwiftUI. The
    /// level changes tens of times a second and is sampled, never published,
    /// so it cannot invalidate the tree that holds the mascot. `animates` false
    /// parks the loops (the window is off screen, or Reduce Motion is on); a
    /// new pose is still drawn.
    ///
    /// The view takes no clicks: the surface around it owns what a click does.
    func mascot(pose: PetExpression, level: @escaping @MainActor () -> Float, animates: Bool) -> AnyView
}

/// The animation the renderer plays, and the names it publishes, written once.
///
/// The file is authored in Rive: a state machine whose `mode` enum takes the
/// four `PetExpression` raw values, and whose `level` number (0 to 1) drives
/// the waveform mouth and the body's swell with the voice.
public enum MascotAnimation {
    public static let fileName = "FermixMascot"
    public static let fileExtension = ".riv"
    public static let stateMachine = "Pet"
    public static let modeProperty = "mode"
    public static let levelProperty = "level"

    /// The app's own resources, where the file ships.
    public static var bundle: Bundle { AppResources.bundle }
}

extension EnvironmentValues {
    /// The renderer every window's root carries (`AppSurfaces`). Absent only
    /// where no window hosts the view, which is to say in tests.
    public var mascot: (any MascotRendering)? {
        get { self[MascotRenderingKey.self] }
        set { self[MascotRenderingKey.self] = newValue }
    }
}

private struct MascotRenderingKey: EnvironmentKey {
    static let defaultValue: (any MascotRendering)? = nil
}
