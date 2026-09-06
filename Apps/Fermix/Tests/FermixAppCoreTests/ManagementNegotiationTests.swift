import Foundation
import Testing

@testable import FermixAppCore

/// M34 §7.1: the version is a window on both sides.
///
/// The failure this suite exists to prevent is the permanent trap at the first
/// engine bump: an app that declares one integer and refuses everything when the
/// daemon's window excludes it cannot call `lifecycle.prepare`, which is the one
/// call it needs to restart that daemon onto the engine in its own bundle. So
/// the guarantee is asserted from both ends — what an N-1 daemon still serves,
/// and what it refuses — rather than only that a refusal exists.
@Suite("Management version negotiation")
struct ManagementNegotiationTests {

    // MARK: - The negotiated version

    @Test("the negotiated version is the highest both sides speak")
    func negotiatedVersionIsTheHighestShared() throws {
        let cases: [(minimum: Int, maximum: Int, expected: Int?)] = [
            (1, 2, 2),
            (1, 1, 1),
            (2, 2, 2),
            (2, 3, 2),
            (3, 4, nil)
        ]

        for scenario in cases {
            let window = try ManagementValueFixture.protocolRange(
                minimum: scenario.minimum,
                maximum: scenario.maximum
            )

            #expect(
                ManagementNegotiation.highestShared(speakable: [1, 2], daemon: window)
                    == scenario.expected,
                "{\(scenario.minimum), \(scenario.maximum)}"
            )
        }
    }

    // MARK: - Empty intersection

    @Test("a daemon sharing no version refuses every call past hello")
    func emptyIntersectionIsIncompatible() async throws {
        let client = try Self.client(window: (minimum: 3, maximum: 4))

        _ = try await client.hello()

        await #expect(
            throws: ManagementError.incompatibleProtocol(
                app: [1, 2],
                daemon: try ManagementValueFixture.protocolRange(
                    current: 4,
                    minimum: 3,
                    maximum: 4
                )
            )
        ) {
            _ = try await client.overview()
        }
    }

    // MARK: - The N-1 window

    /// The guarantee, stated as the design states it: against a daemon one
    /// release behind, everything at minimum 1 works, so the app can read the
    /// state, show the reason, and restart that daemon onto the newer engine.
    @Test("an N-1 window serves every method whose minimum is 1")
    func n1WindowServesTheV1Catalog() async throws {
        #expect(Self.v1Catalog().count == 11)

        let client = try Self.client(window: (minimum: 1, maximum: 1))
        _ = try await client.hello()

        let lease = try await client.prepareLifecycle()
        #expect(!lease.leaseId.isEmpty)

        let overview = try await client.overview()
        #expect(overview.health.restartRequired)

        _ = try await client.queryLogs(ManagementLogsQuery())
        _ = try await client.startDoctor()
    }

    /// The invariant is written over the whole catalog, not over one method
    /// somebody remembered: a method added later either joins it or fails the
    /// call table's own coverage assertion.
    @Test("an N-1 window refuses every method whose minimum is 2")
    func n1WindowRefusesTheV2Catalog() async throws {
        let contract = try ManagementContract.vendored()
        let v1 = Self.v1Catalog()
        let requests = try ManagementFixtures.load(.requests, from: .management)
        var refused: Set<String> = []

        for fixture in requests where !v1.contains(try fixture.string("method")) {
            let method = try #require(ManagementMethod(rawValue: try fixture.string("method")))
            let invoke = try #require(ManagementV2Calls.byFixture[fixture.name])
            let client = try Self.client(window: (minimum: 1, maximum: 1))
            _ = try await client.hello()

            await #expect(
                throws: ManagementError.methodRequiresNewerEngine(
                    method: method,
                    required: contract.minimumVersion(for: method),
                    negotiated: 1
                ),
                "\(fixture.name)"
            ) {
                try await invoke(client)
            }
            refused.insert(method.rawValue)
        }

        // A gate that never fires is not a gate: the loop has to have covered
        // every method the v1 catalog does not carry.
        #expect(refused == Set(contract.methods).subtracting(v1))
        #expect(refused.count == 31)
    }

    /// The refusal happens before a byte is written: a daemon that has already
    /// said it cannot serve a method is never asked.
    @Test("a refused v2 method sends nothing")
    func refusedMethodSendsNothing() async throws {
        let transport = EchoingFixtureTransport(
            envelopes: try Self.envelopes(window: (minimum: 1, maximum: 1))
        )
        let client = try ManagementTestClient.make(
            transport: transport,
            contract: try ManagementContract.vendored(),
            requestIdentifier: "req-negotiation-1"
        )
        _ = try await client.hello()

        _ = try? await client.setupState()

        #expect(transport.capturedFrames.map { $0["method"] as? String } == ["hello"])
    }

    /// A refusal has to reach the operator as the state it is, not as an
    /// unexplained failure: the copy names the restart that fixes it.
    @Test("the two refusals render as two different sentences")
    func refusalsRenderAsCopy() throws {
        let incompatible = ManagementError.incompatibleProtocol(
            app: [1, 2],
            daemon: try ManagementValueFixture.protocolRange(minimum: 3, maximum: 4)
        )
        let newerEngine = ManagementError.methodRequiresNewerEngine(
            method: .settingsGet,
            required: 2,
            negotiated: 1
        )

        #expect(ManagementMessage.sentence(for: incompatible)
            == ProductStrings[.daemonErrorIncompatible])
        #expect(ManagementMessage.sentence(for: newerEngine)
            == ProductStrings[.daemonErrorRequiresNewerEngine])
        #expect(ManagementMessage.sentence(for: incompatible)
            != ManagementMessage.sentence(for: newerEngine))

        #expect(ManagementMessage.requiresNewerEngine(newerEngine))
        #expect(!ManagementMessage.requiresNewerEngine(incompatible))
        // Neither is an unreachable daemon: the socket answered.
        #expect(!ManagementMessage.isUnreachable(newerEngine))
        #expect(!ManagementMessage.isUnreachable(incompatible))
    }

    // MARK: - N-1 results

    /// Every field protocol v2 adds to a v1-minimum method is optional, and
    /// the absent rendering is defined. The two are asserted together: the
    /// schema says the key may be missing, and the golden with that one key
    /// removed — which is exactly what an N-1 daemon sends — still decodes.
    @Test("an N-1 overview without restart reasons renders the plain sentence")
    func n1OverviewDecodes() throws {
        #expect(!(try Self.requiredKeys(of: "overview_get_result", "health")).contains("restart_reasons"))

        let golden = try Self.golden("overview_get")
        var health = try #require(golden["health"] as? [String: Any])
        health.removeValue(forKey: "restart_reasons")

        let overview: ManagementOverview = try Self.decode(
            golden.merging(["health": health]) { _, replacement in replacement }
        )

        #expect(overview.health.restartReasons == nil)
        #expect(overview.health.restartReasonSections.isEmpty)
        #expect(overview.readiness.status == "ready")
    }

    @Test("an N-1 doctor check without a remediation offers no action")
    func n1DoctorDecodes() throws {
        #expect(!(try Self.requiredKeys(of: "doctorCheck")).contains("remediation"))

        var golden = try Self.golden("doctor_get_in_progress")
        let checks = try #require(golden["checks"] as? [[String: Any]])
        golden["checks"] = checks.map { check in
            var stripped = check
            stripped.removeValue(forKey: "remediation")
            return stripped
        }

        let session: ManagementDoctorSession = try Self.decode(golden)

        #expect(!session.checks.isEmpty)
        for check in session.checks {
            #expect(check.remediation == nil)
            #expect(check.remediationActionKind == .none)
        }
    }

    /// The other half of that pair: a v2 daemon's Doctor check carries the
    /// whole remediation, so the absent case above proves something.
    @Test("a v2 doctor check carries a remediation with an action")
    func v2DoctorCarriesRemediation() throws {
        let session: ManagementDoctorSession = try FakeDaemonGateway.fixtureResult(
            named: "doctor_get_in_progress",
            as: ManagementDoctorSession.self
        )
        let check = try #require(session.checks.first { $0.remediation != nil })
        let remediation = try #require(check.remediation)

        // The golden's remediation is the pending restart. It names no target:
        // the surface is the app's own Restart sheet, and there is nothing left
        // to name.
        #expect(remediation.action.kind == .restart)
        #expect(remediation.action.target == nil)
        #expect(check.remediationActionKind == .restart)
    }

    /// A check's evidence is `{source_name, source_status}` and nothing else.
    /// The scope and the path of a legacy service unit are published by
    /// `setup.state.get` under `coexistence.legacy_service_unit`, which is
    /// where the app reads them: one fact in one place rather than two copies
    /// in two shapes.
    @Test("doctor evidence carries the source and its status, never a path or a scope")
    func doctorEvidenceIsTheSourceOnly() throws {
        let session: ManagementDoctorSession = try FakeDaemonGateway.fixtureResult(
            named: "doctor_get_in_progress",
            as: ManagementDoctorSession.self
        )

        #expect(!session.checks.isEmpty)
        for check in session.checks {
            #expect(Set(check.evidence.values.keys) == ["source_name", "source_status"])
        }
    }

    /// The router's own refusal, replayed from the compatibility fixtures: a
    /// v2-only method reaches an N-1 daemon as `method_not_found` naming the
    /// version it needs, which is what tells `restart onto the newer engine`
    /// apart from `no such method`.
    @Test("an N-1 daemon refuses a v2 method by naming the version it needs")
    func n1RouterRefusalCarriesItsRequirement() throws {
        var seen: Set<String> = []

        let contract = try ManagementContract.vendored()

        for fixture in try ManagementFixtures.load(.compatibility, from: .management)
        where (fixture.object["expect"] as? String) == "refused_by_router" {
            let method = try #require(ManagementMethod(rawValue: try fixture.string("method")))
            let requires = try #require(fixture.object["requires"] as? Int)

            #expect(ManagementErrorCode(wireValue: try fixture.string("error_code")) == .methodNotFound)
            // The app never has to learn this from the wire: the version the
            // daemon would name is the one its own contract publishes, so the
            // §7.1 gate refuses the call before a byte is written.
            #expect(contract.minimumVersion(for: method) == requires)
            #expect((fixture.object["frame"] as? [String: Any])?["protocol_version"] as? Int == 1)
            seen.insert(method.rawValue)
        }

        #expect(seen == ["settings.get", "plugins.list"])
    }

    // MARK: - The double

    /// The fixture gateway is what every surface is developed against, so the
    /// N-1 state has to be reachable there too, with the same refusal.
    @Test("the daemon double serves a v2 method, and refuses it at N-1")
    func doubleServesAndRefuses() async throws {
        let gateway = FakeDaemonGateway()
        // The double's default: a daemon that speaks what this build speaks.
        gateway.hello = try ManagementValueFixture.hello()

        let state = try await gateway.setupState()
        #expect(state.coexistence.configState == .clear)
        #expect(state.readiness.gating.count == 1)

        // Narrowed on purpose: this is the N-1 daemon. The window is dropped
        // with it, because the double caches the negotiated window exactly as
        // the shipping gateway does: a scripted `hello` change takes effect on
        // the next call only once something invalidates the old one (M34 §7.2).
        gateway.hello = try ManagementValueFixture.hello(minimum: 1, maximum: 1)
        await gateway.invalidateNegotiation()

        await #expect(
            throws: ManagementError.methodRequiresNewerEngine(
                method: .setupStateGet,
                required: 2,
                negotiated: 1
            )
        ) {
            _ = try await gateway.setupState()
        }
        #expect(gateway.calls.contains(.v2(.setupStateGet)))
    }

    // MARK: - Fixtures

    /// The negotiated window belongs to the daemon that answered `hello`, and a
    /// restart replaces that daemon. Until something drops it, every call is
    /// gated against the window of the engine that just exited: after an upgrade
    /// restart the panes kept saying `Restart to finish updating` against the
    /// newer engine that had come back (M34 §7.2).
    @Test("a gateway serves a v2 method once its stale window is invalidated")
    func invalidatingTheWindowLetsTheNewerEngineServe() async throws {
        let transport = try WindowedFixtureTransport(window: (minimum: 1, maximum: 1))
        let contract = try ManagementContract.vendored()
        let gateway = ManagementGateway {
            try ManagementTestClient.make(transport: transport, contract: contract)
        }

        _ = try await gateway.negotiate()
        await #expect(throws: ManagementError.self) { _ = try await gateway.setupState() }

        // The daemon that came back serves what this build speaks. The cached
        // window still says otherwise, so the call still refuses.
        transport.window = (minimum: 1, maximum: 2)
        await #expect(throws: ManagementError.self) { _ = try await gateway.setupState() }

        await gateway.invalidateNegotiation()
        let state = try await gateway.setupState()

        #expect(!state.providers.isEmpty)
    }

    private static func envelopes(
        window: (minimum: Int, maximum: Int)
    ) throws -> [String: [String: Any]] {
        var envelopes = try ManagementFixtures.successEnvelopesByMethod(from: .management)
        var hello = try #require(envelopes["hello"])
        var result = try #require(hello["result"] as? [String: Any])
        result["protocol"] = [
            "current_version": window.maximum,
            "minimum_version": window.minimum,
            "maximum_version": window.maximum
        ]
        hello["result"] = result
        envelopes["hello"] = hello

        return envelopes
    }

    private static func client(window: (minimum: Int, maximum: Int)) throws -> ManagementClient {
        try ManagementTestClient.make(
            transport: EchoingFixtureTransport(envelopes: try envelopes(window: window)),
            contract: try ManagementContract.vendored(),
            requestIdentifier: "req-negotiation-1"
        )
    }

    /// The methods an N-1 daemon still serves, read from the schema's own
    /// minimums rather than from a second artifact: there is one management
    /// schema now, and the v1 catalog is the part of it whose minimum is 1.
    private static func v1Catalog() -> Set<String> {
        guard let contract = try? ManagementContract.vendored() else { return [] }

        return Set(contract.minimumVersions.filter { $0.value == 1 }.keys)
    }

    private static func golden(_ name: String) throws -> [String: Any] {
        let fixtures = try ManagementFixtures.load(.success, from: .management)
        let record = try #require(fixtures.first { $0.name == name })

        return try #require(try record.object("response")["result"] as? [String: Any])
    }

    private static func decode<Value: Decodable>(_ object: Any?) throws -> Value {
        try JSONDecoder().decode(
            Value.self,
            from: try JSONSerialization.data(withJSONObject: try #require(object))
        )
    }

    /// The keys the vendored schema marks required at one path under `$defs`,
    /// so "this field is optional" is read from the artifact rather than
    /// asserted from memory.
    private static func requiredKeys(of definition: String, _ property: String? = nil) throws -> Set<String> {
        let document = try #require(
            try JSONSerialization.jsonObject(
                with: try VendoredContracts.data(.management, "protocol.schema.json")
            ) as? [String: Any]
        )
        let defs = try #require(document["$defs"] as? [String: Any])
        var node = try #require(defs[definition] as? [String: Any])
        if let property {
            let properties = try #require(node["properties"] as? [String: Any])
            node = try #require(properties[property] as? [String: Any])
        }

        return Set(node["required"] as? [String] ?? [])
    }
}

