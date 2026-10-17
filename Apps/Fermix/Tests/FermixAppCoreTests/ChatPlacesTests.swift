import CoreGraphics
import Foundation
import Testing

@testable import FermixAppCore

/// A reply's places (M72 §8): what a card says from its record alone, the
/// Maps address the app builds itself, the area a map shows, and the strip
/// leaving a place's links to its card. No view is built, and nothing is
/// opened.
@Suite("Chat places")
struct ChatPlacesTests {
    private static let english = Locale(identifier: "en_US")

    private static func place(
        _ name: String = "Example Coffee",
        canonical: String? = "https://example.coffee/",
        source: String? = "https://provider.example/place/1",
        at location: CompanionPlaceLocation = CompanionPlaceLocation(latitude: 40.7233, longitude: -74.0030),
        address: String? = "12 Example St, New York",
        rating: CompanionPlaceRating? = CompanionPlaceRating(value: 4.6, best: 5, count: 321),
        price: String? = "$$",
        categories: [String]? = ["coffee_shop"],
        hours: String? = "Thursday 07:00-19:00",
        distance: CompanionPlaceDistance? = CompanionPlaceDistance(value: 0.4, units: "km")
    ) -> CompanionPlace {
        CompanionPlace(
            name: name,
            canonicalURL: canonical,
            sourceURL: source,
            location: location,
            address: address,
            rating: rating,
            priceRange: price,
            categories: categories,
            openingHours: hours.map(CompanionPlaceHours.init),
            distance: distance
        )
    }

    // MARK: - A card's words

    @Test("a card with every field says the plan's two lines")
    func everyField() {
        let facts = ChatPlaceFacts(Self.place(), locale: Self.english)

        #expect(facts.lines == ["4.6 (321) · $$ · Coffee shop", "Thursday 07:00-19:00 · 0.4 km"])
        #expect(facts.spoken(name: "Example Coffee") == "Example Coffee, 4.6 (321), $$, Coffee shop, Thursday 07:00-19:00, 0.4 km")
        #expect(facts.website == URL(string: "https://example.coffee/"))
    }

    @Test("a part the record lacks leaves no gap, and a line with no parts is no line")
    func missingParts() {
        let noRating = ChatPlaceFacts(Self.place(rating: nil), locale: Self.english)
        let noHours = ChatPlaceFacts(Self.place(hours: nil), locale: Self.english)
        let bare = ChatPlaceFacts(
            Self.place(rating: nil, price: nil, categories: nil, hours: nil, distance: nil),
            locale: Self.english
        )

        #expect(noRating.lines == ["$$ · Coffee shop", "Thursday 07:00-19:00 · 0.4 km"])
        #expect(noHours.lines == ["4.6 (321) · $$ · Coffee shop", "0.4 km"])
        #expect(bare.lines.isEmpty)
        #expect(bare.spoken(name: "Bare") == "Bare")
    }

    /// A count of ratings without the rating, or a distance without its
    /// units, says nothing true on its own.
    @Test("a rating without its count stands alone; a count without its rating and a distance without units are left out")
    func halfFacts() {
        let unCounted = ChatPlaceFacts(Self.place(rating: CompanionPlaceRating(value: 4, best: nil, count: nil)), locale: Self.english)
        let countOnly = ChatPlaceFacts(Self.place(rating: CompanionPlaceRating(value: nil, best: 5, count: 12)), locale: Self.english)
        let noUnits = ChatPlaceFacts(Self.place(distance: CompanionPlaceDistance(value: 0.4, units: nil)), locale: Self.english)
        let many = ChatPlaceFacts(Self.place(rating: CompanionPlaceRating(value: 4.75, best: 5, count: 1204)), locale: Self.english)

        #expect(unCounted.summary == ["4.0", "$$", "Coffee shop"])
        #expect(countOnly.summary == ["$$", "Coffee shop"])
        #expect(noUnits.today == ["Thursday 07:00-19:00"])
        #expect(many.summary.first == "4.8 (1,204)")
    }

    @Test("a source's category is said in sentence case, the first one only")
    func kinds() {
        #expect(ChatPlaceFacts.kind("coffee_shop") == "Coffee shop")
        #expect(ChatPlaceFacts.kind("Book_Store") == "Book store")
        #expect(ChatPlaceFacts.kind("cafe") == "Cafe")
        #expect(ChatPlaceFacts(Self.place(categories: ["espresso_bar", "bakery"]), locale: Self.english).summary.last == "Espresso bar")
    }

    @Test("the website is the place's own, else its page at the source, else none")
    func website() {
        #expect(ChatPlaceFacts(Self.place(canonical: nil)).website == URL(string: "https://provider.example/place/1"))
        #expect(ChatPlaceFacts(Self.place(canonical: nil, source: nil)).website == nil)
    }

