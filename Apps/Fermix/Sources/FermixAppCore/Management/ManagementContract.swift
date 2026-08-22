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

/// The management wire contract, read from the vendored schema.
public struct ManagementContract: Equatable, Sendable {
    /// The version this application declares on every request. The app speaks
    /// v1 only and never retries through the historical unversioned protocol.
    public let protocolVersion: Int
    /// The window the schema publishes. The window that governs a live session
    /// is the one `hello` returns.
    public let publishedRange: ManagementVersionWindow
    public let limits: ManagementLimits
    public let methods: [String]

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
            methods: try methodCatalog(document)
        )
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
