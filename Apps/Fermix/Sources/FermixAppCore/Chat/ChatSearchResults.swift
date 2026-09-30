import SwiftUI

/// The daemon's answer to a search of the whole conversation, newest first:
/// each hit's excerpt with its matches marked, who wrote it and when. Choosing
/// one returns to the transcript at that row. Where the daemon said older hits
/// exist, one action at the foot asks for them.
///
/// Nothing is searched here: the app holds only a window of rows, and the
/// engine's index holds the months (plan §3.5).
struct ChatSearchResults: View {
    let search: CompanionSearch
    let older: () -> Void
    let choose: (CompanionSearchHit) -> Void

    var body: some View {
        if let hits = search.hits, hits.isEmpty {
            SurfaceEmptyState(
                model: EmptyStateModel(message: ProductStrings[.chatSearchNoMatches]),
                symbol: "magnifyingglass"
            )
        } else {
            List {
                if let hits = search.hits {
                    ForEach(hits, id: \.serverSeq) { hit in
                        Button { choose(hit) } label: { ChatHitRow(hit: hit) }
                            .buttonStyle(.plain)
                    }

                    if search.nextBeforeSeq != nil {
                        Button(ProductStrings[.chatSearchOlder], action: older)
                            .buttonStyle(SecondaryButtonStyle(.row))
                            .disabled(search.olderHitsAsked != nil)
                    }
                } else {
                    Label { Text(ProductStrings[.chatSearchSearching]) } icon: { ActivityMark() }
                        .fermixType(Typography.style(.calloutSmall))
                        .foregroundStyle(Palette.secondary.color)
                }
            }
            .listStyle(.plain)
            .showsAmbientGround()
            .scrollIndicators(.never)
            .frame(maxWidth: ChatMetrics.columnWidth)
            .frame(maxWidth: .infinity)
        }
    }
}

/// One hit: the excerpt as the daemon cut it, then who wrote it and when.
private struct ChatHitRow: View {
    let hit: CompanionSearchHit

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text(ChatExcerpt.attributed(hit))
                .fermixType(Typography.style(.body))
                .foregroundStyle(Palette.ink.color)

            Text(ProductStrings.middot(ChatSpeaker.name(role: hit.role), ChatTime.written(hit.timestamp)))
                .fermixType(Typography.style(.caption))
                .foregroundStyle(Palette.faint.color)
        }
        .padding(.vertical, Spacing.xxs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}
