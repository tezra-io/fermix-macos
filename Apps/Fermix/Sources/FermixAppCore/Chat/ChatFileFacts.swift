import Foundation
import UniformTypeIdentifiers

/// The facts a tile reads of the file a path names, off the main thread
/// (`ChatFileFacts.read`): what the pane's own rule reads of it, and what a
/// tile adds to choose its look and to key its preview.
struct ChatFileFacts: Equatable, Sendable {
    /// Where the path really lands, every symbolic link resolved.
    let file: URL
    /// Its type and what it is on the disk, read as the pane reads them.
    let disk: FileFacts
    /// What the preview cache keys on: the file's volume and number, which a
    /// rename keeps and a new file under the old name does not, and its
    /// modification date and size, which an edit changes.
    let identity: ChatFileIdentity
    let modified: Date
    /// Whether it lies inside the Fermix home, as the disk says: decided
    /// where both really are (`FilePlace.path(_:liesUnder:)`), so a link
    /// inside the home that points out of it is outside. This is the word
    /// content is drawn on; `ChatHome.contains` is only the strip's reading
    /// of a path's text before the disk is asked.
    let insideHome: Bool

    var type: UTType { disk.type }

    /// Its size in bytes, for the preview's key. A folder, a package among
    /// them, has none of its own and counts zero.
    var size: Int { disk.size ?? 0 }
}

/// A file's identity on this Mac: its volume and its number there.
struct ChatFileIdentity: Hashable, Sendable {
    let volume: UInt64
    let number: UInt64
}

/// What a tile has learnt of its file so far.
enum ChatFileLookup: Equatable, Sendable {
    /// Its facts are being read.
    case reading
    /// Nothing is there now.
    case missing
    case found(ChatFileFacts)
}

extension ChatFileFacts {
    /// The facts of the file a link names, read where it really lands, or nil
    /// where nothing is there now. It reads the disk, so it is called off the
    /// main thread (`ChatMedia.lookUp`).
    static func read(_ link: URL, home: URL?) -> ChatFileFacts? {
        guard let real = FilePlace.resolved(link.path) else { return nil }

        let file = URL(fileURLWithPath: real)
        var status = stat()
        guard let values = try? file.resourceValues(forKeys: FileFacts.keys.union([.contentModificationDateKey])),
              let disk = FileFacts(values),
              let modified = values.contentModificationDate,
              stat(real, &status) == 0
        else { return nil }

        return ChatFileFacts(
            file: file,
            disk: disk,
            identity: ChatFileIdentity(volume: UInt64(UInt32(bitPattern: status.st_dev)), number: status.st_ino),
            modified: modified,
            insideHome: home.map { FilePlace.path(real, liesUnder: $0) } ?? false
        )
    }
}
