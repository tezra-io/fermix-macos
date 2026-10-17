import Foundation

/// A record a reply carries beside its text (M72 §8.3): what a tool returned
/// in the reply's turn that the text links, which the Mac draws under it. The
/// text stands alone without it (§6.1), so every channel, the transcript
/// search and an older app lose nothing a block holds.
public enum CompanionBlock: Equatable, Sendable {
    /// The places `place_search` found that the reply links, one to ten, in
    /// the order the text first links them.
    case places([CompanionPlace])
}

/// A row's `blocks` as the wire carries them, at most one of each type, read
/// by the contract's rule for a type this build does not know: it is skipped,
/// and the text is all that is drawn for it. A block of a known type that is
/// misshapen is refused with its whole line, as a misshapen link preview is,
/// and the refusal names the field.
public struct CompanionBlocks: Equatable, Sendable, Decodable {
    /// The blocks of the types this build draws, in the wire's order.
    public let known: [CompanionBlock]

    public init(_ known: [CompanionBlock]) {
        self.known = known
    }

    public init(from decoder: Decoder) throws {
        known = try [Entry](from: decoder).compactMap(\.block)
    }

    /// One entry of the array: a block, or nil for a type published after
    /// this build shipped.
    private struct Entry: Decodable {
        let block: CompanionBlock?

        private enum CodingKeys: String, CodingKey {
            case type, places
        }

        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            switch try fields.decode(String.self, forKey: .type) {
            case "places": block = .places(try fields.decode([CompanionPlace].self, forKey: .places))
            default: block = nil
            }
        }
    }
}

/// A place as the reply's block carries it: a subset of M31's normalized
/// record under M31's own names. `name` and `location` are always there;
/// every other field only where the source gave it, and at least one of the
/// two addresses.
public struct CompanionPlace: Equatable, Hashable, Sendable, Decodable {
    public let name: String
    /// The place's own website.
    public let canonicalURL: String?
    /// The provider's page for the place.
    public let sourceURL: String?
    public let location: CompanionPlaceLocation
    public let address: String?
    public let rating: CompanionPlaceRating?
    /// As the source wrote it, such as `$$`.
    public let priceRange: String?
    /// The source's own words, such as `coffee_shop`.
    public let categories: [String]?
    public let openingHours: CompanionPlaceHours?
    /// From the place search's own centre, which the block never carries.
    public let distance: CompanionPlaceDistance?

    private enum CodingKeys: String, CodingKey {
        case name, location, address, rating, categories, distance
        case canonicalURL = "canonical_url"
        case sourceURL = "source_url"
        case priceRange = "price_range"
        case openingHours = "opening_hours"
    }
}

/// Where a place is: the place's own coordinates, never the person's.
public struct CompanionPlaceLocation: Equatable, Hashable, Sendable, Decodable {
    public let latitude: Double
    public let longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

/// A place's rating, each field only where the source gave it.
public struct CompanionPlaceRating: Equatable, Hashable, Sendable, Decodable {
    public let value: Double?
    /// The best rating the source's scale has.
    public let best: Double?
    /// How many ratings the value is made of.
    public let count: Double?
}

/// A place's hours, as the block carries them: today's alone.
public struct CompanionPlaceHours: Equatable, Hashable, Sendable, Decodable {
    /// Today's hours as the source gave them, such as `Thursday 07:00-19:00`.
    /// The app never works out from it whether the place is open.
    public let currentDay: String?

    private enum CodingKeys: String, CodingKey {
        case currentDay = "current_day"
    }
}

/// How far a place is, in the source's own units.
public struct CompanionPlaceDistance: Equatable, Hashable, Sendable, Decodable {
    public let value: Double?
    public let units: String?
}
