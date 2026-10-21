import Foundation
import UniformTypeIdentifiers

/// What the file system says of a file on this Mac, read once: its type, and
/// what it is on the disk (M66 §3.5).
///
/// The one reader of these facts, for the pane's opening rule
/// (`BrowserLocalFile`) and a chat tile's (`ChatFileFacts`) alike, so a tile
/// and a click on its link are always decided on the same reading of the
/// same keys.
struct FileFacts: Equatable, Sendable {
    /// What a path is on the disk.
    enum Entry: Equatable, Sendable {
        /// A regular file: its size, and whether its executable bit is set.
        case file(size: Int, isExecutable: Bool)
        /// A folder, or a package, which is a folder its type names.
        case folder
        /// Anything else: a pipe, a socket, a device.
        case other
    }

    /// The resource keys the facts are read from, for a reader that reads
    /// more of the same file in the same call.
    static let keys: Set<URLResourceKey> = [.contentTypeKey, .isRegularFileKey, .isDirectoryKey, .isExecutableKey, .fileSizeKey]

    let type: UTType
    let entry: Entry

    init(type: UTType, entry: Entry) {
        self.type = type
        self.entry = entry
    }

    /// The facts of the file at `file`, nil where the file system cannot say.
    init?(of file: URL) {
        guard let values = try? file.resourceValues(forKeys: Self.keys) else { return nil }

        self.init(values)
    }

    /// The facts among values read with `keys`. A regular file whose size
    /// cannot be read gives no facts at all.
    init?(_ values: URLResourceValues) {
        guard let type = values.contentType else { return nil }

        self.type = type
        if values.isDirectory == true {
            entry = .folder
        } else if values.isRegularFile == true {
            guard let size = values.fileSize else { return nil }

            entry = .file(size: size, isExecutable: values.isExecutable == true)
        } else {
            entry = .other
        }
    }

    /// A regular file's size; a folder, a package among them, and anything
    /// else has none of its own.
    var size: Int? {
        guard case .file(let size, _) = entry else { return nil }

        return size
    }
}
