import Foundation
import Testing

@testable import FermixAppCore

/// A link's card (M72): what it says of its page, read from its address and
/// the preview the engine stored, never from the web. No view is built, and
/// nothing is opened.
@Suite("Chat link cards")
struct ChatLinkCardTests {
    private static let picture = String(repeating: "ab", count: 32)

    private static func face(_ address: String, preview: CompanionLinkPreview? = nil) -> ChatLinkFace {
        ChatLinkFace(ChatStripLink(address: URL(string: address)!, preview: preview))
    }

    private static func preview(site: String = "Garden Notes", imageRef: String? = picture) -> CompanionLinkPreview {
        CompanionLinkPreview(
            link: nil,
            url: "https://gardennotes.example/grow/sunflowers",
            site: site,
            title: "How to grow sunflowers from seed",
            description: nil,
            imageRef: imageRef
        )
    }

    @Test("with a preview, the page's title over its site, its picture, and the site's initial")
    func previewed() {
        let face = Self.face("https://www.gardennotes.example/grow/sunflowers", preview: Self.preview())

        #expect(face.title == "How to grow sunflowers from seed")
        #expect(face.detail == "Garden Notes")
        #expect(face.picture == Self.picture)
        #expect(face.initial == "G")
    }

    @Test("a preview with no site name is under its host, and a picture that is no media ref is none")
    func previewWithoutSite() {
        let face = Self.face("https://www.gardennotes.example/grow/sunflowers", preview: Self.preview(site: "", imageRef: "https://cdn.example/a.jpg"))

        #expect(face.detail == "gardennotes.example")
        #expect(face.picture == nil)
        #expect(face.initial == "G")
    }

    @Test("without a preview, the host over the words of the path's last part, and no picture")
    func bare() {
        let face = Self.face("https://www.seedswap.example/lists/spring-seeds/")

        #expect(face.title == "seedswap.example")
        #expect(face.detail == "Spring seeds")
        #expect(face.picture == nil)
        #expect(face.initial == "S")
    }

    @Test("a path's last part reads as words, and an address that is only its host, or an identifier, has none")
    func words() {
        #expect(ChatLinkFace.words(of: URL(string: "https://a.example/menu")!) == "Menu")
        #expect(ChatLinkFace.words(of: URL(string: "https://a.example/2026/03/cutting_garden+in-one-bed.html")!) == "Cutting garden in one bed")
        #expect(ChatLinkFace.words(of: URL(string: "https://a.example/Spring%20Seeds?ref=chat")!) == "Spring seeds")
        #expect(ChatLinkFace.words(of: URL(string: "https://a.example/")!) == nil)
        #expect(ChatLinkFace.words(of: URL(string: "https://a.example")!) == nil)
        #expect(ChatLinkFace.words(of: URL(string: "https://a.example/p/12345")!) == nil)
        #expect(ChatLinkFace.words(of: URL(string: "https://a.example/v/f3a9c1e77b2d4e08a6c5b0d9")!) == nil)
    }

    @Test("a host loses only a leading www")
    func host() {
        #expect(ChatLinkFace.host(of: URL(string: "https://www.example.com/x")!) == "example.com")
        #expect(ChatLinkFace.host(of: URL(string: "https://news.www.example.com/")!) == "news.www.example.com")
    }
}
