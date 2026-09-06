import Foundation

@testable import FermixAppCore

/// Loading and comparison helpers for the vendored golden management fixtures.
///
/// The fixtures are the same frames the daemon is tested against, vendored from
/// `apps/fermix_core/priv/management/fixtures/` and pinned by checksum. Tests
/// read them out of the shipped resource bundle rather than restating shapes,
/// so an upstream change to the contract lands here as a test failure.
enum ManagementFixtureDefect: Error, Equatable {
    case recordIsNotAnObject(file: String, line: Int)
    case recordHasNoName(file: String, line: Int)
    case recordFieldMissing(name: String, field: String)
    case fileIsEmpty(file: String)
}

/// One `*.jsonl` record: its declared name plus the raw decoded object.
struct ManagementFixture {
    let name: String
    let object: [String: Any]

    func object(_ field: String) throws -> [String: Any] {
        guard let value = object[field] as? [String: Any] else {
            throw ManagementFixtureDefect.recordFieldMissing(name: name, field: field)
        }
        return value
    }

    func string(_ field: String) throws -> String {
        guard let value = object[field] as? String else {
            throw ManagementFixtureDefect.recordFieldMissing(name: name, field: field)
        }
        return value
    }
}

enum ManagementFixtureFile: String, CaseIterable {
    case requests = "fixtures/requests.jsonl"
    case success = "fixtures/success.jsonl"
    case errors = "fixtures/errors.jsonl"
    case compatibility = "fixtures/compatibility.jsonl"
}

enum ManagementFixtures {
    /// Every record in one fixture file of one shipped contract, in file order.
    ///
    /// The contract is explicit rather than defaulted: the management tree and
    /// the realtime tree are two published wires, and a test that read the wrong
    /// one would still pass on the shapes they share.
    static func load(
        _ file: ManagementFixtureFile,
        from contract: VendoredContract = .management
    ) throws -> [ManagementFixture] {
        let data = try VendoredContracts.data(contract, file.rawValue)
        let lines = String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
        guard !lines.isEmpty else {
            throw ManagementFixtureDefect.fileIsEmpty(file: file.rawValue)
        }

        return try lines.enumerated().map { index, line in
            let decoded = try JSONSerialization.jsonObject(with: Data(line.utf8))
            guard let object = decoded as? [String: Any] else {
                throw ManagementFixtureDefect.recordIsNotAnObject(file: file.rawValue, line: index + 1)
            }
            guard let name = object["name"] as? String else {
                throw ManagementFixtureDefect.recordHasNoName(file: file.rawValue, line: index + 1)
            }
            return ManagementFixture(name: name, object: object)
        }
    }

    /// The success envelope published for each method, keyed by wire method
    /// name. Used to answer a request with the contract's own result shape.
    static func successEnvelopesByMethod(
        from contract: VendoredContract = .management
    ) throws -> [String: [String: Any]] {
        // The first record a method publishes, not the last: several methods
        // publish more than one golden (a fresh home, a configured one), and a
        // helper whose answer moved with file order would make an unrelated
        // fixture addition change what a negotiation case is asserting.
        var envelopes: [String: [String: Any]] = [:]
        for fixture in try load(.success, from: contract) {
            let method = try fixture.string("method")
            guard envelopes[method] == nil else { continue }

            envelopes[method] = try fixture.object("response")
        }
        return envelopes
    }

    static func encode(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    static func decode(_ data: Data) throws -> [String: Any] {
        let decoded = try JSONSerialization.jsonObject(with: data)
        guard let object = decoded as? [String: Any] else {
            throw ManagementFixtureDefect.recordIsNotAnObject(file: "response", line: 0)
        }
        return object
    }

    static func equal(_ lhs: [String: Any], _ rhs: [String: Any]) -> Bool {
        NSDictionary(dictionary: lhs).isEqual(to: rhs)
    }
}

/// Answers every request with the contract's published success envelope for
/// that method, echoing back the request id it was sent. Used to exercise
/// request *encoding*: the response is scaffolding, the captured frame is the
/// assertion.
final class EchoingFixtureTransport: ManagementTransport, @unchecked Sendable {
    private let queue = DispatchQueue(label: "test.management.echo")
    private let envelopes: [String: [String: Any]]
    private var captured: [[String: Any]] = []

    init(envelopes: [String: [String: Any]]) {
        self.envelopes = envelopes
    }

    var capturedFrames: [[String: Any]] {
        queue.sync { captured }
    }

    func exchange(_ payload: Data, timeout: Duration) async throws -> Data {
        let frame = try ManagementFixtures.decode(payload)
        queue.sync { captured.append(frame) }

        guard let method = frame["method"] as? String,
              let envelope = envelopes[method],
              let result = envelope["result"] else {
            throw ManagementFixtureDefect.recordFieldMissing(
                name: frame["method"] as? String ?? "unknown",
                field: "result"
            )
        }
        return try ManagementFixtures.encode([
            "request_id": frame["request_id"] as Any,
            "result": result
        ])
    }
}

/// Replays a fixed script of raw response payloads, in order, and records what
/// was sent. A script that runs out is a test defect, never a silent reuse.
final class ScriptedManagementTransport: ManagementTransport, @unchecked Sendable {
    enum Defect: Error, Equatable {
        case scriptExhausted(afterExchanges: Int)
    }

    private let queue = DispatchQueue(label: "test.management.script")
    private var responses: [Data]
    private var sent: [Data] = []

    init(responses: [Data]) {
        self.responses = responses
    }

    var sentPayloads: [Data] {
        queue.sync { sent }
    }

    func exchange(_ payload: Data, timeout: Duration) async throws -> Data {
        try queue.sync {
            sent.append(payload)
            guard !responses.isEmpty else {
                throw Defect.scriptExhausted(afterExchanges: sent.count - 1)
            }
            return responses.removeFirst()
        }
    }
}

/// Hands out one fixed request id, so a test can compare an emitted frame with
/// a golden frame byte for byte instead of masking the id.
struct FixedRequestIdentifierGenerator: ManagementRequestIdentifierGenerator {
    let identifier: String

    func nextIdentifier(for method: ManagementMethod) -> String { identifier }
}

/// A clock frozen at a chosen instant, so a relative lease TTL resolves to a
/// deterministic absolute deadline.
struct FixedManagementClock: ManagementClock {
    let instant: Date

    var now: Date { instant }
}

enum ManagementTestClient {
    /// A client wired to one shipped contract, with a deterministic id and
    /// clock.
    static func make(
        transport: ManagementTransport,
        contract: ManagementContract? = nil,
        requestIdentifier: String = "req-test-1",
        clock: Date = Date(timeIntervalSince1970: 1_755_561_000)
    ) throws -> ManagementClient {
        ManagementClient(
            transport: transport,
            contract: try contract ?? ManagementContract.vendored(),
            clock: FixedManagementClock(instant: clock),
            identifiers: FixedRequestIdentifierGenerator(identifier: requestIdentifier)
        )
    }
}
