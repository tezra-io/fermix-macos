import SwiftUI

/// The ambient ground's colours and geometry (redlines §1.3).
///
/// The backdrop §1.3 published for the artboards, brought back as the ground of
/// the one window the app has: a quiet diagonal wash with two soft glows of the
/// product blue. It exists because glass needs something behind it. The system
/// draws the sidebar, the toolbar and every form section as translucent
/// material, and over a flat grey window that material has nothing to refract,
/// so the whole app read as one grey sheet however much glass was in it.
///
/// The wash is one pair of colours for the whole app. What varies is how hard
/// the two glows are turned up, which is what `AmbientIntensity` names: the
/// table below carries both sets, and the intensity picks the pair.
///
/// The glows are gradients that fall off to clear, never blurred shapes: a blur
/// is a filter the compositor re-runs, and a gradient is drawn once. Nothing
/// here moves, so the ground costs one draw per resize and nothing per frame.
public enum AmbientRecipe {
    /// The wash under the glows, leading top to trailing bottom.
    public static let groundStart = ThemedColor(lightHex: "#eef2fb", darkHex: "#0d1020")
    public static let groundEnd = ThemedColor(lightHex: "#fafbfd", darkHex: "#08080c")

    /// The glow behind the window's leading top corner, where the sidebar and
    /// the toolbar meet. It is the stronger of the two because that corner is
    /// all navigation glass and carries no caption text.
    ///
    /// The alphas are the largest that keep §9's floors at the glow's own
    /// centre, which is the brightest point on dark and the most saturated on
    /// light: `secondary` holds 4.5:1 and `faint` holds 3:1 there, and the gate
    /// in `DesignMaterialsTests` computes both rather than trusting this line.
    public static let glowLeading = ThemedColor(
        light: .rgba(43, 92, 255, 0.10),
        dark: .rgba(43, 92, 255, 0.28)
    )
    /// The glow behind the trailing bottom corner, which is content. Quieter,
    /// and on dark a lighter blue, so the two corners do not read as one lamp.
    public static let glowTrailing = ThemedColor(
        light: .rgba(43, 92, 255, 0.06),
        dark: .rgba(90, 130, 255, 0.14)
    )

    /// The same two glows, same hues and same centres, at about a third of
    /// their alpha (owner, 2026-09-20: on Settings over the gradient "some text
    /// doesnt feel that visible wherever it falls").
    ///
    /// The expressive alphas are the largest that keep §9's floors, and they do
    /// keep them: the defect is not a failed ratio but a moving one. A pane of
    /// thirteen rows crosses the whole wash, so the same caption reads at 6.22:1
    /// at the top of the window and 7.54:1 at the bottom, and the eye reads that
    /// gradient across a page of text as the text fading rather than as the
    /// ground shading. A surface a person works in should sit on nearly one
    /// value, so these are what it sits on: `secondary` moves 7.57 to 8.34 on
    /// dark instead of 6.22 to 7.54, and `faint` clears 3:1 at every point of
    /// both appearances.
    ///
    /// Lowering alpha rather than changing hue, because the two grounds have to
    /// be the same ground: a person crossing from Pet to Settings passes between
    /// them inside one window, and a hue step there is the two-window-colours
    /// defect §5.8 already closed once.
    public static let calmGlowLeading = ThemedColor(
        light: .rgba(43, 92, 255, 0.04),
        dark: .rgba(43, 92, 255, 0.10)
    )
    public static let calmGlowTrailing = ThemedColor(
        light: .rgba(43, 92, 255, 0.02),
        dark: .rgba(90, 130, 255, 0.05)
    )

    public static let glowLeadingCenter = UnitPoint(x: 0.08, y: 0)
    public static let glowTrailingCenter = UnitPoint(x: 1, y: 1.05)

    /// Whether the ground is drawn mirrored across the window's vertical axis:
    /// wash, both glows and both centres, so "leading" and "trailing" above name
    /// the light appearance's corners.
    ///
    /// The rule is that the darker end of the wash meets the rail. On
    /// light the darker end is the blue-washed start, which is already at the
    /// leading edge. On dark it is the near-black end, so the dark ground runs
    /// the other way and the blue rises away from the rail instead of against
    /// it (owner, 2026-09-24: the blue light on the left beside the pitch-black
    /// rail "doesnt feel smooth"). Mirroring rather than recolouring keeps each
    /// glow over the end of the wash it was measured on, so §9's floors hold
    /// unchanged.
    public static func isMirrored(in scheme: FermixColorScheme) -> Bool {
        scheme == .dark
    }
    /// Each glow's reach, as a fraction of the window's longer side, so the
    /// ground keeps its proportions from the 760 by 520 floor to a full screen.
    public static let glowLeadingReach: Double = 0.62
    public static let glowTrailingReach: Double = 0.60
}

