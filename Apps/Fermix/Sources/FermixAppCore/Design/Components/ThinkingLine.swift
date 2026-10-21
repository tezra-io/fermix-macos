import SwiftUI

/// The geometry and ink of the thinking line (`ThinkingLine`).
///
/// A braille cell of six dots, two across and three down, as tall as a
/// capital and sitting on the word's baseline like one, in the word's own
/// grey; a soft gap walks round it. Through the word flows a band of the
/// strongest ink.
enum ThinkingLineRecipe {
    static let ink = Palette.faint
    /// The band's colour at its heart.
    static let glow = Palette.ink

    /// A dot's diameter and the step from one dot to the next, in whole
    /// points, so on a display without Retina every dot falls on whole pixels
    /// and stays crisp: beside the word, as tall as a capital, and in the
    /// chat's newest button, as tall as its arrow.
    static let lineDots = (diameter: 2.0, step: 3.0)
    static let buttonDots = (diameter: 3.0, step: 4.0)
    /// The cell read round from its top left, down the right column and up
    /// the left, which is the way the gap walks.
    static let cells: [(column: Int, row: Int)] = [(0, 0), (1, 0), (1, 1), (1, 2), (0, 2), (0, 1)]
    /// The gap's strength at its heart, and how many dots its softness
    /// reaches.
    static let gapAlpha = 0.15
    static let gapReach = 1.3

    /// The band's half width and the path its centre takes, as fractions of
    /// the word's width. It starts and ends wholly off the word, so the word
    /// rests plain between passes.
    static let bandHalfWidth = 0.35
    static let bandPath = (start: -0.6, end: 1.6)

    /// Plenty for something this small, at half a display's frames.
    static let framesPerSecond: Double = 30
}

/// Fermix thinking: the braille cell with its walking gap beside the word,
/// with a band of light flowing through it (`MotionRole.thinkingDots`,
/// `MotionRole.thinkingShimmer`), both on one timeline. Under Reduce Motion
/// every dot holds lit and the word holds plain.
struct ThinkingLine: View {
    let word: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let motion = Motion(reduceMotion: reduceMotion)
        let schedule = AnimationTimelineSchedule(
            minimumInterval: 1 / ThinkingLineRecipe.framesPerSecond,
            paused: motion.isSuppressed(.thinkingDots) && motion.isSuppressed(.thinkingShimmer)
        )

        TimelineView(schedule) { context in
            HStack(alignment: .firstTextBaseline, spacing: Spacing.xxs) {
                Self.cell(Self.strengths(at: context.date, motion: motion), dots: ThinkingLineRecipe.lineDots)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] }

                Text(word)
                    .fermixType(Typography.style(.calloutSmall))
                    .foregroundStyle(Self.wordStyle(band: Self.band(at: context.date, motion: motion)))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(word)
        .accessibilityAddTraits(.updatesFrequently)
    }

    /// The cell in dots of this size, each as strong as `strengths` says, in
    /// the cell's order.
    static func cell(_ strengths: [Double], dots: (diameter: Double, step: Double)) -> some View {
        let recipe = ThinkingLineRecipe.self
        let size = CGSize(width: dots.diameter, height: dots.diameter)

        return Canvas { graphics, _ in
            for (cell, strength) in zip(recipe.cells, strengths) {
                let corner = CGPoint(x: Double(cell.column) * dots.step, y: Double(cell.row) * dots.step)
                graphics.fill(Path(ellipseIn: CGRect(origin: corner, size: size)), with: .color(recipe.ink.color.opacity(strength)))
            }
        }
        .frame(width: dots.step + dots.diameter, height: 2 * dots.step + dots.diameter)
    }

    private static func wordStyle(band: Double?) -> AnyShapeStyle {
        let recipe = ThinkingLineRecipe.self
        guard let band else { return AnyShapeStyle(recipe.ink.color) }

        return AnyShapeStyle(LinearGradient(
            colors: [recipe.ink.color, recipe.glow.color, recipe.ink.color],
            startPoint: UnitPoint(x: band - recipe.bandHalfWidth, y: 0.5),
            endPoint: UnitPoint(x: band + recipe.bandHalfWidth, y: 0.5)
        ))
    }

    /// How strong each dot is at a moment, in the cell's order: lit, but for
    /// a soft gap walking round once per the spec's duration. Under Reduce
    /// Motion every dot rests where a suppressed loop does, at its high
    /// value, which is lit.
    static func strengths(at date: Date, motion: Motion) -> [Double] {
        let recipe = ThinkingLineRecipe.self
        let count = Double(recipe.cells.count)

        guard let spec = motion.resolved(.thinkingDots) else {
            return recipe.cells.map { _ in motion.restingProgress(.thinkingDots) }
        }

        let gap = (date.timeIntervalSinceReferenceDate / spec.duration).truncatingRemainder(dividingBy: 1) * count
        return recipe.cells.indices.map { index in
            let along = abs(Double(index) - gap)
            let lit = min(1, min(along, count - along) / recipe.gapReach)
            return recipe.gapAlpha + (1 - recipe.gapAlpha) * lit * lit
        }
    }

    /// Where the band's centre is at a moment, as a fraction of the word's
    /// width, crossing once per the spec's duration; nil while Reduce Motion
    /// holds the word plain.
    static func band(at date: Date, motion: Motion) -> Double? {
        guard let spec = motion.resolved(.thinkingShimmer) else { return nil }

        let path = ThinkingLineRecipe.bandPath
        let progress = (date.timeIntervalSinceReferenceDate / spec.duration).truncatingRemainder(dividingBy: 1)
        return path.start + (path.end - path.start) * progress
    }
}

/// The thinking line's cell on its own, on a timeline of its own: what the
/// chat's newest button holds while a reply is being written. Under Reduce
/// Motion every dot holds lit.
struct ThinkingCell: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let motion = Motion(reduceMotion: reduceMotion)
        let schedule = AnimationTimelineSchedule(
            minimumInterval: 1 / ThinkingLineRecipe.framesPerSecond,
            paused: motion.isSuppressed(.thinkingDots)
        )

        TimelineView(schedule) { context in
            ThinkingLine.cell(ThinkingLine.strengths(at: context.date, motion: motion), dots: ThinkingLineRecipe.buttonDots)
        }
    }
}
