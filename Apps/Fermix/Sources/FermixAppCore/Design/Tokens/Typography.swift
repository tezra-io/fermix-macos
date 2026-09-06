import SwiftUI

/// The three weights the ramp uses, named by the numeric weight the redline
/// tables publish so a declaration can be diffed against the table.
public enum FermixFontWeight: String, CaseIterable, Sendable {
    case regular
    case medium
    case semibold

    public var numeric: Int {
        switch self {
        case .regular: return 400
        case .medium: return 500
        case .semibold: return 600
        }
    }

    public var fontWeight: Font.Weight {
        switch self {
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        }
    }
}

/// A rung of the type ramp (`M34_DESIGN_SYSTEM_REDLINES.md` §2).
public enum TypeRole: String, CaseIterable, Sendable {
    /// Onboarding headlines.
    case display
    /// "Fermix is live" only.
    case titleLarge
    /// Step titles.
    case title
    /// Home's "Running".
    case statusHeadline
    /// Card headers.
    case headline
    /// Descriptions, setup copy, CTA labels.
    case body
    /// Step subcopy and row titles.
    case bodyCompact
    /// Buttons, list rows, menu items.
    case callout
    /// Hints, chips, footers.
    case calloutSmall
    /// Section labels and timestamps.
    case caption
    /// Commands and tokens.
    case mono
    /// Log lines.
    case monoLog
}

/// One resolved type style: the size, the artboard's leading, the weight, and
/// the tracking. `font` and `lineSpacing` are what a view applies.
public struct TypeStyle: Equatable, Sendable {
    public let size: Double
    /// The artboard's `line-height`, or nil where the ramp does not pin one.
    public let leading: Double?
    public let weight: FermixFontWeight
    public let monospaced: Bool
    public let tracking: Double
    /// The system text style this rung scales with.
    ///
    /// macOS publishes the operator's `Accessibility ▸ Display ▸ Text size` step
    /// through `dynamicTypeSize`, and a fixed point size ignores it. The rung
    /// keeps the redline's own size as its base and grows from it against this
    /// style, so the table stays diffable against §2 and the text still
    /// responds.
    public let relativeTo: Font.TextStyle

    public init(
        size: Double,
        leading: Double?,
        weight: FermixFontWeight,
        monospaced: Bool = false,
        tracking: Double = 0,
        relativeTo: Font.TextStyle = .body
    ) {
        precondition(size > 0, "type size must be positive")
        precondition(leading.map { $0 >= size } ?? true, "leading must not be tighter than the size")

        self.size = size
        self.leading = leading
        self.weight = weight
        self.monospaced = monospaced
        self.tracking = tracking
        self.relativeTo = relativeTo
    }

    /// What SwiftUI's `.lineSpacing` adds: the artboard leading minus the size.
    public var lineSpacing: Double {
        max(0, (leading ?? size) - size)
    }

    public var font: Font { font(at: size) }

    /// The rung's face at whatever size the environment scaled it to.
    public func font(at scaled: Double) -> Font {
        monospaced
            ? .system(size: scaled, weight: weight.fontWeight, design: .monospaced)
            : .system(size: scaled, weight: weight.fontWeight)
    }

    /// How much the environment grew this rung, as a ratio, so the leading and
    /// the tracking grow with the size rather than staying at the base value.
    public func ratio(at scaled: Double) -> Double {
        scaled / size
    }

    public func weight(_ weight: FermixFontWeight) -> TypeStyle {
        TypeStyle(
            size: size,
            leading: leading,
            weight: weight,
            monospaced: monospaced,
            tracking: tracking,
            relativeTo: relativeTo
        )
    }

    /// The uppercase-section-label variant: one rule, +4% of the point size,
    /// rather than a hand-written tracking constant per label.
    public func uppercased() -> TypeStyle {
        TypeStyle(
            size: size,
            leading: leading,
            weight: weight,
            monospaced: monospaced,
            tracking: size * Typography.uppercaseTrackingRatio,
            relativeTo: relativeTo
        )
    }
}

