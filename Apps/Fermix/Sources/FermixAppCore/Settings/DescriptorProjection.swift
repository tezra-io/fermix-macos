import Foundation

/// The control one descriptor row renders as (M34 §7.7).
///
/// Exactly one per row. The mapping is the design's own — toggle to `Toggle`,
/// choice to `Picker`, text to `TextField`, number to a `Stepper` or a `Slider`,
/// secret to the secret row, list to the list editor — and a row the daemon
/// marks read-only is a plain labelled row rather than a control whose save
/// would always refuse.
public enum DescriptorControl: Equatable, Sendable {
    case toggle(Bool)
    /// A closed menu: `options` is the whole value space, and `settings.apply`
    /// refuses anything else.
    case choice(selected: String?, options: [ManagementSettingOption])
    /// A choice row whose `options` are only suggestions. The daemon takes
    /// whatever the key's own validator takes, so the control has to let a value
    /// outside the list be given — a closed menu here is a control that cannot
    /// express the answers the daemon accepts.
    case suggestion(value: String, options: [ManagementSettingOption])
    /// The time zone, which macOS already knows how to choose. The suggestion
    /// list is 21 zones and the daemon accepts any of the several hundred this
    /// Mac knows, so the row opens the same searchable sheet About you does.
    case timeZone(String)
    /// The prompt says the field is empty, and it is the same sentence for
    /// every text row. The daemon publishes no placeholder, so the alternative
    /// was the row's own label — which draws it twice, once as the row title
    /// and once inside the field, so `Zoom account id` reads as its own value.
    /// One shared empty-state word is not per-field copy.
    case text(value: String, prompt: String)
    case stepper(value: Double, minimum: Double?, maximum: Double?, step: Double, measure: NumberMeasure)
    case slider(value: Double, minimum: Double, maximum: Double, step: Double, measure: NumberMeasure)
    case secret(present: Bool)
    case list([String])
    /// A row the daemon publishes but will not take a write for.
    case readOnly(String)
    /// A kind this build does not know, which means the daemon is newer than
    /// the engine in the bundle. It renders M34 §7.1's named state, never a
    /// guessed control.
    ///
    /// M34 §7.7 rules out an unknown-kind degrade branch, and the gate it names
    /// is real: `DescriptorCoverageTests` fails at re-vendor time on a kind with
    /// no control, so nothing reaches this case through the vendored path. It
    /// exists because `ManagementSettingKind` is an open wire vocabulary like
    /// every other one in `ManagementVocabulary`, and a `preconditionFailure`
    /// inside a settings window is a worse answer than the state that says the
    /// engine is behind. The coverage gate is the guard; this is the rendering.
    case unsupported(String)
}

/// One descriptor row, resolved to exactly one control.
///
/// A value rather than a view, because "which control does this row get, and
/// does it honour the daemon's step" is the invariant worth proving and a view
/// body is not where it can be read.
public struct DescriptorRowModel: Identifiable, Equatable, Sendable {
    public let key: String
    public let label: String
    public let footer: String?
    public let control: DescriptorControl
    /// Whether changing this row needs a restart, which the banner then names.
    public let restart: Bool

    public var id: String { key }

    public init(row: ManagementSettingRow, value: ManagementSettingValue) {
        precondition(!row.key.isEmpty, "a descriptor row is addressed by key")

        self.key = row.key
        self.label = row.label
        self.footer = row.footer
        self.restart = row.restart
        self.control = Self.control(for: row, value: value)
    }

    /// The one resolver. Read-only wins over kind, because a read-only row of
    /// any kind is a labelled fact.
    private static func control(
        for row: ManagementSettingRow,
        value: ManagementSettingValue
    ) -> DescriptorControl {
        guard !row.readOnly else { return .readOnly(DescriptorValue.text(value)) }

        switch row.kind {
        case .toggle:
            return .toggle(DescriptorValue.flag(value))
        case .choice:
            return choice(row, value: value)
        case .text:
            return .text(value: DescriptorValue.text(value), prompt: ProductStrings[.settingsTextEmptyPrompt])
        case .number:
            return number(row, value: value)
        case .secret:
            return .secret(present: row.present ?? false)
        case .list:
            return .list(DescriptorValue.list(value))
        case .unrecognized(let name):
            return .unsupported(name)
        }
    }

