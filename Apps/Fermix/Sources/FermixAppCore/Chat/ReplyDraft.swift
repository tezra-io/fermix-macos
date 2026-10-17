import Foundation

/// A turn's draft as it reads while it is being written: the blocks before
/// the last place the words can be cut (`ReplyReading.Cut`) are read once and
/// kept, and each piece that arrives reads only the words after them, the
/// paragraph, list, table or quote still being written. The words before a
/// cut read the same whatever follows them, so the blocks are always the ones
/// the whole draft reads as at once (`ReplyText(markdown:)`), however it
/// arrived. A draft that is not the one kept with more after it, or that `~`
/// reads differently in, is read again from its start.
final class ReplyDraft {
    /// The draft up to its last cut, which the kept blocks were read from.
    private(set) var keptText = ""
    private var kept: [ReplyBlock] = []
    private var home = ""

    /// The draft's blocks, `~` read as `home`.
    func blocks(_ text: String, home: String) -> [ReplyBlock] {
        if home != self.home || !text.utf8.starts(with: keptText.utf8) {
            self.home = home
            keptText = ""
            kept = []
        }
        let start = text.utf8.index(text.startIndex, offsetBy: keptText.utf8.count)
        let rest = String(text[start...])
        let reading = ReplyText.reading(rest, home: home)
        guard let cut = reading.cut else { return kept + reading.blocks }

        kept += reading.blocks[..<cut.blocks]
        keptText += rest[..<cut.index]
        return kept + reading.blocks[cut.blocks...]
    }
}
