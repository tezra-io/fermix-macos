import Foundation

@testable import FermixAppCore

/// Loading helpers for the vendored golden realtime fixtures.
///
/// The realtime fixture files are bare newline-delimited wire events (no name
/// wrapper), so they are read as objects and matched by their `type`.
enum RealtimeFixtureDefect: Error, Equatable {
    case recordIsNotAnObject(file: String, line: Int)
    case recordHasNoType(file: String, line: Int)
    case fileIsEmpty(file: String)
}

struct RealtimeFixture {
    let type: String
    let line: Data
    let object: [String: Any]
}

enum RealtimeFixtureFile: String, CaseIterable {
    case clientEvents = "fixtures/client_events.jsonl"
    case serverEvents = "fixtures/server_events.jsonl"
}

enum RealtimeFixtures {
    static func load(_ file: RealtimeFixtureFile) throws -> [RealtimeFixture] {
        let data = try VendoredContracts.data(.realtime, file.rawValue)
        let lines = String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
        guard !lines.isEmpty else {
            throw RealtimeFixtureDefect.fileIsEmpty(file: file.rawValue)
        }

        return try lines.enumerated().map { index, line in
            let raw = Data(line.utf8)
            let decoded = try JSONSerialization.jsonObject(with: raw)
            guard let object = decoded as? [String: Any] else {
                throw RealtimeFixtureDefect.recordIsNotAnObject(file: file.rawValue, line: index + 1)
            }
            guard let type = object["type"] as? String else {
                throw RealtimeFixtureDefect.recordHasNoType(file: file.rawValue, line: index + 1)
            }
            return RealtimeFixture(type: type, line: raw, object: object)
        }
    }

    /// Compares two wire frames as objects, so a key-order difference between an
    /// encoder and a golden file is not read as a contract difference.
    static func sameObject(_ produced: Data, _ golden: Data) throws -> Bool {
        let left = try JSONSerialization.jsonObject(with: produced)
        let right = try JSONSerialization.jsonObject(with: golden)
        guard let left = left as? [String: Any], let right = right as? [String: Any] else {
            return false
        }
        return NSDictionary(dictionary: left).isEqual(to: right)
    }
}
