import Combine
import Foundation

/// Where the chat's connection stands, as a surface shows it.
public enum CompanionConnection: Equatable, Sendable {
    /// Nothing has asked for chat yet.
    case idle
    /// The first attempt since chat was asked for. Later attempts keep showing
    /// why the last one failed.
    case connecting
    case connected
    /// The home has no companion socket: the engine running there predates
    /// chat. The session keeps looking, so an engine that gains chat is found.
    case engineHasNoChat
    /// The daemon and this app cannot talk, and trying again will not change
    /// that. The sentence says which side to update.
    case refused(String)
    /// Not connected, and the session is trying again. The sentence says why.
    case disconnected(String)

    /// What a surface says about this state, where it says anything.
    public var sentence: String? {
        switch self {
        case .idle, .connecting, .connected: return nil
        case .engineHasNoChat: return ProductStrings[.companionConnectionEngineHasNoChat]
        case .refused(let sentence), .disconnected(let sentence): return sentence
        }
    }
}

/// The chat, as a surface reads it.
///
/// Every fact is the daemon's or the outbox's: the rows, the cursor and the
/// head are what the pages and live rows said, and nothing here is derived
/// from them. The session is the only writer; a surface observes this and asks
/// the session for everything it wants done.
@MainActor
public final class CompanionModel: ObservableObject {
    @Published public private(set) var connection: CompanionConnection = .idle
    /// The held window of the timeline, strictly ascending by seq.
    @Published public private(set) var rows: [CompanionRow] = []
    /// The last seq shown: the newest held row, or 0 before any.
    @Published public private(set) var cursor = 0
    /// The newest seq the daemon had written when it read the latest page.
    @Published public private(set) var historyHeadSeq = 0
    /// Whether a row older than the oldest held one exists.
    @Published public private(set) var hasOlder = false
    /// The turn answering now, with its draft and its latest tool call.
    @Published public private(set) var turn: CompanionTurn?
    /// Requests the daemon has not yet accepted, oldest first: the ones a
    /// surface shows as sending.
    @Published public private(set) var pending: [CompanionOutboxEntry] = []
    /// Approvals waiting on the owner, in the order they arrived.
    @Published public private(set) var approvals: [CompanionApproval] = []
    @Published public private(set) var search: CompanionSearch?
    /// The latest failure, in a sentence, until the next request.
    @Published public private(set) var lastError: String?

    init() {}

    func show(_ connection: CompanionConnection) {
        publish(\.connection, connection)
    }

    /// Publishes the reduced chat. Only the facts that changed are written, so
    /// a delta, tens a second, publishes one change rather than nine.
    func show(_ chat: CompanionChat) {
        publish(\.rows, chat.rows)
        publish(\.cursor, chat.cursor)
        publish(\.historyHeadSeq, chat.historyHeadSeq)
        publish(\.hasOlder, chat.hasOlder)
        publish(\.turn, chat.turn)
        publish(\.pending, chat.pending)
        publish(\.approvals, chat.approvals)
        publish(\.search, chat.search)
        publish(\.lastError, chat.lastError)
    }

    private func publish<Value: Equatable>(_ field: ReferenceWritableKeyPath<CompanionModel, Value>, _ value: Value) {
        guard self[keyPath: field] != value else { return }

        self[keyPath: field] = value
    }
}
