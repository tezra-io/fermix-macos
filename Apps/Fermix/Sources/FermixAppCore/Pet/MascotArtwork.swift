import SwiftUI

/// The mascot at rest, at whatever size a surface calls for.
///
/// Ready draws it. The floating companion is `PetView`, which feeds the same
/// animation the live voice mode and level; this one never reads the daemon.
/// Both are the one Rive mascot (`MascotRendering`), so the app shows one
/// character everywhere rather than a painting on one screen and an animation
/// on another.
///
/// **The pose is the awake one.** The idle pose has its eyes shut, which reads
/// as a mascot with no face (the owner's report of 2026-09-03). `listening` is
/// the open-eye pose, the one the colour app icon is cut from.
///
/// **It draws no ground** (owner directive of 2026-09-04: "make the pet tab
/// little cleaner no need of that circle").
struct MascotArtwork: View {
    /// The room the component reserves around the artwork, as a multiple of
    /// it. It is the frame the painted mascot and its orbit took, kept so the
    /// screens around it do not move.
    private static let canvasScale: Double = 132.0 / 108.0

    let size: Double
    /// Which pose to draw. Awake by default, and every shipped call site takes
    /// the default: the parameter exists so the pose is stated where it is
    /// decided rather than assumed inside the view.
    var pose: PetExpression = .listening

    @Environment(\.mascot) private var mascot
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // The animation's own frame carries room for the pose's motion, so at
        // `size` the body is drawn at the painted still's size.
        mascot?.mascot(pose: pose, level: { 0 }, animates: !reduceMotion)
            .frame(width: size, height: size)
            .frame(width: size * Self.canvasScale, height: size * Self.canvasScale)
            .accessibilityHidden(true)
    }
}