/// The golden answers, with a `hello` window a case can move between calls.
///
/// It is what an upgrade restart looks like from this side of the socket: the
/// same path, a different daemon behind it.
final class WindowedFixtureTransport: ManagementTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let envelopes: [String: [String: Any]]
    private var reported: (minimum: Int, maximum: Int)

    init(window: (minimum: Int, maximum: Int)) throws {
        envelopes = try ManagementFixtures.successEnvelopesByMethod(from: .management)
        reported = window
    }

    var window: (minimum: Int, maximum: Int) {
        get { lock.withLock { reported } }
        set { lock.withLock { reported = newValue } }
    }

    func exchange(_ payload: Data, timeout: Duration) async throws -> Data {
        let frame = try ManagementFixtures.decode(payload)
        guard let method = frame["method"] as? String,
              var envelope = envelopes[method],
              var result = envelope["result"] as? [String: Any] else {
            throw ManagementFixtureDefect.recordFieldMissing(
                name: frame["method"] as? String ?? "unknown",
                field: "result"
            )
        }

        if method == "hello" {
            let reported = window
            result["protocol"] = [
                "current_version": reported.maximum,
                "minimum_version": reported.minimum,
                "maximum_version": reported.maximum
            ]
            envelope["result"] = result
        }

        return try ManagementFixtures.encode([
            "request_id": frame["request_id"] as Any,
            "result": envelope["result"] as Any
        ])
    }
}
