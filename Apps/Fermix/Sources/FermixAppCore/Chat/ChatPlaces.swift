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
}

/// The records a reply carries, drawn under its words (M72 §6.3): each of
/// its blocks by its type, in the order the row holds them. A places block
/// with no places, which the contract never sends, draws nothing.
struct ChatRecords: View {
    let blocks: [CompanionBlock]
    /// The row's sequence number, which tells its places from another
    /// reply's.
    let reply: Int

    @Environment(\.chatRows) private var rows

    var body: some View {
        if let rows {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .places(let places):
                    if !places.isEmpty {
                        ChatPlaces(places: places, width: rows.columnWidth, reply: reply, selection: rows.places)
                    }
                }
            }
        }
    }
}

/// A reply's places (M72 §8.1): a map at the reply's width with a numbered
/// pin for each, then a sideways lane of their cards in the same order,
/// which scrolls as the M66 strip does. A click on a card or a pin, or
/// Return on a card, shows a place Apple Maps found on the map itself, with
/// Apple's compact callout at its pin (§14.1), and opens any other in Maps
/// (`ChatPlaceSelection`); Escape puts the place shown away. The pointer on
/// a card lights its pin.
struct ChatPlaces: View {
    let places: [CompanionPlace]
    let width: Double
    let reply: Int
    @ObservedObject var selection: ChatPlaceSelection

    @StateObject private var light = ChatPlaceLight()
    @Environment(\.chatRows) private var rows

    var body: some View {
        let numbered = ChatNumberedPlace.numbering(places)

        VStack(alignment: .leading, spacing: ChatMetrics.stripTopGap) {
            ChatPlaceMap(
                places: numbered,
                size: CGSize(width: width, height: ChatMetrics.placeMapHeight),
                reply: reply,
                shown: selection.shown?.reply == reply ? selection.shown : nil,
                light: light
            )
            ChatStripLane(items: numbered, itemWidth: ChatMetrics.placeCardWidth, width: width, trailing: false) { place in
                ChatPlaceCard(
                    place: place,
                    open: { selection.click(place.place, numbered: place.number, in: reply) },
                    openInMaps: { rows?.links.openInMaps(place.place) },
                    hover: { light.hover(place.number, $0) }
                )
            }
        }
        .accessibilityElement(children: .contain)
        .onExitCommand { selection.dismiss(in: reply) }
    }
}

/// Which pin is lit: the one whose card is under the pointer. One object
/// rather than the view's own state, because the live map's pins are drawn
/// apart from the view, inside the map, and light as the picture's do.
@MainActor
final class ChatPlaceLight: ObservableObject {
    @Published private(set) var lit: Int?

