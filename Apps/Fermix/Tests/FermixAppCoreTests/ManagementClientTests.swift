import Foundation
import Testing

@testable import FermixAppCore

/// The client is driven by the vendored golden fixtures — the same frames the
/// daemon is tested against. Every record in every fixture file is exercised,
/// and each suite asserts that the set of records it handled equals the set the
/// file contains, so an added fixture fails here instead of being ignored.
@Suite("ManagementClient requests")
struct ManagementClientRequestTests {
    /// Each golden request, mapped to the call that must produce it.
    private static let invocations: [String: @Sendable (ManagementClient) async throws -> Void] = [
        "hello": { _ = try await $0.hello() },
        "hello_without_params": { _ = try await $0.hello() },
        "overview_get": { _ = try await $0.overview() },
        "setup_session_create": { _ = try await $0.createSetupSession() },
        "doctor_start_default_scope": { _ = try await $0.startDoctor() },
        "doctor_start_network_scope": { _ = try await $0.startDoctor(scope: .network) },
        "doctor_get": { _ = try await $0.doctorSession(id: "doctor:9Fj2mQ7bT1xK") },
        "doctor_cancel": { _ = try await $0.cancelDoctorSession(id: "doctor:9Fj2mQ7bT1xK") },
        "logs_query_default_tail": { _ = try await $0.queryLogs(ManagementLogsQuery()) },
        "logs_query_filtered": {
            _ = try await $0.queryLogs(
                ManagementLogsQuery(
                    limit: 50,
                    level: .warning,
                    subsystem: "realtime",
                    search: "socket",
                    direction: .backward
                )
            )
        },
        "logs_query_next_page": {
            _ = try await $0.queryLogs(
                ManagementLogsQuery(
                    limit: 200,
                    direction: .backward,
                    cursor: "eyJhbmNob3IiOjIwMCwiZmluZ2VycHJpbnQiOjExODgxMjkxM30"
                )
            )
        },
        "lifecycle_prepare": { _ = try await $0.prepareLifecycle() },
        "lifecycle_commit": { _ = try await $0.commitLifecycle(leaseId: "lease_Qm5xR2t7Vd9pLk3A") },
        "lifecycle_cancel": { _ = try await $0.cancelLifecycle(leaseId: "lease_Qm5xR2t7Vd9pLk3A") },
        "diagnostics_build": { _ = try await $0.buildDiagnostics() }
    ]

    @Test("every golden request is exercised")
    func everyGoldenRequestIsExercised() throws {
        let published = Set(try ManagementFixtures.load(.requests).map(\.name))

        #expect(Set(Self.invocations.keys) == published)
    }