/// The window's frame (redlines §5.7): the rail down the leading edge and the
/// band across the top, one colour in one L, with the body set inside it.
///
/// Pitch black on dark, where it is the application icon's own ground: the mark
/// is white on near-black wherever the product draws it, and the frame is where
/// the window wears that. On light it is the standard window grey most Mac apps
/// give their sidebar, the light value of the system's window background
/// (owner, 2026-09-25: "for the light mode let the side bar color be the
/// standard grey most app uses than the pitch black like the dark mode").
///
/// Thin, and only on two sides: the owner liked the thin frame of the Codex
/// app (2026-09-25), a narrow rail and a titlebar band that carry the traffic
/// lights between them. A frame on all four sides, an inset panel, was tried
/// and withdrawn (owner, 2026-09-20: "Lets remove the border, it doesnt fit
/// well with the color of ours").
public enum WindowFrameRecipe {
    public static let fill = ThemedColor(lightHex: "#ececec", darkHex: "#000000")
    /// The rail's symbols.
    public static let ink = ThemedColor(lightHex: "#1d1d1f", darkHex: "#ffffff")
    /// The settings pane list, the second pane inside the frame: a step lighter
    /// than the frame on light and a step off black on dark, so the list reads
    /// as its own pane between the frame and the form.
    public static let pane = ThemedColor(lightHex: "#f8f8f8", darkHex: "#0b0b0e")
}

/// How hard the one ground turns its glows up (redlines §1.3).
///
/// Two settings on one ground, not two grounds. The wash, the hues and the two
/// centres are the same in both, so the window never changes colour: what
/// changes is how far the blue reaches across it.
///
/// `expressive` is the ground as it was published, for the moments the product
/// is being itself: the assistant, recovery, and Pet. Those are single screens
/// a person passes through or watches, with a headline and one action on them,
/// and the glow is what makes them feel like more than a form.
///
/// `calm` is for the surfaces a person reads and works in: Home, Doctor, Logs,
/// the update surface and every settings pane. A page of rows should sit on
/// nearly one value, because a caption that reads lighter at the top of the
/// window than at the bottom reads as the text fading rather than as the ground
/// shading (owner, 2026-09-20). A chat surface, when the window grows one, is
/// this kind of surface and takes the calm ground.
public enum AmbientIntensity: String, CaseIterable, Sendable {
    case expressive
    case calm

    /// Which ground a presentation of the primary window sits on.
    ///
    /// The whole rule, as one function over the two facts the window has: which
    /// presentation is up, and which route is showing inside it. It is a pure
    /// function rather than a branch inside the view so that a gate can walk
    /// every `AppRoute` through it and a route added later has to answer here
    /// instead of falling into whichever branch the compiler reaches first.
    ///
    /// Settings answers before the route does: the route behind the settings
    /// presentation is whatever surface the person will return to, and it is not
    /// what they are looking at.
    public static func forWindow(showingSettings: Bool, route: AppRoute) -> AmbientIntensity {
        guard !showingSettings else { return .calm }

        switch route {
        case .setup, .recovery, .pet: return .expressive
        case .home, .doctor, .logs, .update, .uninstall: return .calm
        }
    }

    /// The two glows this intensity draws. Read by the view and by the contrast
    /// gate, so the ratios §9 asks for are computed on the pair that actually
    /// ships rather than on the pair a test remembered.
    public var leadingGlow: ThemedColor {
        self == .calm ? AmbientRecipe.calmGlowLeading : AmbientRecipe.glowLeading
    }

    public var trailingGlow: ThemedColor {
        self == .calm ? AmbientRecipe.calmGlowTrailing : AmbientRecipe.glowTrailing
    }
}

