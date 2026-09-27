import Foundation

/// A key as the Mac's keyboard sends it: the virtual key code of the US
/// layout, the characters it types, and whether Shift is held for them.
///
/// `press` names keys the way the engine does (`Enter`, `ArrowDown`, a single
/// character), and typed text is the same table read a character at a time.
/// A character with no key on the US layout has no entry: typing it would
/// claim a key nobody pressed, so such text is set, not typed.
public struct BrowserKey: Equatable, Sendable {
    public let keyCode: UInt16
    public let characters: String
    public let shift: Bool

    public init(keyCode: UInt16, characters: String, shift: Bool = false) {
        self.keyCode = keyCode
        self.characters = characters
        self.shift = shift
    }

    /// The key a name stands for: one of the engine's named keys, or a single
    /// character.
    public static func named(_ name: String) -> BrowserKey? {
        if let key = named[name] { return key }
        guard name.count == 1, let character = name.first else { return nil }

        return typing(character)
    }

    /// The key that types a character.
    public static func typing(_ character: Character) -> BrowserKey? {
        if let code = unshifted[character] { return BrowserKey(keyCode: code, characters: String(character)) }
        if let code = shifted[character] { return BrowserKey(keyCode: code, characters: String(character), shift: true) }

        return nil
    }

    /// The keys that type a text, or nil when a character in it has no key.
    public static func typing(_ text: String) -> [BrowserKey]? {
        var keys: [BrowserKey] = []
        for character in text {
            guard let key = typing(character) else { return nil }
            keys.append(key)
        }

        return keys
    }

    /// The engine's named keys (its `key_params`), plus the navigation keys a
    /// page reads the same way. Arrow and editing keys type the private-use
    /// characters AppKit gives them.
    private static let named: [String: BrowserKey] = [
        "Enter": BrowserKey(keyCode: 36, characters: "\r"),
        "Tab": BrowserKey(keyCode: 48, characters: "\t"),
        "Escape": BrowserKey(keyCode: 53, characters: "\u{1B}"),
        "Backspace": BrowserKey(keyCode: 51, characters: "\u{7F}"),
        "Delete": BrowserKey(keyCode: 117, characters: "\u{F728}"),
        "ArrowUp": BrowserKey(keyCode: 126, characters: "\u{F700}"),
        "ArrowDown": BrowserKey(keyCode: 125, characters: "\u{F701}"),
        "ArrowLeft": BrowserKey(keyCode: 123, characters: "\u{F702}"),
        "ArrowRight": BrowserKey(keyCode: 124, characters: "\u{F703}"),
        "Home": BrowserKey(keyCode: 115, characters: "\u{F729}"),
        "End": BrowserKey(keyCode: 119, characters: "\u{F72B}"),
        "PageUp": BrowserKey(keyCode: 116, characters: "\u{F72C}"),
        "PageDown": BrowserKey(keyCode: 121, characters: "\u{F72D}"),
        "Space": BrowserKey(keyCode: 49, characters: " ")
    ]

    /// The US layout, by the character each key types without Shift.
    private static let unshifted: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11,
        "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21,
        "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31,
        "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42,
        ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, " ": 49, "`": 50
    ]

    /// The same keys, by the character each types with Shift held.
    private static let shifted: [Character: UInt16] = {
        var table: [Character: UInt16] = [
            "!": 18, "@": 19, "#": 20, "$": 21, "^": 22, "%": 23, "+": 24, "(": 25, "&": 26, "_": 27,
            "*": 28, ")": 29, "}": 30, "{": 33, "\"": 39, ":": 41, "|": 42, "<": 43, "?": 44, ">": 47,
            "~": 50
        ]
        for (character, code) in unshifted where character.isLetter {
            table[Character(character.uppercased())] = code
        }
        return table
    }()
}
