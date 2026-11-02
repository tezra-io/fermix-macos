import SwiftUI

/// The window toolbar's pills: the browser's tabs and its new-tab control,
/// and a surface's search field, each the toolbar's own control height on the
/// toolbar's own glass, so the bar across the window reads as one (owner,
/// 2026-11-01: the tabs the same pill as the search field).
enum ToolbarPillMetrics {
    /// The toolbar's control height, which every pill takes.
    static let height: Double = HitTarget.button
    /// How much of a quieter pill shows: a tab not in front.
    static let quietStrength: Double = 0.55
    /// A surface's search field: wide enough for its prompt, never so wide it
    /// pushes the surface's controls into the toolbar's overflow.
    static let searchWidth: Double = 240
    static let searchGlyph: Double = 12
}

extension View {
    /// A pill of the toolbar's glass behind this view, in `shape`: full where
    /// `strong`, quieter otherwise, the view itself drawn as it is. Before
    /// macOS 26, which has no such glass, the bar's material with a hairline
    /// edge.
    func toolbarPill(in shape: some Shape, strong: Bool) -> some View {
        background {
            ToolbarPillGround(shape: shape)
                .opacity(strong ? 1 : ToolbarPillMetrics.quietStrength)
        }
    }
}

private struct ToolbarPillGround<S: Shape>: View {
    let shape: S

    var body: some View {
        if #available(macOS 26.0, *) {
            Color.clear.glassEffect(.regular, in: shape)
        } else {
            shape.fill(.bar)
                .overlay(shape.stroke(Palette.hairline(.standard).color, lineWidth: Stroke.hairline))
        }
    }
}

/// A surface's search, in its own part of the window's toolbar after its
/// controls, as a pill (`toolbarPill`). It stays over the surface it searches
/// whatever stands beside it, which the system's toolbar search does not: that
/// one always takes the window's trailing end, over the browser pane when it
/// is open.
///
/// The field is the toolbar's height, with the magnifier before its prompt and
/// a clear control while it holds words. Return asks at once, where the
/// surface asks for that, and Escape clears it.
struct ToolbarSearch: ToolbarContent {
    @Binding var text: String
    let prompt: String
    /// What Return does, where the surface searches at once on it.
    var submit: (() -> Void)?

    var body: some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarItem(placement: .primaryAction) { field }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .primaryAction) { field }
        }
    }

    private var field: some View {
        ToolbarSearchField(text: $text, prompt: prompt, submit: submit)
    }
}

struct ToolbarSearchField: View {
    @Binding var text: String
    let prompt: String
    var submit: (() -> Void)?

    var body: some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: ToolbarPillMetrics.searchGlyph, weight: .medium))
                .foregroundStyle(Palette.secondary.color)
                .accessibilityHidden(true)

            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .fermixType(Typography.style(.callout).weight(.regular))
                .onSubmit { submit?() }
                .onExitCommand { text = "" }
                .accessibilityLabel(prompt)

            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: ToolbarPillMetrics.searchGlyph))
                        .foregroundStyle(Palette.faint.color)
                }
                .buttonStyle(.plain)
                .help(ProductStrings[.toolbarSearchClear])
                .accessibilityLabel(ProductStrings[.toolbarSearchClear])
            }
        }
        .padding(.horizontal, Spacing.s)
        .frame(width: ToolbarPillMetrics.searchWidth, height: ToolbarPillMetrics.height)
        .toolbarPill(in: Capsule(), strong: true)
    }
}