    @Test("each call emits the contract's golden frame")
    func callsEmitGoldenFrames() async throws {
        let envelopes = try ManagementFixtures.successEnvelopesByMethod()

        for fixture in try ManagementFixtures.load(.requests) {
            guard let invoke = Self.invocations[fixture.name] else { continue }

            var expected = try fixture.object("frame")
            let identifier = expected["request_id"] as? String ?? ""
            // A request-free method may omit `params` entirely; the client
            // always sends the empty object the schema defaults it to.
            if expected["params"] == nil { expected["params"] = [String: Any]() }

            let transport = EchoingFixtureTransport(envelopes: envelopes)
            let client = try ManagementTestClient.make(
                transport: transport,
                requestIdentifier: identifier
            )
            _ = try await client.hello()
            try await invoke(client)

            let emitted = try #require(transport.capturedFrames.last)
            #expect(
                ManagementFixtures.equal(emitted, expected),
                "\(fixture.name): emitted \(emitted) expected \(expected)"
            )
        }
    }

    @Test("a bounded parameter over its published limit is refused before sending")
    func outOfRangeParametersAreRefused() async throws {
        let transport = EchoingFixtureTransport(
            envelopes: try ManagementFixtures.successEnvelopesByMethod()
        )
        let client = try ManagementTestClient.make(transport: transport)
        _ = try await client.hello()

        await #expect(throws: ManagementError.invalidParameter(.outOfRange(field: "limit"))) {
            _ = try await client.queryLogs(ManagementLogsQuery(limit: 501))
        }
        await #expect(throws: ManagementError.invalidParameter(.outOfRange(field: "search"))) {
            _ = try await client.queryLogs(
                ManagementLogsQuery(search: String(repeating: "x", count: 257))
            )
        }
        await #expect(throws: ManagementError.invalidParameter(.outOfRange(field: "subsystem"))) {
            _ = try await client.queryLogs(
                ManagementLogsQuery(subsystem: String(repeating: "x", count: 65))
            )
        }
        await #expect(throws: ManagementError.invalidParameter(.empty(field: "session_id"))) {
            _ = try await client.doctorSession(id: "")
        }
        await #expect(throws: ManagementError.invalidParameter(.empty(field: "lease_id"))) {
            _ = try await client.commitLifecycle(leaseId: "")
        }
    }

    @Test("a request id outside the published pattern is refused, never truncated")
    func invalidRequestIdentifierIsRefused() async throws {
        let transport = EchoingFixtureTransport(
            envelopes: try ManagementFixtures.successEnvelopesByMethod()
        )
        let client = try ManagementTestClient.make(
            transport: transport,
            requestIdentifier: "-leading-dash"
        )

        await #expect(throws: ManagementError.invalidRequestIdentifier("-leading-dash")) {
            _ = try await client.hello()
        }
        #expect(transport.capturedFrames.isEmpty)
    }

    @Test("the generated request id fits the published pattern")
    func generatedIdentifiersAreValid() {
        let generator = UUIDRequestIdentifierGenerator()

        for method in ManagementMethod.allCases {
            let identifier = generator.nextIdentifier(for: method)
            #expect(ManagementRequestIdentifier.isValid(identifier), "\(identifier) is not valid")
            #expect(identifier.count <= 128)
        }
    }
}

@Suite("ManagementClient results")
struct ManagementClientResultTests {
    private static let leaseClock = Date(timeIntervalSince1970: 1_755_561_000)

    @Test("every golden success envelope is exercised")
    func everyGoldenSuccessIsExercised() throws {
        let published = Set(try ManagementFixtures.load(.success).map(\.name))

        #expect(published == Self.exercisedNames)
    }

    private static let exercisedNames: Set<String> = [
        "hello", "overview_get", "setup_session_create", "doctor_start",
        "doctor_get_in_progress", "doctor_cancel_terminal", "logs_query",
        "lifecycle_prepare", "lifecycle_commit", "lifecycle_cancel", "diagnostics_build"
    ]

    @Test("hello carries the version window, engine identity, and setup endpoint")
    func helloDecodes() async throws {
        let hello = try await Self.helloResult()

        #expect(hello.protocolRange.currentVersion == 1)
        #expect(hello.protocolRange.minimum == 1)
        #expect(hello.protocolRange.maximum == 1)
        #expect(hello.capabilities.methods.count == 11)
        #expect(hello.engine.engineId == "fermix-core")
        #expect(hello.engine.productVersion == "0.9.0")
        #expect(hello.engine.distributionIdentity == "macos_app")
        #expect(hello.engine.architecture == "arm64")
        #expect(hello.engine.pid == "47119")
        #expect(hello.setup.origin == "http://127.0.0.1:4030")
        #expect(hello.setup.path == "/setup")
    }

