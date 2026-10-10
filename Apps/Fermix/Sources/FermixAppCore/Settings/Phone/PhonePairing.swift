import Foundation

/// The phone channel's names on the wire (M60).
///
/// The channel is `mobile` in `setup.state.get` and its section is
/// `channels.mobile`; both are the contract's own spellings, written once here
/// through the projection every channel row uses.
public enum PhoneChannel {
    public static let name = "mobile"

    public static var section: String { ChannelRowProjection.sectionId(for: name) }

    /// The section's switch, `mobile_enabled`.
    public static var switchKey: String { ChannelRowProjection.enabledKey(for: name) }

    /// The cadence the contract recommends for reading a pairing window, and
    /// the one this app polls at (PROTOCOL.md).
    public static let pollSeconds: TimeInterval = 1
}

// MARK: - The link

/// The pairing link the daemon hands back once, held by the Scan step and
/// nowhere else, so it leaves memory when Scan does.
///
/// It carries the one-time secret the phone pairs with, so it is never logged,
/// never written to disk and never an accessibility value (M60 §3.5). It is
/// shown as text only when the person asks, behind "Can't scan the code?", for
/// a phone or an emulator that cannot scan, and copied for this Mac only,
/// taken back off the pasteboard when Scan leaves. Its descriptions say so
/// rather than spelling it: a value printed into a log line or a test failure
/// prints this type's name and nothing of the link.
public struct PairingLink: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// The bytes the code is drawn from, as the daemon sent them.
    let utf8: Data

    /// The link as the person reads and pastes it.
    var text: String { String(decoding: utf8, as: UTF8.self) }

    public var description: String { "PairingLink(withheld)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

// MARK: - The guards

/// What an answer is held to before anything is drawn: the guards `fermix pair`
/// applies (M60 §3.4). An answer that fails one ends the session with the app's
/// sentence rather than drawing a code or a phone this app cannot vouch for.
public enum PairingGuards {
    public static let linkPrefix = "fermix://pair?"
    public static let maxLinkBytes = 2048
    public static let ttlRange = 1...120_000
    public static let digitCount = 6
    public static let maxFieldBytes = 128

    /// The link, held to its prefix, its length and its characters. Its
    /// version is never read: the link is the phone's to parse, and the two
    /// sides agree on it without this app.
    public static func link(_ value: String?) -> PairingLink? {
        guard let value, value.hasPrefix(linkPrefix) else { return nil }

        let bytes = Data(value.utf8)
        guard bytes.count <= maxLinkBytes else { return nil }
        guard !value.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else { return nil }

        return PairingLink(utf8: bytes)
    }

    /// The window's lifetime as it opens, which `fermix pair` holds to one to
    /// 120000 milliseconds.
    public static func ttl(_ value: Int?) -> Int? {
        guard let value, ttlRange.contains(value) else { return nil }

        return value
    }

    /// What is left of an open window on a later read. The daemon counts it
    /// down to zero before it says the window expired, so a read in that last
    /// moment can carry zero.
    public static func remaining(_ value: Int?) -> Int? {
        guard let value, (0...ttlRange.upperBound).contains(value) else { return nil }

        return value
    }

    /// Six ASCII digits, which is what the phone draws.
    public static func digits(_ value: String) -> Bool {
        value.utf8.count == digitCount && value.utf8.allSatisfy { (0x30...0x39).contains($0) }
    }

    /// A device's name or model: present, and inside the pairing intake bound.
    public static func field(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= maxFieldBytes
    }
}

// MARK: - The sheet's steps

/// What the Phone sheet opens for: pairing a phone, or the phones already
/// paired. The row's own button names which (M60 §3.2).
public enum PhoneSheetIntent: Equatable, Sendable {
    case pair
    case phones
}

/// The one step the Phone sheet shows, which changes in place (M60 §3.3).
public enum PhoneSheetStep: Equatable, Sendable {
    /// Waiting on the daemon: reading the channel, opening a window, or
    /// resuming the window `session` names, which a poll then reads.
    case waiting(session: String?)
    case turnOn(PhoneTurnOn)
    case scan(PhoneScan)
    case compare(PhoneCompare)
    case paired(name: String)
    case ended(PhoneEnding)
    case phones

    /// The pairing window this step is showing, which is the one a poll reads
    /// and closing the sheet cancels. Nil once the session has ended, so a
    /// window that is over is never cancelled.
    public var openSession: String? {
        switch self {
        case .waiting(let session): return session
        case .scan(let scan): return scan.session
        case .compare(let compare): return compare.session
        case .turnOn, .paired, .ended, .phones: return nil
        }
    }
}

/// Turn on: shown while the channel is not running.
public struct PhoneTurnOn: Equatable, Sendable {
    public enum Progress: Equatable, Sendable {
        case idle
        /// The switch is being written.
        case applying
        /// The app's one restart transaction is running.
        case restarting
    }

    /// Whether this step throws the switch, or the switch is already on and
    /// only the restart is owed.
    public let throwsSwitch: Bool
    public var progress: Progress
    /// What refused it, as written, where something did.
    public var refusal: String?

    public init(throwsSwitch: Bool, progress: Progress = .idle, refusal: String? = nil) {
        self.throwsSwitch = throwsSwitch
        self.progress = progress
        self.refusal = refusal
    }

    public var actionKey: ProductStringKey {
        throwsSwitch ? .phoneTurnOnAndRestart : .phoneTurnOnRestart
    }
}

/// Scan: the code, the link it was drawn from, and the daemon's own clock.
///
/// The code is drawn from the link once, as the window opens. Both leave
/// memory with the step, since no later answer carries the link again.
public struct PhoneScan: Equatable, Sendable {
    public let session: String
    public let link: PairingLink
    public let code: PairingCode
    /// The daemon's `ttl_ms`, as the last answer gave it.
    public let ttlMs: Int
}

/// Compare: the phone waiting for a decision, as the daemon reports it.
public struct PhoneCompare: Equatable, Sendable {
    public let session: String
    public let deviceName: String
    public let model: String
    public let digits: String
    /// What the daemon says of the phone's hardware, drawn as written.
    public let hardware: String
    public let ttlMs: Int
}

/// Ended: one sentence and the one way on.
public struct PhoneEnding: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case pairAgain
        /// Cancels the window open somewhere else, where one is named, and
        /// opens a new one.
        case startOver(session: String?)
    }

    public let sentence: String
    public let action: Action

    public var actionKey: ProductStringKey {
        switch action {
        case .pairAgain: return .phonePairAgain
        case .startOver: return .phoneStartOver
        }
    }
}