    /// Which of the three choice controls a row gets.
    ///
    /// `suggestions` is the daemon's own field, so the split is read rather than
    /// keyed on a list of row names. The one key named here is the time zone,
    /// because the control that answers it is a searchable list of what macOS
    /// knows rather than anything the contract can describe; it is the same
    /// constant About you writes, so there is one spelling of it in the app.
    private static func choice(
        _ row: ManagementSettingRow,
        value: ManagementSettingValue
    ) -> DescriptorControl {
        guard row.suggestions else {
            return .choice(selected: DescriptorValue.optional(value), options: row.options)
        }

        guard row.key != AboutYouAnswers.timezoneKey else {
            return .timeZone(DescriptorValue.text(value))
        }

        return .suggestion(value: DescriptorValue.text(value), options: row.options)
    }

    /// A `Slider` where the daemon publishes both ends and the value is a
    /// fraction of them: a percentage is the one number a person reads off a
    /// track rather than typing. Everything else is a field with a stepper,
    /// which is the shape that can hold a precise value and can be typed into:
    /// a 1-to-240 minute bound behind steppers alone is up to 239 clicks
    /// (M34 §5).
    private static func number(
        _ row: ManagementSettingRow,
        value: ManagementSettingValue
    ) -> DescriptorControl {
        let current = DescriptorValue.number(value)
        let step = row.step ?? 1
        let bounds = orderedBounds(row.min, row.max)
        let measure = NumberMeasure(unit: row.unit, format: row.format)

        guard measure.readsAsFraction, let minimum = bounds.minimum, let maximum = bounds.maximum,
              maximum > minimum, step > 0
        else {
            return .stepper(
                value: current,
                minimum: bounds.minimum,
                maximum: bounds.maximum,
                step: step,
                measure: measure
            )
        }

        return .slider(value: current, minimum: minimum, maximum: maximum, step: step, measure: measure)
    }

    /// The daemon's bounds, in the order a range needs them.
    ///
    /// A pair published the wrong way round is no bound at all: it is dropped
    /// here rather than handed to a `ClosedRange`, which has no defined
    /// behaviour when the lower end is above the upper one.
    private static func orderedBounds(
        _ minimum: Double?,
        _ maximum: Double?
    ) -> (minimum: Double?, maximum: Double?) {
        guard let minimum, let maximum, minimum > maximum else { return (minimum, maximum) }

        return (nil, nil)
    }

}

/// What a number counts and how it reads (M34 §5).
///
/// The daemon owns both; this is the one place they become a rendering, so a
/// unit shown as a suffix, a fraction shown as a percentage and cents shown as
/// money cannot be spelled three ways.
public struct NumberMeasure: Equatable, Sendable {
    public let unit: String?
    public let format: ManagementNumberFormat?

    public init(unit: String?, format: ManagementNumberFormat?) {
        self.unit = unit
        self.format = format
    }

    /// A number the operator reads as a share of its own bounds.
    public var readsAsFraction: Bool { format == .percent }

    /// The value as words: a percentage, an amount of money, or the figure with
    /// its unit beside it.
    public func text(_ value: Double, step: Double) -> String {
        switch format {
        case .percent:
            return String(format: ProductStrings[.settingsNumberPercentFormat], (value * 100).rounded())
        case .currencyCents:
            return CurrencyFormat.wholeCents(value)
        case .integer, .minutes, .hours, .unrecognized, .none:
            return suffixed(NumberRowFormat.text(value, step: step))
        }
    }

