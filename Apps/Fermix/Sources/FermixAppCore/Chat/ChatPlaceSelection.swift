import Foundation

/// The place a reply's map shows (M72 §14.1): in which reply, by its row's
/// sequence number, which place, by the number its pin and its card show,
/// and Apple's identifier the place is looked up by.
struct ChatPlaceShown: Equatable {
    let reply: Int
    let number: Int
    let identifier: String
}

/// The one place the whole chat shows on a reply's map at a time (M72
/// §14.1), with Apple's compact callout at its pin, and every decision
/// about it, made here from what the person asks and what Maps answers. A
/// click on a place Apple Maps found shows it, in place of any place shown
/// in this reply or another; the same place clicked again is put away; a
/// place another source found goes to Maps at its address and leaves the
/// map as it is. Escape, or a click on the empty map, puts the reply's place
/// away; and where Maps finds no place by the identifier, the pane says so
/// and the map stays its picture, with nothing looked up by the place's
/// name. Built once for the chat surface, so a visit starts with no place
/// shown.
@MainActor
final class ChatPlaceSelection: ObservableObject {
    @Published private(set) var shown: ChatPlaceShown?

    private let links: ContentLinkOpener

    init(links: ContentLinkOpener) {
        self.links = links
    }

    /// A click on a place's card or its pin in `reply`, or Return on its
    /// card.
    func click(_ place: CompanionPlace, numbered number: Int, in reply: Int) {
        guard let identifier = links.show(place) else { return }

        let asked = ChatPlaceShown(reply: reply, number: number, identifier: identifier)
        shown = asked == shown ? nil : asked
    }

    /// Escape, or a click on the empty map, in `reply`.
    func dismiss(in reply: Int) {
        guard shown?.reply == reply else { return }

        shown = nil
    }

    /// Maps found no place by the identifier `asked` was looked up by, or
    /// could not be asked. Said only while it is still the place asked for:
    /// one the person has moved on from says nothing.
    func failed(_ asked: ChatPlaceShown) {
        guard shown == asked else { return }

        shown = nil
        links.placeNotShown()
    }
}
