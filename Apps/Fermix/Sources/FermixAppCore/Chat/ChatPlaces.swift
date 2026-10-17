import AppKit
import SwiftUI

extension ChatMetrics {
    /// A reply's map (M72 §7.2): as wide as the reply and this tall whatever
    /// it shows, so it is laid out before its picture comes.
    static let placeMapHeight: Double = 200
    /// How far a place stays in from the map's edges, so its whole pin shows.
    static let placeMapPadding: Double = 28
    /// A pin: the place's number on a disc, and how much larger it is drawn
    /// while it is lit. On its card the number takes the compact card's icon
    /// place, at `cardIconSize`.
    static let placePinSize: Double = 22
    static let placePinLitScale: Double = 1.25
    /// A place card (M72 §8.1): one size whatever its record holds, the
    /// compact card's face with room for a second line of facts.
    static let placeCardWidth: Double = 240
    static let placeCardHeight: Double = cardHeight + 16
    /// A place's popover (M72 §14.1), one size whatever it holds, so nothing
    /// moves when Apple's card comes: the width MapKit lays the card out at,
    /// and a height whose first screen ends between two of the card's rows
    /// whichever place it shows, after the week's hours under a place's
    /// photo, and after the phone or the website where it has none. The
    /// rest, the address and the ways to get there among it, is a short
    /// scroll below.
    static let placePopoverWidth: Double = 320
    static let placePopoverHeight: Double = 358
}

/// The records a reply carries, drawn under its words (M72 §6.3): each of
/// its blocks by its type, in the order the row holds them. A places block
/// with no places, which the contract never sends, draws nothing.
struct ChatRecords: View {
    let blocks: [CompanionBlock]

    @Environment(\.chatRows) private var rows

    var body: some View {
        if let rows {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .places(let places):
                    if !places.isEmpty {
                        ChatPlaces(places: places, width: rows.columnWidth)
                    }
                }
            }
        }
    }
}

/// A reply's places (M72 §8.1): a map at the reply's width with a numbered
/// pin for each, then a sideways lane of their cards in the same order,
/// which scrolls as the M66 strip does. A click on a card or a pin shows a
/// place Apple Maps found at Apple's own card for it, in a popover at what
/// was clicked (§14.1), and opens any other in Maps; the pointer on a card
/// lights its pin.
struct ChatPlaces: View {
    let places: [CompanionPlace]
    let width: Double

    /// The number of the place whose card is under the pointer.
    @State private var lit: Int?
    /// The place whose card is open, and at what: one at a time.
    @StateObject private var cards = ChatPlaceCards()
    @Environment(\.chatRows) private var rows

