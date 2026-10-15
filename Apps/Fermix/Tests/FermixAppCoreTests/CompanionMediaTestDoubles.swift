import Foundation

@testable import FermixAppCore

/// Rows with files, as they reach this client: announced live with none of
/// them, since protocol 2's `row` carries no media list, and read from history
/// with them (M66 §3.6).
enum CompanionMediaRows {
    static let voice = CompanionMediaRef(
        ref: String(repeating: "a", count: 64),
        kind: "audio",
        mime: "audio/ogg",
        sizeBytes: 18_204,
        sha256: nil,
        filename: nil,
        caption: nil
    )
    static let picture = CompanionMediaRef(
        ref: String(repeating: "b", count: 64),
        kind: "image",
        mime: "image/png",
        sizeBytes: 402_118,
        sha256: nil,
        filename: "chart.png",
        caption: nil
    )

    /// The request a voice note from the phone recorded, which its reply
    /// names in `in_reply_to`.
    static func request(_ seq: Int) -> String {
        "phone-\(seq)"
    }

    /// A media row announced live: a voice note from the phone is the user's,
    /// with no text and the request it recorded; a picture Fermix sent the
    /// phone is the assistant's.
    static func announced(
        _ seq: Int,
        role: String = "user",
        text: String = "",
        request: String? = nil
    ) -> CompanionServerEvent {
        .row(
            CompanionAnnouncedRow(
                profileId: CompanionEvents.profile,
                serverSeq: seq,
                role: role,
                text: text,
                timestamp: "2026-10-11T09:00:00Z",
                clientMsgId: request,
                kind: "media",
                metadata: nil
            )
        )
    }

    /// A media row as history has it, with its files. A voice note's
    /// transcript, once stored, is its text.
    static func exported(
        _ seq: Int,
        role: String = "user",
        text: String = "",
        refs: [CompanionMediaRef],
        request: String? = nil
    ) -> CompanionTimelineRow {
        CompanionTimelineRow(
            serverSeq: seq,
            role: role,
            content: text,
            kind: "media",
            timestamp: "2026-10-11T09:00:00Z",
            mediaRefs: refs,
            clientMsgId: request,
            inReplyTo: nil,
            metadata: nil,
            linkPreviews: nil
        )
    }

    /// Fermix's reply to a voice note, as history has it.
    static func reply(_ seq: Int, to note: Int, text: String) -> CompanionTimelineRow {
        CompanionTimelineRow(
            serverSeq: seq,
            role: "assistant",
            content: text,
            kind: "text",
            timestamp: "2026-10-11T09:00:05Z",
            mediaRefs: [],
            clientMsgId: nil,
            inReplyTo: request(note),
            metadata: nil,
            linkPreviews: nil
        )
    }

    /// The page answering a forward read: these rows, oldest first.
    static func page(_ rows: [CompanionTimelineRow], head: Int) -> CompanionServerEvent {
        .historyPage(
            CompanionHistoryPage(
                profileId: CompanionEvents.profile,
                messages: rows,
                historyHeadSeq: head,
                nextAfterSeq: rows.last?.serverSeq,
                nextBeforeSeq: nil
            )
        )
    }

    /// A read of held rows on the wire: from just below the lowest, only as
    /// many rows as it spans.
    static func read(after seq: Int, limit: Int) -> CompanionClientEvent {
        .historyPull(profileId: CompanionProtocol.profileId, cursor: .after(seq: seq), limit: limit)
    }
}
