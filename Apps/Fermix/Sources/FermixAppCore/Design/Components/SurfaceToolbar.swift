import SwiftUI

/// One surface's trailing toolbar, built from the `CommandTable` (M34 §3.2).
///
/// The leading side is the system's: the sidebar toggle and the inline title
/// come from `NavigationSplitView` and the window, not from here. What this
/// draws is the trailing side, in the published order — one tinted primary
/// action while its condition holds, one secondary group, one overflow menu —
/// and a status item whose text never sits on glass.
struct SurfaceToolbar: ToolbarContent {
    let spec: ToolbarSpec
    let router: any CommandPerforming
    /// A sentence about what the surface is doing right now, where it has one.
    var statusText: String?

    var body: some ToolbarContent {
        statusItem

        // The tinted action exists only while its condition holds (M34 §3.2).
        // The table decides whether the surface carries one at all; this is the
        // second half of the same rule, for a command whose own condition has
        // stopped holding. Neither draws it dimmed: a permanently dead
        // prominent button is worse than no button.
        if let primary = spec.primary, router.canPerform(primary) {
            ToolbarItem(placement: .primaryAction) {
                PrimaryToolbarButton(title: router.toolbarTitle(of: primary)) {
                    router.perform(primary)
                }
            }
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

    /// Status text sits beside the toolbar's glass groups, never on one: on
    /// macOS 26 that is `sharedBackgroundVisibility(.hidden)`, and on macOS 15
    /// it is a plain `Text` with no background modifier at all.
    @ToolbarContentBuilder
    private var statusItem: some ToolbarContent {
        if let statusText {
            if #available(macOS 26.0, *) {
                ToolbarItem(placement: .status) { statusLabel(statusText) }
                    .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .status) { statusLabel(statusText) }
            }
        }
    }

    private func statusLabel(_ text: String) -> some View {
        Text(text)
            .fermixType(Typography.style(.calloutSmall))
            .foregroundStyle(Palette.secondary.color)
            .accessibilityAddTraits(.updatesFrequently)
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

/// The one tinted action a surface may carry: prominent glass on macOS 26, and
/// `borderedProminent` on the macOS 15 floor.
///
/// It sets no tint of its own. The product accent reaches it from the window's
/// root (`ProductTinted`), which is what keeps this button, the switches under
/// it and the list selection beside it all one blue.
struct PrimaryToolbarButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        if #available(macOS 26.0, *) {
            Button(title, action: action).buttonStyle(.glassProminent)
        } else {
            Button(title, action: action).buttonStyle(.borderedProminent)
        }
    }
}