/// The window's ambient ground: one static wash behind everything the window
/// shows, in every presentation (the app surfaces, Settings, the assistant).
///
/// One ground for one window, which is the rule §5.8 set when the assistant
/// stopped painting a ground of its own: a person moving between Home, Settings
/// and setup never crosses from one window colour to another. The intensity is
/// handed in rather than read here, because which surface is showing is the
/// window's fact and not the recipe's.
///
/// Reduce Transparency and Increase Contrast draw nothing here, so the window
/// shows the system's own colour exactly as it did before this ground existed.
/// Both settings ask for flat, predictable grounds under text, and the honest
/// answer is the one the system already gives.
struct AmbientGround: View {
    var intensity: AmbientIntensity = .expressive
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if !reduceTransparency, contrast != .increased {
            GeometryReader { proxy in
                wash(longerSide: max(proxy.size.width, proxy.size.height))
            }
            .accessibilityHidden(true)
        }
    }

    private func wash(longerSide: Double) -> some View {
        ZStack {
            LinearGradient(
                colors: [AmbientRecipe.groundStart.color, AmbientRecipe.groundEnd.color],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [intensity.leadingGlow.color, .clear],
                center: AmbientRecipe.glowLeadingCenter,
                startRadius: 0,
                endRadius: longerSide * AmbientRecipe.glowLeadingReach
            )
            RadialGradient(
                colors: [intensity.trailingGlow.color, .clear],
                center: AmbientRecipe.glowTrailingCenter,
                startRadius: 0,
                endRadius: longerSide * AmbientRecipe.glowTrailingReach
            )
        }
        .scaleEffect(x: AmbientRecipe.isMirrored(in: colorScheme == .dark ? .dark : .light) ? -1 : 1)
    }
}

extension View {
    /// A scrolling surface gives up the ground it paints for itself, so the
    /// window's shows through the system's translucent sections.
    ///
    /// A grouped `Form` and a `List` each fill their scroll area with an opaque
    /// system colour. Left in place it covers the ambient ground with exactly
    /// the flat sheet the ground replaces. The section cards, their separators
    /// and their row material stay the system's; only the fill behind them goes.
    func showsAmbientGround() -> some View {
        scrollContentBackground(.hidden)
    }
}

extension View {
    /// The window's leading column, drawn as the rail (redlines §5.7).
    ///
    /// The list gives up the system's sidebar material for the rail's own
    /// fill, and takes the window's appearance with it: dark symbols and the
    /// light selection on the light grey, light ones on the dark rail's black.
    /// It sits beside `showsAmbientGround()` because it is the same act with
    /// the other outcome: a scroll container gives up its own fill, here for
    /// the rail's.
    func railColumn() -> some View {
        scrollContentBackground(.hidden)
            .background(WindowFrameRecipe.fill.color)
    }

    /// The settings pane list, drawn as the second pane inside the frame.
    ///
    /// A sidebar list, so its rows, symbols and selection are the system's
    /// own, on the pane's fill rather than a material of its own.
    func paneColumn() -> some View {
        listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .background(WindowFrameRecipe.pane.color)
    }

    /// The frame's band across the top of the body.
    ///
    /// The band sits where the toolbar does, `height` being the column's top
    /// safe area, and the body under it is masked off, so content scrolled up
    /// ends at the band instead of running on under the title and the toolbar's
    /// actions. The system's own toolbar background is not honoured over this
    /// window's clear titlebar, so the band is drawn here.
    func framedByBand(height: Double) -> some View {
        mask {
            VStack(spacing: 0) {
                Color.clear.frame(height: height)
                Color.black
            }
            .ignoresSafeArea()
        }
        .background {
            VStack(spacing: 0) {
                WindowFrameRecipe.fill.color.frame(height: height)
                Color.clear
            }
            .ignoresSafeArea()
        }
    }
}

/// The piece of the rail's fill that turns a square corner of the body into a
/// rounded one: a square with a quarter disc taken out of it.
///
/// It is drawn over the body's corner rather than clipped out of it, so the
/// surface underneath keeps every point of its own width and needs no second
/// ground behind it. The shape is the negative space, which is why it is a
/// `Shape` and not a rounded rectangle: an arc swept from the square's own far
/// corner leaves exactly the wedge the window's rounded corner would have cut,
/// and nothing has to be aligned by eye.
///
/// One shape for both corners: the bottom one is the same path flipped, so the
/// two can never be cut to different radii.
struct FrameCorner: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addArc(
            center: CGPoint(x: rect.maxX, y: rect.maxY),
            radius: rect.width,
            startAngle: .degrees(-90),
            endAngle: .degrees(180),
            clockwise: true
        )
        path.closeSubpath()

        return path
    }
}
