import Foundation
import Testing

@testable import FermixAppCore

/// `BrowserHostProtocol.closedPaths`, the places the login ledger's scrub
/// leaves whole, held to the protocol 2 schema both ways: each one is an
/// `enum` or a `const` there, and every string `enum` or `const` in a frame
/// this build sends is one of them. A closed value the scrub touched would
/// break a frame the daemon reads; a free-text value it skipped would carry a
/// password out.
@Suite("Browser host closed paths")
struct BrowserHostClosedPathTests {
    @Test("every closed path is an enum or a const in the schema, and every closed string the app sends is a closed path")
    func closedPathsMatchTheSchema() throws {
        let schema = try BrowserHostFixtures.schema()
        #expect(schema["x-protocol-version"] as? Int == BrowserHostProtocol.version, "the schema is protocol 2's")
        let derived = try Self.closedPaths(in: schema)

        for (frame, paths) in BrowserHostProtocol.closedPaths {
            for path in paths where derived[frame]?.contains(path) != true {
                Issue.record("\(frame) \(path) is not closed in the schema, so the scrub must not skip it")
            }
        }
        for (frame, paths) in derived {
            for path in paths where BrowserHostProtocol.closedPaths[frame]?.contains(path) != true {
                Issue.record("\(frame) \(path) is closed in the schema but not in BrowserHostProtocol.closedPaths")
            }
        }
        #expect(Set(derived.keys) == Set(BrowserHostProtocol.closedPaths.keys))
    }

    @Test("free text that shares a closed key's name elsewhere is not closed: availability, task.cancel and download.finished reasons")
    func freeTextReasonsAreNotClosed() {
        for frame in ["availability", "task.cancel", "download.finished"] {
            #expect(BrowserHostProtocol.closedPaths[frame]?.contains(["reason"]) == false, "\(frame)")
        }
        #expect(BrowserHostProtocol.closedPaths["response"]?.contains(["error", "message"]) == false)
        #expect(BrowserHostProtocol.closedPaths["response"]?.contains(["error", "reason"]) == true)
    }

    // MARK: - The schema walk

    /// Every string `enum` or `const` under `response` and under each event
    /// the schema's `hostEvent` names, by the keys down to it.
    static func closedPaths(in schema: [String: Any]) throws -> [String: Set<[String]>] {
        let definitions = try #require(schema["$defs"] as? [String: Any])
        let eventTypes = try #require(
            ((definitions["hostEvent"] as? [String: Any])?["properties"] as? [String: Any])
                .flatMap { ($0["type"] as? [String: Any])?["enum"] as? [String] }
        )
        var walk = SchemaWalk(definitions: definitions)
        var paths: [String: Set<[String]>] = [:]
        for frame in ["response"] + eventTypes {
            let definition = try #require(definitions[frame] as? [String: Any], "no definition for \(frame)")
            var found: Set<[String]> = []
            walk.collect(definition, at: [], into: &found)
            paths[frame] = found
        }
        return paths
    }
}

/// A walk of the schema's own structure: references, properties, array
/// items and the combinators, each reference followed once per place.
private struct SchemaWalk {
    let definitions: [String: Any]
    private var followed: Set<String> = []

    init(definitions: [String: Any]) {
        self.definitions = definitions
    }

    mutating func collect(_ node: [String: Any], at path: [String], into found: inout Set<[String]>) {
        if let reference = node["$ref"] as? String, let name = reference.split(separator: "/").last.map(String.init),
           followed.insert("\(name)@\(path.joined(separator: "/"))").inserted,
           let definition = definitions[name] as? [String: Any] {
            collect(definition, at: path, into: &found)
        }
        let values = (node["enum"] as? [Any]) ?? node["const"].map { [$0] } ?? []
        if values.contains(where: { $0 is String || $0 is [Any] }) {
            found.insert(node["type"] as? String == "array" ? path + ["*"] : path)
        }
        for (key, child) in node["properties"] as? [String: Any] ?? [:] {
            if let child = child as? [String: Any] { collect(child, at: path + [key], into: &found) }
        }
        if let items = node["items"] as? [String: Any] { collect(items, at: path + ["*"], into: &found) }
        for combinator in ["anyOf", "oneOf", "allOf"] {
            for branch in node[combinator] as? [[String: Any]] ?? [] { collect(branch, at: path, into: &found) }
        }
        for branch in ["then", "else"] {
            if let child = node[branch] as? [String: Any] { collect(child, at: path, into: &found) }
        }
    }
}
