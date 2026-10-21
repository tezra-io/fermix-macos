import Foundation

/// A managed local file the engine granted for a media ref (M66 decision 1).
/// The file is the engine's, held for this app while a use of it is counted.
/// What the file is, its type and size, is the row's media ref's to say: the
/// grant only says where it is.
public struct MediaGrant: Equatable, Sendable {
    public let ref: String
    public let url: URL
}

extension MediaGrant {
    init(_ path: CompanionMediaPath) {
        self.init(ref: path.ref, url: URL(fileURLWithPath: path.path))
    }
}

/// What asking for a ref's file came to.
public enum MediaGrantOutcome: Equatable, Sendable {
    case granted(MediaGrant)
    /// Nothing to grant: the engine no longer holds the bytes, no row names
    /// the ref, or the ref is not one.
    case missing
    /// The engine could not make the file for a reason of its own, or the use
    /// stopped waiting for its answer: its task was cancelled.
    case failed
}

/// What the chat's tiles, the player and the pane hold a phone-side file by.
@MainActor
public protocol MediaGranting: AnyObject {
    /// One more use of `ref`. Every call is paired with exactly one
    /// `release(ref)`, whatever it returned.
    func hold(_ ref: String) async -> MediaGrantOutcome
    func release(_ ref: String)
}

/// The app's count per ref of what is using a granted file, and the
/// `media_fetch` and `media_release` the count asks for (M66 decision 1).
///
/// A ref is fetched when its first use comes and released once, when its last
/// one goes, and only when the engine granted it: a file is held only while
/// something reads it. The first answer resolves every use waiting on it, and
/// a later use takes that answer at once. A connection's grants end with it,
/// so after every handshake each ref still counted is fetched again; its
/// answer, normally the same path, resolves the uses waiting and replaces the
/// one held. A use that comes while there is no connection waits for the next
/// handshake, and a daemon that refused this build's version sends none: its
/// rows are drawn under the sentence that says to update.
///
/// The session owns the socket: it hands this its way of sending, which sends
/// only on a negotiated connection, and routes the handshake, the drop and the
/// three answers here.
@MainActor
public final class MediaGrants: MediaGranting {
    /// Puts an event on the negotiated connection, and says whether there was
    /// one.
    typealias Send = (CompanionClientEvent) -> Bool

    /// What uses one ref.
    private struct Uses {
        var count = 0
        /// The engine's answer on this connection, once it has answered.
        var answer: MediaGrantOutcome?
        /// The uses waiting for that answer, by the number each was given.
        var waiting: [Int: (MediaGrantOutcome) -> Void] = [:]
    }

    private let send: Send
    private var uses: [String: Uses] = [:]
    /// The refs fetched on this connection and not answered yet.
    private var asked: Set<String> = []
    private var waitersIssued = 0

    init(send: @escaping Send) {
        self.send = send
    }

    // MARK: - The uses

    /// A ref that is not one is answered `.missing` and sends nothing. A use
    /// whose task is cancelled while it waits stops waiting, answered
    /// `.failed`; it is still counted until its release.
    public func hold(_ ref: String) async -> MediaGrantOutcome {
        guard CompanionProtocol.isMediaRef(ref) else { return .missing }

        waitersIssued += 1
        let waiter = waitersIssued
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                use(ref, waiter: waiter) { continuation.resume(returning: $0) }
            }
        } onCancel: {
            Task { @MainActor in self.stopWaiting(waiter, for: ref) }
        }
    }

    /// The release of a ref never counted, a ref that is not one, is nothing.
    public func release(_ ref: String) {
        guard var entry = uses[ref] else { return }

        entry.count -= 1
        guard entry.count == 0 else {
            uses[ref] = entry
            return
        }

        uses[ref] = nil
        if case .granted = entry.answer {
            _ = send(.mediaRelease(profileId: CompanionProtocol.profileId, ref: ref))
        }
    }

    /// How many uses of `ref` are counted.
    func count(of ref: String) -> Int {
        uses[ref]?.count ?? 0
    }

    /// Counts one more use of `ref` and answers it: now, when the engine has
    /// answered on this connection, or when it does. The first use fetches.
    private func use(_ ref: String, waiter: Int, answer: @escaping (MediaGrantOutcome) -> Void) {
        var entry = uses[ref] ?? Uses()
        entry.count += 1
        if let known = entry.answer {
            uses[ref] = entry
            answer(known)
            return
        }

        entry.waiting[waiter] = answer
        uses[ref] = entry
        if entry.count == 1 {
            fetch(ref)
        }
    }

    private func stopWaiting(_ waiter: Int, for ref: String) {
        guard let answer = uses[ref]?.waiting.removeValue(forKey: waiter) else { return }

        answer(.failed)
    }

    /// Asks for `ref` once per connection until it is answered. Marked asked
    /// before it is sent, since an answer can come back inside the send.
    private func fetch(_ ref: String) {
        guard !asked.contains(ref) else { return }

        asked.insert(ref)
        if !send(.mediaFetch(profileId: CompanionProtocol.profileId, ref: ref)) {
            asked.remove(ref)
        }
    }

    // MARK: - The session's side

    /// A handshake completed: every ref still counted is fetched again.
    func negotiated() {
        for ref in uses.keys.sorted() {
            fetch(ref)
        }
    }

    /// The connection ended, and the engine let go of everything it granted on
    /// it. The uses stay counted, and those waiting wait on.
    func disconnected() {
        asked = []
        for ref in uses.keys {
            uses[ref]?.answer = nil
        }
    }

    /// The engine answered a fetch of `ref`. When every use let go before the
    /// answer came, a grant is let go at once.
    func answered(_ ref: String, _ outcome: MediaGrantOutcome) {
        let wasAsked = asked.remove(ref) != nil
        guard var entry = uses[ref] else {
            if wasAsked, case .granted = outcome {
                _ = send(.mediaRelease(profileId: CompanionProtocol.profileId, ref: ref))
            }
            return
        }

        let waiting = entry.waiting.sorted { $0.key < $1.key }.map(\.value)
        entry.answer = outcome
        entry.waiting = [:]
        uses[ref] = entry
        waiting.forEach { $0(outcome) }
    }
}
