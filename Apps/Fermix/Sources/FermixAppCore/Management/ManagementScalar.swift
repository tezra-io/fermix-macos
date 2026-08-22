import Foundation

/// One public scalar from a bounded wire object (`error.details`, a Doctor
/// check's `evidence`). The contract admits scalars only, so anything else is a
/// contract violation and is reported rather than skipped.
public enum ManagementScalar: Codable, Equatable, Sendable {
    case string(String)
    case integer(Int)
    case double(Double)
    case boolean(Bool)
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
            return
        }
        // Probe in JSON's own order of specificity. These are type tests, not
        // swallowed failures: a value matching none of them throws below.
        if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
        } else if let value = try? container.decode(Int.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "management details admit scalars only"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case .string(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .boolean(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

/// A key that is only known at decode time.
struct ManagementDynamicKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }

    init(_ value: String) { stringValue = value }
    init?(stringValue: String) { self.init(stringValue) }
    init?(intValue: Int) { nil }
}

/// A bounded object of public scalars, keyed exactly as the daemon sent it.
///
/// `ManagementErrorDetails` is the same type: the named accessors below are the
/// detail keys the protocol publishes, and reading one that is absent answers
/// nil rather than inventing a value.
public struct ManagementScalarMap: Codable, Equatable, Sendable {
    public let values: [String: ManagementScalar]

    public init(values: [String: ManagementScalar]) {
        self.values = values
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ManagementDynamicKey.self)
        var decoded: [String: ManagementScalar] = [:]
        for key in container.allKeys {
            decoded[key.stringValue] = try container.decode(ManagementScalar.self, forKey: key)
        }
        values = decoded
    }

    /// Written back under the daemon's own keys, so an exported diagnostic is
    /// the object the contract describes rather than a rewriting of it.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: ManagementDynamicKey.self)
        for (key, value) in values {
            try container.encode(value, forKey: ManagementDynamicKey(key))
        }
    }

    public func string(_ key: String) -> String? {
        guard case .string(let value)? = values[key] else { return nil }
        return value
    }

    public func integer(_ key: String) -> Int? {
        guard case .integer(let value)? = values[key] else { return nil }
        return value
    }
}

public typealias ManagementErrorDetails = ManagementScalarMap

extension ManagementScalarMap {
    /// The offending envelope field, on `invalid_request` and `invalid_params`.
    public var field: String? { string("field") }
    /// The method that was not found, on `method_not_found`.
    public var method: String? { string("method") }
    /// The capability that could not answer, on `unavailable`.
    public var capability: String? { string("capability") }
    /// The operation already running, on `busy`.
    public var operation: String? { string("operation") }
    public var leaseId: String? { string("lease_id") }
    public var sessionId: String? { string("session_id") }
    /// The daemon's floor, on `client_too_old` and `daemon_too_old`.
    public var minimumVersion: Int? { integer("minimum_version") }
    /// The daemon's ceiling, on `client_too_old` and `daemon_too_old`.
    public var maximumVersion: Int? { integer("maximum_version") }
    /// The bound that was exceeded, on an oversized `invalid_params`.
    public var maximumBytes: Int? { integer("maximum_bytes") }
}
