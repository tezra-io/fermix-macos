import SwiftUI

/// A window or panel container: the design's glass, and nothing else.
///
/// On macOS 26 the whole surface sits inside one `GlassEffectContainer` so
/// sibling glass elements share a material and morph as one. Under Reduce
/// Transparency there is no glass to contain, so the container is not built.
public struct GlassChrome<Content: View>: View {
    private let recipe: GlassRecipe
    private let content: Content

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    public init(_ recipe: GlassRecipe, @ViewBuilder content: () -> Content) {
        self.recipe = recipe
        self.content = content()
    }

    public var body: some View {
        chrome
            .accessibilityIdentifier(DesignComponent.glassChrome.accessibilityIdentifier)
            .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var chrome: some View {
        let path = GlassSurface.path(
            reduceTransparency: reduceTransparency,
            liquidGlassAvailable: GlassSurface.liquidGlassAvailable
        )

        // One card is one glass surface: a `GlassEffectContainer` here would
        // coalesce the card's effect into a container-level layer that
        // composites OVER the card's own content (observed live on macOS 26.5:
        // the window rendered as a bare lensing slab with the content ghosted
        // into the backdrop sample). Containers are for coalescing *sibling*
        // glass shapes, so the card applies its recipe directly.
        content.fermixGlass(recipe)
    }
}

/// The desktop behind the windows, and the stage every onboarding screen sits
/// on: the 160-degree gradient plus this surface's blue blobs.
public struct BackdropView: View {
    private let surface: BackdropSurface

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(_ surface: BackdropSurface) {
        self.surface = surface
    }

    public var body: some View {
        ZStack {
            LinearGradient(
                colors: [Backdrop.gradient.start.color, Backdrop.gradient.end.color],
                startPoint: .top,
                endPoint: .bottom
            )
            .rotationEffect(.degrees(Backdrop.gradientAngleDegrees - 180))
            .scaleEffect(2)

            ForEach(Array(Backdrop.blobs(surface).enumerated()), id: \.offset) { index, blob in
                BlobView(blob: blob, drifts: drifts, role: index == 0 ? .blobDriftA : .blobDriftB)
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    private var drifts: Bool {
        Backdrop.drifts(surface) && !reduceMotion
    }
}

private struct BlobView: View {
    let blob: BackdropBlob
    let drifts: Bool
    let role: MotionRole

    @State private var drifted = false

    var body: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [blob.color.color, .clear],
                    center: .center,
                    startRadius: 0,
                    endRadius: blob.diameter / 2 * blob.transparentStop
                )
            )
            .frame(width: blob.diameter, height: blob.diameter)
            .blur(radius: blob.blurRadius)
            .offset(x: blob.resolvedOffset.width, y: blob.resolvedOffset.height)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
            .scaleEffect(drifted ? driftScale : 1)
            .offset(x: drifted ? driftOffset.width : 0, y: drifted ? driftOffset.height : 0)
            .onAppear {
                guard drifts, let animation = Motion(reduceMotion: false).animation(role) else { return }

                withAnimation(animation) { drifted = true }
            }
    }

    private var alignment: Alignment {
        blob.anchor == .topLeading ? .topLeading : .bottomTrailing
    }

    private var driftScale: Double {
        role == .blobDriftA ? 1.08 : 1.06
    }

    private var driftOffset: CGSize {
        role == .blobDriftA ? CGSize(width: 60, height: 30) : CGSize(width: -50, height: -24)
    }
}
