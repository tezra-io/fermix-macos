import SwiftUI

/// The Fermix wordmark's letterforms, as a shape.
///
/// A 1:1 port of the approved SVG (`Resources/Wordmark/fermix-wordmark.svg`,
/// vendored from the engine's `fermix_wordmark/1`): the exact path commands in
/// the 384 by 100 glyph space, not a redrawn approximation — the coordinates
/// ARE the approved asset. `NSImage` cannot tint a `currentColor` SVG, and a
/// template image would flatten the blue eye-dots, which is why the mark is
/// drawn rather than loaded. The dots are `FermixWordmark`'s to draw; this
/// shape is the letters only, so they can fill in any colour.
public struct FermixWordmarkLetters: Shape {
    /// The glyph space of the published paths.
    public static let glyphSize = CGSize(width: 384, height: 100)

    public init() {}

    public func path(in rect: CGRect) -> Path {
        let scale = rect.width / Self.glyphSize.width
        var pen = Pen(origin: rect.origin, scale: scale)

        // F at translate(0), and E's shared first three subpaths at
        // translate(69).
        stemAndArms(&pen, dx: 0)
        stemAndArms(&pen, dx: 69)
        // E's foot: M17,83 H56 V100 H17 Z.
        pen.polygon(dx: 69, [(17, 83), (56, 83), (56, 100), (17, 100)])
        letterR(&pen, dx: 138)
        // M: M0,100 V0 H18 L36,47 L54,0 H72 V100 H55 V34 L41,70 H31 L17,34 V100 Z.
        pen.polygon(
            dx: 209,
            [
                (0, 100), (0, 0), (18, 0), (36, 47), (54, 0), (72, 0), (72, 100),
                (55, 100), (55, 34), (41, 70), (31, 70), (17, 34), (17, 100)
            ]
        )
        // I stem at translate(294): M0,40 H17 V100 H0 Z.
        pen.polygon(dx: 294, [(0, 40), (17, 40), (17, 100), (0, 100)])
        // X at translate(324): four L-path wedges.
        pen.polygon(dx: 324, [(0, 0), (17, 0), (30, 30), (21.5, 50)])
        pen.polygon(dx: 324, [(0, 100), (17, 100), (30, 70), (21.5, 50)])
        pen.polygon(dx: 324, [(60, 0), (43, 0), (30, 30), (38.5, 50)])
        pen.polygon(dx: 324, [(60, 100), (43, 100), (30, 70), (38.5, 50)])

        return pen.path
    }

    /// F's three subpaths, which E shares: the stem and the two arms.
    private func stemAndArms(_ pen: inout Pen, dx: Double) {
        // M9,0 H17 V100 H0 V9 Z
        pen.polygon(dx: dx, [(9, 0), (17, 0), (17, 100), (0, 100), (0, 9)])
        // M17,0 H56 V9 L48,17 H17 Z
        pen.polygon(dx: dx, [(17, 0), (56, 0), (56, 9), (48, 17), (17, 17)])
        // M17,41 H48 V50 L40,58 H17 Z
        pen.polygon(dx: dx, [(17, 41), (48, 41), (48, 50), (40, 58), (17, 58)])
    }

