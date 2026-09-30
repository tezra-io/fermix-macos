import AppKit
import FermixAppCore
import WebKit

/// `page.screenshot` and `page.pdf` (plan §4.9), on `WKWebView`'s own
/// snapshot and PDF APIs.
///
/// A `full_page` screenshot asks for a snapshot as tall as the document: where
/// WebKit renders that, the image is the whole page; where it does not (its
/// own documented limit is the receiver's current bounds), the image is the
/// viewport it always was. `PROTOCOL.md`'s `page.screenshot` result carries no
/// field for which one happened, so that is the whole of what this build can
/// say about it on the wire.
@MainActor
final class WebKitPageCapture {
    private let webView: WKWebView
    private let script: WebKitPageScript

    init(webView: WKWebView, script: WebKitPageScript) {
        self.webView = webView
        self.script = script
    }

    func screenshot(fullPage: Bool) async throws -> BrowserPageCapture {
        let configuration = WKSnapshotConfiguration()
        if fullPage, let height = try? await documentHeight(), height > webView.bounds.height {
            configuration.rect = CGRect(x: 0, y: 0, width: webView.bounds.width, height: height)
        }

        let image = try await webView.takeSnapshot(configuration: configuration)
        guard let data = Self.pngData(image) else {
            throw BrowserPageDriveError.script("could not encode the screenshot")
        }

        return BrowserPageCapture(
            data: data,
            mimeType: "image/png",
            devicePixelRatio: Double(webView.window?.backingScaleFactor ?? 1)
        )
    }

    func pdf() async throws -> Data {
        try await webView.pdf(configuration: WKPDFConfiguration())
    }

    private func documentHeight() async throws -> Double {
        let answer: DocumentHeight = try await script.call("documentHeight", [])
        return answer.value
    }

    private static func pngData(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }

        return rep.representation(using: .png, properties: [:])
    }
}

private struct DocumentHeight: Decodable {
    let value: Double
}
