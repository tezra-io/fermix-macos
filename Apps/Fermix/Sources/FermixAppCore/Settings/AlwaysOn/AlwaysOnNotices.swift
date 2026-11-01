import Foundation

/// The system notifications of Always On (Always On setup §3.1): the server
/// is ready, the move is done, the server cannot be reached, a server must be
/// set up again, and the newest backup is a week old. Each is the summary's
/// `notice`, worded by the engine; the app raises one the first time it sees
/// its id, from any summary it reads or a press answers.

/// The notices this app raised, the last sixteen of them. A notice's id
/// stays the same while its occurrence stands and can come back after
/// another one, as the move's does once an outage clears, so one remembered
/// id would raise it twice.
struct AlwaysOnPosted: Equatable {
    static let bound = 16

    private(set) var ids: [String] = []

    /// Whether `id` was not raised yet; it is remembered from now on, with
    /// the oldest forgotten past the bound.
    mutating func first(_ id: String) -> Bool {
        guard !ids.contains(id) else { return false }

        ids.append(id)
        if ids.count > Self.bound { ids.removeFirst(ids.count - Self.bound) }
        return true
    }
}
