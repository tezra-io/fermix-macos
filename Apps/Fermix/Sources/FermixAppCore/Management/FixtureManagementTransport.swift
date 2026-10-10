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
        records = try Self.loadRecords(phoneMoment: machine.phoneChannel.moment)
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
        let params = frame["params"] as? [String: Any] ?? [:]
        if method == ManagementMethod.settingsApply.rawValue, let on = Self.phoneSwitch(in: params) {
            machine.switchPhone(on)
            return try Self.envelope(requestId: identifier, result: try phoneSwitchApplied(params))
        }
        guard let published = candidates(for: method) else {
            throw Defect.methodHasNoAnswer(method)
        }

        let result = try Self.resolve(
            published,
            method: method,
            params: Self.selectable(method: method, params: params)
        )

        // The daemon commits the shutdown and then answers, in that order.
        if method == ManagementMethod.lifecycleCommit.rawValue {
            machine.shutdownCommitted()
        }
        let answered = try answer(method, result)

        return try Self.envelope(requestId: identifier, result: answered)
    }

    /// The records a request is answered from.
    ///
    /// `mobile.pair.start` publishes the window opened and the refusal with the
    /// channel off, for the same request: a running phone channel answers the
    /// first, and a channel that is not running the second.
    private func candidates(for method: String) -> [Record]? {
        guard method == ManagementMethod.mobilePairStart.rawValue else { return records[method] }

        let running = machine.phoneChannel.running
        return records[method]?.filter { ($0.moment?.sessionId != nil) == running }
    }

    /// The phone channel's switch, where a write sets it.
    private static func phoneSwitch(in params: [String: Any]) -> Bool? {
        guard params["section"] as? String == PhoneChannel.section,
              let values = params["values"] as? [String: Any]
        else { return nil }

        return values[PhoneChannel.switchKey] as? Bool
    }

    /// The write that throws the phone channel's switch, answered as the
    /// contract's own `settings.apply` golden answers a boot-bound write: the
    /// keys it applied, and the restart the home already reports. The golden
    /// publishes no write of this section, and Turn on is looked at through
    /// this one.
    private func phoneSwitchApplied(_ params: [String: Any]) throws -> Data {
        let method = ManagementMethod.settingsApply.rawValue
        guard let golden = records[method]?.first(where: { $0.name == Self.bootBoundWrite }) else {
            throw Defect.methodHasNoAnswer(method)
        }

        let keys = ((params["values"] as? [String: Any]) ?? [:]).keys.sorted()
        return try reshape(golden.result, method: method) { applied in
            var answer = applied
            answer["applied"] = keys
            return answer
        }
    }

    /// The golden write whose rows need a restart.
    private static let bootBoundWrite = "settings_apply"

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
            return try reshape(result, method: method) { phone.withChannel(readiness.setupState($0)) }
        case ManagementMethod.overviewGet.rawValue:
            return try reshape(result, method: method) { readiness.overview($0, setupState: setupState) }
        case ManagementMethod.mobileStatus.rawValue:
            return try reshape(result, method: method, with: phone.status)
        default:
            return result
        }
    }

    /// The machine's phone channel, as the answers that speak of it read it.
    private var phone: FixturePhoneAnswers {
        FixturePhoneAnswers(channel: machine.phoneChannel)
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
    private static func loadRecords(phoneMoment: String?) throws -> [String: [Record]] {
        let data = try VendoredContracts.data(.management, "fixtures/success.jsonl")
        let lines = String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)

        var grouped: [String: [Record]] = [:]
        for (index, line) in lines.enumerated() {
            let record = try read(line: line, number: index + 1)
            grouped[record.method, default: []].append(record)
        }

        return atVoiceEngine(atPhoneMoment(grouped, declared: phoneMoment))
    }

    /// The voice engine this daemon runs.
    ///
    /// `settings.get {section: "realtime"}` publishes one golden per engine,
    /// every one for the same request, because the section's rows are scoped
    /// to the engine its model implies (PROTOCOL.md), so no selector tells them
    /// apart. A daemon runs one engine, and `overview.get` names it under
    /// `realtime.engine`; the voice section published under that engine is
    /// this machine's answer, and the other is another machine's. An overview
    /// that names no engine leaves the records as published, and `resolve` says
    /// so.
    private static func atVoiceEngine(_ grouped: [String: [Record]]) -> [String: [Record]] {
        guard let live = grouped[ManagementMethod.overviewGet.rawValue]?.first?.liveVoice else { return grouped }

        var records = grouped
        records[ManagementMethod.settingsGet.rawValue] = grouped[ManagementMethod.settingsGet.rawValue]?
            .filter { $0.liveVoice == nil || $0.liveVoice == live }

        return records
    }

    /// The moment this daemon answers from.
    ///
    /// `mobile.pair.get` publishes one golden per session state, every one for
    /// the same request, so no selector tells them apart: they are moments of
    /// one session, not answers to different questions. A daemon answers from
    /// one moment, and `mobile.status` names it under `pairing`: the session,
    /// in the state it is in. The read that shows that session in that state
    /// is this machine's answer; the other records are other moments. A
    /// machine may declare its own moment of the same session, which is how
    /// the Phone sheet is looked at on each of its steps. A status that names
    /// no session leaves the records as published, and `resolve` says so.
    ///
    /// `mobile.pair.start`'s two records are kept: which one answers is
    /// whether the channel runs, which a restart changes (`candidates`).
    private static func atPhoneMoment(_ grouped: [String: [Record]], declared: String?) -> [String: [Record]] {
        guard let published = grouped[ManagementMethod.mobileStatus.rawValue]?.first?.moment else { return grouped }

        let moment = PairingMoment(sessionId: published.sessionId, state: declared ?? published.state)
        var records = grouped
        records[ManagementMethod.mobilePairGet.rawValue] = grouped[ManagementMethod.mobilePairGet.rawValue]?
            .filter { $0.moment == moment }

        return records
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
        /// The pairing session this answer is a moment of, where it is one.
        let moment: PairingMoment?
        /// Whether this answer speaks of the Live voice engine, where it names
        /// an engine at all.
        let liveVoice: Bool?
        let result: Data

        func answers(_ params: [String: Any]) -> Bool {
            selector.allSatisfy { key, value in params[key] as? String == value }
        }
    }

    /// A pairing session's id and state: the two facts that place one golden
    /// among the others published for the same request.
    private struct PairingMoment: Equatable {
        let sessionId: String?
        let state: String
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
            moment: pairingMoment(method: method, result: result),
            liveVoice: liveVoice(method: method, result: result),
            result: try JSONSerialization.data(withJSONObject: result)
        )
    }

    /// Whether an answer speaks of the Live voice engine: `overview.get` names
    /// the engine under `realtime.engine`, and the voice section is Live's
    /// exactly when it carries `realtime_backend`, the row PROTOCOL.md publishes
    /// only under Live. Nil for every other answer, and for an overview whose
    /// voice is off.
    private static func liveVoice(method: String, result: Any) -> Bool? {
        guard let object = result as? [String: Any] else { return nil }

        switch method {
        case ManagementMethod.overviewGet.rawValue:
            let engine = (object["realtime"] as? [String: Any])?["engine"] as? String
            return engine.map { $0 == Self.liveEngine }
        case ManagementMethod.settingsGet.rawValue where object["id"] as? String == Self.voiceSection:
            let rows = object["rows"] as? [[String: Any]] ?? []
            return rows.contains { $0["key"] as? String == Self.liveOnlyRow }
        default:
            return nil
        }
    }

    /// The wire names `liveVoice` reads, each as PROTOCOL.md publishes it.
    private static let voiceSection = "realtime"
    private static let liveEngine = "openai_live"
    private static let liveOnlyRow = "realtime_backend"

    /// The pairing session an answer speaks of: `mobile.status` under
    /// `pairing`, a start or a read as the whole result. Nil for every other
    /// method, and for a status with no session.
    private static func pairingMoment(method: String, result: Any) -> PairingMoment? {
        guard let object = result as? [String: Any] else { return nil }

        let session: [String: Any]?
        switch method {
        case ManagementMethod.mobileStatus.rawValue:
            session = object["pairing"] as? [String: Any]
        case ManagementMethod.mobilePairStart.rawValue, ManagementMethod.mobilePairGet.rawValue:
            session = object
        default:
            return nil
        }
        guard let session, let state = session["state"] as? String else { return nil }

        return PairingMoment(sessionId: session["session_id"] as? String, state: state)
    }

    /// The request params a record answers for, read from the answer itself.
    ///
    /// Five methods publish more than one golden, and each result names the
    /// request it answers under its own key: `settings.get` answers per section
    /// (`id` is the section), and `secret.set` and `secret.clear` answer per
    /// secret (`id` is the secret). Reading it off the answer keeps the selector
    /// and the answer one fact, so a re-vendor that adds a section or a secret
    /// needs nothing here. A method that publishes its second golden does: it
    /// joins this switch, which is what `secret.clear` did when the sandbox
    /// environment family gave it one.
    static func selector(method: String, result: Any) -> [String: String] {
        let object = result as? [String: Any]
        // `settings.apply` answers per key it changed: its answer lists them
        // under `applied`, and the request names them under `values`.
        if method == ManagementMethod.settingsApply.rawValue {
            guard let applied = (object?["applied"] as? [String])?.sorted().first else { return [:] }
            return ["applied": applied]
        }
        // `job.get` answers per job: its answer names the job under `job_id`.
        if method == ManagementMethod.jobGet.rawValue {
            guard let job = object?["job_id"] as? String else { return [:] }
            return ["job_id": job]
        }
        guard let identifier = object?["id"] as? String else { return [:] }

        switch method {
        case ManagementMethod.settingsGet.rawValue:
            return ["section": identifier]
        case ManagementMethod.secretSet.rawValue, ManagementMethod.secretClear.rawValue:
            return ["id": identifier]
        default:
            return [:]
        }
    }

    /// The request params as a record's selector reads them: `settings.apply`
    /// names the first key it changes under `applied`, the way its answer does.
    private static func selectable(method: String, params: [String: Any]) -> [String: Any] {
        guard method == ManagementMethod.settingsApply.rawValue,
              let values = params["values"] as? [String: Any],
              let first = values.keys.sorted().first
        else { return params }
        var selectable = params
        selectable["applied"] = first
        return selectable
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

/// The answers that speak of the phone channel, over the contract's own
/// goldens (M60).
///
/// The goldens are a running channel with one phone paired and a window
/// waiting for a decision. The machine's channel may be switched off, waiting
/// for the restart its switch asks for, or in another moment of that window,
/// and these say so in the fields that report it, leaving every other byte
/// the contract's.
struct FixturePhoneAnswers {
    let channel: FixturePhoneChannel

    /// `mobile.status`: the switch, whether the channel runs, and the window,
    /// in the moment the machine is in. A channel that is not running pairs
    /// nobody and has no window.
    func status(_ golden: [String: Any]) -> [String: Any] {
        var status = golden
        status["enabled"] = channel.switchedOn
        status["started"] = channel.running
        if !channel.running {
            status["paired_devices"] = 0
            status["pairing"] = NSNull()
        } else if let moment = channel.moment, var pairing = golden["pairing"] as? [String: Any] {
            pairing["state"] = moment
            status["pairing"] = pairing
        }

        return status
    }

    /// `setup.state.get` with the phone channel's row after the inventory
    /// channels, as PROTOCOL.md publishes it and the golden predates: always
    /// configured, `ok` and `listener` while it is on, nothing while it is off.
    func withChannel(_ state: [String: Any]) -> [String: Any] {
        let on = channel.switchedOn
        let row: [String: Any] = [
            "name": PhoneChannel.name,
            "enabled": on,
            "configured": true,
            "status": on ? "ok" : NSNull(),
            "mode": on ? "listener" : NSNull()
        ]
        var reshaped = state
        reshaped["channels"] = (state["channels"] as? [[String: Any]] ?? []) + [row]

        return reshaped
    }
}

/// The readiness a fixture home reports, over the contract's own goldens.
///
/// The engine publishes one `setup.state.get` and one `overview.get`, and since
/// its first boot began seeding personalization (2026-09-27) they are a ready
/// home with two advisory rows. None of the three machines the app has to be
/// looked at on is that one, so each is derived from it — the gate a surface is
/// looked at through by withdrawing the primary provider's credential, Ready by
/// clearing the advisory rows, a first run by emptying what it has not filled
/// in yet — rather than by a second golden nobody upstream maintains.
enum FixtureReadiness: Equatable {
    /// The golden's home with its primary provider's credential withdrawn: one
    /// gating failure, the provider, beside the golden's two advisory rows.
    case gatingFailure
    /// Every gate passed, which is the only machine Ready renders on.
    case ready
    /// A first run: no configured provider and no channel. Personalization is
    /// present, because the daemon's first boot seeds it before any screen.
    case fresh

    /// This machine's `setup.state.get`, from the golden.
    func setupState(_ golden: [String: Any]) -> [String: Any] {
        switch self {
        case .gatingFailure:
            return Self.providerGate(golden)
        case .ready:
            var state = golden
            state["readiness"] = ["status": "ready", "failures": [[String: Any]]()]
            return state
        case .fresh:
            return Self.firstRun(golden)
        }
    }

    /// The golden's primary provider, which every derived machine gates on.
    private static func primaryProvider(_ golden: [String: Any]) -> String {
        let providers = golden["providers"] as? [[String: Any]] ?? []
        guard let primary = providers.first(where: { $0["primary"] as? Bool == true }),
              let id = primary["id"] as? String
        else { preconditionFailure("the setup.state.get golden names no primary provider") }

        return id
    }

    /// Readiness gated on the primary: the row the daemon publishes for a primary
    /// whose credential is missing, ahead of whatever advisory rows the machine
    /// keeps.
    private static func gated(primary: String, advisory: [[String: Any]]) -> [String: Any] {
        let failure: [String: Any] = [
            "component": "provider:\(primary)",
            "gating": true,
            "pane": "providers",
            "detail_key": "provider:missing_credentials:\(primary)"
        ]

        return ["status": "setup_required", "failures": [failure] + advisory]
    }

    /// The golden's home with the primary's credential withdrawn: still the
    /// primary, with nothing to answer with.
    private static func providerGate(_ golden: [String: Any]) -> [String: Any] {
        let primary = primaryProvider(golden)
        let advisory = ((golden["readiness"] as? [String: Any])?["failures"] as? [[String: Any]] ?? [])
            .filter { $0["gating"] as? Bool == false }
        var state = golden
        state["providers"] = (golden["providers"] as? [[String: Any]] ?? []).map { provider in
            provider["id"] as? String == primary ? unauthenticated(provider) : provider
        }
        state["readiness"] = gated(primary: primary, advisory: advisory)

        return state
    }

    private static func unauthenticated(_ provider: [String: Any]) -> [String: Any] {
        var entry = provider
        entry["configured"] = false
        entry["present_key"] = false
        entry["account_label"] = NSNull()
        entry["token_state"] = NSNull()

        return entry
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
    /// The one readiness failure is the provider gate: a first run has no
    /// provider credential and, with every channel silenced, nothing else to
    /// report. Personalization is present, because the daemon's first boot seeds
    /// it from the machine. Everything else is emptied rather than rewritten, so
    /// no value here is one the contract does not already publish.
    private static func firstRun(_ golden: [String: Any]) -> [String: Any] {
        var state = golden
        state["providers"] = (golden["providers"] as? [[String: Any]] ?? []).map(unconfigured)
        state["channels"] = (golden["channels"] as? [[String: Any]] ?? []).map(silent)
        state["readiness"] = gated(primary: primaryProvider(golden), advisory: [])
        state["restart"] = ["required": false, "reasons": [[String: Any]]()]
        state["personalization"] = [
            "present": ["user_name": true, "timezone": true, "communication_style": true]
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
        realtime["engine"] = NSNull()
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