    private func suffixed(_ figure: String) -> String {
        guard let unit, !unit.isEmpty else { return figure }

        return "\(figure) \(unit)"
    }
}

/// Whole cents as money, in the operator's own locale.
public enum CurrencyFormat {
    public static func wholeCents(_ cents: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.maximumFractionDigits = 2

        return formatter.string(from: NSNumber(value: cents / 100)) ?? String(Int(cents.rounded()))
    }
}

/// Reading a wire value at the type the control needs.
///
/// Every reading is total: a row whose kind and value disagree is a daemon
/// defect the contract test catches at re-vendor time, and until then the
/// control shows the empty value for its type rather than refusing to draw.
public enum DescriptorValue {
    public static func flag(_ value: ManagementSettingValue) -> Bool {
        guard case .flag(let flag) = value else { return false }

        return flag
    }

    public static func number(_ value: ManagementSettingValue) -> Double {
        guard case .number(let number) = value else { return 0 }

        return number
    }

    public static func list(_ value: ManagementSettingValue) -> [String] {
        guard case .list(let items) = value else { return [] }

        return items
    }

    /// The value as the operator reads it, for a text field or a labelled fact.
    public static func text(_ value: ManagementSettingValue) -> String {
        optional(value) ?? ""
    }

    /// The value as a selection, where absent genuinely means "nothing chosen"
    /// rather than the empty string.
    public static func optional(_ value: ManagementSettingValue) -> String? {
        switch value {
        case .text(let text): return text
        case .number(let number): return number == number.rounded() ? String(Int(number)) : String(number)
        case .flag(let flag): return flag ? "true" : "false"
        case .list(let items): return items.joined(separator: ", ")
        case .absent: return nil
        }
    }
}

extension ManagementSettingRow {
    /// An empty option can name an inherited default without storing an override.
    var emptyValuePrompt: String {
        options.first { $0.value.isEmpty }?.label ?? ProductStrings[.settingsTextEmptyPrompt]
    }
}

/// Which descriptor row keys Swift binds by name.
///
/// M34 §7.7: the app supplies no field inventory. Almost every settings row is
/// drawn from the descriptor the daemon published, and the coverage gate is
/// what keeps it that way — the moment a pane reaches for a key by name, the
/// key has to be declared here and justified against the contract instead of
/// appearing unremarked in a view body.
///
/// Coding consent and preference need the daemon's separate CLI detection to
/// decide availability. Their labels, values and choices still use descriptors.
public enum SettingsBinding {
    public static let codingConsent = "harness_approved"
    public static let codingPreference = "harness_default_vendor"

    /// The meetings switch and the section it lives in (M34 §5.4). It is bound
    /// by name because it is the one control that runs a job before its write,
    /// and the job is not the daemon's to start.
    public static let meetingsSection = "meetings"
    public static let meetingsEnabled = "meetings_enabled"

    /// Channel switches construct their key; coding controls add detection
    /// guards to the two published rows, and the meetings switch heads its own
    /// pane. Coverage checks all four bindings.
    public static let boundKeys: Set<String> = [
        "<channel>_enabled", codingConsent, codingPreference, meetingsEnabled
    ]

    /// The bound keys, resolved against the channels a snapshot publishes. The
    /// gate reads it so the family is checked against the daemon's own list
    /// rather than against a spelling written twice.
    public static func boundKeys(forChannels channels: [String]) -> Set<String> {
        Set(channels.map(ChannelRowProjection.enabledKey(for:)))
            .union([codingConsent, codingPreference, meetingsEnabled])
    }

    /// Fixture keys the app deliberately does not render yet. Empty: every kind
    /// the contract publishes has a control.
    public static let deferredKeys: Set<String> = []

    /// The kinds `DescriptorRowModel` resolves to a control. A kind outside this
    /// set renders M34 §7.1's newer-engine state rather than a guess.
    public static let renderedKinds: Set<String> = Set(ManagementSettingKind.publishedValues.keys)
}
