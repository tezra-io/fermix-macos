import Foundation

/// The `cues.*` calls (M60 app surface §3.3): what each sends, the client's
/// one line over `send` per method, and the gateway's negotiated delegate.
///
/// Every cue method is minimum version 2 and arrived inside protocol 2, so a
/// surface finds them in `hello.capabilities.methods` before it draws
/// anything that calls one (`DaemonQuerying.servedMethods`).

// MARK: - What a write sends

/// One value a cue form sends: a settings row's value, or a mandate's pinned
/// arguments, which no settings row carries.
public enum ManagementCueValue: Encodable, Equatable, Sendable {
    case setting(ManagementSettingValue)
    case pins([ManagementCuePin])

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .setting(let value): try value.encode(to: encoder)
        case .pins(let pins): try pins.encode(to: encoder)
        }
    }
}

/// What a new source is made from: a kind, or a preset that names its kind.
public enum ManagementCueSourceChoice: Equatable, Sendable {
    case kind(String)
    case preset(String)
}

/// `cues.sources.add`: the name, the kind or the preset, and the values the
/// owner set. A secret is never among them: each one is its own
/// `secret.set`, once the source exists.
public struct ManagementCueSourceSpec: Encodable, Equatable, Sendable {
    public let ref: String
    public let kind: String?
    public let preset: String?
    public let values: [String: ManagementCueValue]

    public init(ref: String, choice: ManagementCueSourceChoice, values: [String: ManagementCueValue]) {
        precondition(!ref.isEmpty, "a source is added by name")
        self.ref = ref
        self.values = values
        switch choice {
        case .kind(let kind):
            self.kind = kind
            preset = nil
        case .preset(let preset):
            kind = nil
            self.preset = preset
        }
    }
}

/// The choice `cues.sources.form` answers for. Every field is optional: with
/// none, the form is a feed's.
public struct ManagementCueFormRequest: Encodable, Equatable, Sendable {
    public let kind: String?
    public let preset: String?
    public let verify: String?

    public init(kind: String? = nil, preset: String? = nil, verify: String? = nil) {
        self.kind = kind
        self.preset = preset
        self.verify = verify
    }
}

struct ManagementCueRefParams: Encodable {
    let ref: String
}

struct ManagementCueNameParams: Encodable {
    let name: String
}

struct ManagementCueValuesParams: Encodable {
    let ref: String
    let values: [String: ManagementCueValue]
}

struct ManagementCueMandateParams: Encodable {
    let name: String
    let values: [String: ManagementCueValue]
}

struct ManagementCueProposalListParams: Encodable {
    /// Omitted for the waiting proposals, the daemon's default.
    let state: ManagementCueProposalFilter?
}

struct ManagementCueProposalParams: Encodable {
    let proposalId: String

    private enum CodingKeys: String, CodingKey {
        case proposalId = "proposal_id"
    }
}

struct ManagementCueDecisionParams: Encodable {
    let proposalId: String
    let decision: ManagementCueDecision

    private enum CodingKeys: String, CodingKey {
        case decision
        case proposalId = "proposal_id"
    }
}

// MARK: - The client

extension ManagementClient {
    public func cuesStatus() async throws -> ManagementCueStatus {
        try await send(.cuesStatus, params: ManagementEmptyParams(), as: ManagementCueStatus.self)
    }

    public func cueSources() async throws -> ManagementCueSourceList {
        try await send(.cuesSourcesList, params: ManagementEmptyParams(), as: ManagementCueSourceList.self)
    }

    public func cueSource(ref: String) async throws -> ManagementCueSourceDetail {
        try await send(.cuesSourcesGet, params: try refParams(ref), as: ManagementCueSourceDetail.self)
    }

    public func cueSourceForm(_ request: ManagementCueFormRequest) async throws -> ManagementCueSourceForm {
        try await send(.cuesSourcesForm, params: request, as: ManagementCueSourceForm.self)
    }

    public func addCueSource(_ spec: ManagementCueSourceSpec) async throws -> ManagementCueSourceAdded {
        _ = try requireText(spec.ref, field: "ref")

        return try await send(.cuesSourcesAdd, params: spec, as: ManagementCueSourceAdded.self)
    }

    /// Changes the fields named. A change that names none is refused here
    /// rather than sent, because a write with nothing to write is a caller
    /// defect.
    public func updateCueSource(ref: String, values: [String: ManagementCueValue]) async throws -> ManagementCueSourceAnswer {
        guard !values.isEmpty else { throw ManagementError.invalidParameter(.empty(field: "values")) }

        return try await send(
            .cuesSourcesUpdate,
            params: ManagementCueValuesParams(ref: try requireText(ref, field: "ref"), values: values),
            as: ManagementCueSourceAnswer.self
        )
    }

