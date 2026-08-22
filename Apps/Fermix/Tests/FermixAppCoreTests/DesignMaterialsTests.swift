import Testing

@testable import FermixAppCore

/// The two glass recipes and the three declared configurations that render
/// them (`M34_DESIGN_SYSTEM_REDLINES.md` §4).
@Suite("Design materials")
struct DesignMaterialsTests {
    @Test("the window recipe matches the redline")
    func windowRecipe() {
        let recipe = GlassRecipe.window

        #expect(recipe.cornerRadius == 14)
        #expect(recipe.tint.light == .rgba(255, 255, 255, 0.66))
        #expect(recipe.tint.dark == .rgba(26, 26, 29, 0.58))
        #expect(recipe.innerHighlight.light == .rgba(255, 255, 255, 0.75))
        #expect(recipe.innerHighlight.dark == .rgba(255, 255, 255, 0.12))
        #expect(recipe.shadow.yOffset == 32)
        #expect(recipe.shadow.cssBlur == 80)
        #expect(recipe.shadow.color.light == .rgba(20, 24, 40, 0.16))
        #expect(recipe.shadow.color.dark == .rgba(0, 0, 0, 0.55))
        #expect(recipe.cssBlurRadius == 30)
        #expect(recipe.saturation == 1.5)
    }

    @Test("the popover recipe matches the redline")
    func popoverRecipe() {
        let recipe = GlassRecipe.popover

        #expect(recipe.cornerRadius == 12)
        #expect(recipe.tint.light == .rgba(255, 255, 255, 0.72))
        #expect(recipe.tint.dark == .rgba(26, 26, 29, 0.62))
        #expect(recipe.innerHighlight.light == .rgba(255, 255, 255, 0.80))
        #expect(recipe.innerHighlight.dark == .rgba(255, 255, 255, 0.12))
        #expect(recipe.shadow.yOffset == 22)
        #expect(recipe.shadow.cssBlur == 60)
        #expect(recipe.shadow.color.light == .rgba(20, 24, 40, 0.20))
        #expect(recipe.shadow.color.dark == .rgba(0, 0, 0, 0.60))
    }

    /// The artboards publish CSS box-shadow blur, which is twice SwiftUI's
    /// shadow radius. Both numbers are carried so a reviewer can check either.
    @Test("the SwiftUI shadow radius is half the published CSS blur")
    func shadowRadiusConversion() {
        #expect(GlassRecipe.window.shadow.radius == 40)
        #expect(GlassRecipe.popover.shadow.radius == 30)
    }

    /// Both recipes share the window border. Only the fill, highlight, shadow,
    /// and radius differ.
    @Test("both recipes use the standard hairline border")
    func bordersAreShared() {
        for recipe in GlassRecipe.allCases {
            #expect(recipe.border == Palette.hairline(.standard), "\(recipe)")
        }
    }

    @Test("the three configurations are selected by accessibility and OS, in that order")
    func pathSelection() {
        #expect(GlassSurface.path(reduceTransparency: true, liquidGlassAvailable: true) == .solid)
        #expect(GlassSurface.path(reduceTransparency: true, liquidGlassAvailable: false) == .solid)
        #expect(GlassSurface.path(reduceTransparency: false, liquidGlassAvailable: true) == .liquidGlass)
        #expect(GlassSurface.path(reduceTransparency: false, liquidGlassAvailable: false) == .material)
    }

    /// Reduce Transparency is a third declared configuration, not a fallback:
    /// it fills with the opaque recessed ground and keeps every other property.
    @Test("the reduce-transparency configuration fills with base200")
    func solidConfigurationUsesBase200() {
        for recipe in GlassRecipe.allCases {
            #expect(GlassSurface.fill(for: .solid, recipe: recipe) == Palette.base200, "\(recipe)")
            #expect(GlassSurface.fill(for: .material, recipe: recipe) == recipe.tint, "\(recipe)")
            #expect(GlassSurface.fill(for: .liquidGlass, recipe: recipe) == recipe.tint, "\(recipe)")
        }
    }

    /// This machine builds against the macOS 26 SDK, so the compiled
    /// availability answer must be the real one rather than a constant.
    @Test("liquid glass availability is answered by the running OS")
    func availabilityIsRuntimeResolved() {
        if #available(macOS 26.0, *) {
            #expect(GlassSurface.liquidGlassAvailable)
        } else {
            #expect(!GlassSurface.liquidGlassAvailable)
        }
    }

    /// The primary button is the one control that carries a shadow inside a
    /// window; secondary carries none.
    @Test("the button recipes match the redline")
    func buttonRecipes() {
        #expect(ButtonRecipe.primary(.onboarding).height == 44)
        #expect(ButtonRecipe.primary(.onboarding).cornerRadius == 10)
        #expect(ButtonRecipe.primary(.onboarding).labelStyle.size == 15)
        #expect(ButtonRecipe.primary(.onboarding).labelStyle.weight == .semibold)
        #expect(ButtonRecipe.primary(.inWindow).height == 36)
        #expect(ButtonRecipe.primary(.inWindow).cornerRadius == 9)
        #expect(ButtonRecipe.primary(.inWindow).labelStyle.size == 13)

        #expect(ButtonRecipe.primaryFill == Palette.accent)
        #expect(ButtonRecipe.primaryPressedFill == Palette.accentPressed)
        #expect(ButtonRecipe.primaryShadow.cssBlur == 18)
        #expect(ButtonRecipe.primaryShadow.yOffset == 6)
        #expect(ButtonRecipe.primaryPressedShadow.cssBlur == 10)
        #expect(ButtonRecipe.primaryPressedShadow.yOffset == 3)
        #expect(ButtonRecipe.primaryInnerHighlight == .rgba(255, 255, 255, 0.25))

        #expect(ButtonRecipe.secondary(.inWindow).height == 36)
        #expect(ButtonRecipe.secondary(.inWindow).labelStyle.weight == .medium)
        #expect(ButtonRecipe.secondaryFill == Palette.buttonFill)
        #expect(ButtonRecipe.secondaryBorder == Palette.buttonBorder)
    }
}