    @Test("overview decodes the whole typed projection")
    func overviewDecodes() async throws {
        let overview: ManagementOverview = try await Self.decode("overview_get") {
            try await $0.overview()
        }

        #expect(overview.readiness.status == "ready")
        #expect(overview.readiness.failureCount == 0)
        #expect(overview.health.providers.count == 2)
        #expect(overview.health.providers[0].name == "openai_codex")
        #expect(overview.health.providers[0].primary)
        #expect(overview.daemon.uptimeMs == 864_213)
        #expect(overview.daemon.pid == "47119")
        #expect(overview.provider.model == "gpt-5.6-sol")
        #expect(overview.channels.count == 1)
        #expect(overview.channels[0].name == "telegram")
        #expect(overview.channels[0].enabled)
        #expect(overview.memory.repo == "ready")
        #expect(overview.jobs.scheduled == 4)
        #expect(overview.jobs.next?.id == "job_7Kd2")
        #expect(overview.agents.main.health == "ok")
        #expect(overview.agents.skillWorkers == 3)
        #expect(overview.realtime.companionConnected)
        #expect(overview.capabilities.total == 62)
    }

    @Test("a setup session carries the one-use url and its absolute expiry")
    func setupSessionDecodes() async throws {
        let session: ManagementSetupSession = try await Self.decode("setup_session_create") {
            try await $0.createSetupSession()
        }

        #expect(session.url.contains("/setup?t="))
        #expect(session.expiresAtMs == 1_755_561_600_000)
        #expect(session.expiresAt == Date(timeIntervalSince1970: 1_755_561_600))
    }

    @Test("a started doctor session decodes with an empty check list")
    func doctorStartDecodes() async throws {
        let session: ManagementDoctorSession = try await Self.decode("doctor_start") {
            try await $0.startDoctor()
        }

        #expect(session.sessionId == "doctor:9Fj2mQ7bT1xK")
        #expect(session.scope == .local)
        #expect(session.status == .running)
        #expect(session.budgetMs == 10_000)
        #expect(session.total == 34)
        #expect(session.completedCount == 0)
        #expect(session.checks.isEmpty)
        #expect(session.finishedAt == nil)
    }

    @Test("an in-progress doctor session decodes its landed checks")
    func doctorGetDecodes() async throws {
        let session: ManagementDoctorSession = try await Self.decode("doctor_get_in_progress") {
            try await $0.doctorSession(id: "doctor:9Fj2mQ7bT1xK")
        }

        #expect(session.completedCount == 2)
        #expect(session.summary.passed == 1)
        #expect(session.summary.warning == 1)
        #expect(session.checks.count == 2)
        #expect(session.checks[0].id == "readiness")
        #expect(session.checks[0].status == .passed)
        #expect(session.checks[0].category == .runtime)
        #expect(session.checks[0].severity == .critical)
        #expect(session.checks[0].applicability == .always)
        #expect(session.checks[0].remediationCode == nil)
        #expect(session.checks[1].status == .warning)
        #expect(session.checks[1].remediationCode == "daemon_socket.warning")
        #expect(session.checks[1].evidence.values["source_status"] == .string("warn"))
    }

    @Test("a cancelled doctor session decodes as terminal")
    func doctorCancelDecodes() async throws {
        let session: ManagementDoctorSession = try await Self.decode("doctor_cancel_terminal") {
            try await $0.cancelDoctorSession(id: "doctor:T4pW8sN2yB6h")
        }

        #expect(session.scope == .network)
        #expect(session.status == .cancelled)
        #expect(session.budgetMs == 30_000)
        #expect(session.summary.cancelled == 3)
        #expect(session.finishedAt != nil)
        #expect(session.checks.count == 4)
    }

    @Test("a log page decodes entries, direction, and cursor")
    func logsQueryDecodes() async throws {
        let page: ManagementLogPage = try await Self.decode("logs_query") {
            try await $0.queryLogs(ManagementLogsQuery())
        }

        #expect(page.count == 2)
        #expect(page.truncated == false)
        #expect(page.direction == .backward)
        #expect(page.cursor == "eyJhbmNob3IiOjIwMCwiZmluZ2VycHJpbnQiOjExODgxMjkxM30")
        #expect(page.entries.count == 2)
        #expect(page.entries[0].level == .info)
        #expect(page.entries[0].subsystem == "realtime")
        #expect(page.entries[1].level == .warning)
        #expect(page.entries[1].subsystem == nil)
    }

