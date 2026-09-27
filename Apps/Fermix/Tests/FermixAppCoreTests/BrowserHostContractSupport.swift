import Foundation

@testable import FermixAppCore

/// Loading helpers for the vendored golden `browser_host` fixtures.
///
/// Unlike the companion wire, direction is reversed and the three fixture
/// files are not symmetric: `requests.jsonl` carries everything this build
/// decodes (the handshake reply, daemon requests and daemon errors, each
/// already a bare `type`-carrying object), `events.jsonl` carries everything
/// this build encodes unasked, and `responses.jsonl` carries this build's own
/// answers, which have no `type` at all (`{id, ok, result | error}`).
enum BrowserHostFixtureDefect: Error, Equatable {
    case recordIsNotAnObject(file: String, line: Int)
    case fileIsEmpty(file: String)
    case schemaFieldMissing(String)
}

struct BrowserHostFixtureLine {
    let line: Data
    let object: [String: Any]
}

enum BrowserHostFixtureFile: String {
    case requests = "fixtures/requests.jsonl"
    case responses = "fixtures/responses.jsonl"
    case events = "fixtures/events.jsonl"
}

enum BrowserHostFixtures {
    static func load(_ file: BrowserHostFixtureFile) throws -> [BrowserHostFixtureLine] {
        let data = try VendoredContracts.data(.browserHost, file.rawValue)
        let lines = String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
        guard !lines.isEmpty else {
            throw BrowserHostFixtureDefect.fileIsEmpty(file: file.rawValue)
        }

        return try lines.enumerated().map { index, line in
            let raw = Data(line.utf8)
            let decoded = try JSONSerialization.jsonObject(with: raw)
            guard let object = decoded as? [String: Any] else {
                throw BrowserHostFixtureDefect.recordIsNotAnObject(file: file.rawValue, line: index + 1)
            }
            return BrowserHostFixtureLine(line: raw, object: object)
        }
    }

    /// The vendored schema, as an object.
    static func schema() throws -> [String: Any] {
        let data = try VendoredContracts.data(.browserHost, "protocol.schema.json")
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BrowserHostFixtureDefect.schemaFieldMissing("$")
        }
        return object
    }

    /// One `$defs` entry of the schema.
    static func definition(_ name: String) throws -> [String: Any] {
        let definitions = try schema()["$defs"] as? [String: Any]
        guard let definition = definitions?[name] as? [String: Any] else {
            throw BrowserHostFixtureDefect.schemaFieldMissing("$defs.\(name)")
        }
        return definition
    }

    /// The `type` values a `$defs` entry's discriminator publishes.
    static func publishedTypes(_ definition: String) throws -> Set<String> {
        let properties = try self.definition(definition)["properties"] as? [String: Any]
        let type = properties?["type"] as? [String: Any]
        guard let types = type?["enum"] as? [String] else {
            throw BrowserHostFixtureDefect.schemaFieldMissing("$defs.\(definition).properties.type.enum")
        }
        return Set(types)
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
/// golden `requests.jsonl` line proves the decoder captured every field: the
/// app never sends one of these itself, so there is no encoder to round-trip
/// through, and this is written independently of the decoder's own field
/// names.
enum BrowserHostDaemonWire {
    static func object(_ inbound: BrowserHostInbound) -> [String: Any] {
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

    private static func errorFields(_ error: BrowserHostDaemonError) -> [String: Any] {
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

    private static func requestFields(_ request: BrowserHostRequest) -> [String: Any] {
        switch request {
        case .tabOpen(_, let payload):
            return present([
                "task_id": payload.taskId,
                "url": payload.url,
                "observe": payload.observe,
                "download_dir": payload.downloadDir,
                "task_tab_cap": payload.taskTabCap,
                "tab_cap": payload.tabCap,
                "snapshot": payload.snapshot.map(snapshotObject)
            ])
        case .tabNavigate(_, let payload):
            return present([
                "tab_id": payload.tabId,
                "url": payload.url,
                "observe": payload.observe,
                "snapshot": payload.snapshot.map(snapshotObject)
            ])
        case .tabList(_, let taskId):
            return ["task_id": taskId]
        case .tabFocus(_, let tabId), .tabClose(_, let tabId):
            return ["tab_id": tabId]
        case .taskRelease(_, let taskId):
            return ["task_id": taskId]
        case .pageSnapshot(_, let payload):
            return [
                "tab_id": payload.tabId,
                "mode": payload.mode.rawValue,
                "max_chars": payload.maxChars,
                "depth": payload.depth
            ]
        case .pageScreenshot(_, let payload):
            return ["tab_id": payload.tabId, "full_page": payload.fullPage, "path": payload.path]
        case .pagePdf(_, let tabId, let path):
            return ["tab_id": tabId, "path": path]
        case .pageAct(_, let payload):
            return present([
                "tab_id": payload.tabId,
                "kind": payload.kind.rawValue,
                "observe": payload.observe,
                "snapshot": payload.snapshot.map(snapshotObject),
                "ref": payload.ref,
                "x": payload.x,
                "y": payload.y,
                "text": payload.text,
                "key": payload.key,
                "fields": payload.fields.map { $0.map { ["ref": $0.ref, "text": $0.text] } },
                "field": payload.field?.rawValue,
                "selector": payload.selector,
                "wait_until": payload.waitUntil?.rawValue,
                "timeout_ms": payload.timeoutMs
            ])
        case .pageUpload(_, let tabId, let ref, let path):
            return ["tab_id": tabId, "ref": ref, "path": path]
        case .dialogResolve(_, let tabId, let accept, let text):
            return present(["tab_id": tabId, "accept": accept, "text": text])
        case .cookiesGet(_, let tabId), .cookiesClear(_, let tabId):
            return ["tab_id": tabId]
        case .hostStatus, .hostStopAck:
            return [:]
        }
    }

    private static func snapshotObject(_ options: BrowserHostSnapshotOptions) -> [String: Any] {
        ["mode": options.mode.rawValue, "max_chars": options.maxChars, "depth": options.depth]
    }
}