    var body: some View {
        let numbered = ChatNumberedPlace.numbering(places)

        VStack(alignment: .leading, spacing: ChatMetrics.stripTopGap) {
            ChatPlaceMap(
                places: numbered,
                size: CGSize(width: width, height: ChatMetrics.placeMapHeight),
                lit: lit,
                cards: cards,
                open: { open($0, at: .pin) }
            )
            ChatStripLane(items: numbered, itemWidth: ChatMetrics.placeCardWidth, width: width, trailing: false) { place in
                ChatPlaceCard(
                    place: place,
                    cards: cards,
                    open: { open(place, at: .card) },
                    openInMaps: { rows?.links.openInMaps(place.place) },
                    hover: { hover(place.number, $0) }
                )
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// A click on a place, through the one content link opener: a place
    /// Apple Maps found opens its card here, at what was clicked, in place of
    /// any card already open (`ChatPlaceCards`), and any other goes straight
    /// to Maps.
    private func open(_ place: ChatNumberedPlace, at anchor: ChatPlaceShown.Anchor) {
        guard let identifier = rows?.links.show(place.place) else { return }

        cards.ask(ChatPlaceShown(number: place.number, identifier: identifier, anchor: anchor))
    }

    /// The pointer reaching a card lights its pin; leaving it puts the pin
    /// out unless another card has lit its own since.
    private func hover(_ number: Int, _ hovering: Bool) {
        if hovering {
            lit = number
        } else if lit == number {
            lit = nil
        }
    }
}

/// The place whose card a reply's places show (M72 §14.1): by its number,
/// with Apple's identifier its card is asked for by, at its card in the lane
/// or its pin on the map, whichever was clicked, which the popover is
/// anchored to.
struct ChatPlaceShown: Identifiable, Equatable {
    enum Anchor: Equatable {
        case card
        case pin
    }

    let number: Int
    let identifier: String
    let anchor: Anchor

    var id: String { "\(number) \(anchor)" }
}

/// The one card a reply's places show at a time (M72 §14.1), and the order
/// its popovers come and go in. A popover asked for while another is still
/// on screen, even one already closing, is never presented, so a card asked
/// for then waits until the one on screen has gone, and comes in its place.
/// Asking for the card already on screen puts it away instead.
///
/// One object the popovers share rather than a value they bind to: a
/// popover's binding can hand back the value it was presented with, and
/// writing that back would lose a card asked for since.
@MainActor
final class ChatPlaceCards: ObservableObject {
    /// The card whose popover is presented, at its anchor.
    @Published private(set) var shown: ChatPlaceShown?
    /// The card whose popover is on screen, from its appearing until it has
    /// gone, which outlasts `shown` while it closes.
    private(set) var onScreen: ChatPlaceShown?
    /// The card asked for while another was on screen.
    private(set) var next: ChatPlaceShown?

    /// A click on a place Apple Maps found, or Return on its card.
    func ask(_ card: ChatPlaceShown) {
        guard let current = onScreen else {
            shown = card
            return
        }

        shown = nil
        next = card == current ? nil : card
    }

    /// The system closed the card's popover: on Escape, a click outside, or
    /// the card's own close button.
    func closed(_ card: ChatPlaceShown) {
        guard shown == card else { return }

        shown = nil
    }

    func appeared(_ card: ChatPlaceShown) {
        onScreen = card
    }

    /// The card's popover has gone; a card asked for meanwhile comes now.
    func gone(_ card: ChatPlaceShown) {
        guard onScreen == card else { return }

        onScreen = nil
        if let next { shown = next }
        next = nil
    }
}

/// A place with the number its pin and its card show: its place in the
/// reply's order, from one.
struct ChatNumberedPlace: Identifiable, Equatable {
    let number: Int
    let place: CompanionPlace

    var id: String { String(number) }

    static func numbering(_ places: [CompanionPlace]) -> [ChatNumberedPlace] {
        places.enumerated().map { ChatNumberedPlace(number: $0.offset + 1, place: $0.element) }
    }
}

/// The map: each place's numbered pin where the area's projection puts it
/// (`PlaceMapArea.point(of:in:)`), drawn from the record at once, and under
/// them a picture of the area, drawn while it is on screen through the
/// previews (`ChatPreviews.map`) in the app's light or dark. Until the
/// picture comes, and where it cannot, the pins stand on the tiles' quiet
/// fill in their true places, with the tiles' progress mark once the wait is
/// long enough to notice, so only the map ever arrives under them. The pins
/// are drawn here rather than into the picture, so lighting one redraws no
/// map, and they follow light and dark with the app. VoiceOver reads it as
/// one picture, by the places it shows: their cards carry what a pin does.
private struct ChatPlaceMap: View {
    let places: [ChatNumberedPlace]
    let size: CGSize
    let lit: Int?
    let cards: ChatPlaceCards
    let open: (ChatNumberedPlace) -> Void

    /// The previews' last answer, with what it answered: one for another
    /// size or appearance is not shown.
    @State private var answered: (key: ChatPreviewKey, outcome: ChatPreviewOutcome)?
    @State private var onScreen = false
    @State private var slow = false
    @Environment(\.chatRows) private var rows
    @Environment(\.displayScale) private var scale
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let request = ChatMapRequest(
            places: places.map(\.place.location),
            size: size,
            scale: scale,
            appearance: colorScheme == .dark ? .dark : .light
        )
        // Asked again whenever what it asks for changes, and only on screen.
        let asking = onScreen ? request.key : nil
        let answer = answered?.key == request.key ? answered?.outcome : nil

        ChatTileFrame(size: size) {
            ZStack(alignment: .topLeading) {
                if case .made(.map(let picture))? = answer {
                    Image(decorative: picture.image, scale: scale)
                        .resizable()
                } else if answer == nil, slow {
                    ActivityMark()
                        .padding(Spacing.xs)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }

                pins(in: request.area)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ProductStrings[.chatPlacesMap])
        .accessibilityValue(Self.spoken(places))
        .accessibilityAddTraits(.isImage)
        .onScrollVisibilityChange(threshold: 0.01) { onScreen = $0 }
        .task(id: asking) {
            guard asking != nil, let rows else { return }

            let outcome = await rows.media.previews.map(request)
            guard !Task.isCancelled else { return }

            answered = (request.key, outcome)
        }
        .task(id: asking) {
            slow = false
            guard asking != nil else { return }

            try? await Task.sleep(for: ChatMetrics.tileProgressDelay)
            slow = !Task.isCancelled
        }
    }

    /// The places' names, as a list.
    private static func spoken(_ places: [ChatNumberedPlace]) -> String {
        let names = places.map(\.place.name)
        return names.dropFirst().reduce(names[0], ProductStrings.commaPair)
    }

    /// Each place's pin where the area puts it, the lit one over the rest.
    private func pins(in area: PlaceMapArea) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(places) { place in
                ChatPlacePin(place: place, lit: lit == place.number, cards: cards) { open(place) }
                    .position(area.point(of: place.place.location, in: size))
                    .zIndex(lit == place.number ? 1 : 0)
            }
        }
        .frame(width: size.width, height: size.height)
    }
}

/// A place's pin: its number on the primary control's disc, which reads on
/// the light map and the dark one alike, ringed in the card's fill to lift it
/// off the streets. Lit, while its card or the pin itself is under the
/// pointer, it grows a little and its ring takes the accent. A click shows the
/// place as its card's click does, its popover anchored at the pin.
private struct ChatPlacePin: View {
    let place: ChatNumberedPlace
    let lit: Bool
    let cards: ChatPlaceCards
    let open: () -> Void

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shown = lit || hovering

