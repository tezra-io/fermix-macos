import Foundation

@testable import FermixAppCore

/// Rows with files as they reach this client on version 3: announced live
/// with their files, read from history with them, changed later as a
/// `row_updated` says (M66 §3.6), and their files granted by ref (decision 1).
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

    /// A media row announced live with its files: a voice note from the phone
    /// is the user's, with no text until its transcript is stored; a picture
    /// Fermix sent the phone is the assistant's.
    static func announced(
        _ seq: Int,
        role: String = "user",
        text: String = "",
        refs: [CompanionMediaRef],
        previews: [CompanionLinkPreview]? = nil
    ) -> CompanionServerEvent {
        .row(
            CompanionAnnouncedRow(
                profileId: CompanionEvents.profile,
                serverSeq: seq,
                role: role,
                text: text,
                timestamp: "2026-10-11T09:00:00Z",
                clientMsgId: nil,
                kind: "media",
                metadata: nil,
                mediaRefs: refs,
                linkPreviews: previews,
                blocks: nil
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
        previews: [CompanionLinkPreview]? = nil
    ) -> CompanionTimelineRow {
        CompanionTimelineRow(
            serverSeq: seq,
            role: role,
            content: text,
            kind: "media",
            timestamp: "2026-10-11T09:00:00Z",
            mediaRefs: refs,
            clientMsgId: nil,
            inReplyTo: nil,
            metadata: nil,
            linkPreviews: previews,
            blocks: nil
        )
    }

    /// A link preview the engine stored for an address in a row.
    static let preview = CompanionLinkPreview(
        url: "https://x.test/a",
        site: "X",
        title: "A page",
        description: nil,
        imageRef: String(repeating: "c", count: 64)
    )

    /// The engine's notice that a written row changed.
    static func updated(_ seq: Int) -> CompanionServerEvent {
        .rowUpdated(profileId: CompanionEvents.profile, serverSeq: seq)
    }

    /// The page answering a forward read: these rows, oldest first, and the
    /// last of them as where the read stopped.
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

    /// The managed file the engine makes for a ref.
    static func path(_ media: CompanionMediaRef) -> String {
        "/Users/me/.fermix/companion/media/\(media.ref).bin"
    }

    /// The engine's grant of a ref's file.
    static func granted(_ media: CompanionMediaRef, at path: String? = nil) -> CompanionServerEvent {
        .mediaPath(
            CompanionMediaPath(
                ref: media.ref,
                path: path ?? Self.path(media),
                kind: media.kind,
                mime: media.mime,
                sizeBytes: media.sizeBytes,
                sha256: media.ref
            )
        )
    }

    /// The grant the app hands a use, for that file.
    static func grant(_ media: CompanionMediaRef, at path: String? = nil) -> MediaGrant {
        MediaGrant(ref: media.ref, url: URL(fileURLWithPath: path ?? Self.path(media)))
    }

    static func fetch(_ media: CompanionMediaRef) -> CompanionClientEvent {
        .mediaFetch(profileId: CompanionProtocol.profileId, ref: media.ref)
    }

    static func release(_ media: CompanionMediaRef) -> CompanionClientEvent {
        .mediaRelease(profileId: CompanionProtocol.profileId, ref: media.ref)
    }
}
