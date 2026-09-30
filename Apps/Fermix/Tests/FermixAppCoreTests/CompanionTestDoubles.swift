import Foundation

@testable import FermixAppCore

/// The companion daemon's side of the socket, driven by hand: a session built
/// over `CompanionSocketClient(lines:)` on one of these crosses the real adapter
/// in both directions, and a case reads back the lines it put on the wire.
typealias FakeCompanionSocket = FakeLineSocketTransport<CompanionServerEvent, CompanionDecodeFailure>

/// The object a client event goes on the wire as, for comparing against what a
/// fake line socket recorded. Labelled, because the realtime wire's events share
/// case names with these and an implicit member would not know which it meant.
func wireObject(companion event: CompanionClientEvent) throws -> NSDictionary {
    try wireObject(event.line())
}

/// The pull a case expects on the wire: every pull asks for a full page.
func historyPull(_ cursor: CompanionHistoryCursor) -> CompanionClientEvent {
    .historyPull(profileId: CompanionProtocol.profileId, cursor: cursor, limit: CompanionProtocol.historyPageLimit)
}

/// The cold start's pull: the newest page.
let newestPagePull = historyPull(.before(seq: CompanionReducer.newestPageBound))

/// Server events built the way the daemon writes them, with only the facts a
/// case varies named at the call.
enum CompanionEvents {
    static let profile = CompanionProtocol.profileId

    static func hello(_ minimum: Int = 1, _ maximum: Int = 1) -> CompanionServerEvent {
        .serverHello(minVersion: minimum, maxVersion: maximum)
    }

    /// A live row, as announced outside a turn's completion.
    static func row(_ seq: Int, role: String = "user", clientMsgId: String? = nil) -> CompanionServerEvent {
        .row(
            CompanionAnnouncedRow(
                profileId: profile,
                serverSeq: seq,
                role: role,
                text: "row \(seq)",
                timestamp: "2026-09-25T09:00:00Z",
                clientMsgId: clientMsgId
            )
        )
    }

    static func exported(_ seq: Int) -> CompanionTimelineRow {
        CompanionTimelineRow(
            serverSeq: seq,
            role: "assistant",
            content: "row \(seq)",
            kind: "text",
            timestamp: "2026-09-25T09:00:00Z",
            mediaRefs: [],
            clientMsgId: nil,
            inReplyTo: nil,
            metadata: nil
        )
    }

    /// A forward page: the rows after a cursor, and where the read stopped.
    static func forward(_ seqs: [Int], head: Int, next: Int) -> CompanionServerEvent {
        .historyPage(
            CompanionHistoryPage(
                profileId: profile,
                messages: seqs.map(exported),
                historyHeadSeq: head,
                nextAfterSeq: next,
                nextBeforeSeq: nil
            )
        )
    }

    /// A backward page: the newest rows below a cursor, and where older ones
    /// start when any exist.
    static func backward(_ seqs: [Int], head: Int, older: Int? = nil) -> CompanionServerEvent {
        .historyPage(
            CompanionHistoryPage(
                profileId: profile,
                messages: seqs.map(exported),
                historyHeadSeq: head,
                nextAfterSeq: nil,
                nextBeforeSeq: older
            )
        )
    }

    static func accepted(_ clientMsgId: String, duplicate: Bool, serverSeq: Int? = nil) -> CompanionServerEvent {
        .accepted(CompanionAccepted(clientMsgId: clientMsgId, duplicate: duplicate, serverSeq: serverSeq))
    }

    static func approval(_ approvalId: String = "sandbox-1") -> CompanionServerEvent {
        .approval(
            CompanionApproval(
                approvalId: approvalId,
                kind: "sandbox",
                text: "Allow reading ~/Documents?",
                detail: nil,
                token: "opaque-token",
                ttlSeconds: 60,
                approveCommand: "/confirm opaque-token",
                denyCommand: "/deny opaque-token"
            )
        )
    }

    static func results(_ query: String, seqs: [Int], older: Int? = nil) -> CompanionServerEvent {
        .searchResults(
            CompanionSearchResults(
                profileId: profile,
                query: query,
                hits: seqs.map(hit),
                nextBeforeSeq: older
            )
        )
    }

    static func hit(_ seq: Int) -> CompanionSearchHit {
        CompanionSearchHit(
            serverSeq: seq,
            role: "user",
            timestamp: "2026-09-24T09:15:00Z",
            excerpt: "book the dentist for Friday",
            ranges: [CompanionMatchRange(start: 9, length: 7)]
        )
    }

    static func refusal(
        _ reason: String,
        clientMsgId: String? = nil,
        direction: CompanionVersionDirection? = nil,
        window: CompanionVersionWindow? = nil
    ) -> CompanionServerEvent {
        .error(
            CompanionServerError(
                reason: reason,
                message: nil,
                field: nil,
                event: nil,
                clientMsgId: clientMsgId,
                direction: direction,
                clientVersion: direction.map { _ in CompanionProtocol.version },
                minVersion: window?.minimum,
                maxVersion: window?.maximum
            )
        )
    }
}
