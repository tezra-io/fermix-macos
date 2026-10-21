import Foundation

@testable import FermixAppCore

/// Loading helpers for the vendored golden `native_host` fixtures.
///
/// The browser host's layout, and its asymmetry: `requests.jsonl` carries
/// everything this build decodes (the handshake reply, the daemon's requests
/// and its errors), `events.jsonl` everything this build sends unasked, and
/// `responses.jsonl` this build's own answers, which carry no `type`.
enum NativeHostFixtureDefect: Error, Equatable {
    case recordIsNotAnObject(file: String, line: Int)
    case fileIsEmpty(file: String)
    case schemaFieldMissing(String)
}

struct NativeHostFixtureLine {
    let line: Data
    let object: [String: Any]
}

enum NativeHostFixtureFile: String {
    case requests = "fixtures/requests.jsonl"
    case responses = "fixtures/responses.jsonl"
    case events = "fixtures/events.jsonl"
}

enum NativeHostFixtures {
    static func load(_ file: NativeHostFixtureFile) throws -> [NativeHostFixtureLine] {
        let data = try VendoredContracts.data(.nativeHost, file.rawValue)
        let lines = String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
        guard !lines.isEmpty else {
            throw NativeHostFixtureDefect.fileIsEmpty(file: file.rawValue)
        }

        return try lines.enumerated().map { index, line in
            let raw = Data(line.utf8)
            guard let object = try JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
                throw NativeHostFixtureDefect.recordIsNotAnObject(file: file.rawValue, line: index + 1)
            }
            return NativeHostFixtureLine(line: raw, object: object)
        }
    }

    /// The vendored schema, as an object.
    static func schema() throws -> [String: Any] {
        let data = try VendoredContracts.data(.nativeHost, "protocol.schema.json")
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NativeHostFixtureDefect.schemaFieldMissing("$")
        }
        return object
    }

    /// One `$defs` entry of the schema.
    static func definition(_ name: String) throws -> [String: Any] {
        let definitions = try schema()["$defs"] as? [String: Any]
        guard let definition = definitions?[name] as? [String: Any] else {
            throw NativeHostFixtureDefect.schemaFieldMissing("$defs.\(name)")
        }
        return definition
    }

    /// One property of a `$defs` entry.
    static func property(_ name: String, of definition: String) throws -> [String: Any] {
        let properties = try self.definition(definition)["properties"] as? [String: Any]
        guard let property = properties?[name] as? [String: Any] else {
            throw NativeHostFixtureDefect.schemaFieldMissing("$defs.\(definition).properties.\(name)")
        }
        return property
    }

    /// The `enum` a `$defs` entry, or one of its properties, publishes.
    static func enumeration(_ definition: String, property: String? = nil) throws -> Set<String> {
        let holder = try property.map { try self.property($0, of: definition) } ?? self.definition(definition)
        guard let values = holder["enum"] as? [String] else {
            throw NativeHostFixtureDefect.schemaFieldMissing("$defs.\(definition).\(property ?? "").enum")
        }
        return Set(values)
    }

    /// Compares two wire lines as objects, so a key-order difference between
    /// an encoder and a golden file is not read as a contract difference.
    static func sameObject(_ produced: Data, _ golden: Data) throws -> Bool {
        let left = try JSONSerialization.jsonObject(with: produced)
        let right = try JSONSerialization.jsonObject(with: golden)
        guard let left = left as? [String: Any], let right = right as? [String: Any] else {
            return false
        }
        return NSDictionary(dictionary: left).isEqual(to: right)
    }
}

/// Writes a decoded daemon frame back out as the object it carried, so a
/// golden `requests.jsonl` line proves the decoder captured every field. The
/// app never sends one of these itself, so this is written independently of
/// the decoder's own field names.
enum NativeHostDaemonWire {
    static func object(_ inbound: NativeHostInbound) -> [String: Any] {
        switch inbound {
        case .serverHello(let minVersion, let maxVersion):
            return ["type": "server_hello", "min_version": minVersion, "max_version": maxVersion]
        case .error(let error):
            return errorFields(error).merging(["type": "error"]) { _, type in type }
        case .request(let request):
            return requestFields(request).merging(["type": request.wireType, "id": request.id]) { _, value in value }
        }
    }

    private static func present(_ fields: [String: Any?]) -> [String: Any] {
        fields.compactMapValues { $0 }
    }

    private static func errorFields(_ error: NativeHostDaemonError) -> [String: Any] {
        present([
            "reason": error.reason,
            "message": error.message,
            "field": error.field,
            "event": error.event,
            "direction": error.direction?.rawValue,
            "client_version": error.clientVersion,
            "min_version": error.minVersion,
            "max_version": error.maxVersion
        ])
    }

    private static func requestFields(_ request: NativeHostRequest) -> [String: Any] {
        switch request {
        case .notificationsPost(_, let payload):
            return present([
                "title": payload.title,
                "body": payload.body,
                "sound": payload.sound,
                "actions": payload.actions.map { ["id": $0.id, "title": $0.title] },
                "reminder_id": payload.reminderId
            ])
        case .notificationsAuthorize, .hostStatus, .hostStopAck:
            return [:]
        }
    }
}