        Button(action: open) {
            ChatPlaceNumber(number: place.number, size: ChatMetrics.placePinSize)
                .overlay(
                    Circle().strokeBorder(
                        (shown ? Palette.accent : Palette.cardFill).color,
                        lineWidth: Stroke.heroBorder
                    )
                )
                .scaleEffect(shown ? ChatMetrics.placePinLitScale : 1)
        }
        .buttonStyle(ChatTileButtonStyle())
        .focusable(false)
        .onHover { hovering = $0 }
        .help(place.place.name)
        .modifier(ChatPlacePopover(number: place.number, anchor: .pin, cards: cards))
        .animation(Motion(reduceMotion: reduceMotion).animation(.stepCrossfade), value: shown)
    }
}

/// A place's number on the primary control's disc, as its pin and its card
/// both show it.
private struct ChatPlaceNumber: View {
    let number: Int
    let size: Double

    var body: some View {
        Text(number.formatted())
            .fermixType(Typography.style(.caption).weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(ButtonRecipe.primaryLabel.color)
            .frame(width: size, height: size)
            .background(Circle().fill(ButtonRecipe.primaryFill.color))
            .accessibilityHidden(true)
    }
}

/// A place's card (M72 §8.1), one size whatever its record holds: its number
/// beside its name, then a line of rating, price and kind and a line of
/// today's hours and the distance, each as the record has it
/// (`ChatPlaceFacts`). A click, or Return while it has focus, shows a place
/// Apple Maps found at Apple's own card for it, in a popover anchored here,
/// and opens any other in Maps; its menu opens the place in Maps whichever it
/// is, opens its website, as a link in a reply opens, and copies its address.
private struct ChatPlaceCard: View {
    let place: ChatNumberedPlace
    let cards: ChatPlaceCards
    let open: () -> Void
    let openInMaps: () -> Void
    let hover: (Bool) -> Void

    @Environment(\.openURL) private var openURL

