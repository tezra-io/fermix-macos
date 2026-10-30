import Foundation

/// A link held back from opening until the person says so: where it goes,
/// and why it was held.
struct ChatHeldLink: Equatable, Identifiable {
    let url: URL
    let caution: LinkCaution

    var id: String { url.absoluteString }
}

/// Every link the chat opens, checked first (`LinkSafety`). A link that may
/// not go where it seems to is held, and the chat asks before it opens; any
/// other opens straight away, where the person's preference says
/// (`ContentLinkOpener`). A link whose words are known is checked against
/// them as well, which is how a reply's words reach here (`ChatProse`); a
/// link known only by where it goes is checked by that alone. Built once
/// for the chat surface, so a visit starts with nothing held.
@MainActor
final class ChatLinkGuard: ObservableObject {
    @Published private(set) var held: ChatHeldLink?

    private let links: ContentLinkOpener

    init(links: ContentLinkOpener) {
        self.links = links
    }

    /// A click on a link, its caution already read from its words.
    func open(_ url: URL, caution: LinkCaution?) {
        guard let caution else {
            links.open(url)
            return
        }

        held = ChatHeldLink(url: url, caution: caution)
    }

    /// A click on a link known only by where it goes.
    func open(_ url: URL) {
        open(url, caution: LinkSafety.caution(url: url))
    }

    /// The person chose to open the held link all the same.
    func openHeld() {
        guard let held else { return }

        self.held = nil
        links.open(held.url)
    }

    /// The person chose not to open it.
    func dismiss() {
        held = nil
    }
}

/// What the chat says of a link that may not go where it seems to: in the
/// question before it opens, and where the pointer rests on it.
enum ChatLinkCautionWords {
    static func sentence(_ caution: LinkCaution) -> String {
        switch caution {
        case .elsewhere(let shown, let opens):
            return String(format: ProductStrings[.chatLinkElsewhereFormat], shown, opens)
        case .lookalike(let opens):
            return String(format: ProductStrings[.chatLinkLookalikeFormat], opens)
        case .hiddenName(let opens):
            return String(format: ProductStrings[.chatLinkHiddenNameFormat], opens)
        }
    }
}
