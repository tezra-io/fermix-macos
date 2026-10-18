import SwiftUI

/// The colours and geometry of the thinking orb (`ThinkingOrb`).
///
/// The one blue, deep to pale, swept round a small pearl and softened, under
/// a faint sheen from above and a rim that falls off into the deep tone, so it
/// reads as a sphere at text size. Its glow is the accent itself.
enum ThinkingOrbRecipe {
    /// A little shorter than the `calloutSmall` line it sits in.
    static let diameter: Double = 14

    static let deep = Palette.accentPressed
    /// The accent as dark text, used here as a tone of the pearl.
    static let pale = ThemedColor(uniform: SRGBColor(hex: "#7f9dff"))
    static let light = ThemedColor(uniform: SRGBColor(hex: "#dbe4ff"))
    /// The tones the sweep passes through, once round the pearl.
    static let sweep = [deep, Palette.accent, pale, light, Palette.accentHover, Palette.accent, deep]
    static let sheen = ThemedColor(uniform: .rgba(255, 255, 255, 0.35))
    static let rim = ThemedColor(uniform: .rgba(30, 70, 214, 0.45))

    /// How soft the sweep is, as a fraction of the diameter.
    static let softness = 0.12
    /// The pearl's scale with the breath out, and its glow from out to in.
    static let exhaledScale = 0.9
    static let glowAlpha = (exhaled: 0.2, inhaled: 0.5)
    /// How far the glow reaches, as a fraction of the diameter.
    static let glowReach = 0.35
    /// Plenty for something this slow and this small, at half a display's
    /// frames.
    static let framesPerSecond: Double = 30
}

/// Fermix thinking, as a small blue pearl that breathes while its light turns
/// slowly round it (`MotionRole.thinkingOrb`). Under Reduce Motion it holds
/// still at a full breath. It is decorative: the word beside it says what it
/// means, so every caller hides it from accessibility.
struct ThinkingOrb: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let motion = Motion(reduceMotion: reduceMotion)
        let schedule = AnimationTimelineSchedule(
            minimumInterval: 1 / ThinkingOrbRecipe.framesPerSecond,
            paused: motion.isSuppressed(.thinkingOrb)
        )

        TimelineView(schedule) { context in
            pearl(Pose(at: context.date, motion: motion))
        }
    }

    private func pearl(_ pose: Pose) -> some View {
        let recipe = ThinkingOrbRecipe.self
        let size = recipe.diameter

        return ZStack {
            AngularGradient(colors: recipe.sweep.map(\.color), center: .center, angle: pose.turn)
                .blur(radius: size * recipe.softness, opaque: true)
            RadialGradient(
                colors: [recipe.sheen.color, .clear],
                center: UnitPoint(x: 0.5, y: 0.3),
                startRadius: 0,
                endRadius: size * 0.45
            )
            RadialGradient(colors: [.clear, recipe.rim.color], center: .center, startRadius: size * 0.32, endRadius: size * 0.52)
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .scaleEffect(recipe.exhaledScale + (1 - recipe.exhaledScale) * pose.breath)
        .shadow(
            color: Palette.accent.color.opacity(
                recipe.glowAlpha.exhaled + (recipe.glowAlpha.inhaled - recipe.glowAlpha.exhaled) * pose.breath
            ),
            radius: size * recipe.glowReach
        )
    }

    /// Where the orb is at a moment: how full its breath is, 0 to 1, and how
    /// far its light has turned. A breath out and in takes the spec's two
    /// half-cycles, along a cosine, which is the ease in and out it names; the
    /// light turns once every two breaths. Under Reduce Motion it rests where
    /// a suppressed loop does, at a full breath, with its light where it
    /// starts.
    struct Pose: Equatable {
        let breath: Double
        let turn: Angle

        init(at date: Date, motion: Motion) {
            guard let spec = motion.resolved(.thinkingOrb) else {
                breath = motion.restingProgress(.thinkingOrb)
                turn = .zero
                return
            }

            let cycles = date.timeIntervalSinceReferenceDate / (2 * spec.duration)
            breath = (1 - cos(2 * .pi * cycles)) / 2
            turn = .radians(.pi * cycles)
        }
    }
}