    var body: some View {
        let facts = ChatPlaceFacts(place.place)

        Button(action: open) {
            ChatTileFrame(size: CGSize(width: ChatMetrics.placeCardWidth, height: ChatMetrics.placeCardHeight)) {
                HStack(spacing: Spacing.s) {
                    ChatPlaceNumber(number: place.number, size: ChatMetrics.cardIconSize)

                    VStack(alignment: .leading, spacing: 0) {
                        Text(place.place.name)
                            .fermixType(Typography.style(.callout))
                            .foregroundStyle(Palette.ink.color)
                        ForEach(Array(facts.lines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .fermixType(Typography.style(.caption))
                                .foregroundStyle(Palette.secondary.color)
                        }
                    }
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, Spacing.s)
            }
        }
        .buttonStyle(ChatTileButtonStyle())
        .onKeyPress(.return) {
            open()
            return .handled
        }
        .onHover(perform: hover)
        .help(place.place.name)
        .contextMenu { menu(facts) }
        .modifier(ChatPlacePopover(number: place.number, anchor: .card, cards: cards))
        .accessibilityLabel(facts.spoken(name: place.place.name))
        .accessibilityHint(facts.hint)
    }

    /// Open in Maps always, which opens the Maps app whatever a click does;
    /// Open website where the record has an address that parses; Copy
    /// address where it has an address.
    @ViewBuilder
    private func menu(_ facts: ChatPlaceFacts) -> some View {
        Button(ProductStrings[.chatPlaceOpenInMaps], action: openInMaps)
        if let website = facts.website {
            Button(ProductStrings[.chatPlaceOpenWebsite]) { openURL(website) }
        }
        if let address = place.place.address {
            Button(ProductStrings[.chatPlaceCopyAddress]) { Clipboard.write(address) }
        }
    }
}

/// The one popover a reply's places show (M72 §14.1), at a place's card or
/// its pin, whichever was clicked (`ChatPlaceCards`): presented while it is
/// this place's at this anchor, and let go when the system closes it, on
/// Escape or a click outside. It is a transient popover as the info
/// control's is, so it never stacks on another popup, and it tells the
/// cards when it is on screen and when it has gone.
private struct ChatPlacePopover: ViewModifier {
    let number: Int
    let anchor: ChatPlaceShown.Anchor
    @ObservedObject var cards: ChatPlaceCards

    @Environment(\.chatRows) private var rows

    func body(content: Content) -> some View {
        content.popover(item: presented) { shown in
            if let rows {
                ChatPlaceCardPopover(identifier: shown.identifier, rows: rows)
                    .onAppear { cards.appeared(shown) }
                    .onDisappear { cards.gone(shown) }
            }
        }
    }

    private var presented: Binding<ChatPlaceShown?> {
        Binding {
            cards.shown.flatMap { $0.number == number && $0.anchor == anchor ? $0 : nil }
        } set: { now in
            guard now == nil, let shown = cards.shown, shown.number == number, shown.anchor == anchor else { return }

            cards.closed(shown)
        }
    }
}

/// What a place's popover holds (M72 §14.1): Apple's own card for the place,
/// as MapKit draws it, with its photos, hours and whether it is open now,
/// inside Fermix rather than in Maps, and nothing of the app's own around it.
/// One size whatever it holds (`placePopoverHeight`), so while Apple is asked
/// it holds the tiles' quiet progress mark, once the wait is long enough to
/// notice, and where Maps has no card for the place it says so in one
/// sentence. The place is never looked up another way. The card's own close
/// button puts the popover away, as Escape does.
private struct ChatPlaceCardPopover: View {
    let identifier: String
    /// The chat's, handed in rather than read from the environment, which a
    /// popover's content is not promised.
    let rows: ChatRowContext

    @State private var answer: PlaceCardAnswer?
    @State private var slow = false
    @Environment(\.dismiss) private var dismiss

    private let size = CGSize(width: ChatMetrics.placePopoverWidth, height: ChatMetrics.placePopoverHeight)

