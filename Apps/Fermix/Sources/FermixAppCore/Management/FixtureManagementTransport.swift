#if DEBUG
import Foundation

/// The management socket, replaced by the contract's own golden answers.
///
/// Only the socket is replaced. Every frame still goes through
/// `ManagementClient`: the same request encoding, the same negotiation gate, the
/// same correlation check and the same result decoding the shipped app uses. So
/// a surface rendered over this is rendered over the shapes the contract
/// publishes, not over a Swift literal somebody wrote to make a screenshot look
/// right.
///
/// The answers come from the vendored `management/` tree, which is the engine's
/// own export. Two facts are the home's rather than the contract's and are
/// declared as such: `hello.engine.pid`, which names the process that replied,
/// and the readiness this machine reports, which the engine publishes one of
/// and a fixture app needs three of (`FixtureReadiness`).
///
/// DEBUG only, by construction: a release build has no fixture answers to give.
struct FixtureManagementTransport: ManagementTransport {
    enum Defect: Error, Equatable {
        case recordIsNotAnObject(line: Int)
        case recordIsIncomplete(line: Int)
        /// Two golden records answer one method under the same request params,
        /// so which one it gives would be file order.
        case methodAnsweredTwice(method: String, records: [String])
        /// Every record for a method declared a selector and none of them
        /// matched the request. Loud, because the alternative is a pane that
        /// renders empty for a section the contract does publish.
        case noRecordMatches(method: String, params: [String: String])
        case requestIsNotAnObject
        case requestIsIncomplete
        /// The app called a method the contract publishes no success answer
        /// for. Loud, because a surface silently rendering nothing is exactly
        /// what the fixture configuration exists to make impossible.
        case methodHasNoAnswer(String)
        /// The golden `hello` has no engine block to carry a pid, so this home
        /// could not say which process answered.
        case helloCarriesNoEngine
        /// A golden this home reshapes is not the shape the contract publishes.
        case answerIsNotReshapable(method: String)
    }

    /// Every record a method publishes, in file order.
    private let records: [String: [Record]]
    /// The daemon behind the socket, which a lifecycle transaction replaces.
    private let machine: FixtureMachine
    /// The readiness this machine reports, which is the property that decides
    /// which screen the assistant draws at all.
    private let readiness: FixtureReadiness

    init(machine: FixtureMachine, readiness: FixtureReadiness) throws {
        self.machine = machine
        self.readiness = readiness
        records = try Self.loadRecords()
    }

    func exchange(_ payload: Data, timeout: Duration) async throws -> Data {
        guard let frame = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            throw Defect.requestIsNotAnObject
        }
        guard let method = frame["method"] as? String,
              let identifier = frame["request_id"] as? String
        else {
            throw Defect.requestIsIncomplete
        }
        guard let published = records[method] else {
            throw Defect.methodHasNoAnswer(method)
        }

        let result = try Self.resolve(
            published,
            method: method,
            params: frame["params"] as? [String: Any] ?? [:]
        )

        // The daemon commits the shutdown and then answers, in that order.
        if method == ManagementMethod.lifecycleCommit.rawValue {
            machine.shutdownCommitted()
        }
        let answered = try answer(method, result)

