import Foundation
import Testing

@testable import FermixAppCore

/// The key-name table a `press` and a typed value both read.
@Suite("Browser key table")
struct BrowserKeyTests {
    @Test("the engine's named keys carry the US layout's virtual key code")
    func namedKeys() {
        #expect(BrowserKey.named("Enter") == BrowserKey(keyCode: 36, characters: "\r"))
        #expect(BrowserKey.named("ArrowDown") == BrowserKey(keyCode: 125, characters: "\u{F701}"))
        #expect(BrowserKey.named("Backspace") == BrowserKey(keyCode: 51, characters: "\u{7F}"))
    }

    @Test("a single character not in the named table is a key that types it")
    func singleCharacterFallsBackToTyping() {
        #expect(BrowserKey.named("a") == BrowserKey.typing(Character("a")))
        #expect(BrowserKey.named("q") == BrowserKey(keyCode: 12, characters: "q"))
    }

    @Test("a name that is neither a named key nor one character is unknown")
    func unknownNameIsNil() {
        #expect(BrowserKey.named("Ctrl") == nil)
        #expect(BrowserKey.named("") == nil)
    }

    @Test("an unshifted letter carries no shift")
    func unshiftedLetter() {
        let key = BrowserKey.typing(Character("a"))
        #expect(key?.shift == false)
        #expect(key?.keyCode == 0)
    }

    @Test("an uppercase letter shares its lowercase key code with shift held")
    func uppercaseSharesTheLowercaseKey() {
        let lower = BrowserKey.typing(Character("a"))
        let upper = BrowserKey.typing(Character("A"))
        #expect(upper?.keyCode == lower?.keyCode)
        #expect(upper?.shift == true)
        #expect(upper?.characters == "A")
    }

    @Test("a shifted symbol carries its own key code and shift")
    func shiftedSymbol() {
        let key = BrowserKey.typing(Character("!"))
        #expect(key == BrowserKey(keyCode: 18, characters: "!", shift: true))
    }

    @Test("a character with no key on the US layout has no entry")
    func unmappableCharacterIsNil() {
        #expect(BrowserKey.typing(Character("é")) == nil)
        #expect(BrowserKey.typing(Character("€")) == nil)
    }

    @Test("a whole string types as one key per character")
    func typingAString() {
        let keys = BrowserKey.typing("Hi!")
        #expect(keys?.map(\.characters) == ["H", "i", "!"])
        #expect(keys?.map(\.shift) == [true, false, true])
    }

    @Test("a string holding one unmappable character types as nothing at all")
    func stringWithUnmappableCharacterIsNil() {
        #expect(BrowserKey.typing("Café") == nil)
    }
}