    /// `ttl_ms` is relative on purpose (the daemon's timer is monotonic), so the
    /// client turns it into an absolute deadline against its own clock.
    @Test("a lifecycle lease resolves its relative ttl against the injected clock")
    func lifecyclePrepareDecodes() async throws {
        let lease: ManagementLifecycleLease = try await Self.decode("lifecycle_prepare") {
            try await $0.prepareLifecycle()
        }

        #expect(lease.leaseId == "lease_Qm5xR2t7Vd9pLk3A")
        #expect(lease.ttlMs == 30_000)
        #expect(lease.expiresAt == Self.leaseClock.addingTimeInterval(30))
    }

    @Test("a committed lifecycle transition decodes")
    func lifecycleCommitDecodes() async throws {
        let transition: ManagementLifecycleTransition = try await Self.decode("lifecycle_commit") {
            try await $0.commitLifecycle(leaseId: "lease_Qm5xR2t7Vd9pLk3A")
        }

        #expect(transition.leaseId == "lease_Qm5xR2t7Vd9pLk3A")
        #expect(transition.status == .committed)
    }

    @Test("a cancelled lifecycle transition decodes")
    func lifecycleCancelDecodes() async throws {
        let transition: ManagementLifecycleTransition = try await Self.decode("lifecycle_cancel") {
            try await $0.cancelLifecycle(leaseId: "lease_Qm5xR2t7Vd9pLk3A")
        }

        #expect(transition.status == .cancelled)
    }

    @Test("a diagnostics object decodes engine, doctor, and log sections")
    func diagnosticsDecodes() async throws {
        let report: ManagementDiagnostics = try await Self.decode("diagnostics_build") {
            try await $0.buildDiagnostics()
        }

        #expect(report.schemaVersion == 1)
        #expect(report.engine.architecture == "arm64")
        #expect(report.protocolRange.currentVersion == 1)
        #expect(report.service.state == "app_managed")
        #expect(report.service.scope == nil)
        #expect(report.doctor?.checks.count == 1)
        #expect(report.doctor?.checks.first?.category == .security)
        #expect(report.logs.count == 2)
        #expect(report.logs.entries.count == 2)
    }

    // MARK: - Fixture plumbing

    private static func helloResult() async throws -> ManagementHello {
        let fixture = try fixture(named: "hello")
        let envelope = try fixture.object("response")
        let identifier = envelope["request_id"] as? String ?? ""
        let transport = ScriptedManagementTransport(
            responses: [try ManagementFixtures.encode(envelope)]
        )
        let client = try ManagementTestClient.make(
            transport: transport,
            requestIdentifier: identifier,
            clock: leaseClock
        )
        return try await client.hello()
    }

    /// Answers `hello` with the golden hello envelope (re-keyed to this test's
    /// request id) and the call under test with the named golden envelope,
    /// untouched.
    private static func decode<Value>(
        _ name: String,
        _ call: (ManagementClient) async throws -> Value
    ) async throws -> Value {
        let envelope = try fixture(named: name).object("response")
        let identifier = envelope["request_id"] as? String ?? ""

        var hello = try fixture(named: "hello").object("response")
        hello["request_id"] = identifier

        let transport = ScriptedManagementTransport(responses: [
            try ManagementFixtures.encode(hello),
            try ManagementFixtures.encode(envelope)
        ])
        let client = try ManagementTestClient.make(
            transport: transport,
            requestIdentifier: identifier,
            clock: leaseClock
        )
        _ = try await client.hello()
        return try await call(client)
    }

    private static func fixture(named name: String) throws -> ManagementFixture {
        let all = try ManagementFixtures.load(.success)
        guard let match = all.first(where: { $0.name == name }) else {
            throw ManagementFixtureDefect.recordFieldMissing(name: name, field: "response")
        }
        return match
    }
}

