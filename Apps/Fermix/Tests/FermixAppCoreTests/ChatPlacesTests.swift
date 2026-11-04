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
        apple: String? = nil,
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
            applePlaceID: apple,
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

    @Test("a part the record lacks leaves no gap, the street stands in for missing hours, and a line with no parts is no line")
    func missingParts() {
        let noRating = ChatPlaceFacts(Self.place(rating: nil), locale: Self.english)
        let noHours = ChatPlaceFacts(Self.place(hours: nil), locale: Self.english)
        let noHoursOrAddress = ChatPlaceFacts(Self.place(address: nil, hours: nil), locale: Self.english)
        let bare = ChatPlaceFacts(
            Self.place(address: nil, rating: nil, price: nil, categories: nil, hours: nil, distance: nil),
            locale: Self.english
        )

        #expect(noRating.lines == ["$$ · Coffee shop", "Thursday 07:00-19:00 · 0.4 km"])
        #expect(noHours.lines == ["4.6 (321) · $$ · Coffee shop", "12 Example St · 0.4 km"])
        #expect(noHoursOrAddress.lines == ["4.6 (321) · $$ · Coffee shop", "0.4 km"])
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
        #expect(noUnits.visit == ["Thursday 07:00-19:00"])
        #expect(many.summary.first == "4.8 (1,204)")
    }

    /// An Apple Maps place (M72 §14.1) has no rating, price or hours: its
    /// card says its kind, and under it its street, with the distance where
    /// the search had coordinates to measure from, and no stray mark.
    @Test("an Apple Maps place's card says its kind, then its street and its distance where it has one")
    func applePlace() {
        let named = ChatPlaceFacts(Self.applePlace(distance: nil), locale: Self.english)
        let measured = ChatPlaceFacts(Self.applePlace(distance: CompanionPlaceDistance(value: 1.25, units: "km")), locale: Self.english)

        #expect(named.lines == ["Restaurant", "340 Town Center Ave"])
        #expect(named.spoken(name: "Tequila Mama Taqueria") == "Tequila Mama Taqueria, Restaurant, 340 Town Center Ave")
        #expect(measured.lines == ["Restaurant", "340 Town Center Ave · 1.25 km"])
        #expect(measured.spoken(name: "Tequila Mama Taqueria") == "Tequila Mama Taqueria, Restaurant, 340 Town Center Ave, 1.25 km")
        #expect(named.website == URL(string: "https://tequilamama.com/"))
        #expect(ChatPlaceFacts(Self.applePlace(canonical: nil, distance: nil)).website == URL(string: Self.applePage))
    }

    @Test("a street is an address's part before its first comma, and an empty one is none")
    func street() {
        #expect(ChatPlaceFacts.street("3463 Lawrenceville-Suwanee Rd, Unit 110, Suwanee, GA 30024") == "3463 Lawrenceville-Suwanee Rd")
        #expect(ChatPlaceFacts.street(" 88 Wooster St ") == "88 Wooster St")
        #expect(ChatPlaceFacts.street(", Suwanee") == nil)
        #expect(ChatPlaceFacts.street("") == nil)
    }

    /// Apple's own page for the place, as the engine writes it beside the
    /// identifier.
    private static let applePage = "https://maps.apple.com/place?place-id=I15D3EC7F56AE8D5C"

    /// A place as Apple Maps gives it: Apple's identifier and page, its own
    /// website, its kind and address, and nothing else.
    private static func applePlace(canonical: String? = "https://tequilamama.com/", distance: CompanionPlaceDistance?) -> CompanionPlace {
        place(
            "Tequila Mama Taqueria",
            canonical: canonical,
            source: applePage,
            apple: "I15D3EC7F56AE8D5C",
            at: CompanionPlaceLocation(latitude: 34.0555026, longitude: -84.0647238),
            address: "340 Town Center Ave, Suwanee, GA 30024, United States",
            rating: nil,
            price: nil,
            categories: ["restaurant"],
            hours: nil,
            distance: distance
        )
    }

    /// VoiceOver hears what a click does: a place Apple Maps found is shown
    /// on the map (§14.1), and any other opens in Maps.
    @Test("a card's hint says a place Apple Maps found is shown on the map, and any other opens in Maps")
    func hint() {
        #expect(ChatPlaceFacts(Self.applePlace(distance: nil)).hint == ProductStrings[.chatPlaceShowOnMap])
        #expect(ChatPlaceFacts(Self.place()).hint == ProductStrings[.chatPlaceOpenInMaps])
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
}

