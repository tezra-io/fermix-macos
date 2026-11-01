import Combine
import Foundation

/// Where whether the Lists panel is open is remembered (M85 §09).
@MainActor
public protocol ChecklistPanelStoring: AnyObject {
    /// The stored choice, or nil where the owner has never opened or hidden
    /// the panel.
    var panelOpen: Bool? { get set }
}

/// The shipped store.
@MainActor
public final class UserDefaultsChecklistPanelStore: ChecklistPanelStoring {
    public static let key = "chat.lists.panel.open"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var panelOpen: Bool? {
        get {
            guard defaults.object(forKey: Self.key) != nil else { return nil }

            return defaults.bool(forKey: Self.key)
        }
        set {
            guard let newValue else {
                defaults.removeObject(forKey: Self.key)
                return
            }

            defaults.set(newValue, forKey: Self.key)
        }
    }
}

/// The Lists panel beside the chat (M85 §09): whether it is open, how wide,
/// and which list it shows. One instance for the window's life, so the
/// toolbar's button, the View menu's command, a card and the panel's own
/// hide button all move the same panel, and leaving Chat keeps it as it was.
/// Whether it is open is remembered; its width and its list are not.
@MainActor
public final class ChecklistPanelModel: ObservableObject {
    @Published public private(set) var isOpen: Bool
    /// The divider's place: 330 points, 280 to 420 by dragging.
    @Published public private(set) var width = ChecklistMetrics.panelWidth
    /// The list asked for, by a card, the picker or a new list made here.
    /// Nil, or a list the index no longer holds, shows the first list.
    @Published public private(set) var asked: String?
    /// Whether the daemon serves lists, which the Lists button and the panel
    /// are drawn by.
    @Published public private(set) var served = false
    /// Counts the cards' requests, so a second click on the same list still
    /// draws the eye to the panel.
    @Published public private(set) var requests = 0
    /// The list removed here a moment ago, which the panel offers to bring
    /// back: once the engine has removed it, the panel turns to another.
    @Published public private(set) var removedList: CompanionChecklistEntry?

    public let library: ChecklistLibrary
    private let store: any ChecklistPanelStoring
    private var watching: Set<AnyCancellable> = []
    /// The removals made here, counted, and those already taken back.
    private var removals = 0
    private var takenBack: Set<Int> = []
    /// The removal of each list removed here and not yet taken back.
    private var listRemovals: [String: ChecklistRemoval] = [:]

    public init(library: ChecklistLibrary, store: any ChecklistPanelStoring) {
        self.library = library
        self.store = store
        isOpen = store.panelOpen ?? false

        library.index.$served
            .removeDuplicates()
            .sink { [weak self] served in self?.served = served }
            .store(in: &watching)
        library.index.$created
            .compactMap { $0 }
            .sink { [weak self] created in self?.show(created.listId) }
            .store(in: &watching)
    }

    /// The list the panel shows: the one asked for while the index holds it,
    /// or else the first in picker order.
    public func shown(in index: ChecklistIndexStore) -> CompanionChecklistEntry? {
        guard let entries = index.entries else { return nil }

        return entries.first { $0.listId == asked } ?? entries.first
    }

    public func toggle() {
        remember(!isOpen)
    }

    /// Opens the panel, at a list when one is named.
    public func show(_ listId: String?) {
        if let listId { asked = listId }
        requests += 1
        remember(true)
    }

    public func hide() {
        remember(false)
    }

    public func select(_ listId: String) {
        asked = listId
    }

    /// Removes the list the panel shows, and offers it back for a moment.
    public func remove(_ entry: CompanionChecklistEntry) {
        let removal = removing(listId: entry.listId, rowId: nil, text: entry.title)
        library.edit(entry.listId, .removeList)
        listRemovals[entry.listId] = removal
        removedList = entry
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: ChecklistMetrics.undoLine)
            if self?.removedList == entry { self?.removedList = nil }
        }
    }

    /// Brings back the list removed here, once, and shows it again.
    public func restore(_ entry: CompanionChecklistEntry) {
        if removedList == entry { removedList = nil }
        guard let removal = listRemovals.removeValue(forKey: entry.listId) else { return }

        takeBack(removal)
    }

    /// Removes one row of a list, which the panel offers back for a moment.
    func remove(_ row: CompanionChecklistRow, from listId: String) -> ChecklistRemoval {
        library.edit(listId, .remove(rowId: row.rowId))
        return removing(listId: listId, rowId: row.rowId, text: row.text)
    }

    /// Takes a removal made here back, once: the Undo line and ⌘Z reach
    /// the same removal, and whichever comes second sends nothing. A list
    /// taken back is shown again.
    func takeBack(_ removal: ChecklistRemoval) {
        guard takenBack.insert(removal.token).inserted else { return }

        library.edit(removal.listId, .restore(rowId: removal.rowId, title: nil))
        if removal.rowId == nil { asked = removal.listId }
    }

    private func removing(listId: String, rowId: String?, text: String) -> ChecklistRemoval {
        removals += 1
        return ChecklistRemoval(token: removals, listId: listId, rowId: rowId, text: text)
    }

    /// The divider dragged to a width, kept inside the panel's range.
    public func resize(to width: Double) {
        let bounded = min(max(width, ChecklistMetrics.panelWidths.lowerBound), ChecklistMetrics.panelWidths.upperBound)
        if self.width != bounded { self.width = bounded }
    }

    private func remember(_ open: Bool) {
        if isOpen != open { isOpen = open }
        store.panelOpen = open
    }
}

/// A removal made here, which Undo or ⌘Z takes back once.
struct ChecklistRemoval: Equatable, Sendable {
    let token: Int
    let listId: String
    /// Nil for the list itself.
    let rowId: String?
    let text: String
}

/// The lists' own measures (M85 §09).
enum ChecklistMetrics {
    static let panelWidth: Double = 330
    static let panelWidths: ClosedRange<Double> = 280 ... 420
    /// The circle, in the row action's 24-point target.
    static let circle: Double = 17
    static let target: Double = HitTarget.rowAction
    /// A card is the soft panel a code block is, with its corners.
    static let cardRadius: Double = Radius.card
    /// How long a ticked row keeps its place, so a mis-tick is easy to undo,
    /// before it folds into Done. Reduce Motion folds it at once.
    static let settle: Duration = .milliseconds(700)
    /// The divider's grip: wider than the hairline it draws.
    static let grip: Double = Spacing.xs
    /// How long the line saying what was removed stays.
    static let undoLine: Duration = .seconds(6)
}
