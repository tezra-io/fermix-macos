import Foundation

/// The typed results of the `settings.*` methods, plus the two shapes every
/// write result carries. Coding keys are the wire names, so a shape reads
/// against the vendored schema line by line.

/// Why a restart is pending, in the daemon's own sentences. The app renders
/// them; it never composes its own reason for a restart.
public struct ManagementRestartReason: Decodable, Equatable, Sendable {
    public let section: String
    public let sentence: String
}

/// M34 §7.5's restart truth, as one value carried on every write result.
public struct ManagementRestartState: Decodable, Equatable, Sendable {
    public let required: Bool
    public let reasons: [ManagementRestartReason]

    public init(required: Bool, reasons: [ManagementRestartReason]) {
        self.required = required
        self.reasons = reasons
    }
}

/// Readiness as a write result carries it: the status and how many failures
/// stand. The failures themselves come from `setup.state.get`.
public struct ManagementReadinessSummary: Decodable, Equatable, Sendable {
    public let status: String?
    public let failureCount: Int

    private enum CodingKeys: String, CodingKey {
        case status
        case failureCount = "failure_count"
    }
}

/// One settings row's value.
///
/// The wire admits a public scalar, a list of strings, or null. Null is a value
/// with a meaning — it deletes the key where the key allows it — so it is a case
/// rather than an absent field.
public enum ManagementSettingValue: Codable, Equatable, Sendable {
    case text(String)
    case number(Double)
    case flag(Bool)
    case list([String])
    /// JSON null: no value, and on a write a request to forget the key.
    case absent

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .absent
            return
        }
        // Probed in JSON's order of specificity. These are type tests, not
        // swallowed failures: a value matching none of them throws below.
        if let value = try? container.decode(Bool.self) {
            self = .flag(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .text(value)
        } else if let value = try? container.decode([String].self) {
            self = .list(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "a settings value is a scalar, a list of strings, or null"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case .text(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .flag(let value): try container.encode(value)
        case .list(let value): try container.encode(value)
        case .absent: try container.encodeNil()
        }
    }
}

/// One option of a `choice` row. `hint` and `disabled` are the daemon's, so the
/// app never decides which option is selectable.
public struct ManagementSettingOption: Decodable, Equatable, Sendable {
    public let value: String
    public let label: String
    public let hint: String?
    public let disabled: Bool
}

/// One descriptor row. Everything a control needs comes from here; nothing in
/// Swift keeps a field inventory beside it.
public struct ManagementSettingRow: Decodable, Equatable, Sendable {
    public let key: String
    public let kind: ManagementSettingKind
    public let label: String
    public let footer: String?
    public let value: ManagementSettingValue
    /// Whether a secret sits at the key's path. Nil on every other kind.
    public let present: Bool?
    public let options: [ManagementSettingOption]
    public let min: Double?
    public let max: Double?
    public let step: Double?
    /// Whether changing this row requires a daemon restart.
    public let restart: Bool
    /// Whether a choice row's `options` are only what a client may offer inline
    /// rather than its whole value space. True on the time zone row, the
    /// communication style row and the four model rows, where `settings.apply`
    /// takes whatever the key's own validator takes; false everywhere else, and
    /// a value outside the options is then refused. False on every non-choice
    /// kind.
    public let suggestions: Bool
    /// A row the section publishes but `settings.apply` will not take, rendered
    /// as a plain labelled row rather than a control whose save always refuses.
    ///
    /// M34 §7.7's parity gate names this mark — every row key round-trips
    /// through `settings.apply` or is marked `read_only` and rendered as a
    /// `LabeledContent`. §7.3's row column does not list it; the gate paragraph
    /// is what obliges the engine to publish it, on every row.
    public let readOnly: Bool
    /// What a number counts, rendered as a suffix beside the field. Nil where
    /// the number counts nothing but itself, and on every non-number row.
    public let unit: String?
    /// How a number reads (M34 §5): a plain count, a 0-1 fraction as a
    /// percentage, whole cents as money, or a duration. Nil on every other kind.
    public let format: ManagementNumberFormat?

    private enum CodingKeys: String, CodingKey {
        case key, kind, label, footer, value, present, options, min, max, step, restart
        case suggestions, unit, format
        case readOnly = "read_only"
    }
}

/// How a number row reads (M34 §5).
///
/// Without it every number was a bare figure with steppers: `Stop a
/// conversation at 200` over the footer `In cents.`, and a 0-1 compaction
/// fraction rendered as `0.83`.
public enum ManagementNumberFormat: ManagementVocabulary {
    case integer
    case percent
    case currencyCents
    case minutes
    case hours
    case unrecognized(String)

    public static let publishedValues: [String: Self] = [
        "integer": .integer,
        "percent": .percent,
        "currency_cents": .currencyCents,
        "minutes": .minutes,
        "hours": .hours
    ]
    public static func unrecognizedCase(_ value: String) -> Self { .unrecognized(value) }
    public var unrecognizedValue: String? {
        if case .unrecognized(let value) = self { return value }
        return nil
    }
}

/// One entry of the published section inventory. `pane` is the M34 §3.4 slug the
/// section renders under, so the sidebar and the section list agree by
/// construction rather than by a hand-written map.
public struct ManagementSettingsSection: Decodable, Equatable, Sendable {
    public let id: String
    public let pane: ManagementSettingsPane
    public let title: String
}

public struct ManagementSettingsInventory: Decodable, Equatable, Sendable {
    public let sections: [ManagementSettingsSection]
}

/// One section's rows. `settings.get` serves exactly one section per call, which
/// is what keeps every result inside the published depth budget.
public struct ManagementSettingsSectionRows: Decodable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let rows: [ManagementSettingRow]
}

/// What an apply did. `sideEffects` are the daemon's sentences for changes the
/// operator did not type, so the app can show them without inferring any.
public struct ManagementSettingsApplied: Decodable, Equatable, Sendable {
    public let applied: [String]
    public let restart: ManagementRestartState
    public let readiness: ManagementReadinessSummary
    public let sideEffects: [String]

    private enum CodingKeys: String, CodingKey {
        case applied, restart, readiness
        case sideEffects = "side_effects"
    }
}

/// The one action behind `Reload settings from disk`, and the only member of the
/// write family allowed while the configuration state is `externalChange`.
public struct ManagementSettingsReloaded: Decodable, Equatable, Sendable {
    public let reloaded: Bool
    public let restart: ManagementRestartState
    public let readiness: ManagementReadinessSummary
    public let configState: ManagementConfigState

    private enum CodingKeys: String, CodingKey {
        case reloaded, restart, readiness
        case configState = "config_state"
    }
}
