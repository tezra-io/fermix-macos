import AppKit
import SwiftUI

/// Which glass every sheet wears (owner, 2026-10-16: every popup in the app
/// wears the app's glass, consistent with the window frame).
///
/// Two recipes behind one switch, for the owner to choose between from
/// captures, the way the frame's tint was chosen. The switch is not a setting:
/// a launch takes `standard`, and only a fixture launch can name the other
/// (`FixtureLaunchRequest.sheetGroundFlag`).
public enum SheetGroundRecipe: String, CaseIterable, Sendable {
    /// The window frame's own glass, `FrameGlass`: the system's sidebar
    /// material under `WindowFrameRecipe.glassTint`.
    case frame
    /// The system's Liquid Glass, the material macOS gives a surface floating
    /// over content.
    case liquid

    /// The recipe every launch takes unless a fixture launch names the other.
    public static let standard: SheetGroundRecipe = .frame

    /// The Liquid Glass's corner radius: the sheet window's own, so the glass's
    /// rim runs along the sheet's edge instead of being cut at each corner.
    /// Measured on macOS 27, where a sheet's corner is the window's 16pt.
    static let liquidCornerRadius: Double = 16
}

extension EnvironmentValues {
    /// The recipe every window's root carries (`AppSurfaces`), which a sheet
    /// inherits from the view that presents it.
    public var sheetGroundRecipe: SheetGroundRecipe {
        get { self[SheetGroundRecipeKey.self] }
        set { self[SheetGroundRecipeKey.self] = newValue }
    }
}

private struct SheetGroundRecipeKey: EnvironmentKey {
    static let defaultValue = SheetGroundRecipe.standard
}

extension View {
    /// The ground of a sheet, applied once at the root of every sheet's content
    /// in place of the system's flat panel.
    ///
    /// The system keeps its own sheet material under the presentation's
    /// background, and there is no public way to remove it, so the recipe is
    /// laid over it edge to edge. Each recipe gives its own answer to Reduce
    /// Transparency and Increase Contrast: the frame's glass its plain fill,
    /// and Liquid Glass the system's.
    ///
    /// Being every sheet's root, it also states the row actions for the whole
    /// sheet (`rowActions`), so a button in a sheet that names no style is the
    /// secondary capsule rather than the system button the window's tint
    /// turns blue (owner, 2026-10-18).
    func sheetGround() -> some View {
        modifier(SheetGround())
    }
}

private struct SheetGround: ViewModifier {
    @Environment(\.sheetGroundRecipe) private var recipe

    func body(content: Content) -> some View {
        content.rowActions().presentationBackground { ground }
    }

    @ViewBuilder
    private var ground: some View {
        switch recipe {
        case .frame: FrameGlass()
        case .liquid: SheetLiquidGlass()
        }
    }
}

/// The system's Liquid Glass, on macOS 26 and later. The macOS 15 floor has no
/// Liquid Glass, so there the switch has only the frame's glass to show.
private struct SheetLiquidGlass: View {
    var body: some View {
        if #available(macOS 26.0, *) {
            LiquidGlassMaterial()
        } else {
            FrameGlass()
        }
    }
}

@available(macOS 26.0, *)
private struct LiquidGlassMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSGlassEffectView {
        let view = NSGlassEffectView()
        view.cornerRadius = SheetGroundRecipe.liquidCornerRadius
        return view
    }

    func updateNSView(_ nsView: NSGlassEffectView, context: Context) {}
}