    /// R's compound path: stem, bowl-and-leg with its two `Q` quadratics, and
    /// the inner counter the even-odd fill cuts out.
    private func letterR(_ pen: inout Pen, dx: Double) {
        // M9,0 H17 V100 H0 V9 Z
        pen.polygon(dx: dx, [(9, 0), (17, 0), (17, 100), (0, 100), (0, 9)])
        // M17,0 H44 Q58,0 58,18 V34 Q58,52 44,52 H30 L46,52 L58,100 H41 L30,52 H17 Z
        pen.move(dx: dx, 17, 0)
        pen.line(dx: dx, 44, 0)
        pen.quad(dx: dx, to: (58, 18), control: (58, 0))
        pen.line(dx: dx, 58, 34)
        pen.quad(dx: dx, to: (44, 52), control: (58, 52))
        pen.line(dx: dx, 30, 52)
        pen.line(dx: dx, 46, 52)
        pen.line(dx: dx, 58, 100)
        pen.line(dx: dx, 41, 100)
        pen.line(dx: dx, 30, 52)
        pen.line(dx: dx, 17, 52)
        pen.close()
        // M17,17 H38 Q41,17 41,20 V32 Q41,35 38,35 H17 Z
        pen.move(dx: dx, 17, 17)
        pen.line(dx: dx, 38, 17)
        pen.quad(dx: dx, to: (41, 20), control: (41, 17))
        pen.line(dx: dx, 41, 32)
        pen.quad(dx: dx, to: (38, 35), control: (41, 35))
        pen.line(dx: dx, 17, 35)
        pen.close()
    }

    /// SVG path commands in glyph space, resolved to a scaled `Path`.
    private struct Pen {
        var path = Path()
        let origin: CGPoint
        let scale: Double

        func point(dx: Double, _ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: origin.x + (x + dx) * scale, y: origin.y + y * scale)
        }

        mutating func move(dx: Double, _ x: Double, _ y: Double) {
            path.move(to: point(dx: dx, x, y))
        }

        mutating func line(dx: Double, _ x: Double, _ y: Double) {
            path.addLine(to: point(dx: dx, x, y))
        }

        mutating func quad(dx: Double, to end: (Double, Double), control: (Double, Double)) {
            path.addQuadCurve(
                to: point(dx: dx, end.0, end.1),
                control: point(dx: dx, control.0, control.1)
            )
        }

        mutating func close() {
            path.closeSubpath()
        }

        /// A closed run of straight edges: `M` then `H`/`V`/`L` then `Z`.
        mutating func polygon(dx: Double, _ points: [(Double, Double)]) {
            precondition(points.count >= 3, "a polygon needs at least three points")

            move(dx: dx, points[0].0, points[0].1)
            for vertex in points.dropFirst() {
                line(dx: dx, vertex.0, vertex.1)
            }
            close()
        }
    }
}

/// The Fermix wordmark: the letters in one tint, and the two accent eye-dots.
///
/// This is the brand mark everywhere the mascot used to stand in for one; the
/// Pet surface keeps `MascotArtwork`, because there the mascot is the content
/// rather than branding.
public struct FermixWordmark: View {
    /// Width over height of the glyph space: 384 / 100.
    public static let aspectRatio: Double = 3.84
    /// The dot radius in glyph space.
    public static let dotRadius: Double = 4.7
    /// The two eye-dot centres in glyph space: `translate(294 0)` plus
    /// `cx 2 / cx 15`, both at `cy 21`.
    public static let dotCenters: [CGPoint] = [CGPoint(x: 296, y: 21), CGPoint(x: 309, y: 21)]

    public let height: Double
    public let color: Color

    public init(height: Double, color: Color = Palette.ink.color) {
        precondition(height > 0, "the wordmark needs a positive height")

        self.height = height
        self.color = color
    }

    public var body: some View {
        let scale = height / FermixWordmarkLetters.glyphSize.height

        ZStack(alignment: .topLeading) {
            // The published fill-rule is evenodd; nonzero would fill the R's
            // inner counter solid.
            FermixWordmarkLetters()
                .fill(color, style: FillStyle(eoFill: true))

            ForEach(Array(Self.dotCenters.enumerated()), id: \.offset) { _, center in
                Circle()
                    .fill(Palette.accent.color)
                    .frame(width: Self.dotRadius * 2 * scale, height: Self.dotRadius * 2 * scale)
                    .offset(
                        x: (center.x - Self.dotRadius) * scale,
                        y: (center.y - Self.dotRadius) * scale
                    )
            }
        }
        .frame(width: height * Self.aspectRatio, height: height)
        .accessibilityLabel(ProductStrings[.productName])
    }
}
