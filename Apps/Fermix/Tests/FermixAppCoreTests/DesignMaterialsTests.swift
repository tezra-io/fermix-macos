import Testing

@testable import FermixAppCore

/// The button geometry of `M34_DESIGN_SYSTEM_REDLINES.md` §4.4.
///
/// The two window glass recipes and the three configurations that rendered them
/// left with the assistant's glass card (owner decision 1): no window draws a
/// container of its own, so the recipes applied to nothing.
@Suite("Design materials")
struct DesignMaterialsTests {
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
        #expect(ButtonRecipe.primaryHoverFill == Palette.accentHover)
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
