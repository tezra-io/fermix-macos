import AppKit
import SwiftUI

/// One provider, channel, plugin or feature mark, and the ways it may be drawn.
///
/// M34 §7 and redline §8.4: a mark ships only when it was retrieved from the
/// source recorded beside it and shipped byte for byte. When nothing could be
/// retrieved, the vendor's text name beside a neutral system symbol is the
/// treatment; a fabricated monogram is a mark the vendor never made.
///
/// **Which treatment each key gets is not decided here.** It is recorded in
/// `Resources/VendorMarks/PROVENANCE.json`, and `VendorMarkTests` reads that
/// file and proves this table says the same thing about every key, plate,
/// treatment and file. The record is the authority; this is what the app draws.
public struct VendorMark: Equatable, Sendable {
    /// Which roster a mark belongs to. Two kinds may name one vendor: Discord
    /// and Slack are each both a channel and a plugin, with different art.
    public enum Kind: String, CaseIterable, Sendable {
        case provider
        case channel
        case plugin
        case feature
        case oauthClient = "oauth_client"

        /// The neutral symbol this kind falls back to. Deliberately generic: a
        /// symbol that resembled a vendor's own mark would be the fabrication
        /// the no-monogram rule exists to prevent.
        public var neutralSymbol: String {
            switch self {
            case .provider: return "cpu"
            case .channel: return "bubble.left.and.bubble.right"
            case .plugin, .feature, .oauthClient: return "puzzlepiece.extension"
            }
        }
    }

    /// The plate a mark is drawn on, from its record. The app reads the field
    /// rather than guessing from the pixels, so the two cannot disagree about a
    /// mark that would be invisible on one of the two appearances.
    public enum Plate: String, CaseIterable, Sendable {
        /// A coloured glyph on transparency, inset on the app's own tile.
        case neutral
        /// The file is an opaque square or disc carrying its own ground, so it
        /// fills the tile and is clipped to its radius.
        case bleed
    }

    /// One shipped file, by the directory and name it has in the bundle.
    public struct Asset: Equatable, Sendable {
        public let directory: String
        public let name: String
        public let fileExtension: String

        public init(_ directory: String, _ name: String, _ fileExtension: String) {
            precondition(!directory.isEmpty && !name.isEmpty, "an asset is named by directory and file")

            self.directory = directory
            self.name = name
            self.fileExtension = fileExtension
        }

        /// The path the provenance record claims, so the record and this table
        /// are comparable without either restating the other.
        public var recordedPath: String { "\(directory)/\(name).\(fileExtension)" }
    }

    /// How this mark is allowed to be drawn.
    public enum Treatment: Equatable, Sendable {
        /// One official file, drawn as it is.
        case file(Asset)
        /// Two published inks, resolved by appearance: the vendor's own choice
        /// per background rather than one file tinted.
        case pair(light: Asset, dark: Asset)
        /// A single-ink file with no published variant, drawn as a template
        /// tinted with the system label colour.
        case template(Asset)
        /// The vendor's text name beside a neutral system symbol.
        case textWithSymbol
    }

    public let key: String
    public let kind: Kind
    public let treatment: Treatment
    public let plate: Plate

    init(_ kind: Kind, _ key: String, _ treatment: Treatment, plate: Plate = .neutral) {
        precondition(!key.isEmpty, "a mark is keyed by its vendor")

        self.key = key
        self.kind = kind
        self.treatment = treatment
        self.plate = plate
    }

    /// The file to draw in this appearance, or nothing where the record ships
    /// no file at all.
    func asset(dark: Bool) -> Asset? {
        switch treatment {
        case .file(let asset), .template(let asset): return asset
        case .pair(let light, let dark_): return dark ? dark_ : light
        case .textWithSymbol: return nil
        }
    }

    var isTemplate: Bool {
        if case .template = treatment { return true }

        return false
    }
}