public enum Typography {
    /// §2: uppercase section labels take +4% tracking.
    public static let uppercaseTrackingRatio: Double = 0.04

    public static func style(_ role: TypeRole) -> TypeStyle {
        switch role {
        case .display: return TypeStyle(size: 28, leading: 34, weight: .semibold, relativeTo: .largeTitle)
        case .titleLarge: return TypeStyle(size: 24, leading: 30, weight: .semibold, relativeTo: .title)
        case .title: return TypeStyle(size: 22, leading: 28, weight: .semibold, relativeTo: .title2)
        case .statusHeadline: return TypeStyle(size: 19, leading: nil, weight: .semibold, relativeTo: .title3)
        case .headline: return TypeStyle(size: 17, leading: 22, weight: .semibold, relativeTo: .headline)
        case .body: return TypeStyle(size: 15, leading: 20, weight: .regular, relativeTo: .body)
        case .bodyCompact: return TypeStyle(size: 14, leading: 20, weight: .regular, relativeTo: .body)
        case .callout: return TypeStyle(size: 13, leading: 18, weight: .medium, relativeTo: .callout)
        case .calloutSmall: return TypeStyle(size: 12, leading: 17, weight: .regular, relativeTo: .footnote)
        case .caption: return TypeStyle(size: 11, leading: 14, weight: .medium, relativeTo: .caption)
        case .mono:
            return TypeStyle(size: 13, leading: nil, weight: .regular, monospaced: true, relativeTo: .callout)
        case .monoLog:
            return TypeStyle(size: 11.5, leading: 16, weight: .regular, monospaced: true, relativeTo: .caption)
        }
    }

    /// A sheet's title.
    ///
    /// The card-header rung rather than the step-title rung the assistant's
    /// screens use: a sheet is a panel over a window, and macOS titles one at
    /// the size of a section header, not at the size of a full-screen step. At
    /// 22pt every credential sheet in the app opened with a headline as large
    /// as the window title behind it.
    public static var sheetTitle: TypeStyle { style(.headline) }

    /// The 11pt uppercase label used for LAST LOG LINES, NETWORK CHECKS, and
    /// SUPPORT.
    public static var sectionLabel: TypeStyle {
        style(.caption).weight(.semibold).uppercased()
    }

    /// The 12pt uppercase label used for Home's RUNTIME and ATTENTION headers.
    public static var sectionLabelLarge: TypeStyle {
        style(.calloutSmall).weight(.semibold).uppercased()
    }
}

/// Applies a ramp rung at the size the environment scaled it to.
///
/// A modifier rather than a chain of view modifiers, because the scaling is a
/// `@ScaledMetric` and only a view type can hold one. It is the one place a
/// point size becomes a font, so nothing in the product draws at a size that
/// ignores `Accessibility ▸ Display ▸ Text size` (redlines §2).
struct FermixTypeModifier: ViewModifier {
    private let style: TypeStyle
    @ScaledMetric private var scaled: Double

    init(_ style: TypeStyle) {
        self.style = style
        _scaled = ScaledMetric(wrappedValue: style.size, relativeTo: style.relativeTo)
    }

    func body(content: Content) -> some View {
        let ratio = style.ratio(at: scaled)

        return content
            .font(style.font(at: scaled))
            .tracking(style.tracking * ratio)
            .lineSpacing(style.lineSpacing * ratio)
    }
}

extension View {
    /// Applies a ramp rung: font, tracking, and the artboard's leading, all
    /// scaled together. Nothing here pins a frame height, so the text grows.
    func fermixType(_ style: TypeStyle) -> some View {
        modifier(FermixTypeModifier(style))
    }

    func fermixType(_ role: TypeRole) -> some View {
        fermixType(Typography.style(role))
    }
}
