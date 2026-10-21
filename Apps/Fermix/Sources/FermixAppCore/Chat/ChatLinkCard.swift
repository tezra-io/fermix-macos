import SwiftUI

extension ChatMetrics {
    /// A link card (M72): the place card's size, so the records under a reply
    /// read as one set, with the page's picture filling a square at its
    /// leading edge and room for two lines of title beside it.
    static let linkCardWidth: Double = placeCardWidth
    static let linkCardHeight: Double = placeCardHeight
}

/// A row's links in one sideways row of cards, which scrolls as the strip's
/// other rows do.
struct ChatLinkLane: View {
    let links: [ChatStripLink]
    let width: Double
    let trailing: Bool

    var body: some View {
        ChatStripLane(items: links, itemWidth: ChatMetrics.linkCardWidth, width: width, trailing: trailing) { link in
            ChatLinkCard(link: link)
        }
    }
}

/// What a link says of its page (M72), read from its address and the preview
/// the engine stored for it, never from the web: with a preview, the page's
/// title over its site, and its picture where it has one; without one, its
/// host over the words of its path's last part, where that has any. The
/// site's initial stands in for a picture it does not have.
struct ChatLinkFace: Equatable {
    let title: String
    let detail: String?
    let initial: String
    /// The preview's picture, a media ref.
    let picture: String?

    init(_ link: ChatStripLink) {
        let host = Self.host(of: link.address)
        let site = link.preview.map { $0.site.isEmpty ? host : $0.site }

        if let preview = link.preview {
            title = preview.title
            detail = site
        } else {
            title = host
            detail = Self.words(of: link.address)
        }
        initial = (site ?? host).first { $0.isLetter || $0.isNumber }.map { String($0).uppercased() } ?? ""
        picture = link.preview?.imageRef.flatMap { CompanionProtocol.isMediaRef($0) ? $0 : nil }
    }

    /// The host without its `www.`, or the whole address where it has none.
    static func host(of address: URL) -> String {
        guard let host = address.host(percentEncoded: false), !host.isEmpty else { return address.absoluteString }

        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// The last part of the path as words: `/lists/spring-seeds` is `Spring
    /// seeds`. None where the path is only `/`, or its last part has no
    /// letter or reads as an identifier rather than words.
    static func words(of address: URL) -> String? {
        guard let last = address.path(percentEncoded: false).split(separator: "/").last else { return nil }

        let name = last.split(separator: ".").first ?? last
        let words = name.split { $0 == "-" || $0 == "_" || $0 == "+" || $0 == " " }
        guard words.contains(where: { $0.contains(where: \.isLetter) }),
              words.allSatisfy({ $0.count <= longestWord })
        else { return nil }

        let joined = words.joined(separator: " ").lowercased()
        return joined.prefix(1).uppercased() + joined.dropFirst()
    }

    private static let longestWord = 20
}

/// A link as a card (M72): its picture filling the square at its leading
/// edge, or the site's initial where it has none, and its title over its site
/// beside it, at one size whatever arrives, so nothing moves when a preview
/// does. A click, or Return, opens the address as the text wrote it, where
/// the person's preference says; its help tag names the address, and it is
/// heard as its title and the word Link.
struct ChatLinkCard: View {
    let link: ChatStripLink

    @Environment(\.openURL) private var openURL

    var body: some View {
        let face = ChatLinkFace(link)
        let side = ChatMetrics.linkCardHeight

        Button { openURL(link.address) } label: {
            ChatTileFrame(size: CGSize(width: ChatMetrics.linkCardWidth, height: side)) {
                HStack(spacing: Spacing.s) {
                    ChatLinkPicture(face: face, size: CGSize(width: side, height: side))
                    ChatLinkWords(face: face)
                        .padding(.trailing, Spacing.s)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .buttonStyle(ChatTileButtonStyle())
        .onKeyPress(.return) {
            openURL(link.address)
            return .handled
        }
        .help(link.address.absoluteString)
        .accessibilityLabel(ProductStrings.commaPair(face.title, ProductStrings[.chatKindLink]))
    }
}

/// A link's title, up to two lines, over its site.
private struct ChatLinkWords: View {
    let face: ChatLinkFace

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs / 2) {
            Text(face.title)
                .fermixType(Typography.style(.callout))
                .foregroundStyle(Palette.ink.color)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if let detail = face.detail {
                Text(detail)
                    .fermixType(Typography.style(.caption))
                    .foregroundStyle(Palette.secondary.color)
                    .lineLimit(1)
            }
        }
        .truncationMode(.tail)
    }
}

/// A link's picture filling its place, made while it is on screen from the
/// file the engine grants for its ref, through the same previews as every
/// tile's. The site's initial stands in until it comes, and where the link
/// has none, so the card never changes size.
private struct ChatLinkPicture: View {
    let face: ChatLinkFace
    let size: CGSize

    @State private var outcome: ChatPreviewOutcome?
    @State private var onScreen = false
    @Environment(\.chatRows) private var rows
    @Environment(\.displayScale) private var scale

    var body: some View {
        Group {
            if case .made(.picture(let preview))? = outcome {
                Image(decorative: preview.image, scale: scale)
                    .resizable()
            } else {
                Text(face.initial)
                    .fermixType(Typography.style(.title))
                    .foregroundStyle(Palette.secondary.color)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Palette.monoDisc.color)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .accessibilityHidden(true)
        .onScrollVisibilityChange(threshold: 0.01) { onScreen = $0 }
        .task(id: onScreen) {
            guard onScreen, let rows, let ref = face.picture, outcome?.isFinal != true else { return }

            let made = await rows.media.previews.preview(ChatPreviewRequest(ref: ref, family: .picture, size: size, scale: scale))
            guard !Task.isCancelled else { return }

            outcome = made
        }
    }
}
