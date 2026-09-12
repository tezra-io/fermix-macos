import SwiftUI

/// Whether the primary window is showing the app or its settings, and what
/// leaving settings returns to (decision D1, owner directive of 2026-09-03:
/// "the setup/settings should launch in the same app/window").
///
/// A model rather than a `@State` flag inside the window view, because three
/// things outside the view enter settings — a `fermix://settings/<pane>` url,
/// Command-comma, and an Attention or Doctor deep link — and the route the user
/// came from has to survive a view rebuild. It owns *whether* settings shows;
/// `SettingsModel` goes on owning *which pane*, so there is still one owner of
/// the selected pane.
@MainActor
public final class SettingsPresentation: ObservableObject {
    @Published public private(set) var isShowing = false

    /// The surface to come back to. Recorded on the way in, so the back control
    /// returns to what the user left rather than to Home.
    @Published public private(set) var returnRoute: AppRoute = .home

    /// Grows the window on the way in (decision D3). A closure rather than a
    /// reference to the coordinator, because the coordinator builds this.
    private let grow: () -> Void

    public init(grow: @escaping () -> Void = {}) {
        self.grow = grow
    }

    /// Enters settings from the surface the window is showing.
    ///
    /// The return route is recorded only on the way in: entering twice — a url
    /// while settings is already open, say — must not record the settings
    /// presentation as the place to come back to.
    public func enter(from route: AppRoute) {
        if !isShowing {
            returnRoute = route
            isShowing = true
        }

        grow()
    }

    /// Leaves settings. Answers the route to restore, so the caller writes the
    /// model once rather than reading a flag and guessing.
    @discardableResult
    public func leave() -> AppRoute {
        isShowing = false

        return returnRoute
    }
}

/// The settings layout, inside the primary window (redlines §5.8).
///
/// It is the retired Settings window's own tree re-rooted here: the same fixed
/// pane column, the same sidebar-placed search, the same one grouped form per
/// pane, the same banners. What went away is a window, not a surface.
struct SettingsPaneColumn: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        List(selection: selection) {
            ForEach(SettingsPaneGroup.allCases, id: \.self) { group in
                let panes = model.panes(matching: model.searchText, in: group)

                if !panes.isEmpty {
                    Section(group.title) {
                        ForEach(panes) { pane in
                            Label(pane.title, systemImage: pane.systemImage)
                                .tag(pane)
                        }
                    }
                }
            }
        }
        // Decision D4 is the window's rule and not one pane's: the thirteen
        // panes are taller than the 640 point default the window opens at, so
        // the column scrolls, and a column that scrolls draws the same inline
        // scroller the form was told not to. Same two modifiers, same reason.
        .scrollIndicators(.never)
        .paneScrollEdges()
        .navigationSplitViewColumnWidth(
            min: WindowMetrics.settingsSidebarWidth,
            ideal: WindowMetrics.settingsSidebarWidth,
            max: WindowMetrics.settingsSidebarWidth
        )
        .frame(width: WindowMetrics.settingsSidebarWidth)
    }

    /// The column selects a pane and never nothing: clearing the selection
    /// would leave the window with no title and no detail.
    var selection: Binding<SettingsPane?> {
        Binding(
            get: { model.selectedPane },
            set: { pane in
                guard let pane else { return }

                // List can write during reconciliation. Queue every request,
                // including a return to the current pane while another is pending.
                DispatchQueue.main.async { [model] in
                    guard pane != model.selectedPane else { return }

                    model.selectedPane = pane
                }
            }
        )
    }
}

/// The content column: the banners, then the pane.
struct SettingsDetailView: View {
    @ObservedObject var model: SettingsModel
    let router: any CommandPerforming
    let openRecovery: () -> Void

    var body: some View {
        SettingsPaneView(pane: model.selectedPane, model: model, router: router)
            .settingsBanners(model: model, openRecovery: openRecovery)
            .task(id: model.selectedPane) { await model.paneAppeared(model.selectedPane) }
    }
}

/// The one new toolbar item settings adds: a chevron at the leading edge,
/// returning to the surface the user came from (redlines §5.8).
///
/// The chevron alone, drawn the way a `NavigationStack` draws its own back
/// button (owner directive of 2026-09-03: "The back button < Fermix isnt
/// aligned properly, i think just the < arrow should be fine"). The word beside
/// it was the misalignment: a chevron glyph and a 13pt word have different
/// optical centres, so the pair sat low against the inline title however the
/// label was styled, and the system's own back control carries no word either.
///
/// It keeps the system's own button chrome rather than being flattened: that
/// is what supplies the standard leading-edge position, the standard hit
/// target, and the vertical centring against the title. The name survives
/// where it is still read, which is VoiceOver.
///
/// The glyph is `chevron.backward`, not `chevron.left`: the system's own back
/// button is the direction-relative symbol, which mirrors under a
/// right-to-left layout while the named-side symbol keeps pointing at the
/// trailing edge.
///
/// There is no second way back and no close button, because nothing is closing.
struct SettingsBackControl: ToolbarContent {
    let back: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button(action: back) {
                Image(systemName: "chevron.backward")
                    .fontWeight(.semibold)
            }
            .accessibilityLabel(ProductStrings[.settingsBackAccessibility])
        }
    }
}