// MARK: - The reducer

/// One answer from the daemon, as the sheet takes it.
public enum PhoneAnswer: Equatable, Sendable {
    /// `mobile.status`, read as pairing begins.
    case status(ManagementMobileStatus)
    /// `mobile.pair.start`'s answer.
    case started(ManagementPairingStart)
    /// `mobile.pair.start` refused `busy`, with the session `mobile.status`
    /// named afterwards, where it named one.
    case busy(ManagementPairingSummary?)
    /// A session view: `mobile.pair.get`, `.decide` or `.cancel`.
    case session(ManagementPairingSession)
    /// Any other refusal, in the daemon's own words.
    case refused(String)
}

/// The step an answer leads to, and the window it leaves open that nothing
/// will show, which the model cancels so no window waits for a scan (§3.4).
public struct PhoneTransition: Equatable, Sendable {
    public let step: PhoneSheetStep
    public let abandons: String?

    init(_ step: PhoneSheetStep, abandons: String? = nil) {
        self.step = step
        self.abandons = abandons
    }
}

/// The Phone sheet as a reducer over the daemon's answers (M60 §3.3, §3.4).
///
/// It derives nothing the daemon publishes: which state the session is in,
/// whether the channel runs and how a session ended are all read. The words it
/// adds are the app's over the daemon's facts, switched on the published
/// state and reason and never on a verb word.
public enum PhonePairing {
    public static func reduce(_ step: PhoneSheetStep, _ answer: PhoneAnswer) -> PhoneTransition {
        switch answer {
        case .status(let status):
            return opening(status)
        case .started(let started):
            return start(started)
        case .busy(let pairing):
            return busy(pairing)
        case .session(let session):
            return read(session, on: step)
        case .refused(let sentence):
            return PhoneTransition(.ended(PhoneEnding(sentence: sentence, action: .pairAgain)))
        }
    }