    @Test("a website that is not a web address is never offered, so no record opens another app")
    func websiteIsAWebAddress() {
        let other = ChatPlaceFacts(Self.place(canonical: "shortcuts://run-shortcut?name=x"))
        #expect(other.website == URL(string: "https://provider.example/place/1"))
        #expect(ChatPlaceFacts(Self.place(canonical: "shortcuts://x", source: "file:///etc/hosts")).website == nil)
    }

    // MARK: - Maps

    /// Decision 3: Maps looks the name up at the place's own coordinates; the
    /// reply's links, and the record's own addresses, never reach it.
    @Test("the Maps address is the place's name at its coordinates, built from the record alone")
    func mapsAddress() {
        let url = PlaceMapsAddress.url(for: Self.place())

        #expect(url.absoluteString == "maps://?q=Example%20Coffee&ll=40.7233,-74.003")
        #expect(url.scheme == "maps")
        #expect(!url.absoluteString.contains("example.coffee"))
        #expect(!url.absoluteString.contains("provider.example"))
    }

    @Test("a name's own marks stay the name and cannot add to the address")
    func mapsAddressEncodesTheName() {
        let url = PlaceMapsAddress.url(for: Self.place("Café & Bar #2 + more=yes?", at: CompanionPlaceLocation(latitude: -33.8688, longitude: 151.2093)))
        let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)