@Suite("ManagementClient errors")
struct ManagementClientErrorTests {
    @Test("every published error code surfaces as a typed failure")
    func errorFixturesSurfaceTyped() async throws {
        let fixtures = try ManagementFixtures.load(.errors)
        #expect(fixtures.count == 14)

        for fixture in fixtures {
            let envelope = try fixture.object("response")
            let published = try fixture.object("response")["error"] as? [String: Any] ?? [:]
            let identifier = envelope["request_id"] as? String ?? "req-unmatched-1"

            let transport = ScriptedManagementTransport(
                responses: [try ManagementFixtures.encode(envelope)]
            )
            let client = try ManagementTestClient.make(
                transport: transport,
                requestIdentifier: identifier
            )

            do {
                _ = try await client.hello()
                Issue.record("\(fixture.name): expected a typed failure")
            } catch let error as ManagementError {
                guard case .daemon(let failure) = error else {
                    Issue.record("\(fixture.name): expected a daemon failure, got \(error)")
                    continue
                }
                #expect(failure.code.wireValue == (try fixture.string("code")))
                #expect(failure.message == published["message"] as? String)
                assertDetailsMatch(failure.details, published["details"] as? [String: Any] ?? [:],
                                   fixture: fixture.name)
            }
        }
    }

    /// The daemon answers with a null id only when the request was so malformed
    /// that no id could be recovered. That is a legitimate error envelope, not a
    /// correlation failure — reporting it as one would hide the real defect.
    @Test("an error with an unrecoverable request id is not a correlation failure")
    func unrecoverableIdentifierIsStillAnError() async throws {
        let envelope = try Self.errorFixture("invalid_request_unrecoverable_id").object("response")
        let transport = ScriptedManagementTransport(
            responses: [try ManagementFixtures.encode(envelope)]
        )
        let client = try ManagementTestClient.make(transport: transport)

        do {
            _ = try await client.hello()
            Issue.record("expected a daemon failure")
        } catch let error as ManagementError {
            guard case .daemon(let failure) = error else {
                Issue.record("expected a daemon failure, got \(error)")
                return
            }
            #expect(failure.code == .invalidRequest)
            #expect(failure.details.field == "request_id")
        }
    }

    @Test("a version refusal carries the daemon's supported window")
    func versionRefusalCarriesTheWindow() async throws {
        for name in ["client_too_old", "daemon_too_old"] {
            let envelope = try Self.errorFixture(name).object("response")
            let identifier = envelope["request_id"] as? String ?? ""
            let transport = ScriptedManagementTransport(
                responses: [try ManagementFixtures.encode(envelope)]
            )
            let client = try ManagementTestClient.make(
                transport: transport,
                requestIdentifier: identifier
            )

            do {
                _ = try await client.hello()
                Issue.record("\(name): expected a daemon failure")
            } catch let error as ManagementError {
                guard case .daemon(let failure) = error else {
                    Issue.record("\(name): expected a daemon failure, got \(error)")
                    continue
                }
                #expect(failure.details.minimumVersion == 1)
                #expect(failure.details.maximumVersion == 1)
            }
        }
    }

