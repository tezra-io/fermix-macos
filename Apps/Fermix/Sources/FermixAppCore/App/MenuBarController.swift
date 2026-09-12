import AppKit
import Combine

/// The status item, behind a seam.
///
/// `NSStatusBar` is machine-wide and shared: a test that built one would put a
/// real item on the operator's menu bar and leave it there. Everything the app
/// does to the item goes through these four members, so the controller's rules
/// can be proved without AppKit.
///
/// Removal is not one of them. `.removalAllowed` and the autosave name macOS
/// remembers the answer under are set when the item is created, because the
/// item is on the bar from the moment it exists and macOS applies the
/// remembered visibility at the instant the name is assigned: a seam that could
/// name the item afterwards is a window in which an item the user removed is
/// drawn and then taken away again.
@MainActor
public protocol StatusItemPresenting: AnyObject {
    /// Whether the item is on the bar. macOS persists this under the item's
    /// autosave name, which makes the item itself the one owner of the fact:
    /// there is no second copy in user defaults to drift from it.
    var isVisible: Bool { get set }
    /// Called when the item goes on or off the bar for a reason the app did not
    /// cause. A Command-drag off it is the one the user performs, and it is the
    /// affordance `.removalAllowed` exists for.
    var onVisibilityChanged: (() -> Void)? { get set }
    /// The image the system draws, and what VoiceOver reads for it.
    func present(_ image: NSImage, label: String, identifier: String)
    /// The menu the item opens. A plain `NSMenu`, so macOS draws it, sizes it,
    /// and gives it the current system material.
    func attach(_ menu: NSMenu)
}

/// Whether Fermix shows a menu bar item, as the surfaces that can change it see
/// it.
///
/// Home has a switch and the status menu has a row. Both write here, so the two
/// cannot disagree about whether the item is on the bar, and neither of them
/// holds a copy of the answer.
@MainActor
public protocol MenuBarItemPresenting: AnyObject {
    var menuBarItemShown: Bool { get }
    func setMenuBarItemShown(_ shown: Bool)
}

/// The `NSStatusItem`, its glyph, and the menu under it.
///
/// The status item is the app: closing every window leaves this running. The
/// glyph is a template `NSImage` set on the status button, so the SYSTEM owns
/// its sizing, its tint for the current menu-bar appearance, its hover, and the
/// glass behind the menu it opens. Nothing is drawn into the button and nothing
/// is layered over it: a subview added to a status button is clipped to the
/// button, which is what cut the top off the old badge.
///
/// All three states are rasters (`MenuBarGlyphImage`), so the item never
/// animates and Reduce Motion needs no branch here.
@MainActor
public final class MenuBarController: MenuBarItemPresenting {
    /// The name macOS remembers this item's position and visibility under. It
    /// is written into the account's defaults, so it never changes: a new name
    /// would read as a new item and put a removed one back on the bar.
    public static let autosaveName = "fermix.statusItem"

    private let model: AppModel
    private let item: any StatusItemPresenting
    private var modelChanges: AnyCancellable?

    /// The shipped item: one real `NSStatusItem`, made here because this is the
    /// one object that owns it. It is named as it is created, so macOS has
    /// applied the remembered visibility before anything can draw the item.
    public convenience init(model: AppModel) {
        self.init(model: model, item: SystemStatusItem(autosaveName: Self.autosaveName))
    }

    public init(model: AppModel, item: any StatusItemPresenting) {
        self.model = model
        self.item = item
        // Wired here rather than at install, so the one notice that the item
        // went on or off the bar exists for as long as the item does.
        item.onVisibilityChanged = { [weak self] in self?.onMenuBarItemShownChanged?() }
    }

    /// Puts the item on the bar under the menu the command table built.
    ///
    /// Visibility is deliberately not written here. macOS restores it from the
    /// autosave name the item was created with, so an item the user removed
    /// with Command-drag stays removed across launches; writing `isVisible` at
    /// install would put it back every time.
    public func install(menu: NSMenu) {
        precondition(modelChanges == nil, "the status item is installed once")

        item.attach(menu)
        draw()

        modelChanges = model.objectWillChange.sink { [weak self] _ in
            // The published change lands after this fires, so the state is read
            // on the next turn of the run loop.
            DispatchQueue.main.async { self?.draw() }
        }
    }

    /// The one place the glyph is chosen, so the image and the label VoiceOver
    /// reads can never name different states.
    private func draw() {
        let state = model.menuGlyph

        item.present(
            MenuBarGlyphImage.template(for: state),
            label: state.accessibilityLabel,
            identifier: DesignComponent.menuBarGlyph.accessibilityIdentifier
        )
    }

    // MARK: - MenuBarItemPresenting

    /// Called whenever the item goes on or off the bar, however it happened.
    ///
    /// Home draws a switch from `menuBarItemShown`, which reads through to the
    /// item rather than holding a copy, so this is the only way it can learn
    /// that a Command-drag took the item off the bar while the window was open.
    public var onMenuBarItemShownChanged: (() -> Void)?

    public var menuBarItemShown: Bool { item.isVisible }

    public func setMenuBarItemShown(_ shown: Bool) {
        item.isVisible = shown
    }
}

/// The shipped status item.
///
/// `squareLength` lets the system size the item to the bar, `scaleNone` keeps
/// the template at the size it was rasterized for, and `imageOnly` is what
/// stops the button reserving room for a title it never has.
@MainActor
final class SystemStatusItem: StatusItemPresenting {
    private let item: NSStatusItem
    private var visibility: NSKeyValueObservation?

    var onVisibilityChanged: (() -> Void)?

    /// Creates the item and names it in the same breath.
    ///
    /// The item is on the menu bar from the moment it exists, and macOS applies
    /// the visibility it remembers at the instant `autosaveName` is assigned.
    /// Anything at all between the two — and assembling the rest of the app is
    /// a great deal — is time an item the user removed spends drawn on the bar
    /// before being taken away again, on every single launch.
    init(autosaveName: String) {
        precondition(!autosaveName.isEmpty, "the status item needs a name macOS can remember it by")

        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.behavior.insert(.removalAllowed)
        item.autosaveName = autosaveName
        // A Command-drag off the bar is a removal nothing in the app made, and
        // the surfaces that draw a switch for it read the item rather than a
        // copy: this is how they learn to read it again.
        visibility = item.observe(\.isVisible) { [weak self] _, _ in
            Task { @MainActor in self?.onVisibilityChanged?() }
        }
    }

    var isVisible: Bool {
        get { item.isVisible }
        set { item.isVisible = newValue }
    }

    func present(_ image: NSImage, label: String, identifier: String) {
        guard let button = item.button else {
            preconditionFailure("the status item has no button to draw into")
        }

        button.image = image
        button.imageScaling = .scaleNone
        button.imagePosition = .imageOnly
        button.setAccessibilityLabel(label)
        button.setAccessibilityIdentifier(identifier)
    }

    func attach(_ menu: NSMenu) {
        item.menu = menu
    }
}

extension MenuBarGlyphState {
    /// The glyph follows the daemon: running is the mark, starting is the mark
    /// in a lighter ink, and anything the operator must look at carries the
    /// badge.
    public init(daemon: DaemonCondition, hasAttention: Bool) {
        if hasAttention {
            self = .attention
            return
        }

        switch daemon {
        case .running: self = .running
        case .starting: self = .starting
        case .stopped: self = .attention
        }
    }
}
