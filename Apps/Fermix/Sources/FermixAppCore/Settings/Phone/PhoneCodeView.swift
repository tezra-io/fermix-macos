import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

/// A pairing link as a QR code's modules, before anything is scaled (M60 §3.5).
///
/// Drawn with Core Image's own generator from the link's bytes at correction
/// level M, which is what `fermix pair` draws and the highest level a
/// 2048-byte link fits. Core Image's own margin is dropped, so the quiet zone
/// is exactly the one the card draws.
///
/// The modules are the link in another form, so they are withheld from every
/// description exactly as the link is.
public struct PairingCode: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable {
    /// One row per module row, top first; true where the module is dark.
    public let modules: [[Bool]]

    public var description: String { "PairingCode(\(count) modules, withheld)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }

    /// The modules on a side, without the quiet zone.
    public var count: Int { modules.count }

    /// Nil only where Core Image draws nothing, which a link the guards passed
    /// never is.
    public static func make(from link: PairingLink) -> PairingCode? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = link.utf8
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }

        let context = CIContext(options: [.useSoftwareRenderer: true])
        guard let image = context.createCGImage(output, from: output.extent.integral),
              let pixels = darkPixels(of: image)
        else { return nil }

        return PairingCode(modules: cropped(pixels))
    }

    /// The image's pixels, one per module, read top row first.
    private static func darkPixels(of image: CGImage) -> [[Bool]]? {
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let bitmap = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }

            bitmap.interpolationQuality = .none
            bitmap.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }

        // A bitmap context's first row in memory is the top of what it drew.
        return (0..<height).map { row in
            (0..<width).map { column in bytes[row * width + column] < 128 }
        }
    }

    /// The square the dark modules span. A QR code's three finder patterns sit
    /// in its corners, so their bounds are the code's.
    private static func cropped(_ pixels: [[Bool]]) -> [[Bool]] {
        guard let first = pixels.first else { return [] }

        let rows = pixels.indices.filter { pixels[$0].contains(true) }
        let columns = first.indices.filter { column in pixels.contains { $0[column] } }
        guard let top = rows.first, let bottom = rows.last,
              let left = columns.first, let right = columns.last
        else { return [] }

        return pixels[top...bottom].map { Array($0[left...right]) }
    }
}

/// How large the card is drawn (M60 §3.5): whole points per module and never
/// fewer than two, a four-module quiet zone, and a card that grows with the
/// code up to the sheet's width.
public enum PairingCodeLayout {
    public static let quietZone = 4
    public static let minimumModulePoints = 2
    /// The side a short link's card is drawn at, near enough.
    public static let preferredSide = 240
    /// The widest the card may be: the credential sheet's own content width.
    public static var maximumSide: Int {
        Int(SheetMetrics.credentialWidth - 2 * WindowMetrics.contentPadding)
    }

    /// Modules on a side, quiet zone included.
    public static func span(of code: PairingCode) -> Int {
        code.count + 2 * quietZone
    }

    public static func modulePoints(for code: PairingCode) -> Int {
        max(minimumModulePoints, preferredSide / span(of: code))
    }

    public static func side(of code: PairingCode) -> Int {
        span(of: code) * modulePoints(for: code)
    }
}

/// The code on its white card: black on white in both appearances, since a
/// scanner needs the contrast the window's ground does not give in dark mode,
/// and with Increase contrast on as well. Scaled by whole numbers with no
/// smoothing.
///
/// The image is labelled and carries no value: what it draws is the secret.
struct PairingCodeCard: View {
    let code: PairingCode

    /// The card's two colours, the same in both appearances.
    private static let paper = ThemedColor(uniform: SRGBColor(hex: "#ffffff"))

    var body: some View {
        let side = Double(PairingCodeLayout.side(of: code))

        Image(decorative: image, scale: 1)
            .interpolation(.none)
            .resizable()
            .frame(width: side, height: side)
            .background(Self.paper.color)
            .clipShape(RoundedRectangle(cornerRadius: Radius.controlCompact, style: .continuous))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(ProductStrings[.phoneScanCodeLabel])
            .accessibilityAddTraits(.isImage)
    }

    /// One pixel per module, quiet zone included, in grey: white paper and
    /// black modules.
    private var image: CGImage {
        let span = PairingCodeLayout.span(of: code)
        let zone = PairingCodeLayout.quietZone
        var bytes = [UInt8](repeating: 255, count: span * span)
        for (row, modules) in code.modules.enumerated() {
            for (column, dark) in modules.enumerated() where dark {
                bytes[(row + zone) * span + column + zone] = 0
            }
        }

        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(
                  width: span,
                  height: span,
                  bitsPerComponent: 8,
                  bitsPerPixel: 8,
                  bytesPerRow: span,
                  space: CGColorSpaceCreateDeviceGray(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              )
        else { preconditionFailure("a grey bitmap of the code's own size is always drawable") }

        return image
    }
}

/// Keeps the window the code is drawn in out of screen sharing and recordings
/// while the code is on screen (M60 decision 5), and gives the window its
/// sharing back when the code leaves.
///
/// The one place the sheet reaches its window, so nothing that is tested
/// touches one.
struct ScreenCaptureExclusion: NSViewRepresentable {
    func makeNSView(context: Context) -> ExcludingView {
        ExcludingView()
    }

    func updateNSView(_ view: ExcludingView, context: Context) {}

    static func dismantleNSView(_ view: ExcludingView, coordinator: ()) {
        view.release()
    }

    final class ExcludingView: NSView {
        private weak var excluded: NSWindow?
        private var sharing: NSWindow.SharingType = .readOnly

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            release()
            guard let window else { return }

            sharing = window.sharingType
            window.sharingType = .none
            excluded = window
        }

        func release() {
            excluded?.sharingType = sharing
            excluded = nil
        }
    }
}