    @Test("an unpublished error code is preserved rather than mapped away")
    func unrecognisedCodeIsPreserved() async throws {
        let envelope: [String: Any] = [
            "request_id": "req-test-1",
            "error": ["code": "teapot", "message": "Not a published code.", "details": [:]]
        ]
        let transport = ScriptedManagementTransport(
            responses: [try ManagementFixtures.encode(envelope)]
        )
        let client = try ManagementTestClient.make(transport: transport)

        do {
            _ = try await client.hello()
            Issue.record("expected a daemon failure")
        } catch let error as ManagementError {
            #expect(error == .daemon(ManagementFailure(
                code: .unrecognized("teapot"),
                message: "Not a published code.",
                details: ManagementErrorDetails(values: [:])
            )))
        }
    }

    @Test("a mismatched request id is refused, not delivered")
    func correlationMismatchIsRefused() async throws {
        let envelope: [String: Any] = ["request_id": "req-other-1", "result": ["ok": true]]
        let transport = ScriptedManagementTransport(
            responses: [try ManagementFixtures.encode(envelope)]
        )
        let client = try ManagementTestClient.make(transport: transport, requestIdentifier: "req-mine-1")

        await #expect(
            throws: ManagementError.correlationMismatch(expected: "req-mine-1", received: "req-other-1")
        ) {
            _ = try await client.hello()
        }
    }

    @Test("an envelope carrying both a result and an error is malformed")
    func bothResultAndErrorIsMalformed() async throws {
        let envelope: [String: Any] = [
            "request_id": "req-test-1",
            "result": [:],
            "error": ["code": "busy", "message": "m", "details": [:]]
        ]
        let transport = ScriptedManagementTransport(
            responses: [try ManagementFixtures.encode(envelope)]
        )
        let client = try ManagementTestClient.make(transport: transport)

        await #expect(throws: ManagementError.malformedEnvelope(.resultAndErrorPresent)) {
            _ = try await client.hello()
        }
    }

    @Test("an envelope carrying neither a result nor an error is malformed")
    func neitherResultNorErrorIsMalformed() async throws {
        let transport = ScriptedManagementTransport(
            responses: [try ManagementFixtures.encode(["request_id": "req-test-1"])]
        )
        let client = try ManagementTestClient.make(transport: transport)

        await #expect(throws: ManagementError.malformedEnvelope(.neitherResultNorError)) {
            _ = try await client.hello()
        }
    }

    @Test("a response that is not a JSON object is malformed")
    func undecodableResponseIsMalformed() async throws {
        let transport = ScriptedManagementTransport(responses: [Data("not json".utf8)])
        let client = try ManagementTestClient.make(transport: transport)

        await #expect(throws: ManagementError.malformedEnvelope(.undecodableJSON)) {
            _ = try await client.hello()
        }
    }

    @Test("a result that does not match the method's shape names the field")
    func resultShapeMismatchNamesTheField() async throws {
        let envelope: [String: Any] = [
            "request_id": "req-test-1",
            "result": ["lease_id": "lease_A"]
        ]
        let transport = ScriptedManagementTransport(
            responses: [try ManagementFixtures.encode(envelope)]
        )
        let client = try ManagementTestClient.make(transport: transport)

        await #expect(
            throws: ManagementError.malformedEnvelope(
                .resultShapeMismatch(method: .hello, field: "protocol")
            )
        ) {
            _ = try await client.hello()
        }
    }

    private static func errorFixture(_ name: String) throws -> ManagementFixture {
        let all = try ManagementFixtures.load(.errors)
        guard let match = all.first(where: { $0.name == name }) else {
            throw ManagementFixtureDefect.recordFieldMissing(name: name, field: "response")
        }
        return match
    }

    private func assertDetailsMatch(
        _ details: ManagementErrorDetails,
        _ published: [String: Any],
        fixture: String
    ) {
        #expect(details.values.count == published.count, "\(fixture): detail count")
        for (key, value) in published {
            guard let scalar = details.values[key] else {
                Issue.record("\(fixture): missing detail \(key)")
                continue
            }
            #expect(scalar.matches(value), "\(fixture): detail \(key)")
        }
    }
}