    public func removeCueSource(ref: String) async throws -> ManagementCueSourceRemoved {
        try await send(.cuesSourcesRemove, params: try refParams(ref), as: ManagementCueSourceRemoved.self)
    }

    public func enableCueSource(ref: String) async throws -> ManagementCueSourceAnswer {
        try await send(.cuesSourcesEnable, params: try refParams(ref), as: ManagementCueSourceAnswer.self)
    }

    public func disableCueSource(ref: String) async throws -> ManagementCueSourceAnswer {
        try await send(.cuesSourcesDisable, params: try refParams(ref), as: ManagementCueSourceAnswer.self)
    }

    public func newCueSourceToken(ref: String) async throws -> ManagementCueSourceToken {
        try await send(.cuesSourcesTokenNew, params: try refParams(ref), as: ManagementCueSourceToken.self)
    }

    public func cueSourceAddress(ref: String) async throws -> ManagementCueSourceAddress {
        try await send(.cuesSourcesURLGet, params: try refParams(ref), as: ManagementCueSourceAddress.self)
    }

    public func cueWatchers() async throws -> ManagementCueWatcherList {
        try await send(.cuesWatchersList, params: ManagementEmptyParams(), as: ManagementCueWatcherList.self)
    }

    public func cueWatcher(name: String) async throws -> ManagementCueWatcherAnswer {
        try await send(.cuesWatchersGet, params: try nameParams(name), as: ManagementCueWatcherAnswer.self)
    }

    public func cueMandates() async throws -> ManagementCueMandateList {
        try await send(.cuesMandatesList, params: ManagementEmptyParams(), as: ManagementCueMandateList.self)
    }

    public func cueMandateChoices() async throws -> ManagementCueMandateChoices {
        try await send(.cuesMandatesChoices, params: ManagementEmptyParams(), as: ManagementCueMandateChoices.self)
    }

    public func addCueMandate(name: String, values: [String: ManagementCueValue]) async throws -> ManagementCueMandateAnswer {
        try await send(
            .cuesMandatesAdd,
            params: ManagementCueMandateParams(name: try requireText(name, field: "name"), values: values),
            as: ManagementCueMandateAnswer.self
        )
    }

    public func updateCueMandate(name: String, values: [String: ManagementCueValue]) async throws -> ManagementCueMandateAnswer {
        guard !values.isEmpty else { throw ManagementError.invalidParameter(.empty(field: "values")) }

        return try await send(
            .cuesMandatesUpdate,
            params: ManagementCueMandateParams(name: try requireText(name, field: "name"), values: values),
            as: ManagementCueMandateAnswer.self
        )
    }

    public func removeCueMandate(name: String) async throws -> ManagementCueMandateRemoved {
        try await send(.cuesMandatesRemove, params: try nameParams(name), as: ManagementCueMandateRemoved.self)
    }

    public func enableCueMandate(name: String) async throws -> ManagementCueMandateAnswer {
        try await send(.cuesMandatesEnable, params: try nameParams(name), as: ManagementCueMandateAnswer.self)
    }

    public func disableCueMandate(name: String) async throws -> ManagementCueMandateAnswer {
        try await send(.cuesMandatesDisable, params: try nameParams(name), as: ManagementCueMandateAnswer.self)
    }

    public func approveCueMandate(name: String) async throws -> ManagementCueMandateAnswer {
        try await send(.cuesMandatesApprove, params: try nameParams(name), as: ManagementCueMandateAnswer.self)
    }

    /// The waiting proposals, or the last seven days. The waiting ones are
    /// the daemon's default, so asking for them sends no `state`.
    public func cueProposals(_ filter: ManagementCueProposalFilter) async throws -> ManagementCueProposalList {
        try await send(
            .cuesProposalsList,
            params: ManagementCueProposalListParams(state: filter == .waiting ? nil : filter),
            as: ManagementCueProposalList.self
        )
    }

    public func cueProposal(id: String) async throws -> ManagementCueProposalCardAnswer {
        try await send(
            .cuesProposalsGet,
            params: ManagementCueProposalParams(proposalId: try requireText(id, field: "proposal_id")),
            as: ManagementCueProposalCardAnswer.self
        )
    }

