import Foundation

/// The system notifications of Always On (Always On setup §3.1): the server
/// is ready, the move is done, the server cannot be reached, the newest
/// backup is a week old, and Fermix is back on this computer while the
/// server still runs its retired copy. Each is the summary's `notice`,
/// worded by the engine; the app raises one the first time it sees its id,
/// from any summary it reads or a press answers, across launches.

/// Where the ids of the notices this app raised are kept, so a relaunch does
/// not raise a standing one again.
@MainActor
public protocol AlwaysOnNoticeStoring: AnyObject {
    /// The ids, oldest first.
    var postedNotices: [String] { get set }
}

/// The shipped store: this Mac's defaults, as the pane's other choices are.
@MainActor
public final class UserDefaultsAlwaysOnNoticeStore: AlwaysOnNoticeStoring {
    public static let key = "alwaysOn.notices.posted"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var postedNotices: [String] {
        get { defaults.stringArray(forKey: Self.key) ?? [] }
        set { defaults.set(newValue, forKey: Self.key) }
    }
}

/// The notices this app raised, the last sixteen of them, kept in the store.
/// A notice's id stays the same while its occurrence stands and can come
/// back after another one, as the move's does once an outage clears, so one
/// remembered id would raise it twice.
@MainActor
struct AlwaysOnPosted {
    static let bound = 16

    let store: any AlwaysOnNoticeStoring

    /// Whether `id` was not raised yet; it is remembered from now on, with
    /// the oldest forgotten past the bound.
    func first(_ id: String) -> Bool {
        var ids = store.postedNotices
        guard !ids.contains(id) else { return false }

        ids.append(id)
        store.postedNotices = Array(ids.suffix(Self.bound))
        return true
    }
}
