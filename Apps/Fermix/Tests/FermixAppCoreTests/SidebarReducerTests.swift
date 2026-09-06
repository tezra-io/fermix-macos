import Foundation
import Testing

@testable import FermixAppCore

/// The sidebar's collapse rule (M34 §6), as a pure function.
///
/// Width-driven collapse, the hysteresis band between the two thresholds, and
/// an explicit hide that nothing overrides are exactly the kind of rule that is
/// invisible inside a view body, so they are proven as values here.
@Suite("Sidebar reducer")
struct SidebarReducerTests {
    private let shown = SidebarState(visibility: .all, collapsedByWidth: false, hiddenByUser: false)

    @Test("first launch shows the sidebar, and only a persisted hide starts it collapsed")
    func firstLaunch() {
        #expect(SidebarReducer.initial(persistedVisible: nil) == shown)
        #expect(SidebarReducer.initial(persistedVisible: true) == shown)
        #expect(
            SidebarReducer.initial(persistedVisible: false)
                == SidebarState(visibility: .detailOnly, collapsedByWidth: false, hiddenByUser: true)
        )
    }

    @Test("the window collapses below 840 points and remembers that width did it")
    func collapsesBelowThreshold() {
        let narrow = SidebarReducer.reduce(shown, .widthChanged(839))

        #expect(narrow.visibility == .detailOnly)
        #expect(narrow.collapsedByWidth)
        #expect(!narrow.hiddenByUser)
        #expect(SidebarReducer.collapseWidth == 840)
    }

    /// The band is what stops a window parked on the threshold flickering.
    ///
    /// The two thresholds move with decision D3's 760 pt window minimum and
    /// keep their offsets from it, +80 and +140. Left at 720 and 780 both would
    /// be dead: a window that can never be narrower than 760 never crosses 720.
    @Test("nothing changes between the collapse and restore thresholds")
    func hysteresisBand() {
        #expect(SidebarReducer.reduce(shown, .widthChanged(840)) == shown)
        #expect(SidebarReducer.reduce(shown, .widthChanged(880)) == shown)
        #expect(SidebarReducer.restoreWidth - SidebarReducer.collapseWidth == 60)

        let collapsed = SidebarReducer.reduce(shown, .widthChanged(820))
        #expect(SidebarReducer.reduce(collapsed, .widthChanged(880)) == collapsed)
        #expect(SidebarReducer.reduce(collapsed, .widthChanged(900)) == collapsed)
    }

    @Test("a width-driven collapse comes back above 900 points")
    func restoresAboveThreshold() {
        let collapsed = SidebarReducer.reduce(shown, .widthChanged(820))
        let wide = SidebarReducer.reduce(collapsed, .widthChanged(901))

        #expect(wide == shown)
    }

    /// The rule the design is emphatic about: an explicit hide is a decision,
    /// and widening the window must never undo it.
    @Test("an explicit hide is never overridden by width")
    func explicitHideSurvivesEveryWidth() {
        let hidden = SidebarReducer.reduce(shown, .userSet(.detailOnly))

        #expect(hidden.visibility == .detailOnly)
        #expect(hidden.hiddenByUser)
        #expect(!hidden.collapsedByWidth)

        for width in [400.0, 820.0, 880.0, 1_000.0, 2_000.0] {
            #expect(SidebarReducer.reduce(hidden, .widthChanged(width)) == hidden, "\(width)")
        }
    }

    /// A user who shows the sidebar again clears the hide, and width owns it
    /// once more.
    @Test("showing the sidebar by hand hands the rule back to width")
    func explicitShowClearsTheHide() {
        let hidden = SidebarReducer.reduce(shown, .userSet(.detailOnly))
        let reshown = SidebarReducer.reduce(hidden, .userSet(.all))

        #expect(reshown == shown)
        #expect(SidebarReducer.reduce(reshown, .widthChanged(600)).collapsedByWidth)
    }

    /// The split view collapses the sidebar itself in a window too narrow to
    /// hold both columns. That is the width rule's collapse arriving through
    /// SwiftUI, so it is reversible and carries no decision.
    @Test("a collapse the split view made is a width collapse, not a decision")
    func systemCollapseIsAWidthCollapse() {
        let collapsed = SidebarReducer.reduce(shown, .systemCollapsed)

        #expect(collapsed.visibility == .detailOnly)
        #expect(collapsed.collapsedByWidth)
        #expect(!collapsed.hiddenByUser)
        #expect(SidebarReducer.reduce(collapsed, .widthChanged(901)) == shown)

        let hidden = SidebarReducer.reduce(shown, .userSet(.detailOnly))
        #expect(SidebarReducer.reduce(hidden, .systemCollapsed) == hidden, "it never rewrites a decision")
    }

    /// A collapse the user made cannot be restored by width, and a collapse
    /// width made cannot be recorded as a decision. The state refuses to hold
    /// both reasons at once.
    @Test("a collapse has exactly one reason")
    func oneReasonPerCollapse() {
        let byWidth = SidebarReducer.reduce(shown, .widthChanged(500))
        let byUser = SidebarReducer.reduce(shown, .userSet(.detailOnly))

        #expect(byWidth.collapsedByWidth != byWidth.hiddenByUser)
        #expect(byUser.collapsedByWidth != byUser.hiddenByUser)
    }
}

