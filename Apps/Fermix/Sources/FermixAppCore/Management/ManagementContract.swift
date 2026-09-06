import Foundation

/// A defect in the vendored management schema. The schema is the published
/// contract, so a missing extension is a hard failure rather than a value this
/// module is free to assume.
public enum ManagementContractDefect: Error, Equatable, Sendable {
    case documentIsNotAnObject
    case fieldMissing(String)
    case fieldHasWrongType(String)
}

/// An inclusive protocol-version window.
public struct ManagementVersionWindow: Equatable, Sendable {
    public let minimum: Int
    public let maximum: Int

    public init(minimum: Int, maximum: Int) {
        self.minimum = minimum
        self.maximum = maximum
    }

    public func contains(_ version: Int) -> Bool {
        version >= minimum && version <= maximum
    }
}

/// The published transport bounds. Every value is read from the schema's
/// `x-limits` rather than restated here, so a bound that moves upstream moves
/// here through a re-vendor and nowhere else.
public struct ManagementLimits: Equatable, Sendable {
    public let maxFrameBytes: Int
    public let maxParamsBytes: Int
    public let maxResultBytes: Int
    public let maxErrorDetailsBytes: Int
    public let maxJSONDepth: Int
    public let maxJSONCollectionItems: Int

    public init(
        maxFrameBytes: Int,
        maxParamsBytes: Int,
        maxResultBytes: Int,
        maxErrorDetailsBytes: Int,
        maxJSONDepth: Int,
        maxJSONCollectionItems: Int
    ) {
        self.maxFrameBytes = maxFrameBytes
        self.maxParamsBytes = maxParamsBytes
        self.maxResultBytes = maxResultBytes
        self.maxErrorDetailsBytes = maxErrorDetailsBytes
        self.maxJSONDepth = maxJSONDepth
        self.maxJSONCollectionItems = maxJSONCollectionItems
    }
}

/// The management wire contract, read from a shipped schema.
public struct ManagementContract: Equatable, Sendable {
    /// The version the schema itself publishes. It is the ceiling of the
    /// speakable set, not the version stamped on a request: what a live session
    /// stamps is negotiated against the window `hello` returns.
    public let protocolVersion: Int
    /// The window the schema publishes. The window that governs a live session
    /// is the one `hello` returns.
    public let publishedRange: ManagementVersionWindow
    public let limits: ManagementLimits
    public let methods: [String]
    /// The per-method `min_protocol_version` of M34 §7.1, keyed by wire method
    /// name. Empty on a schema that publishes none.
    public let minimumVersions: [String: Int]

    /// Every version this application can speak, ascending.
    ///
    /// M34 §7.1: derived from the published range rather than from a second key,
    /// so the speakable set and the daemon window stay one fact inside one
    /// checksum-pinned artifact.
    public var speakableVersions: [Int] {
        Array(publishedRange.minimum...publishedRange.maximum)
    }

    /// The protocol version a method needs.
    ///
    /// The floor answers only for a single-version schema, which publishes no
    /// per-method minimums because every method it lists is serveable at the one
    /// version it speaks. On a schema whose window spans two versions, `decode`
    /// has already refused a table missing any catalog method, so nothing
    /// reaches this default with a table present.
    public func minimumVersion(for method: ManagementMethod) -> Int {
        minimumVersions[method.rawValue] ?? publishedRange.minimum
    }

    /// The contract this application is built against: the schema vendored
    /// from the engine, and the only one that ships.
    public static func vendored() throws -> ManagementContract {
        try decode(from: try VendoredContracts.data(.management, "protocol.schema.json"))
    }

    public static func decode(from data: Data) throws -> ManagementContract {
        guard let document = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ManagementContractDefect.documentIsNotAnObject
        }

        // Read in the order the schema declares, so an incomplete document is
        // refused by the first field it is actually missing.
        let protocolVersion = try integer(document, "x-protocol-version")
        let range = try object(document, "x-supported-version-range")
        let limits = try object(document, "x-limits")
        let catalog = try methodCatalog(document)

        return ManagementContract(
            protocolVersion: protocolVersion,
            publishedRange: ManagementVersionWindow(
                minimum: try integer(range, "min"),
                maximum: try integer(range, "max")
            ),
            limits: ManagementLimits(
                maxFrameBytes: try integer(limits, "max_frame_bytes"),
                maxParamsBytes: try integer(limits, "max_params_bytes"),
                maxResultBytes: try integer(limits, "max_result_bytes"),
                maxErrorDetailsBytes: try integer(limits, "max_error_details_bytes"),
                maxJSONDepth: try integer(limits, "max_json_depth"),
                maxJSONCollectionItems: try integer(limits, "max_json_collection_items")
            ),
            methods: catalog,
            minimumVersions: try methodMinimums(document, range: range, catalog: catalog)
        )
    }

    /// A schema whose window tops out at 1 speaks one version and has no
    /// per-method minimum to publish. Above that the table is what makes an N-1
    /// daemon usable, so its absence is a defect and not a value to default:
    /// every v2 method would otherwise report minimum 1, the local §7.1 gate
    /// would let it through, and the designed `methodRequiresNewerEngine` state
    /// would be replaced by a wire `method_not_found`.
    ///
    /// A *partial* table is the same defect wearing a present key, so on a
    /// multi-version schema every method in the catalog has to appear in it.
    /// Without that, `minimumVersion(for:)`'s floor default answers 1 for a v2
    /// method the table simply forgot, which is the one answer that cannot be
    /// distinguished from a method that really is serveable at 1.
    private static func methodMinimums(
        _ document: [String: Any],
        range: [String: Any],
        catalog: [String]
    ) throws -> [String: Int] {
        guard let published = document["x-method-minimum-versions"] else {
            guard try integer(range, "max") == 1 else {
                throw ManagementContractDefect.fieldMissing("x-method-minimum-versions")
            }
            return [:]
        }
        guard let minimums = published as? [String: Int] else {
            throw ManagementContractDefect.fieldHasWrongType("x-method-minimum-versions")
        }
        let maximum = try integer(range, "max")
        let minimum = try integer(range, "min")
        guard maximum > minimum else { return minimums }

        for method in catalog where minimums[method] == nil {
            throw ManagementContractDefect.fieldMissing("x-method-minimum-versions.\(method)")
        }
        return minimums
    }

    private static func methodCatalog(_ document: [String: Any]) throws -> [String] {
        let request = try object(try object(try object(document, "$defs"), "request"), "properties")
        guard let catalog = try object(request, "method")["enum"] as? [String] else {
            throw ManagementContractDefect.fieldHasWrongType("$defs.request.properties.method.enum")
        }
        return catalog
    }

    private static func object(_ container: [String: Any], _ key: String) throws -> [String: Any] {
        guard let value = container[key] else {
            throw ManagementContractDefect.fieldMissing(key)
        }
        guard let object = value as? [String: Any] else {
            throw ManagementContractDefect.fieldHasWrongType(key)
        }
        return object
    }

    private static func integer(_ container: [String: Any], _ key: String) throws -> Int {
        guard let value = container[key] else {
            throw ManagementContractDefect.fieldMissing(key)
        }
        guard let number = value as? Int else {
            throw ManagementContractDefect.fieldHasWrongType(key)
        }
        return number
    }
}