        return try Self.envelope(requestId: identifier, result: answered)
    }

    /// The golden answer, with this home's own two facts written into it.
    ///
    /// The pid is a fact about the process that replied rather than a shape the
    /// contract defines, and a restart is precisely the transaction that changes
    /// it. The readiness is the machine the home declares. Every other byte of
    /// every answer is the contract's own.
    private func answer(_ method: String, _ result: Data) throws -> Data {
        switch method {
        case ManagementMethod.hello.rawValue:
            return try helloWithLivePid(result)
        case ManagementMethod.setupStateGet.rawValue:
            return try reshape(result, method: method, with: readiness.setupState)
        case ManagementMethod.overviewGet.rawValue:
            return try reshape(result, method: method) { readiness.overview($0, setupState: setupState) }
        default:
            return result
        }
    }

    private func helloWithLivePid(_ result: Data) throws -> Data {
        guard var hello = try JSONSerialization.jsonObject(with: result) as? [String: Any],
              var engine = hello["engine"] as? [String: Any]
        else {
            throw Defect.helloCarriesNoEngine
        }

        engine["pid"] = String(machine.currentPid)
        hello["engine"] = engine

        return try JSONSerialization.data(withJSONObject: hello)
    }

    /// The golden `setup.state.get` this home reports, which is what the
    /// overview's readiness is derived from: one machine answers one readiness,
    /// and paired the other way Home drew `Running` beside `Continue setup`.
    private var setupState: [String: Any] {
        guard let published = records[ManagementMethod.setupStateGet.rawValue]?.first,
              let object = try? JSONSerialization.jsonObject(with: published.result) as? [String: Any]
        else { return [:] }

        return readiness.setupState(object)
    }

    private func reshape(
        _ result: Data,
        method: String,
        with body: ([String: Any]) -> [String: Any]
    ) throws -> Data {
        guard let object = try JSONSerialization.jsonObject(with: result) as? [String: Any] else {
            throw Defect.answerIsNotReshapable(method: method)
        }

        return try JSONSerialization.data(withJSONObject: body(object))
    }

    // MARK: - Loading

    /// Every published success answer, grouped by wire method name.
    private static func loadRecords() throws -> [String: [Record]] {
        let data = try VendoredContracts.data(.management, "fixtures/success.jsonl")
        let lines = String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)

        var grouped: [String: [Record]] = [:]
        for (index, line) in lines.enumerated() {
            let record = try read(line: line, number: index + 1)
            grouped[record.method, default: []].append(record)
        }

        return grouped
    }

    /// One golden record: its name, the method it answers, the request params it
    /// answers *for*, and the result.
    ///
    /// `selector` is what lets one method publish an answer per section, so
    /// `settings.get {section: "meetings"}` renders the meetings rows and not
    /// whichever section the file happened to list last.
    private struct Record {
        let name: String
        let method: String
        let selector: [String: String]
        let result: Data

        func answers(_ params: [String: Any]) -> Bool {
            selector.allSatisfy { key, value in params[key] as? String == value }
        }
    }

    private static func read(line: Substring, number: Int) throws -> Record {
        guard let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
            throw Defect.recordIsNotAnObject(line: number)
        }
        guard let name = object["name"] as? String,
              let method = object["method"] as? String,
              let response = object["response"] as? [String: Any],
              let result = response["result"]
        else {
            throw Defect.recordIsIncomplete(line: number)
        }

        return Record(
            name: name,
            method: method,
            selector: selector(method: method, result: result),
            result: try JSONSerialization.data(withJSONObject: result)
        )
    }

    /// The request params a record answers for, read from the answer itself.
    ///
    /// Two methods publish more than one golden, and each result names the
    /// request it answers under its own key: `settings.get` answers per section
    /// (`id` is the section), and `secret.set` answers per secret (`id` is the
    /// secret). Reading it off the answer keeps the selector and the answer one
    /// fact, so a re-vendor that adds a section or a secret needs nothing here.
    static func selector(method: String, result: Any) -> [String: String] {
        guard let identifier = (result as? [String: Any])?["id"] as? String else { return [:] }

        switch method {
        case ManagementMethod.settingsGet.rawValue:
            return ["section": identifier]
        case ManagementMethod.secretSet.rawValue:
            return ["id": identifier]
        default:
            return [:]
        }
    }

    /// Which record answers this request.
    ///
    /// The records whose selector matches the request come first; where more
    /// than one still stands, or none does, it refuses rather than answering
    /// with whichever the file listed last, which is a choice nobody made.
    private static func resolve(
        _ published: [Record],
        method: String,
        params: [String: Any]
    ) throws -> Data {
        let matching = published.filter { $0.answers(params) }
        guard let first = matching.first else {
            throw Defect.noRecordMatches(
                method: method,
                params: params.compactMapValues { $0 as? String }
            )
        }
        guard matching.count == 1 else {
            throw Defect.methodAnsweredTwice(method: method, records: matching.map(\.name))
        }

        return first.result
    }

    /// `{"request_id": <the id asked under>, "result": <the golden result>}`.
    ///
    /// Correlated with the id the client actually sent, so the client's
    /// correlation check is exercised rather than bypassed.
    private static func envelope(requestId: String, result: Data) throws -> Data {
        var payload = Data(#"{"request_id":"#.utf8)
        payload.append(try JSONEncoder().encode(requestId))
        payload.append(Data(#","result":"#.utf8))
        payload.append(result)
        payload.append(Data("}".utf8))

        return payload
    }
}

/// The readiness a fixture home reports, over the contract's own goldens.
///
/// The engine publishes one `setup.state.get` and one `overview.get`, and they
/// are the machine with one gating failure standing. Two of the three machines
/// the app has to be looked at on are not that one, so they are derived from it
/// — Ready by clearing what a passing machine has cleared, a first run by
/// emptying what it has not filled in yet — rather than by a second golden
/// nobody upstream maintains.
enum FixtureReadiness: Equatable {
    /// The machine the golden publishes: one gating failure and one advisory.
    case gatingFailure
    /// Every gate passed, which is the only machine Ready renders on.
    case ready
    /// A first run: no configured provider, no personalization, no channel.
    case fresh

    /// This machine's `setup.state.get`, from the golden.
    func setupState(_ golden: [String: Any]) -> [String: Any] {
        switch self {
        case .gatingFailure:
            return golden
        case .ready:
            var state = golden
            state["readiness"] = ["status": "ready", "failures": [[String: Any]]()]
            return state
        case .fresh:
            return Self.firstRun(golden)
        }
    }

    /// This machine's `overview.get`, whose readiness is derived from the
    /// `setup.state.get` above so the two can never disagree.
    func overview(_ golden: [String: Any], setupState: [String: Any]) -> [String: Any] {
        let failures = (setupState["readiness"] as? [String: Any])?["failures"] as? [Any] ?? []
        let status = (setupState["readiness"] as? [String: Any])?["status"] as? String

        var overview = golden
        overview["readiness"] = ["status": status as Any, "failure_count": failures.count]
        guard self == .fresh else { return overview }

        return Self.firstRunOverview(overview)
    }

    /// A machine nothing has been set up on, from the one the golden publishes.
    ///
    /// The readiness failures are the golden's own: a first run has no provider
    /// credentials and no configured channel, which is exactly what those two
    /// entries say. Everything else is emptied rather than rewritten, so no
    /// value here is one the contract does not already publish.
    private static func firstRun(_ golden: [String: Any]) -> [String: Any] {
        var state = golden
        state["providers"] = (golden["providers"] as? [[String: Any]] ?? []).map(unconfigured)
        state["channels"] = (golden["channels"] as? [[String: Any]] ?? []).map(silent)
        state["restart"] = ["required": false, "reasons": [[String: Any]]()]
        state["personalization"] = [
            "present": ["user_name": false, "timezone": false, "communication_style": false]
        ]
        state["features"] = [
            "voice": false,
            "voice_notes": false,
            "meetings": false,
            "computer_use": false,
            "computer_history": ["enabled": false, "installed": false, "ready": false]
        ]
        state["coexistence"] = [
            "legacy_service_unit": ["present": false, "scope": NSNull(), "path": NSNull()],
            "config_state": "clear",
            // Nothing has run Doctor on a machine this fresh, so the probe is
            // unmeasured rather than measured clear (PROTOCOL.md: null is not
            // false).
            "secret_acl_restricted": ["present": NSNull(), "keys": [String]()]
        ]

        return state
    }

    /// The same machine, as Home reads it: nothing is authenticated, nothing is
    /// answering, and nothing is waiting to be applied.
    private static func firstRunOverview(_ golden: [String: Any]) -> [String: Any] {
        var overview = golden
        var health = golden["health"] as? [String: Any] ?? [:]
        health["providers"] = [[String: Any]]()
        health["restart_required"] = false
        health["restart_reasons"] = [String]()
        overview["health"] = health
        overview["provider"] = [
            "active": NSNull(), "model": NSNull(),
            "auth_mode": NSNull(), "reasoning_effort": NSNull()
        ]
        overview["channels"] = [[String: Any]]()

        var realtime = golden["realtime"] as? [String: Any] ?? [:]
        realtime["enabled"] = false
        realtime["status"] = NSNull()
        realtime["provider"] = NSNull()
        realtime["model"] = NSNull()
        realtime["socket_alive"] = false
        realtime["active_sessions"] = 0
        realtime["active_clients"] = 0
        realtime["companion_connected"] = false
        overview["realtime"] = realtime

        return overview
    }

    private static func unconfigured(_ provider: [String: Any]) -> [String: Any] {
        var entry = provider
        entry["configured"] = false
        entry["primary"] = false
        entry["present_key"] = false
        entry["default_model"] = NSNull()
        entry["reasoning_effort"] = NSNull()
        entry["fast"] = NSNull()
        entry["account_label"] = NSNull()
        entry["token_state"] = NSNull()

        return entry
    }

    private static func silent(_ channel: [String: Any]) -> [String: Any] {
        var entry = channel
        entry["enabled"] = false
        entry["configured"] = false
        entry["status"] = NSNull()
        entry["mode"] = NSNull()

        return entry
    }
}
#endif