    /// The owner's answer, by id and word alone: never an argument, never a
    /// token, never a value edited here.
    public func decideCueProposal(id: String, decision: ManagementCueDecision) async throws -> ManagementCueProposalAnswer {
        guard decision.isPublished else { throw ManagementError.invalidParameter(.outOfRange(field: "decision")) }

        return try await send(
            .cuesProposalsDecide,
            params: ManagementCueDecisionParams(proposalId: try requireText(id, field: "proposal_id"), decision: decision),
            as: ManagementCueProposalAnswer.self
        )
    }

    private func refParams(_ ref: String) throws -> ManagementCueRefParams {
        ManagementCueRefParams(ref: try requireText(ref, field: "ref"))
    }

    private func nameParams(_ name: String) throws -> ManagementCueNameParams {
        ManagementCueNameParams(name: try requireText(name, field: "name"))
    }
}

// MARK: - The gateway

extension ManagementGateway {
    public func cuesStatus() async throws -> ManagementCueStatus {
        try await negotiated().cuesStatus()
    }

    public func cueSources() async throws -> ManagementCueSourceList {
        try await negotiated().cueSources()
    }

    public func cueSource(ref: String) async throws -> ManagementCueSourceDetail {
        try await negotiated().cueSource(ref: ref)
    }

    public func cueSourceForm(_ request: ManagementCueFormRequest) async throws -> ManagementCueSourceForm {
        try await negotiated().cueSourceForm(request)
    }

    public func addCueSource(_ spec: ManagementCueSourceSpec) async throws -> ManagementCueSourceAdded {
        try await negotiated().addCueSource(spec)
    }

    public func updateCueSource(ref: String, values: [String: ManagementCueValue]) async throws -> ManagementCueSourceAnswer {
        try await negotiated().updateCueSource(ref: ref, values: values)
    }

    public func removeCueSource(ref: String) async throws -> ManagementCueSourceRemoved {
        try await negotiated().removeCueSource(ref: ref)
    }

    public func enableCueSource(ref: String) async throws -> ManagementCueSourceAnswer {
        try await negotiated().enableCueSource(ref: ref)
    }

    public func disableCueSource(ref: String) async throws -> ManagementCueSourceAnswer {
        try await negotiated().disableCueSource(ref: ref)
    }

    public func newCueSourceToken(ref: String) async throws -> ManagementCueSourceToken {
        try await negotiated().newCueSourceToken(ref: ref)
    }

    public func cueSourceAddress(ref: String) async throws -> ManagementCueSourceAddress {
        try await negotiated().cueSourceAddress(ref: ref)
    }

    public func cueWatchers() async throws -> ManagementCueWatcherList {
        try await negotiated().cueWatchers()
    }

    public func cueWatcher(name: String) async throws -> ManagementCueWatcherAnswer {
        try await negotiated().cueWatcher(name: name)
    }

    public func cueMandates() async throws -> ManagementCueMandateList {
        try await negotiated().cueMandates()
    }

    public func cueMandateChoices() async throws -> ManagementCueMandateChoices {
        try await negotiated().cueMandateChoices()
    }

    public func addCueMandate(name: String, values: [String: ManagementCueValue]) async throws -> ManagementCueMandateAnswer {
        try await negotiated().addCueMandate(name: name, values: values)
    }

    public func updateCueMandate(name: String, values: [String: ManagementCueValue]) async throws -> ManagementCueMandateAnswer {
        try await negotiated().updateCueMandate(name: name, values: values)
    }

    public func removeCueMandate(name: String) async throws -> ManagementCueMandateRemoved {
        try await negotiated().removeCueMandate(name: name)
    }

    public func enableCueMandate(name: String) async throws -> ManagementCueMandateAnswer {
        try await negotiated().enableCueMandate(name: name)
    }

    public func disableCueMandate(name: String) async throws -> ManagementCueMandateAnswer {
        try await negotiated().disableCueMandate(name: name)
    }

    public func approveCueMandate(name: String) async throws -> ManagementCueMandateAnswer {
        try await negotiated().approveCueMandate(name: name)
    }

    public func cueProposals(_ filter: ManagementCueProposalFilter) async throws -> ManagementCueProposalList {
        try await negotiated().cueProposals(filter)
    }

    public func cueProposal(id: String) async throws -> ManagementCueProposalCardAnswer {
        try await negotiated().cueProposal(id: id)
    }

    public func decideCueProposal(id: String, decision: ManagementCueDecision) async throws -> ManagementCueProposalAnswer {
        try await negotiated().decideCueProposal(id: id, decision: decision)
    }
}