        #expect(url.absoluteString == "maps://?q=Caf%C3%A9%20%26%20Bar%20%232%20%2B%20more%3Dyes%3F&ll=-33.8688,151.2093")
        #expect(parts?.queryItems?.map(\.name) == ["q", "ll"])
        #expect(parts?.queryItems?.first?.value == "Café & Bar #2 + more=yes?")
    }

    // MARK: - The map's area

    private static let mapSize = CGSize(width: 680, height: 200)

    private static func point(_ place: CompanionPlaceLocation, in area: PlaceMapArea) -> CGPoint {
        area.point(of: place, in: mapSize)
    }

    /// A place at a spot on the unit square: Web Mercator undone.
    private static func place(atSpot x: Double, _ y: Double) -> CompanionPlaceLocation {
        CompanionPlaceLocation(latitude: (2 * atan(exp((0.5 - y) * 2 * .pi)) - .pi / 2) * 180 / .pi, longitude: x * 360 - 180)
    }

    /// The one answer to where a pin goes, the map picture or none: the
    /// area's corners are the picture's, and its middle the picture's middle.
    /// A snapshot drawn of exactly the area puts each place at this point
    /// too, which a run of MapKit on this Mac showed and no test can, since
    /// none asks MapKit for anything.
    @Test("a place falls in a picture of the area by the area's own projection, from the top left")
    func pointInThePicture() {
        let area = PlaceMapArea(x: 0.2945, y: 0.3759, width: 0.0004, height: 0.0001)

        for (spot, point) in [
            ((0.2945, 0.3759), CGPoint(x: 0, y: 0)),
            ((0.2949, 0.3760), CGPoint(x: Self.mapSize.width, y: Self.mapSize.height)),
            ((0.2947, 0.37595), CGPoint(x: Self.mapSize.width / 2, y: Self.mapSize.height / 2)),
            ((0.2946, 0.375925), CGPoint(x: Self.mapSize.width / 4, y: Self.mapSize.height / 4))
        ] {
            let drawn = area.point(of: Self.place(atSpot: spot.0, spot.1), in: Self.mapSize)
            #expect(abs(drawn.x - point.x) < 1e-6 && abs(drawn.y - point.y) < 1e-6, "\(spot) at \(drawn)")
        }

        let north = area.point(of: CompanionPlaceLocation(latitude: 40.73, longitude: -74), in: Self.mapSize)
        let south = area.point(of: CompanionPlaceLocation(latitude: 40.72, longitude: -74), in: Self.mapSize)
        #expect(north.y < south.y)
    }

    private static let soho = [
        CompanionPlaceLocation(latitude: 40.7239, longitude: -74.0011),
        CompanionPlaceLocation(latitude: 40.7247, longitude: -73.9986),
        CompanionPlaceLocation(latitude: 40.7255, longitude: -74.0023),
        CompanionPlaceLocation(latitude: 40.7226, longitude: -74.0004)
    ]

    @Test("the area keeps the map's proportion and every place its pin's room from each edge")
    func areaFitsEveryPlace() {
        let wide = [CompanionPlaceLocation(latitude: 51.5007, longitude: -0.1246), CompanionPlaceLocation(latitude: 51.5081, longitude: -0.0759)]
        let tall = [CompanionPlaceLocation(latitude: 48.8867, longitude: 2.3431), CompanionPlaceLocation(latitude: 48.8462, longitude: 2.3464)]

        for places in [Self.soho, wide, tall] {
            let area = PlaceMapArea.fitting(places, in: Self.mapSize, padding: 28)

            #expect(abs(area.width / area.height - Self.mapSize.width / Self.mapSize.height) < 1e-9)
            for place in places {
                let point = Self.point(place, in: area)
                #expect(point.x >= 28 - 1e-6 && point.x <= Self.mapSize.width - 28 + 1e-6, "\(place) at \(point)")
                #expect(point.y >= 28 - 1e-6 && point.y <= Self.mapSize.height - 28 + 1e-6, "\(place) at \(point)")
            }
        }
    }

    /// The places' middle is the map's middle, and the side that limits the
    /// fit puts its outermost places exactly at the padding.
    @Test("the area is centred on the places and no larger than their pins need")
    func areaIsTight() {
        let wide = [CompanionPlaceLocation(latitude: 51.5007, longitude: -0.1246), CompanionPlaceLocation(latitude: 51.5014, longitude: -0.0759)]
        let area = PlaceMapArea.fitting(wide, in: Self.mapSize, padding: 28)
        let points = wide.map { Self.point($0, in: area) }

        #expect(abs(points.map(\.x).min()! - 28) < 1e-6)
        #expect(abs(points.map(\.x).max()! - (Self.mapSize.width - 28)) < 1e-6)
        #expect(abs((points[0].y + points[1].y) / 2 - Self.mapSize.height / 2) < 1e-6)
    }

    /// One place, or places close together, still show the streets around
    /// them: the shorter side spans the minimum on the ground.
    @Test("one place is centred, with the minimum span across the map's shorter side")
    func onePlaceKeepsTheMinimumSpan() {
        let only = CompanionPlaceLocation(latitude: 40.7233, longitude: -74.0030)
        let area = PlaceMapArea.fitting([only], in: Self.mapSize, padding: 28)
        let point = Self.point(only, in: area)
        let metersPerUnit = PlaceMapArea.equatorMeters * cos(only.latitude * .pi / 180)

        #expect(abs(point.x - Self.mapSize.width / 2) < 1e-6)
        #expect(abs(point.y - Self.mapSize.height / 2) < 1e-6)
        #expect(abs(area.height * metersPerUnit - PlaceMapArea.minimumMeters) < 1)
    }

    // MARK: - The strip

    private static let home = ChatHome(roots: ["/Users/me/.fermix"])

    private static func strip(_ text: String, blocks: [CompanionBlock], previews: [CompanionLinkPreview] = []) -> ChatStrip {
        ChatStrip(text: text, plain: false, mediaRefs: [], linkPreviews: previews, blocks: blocks, userHome: "/Users/me", home: Self.home)
    }

    private static func links(_ strip: ChatStrip) -> [String] {
        strip.cards.compactMap { item in
            guard case .link(let link) = item else { return nil }

            return link.address.absoluteString
        }
    }

    /// Each destination once (M66 §3.1): a place's card opens its page, so
    /// the strip leaves the reply's link to it there, matched as the engine
    /// matches them, and keeps every other link.
    @Test("the strip leaves a place's links to its card and keeps every other link")
    func stripLeavesPlaceLinks() {
        let text = """
            Two places and a guide.

            - [Example Coffee](https://Example.Coffee#menu) is quiet.
            - [Bare Cafe](https://provider.example/place/2/) has outlets.

            The [guide](https://guide.example/soho) has more.
            """
        let blocks: [CompanionBlock] = [.places([Self.place(), Self.place("Bare Cafe", canonical: nil, source: "https://provider.example/place/2")])]
        let preview = CompanionLinkPreview(url: "https://example.coffee/", site: "Example", title: "Example Coffee", description: nil, imageRef: nil)

        #expect(Self.links(Self.strip(text, blocks: [])).count == 3)
        #expect(Self.links(Self.strip(text, blocks: blocks, previews: [preview])) == ["https://guide.example/soho"])
    }

    @Test("a place's link is matched without its case, fragment and trailing slash, and nothing more")
    func placeLinkMatching() {
        let own = ChatPlaceLink(URL(string: "https://example.coffee/menu")!)

        #expect(ChatPlaceLink(URL(string: "HTTPS://Example.Coffee/menu/#today")!) == own)
        #expect(ChatPlaceLink(URL(string: "https://example.coffee/Menu")!) != own)
        #expect(ChatPlaceLink(URL(string: "https://example.coffee/menu?day=1")!) != own)
        #expect(ChatPlaceLink.links(of: []).isEmpty)
    }
}

/// A place opens in Maps through the one content link opener, whatever the
/// person's preference for links (M72 decision 3).
@Suite("Opening a place")
@MainActor
struct PlaceOpeningTests {
    @Test("a place goes to Maps at the address built from its record, never to the pane", arguments: LinkDestination.allCases)
    func placeOpensInMaps(_ destination: LinkDestination) {
        let harness = BrowserHarness()
        let workspace = RecordingWorkspaceOpener()
        let preference = InMemoryLinkPreferenceStore()
        preference.linkDestination = destination
        let opener = ContentLinkOpener(preference: preference, browser: harness.coordinator, workspace: workspace)
        let place = FixtureRepliesScript.placeRecords[1]

        opener.openInMaps(place)

        #expect(workspace.opened == [PlaceMapsAddress.url(for: place)])
        #expect(workspace.opened.first?.scheme == "maps")
        #expect(harness.model.tabs.isEmpty)
    }
}
