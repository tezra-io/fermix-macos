import Foundation

/// Why the website profile's identity could not be read or kept.
public enum WebsiteProfileRecordError: Error, Equatable, Sendable {
    case malformed(path: String)
    case unsupportedSchemaVersion(Int)
}

/// The identity of the one persistent website profile (plan §4.6).
///
/// WebKit keeps a profile's cookies and storage under an identifier the app
/// chooses, so the identifier is the profile: a new one is a person signed out
/// of every website. It is created once, on the first tab, and kept in the
/// app's support folder beside the bootstrap record and the two journals,
/// where an update that replaces the bundle cannot touch it. The development
/// identity has its own support folder, so it has its own profile too.
///
/// The one reader and writer of this file. The bytes go through `JournalFile`,
/// so a reader sees the record or no record and never half of one.
public struct WebsiteProfileRecord {
    public static let fileName = "website-profile.json"
    public static let supportedSchemaVersion = 1

    private let file: JournalFile

    public init(location: BootstrapLocation, fileManager: FileManager = .default) {
        self.file = JournalFile(directory: location.directoryURL, name: Self.fileName, fileManager: fileManager)
    }

    public var url: URL { file.url }

    /// The profile's identifier: the one on record, or a new one recorded now.
    ///
    /// A record that is there and cannot be read is thrown rather than
    /// replaced, because replacing it would sign the person out of every
    /// website without a word.
    public func identifier() throws -> UUID {
        guard let data = try file.read() else { return try create() }

        let entry: Entry
        do {
            entry = try JSONDecoder().decode(Entry.self, from: data)
        } catch {
            throw WebsiteProfileRecordError.malformed(path: url.path)
        }
        guard entry.schemaVersion == Self.supportedSchemaVersion else {
            throw WebsiteProfileRecordError.unsupportedSchemaVersion(entry.schemaVersion)
        }

        return entry.identifier
    }

    private func create() throws -> UUID {
        let entry = Entry(schemaVersion: Self.supportedSchemaVersion, identifier: UUID())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try file.write(try encoder.encode(entry))

        return entry.identifier
    }

    private struct Entry: Codable {
        let schemaVersion: Int
        let identifier: UUID

        private enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case identifier
        }
    }
}