/// A place opens in Maps through the one content link opener, whatever the
/// person's preference for links (M72 decision 3), by what its record
/// carries: Apple's identifier where Apple Maps found it (§14.1), and the
/// address built from its name and coordinates where another source did. A
/// click shows a place Apple Maps found here instead, on the reply's own
/// map, by its identifier alone.
@Suite("Opening a place")
@MainActor
struct PlaceOpeningTests {
    private static func opener(
        _ destination: LinkDestination = .fermix,
        maps: FakeMediaReader = FakeMediaReader()
    ) -> (ContentLinkOpener, BrowserHarness, RecordingWorkspaceOpener) {
        let harness = BrowserHarness()
        let workspace = RecordingWorkspaceOpener()
        let preference = InMemoryLinkPreferenceStore()
        preference.linkDestination = destination
        let opener = ContentLinkOpener(preference: preference, browser: harness.coordinator, workspace: workspace, maps: maps)

        return (opener, harness, workspace)
    }

    @Test("a place another source found goes to Maps at the address built from its record, never to the pane", arguments: LinkDestination.allCases)
    func placeOpensInMaps(_ destination: LinkDestination) {
        let maps = FakeMediaReader()
        let (opener, harness, workspace) = Self.opener(destination, maps: maps)
        let place = FixtureRepliesScript.placeRecords[1]

        opener.openInMaps(place)

        #expect(workspace.opened == [PlaceMapsAddress.url(for: place)])
        #expect(workspace.opened.first?.scheme == "maps")
        #expect(maps.placesOpened.isEmpty)
        #expect(harness.model.tabs.isEmpty)
    }

    /// Apple's own card, by the identifier alone: no address is built, and
    /// neither the record's links nor the pane are involved.
    @Test("a place Apple Maps found opens at its own card by its identifier, never by an address", arguments: LinkDestination.allCases)
    func applePlaceOpensByIdentifier(_ destination: LinkDestination) {
        let maps = FakeMediaReader()
        let (opener, harness, workspace) = Self.opener(destination, maps: maps)
        let place = FixtureRepliesScript.applePlaceRecords[0]

        opener.openInMaps(place)

        #expect(maps.placesOpened == ["I15D3EC7F56AE8D5C"])
        #expect(workspace.opened.isEmpty)
        #expect(harness.model.tabs.isEmpty)
        #expect(!harness.model.isOpen)
        #expect(harness.model.notice == nil)
    }

    /// An identifier Maps cannot open is said where a reply's file that
    /// cannot open is said, in the pane, which opens to say it; the place is
    /// not looked up again by its name, so no other place can stand in.
    @Test("an identifier Maps cannot open is said in the pane, and the place is never looked up by its name")
    func unopenedIdentifierIsSaid() {
        let maps = FakeMediaReader(findsPlaces: false)
        let (opener, harness, workspace) = Self.opener(maps: maps)

        opener.openInMaps(FixtureRepliesScript.applePlaceRecords[1])

        #expect(maps.placesOpened == ["I47957D91CD7E2F7B"])
        #expect(harness.model.notice == ProductStrings[.browserNoticePlaceNotOpened])
        #expect(harness.model.isOpen)
        #expect(harness.model.tabs.isEmpty)
        #expect(workspace.opened.isEmpty, "the place was looked up again another way")
    }

    // MARK: - A click

    /// The chat is handed the identifier the place is shown by; Maps, the
    /// pane and the workspace are left alone.
    @Test("a click on a place Apple Maps found shows it here by its identifier, and opens nothing", arguments: LinkDestination.allCases)
    func clickShowsAnApplePlace(_ destination: LinkDestination) {
        let maps = FakeMediaReader()
        let (opener, harness, workspace) = Self.opener(destination, maps: maps)

        #expect(opener.show(FixtureRepliesScript.applePlaceRecords[0]) == "I15D3EC7F56AE8D5C")
        #expect(maps.placesOpened.isEmpty)
        #expect(workspace.opened.isEmpty)
        #expect(harness.model.tabs.isEmpty)
        #expect(!harness.model.isOpen)
    }

    @Test("a click on a place another source found opens Maps at its address, and shows nothing here", arguments: LinkDestination.allCases)
    func clickOpensAnotherPlaceInMaps(_ destination: LinkDestination) {
        let maps = FakeMediaReader()
        let (opener, harness, workspace) = Self.opener(destination, maps: maps)
        let place = FixtureRepliesScript.placeRecords[1]

        #expect(opener.show(place) == nil)
        #expect(workspace.opened == [PlaceMapsAddress.url(for: place)])
        #expect(maps.placesOpened.isEmpty)
        #expect(harness.model.tabs.isEmpty)
    }
}

/// The one place the whole chat shows on a reply's map (M72 §14.1), as the
/// person asks and Maps answers: a place Apple Maps found is shown in place
/// of any other, in its reply or another; asked for again it goes; a place
/// another source found goes to Maps at its address; and where Maps finds no
/// place by its identifier, the pane says so and the map stays its picture.
@Suite("The place a reply's map shows")
@MainActor
struct ChatPlaceSelectionTests {
    private static let tequila = FixtureRepliesScript.applePlaceRecords[0]
    private static let betos = FixtureRepliesScript.applePlaceRecords[1]
    private static let brave = FixtureRepliesScript.placeRecords[1]

