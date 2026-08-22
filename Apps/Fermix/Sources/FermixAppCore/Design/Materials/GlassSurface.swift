import SwiftUI

/// Which of the three declared glass configurations a surface is drawing.
///
/// These are configurations, not a fallback chain: exactly one applies, it is
/// selected before anything is drawn, and none of them is a degraded attempt at
/// another.
public enum GlassPath: String, CaseIterable, Sendable {
    /// macOS 26: the system Liquid Glass material, tinted by the recipe.
    case liquidGlass
    /// The macOS 15 floor: `.ultraThinMaterial` with the recipe fill as tint.
    case material
    /// Reduce Transparency: an opaque fill, same border, highlight, and shadow.
    case solid
}

/// The only place either material path is written
/// (`M34_DESIGN_SYSTEM_REDLINES.md` §4.3).
public enum GlassSurface {
    /// Whether the running OS has Liquid Glass. Compiled availability, not a
    /// build flag, so a binary built on the macOS 26 SDK still takes the
    /// Material path when it runs on macOS 15.
    public static var liquidGlassAvailable: Bool {
        if #available(macOS 26.0, *) {
            return true
        }

        return false
    }

    /// Accessibility wins over the OS: Reduce Transparency means opaque on
    /// every macOS version.
    public static func path(reduceTransparency: Bool, liquidGlassAvailable: Bool) -> GlassPath {
        if reduceTransparency {
            return .solid
        }

        return liquidGlassAvailable ? .liquidGlass : .material
    }

    /// What fills the shape on a given path. The opaque configuration uses the
    /// recessed ground rather than a flattened version of the glass tint.
    public static func fill(for path: GlassPath, recipe: GlassRecipe) -> ThemedColor {
        switch path {
        case .solid: return Palette.base200
        case .material, .liquidGlass: return recipe.tint
        }
    }
}

/// Applies one glass recipe: fill, hairline border, top inner highlight, and
/// drop shadow. Identical on all three paths except the fill.
public struct GlassBackground: ViewModifier {
    private let recipe: GlassRecipe

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    public init(recipe: GlassRecipe) {
        self.recipe = recipe
    }

    public func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: recipe.cornerRadius, style: .continuous)
        let path = GlassSurface.path(
            reduceTransparency: reduceTransparency,
            liquidGlassAvailable: GlassSurface.liquidGlassAvailable
        )

        return content
            .background(fill(shape: shape, path: path))
            .overlay(highlight(shape: shape))
            .overlay(shape.strokeBorder(borderColor.color, lineWidth: Stroke.hairline))
            .clipShape(shape)
            .shadow(
                color: recipe.shadow.color.color,
                radius: recipe.shadow.radius,
                y: recipe.shadow.yOffset
            )
    }

    private var borderColor: ThemedColor {
        Palette.hairline(.standard, increaseContrast: contrast == .increased)
    }

    /// One branch per configuration, and the availability check is the branch
    /// rather than a guard inside one: a `#available` with an empty else would
    /// be an unreachable path that silently drew nothing.
    @ViewBuilder
    private func fill(shape: RoundedRectangle, path: GlassPath) -> some View {
        let tint = GlassSurface.fill(for: path, recipe: recipe).color

        if path == .solid {
            shape.fill(tint)
        } else if #available(macOS 26.0, *) {
            shape.fill(tint).glassEffect(.regular, in: shape)
        } else {
            shape.fill(.ultraThinMaterial).overlay(shape.fill(tint))
        }
    }

    /// A one-point top-edge gradient stroke: the SwiftUI equivalent of the
    /// artboards' `inset 0 1 0` highlight.
    private func highlight(shape: RoundedRectangle) -> some View {
        shape.strokeBorder(
            LinearGradient(
                colors: [recipe.innerHighlight.color, .clear],
                startPoint: .top,
                endPoint: UnitPoint(x: 0.5, y: 0.04)
            ),
            lineWidth: Stroke.hairline
        )
    }
}

extension View {
    /// Puts this view on glass. Call it once per surface; nesting two recipes
    /// would stack two materials.
    public func fermixGlass(_ recipe: GlassRecipe) -> some View {
        modifier(GlassBackground(recipe: recipe))
    }
}