/// The mark table, mirroring `Resources/VendorMarks/PROVENANCE.json`.
public enum VendorMarks {
    public static let all: [VendorMark] = [
        // Providers use their official service icons.
        VendorMark(.provider, "anthropic", .file(.init("providers", "anthropic-color", "png")), plate: .bleed),
        VendorMark(.provider, "mistral", .file(.init("providers", "mistral-color", "svg"))),
        VendorMark(.provider, "ollama", .template(.init("providers", "ollama-mono", "svg"))),
        VendorMark(.provider, "openai", .file(.init("providers", "openai-color", "svg")), plate: .bleed),
        VendorMark(.provider, "openai_codex", .file(.init("providers", "openai-color", "svg")), plate: .bleed),
        VendorMark(
            .provider,
            "openrouter",
            .pair(
                light: .init("providers", "openrouter-grape", "svg"),
                dark: .init("providers", "openrouter-volt", "svg")
            )
        ),
        VendorMark(.provider, "xai", .template(.init("providers", "xai-mono", "png"))),

        // Channels.
        VendorMark(.channel, "discord", .file(.init("channels", "discord-blurple", "svg"))),
        VendorMark(.channel, "signal", .file(.init("channels", "signal-ultramarine", "svg"))),
        VendorMark(.channel, "slack", .file(.init("channels", "slack-color", "png")), plate: .bleed),
        VendorMark(.channel, "telegram", .file(.init("channels", "telegram-color", "svg")), plate: .bleed),
        VendorMark(.channel, "whatsapp", .file(.init("channels", "whatsapp-color", "webp")), plate: .bleed),

        // Plugins. Two upstream sets, not one: the static catalog a machine
        // installs from, and the three the engine ships inside itself, which
        // `Registry.list` unions into every answer and which are therefore
        // installed on a machine that added nothing. The sidecar is the one
        // entry the catalog publishes no logo for, so it takes Fermix's own.
        VendorMark(.plugin, "agentmail", .file(.init("plugins", "agentmail-color", "png")), plate: .bleed),
        VendorMark(.plugin, "computer_use_sidecar", .file(.init("features", "computer-use-color", "svg"))),
        VendorMark(.plugin, "discord", .file(.init("plugins", "discord-color", "svg"))),
        VendorMark(.plugin, "eden", .file(.init("plugins", "eden-color", "svg")), plate: .bleed),
        VendorMark(
            .plugin,
            "github",
            .pair(
                light: .init("plugins", "github-black", "svg"),
                dark: .init("plugins", "github-white", "svg")
            )
        ),
        VendorMark(.plugin, "gmail", .file(.init("plugins", "gmail-color", "png")), plate: .bleed),
        VendorMark(
            .plugin,
            "google_calendar",
            .file(.init("plugins", "google-calendar-color", "png")),
            plate: .bleed
        ),
        VendorMark(
            .plugin,
            "google_drive",
            .file(.init("plugins", "google-drive-color", "png")),
            plate: .bleed
        ),
        VendorMark(.plugin, "notion", .file(.init("plugins", "notion-color", "svg"))),
        VendorMark(.plugin, "obsidian", .file(.init("plugins", "obsidian-color", "png")), plate: .bleed),
        VendorMark(.plugin, "slack", .file(.init("plugins", "slack-color", "svg")), plate: .bleed),
        VendorMark(.plugin, "x", .file(.init("plugins", "x-color", "svg")), plate: .bleed),

        // The three native drivers the Integrations page counts under Features.
        VendorMark(.feature, "computer_history", .file(.init("features", "computer-history-color", "svg"))),
        VendorMark(.feature, "computer_use", .file(.init("features", "computer-use-color", "svg"))),
        VendorMark(.feature, "meetings", .file(.init("features", "meetings-color", "svg"))),

        VendorMark(
            .oauthClient,
            "google",
            .pair(
                light: .init("oauth_clients", "google-light", "png"),
                dark: .init("oauth_clients", "google-dark", "png")
            ),
            plate: .bleed
        )
    ]

    public static func mark(_ kind: VendorMark.Kind, _ key: String) -> VendorMark? {
        all.first { $0.kind == kind && $0.key == key }
    }

    /// A plugin row's mark. The Integrations page draws plugins and the three
    /// native driver features in one list, and a row carries only its name, so
    /// the lookup reads both rosters in that order.
    public static func integration(_ key: String) -> VendorMark? {
        mark(.plugin, key) ?? mark(.feature, key)
    }

    /// Google names a shared sign-in client, rather than one Google plugin.
    public static func oauthClient(_ key: String) -> VendorMark? {
        mark(.oauthClient, key) ?? mark(.plugin, key)
    }
}

/// A mark in the shape the row around it draws.
///
/// Decorative at every site: the row carries the name, so nothing is spoken
/// twice. The provenance record names the label that row must speak.
public struct VendorMarkView: View {
    /// The shape a surface asks for. Providers and channels are discs in the
    /// assistant's own rows (redline §5.3); every list row is a rounded tile.
    public enum Container: Equatable, Sendable {
        case disc
        case tile
    }

    private let mark: VendorMark?
    private let kind: VendorMark.Kind
    private let size: Double
    private let container: Container

    @Environment(\.colorScheme) private var colorScheme

    public init(mark: VendorMark?, kind: VendorMark.Kind, size: Double, container: Container = .tile) {
        precondition(size > 0, "a mark is drawn at a positive size")

        self.mark = mark
        self.kind = kind
        self.size = size
        self.container = container
    }

