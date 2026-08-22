import AppKit
import SwiftUI

/// A provider or channel mark, drawn only two ways.
///
/// M34 §7 and redline §8.4: marks come from official brand kits with recorded
/// provenance, or, when a vendor's kit cannot be redistributed accurately, from
/// the vendor's text name beside a neutral system symbol. The artboards' "G",
/// "C", and "X" letter discs are exactly what is forbidden here — a fabricated
/// monogram is a mark the vendor never made.
///
/// Which treatment each vendor gets is not decided here: it is recorded in
/// `Resources/VendorMarks/PROVENANCE.json`, and these cases carry the same keys.
public enum VendorMark: String, CaseIterable, Sendable {
    case chatGPT = "openai_codex"
    case claude = "anthropic"
    case telegram
    case slack
    case discord

    /// How this mark is allowed to be drawn.
    public enum Treatment: Equatable, Sendable {
        /// An official vendor file, by its directory and name in the bundle.
        case vendorFile(directory: String, name: String)
        /// The vendor's text name beside a neutral system symbol.
        case textWithSymbol
    }

    public var treatment: Treatment {
        switch self {
        case .telegram:
            return .vendorFile(directory: "channels", name: "telegram-color")
        case .discord:
            return .vendorFile(directory: "channels", name: "discord-blurple")
        case .chatGPT, .claude, .slack:
            // No redistributable kit was reachable for these three; the record
            // says why for each. Vendor text plus a neutral symbol is the
            // treatment §7 prescribes, and it is not a placeholder.
            return .textWithSymbol
        }
    }

    /// The neutral symbol beside a vendor's text name. It is deliberately
    /// generic: a symbol that resembled the vendor's own mark would be the
    /// fabrication this rule exists to prevent.
    public var neutralSymbol: String {
        switch self {
        case .chatGPT, .claude: return "sparkles"
        case .telegram, .slack, .discord: return "bubble.left.and.bubble.right"
        }
    }

    /// The label VoiceOver reads, as recorded in the provenance file.
    public var accessibilityLabel: String {
        switch self {
        case .chatGPT: return ProductStrings[.connectAIChatGPTName]
        case .claude: return ProductStrings[.connectAIClaudeName]
        case .telegram: return ProductStrings[.connectChannelTelegramName]
        case .slack: return ProductStrings[.connectChannelSlackName]
        case .discord: return ProductStrings[.connectChannelDiscordName]
        }
    }
}

/// Draws a vendor mark at a given size, in whichever of the two treatments the
/// provenance record allows.
public struct VendorMarkImage: View {
    private let mark: VendorMark
    private let size: Double

    public init(mark: VendorMark, size: Double) {
        self.mark = mark
        self.size = size
    }

    public var body: some View {
        Group {
            if case .vendorFile(let directory, let name) = mark.treatment,
               let image = VendorMarkLoader.image(directory: directory, name: name) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                neutralSymbol
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    /// The text-plus-symbol treatment, and also what a bundle missing an
    /// official file draws while the asset gate reports the packaging defect.
    private var neutralSymbol: some View {
        Image(systemName: mark.neutralSymbol)
            .font(.system(size: size * 0.62))
            .foregroundStyle(Palette.secondary.color)
    }
}

/// The neutral disc behind a mark.
public struct VendorMarkDisc: View {
    private let mark: VendorMark
    private let diameter: Double

    public init(mark: VendorMark, diameter: Double) {
        self.mark = mark
        self.diameter = diameter
    }

    public var body: some View {
        ZStack {
            Circle().fill(Palette.monoDisc.color)
            VendorMarkImage(mark: mark, size: diameter * 0.56)
        }
        .frame(width: diameter, height: diameter)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(mark.accessibilityLabel)
    }
}

/// Loads an official vendor mark out of the resource bundle.
///
/// The marks ship as SVG masters, which `NSImage` reads directly on every
/// supported system, so there is no raster tier to keep in step and no
/// resolution for a mark to be wrong at.
enum VendorMarkLoader {
    static func image(directory: String, name: String) -> NSImage? {
        guard let url = Bundle.module.url(
            forResource: name,
            withExtension: "svg",
            subdirectory: "VendorMarks/\(directory)"
        ) else { return nil }

        return NSImage(contentsOf: url)
    }
}