    /// Pairing begins on the channel as it stands: Turn on while it is not
    /// running, and the window opening once it is.
    private static func opening(_ status: ManagementMobileStatus) -> PhoneTransition {
        guard status.started else {
            return PhoneTransition(.turnOn(PhoneTurnOn(throwsSwitch: !status.enabled)))
        }

        return PhoneTransition(.waiting(session: nil))
    }

    /// The window the start opened, or the daemon's refusal of it. The link is
    /// read here and nowhere else, since no later answer carries it.
    private static func start(_ answer: ManagementPairingStart) -> PhoneTransition {
        let session = answer.session
        switch session.state {
        case .awaitingScan:
            guard let id = session.sessionId,
                  let link = PairingGuards.link(answer.uri),
                  let code = PairingCode.make(from: link),
                  let ttl = PairingGuards.ttl(session.ttlMs)
            else { return unreadable(leaving: session) }

            return PhoneTransition(.scan(PhoneScan(session: id, link: link, code: code, ttlMs: ttl)))
        case .failed:
            return failed(session)
        case .awaitingDecision, .approved, .denied, .expired, .cancelled, .unrecognized:
            return unreadable(leaving: session)
        }
    }

    /// A window is already open somewhere else. A phone waiting there is
    /// resumed here, so it can be compared; a code waiting for a scan cannot be
    /// drawn again, since the link is given once.
    private static func busy(_ pairing: ManagementPairingSummary?) -> PhoneTransition {
        guard let pairing, pairing.state == .awaitingDecision else {
            let ending = PhoneEnding(
                sentence: ProductStrings[.phoneEndedElsewhere],
                action: .startOver(session: pairing?.sessionId)
            )
            return PhoneTransition(.ended(ending))
        }

        return PhoneTransition(.waiting(session: pairing.sessionId))
    }

    /// A read of the window this step is showing. An answer about any other
    /// window is one this step has already left, and changes nothing.
    private static func read(_ session: ManagementPairingSession, on step: PhoneSheetStep) -> PhoneTransition {
        guard let id = session.sessionId, id == step.openSession else { return PhoneTransition(step) }

        switch session.state {
        case .awaitingScan:
            return scanning(session, id: id, on: step)
        case .awaitingDecision:
            return comparing(session, id: id)
        case .approved:
            guard let name = session.request?.deviceName, PairingGuards.field(name) else {
                return unreadable(leaving: nil)
            }
            return PhoneTransition(.paired(name: name))
        case .denied, .expired, .cancelled:
            return ended(by: session.outcome?.reason)
        case .failed:
            return failed(session)
        case .unrecognized:
            return unreadable(leaving: session)
        }
    }

    /// Still waiting for a scan: the countdown moves on the daemon's own
    /// clock. A window this sheet did not open has no code to draw.
    private static func scanning(
        _ session: ManagementPairingSession,
        id: String,
        on step: PhoneSheetStep
    ) -> PhoneTransition {
        guard case .scan(let scan) = step else {
            return PhoneTransition(.ended(PhoneEnding(
                sentence: ProductStrings[.phoneEndedElsewhere],
                action: .startOver(session: id)
            )))
        }
        guard let ttl = PairingGuards.remaining(session.ttlMs) else { return unreadable(leaving: session) }

        return PhoneTransition(.scan(PhoneScan(session: id, link: scan.link, code: scan.code, ttlMs: ttl)))
    }

