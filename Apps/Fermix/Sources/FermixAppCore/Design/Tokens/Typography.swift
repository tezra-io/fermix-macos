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

    public init(
        size: Double,
        leading: Double?,
        weight: FermixFontWeight,
        monospaced: Bool = false,
        tracking: Double = 0
    ) {
        precondition(size > 0, "type size must be positive")
        precondition(leading.map { $0 >= size } ?? true, "leading must not be tighter than the size")

        self.size = size
        self.leading = leading
        self.weight = weight
        self.monospaced = monospaced
        self.tracking = tracking
    }

    /// What SwiftUI's `.lineSpacing` adds: the artboard leading minus the size.
    public var lineSpacing: Double {
        max(0, (leading ?? size) - size)
    }

    public var font: Font {
        monospaced
            ? .system(size: size, weight: weight.fontWeight, design: .monospaced)
            : .system(size: size, weight: weight.fontWeight)
    }

    public func weight(_ weight: FermixFontWeight) -> TypeStyle {
        TypeStyle(size: size, leading: leading, weight: weight, monospaced: monospaced, tracking: tracking)
    }

    /// The uppercase-section-label variant: one rule, +4% of the point size,
    /// rather than a hand-written tracking constant per label.
    public func uppercased() -> TypeStyle {
        TypeStyle(
            size: size,
            leading: leading,
            weight: weight,
            monospaced: monospaced,
            tracking: size * Typography.uppercaseTrackingRatio
        )
    }
}

public enum Typography {
    /// §2: uppercase section labels take +4% tracking.
    public static let uppercaseTrackingRatio: Double = 0.04

    public static func style(_ role: TypeRole) -> TypeStyle {
        switch role {
        case .display: return TypeStyle(size: 28, leading: 34, weight: .semibold)
        case .titleLarge: return TypeStyle(size: 24, leading: 30, weight: .semibold)
        case .title: return TypeStyle(size: 22, leading: 28, weight: .semibold)
        case .statusHeadline: return TypeStyle(size: 19, leading: nil, weight: .semibold)
        case .headline: return TypeStyle(size: 17, leading: 22, weight: .semibold)
        case .body: return TypeStyle(size: 15, leading: 20, weight: .regular)
        case .bodyCompact: return TypeStyle(size: 14, leading: 20, weight: .regular)
        case .callout: return TypeStyle(size: 13, leading: 18, weight: .medium)
        case .calloutSmall: return TypeStyle(size: 12, leading: 17, weight: .regular)
        case .caption: return TypeStyle(size: 11, leading: 14, weight: .medium)
        case .mono: return TypeStyle(size: 13, leading: nil, weight: .regular, monospaced: true)
        case .monoLog: return TypeStyle(size: 11.5, leading: 16, weight: .regular, monospaced: true)
        }
    }

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

extension View {
    /// Applies a ramp rung: font, tracking, and the artboard's leading. Nothing
    /// here pins a frame height, so the text still grows with Dynamic Type.
    func fermixType(_ style: TypeStyle) -> some View {
        self
            .font(style.font)
            .tracking(style.tracking)
            .lineSpacing(style.lineSpacing)
    }

    func fermixType(_ role: TypeRole) -> some View {
        fermixType(Typography.style(role))
    }
}