    public var body: some View {
        ZStack {
            plate
            content
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .accessibilityHidden(true)
    }

    /// The ground under the mark. A file that carries its own ground gets
    /// none: it fills the tile itself.
    @ViewBuilder
    private var plate: some View {
        switch mark?.plate {
        case .bleed where image != nil:
            EmptyView()
        case .neutral, .bleed, .none:
            shape.fill(Palette.monoDisc.color)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let image, let mark {
            drawn(image, mark: mark)
        } else {
            Image(systemName: kind.neutralSymbol)
                .font(.system(size: size * Self.symbolInset))
                .foregroundStyle(Palette.secondary.color)
        }
    }

    /// A bleeding mark fills its tile; every other mark is inset on its plate.
    /// A single-ink mark is drawn as a template, which is the one treatment
    /// that keeps it legible in both appearances without redrawing it.
    private func drawn(_ image: NSImage, mark: VendorMark) -> some View {
        let side = mark.plate == .bleed ? size : size * Self.inset

        return Image(nsImage: image)
            .renderingMode(mark.isTemplate ? .template : .original)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .foregroundStyle(Palette.ink.color)
            .frame(width: side, height: side)
    }

    /// How much of the tile a glyph takes.
    ///
    /// Raised from 0.56 on 2026-09-04: at the 20-point settings tile that left
    /// an 11-point box, and a mark whose own file carries whitespace inside its
    /// viewBox (Mistral's is 183 square around a 179 by 127 logotype) drew at
    /// about 7 points beside 20-point marks that bleed. The vendor's own
    /// whitespace is kept rather than the file being cropped, which the records
    /// do not permit.
    static let inset: Double = 0.72

    /// The neutral symbol's size, as a fraction of the tile. Larger than a
    /// glyph's box because a symbol is drawn from a font: at 0.42 the three
    /// providers with no retrievable mark drew an 8-point chip that read as a
    /// smudge rather than as a symbol.
    static let symbolInset: Double = 0.55

    private var image: NSImage? {
        guard let asset = mark?.asset(dark: colorScheme == .dark) else { return nil }

        return VendorMarkLoader.image(asset)
    }

    /// One shape, erased, because it is both the plate's fill and the clip:
    /// two branches would be two shapes, and a mark clipped to one while its
    /// plate drew the other is exactly the seam this avoids.
    private var shape: AnyShape {
        switch container {
        case .disc:
            return AnyShape(Circle())
        case .tile:
            return AnyShape(RoundedRectangle(cornerRadius: size * Self.tileRadiusRatio, style: .continuous))
        }
    }

    /// The tile's corner, as a fraction of its side, so one number serves the
    /// 20-point settings tile and the 28-point plugin tile alike.
    private static let tileRadiusRatio: Double = 0.22
}

/// The disc for a provider the daemon named.
///
/// A provider with a recorded mark draws it; one without draws the neutral
/// symbol beside the daemon's own label. A provider is never given a fabricated
/// monogram just because no kit was reachable for it.
public struct ProviderMarkDisc: View {
    private let provider: String
    private let label: String
    private let diameter: Double

    public init(provider: String, label: String, diameter: Double) {
        precondition(!label.isEmpty, "a provider mark is labelled by its vendor")

        self.provider = provider
        self.label = label
        self.diameter = diameter
    }

    public var body: some View {
        VendorMarkView(
            mark: VendorMarks.mark(.provider, provider),
            kind: .provider,
            size: diameter,
            container: .disc
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }
}

/// Loads a mark out of the resource bundle, once.
///
/// `NSImage` reads both of the formats the marks ship in, so a vendor that
/// publishes only a raster needs no second code path here. The directory is
/// preserved in the bundle because `Resources/VendorMarks` is copied rather
/// than processed.
///
/// It is cached for the same reason `PetAssetCache` exists: a mark is drawn
/// inside a list row, a view body is evaluated on every scroll and every state
/// change, and reading a file off disk per evaluation is a hidden cost that
/// only shows up as a slow list. A miss is cached too, so a packaging defect
/// costs one lookup rather than one per frame.
@MainActor
enum VendorMarkLoader {
    private static var loaded: [String: NSImage?] = [:]

    static func image(_ asset: VendorMark.Asset) -> NSImage? {
        if let cached = loaded[asset.recordedPath] { return cached }

        let image = read(asset)
        loaded[asset.recordedPath] = image

        return image
    }

    private static func read(_ asset: VendorMark.Asset) -> NSImage? {
        guard let url = AppResources.bundle.url(
            forResource: asset.name,
            withExtension: asset.fileExtension,
            subdirectory: "VendorMarks/\(asset.directory)"
        ) else { return nil }

        return NSImage(contentsOf: url)
    }
}