    private static func comparing(_ session: ManagementPairingSession, id: String) -> PhoneTransition {
        guard let request = session.request,
              let ttl = PairingGuards.remaining(session.ttlMs),
              PairingGuards.digits(request.sas),
              PairingGuards.field(request.deviceName),
              PairingGuards.field(request.model)
        else { return unreadable(leaving: session) }

        return PhoneTransition(.compare(PhoneCompare(
            session: id,
            deviceName: request.deviceName,
            model: request.model,
            digits: request.sas,
            hardware: request.attestation.sentence,
            ttlMs: ttl
        )))
    }

    /// The three endings the daemon reports by reason alone (§3.3).
    private static func ended(by reason: ManagementPairingOutcomeReason?) -> PhoneTransition {
        let key: ProductStringKey
        switch reason {
        case .timeout: key = .phoneEndedExpired
        case .denied: key = .phoneEndedDenied
        case .cancelled: key = .phoneEndedCancelled
        case .unrecognized, nil: return unreadable(leaving: nil)
        }

        return PhoneTransition(.ended(PhoneEnding(sentence: ProductStrings[key], action: .pairAgain)))
    }

    /// A failed session ends with the daemon's own sentence.
    private static func failed(_ session: ManagementPairingSession) -> PhoneTransition {
        guard let failure = session.failure else { return unreadable(leaving: nil) }

        return PhoneTransition(.ended(PhoneEnding(sentence: failure.sentence, action: .pairAgain)))
    }

    /// An answer this app cannot show. A window it leaves open is cancelled.
    private static func unreadable(leaving session: ManagementPairingSession?) -> PhoneTransition {
        let open = session.flatMap { $0.state.isTerminal ? nil : $0.sessionId }

        return PhoneTransition(
            .ended(PhoneEnding(sentence: ProductStrings[.phoneEndedUnreadable], action: .pairAgain)),
            abandons: open
        )
    }
}

// MARK: - What the steps draw

/// The words the steps put around the daemon's facts.
public enum PhoneWording {
    /// "Expires in 1:45": the daemon's `ttl_ms`, rounded up to the second so a
    /// window that is still open never reads as `0:00`.
    public static func countdown(ttlMs: Int) -> String {
        let seconds = (ttlMs + 999) / 1000

        return String(format: ProductStrings[.phoneScanCountdownFormat], clock(seconds))
    }

    /// Minutes and seconds, as a phone's own countdown reads.
    static func clock(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    /// Whether the countdown has reached the last ten seconds, which is when it
    /// is announced again (§7).
    public static func isFinalCountdown(ttlMs: Int) -> Bool {
        ttlMs <= 10_000
    }

    /// The six digits in threes, as the phone draws them: `481 062`.
    public static func grouped(_ digits: String) -> String {
        let characters = Array(digits)
        let half = characters.count / 2

        return String(characters[..<half]) + " " + String(characters[half...])
    }

    /// The digits one by one, after the phone's name, which is how VoiceOver
    /// reads them (§7).
    public static func spoken(_ digits: String, from name: String) -> String {
        ProductStrings.commaPair(name, digits.map(String.init).joined(separator: " "))
    }

    /// When a paired phone was last seen: `Seen 2 hours ago`, or `Not seen
    /// yet`. Nil for a time the daemon wrote in a shape this app cannot read,
    /// so the row says nothing rather than something untrue.
    public static func seen(_ lastSeen: String?, now: Date, locale: Locale = .current) -> String? {
        guard let lastSeen else { return ProductStrings[.phoneNotSeen] }
        guard let date = timestamp(lastSeen) else { return nil }

        let relative = RelativeDateTimeFormatter()
        relative.locale = locale
        relative.unitsStyle = .full

        return String(format: ProductStrings[.phoneSeenFormat], relative.localizedString(for: date, relativeTo: now))
    }

    private static func timestamp(_ value: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: value) { return date }

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        return fractional.date(from: value)
    }
}

// MARK: - The row

/// The Phone row's status and button (M60 §3.2).
public struct PhoneRow: Equatable, Sendable {
    public let status: String
    /// What the row's one button opens.
    public let opens: PhoneSheetIntent