    private static func selection() -> (ChatPlaceSelection, BrowserHarness, RecordingWorkspaceOpener, FakeMediaReader) {
        let harness = BrowserHarness()
        let workspace = RecordingWorkspaceOpener()
        let maps = FakeMediaReader()
        let opener = ContentLinkOpener(preference: InMemoryLinkPreferenceStore(), browser: harness.coordinator, workspace: workspace, maps: maps)

        return (ChatPlaceSelection(links: opener), harness, workspace, maps)
    }

    @Test("a place Apple Maps found is shown on its reply's map by its identifier, and nothing opens")
    func showsAnApplePlace() {
        let (selection, harness, workspace, maps) = Self.selection()

        selection.click(Self.tequila, numbered: 1, in: 10)

        #expect(selection.shown == ChatPlaceShown(reply: 10, number: 1, identifier: "I15D3EC7F56AE8D5C"))
        #expect(workspace.opened.isEmpty)
        #expect(maps.placesOpened.isEmpty)
        #expect(!harness.model.isOpen)
    }

    /// One callout in the whole chat: another place, in the same reply or
    /// another, takes the place shown's place.
    @Test("another place, in the same reply or another, is shown in place of the first")
    func oneAtATime() {
        let (selection, _, _, _) = Self.selection()

        selection.click(Self.tequila, numbered: 1, in: 10)
        selection.click(Self.betos, numbered: 2, in: 10)
        #expect(selection.shown == ChatPlaceShown(reply: 10, number: 2, identifier: "I47957D91CD7E2F7B"))

        selection.click(Self.tequila, numbered: 1, in: 24)
        #expect(selection.shown == ChatPlaceShown(reply: 24, number: 1, identifier: "I15D3EC7F56AE8D5C"))
    }

    @Test("the place shown, clicked again, is put away")
    func sameClickPutsItAway() {
        let (selection, _, _, _) = Self.selection()

        selection.click(Self.tequila, numbered: 1, in: 10)
        selection.click(Self.tequila, numbered: 1, in: 10)

        #expect(selection.shown == nil)
    }

    @Test("a place another source found goes to Maps at its address, and the map stays as it is")
    func bravePlaceGoesToMaps() {
        let (selection, _, workspace, _) = Self.selection()
        selection.click(Self.tequila, numbered: 1, in: 10)

        selection.click(Self.brave, numbered: 2, in: 2)

        #expect(workspace.opened == [PlaceMapsAddress.url(for: Self.brave)])
        #expect(selection.shown == ChatPlaceShown(reply: 10, number: 1, identifier: "I15D3EC7F56AE8D5C"))
    }

    /// Escape, or a click on the empty map, puts away the place its reply
    /// shows, and never another reply's.
    @Test("Escape or a click on the empty map puts away its own reply's place, and no other")
    func dismissInItsReply() {
        let (selection, _, _, _) = Self.selection()
        selection.click(Self.tequila, numbered: 1, in: 10)

        selection.dismiss(in: 24)
        #expect(selection.shown != nil)

        selection.dismiss(in: 10)
        #expect(selection.shown == nil)
    }

    /// Nothing is looked up by the place's name, and nothing opens instead.
    @Test("a place Maps cannot show is said in the pane and put away, and nothing else is looked up")
    func failureIsSaid() {
        let (selection, harness, workspace, maps) = Self.selection()
        selection.click(Self.betos, numbered: 2, in: 10)
        let asked = selection.shown

        selection.failed(ChatPlaceShown(reply: 10, number: 2, identifier: "I47957D91CD7E2F7B"))

        #expect(asked != nil)
        #expect(selection.shown == nil)
        #expect(harness.model.notice == ProductStrings[.browserNoticePlaceNotShown])
        #expect(workspace.opened.isEmpty, "the place was looked up again another way")
        #expect(maps.placesOpened.isEmpty)
    }

    /// A place the person has moved on from that Maps then fails to show
    /// says nothing, and leaves the place shown since alone.
    @Test("a failure for a place no longer asked for says nothing and keeps the place shown")
    func staleFailureSaysNothing() {
        let (selection, harness, _, _) = Self.selection()
        selection.click(Self.tequila, numbered: 1, in: 10)
        selection.click(Self.betos, numbered: 2, in: 10)

        selection.failed(ChatPlaceShown(reply: 10, number: 1, identifier: "I15D3EC7F56AE8D5C"))

        #expect(selection.shown == ChatPlaceShown(reply: 10, number: 2, identifier: "I47957D91CD7E2F7B"))
        #expect(harness.model.notice == nil)
    }
}
