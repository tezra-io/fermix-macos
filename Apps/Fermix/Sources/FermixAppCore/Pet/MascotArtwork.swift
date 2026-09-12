import SwiftUI

/// The mascot, at whatever size a surface calls for.
///
/// One component for every *still* mascot in the product: the Pet tab's
/// preview and Ready. The floating companion
/// is `PetView`, which drives the same layers off the live voice mode and is a
/// different thing; this one never reads the daemon.
///
/// **The pose is the awake one.** The idle frame's face is two low crescents,
/// which reads as a mascot with its eyes shut: the owner's report of 2026-09-03
/// that "the mascot doesnt have the face/eye" is that frame, not a missing
/// layer. `listening` is the open-eye frame, and it is the frame the colour app
/// icon is cut from, so the app and its own icon show one face.
///
/// **It draws no ground.** The faint disc this used to sit on is gone (owner
/// directive of 2026-09-04: "make the pet tab little cleaner no need of that
/// circle"). It is the mascot and nothing behind it on both screens, and no
/// background of another shape replaces it: the point was one treatment
/// everywhere, and that is still what this is.
///
/// **Every layer, or nothing to draw.** The ring sits behind at 1.20x, the way
/// the floating pet composes its resting frame, and the face plate fills the
/// opening the body is modelled around, so the body alone is a torus. The two
/// plates ship with the app — `PetSurfaceTests` fails the build without them —
/// so a missing one is a packaging defect and this refuses rather than drawing
/// the retired accent bolt in the mascot's place, which would ship a different
/// mark under the mascot's name.
struct MascotArtwork: View {
    /// The ring is authored to orbit *behind* the mascot, so it is drawn larger
    /// than the plates it sits under. The number is the floating pet's own.
    private static let ringScale: Double = 1.20

    /// The room the component reserves around the artwork, as a multiple of
    /// it. The ring orbits at `ringScale`, so a component measured at the
    /// artwork's own size would have its orbit drawn outside its bounds and over
    /// whatever sits beside it.
    private static let canvasScale: Double = 132.0 / 108.0

    let size: Double
    /// Which frame to draw. Awake by default, and every shipped call site takes
    /// the default: the parameter exists so the pose is stated where it is
    /// decided rather than assumed inside the view.
    var pose: PetExpression = .listening
    var body: some View {
        artwork
            .scaleEffect(scale)
            .frame(width: size, height: size)
            .frame(width: size * Self.canvasScale, height: size * Self.canvasScale)
            .accessibilityHidden(true)
    }

    private var artwork: some View {
        guard let body = image(.body), let face = image(.face) else {
            preconditionFailure("every mascot pose ships a body and a face plate: \(pose)")
        }

        return ZStack {
            // The ring is the one optional layer: a pose that publishes none
            // is a mascot without an orbit, not a mascot without a face.
            if let ring = image(.ring) {
                plate(ring).scaleEffect(Self.ringScale)
            }

            plate(body)
            plate(face)
        }
    }

    /// One layer's artwork, or nothing where this pose has no such plate.
    private func image(_ layer: PetLayer) -> NSImage? {
        PetAssetCache.shared.image(pose.layerAssetName(layer))
    }

    /// One layer of the stack. Every layer is authored on the same square
    /// canvas, so they register by being drawn at the same size.
    private func plate(_ image: NSImage) -> some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
    }

    private var scale: Double {
        // Preserve the established resting size of the still artwork.
        1 - MascotMotion.breathAmp(.listening)
    }
}
