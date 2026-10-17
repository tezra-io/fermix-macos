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
/// which scrolls as the M66 strip does. A click on a card or a pin opens the
/// place in Maps, and the pointer on a card lights its pin.
struct ChatPlaces: View {
    let places: [CompanionPlace]
    let width: Double

    /// The number of the place whose card is under the pointer.
    @State private var lit: Int?
    @Environment(\.chatRows) private var rows

    var body: some View {
        let numbered = ChatNumberedPlace.numbering(places)

        VStack(alignment: .leading, spacing: ChatMetrics.stripTopGap) {
            ChatPlaceMap(
                places: numbered,
                size: CGSize(width: width, height: ChatMetrics.placeMapHeight),
                lit: lit,
                open: open
            )
            ChatStripLane(items: numbered, itemWidth: ChatMetrics.placeCardWidth, width: width, trailing: false) { place in
                ChatPlaceCard(place: place, open: open) { hover(place.number, $0) }
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// Through the one content link opener, straight to Maps.
    private func open(_ place: CompanionPlace) {
        rows?.links.openInMaps(place)
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
    let open: (CompanionPlace) -> Void

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
                ChatPlacePin(place: place, lit: lit == place.number, open: open)
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
/// pointer, it grows a little and its ring takes the accent. A click opens the
/// place in Maps.
private struct ChatPlacePin: View {
    let place: ChatNumberedPlace
    let lit: Bool
    let open: (CompanionPlace) -> Void

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shown = lit || hovering

        Button { open(place.place) } label: {
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
/// (`ChatPlaceFacts`). A click opens the place in Maps; its menu also opens
/// the place's website, as a link in a reply opens, and copies its address.
private struct ChatPlaceCard: View {
    let place: ChatNumberedPlace
    let open: (CompanionPlace) -> Void
    let hover: (Bool) -> Void

    @Environment(\.openURL) private var openURL

    var body: some View {
        let facts = ChatPlaceFacts(place.place)

        Button { open(place.place) } label: {
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
            open(place.place)
            return .handled
        }
        .onHover(perform: hover)
        .help(place.place.name)
        .contextMenu { menu(facts) }
        .accessibilityLabel(facts.spoken(name: place.place.name))
        .accessibilityHint(ProductStrings[.chatPlaceOpenInMaps])
    }

    /// Open in Maps always; Open website where the record has an address
    /// that parses; Copy address where it has an address.
    @ViewBuilder
    private func menu(_ facts: ChatPlaceFacts) -> some View {
        Button(ProductStrings[.chatPlaceOpenInMaps]) { open(place.place) }
        if let website = facts.website {
            Button(ProductStrings[.chatPlaceOpenWebsite]) { openURL(website) }
        }
        if let address = place.place.address {
            Button(ProductStrings[.chatPlaceCopyAddress]) { Clipboard.write(address) }
        }
    }
}

/// What a place card says of its place (M72 §8.1), read from the record
/// alone: its two lines of facts, each without the parts the record lacks,
/// and no line at all where it lacks every one.
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
