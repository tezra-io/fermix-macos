import AppKit
import CoreText
import os
import SwiftUI

/// The face a surface sets its words in (redlines §2). Every working surface
/// and every native control keeps the system's; the chat sets a conversation
/// in the reading face, which is drawn for long replies read on screen
/// (owner, 2026-10-30).
public enum TypeFace: Sendable {
    case system
    case reading
}

extension EnvironmentValues {
    /// The face `fermixType` sets a rung's words in, for every view under the
    /// one that sets it. A monospaced rung keeps the system's monospaced face
    /// in either.
    var typeFace: TypeFace {
        get { self[TypeFaceKey.self] }
        set { self[TypeFaceKey.self] = newValue }
    }
}

private struct TypeFaceKey: EnvironmentKey {
    static let defaultValue: TypeFace = .system
}

/// The chat's reading face, Hanken Grotesk: shipped in the app's resources
/// with its licence and its provenance (`Resources/Fonts`), and registered
/// for this process alone the first time a word is set in it, so nothing is
/// installed on the Mac. Its weights come from one variable file and its
/// italics from the other; a character it has no glyph for, a script it does
/// not cover or an emoji, is drawn by the system's cascade.
enum ReadingFace {
    static let family = "Hanken Grotesk"
    /// The folder in the resource bundle, and the files registered from it.
    static let folder = "Fonts"
    static let files = ["HankenGrotesk.ttf", "HankenGrotesk-Italic.ttf"]

    /// The face as SwiftUI sets it, at a size already scaled.
    static func font(size: Double, weight: FermixFontWeight) -> Font {
        register()
        return Font.custom(family, fixedSize: size).weight(weight.fontWeight)
    }

    /// The face as AppKit draws it, upright or italic.
    static func nsFont(size: Double, weight: NSFont.Weight, italic: Bool = false) -> NSFont {
        register()
        var traits: [NSFontDescriptor.TraitKey: Any] = [.weight: weight]
        if italic {
            traits[.symbolic] = NSFontDescriptor.SymbolicTraits.italic.rawValue
        }
        let descriptor = NSFontDescriptor(fontAttributes: [.family: family, .traits: traits])
        guard let font = NSFont(descriptor: descriptor, size: size) else {
            preconditionFailure("a font descriptor naming a family always makes a font")
        }

        return font
    }

    /// Registers the files once, before the first word set in the face.
    static func register() {
        _ = registration
    }

    /// The files registered for this process. A file that cannot be
    /// registered is logged, and the words it would have set are drawn in the
    /// system's face by the cascade: a packaging fault the staged bundle's
    /// check refuses before it ships (`verify_staged_app.sh`).
    private static let registration: Void = {
        guard let fonts = AppResources.bundle.url(forResource: folder, withExtension: nil) else {
            AppLog.logger(.app).error("the reading face's folder is missing from the resource bundle")
            return
        }
        for file in files {
            var failure: Unmanaged<CFError>?
            guard !CTFontManagerRegisterFontsForURL(fonts.appendingPathComponent(file) as CFURL, .process, &failure) else { continue }

            let reason = failure.map { CFErrorCopyDescription($0.takeRetainedValue()) as String } ?? ""
            AppLog.logger(.app).error("the reading face's \(file, privacy: .public) was not registered: \(reason, privacy: .public)")
        }
    }()
}
