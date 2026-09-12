import SwiftUI

/// The two entrances the design publishes, as one modifier each.
///
/// Both are the same shape: park the view at its published travel, then let
/// `Motion` decide whether that travel is animated, shortened to opacity, or
/// skipped. Reduce Motion is resolved once, in `Motion`, so no view branches on
/// the environment itself.
private struct Entrance: ViewModifier {
    let role: MotionRole
    let delay: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var entered = false

    func body(content: Content) -> some View {
        let motion = Motion(reduceMotion: reduceMotion)
        let offset = MotionEntrance.offset(for: role, reduceMotion: reduceMotion)
        let scale = MotionEntrance.scale(for: role, reduceMotion: reduceMotion)

        return content
            .opacity(entered ? 1 : 0)
            .offset(y: entered ? 0 : offset)
            .scaleEffect(entered ? 1 : scale)
            .onAppear {
                guard let animation = motion.animation(role) else {
                    entered = true
                    return
                }

                withAnimation(animation.delay(MotionEntrance.delay(delay, reduceMotion: reduceMotion))) {
                    entered = true
                }
            }
    }
}

extension View {
    /// One block of a choreographed surface entrance.
    ///
    /// `step` indexes a published stagger ladder, so Welcome and Ready arrive
    /// block by block rather than as one flat pop. The ladder is a parameter
    /// because the two screens publish different ones.
    public func fermixRiseIn(step: Int, ladder: [Double] = MotionStagger.riseIn) -> some View {
        modifier(Entrance(role: .riseIn, delay: MotionStagger.delay(step, in: ladder)))
    }

    /// A window or panel arriving: y+14 to 0, scale .985 to 1, opacity 0 to 1.
    public func fermixWindowEntrance() -> some View {
        modifier(Entrance(role: .windowEnter, delay: 0))
    }
}