/// The model over the reducer: what it persists, and what it tells the window.
@Suite("Sidebar model")
@MainActor
struct SidebarModelTests {
    @Test("only an explicit choice is persisted, and a width collapse is not")
    func persistsOnlyDecisions() {
        let store = InMemorySidebarStore()
        let model = SidebarModel(store: store)

        model.widthChanged(600)
        #expect(model.visibility == .detailOnly)
        #expect(store.sidebarVisible == nil, "a narrow window is not a decision")

        model.userSet(.detailOnly)
        #expect(store.sidebarVisible == false)

        model.userSet(.all)
        #expect(store.sidebarVisible == true)
    }

    @Test("a persisted hide is restored on the next launch")
    func restoresThePersistedHide() {
        let store = InMemorySidebarStore()
        store.sidebarVisible = false

        #expect(SidebarModel(store: store).visibility == .detailOnly)
    }

    /// The width rule moves the sidebar and nothing else. Decision D3 gives the
    /// window one floor, so a collapse no longer reports anywhere: the model
    /// owns the visibility and the window's minimum is a constant.
    @Test("the width rule moves the visibility and reports nowhere")
    func widthMovesTheVisibilityOnly() {
        let model = SidebarModel(store: InMemorySidebarStore())

        model.widthChanged(1_000)
        #expect(model.visibility == .all, "a width that changes nothing changes nothing")

        model.widthChanged(700)
        #expect(model.visibility == .detailOnly)
        #expect(model.state.collapsedByWidth)

        model.widthChanged(1_000)
        #expect(model.visibility == .all)

        model.toggle()
        #expect(model.visibility == .detailOnly)
        #expect(model.state.hiddenByUser)
    }

    @Test("a zero width is ignored rather than collapsing the sidebar on first layout")
    func zeroWidthIsIgnored() {
        let model = SidebarModel(store: InMemorySidebarStore())

        model.widthChanged(0)

        #expect(model.visibility == .all)
    }

    /// SwiftUI writes the same value for two different things: a person pressing
    /// the system toggle, and the split view collapsing the sidebar because the
    /// window cannot hold both columns. Recording the second as a decision would
    /// make it permanent, because the reducer never restores an explicit hide.
    @Test("a collapse SwiftUI writes in a narrow window is not recorded as a decision")
    func aNarrowWriteIsNotADecision() {
        let store = InMemorySidebarStore()
        let model = SidebarModel(store: store)

        // No width reported yet: the split view can only have collapsed because
        // the window is too narrow to hold both columns.
        model.visibilityWritten(.detailOnly)

        #expect(model.visibility == .detailOnly)
        #expect(model.state.collapsedByWidth)
        #expect(store.sidebarVisible == nil, "the split view's own collapse was persisted")

        // And it is reversible, which is the whole point of not persisting it.
        model.widthChanged(1_000)
        #expect(model.visibility == .all)
    }

    /// Above the collapse width the split view has no reason to collapse, so the
    /// write is a person's and outlives every resize.
    @Test("a collapse written in a wide window is the user, and it is persisted")
    func aWideWriteIsADecision() {
        let store = InMemorySidebarStore()
        let model = SidebarModel(store: store)

        model.widthChanged(900)
        model.visibilityWritten(.detailOnly)

        #expect(model.state.hiddenByUser)
        #expect(store.sidebarVisible == false)

        model.widthChanged(1_200)
        #expect(model.visibility == .detailOnly, "width restored a decision")
    }

    /// The reviewer's case, in the world the width rule already owns: at 700 the
    /// reducer has collapsed the sidebar itself, so SwiftUI's write agrees with
    /// the model and changes nothing.
    @Test("a write that agrees with the model records nothing")
    func anAgreeingWriteIsANoOp() {
        let store = InMemorySidebarStore()
        let model = SidebarModel(store: store)

        model.widthChanged(700)
        model.visibilityWritten(.detailOnly)

        #expect(store.sidebarVisible == nil)
        #expect(model.state.collapsedByWidth)
    }

    /// Asking for the sidebar back is always a person: nothing in the system
    /// re-expands a sidebar the app is holding closed.
    @Test("a show written through the binding is the user")
    func aShowWriteIsADecision() {
        let store = InMemorySidebarStore()
        let model = SidebarModel(store: store)

        model.widthChanged(600)
        model.visibilityWritten(.all)

        #expect(model.visibility == .all)
        #expect(store.sidebarVisible == true)
    }

    /// The key is the one M34 §6 names, so a build that renames it loses the
    /// operator's choice silently.
    @Test("the persisted key is the published one")
    func persistedKey() {
        #expect(UserDefaultsSidebarStore.key == "main.sidebar.visible")
    }
}

/// A store with no host state: the suite must never read or write the
/// operator's real defaults.
@MainActor
final class InMemorySidebarStore: SidebarVisibilityStoring {
    var sidebarVisible: Bool?
}