@Suite("ManagementClient version negotiation")
struct ManagementClientNegotiationTests {
    @Test("every compatibility record is exercised")
    func everyCompatibilityRecordIsExercised() async throws {
        let envelopes = try ManagementFixtures.successEnvelopesByMethod()
        let transport = EchoingFixtureTransport(envelopes: envelopes)
        let client = try ManagementTestClient.make(transport: transport)
        _ = try await client.hello()
        let emitted = try #require(transport.capturedFrames.last)

        var handled = 0
        for fixture in try ManagementFixtures.load(.compatibility) {
            let expectation = try fixture.string("expect")
            switch expectation {
            case "v0", "invalid_v0":
                // A v0 frame carries neither marker. Everything the client
                // emits carries both, so it can never be classified as v0.
                let frame = fixture.object["frame"] as? [String: Any]
                #expect(frame?["request_id"] == nil, "\(fixture.name)")
                #expect(frame?["protocol_version"] == nil, "\(fixture.name)")
                #expect(emitted["request_id"] is String, "\(fixture.name)")
                #expect(emitted["protocol_version"] as? Int == 1, "\(fixture.name)")
            case "error":
                let code = ManagementErrorCode(wireValue: try fixture.string("error_code"))
                #expect(code.isPublished, "\(fixture.name): \(code.wireValue) is not published")
            default:
                Issue.record("\(fixture.name): unhandled expectation \(expectation)")
            }
            handled += 1
        }

        #expect(handled == (try ManagementFixtures.load(.compatibility).count))
    }

    /// The app declares v1 and never retries through v0, so both markers are on
    /// every frame it sends and the declared version is never 0.
    @Test("every emitted frame declares protocol version 1")
    func everyEmittedFrameDeclaresVersionOne() async throws {
        let envelopes = try ManagementFixtures.successEnvelopesByMethod()
        let transport = EchoingFixtureTransport(envelopes: envelopes)
        let client = try ManagementTestClient.make(transport: transport)

        _ = try await client.hello()
        _ = try await client.overview()
        _ = try await client.prepareLifecycle()

        #expect(transport.capturedFrames.count == 3)
        for frame in transport.capturedFrames {
            #expect(frame["protocol_version"] as? Int == 1)
            #expect(frame["request_id"] is String)
            #expect(frame["method"] is String)
        }
    }

    @Test("a call before hello is refused")
    func callBeforeHelloIsRefused() async throws {
        let transport = EchoingFixtureTransport(
            envelopes: try ManagementFixtures.successEnvelopesByMethod()
        )
        let client = try ManagementTestClient.make(transport: transport)

        await #expect(throws: ManagementError.notNegotiated(method: .overviewGet)) {
            _ = try await client.overview()
        }
        #expect(transport.capturedFrames.isEmpty)
    }

    /// hello is how the window is learned, so it answers; everything past it is
    /// refused while the daemon's window excludes the version the app speaks.
    @Test("a window that excludes the declared version refuses every call past hello")
    func windowMismatchRefusesPastHello() async throws {
        var hello = try Self.helloEnvelope()
        var result = hello["result"] as? [String: Any] ?? [:]
        result["protocol"] = ["current_version": 2, "minimum_version": 2, "maximum_version": 3]
        hello["result"] = result

        let transport = ScriptedManagementTransport(responses: [
            try ManagementFixtures.encode(hello)
        ])
        let client = try ManagementTestClient.make(
            transport: transport,
            requestIdentifier: hello["request_id"] as? String ?? ""
        )

        let negotiated = try await client.hello()
        #expect(negotiated.protocolRange.minimum == 2)

        await #expect(
            throws: ManagementError.unsupportedProtocolVersion(declared: 1, minimum: 2, maximum: 3)
        ) {
            _ = try await client.overview()
        }
        #expect(transport.sentPayloads.count == 1)
    }

    private static func helloEnvelope() throws -> [String: Any] {
        let fixtures = try ManagementFixtures.load(.success)
        guard let hello = fixtures.first(where: { $0.name == "hello" }) else {
            throw ManagementFixtureDefect.recordFieldMissing(name: "hello", field: "response")
        }
        return try hello.object("response")
    }
}

extension ManagementScalar {
    /// Compare a decoded scalar with the raw JSON value the fixture published.
    func matches(_ value: Any) -> Bool {
        switch self {
        case .string(let text):
            return (value as? String) == text
        case .integer(let number):
            return (value as? Int) == number
        case .double(let number):
            return (value as? Double) == number
        case .boolean(let flag):
            return (value as? Bool) == flag
        case .null:
            return value is NSNull
        }
    }
}