    public var actionTitle: String {
        opens == .phones ? ProductStrings[.channelManage] : ProductStrings[.phonePair]
    }

    /// Nothing read yet.
    public static let unanswered = PhoneRow(status: ProductStrings[.channelStatusChecking], opens: .pair)
}

/// The row's status from `mobile.status` and `mobile.devices.list`, never from
/// `configured`: the phone channel is always configured, so the generic two
/// facts said Connected of a channel with no phone paired.
public enum PhoneRowProjection {
    public static func row(
        status: SettingsReadState<ManagementMobileStatus>,
        devices: SettingsReadState<ManagementMobileDevices>
    ) -> PhoneRow {
        switch status {
        case .loaded(let answer):
            return row(answer, devices: devices)
        case .unavailable(let sentence):
            return PhoneRow(status: sentence, opens: .pair)
        case .requiresNewerEngine:
            return PhoneRow(status: ProductStrings[.daemonErrorRequiresNewerEngine], opens: .pair)
        case .unread, .loading:
            return .unanswered
        }
    }

    /// The table of §3.2, in its order.
    private static func row(
        _ status: ManagementMobileStatus,
        devices: SettingsReadState<ManagementMobileDevices>
    ) -> PhoneRow {
        guard status.enabled else { return PhoneRow(status: ProductStrings[.channelStatusOff], opens: .pair) }
        guard status.started || status.refused else {
            return PhoneRow(status: ProductStrings[.phoneStatusRestartToTurnOn], opens: .pair)
        }
        guard !status.refused, status.listener.status != .unavailable else {
            return PhoneRow(status: ProductStrings[.phoneStatusCouldNotStart], opens: .pair)
        }

        switch status.pairedDevices {
        case ...0:
            return PhoneRow(status: ProductStrings[.phoneStatusNoPhone], opens: .pair)
        case 1:
            return PhoneRow(status: name(of: devices), opens: .phones)
        default:
            let count = String(format: ProductStrings[.phoneStatusCountFormat], status.pairedDevices)
            return PhoneRow(status: count, opens: .phones)
        }
    }

    /// The one paired phone's name, from the list that names it.
    private static func name(of devices: SettingsReadState<ManagementMobileDevices>) -> String {
        switch devices {
        case .loaded(let answer):
            return answer.devices.first?.name ?? ProductStrings[.channelStatusChecking]
        case .unavailable(let sentence):
            return sentence
        case .requiresNewerEngine:
            return ProductStrings[.daemonErrorRequiresNewerEngine]
        case .unread, .loading:
            return ProductStrings[.channelStatusChecking]
        }
    }
}

// MARK: - Forgetting a phone

/// Forget, asked in the row itself (M60 §3.3, decision 9): the row's button
/// becomes `Forget this phone` and `Cancel`, with no confirmation dialog over
/// the sheet.
public struct PhoneForgetting: Equatable, Sendable {
    /// The phone whose row is asking.
    public private(set) var asking: String?
    /// The phone being forgotten right now.
    public private(set) var forgetting: String?
    /// The daemon's sentence under a row whose forget it refused.
    public private(set) var refusals: [String: String] = [:]

    public init() {}

    /// The first step: the row asks. Asking about one phone withdraws the
    /// question from any other.
    public mutating func ask(_ device: String) {
        guard forgetting == nil else { return }

        asking = device
        refusals[device] = nil
    }

    public mutating func withdraw() {
        asking = nil
    }

    /// The second step: the phone the row asked about, which is then the one
    /// being forgotten. Nil where nothing was asked.
    public mutating func confirm() -> String? {
        guard let device = asking, forgetting == nil else { return nil }

        asking = nil
        forgetting = device
        return device
    }

    /// The daemon answered. A refusal stays under the row it refused.
    public mutating func finished(_ device: String, refusal: String?) {
        guard forgetting == device else { return }

        forgetting = nil
        refusals[device] = refusal
    }
}
