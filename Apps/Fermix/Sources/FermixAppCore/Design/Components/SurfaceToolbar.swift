import SwiftUI

/// One surface's trailing toolbar, built from the `CommandTable` (M34 §3.2).
///
/// The leading side is the system's: the sidebar toggle and the inline title
/// come from `NavigationSplitView` and the window, not from here. What this
/// draws is the trailing side, in the published order: one prominent primary
/// action while its condition holds, one secondary group, one overflow menu,
/// and a status item whose text never sits on glass.
struct SurfaceToolbar: ToolbarContent {
    let spec: ToolbarSpec
    let router: any CommandPerforming
    /// A sentence about what the surface is doing right now, where it has one.
    var statusText: String?

    var body: some ToolbarContent {
        if let statusText {
            ToolbarStatus(text: statusText)
        }

        // The prominent action exists only while its condition holds (M34 §3.2).
        // The table decides whether the surface carries one at all; this is the
        // second half of the same rule, for a command whose own condition has
        // stopped holding. Neither draws it dimmed: a permanently dead
        // prominent button is worse than no button.
        if let primary = spec.primary, router.canPerform(primary) {
            primaryItem(primary)
        }

        if !spec.secondary.isEmpty {
            ToolbarItemGroup(placement: .primaryAction) {
                ForEach(spec.secondary, id: \.self) { command in
                    button(command)
                }
            }
        }

        // macOS 26 separates the trailing groups with a fixed spacer so each
        // gets its own glass. The macOS 15 form is exactly what is already
        // written above and below: two `ToolbarItemGroup` placements.
        if #available(macOS 26.0, *), !spec.secondary.isEmpty, !spec.more.isEmpty {
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }

        if !spec.more.isEmpty {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    ForEach(spec.more, id: \.self) { command in
                        button(command)
                    }
                } label: {
                    Label(ProductStrings[.toolbarMore], systemImage: "ellipsis")
                }
                .accessibilityLabel(ProductStrings[.toolbarMore])
            }
        }
    }

    /// The one prominent action, and the one place the toolbar's shared glass is
    /// turned off behind a control.
    ///
    /// The action draws its own capsule now (§4.4), so on macOS 26 the toolbar's
    /// shared background is exactly one ring too many: left in, it drew a
    /// second, larger capsule of glass around the button's own. Hiding it is the
    /// same modifier, for the same reason, that keeps the status sentence off
    /// glass below.
    ///
    /// The macOS 15 form is the same item without the modifier, because the
    /// floor has no shared background to hide.
    @ToolbarContentBuilder
    private func primaryItem(_ primary: AppCommand) -> some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarItem(placement: .primaryAction) { primaryButton(primary) }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .primaryAction) { primaryButton(primary) }
        }
    }

    private func primaryButton(_ primary: AppCommand) -> some View {
        PrimaryToolbarButton(title: router.toolbarTitle(of: primary)) { router.perform(primary) }
    }

    /// A secondary or overflow control. Both are plain buttons: the system
    /// draws the group, and the app draws no container of its own.
    private func button(_ command: AppCommand) -> some View {
        Button {
            router.perform(command)
        } label: {
            if let symbol = CommandTable.symbol(of: command) {
                Label(router.toolbarTitle(of: command), systemImage: symbol)
            } else {
                Text(router.toolbarTitle(of: command))
            }
        }
        .disabled(!router.canPerform(command))
        .accessibilityLabel(router.toolbarTitle(of: command))
        .help(helpText(for: command))
    }

    /// The help tag a control carries, or nothing. `Text("")` draws no tag, so
    /// the modifier is applied once rather than behind a branch that would make
    /// two toolbars out of one.
    private func helpText(for command: AppCommand) -> String {
        CommandTable.toolbarHelpKey(of: command).map { ProductStrings[$0] } ?? ""
    }
}

/// A sentence about what is happening right now, in the toolbar's status
/// placement.
///
/// One drawing for every such sentence, so a surface's own (`Running checks`)
/// and the window's (`Restarting Fermix`) are the same type, ink and placement.
/// Status text sits beside the toolbar's glass groups, never on one: on macOS 26
/// that is `sharedBackgroundVisibility(.hidden)`, and on macOS 15 it is a plain
/// label with no background modifier at all.
struct ToolbarStatus: ToolbarContent {
    let text: String
    /// Whether the sentence names work that is still running, which puts the
    /// activity mark in front of it. The mark is decorative: the sentence is
    /// what VoiceOver reads.
    var showsProgress = false

    var body: some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarItem(placement: .status) { label }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .status) { label }
        }
    }

    private var label: some View {
        HStack(spacing: Spacing.xs) {
            if showsProgress {
                ActivityMark().accessibilityHidden(true)
            }

            Text(text)
                .fermixType(Typography.style(.calloutSmall))
                .foregroundStyle(Palette.secondary.color)
                .accessibilityAddTraits(.updatesFrequently)
        }
    }
}

/// The one prominent action a surface may carry: the product's own primary
/// action, at the in-window size, drawn exactly as a surface's own primary
/// action is. That size is the toolbar's own control height: at the row size it
/// stood ten points shorter than the system controls beside it.
///
/// It was the system's prominent style taking the window's root tint, which made
/// it the one blue-filled button in the toolbar. §4.4 took the blue off the
/// primary action altogether (owner, 2026-09-20: the blue on `Continue setup`
/// "doesnt match with the theme"), and once the fill is the product's own
/// monochrome there is no longer a system style that draws it: the app's
/// component is the only drawing of a primary action there is, so the toolbar
/// takes that one rather than a second copy of it.
///
/// `isDefault: false` is the one difference from a surface's. Return belongs to
/// whatever the surface is asking, and a toolbar action stands beside that
/// rather than confirming it, so this button never takes the key.
struct PrimaryToolbarButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        PrimaryAction(title, size: .inWindow, isDefault: false, action: action)
    }
}
