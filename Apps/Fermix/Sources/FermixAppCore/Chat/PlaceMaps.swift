import CoreGraphics
import Foundation

/// The Mac's own maps, for a reply's places: a map of them (M72 §7.2), a
/// picture of an area and nothing else, and a place Apple Maps found opened
/// at Apple's own card for it (§14.1). Where each place falls on the map is
/// the area's own projection (`PlaceMapArea.point(of:in:)`), so the pins
/// never wait for the picture. Behind a protocol because MapKit is GUI-only:
/// `FermixAgent` links this library and never draws a map, so the maps are
/// `FermixViewers`'s, and the executable hands them in as the chat's media
/// reader (`ChatMediaReading`).
public protocol PlaceMaps: Sendable {
    /// Exactly `area`, drawn at `size` points in the light or the dark map,
    /// with none of the map's own points of interest, so the pins read. It
    /// stops when the task asking for it is cancelled.
    func map(of area: PlaceMapArea, size: CGSize, appearance: PlaceMapAppearance) async throws -> CGImage
    /// The place Apple Maps knows by `identifier` (`CompanionPlace.applePlaceID`),
    /// opened in Maps at its own card. `failed` hears where Maps finds no
    /// place by it or does not open it; nothing else about the place is
    /// ever looked up instead.
    @MainActor func openPlace(_ identifier: String, failed: @escaping @MainActor () -> Void)
}

/// Which map a picture is drawn in: the one the app's own appearance reads.
public enum PlaceMapAppearance: Hashable, Sendable {
    case light
    case dark
}

/// A map picture as the previews keep it, cut to its map's pixels.
struct PlaceMapPicture: Equatable, Sendable {
    let image: CGImage

    /// What it holds decoded, which the previews' cache counts.
    var bytes: Int { image.bytesPerRow * image.height }

    static func == (lhs: PlaceMapPicture, rhs: PlaceMapPicture) -> Bool {
        lhs.image === rhs.image
    }
}

/// A stretch of the world in Web Mercator, the projection Apple's maps draw,
/// over the unit square: `x` runs east from the antimeridian and `y` south
/// from the map's northern edge. A picture of an area is a plain scale of
/// these numbers, so a map whose sides keep the area's proportion shows
/// exactly the area.
public struct PlaceMapArea: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    /// The Earth's circumference at the equator, in metres: the unit square's
    /// width on the ground there.
    static let equatorMeters = 40_075_016.686
    /// The least a map shows across its shorter side, so one place, or places
    /// on one street, still has the streets around it.
    static let minimumMeters = 600.0

    /// The area a map of `size` points shows of `places`: centred on them,
    /// each at least `padding` points in from every edge, never less than
    /// `minimumMeters` across the shorter side, and in the proportion of
    /// `size`. Places a city search returns lie on one side of the
    /// antimeridian, which is the side they are fitted on.
    static func fitting(_ places: [CompanionPlaceLocation], in size: CGSize, padding: Double) -> PlaceMapArea {
        let xs = places.map { mercator($0).x }
        let ys = places.map { mercator($0).y }
        guard let west = xs.min(), let east = xs.max(), let north = ys.min(), let south = ys.max() else {
            preconditionFailure("a map is fitted to one place or more")
        }
        let centre = CGPoint(x: (west + east) / 2, y: (north + south) / 2)

        // How much of the square one point of the picture covers: enough for
        // the places and their padding across, enough down, and enough for
        // the shortest side to span the minimum at the places' latitude.
        let across = (east - west) / max(size.width - 2 * padding, 1)
        let down = (south - north) / max(size.height - 2 * padding, 1)
        let least = minimumMeters / metersPerUnit(atY: centre.y) / max(min(size.width, size.height), 1)
        let scale = max(across, down, least)

        let width = size.width * scale
        let height = size.height * scale
        return PlaceMapArea(x: centre.x - width / 2, y: centre.y - height / 2, width: width, height: height)
    }

    /// Where a place falls in a picture of this area at `size` points, from
    /// its top left corner: its spot on the unit square, scaled into the
    /// picture. The one answer to where a pin goes, the map picture or none.
    public func point(of place: CompanionPlaceLocation, in size: CGSize) -> CGPoint {
        let spot = Self.mercator(place)
        return CGPoint(x: (spot.x - x) / width * size.width, y: (spot.y - y) / height * size.height)
    }

    /// A place's spot on the unit square.
    static func mercator(_ place: CompanionPlaceLocation) -> CGPoint {
        let latitude = place.latitude * .pi / 180
        return CGPoint(
            x: (place.longitude + 180) / 360,
            y: 0.5 - log(tan(.pi / 4 + latitude / 2)) / (2 * .pi)
        )
    }

    /// The ground one unit of the square spans at a height on it: the
    /// equator's length, shortened by the cosine of the latitude there.
    private static func metersPerUnit(atY y: Double) -> Double {
        let latitude = 2 * atan(exp((0.5 - y) * 2 * .pi)) - .pi / 2
        return equatorMeters * cos(latitude)
    }
}

/// Where Apple Maps opens a place another source found (M72 decision 3): an
/// address the app builds from the place's own record, its name at its
/// coordinates, and never a link the reply wrote. Maps looks the name up at
/// that point and shows its own card, with photos, reviews, hours and
/// directions. A place Apple Maps found opens by its identifier instead
/// (`PlaceMaps.openPlace`).
enum PlaceMapsAddress {
    /// The characters a query value keeps as they are: RFC 3986's
    /// unreserved ones, so a name's `&`, `=`, `+` or `#` cannot reach Maps
    /// as anything but the name.
    private static let kept = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")

    static func url(for place: CompanionPlace) -> URL {
        var address = URLComponents()
        address.scheme = "maps"
        address.host = ""
        address.percentEncodedQueryItems = [
            URLQueryItem(name: "q", value: encoded(place.name)),
            URLQueryItem(name: "ll", value: "\(place.location.latitude),\(place.location.longitude)")
        ]
        guard let url = address.url else { preconditionFailure("a Maps address built from encoded parts parses") }

        return url
    }

    private static func encoded(_ value: String) -> String {
        guard let encoded = value.addingPercentEncoding(withAllowedCharacters: kept) else {
            preconditionFailure("a Swift string is valid Unicode and always encodes")
        }

        return encoded
    }
}