    /// The pointer reaching a card lights its pin; leaving it puts the pin
    /// out unless another card has lit its own since.
    func hover(_ number: Int, _ hovering: Bool) {
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
///
/// While one of its places is shown (§14.1), the same area stands live over
/// the picture (`PlaceMaps.liveMap`): drawn unseen until it is drawn as the
/// picture is, then taking the picture's place, its pins inside it, as the
/// place is selected on it and Apple's callout comes, so nothing moves but
/// what fitting the callout moves. When the place is put away, the live map
/// returns to exactly its area, then goes, and the picture is there under
/// it. The chat has one at a time (`ChatPlaceSelection`); one whose size or
/// light changes goes, with its place.
private struct ChatPlaceMap: View {
    let places: [ChatNumberedPlace]
    let size: CGSize
    let reply: Int
    /// The place shown on this map, where it is this reply's.
    let shown: ChatPlaceShown?
    @ObservedObject var light: ChatPlaceLight

    /// The previews' last answer, with what it answered: one for another
    /// size or appearance is not shown.
    @State private var answered: (key: ChatPreviewKey, outcome: ChatPreviewOutcome)?
    @State private var onScreen = false
    @State private var slow = false
    /// The live map, while a place is shown or being put away.
    @State private var live: (any PlaceLiveMap)?
    /// Whether the live map is drawn with its place and stands for the
    /// picture.
    @State private var liveDrawn = false
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

                if let live {
                    ChatLiveMapHost(map: live)
                        .id(ObjectIdentifier(live))
                        .opacity(liveDrawn ? 1 : 0)
                }

                if !liveDrawn {
                    pins(in: request.area)
                }
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
        .task(id: shown) {
            guard let rows else { return }

            if let shown {
                await show(shown, on: live ?? liveMap(request, rows), rows)
            } else if let live {
                await live.putAway()
                guard !Task.isCancelled else { return }

                self.live = nil
                liveDrawn = false
            }
        }
        .onChange(of: request.key) {
            live = nil
            liveDrawn = false
            rows?.places.dismiss(in: reply)
        }
    }

    /// The place on the live map, which stands for the picture once it is
    /// drawn with it; where Maps cannot show it, the selection hears so and
    /// the picture stays.
    private func show(_ shown: ChatPlaceShown, on map: any PlaceLiveMap, _ rows: ChatRowContext) async {
        live = map
        do {
            try await map.show(shown.number, identifier: shown.identifier)
            guard !Task.isCancelled else { return }

            liveDrawn = true
        } catch {
            guard !Task.isCancelled else { return }

            rows.places.failed(shown)
        }
    }

    /// The area live, its pins the places' own faces, lit as the picture's
    /// are, and what the person asks of it handed to the selection.
    private func liveMap(_ request: ChatMapRequest, _ rows: ChatRowContext) -> any PlaceLiveMap {
        let pins = places.map { place in
            PlaceMapPin(
                number: place.number,
                location: place.place.location,
                face: NSHostingView(rootView: ChatLivePin(place: place, light: light))
            )
        }
        let places = places
        let reply = reply

        return rows.media.maps.liveMap(of: request.area, size: size, appearance: request.appearance, pins: pins) { number in
            guard let number else {
                rows.places.dismiss(in: reply)
                return
            }
            guard let place = places.first(where: { $0.number == number }) else { return }

            rows.places.click(place.place, numbered: number, in: reply)
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
                ChatPlacePin(place: place, lit: light.lit == place.number) {
                    rows?.places.click(place.place, numbered: place.number, in: reply)
                }
                .position(area.point(of: place.place.location, in: size))
                .zIndex(light.lit == place.number ? 1 : 0)
            }
        }
        .frame(width: size.width, height: size.height)
    }
}

/// The live map as `FermixViewers` drew it, hosted as it came: the core
/// never names what it is.
private struct ChatLiveMapHost: NSViewRepresentable {
    let map: any PlaceLiveMap

    func makeNSView(context: Context) -> NSView {
        map.view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}

/// A place's pin on the picture (`ChatPlacePinFace`), lit while its card or
/// the pin itself is under the pointer. A click shows the place as its
/// card's click does.
private struct ChatPlacePin: View {
    let place: ChatNumberedPlace
    let lit: Bool
    let open: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            ChatPlacePinFace(number: place.number, lit: lit || hovering)
        }
        .buttonStyle(ChatTileButtonStyle())
        .focusable(false)
        .onHover { hovering = $0 }
        .help(place.place.name)
    }
}

/// A place's pin on the live map, the same face, lit as the picture's is;
/// the map itself hears its click.
private struct ChatLivePin: View {
    let place: ChatNumberedPlace
    @ObservedObject var light: ChatPlaceLight

    @State private var hovering = false

    var body: some View {
        ChatPlacePinFace(number: place.number, lit: light.lit == place.number || hovering)
            .onHover { hovering = $0 }
            .help(place.place.name)
    }
}

/// A place's pin as it looks, on the picture and on the live map alike: its
/// number on the primary control's disc, which reads on the light map and
/// the dark one alike, ringed in the card's fill to lift it off the
/// streets. Lit, it grows a little and its ring takes the accent.
private struct ChatPlacePinFace: View {
    let number: Int
    let lit: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ChatPlaceNumber(number: number, size: ChatMetrics.placePinSize)
            .overlay(
                Circle().strokeBorder(
                    (lit ? Palette.accent : Palette.cardFill).color,
                    lineWidth: Stroke.heroBorder
                )
            )
            .scaleEffect(lit ? ChatMetrics.placePinLitScale : 1)
            .animation(Motion(reduceMotion: reduceMotion).animation(.stepCrossfade), value: lit)
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
/// Apple Maps found on the map above with Apple's callout at its pin, and
/// opens any other in Maps; its menu opens the place in Maps whichever it
/// is, opens its website, as a link in a reply opens, and copies its address.
private struct ChatPlaceCard: View {
    let place: ChatNumberedPlace
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
    /// Maps found is shown on the map above, and any other opens in Maps, as
    /// the one content link opener decides (`show`).
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
        hint = ProductStrings[place.applePlaceID == nil ? .chatPlaceOpenInMaps : .chatPlaceShowOnMap]
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