    var body: some View {
        ZStack {
            switch answer {
            case .card(let card)?:
                ChatPlaceCardHost(card: card)
            case .said(let sentence)?:
                Text(sentence)
                    .fermixType(Typography.style(.calloutSmall))
                    .foregroundStyle(Palette.secondary.color)
                    .multilineTextAlignment(.center)
                    .padding(Spacing.s)
            case nil:
                if slow {
                    ActivityMark()
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .task(id: identifier) {
            let answer = await rows.links.placeCard(identifier, size: size) { dismiss() }
            guard !Task.isCancelled else { return }

            self.answer = answer
        }
        .task(id: identifier) {
            try? await Task.sleep(for: ChatMetrics.tileProgressDelay)
            slow = !Task.isCancelled
        }
    }
}

/// Apple's card as MapKit drew it, hosted as it came (`PlaceMaps.placeCard`):
/// the core never names what it is, and draws nothing of its own on it.
private struct ChatPlaceCardHost: NSViewControllerRepresentable {
    let card: NSViewController

    func makeNSViewController(context: Context) -> NSViewController {
        card
    }

    func updateNSViewController(_ card: NSViewController, context: Context) {}
}

/// What a place card says of its place (M72 §8.1), read from the record
/// alone: its two lines of facts, each without the parts the record lacks,
/// and no line at all where it lacks every one. A place Apple Maps found has
/// no rating, price or hours (§14.1), so its card says its kind, with the
/// distance under it where it has one.
struct ChatPlaceFacts: Equatable {
    /// The rating with its count, the price and the kind:
    /// `4.6 (321)`, `$$`, `Coffee shop`. A count without a rating says
    /// nothing, and is left out with it.
    let summary: [String]
    /// Today's hours exactly as the source gave them, and the distance with
    /// its units: `Thursday 07:00-19:00`, `0.4 km`. A distance without its
    /// units says nothing, and is left out.
    let today: [String]
    /// The place's own website, or its page at the source where it has none:
    /// the first that is a web address (`ReplyLinks.isAddress`), since Open
    /// website goes through the reply's link opener, which hands any other
    /// scheme to the app that owns it.
    let website: URL?
    /// What a click on the card does, as VoiceOver hints it: a place Apple
    /// Maps found shows its card from Maps here, and any other opens in Maps,
    /// as the one content link opener decides (`show`).
    let hint: String

    init(_ place: CompanionPlace, locale: Locale = .current) {
        summary = [
            Self.rating(place.rating, locale: locale),
            place.priceRange,
            place.categories?.first.map(Self.kind)
        ].compactMap { $0 }
        today = [
            place.openingHours?.currentDay,
            Self.distance(place.distance, locale: locale)
        ].compactMap { $0 }
        website = [place.canonicalURL, place.sourceURL]
            .compactMap { $0.flatMap(URL.init(string:)) }
            .first(where: ReplyLinks.isAddress)
        hint = ProductStrings[place.applePlaceID == nil ? .chatPlaceOpenInMaps : .chatPlaceShowCard]
    }

    /// The lines a card draws, each its parts joined by the design's
    /// interpunct.
    var lines: [String] {
        [summary, today].filter { !$0.isEmpty }.map(Self.joined)
    }

    /// What VoiceOver reads for the card: the name, then every part, as a
    /// list.
    func spoken(name: String) -> String {
        (summary + today).reduce(name, ProductStrings.commaPair)
    }

    /// A source's category as the card says it: `coffee_shop` is `Coffee
    /// shop`, in sentence case as all the app's words are.
    static func kind(_ category: String) -> String {
        let words = category.replacingOccurrences(of: "_", with: " ").lowercased()
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    private static func joined(_ parts: [String]) -> String {
        parts.dropFirst().reduce(parts[0], ProductStrings.middot)
    }

    private static func rating(_ rating: CompanionPlaceRating?, locale: Locale) -> String? {
        guard let value = rating?.value else { return nil }

        let shown = value.formatted(.number.precision(.fractionLength(1)).locale(locale))
        guard let count = rating?.count else { return shown }

        let counted = count.formatted(.number.precision(.fractionLength(0)).locale(locale))
        return String(format: ProductStrings[.chatPlaceRatingFormat], shown, counted)
    }

    private static func distance(_ distance: CompanionPlaceDistance?, locale: Locale) -> String? {
        guard let value = distance?.value, let units = distance?.units else { return nil }

        let shown = value.formatted(.number.precision(.fractionLength(0...2)).locale(locale))
        return String(format: ProductStrings[.chatPlaceDistanceFormat], shown, units)
    }
}
