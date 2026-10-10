import CoreImage
import Foundation
import Testing

@testable import FermixAppCore

/// The Phone sheet's pure half (M60 §3.2 to §3.4): the reducer over the
/// daemon's answers, the guards an answer is held to, the row's status, and
/// Forget's two steps.
///
/// Every answer is the vendored contract's own golden, changed in exactly the
/// field a case is about, so a reducer that passes here passes on the shapes
/// the engine publishes.
@Suite("Phone pairing")
@MainActor
struct PhonePairingTests {
    static let session = "5b0c7d2e-8f41-4a6b-9c3d-2e7f1a8b4c60"

    // MARK: - Opening

    @Test("pairing opens the window on a running channel and Turn on on one that is not")
    func openingFollowsTheChannel() throws {
        let running = try PairingGolden.status()
        #expect(PhonePairing.reduce(.waiting(session: nil), .status(running)).step == .waiting(session: nil))

        let owed = try PairingGolden.status { $0["started"] = false }
        #expect(
            PhonePairing.reduce(.waiting(session: nil), .status(owed)).step
                == .turnOn(PhoneTurnOn(throwsSwitch: false))
        )

        let off = try PairingGolden.status {
            $0["enabled"] = false
            $0["started"] = false
        }
        let turnOn = PhonePairing.reduce(.waiting(session: nil), .status(off)).step
        #expect(turnOn == .turnOn(PhoneTurnOn(throwsSwitch: true)))
        guard case .turnOn(let step) = turnOn else { return }
        #expect(step.actionKey == .phoneTurnOnAndRestart)
        #expect(PhoneTurnOn(throwsSwitch: false).actionKey == .phoneTurnOnRestart)
    }

    // MARK: - Every transition, on the goldens

    @Test("the start opens Scan with the link it hands back once")
    func startOpensScan() throws {
        let started = try PairingGolden.start("mobile_pair_start")
        let transition = PhonePairing.reduce(.waiting(session: nil), .started(started))

        guard case .scan(let scan) = transition.step else {
            Issue.record("expected Scan, got \(transition.step)")
            return
        }
        #expect(scan.session == Self.session)
        #expect(scan.ttlMs == 120_000)
        #expect(scan.code == (try Self.code(started.uri)))
        #expect(scan.link.text == started.uri, "Can't scan the code? shows the link the code was drawn from")
        #expect(transition.abandons == nil)
    }

    @Test("a start refused with the channel off ends with the daemon's sentence")
    func refusedStartEnds() throws {
        let refused = try PairingGolden.start("mobile_pair_start_channel_off")
        let transition = PhonePairing.reduce(.waiting(session: nil), .started(refused))

        #expect(transition.step == .ended(PhoneEnding(sentence: "The mobile channel is turned off.", action: .pairAgain)))
        #expect(transition.abandons == nil, "a refused start opened nothing")
    }

    @Test("Scan follows the daemon's clock and moves to Compare when a phone has scanned")
    func scanToCompare() throws {
        let scan = try scanning()

        let waiting = PhonePairing.reduce(scan, .session(try PairingGolden.session("mobile_pair_get_awaiting_scan")))
        guard case .scan(let next) = waiting.step, case .scan(let first) = scan else {
            Issue.record("expected Scan, got \(waiting.step)")
            return
        }
        #expect(next.ttlMs == 112_000)
        #expect(next.code == first.code, "the code survives every read, since no read repeats the link")
        #expect(next.link == first.link, "and so does the link it was drawn from")

        let compare = PhonePairing.reduce(scan, .session(try PairingGolden.session("mobile_pair_get_awaiting_decision")))
        #expect(compare.step == .compare(PhoneCompare(
            session: Self.session,
            deviceName: "Sam's phone",
            model: "Google Pixel 9 Pro",
            digits: "481062",
            hardware: "This phone sent no secure-hardware proof.",
            ttlMs: 83_400
        )))
        #expect(compare.abandons == nil)
    }

    @Test("Approve and a read of an approved session both end on Paired with the phone's name")
    func approvedIsPaired() throws {
        let compare = try comparing()

        for golden in ["mobile_pair_decide", "mobile_pair_get_approved"] {
            let answer = try PairingGolden.session(golden)
            #expect(PhonePairing.reduce(compare, .session(answer)).step == .paired(name: "Sam's phone"), "\(golden)")
        }
    }

    /// The daemon writes a sentence only for `failed`; the three endings it
    /// reports by reason alone take the app's words, switched on the reason.
    @Test("each ending says what the daemon reported")
    func endings() throws {
        let compare = try comparing()
        let expected: [(String, String)] = [
            ("mobile_pair_get_denied", "You denied this phone."),
            ("mobile_pair_get_expired", "The code expired. Pairing codes last two minutes."),
            ("mobile_pair_get_cancelled", "Pairing was cancelled."),
            ("mobile_pair_cancel", "Pairing was cancelled."),
            ("mobile_pair_get_failed", "The phone disconnected before you decided. Start pairing again.")
        ]

        for (golden, sentence) in expected {
            let transition = PhonePairing.reduce(compare, .session(try PairingGolden.session(golden)))

            #expect(transition.step == .ended(PhoneEnding(sentence: sentence, action: .pairAgain)), "\(golden)")
            #expect(transition.abandons == nil, "\(golden) ended on its own")
        }
    }

    /// The words follow the reason, never the state's verb: a cancelled state
    /// whose reason is a timeout reads as the expiry it was.
    @Test("an ending is worded by its reason, not by its state")
    func endingsFollowTheReason() throws {
        let compare = try comparing()
        let answer = try PairingGolden.session("mobile_pair_get_cancelled") {
            $0["outcome"] = ["device_id": NSNull(), "reason": "timeout"]
        }

        #expect(
            PhonePairing.reduce(compare, .session(answer)).step
                == .ended(PhoneEnding(sentence: ProductStrings[.phoneEndedExpired], action: .pairAgain))
        )
    }

    @Test("a refusal ends the session with the daemon's own words")
    func refusalEnds() throws {
        let sentence = "Only the owner can pair or forget a phone; run this from your own terminal."

        #expect(
            PhonePairing.reduce(try comparing(), .refused(sentence)).step
                == .ended(PhoneEnding(sentence: sentence, action: .pairAgain))
        )
    }

    /// A read that comes back after the sheet has moved on is about a window
    /// it has left, and changes nothing.
    @Test("an answer about another window changes nothing")
    func strayAnswers() throws {
        let other = try PairingGolden.session("mobile_pair_get_expired") { $0["session_id"] = "another-window" }
        let scan = try scanning()

        #expect(PhonePairing.reduce(scan, .session(other)).step == scan)
        #expect(PhonePairing.reduce(.phones, .session(try PairingGolden.session("mobile_pair_cancel"))).step == .phones)

        let paired = PhoneSheetStep.paired(name: "Sam's phone")
        #expect(PhonePairing.reduce(paired, .session(try PairingGolden.session("mobile_pair_cancel"))).step == paired)
    }

    // MARK: - busy

    @Test("busy with a phone waiting elsewhere resumes that window for Compare")
    func busyResumesCompare() throws {
        let pairing = try #require(try PairingGolden.status().pairing)
        let resumed = PhonePairing.reduce(.waiting(session: nil), .busy(pairing))

        #expect(resumed.step == .waiting(session: Self.session))
        #expect(resumed.step.openSession == Self.session, "the resumed window is the one a poll reads")

        let compare = PhonePairing.reduce(resumed.step, .session(try PairingGolden.session("mobile_pair_get_awaiting_decision")))
        guard case .compare(let step) = compare.step else {
            Issue.record("expected Compare, got \(compare.step)")
            return
        }
        #expect(step.digits == "481062")
    }

    /// The link is given once, so a code waiting for a scan elsewhere cannot be
    /// drawn here: Start over cancels it and opens a new one.
    @Test("busy with a code waiting elsewhere offers to start over")
    func busyWithAScanStartsOver() throws {
        let pairing = try #require(try PairingGolden.status { status in
            status["pairing"] = ["session_id": Self.session, "state": "awaiting_scan"]
        }.pairing)
        let ending = PhoneEnding(sentence: ProductStrings[.phoneEndedElsewhere], action: .startOver(session: Self.session))

        #expect(PhonePairing.reduce(.waiting(session: nil), .busy(pairing)).step == .ended(ending))
        #expect(ending.actionKey == .phoneStartOver)

        // A resumed window found still waiting for its scan has no code here
        // either.
        let resumed = PhoneSheetStep.waiting(session: Self.session)
        let scan = try PairingGolden.session("mobile_pair_get_awaiting_scan")
        #expect(PhonePairing.reduce(resumed, .session(scan)).step == .ended(ending))
    }

    // MARK: - The guards

    @Test("the link is held to its prefix, its length and its characters")
    func linkGuard() throws {
        let ceiling = PairingGuards.linkPrefix + String(repeating: "a", count: 2048 - PairingGuards.linkPrefix.utf8.count)

        #expect(PairingGuards.link(ceiling) != nil, "a link at the ceiling is drawn")
        #expect(PairingGuards.link(ceiling + "a") == nil, "one byte over is refused")
        #expect(PairingGuards.link(nil) == nil)
        #expect(PairingGuards.link("https://pair?v=1&secret=x") == nil)
        #expect(PairingGuards.link("fermix://pairing?v=1") == nil)
        #expect(PairingGuards.link("fermix://pair?v=1&name=Studio\nMac") == nil)
        #expect(PairingGuards.link("fermix://pair?v=1&name=Studio\u{7}Mac") == nil)
        #expect(PairingGuards.link("fermix://pair?v=1&name=Studio\u{85}Mac") == nil)
        // The version is the phone's to read, so a link the engine writes
        // under a newer one is drawn exactly as the old one was.
        #expect(PairingGuards.link("fermix://pair?v=2&profile=fermix-macos&secret=x") != nil)
        #expect(PairingGuards.link("fermix://pair?v=1&name=Studio+Mac") != nil)
    }

    @Test("a start whose link fails a guard ends and cancels the window it opened")
    func badLinkCancels() throws {
        let cases: [(String, Any)] = [
            ("missing", NSNull()),
            ("another scheme", "https://example.com/pair?v=1"),
            ("too long", PairingGuards.linkPrefix + String(repeating: "a", count: 2048)),
            ("a control character", "fermix://pair?v=1&name=Studio\rMac")
        ]

        for (name, uri) in cases {
            let started = try PairingGolden.start("mobile_pair_start") { $0["uri"] = uri }
            let transition = PhonePairing.reduce(.waiting(session: nil), .started(started))

            #expect(transition.step == Self.unreadable, "\(name)")
            #expect(transition.abandons == Self.session, "\(name) left its window open")
        }
    }

    @Test("a window opens with one to 120000 milliseconds, and a later read may carry zero left")
    func ttlGuard() throws {
        #expect(PairingGuards.ttl(1) == 1)
        #expect(PairingGuards.ttl(120_000) == 120_000)
        #expect(PairingGuards.ttl(0) == nil)
        #expect(PairingGuards.ttl(120_001) == nil)
        #expect(PairingGuards.ttl(nil) == nil)
        #expect(PairingGuards.remaining(0) == 0)
        #expect(PairingGuards.remaining(120_000) == 120_000)
        #expect(PairingGuards.remaining(-1) == nil)
        #expect(PairingGuards.remaining(120_001) == nil)
        #expect(PairingGuards.remaining(nil) == nil)

        for ttl: Any in [0, 120_001, NSNull()] {
            let started = try PairingGolden.start("mobile_pair_start") { $0["ttl_ms"] = ttl }
            #expect(PhonePairing.reduce(.waiting(session: nil), .started(started)).abandons == Self.session)
        }

        for ttl: Any in [120_001, NSNull()] {
            let read = try PairingGolden.session("mobile_pair_get_awaiting_scan") { $0["ttl_ms"] = ttl }
            let transition = PhonePairing.reduce(try scanning(), .session(read))
            #expect(transition.step == Self.unreadable)
            #expect(transition.abandons == Self.session)
        }

        // The last moment before the daemon says the window expired still
        // shows the code, not a refusal.
        let last = try PairingGolden.session("mobile_pair_get_awaiting_scan") { $0["ttl_ms"] = 0 }
        guard case .scan(let scan) = PhonePairing.reduce(try scanning(), .session(last)).step else {
            Issue.record("a read with nothing left still shows Scan")
            return
        }
        #expect(scan.ttlMs == 0)
    }

    @Test("the code is six digits")
    func digitsGuard() throws {
        #expect(PairingGuards.digits("481062"))
        for bad in ["48106", "4810622", "48106a", "481 06", "\u{FF14}81062", ""] {
            #expect(!PairingGuards.digits(bad), "\(bad)")

            let read = try PairingGolden.session("mobile_pair_get_awaiting_decision") { session in
                var request = session["request"] as? [String: Any] ?? [:]
                request["sas"] = bad
                session["request"] = request
            }
            let transition = PhonePairing.reduce(try scanning(), .session(read))
            #expect(transition.step == Self.unreadable, "\(bad)")
            #expect(transition.abandons == Self.session, "\(bad)")
        }
    }

    @Test("the phone's name and model are present and at most 128 bytes")
    func fieldGuard() throws {
        #expect(PairingGuards.field(String(repeating: "a", count: 128)))
        #expect(!PairingGuards.field(String(repeating: "a", count: 129)))
        #expect(!PairingGuards.field(""))
        // Bytes, not characters: 43 three-byte characters are 129 bytes.
        #expect(!PairingGuards.field(String(repeating: "\u{20AC}", count: 43)))

        for field in ["device_name", "model"] {
            for bad in ["", String(repeating: "a", count: 129)] {
                let read = try PairingGolden.session("mobile_pair_get_awaiting_decision") { session in
                    var request = session["request"] as? [String: Any] ?? [:]
                    request[field] = bad
                    session["request"] = request
                }
                let transition = PhonePairing.reduce(try scanning(), .session(read))
                #expect(transition.step == Self.unreadable, "\(field) \(bad.count)")
                #expect(transition.abandons == Self.session)
            }
        }

        let nameless = try PairingGolden.session("mobile_pair_get_approved") { $0["request"] = NSNull() }
        let paired = PhonePairing.reduce(try comparing(), .session(nameless))
        #expect(paired.step == Self.unreadable)
        #expect(paired.abandons == nil, "an approved session is over and has nothing to cancel")
    }

    @Test("a state or a reason this app cannot read ends with its own sentence")
    func unreadableVocabulary() throws {
        let state = try PairingGolden.session("mobile_pair_get_awaiting_scan") { $0["state"] = "awaiting_retina" }
        let unknownState = PhonePairing.reduce(try scanning(), .session(state))
        #expect(unknownState.step == Self.unreadable)
        #expect(unknownState.abandons == Self.session)

        let reason = try PairingGolden.session("mobile_pair_get_denied") {
            $0["outcome"] = ["device_id": NSNull(), "reason": "rate_limited"]
        }
        let unknownReason = PhonePairing.reduce(try comparing(), .session(reason))
        #expect(unknownReason.step == Self.unreadable)
        #expect(unknownReason.abandons == nil)

        let failure = try PairingGolden.session("mobile_pair_get_failed") { $0["failure"] = NSNull() }
        #expect(PhonePairing.reduce(try comparing(), .session(failure)).step == Self.unreadable)
    }

    // MARK: - Closing the sheet

    /// Closing the sheet cancels the window it is showing, so none is left
    /// waiting for a scan, and never one that has already ended.
    @Test("closing cancels the window in Scan and Compare, and nothing once it has ended")
    func closingCancelsOnlyAnOpenWindow() throws {
        #expect(try scanning().openSession == Self.session)
        #expect(try comparing().openSession == Self.session)
        #expect(PhoneSheetStep.waiting(session: Self.session).openSession == Self.session)

        let ended: [PhoneSheetStep] = [
            .paired(name: "Sam's phone"),
            .ended(PhoneEnding(sentence: "Pairing was cancelled.", action: .pairAgain)),
            .phones,
            .turnOn(PhoneTurnOn(throwsSwitch: true)),
            .waiting(session: nil)
        ]
        for step in ended {
            #expect(step.openSession == nil, "\(step)")
        }
    }

    // MARK: - The secret

    /// The code is the link in another form, so it is withheld exactly as the
    /// link is: a step printed into a log line prints neither.
    @Test("neither the link nor its code reaches a description, a reflection or a dump")
    func linkIsWithheld() throws {
        let step = try scanning()
        let link = try #require(PairingGuards.link(try PairingGolden.start("mobile_pair_start").uri))
        let secret = "EXAMPLE-ONE-USE-SECRET"

        for value in [step as Any, link as Any] {
            var dumped = ""
            dump(value, to: &dumped)

            for written in [String(describing: value), String(reflecting: value), dumped] {
                #expect(!written.contains(secret))
                #expect(!written.contains("fermix://pair"))
                #expect(!written.contains("true"), "a module reached a description")
            }
        }
    }

    // MARK: - The code

    /// A link at the 2048-byte ceiling is the densest code a window can ask
    /// for. It is drawn, it reads back as the link, and its card fits the
    /// sheet at two points a module.
    @Test("a link at the 2048-byte ceiling produces a code that reads back and fits the sheet")
    func ceilingLinkProducesACode() throws {
        let filler = String(repeating: "a", count: PairingGuards.maxLinkBytes - PairingGuards.linkPrefix.utf8.count)
        let text = PairingGuards.linkPrefix + filler
        let code = try Self.code(text)

        // A dense code: version 37 or above, 165 modules a side or more.
        #expect(code.count >= 165)
        #expect(PairingCodeLayout.modulePoints(for: code) == PairingCodeLayout.minimumModulePoints)
        #expect(PairingCodeLayout.side(of: code) <= PairingCodeLayout.maximumSide)
        #expect(try PairingCodeReader.read(code) == text)
    }

    @Test("the golden link's code reads back as the link, the right way up")
    func goldenLinkReadsBack() throws {
        let uri = try #require(try PairingGolden.start("mobile_pair_start").uri)
        let code = try Self.code(uri)

        #expect(try PairingCodeReader.read(code) == uri)
        // The three finder patterns sit top left, top right and bottom left,
        // which is what a code that is not mirrored looks like.
        #expect(PairingCodeReader.hasFinder(code, row: 0, column: 0))
        #expect(PairingCodeReader.hasFinder(code, row: 0, column: code.count - 7))
        #expect(PairingCodeReader.hasFinder(code, row: code.count - 7, column: 0))
        #expect(!PairingCodeReader.hasFinder(code, row: code.count - 7, column: code.count - 7))
    }

    /// Whole points per module and never fewer than two, and a card that grows
    /// with the code once two points a module is what it takes.
    @Test("the card scales by whole points and grows with the code up to the sheet's width")
    func cardLayout() throws {
        let short = try Self.code("fermix://pair?v=1")
        let golden = try Self.code(try PairingGolden.start("mobile_pair_start").uri)
        let ceiling = try Self.code(PairingGuards.linkPrefix + String(repeating: "b", count: 2034))

        for code in [short, golden, ceiling] {
            let points = PairingCodeLayout.modulePoints(for: code)

            #expect(points >= 2)
            #expect(PairingCodeLayout.side(of: code) == (code.count + 8) * points)
            #expect(PairingCodeLayout.side(of: code) <= PairingCodeLayout.maximumSide)
        }
        #expect(PairingCodeLayout.side(of: golden) < PairingCodeLayout.side(of: ceiling))
        #expect(PairingCodeLayout.maximumSide == 412)
    }

    // MARK: - The row

    @Test("the row says each of the six things the daemon can report")
    func rowStatuses() throws {
        let devices = SettingsReadState.loaded(try PairingGolden.devices())
        let cases: [(String, (inout [String: Any]) -> Void, String, PhoneSheetIntent)] = [
            ("off", { $0["enabled"] = false; $0["started"] = false }, ProductStrings[.channelStatusOff], .pair),
            ("owed", { $0["started"] = false; $0["paired_devices"] = 0 }, ProductStrings[.phoneStatusRestartToTurnOn], .pair),
            ("refused", { $0["started"] = false; $0["refused"] = true }, ProductStrings[.phoneStatusCouldNotStart], .pair),
            ("unreachable", { Self.listener(&$0, "unavailable") }, ProductStrings[.phoneStatusCouldNotStart], .pair),
            ("none", { $0["paired_devices"] = 0 }, ProductStrings[.phoneStatusNoPhone], .pair),
            ("one", { $0["paired_devices"] = 1 }, "Sam's phone", .phones),
            ("two", { $0["paired_devices"] = 2 }, "2 phones", .phones)
        ]

        for (name, change, status, opens) in cases {
            let row = PhoneRowProjection.row(status: .loaded(try PairingGolden.status(change)), devices: devices)

            #expect(row.status == status, "\(name)")
            #expect(row.opens == opens, "\(name)")
        }
    }

    /// The listener stays dormant until the first pairing creates the
    /// gateway's identity, so a fresh channel reads `down` while it runs.
    /// That is no phone paired, not a channel that could not start.
    @Test("a dormant listener on a running channel is no phone paired")
    func dormantListener() throws {
        let fresh = try PairingGolden.status {
            Self.listener(&$0, "down")
            $0["paired_devices"] = 0
        }

        #expect(
            PhoneRowProjection.row(status: .loaded(fresh), devices: .loaded(try PairingGolden.devices())).status
                == ProductStrings[.phoneStatusNoPhone]
        )
    }

    @Test("the button pairs a phone until one is paired, then changes the phones")
    func rowButton() throws {
        let none = PhoneRowProjection.row(
            status: .loaded(try PairingGolden.status { $0["paired_devices"] = 0 }),
            devices: .unread
        )
        let one = PhoneRowProjection.row(status: .loaded(try PairingGolden.status()), devices: .unread)

        #expect(none.actionTitle == ProductStrings[.phonePair])
        #expect(one.actionTitle == ProductStrings[.channelManage])
        #expect(one.status == ProductStrings[.channelStatusChecking], "the name waits for the list that carries it")
    }

    @Test("a row with no answer claims nothing, and a refusal is the daemon's sentence")
    func rowWithoutAnAnswer() {
        #expect(PhoneRowProjection.row(status: .unread, devices: .unread) == .unanswered)
        #expect(PhoneRowProjection.row(status: .loading, devices: .unread).status == ProductStrings[.channelStatusChecking])
        #expect(PhoneRowProjection.row(status: .unavailable("Nobody answered."), devices: .unread).status == "Nobody answered.")
        #expect(
            PhoneRowProjection.row(status: .requiresNewerEngine, devices: .unread).status
                == ProductStrings[.daemonErrorRequiresNewerEngine]
        )
    }

    // MARK: - Forget

    @Test("Forget asks in the row, and only the second press forgets")
    func forgetTakesTwoSteps() {
        var forgetting = PhoneForgetting()

        #expect(forgetting.confirm() == nil, "nothing was asked")

        forgetting.ask("phone-a")
        #expect(forgetting.asking == "phone-a")
        #expect(forgetting.forgetting == nil, "asking forgets nothing")

        forgetting.withdraw()
        #expect(forgetting.asking == nil)
        #expect(forgetting.confirm() == nil, "a withdrawn question forgets nothing")

        forgetting.ask("phone-a")
        forgetting.ask("phone-b")
        #expect(forgetting.asking == "phone-b", "one row asks at a time")

        #expect(forgetting.confirm() == "phone-b")
        #expect(forgetting.asking == nil)
        #expect(forgetting.forgetting == "phone-b")

        forgetting.ask("phone-a")
        #expect(forgetting.asking == nil, "nothing is asked while a phone is being forgotten")

        forgetting.finished("phone-b", refusal: "No paired phone has that id.")
        #expect(forgetting.forgetting == nil)
        #expect(forgetting.refusals["phone-b"] == "No paired phone has that id.")

        forgetting.ask("phone-b")
        #expect(forgetting.refusals["phone-b"] == nil, "asking again clears the last refusal")
    }

    // MARK: - The words

    @Test("the countdown is the daemon's clock in minutes and seconds")
    func countdown() {
        #expect(PhoneWording.countdown(ttlMs: 120_000) == "Expires in 2:00")
        #expect(PhoneWording.countdown(ttlMs: 112_000) == "Expires in 1:52")
        #expect(PhoneWording.countdown(ttlMs: 83_400) == "Expires in 1:24")
        #expect(PhoneWording.countdown(ttlMs: 400) == "Expires in 0:01", "an open window never reads as 0:00")
        #expect(PhoneWording.isFinalCountdown(ttlMs: 10_000))
        #expect(!PhoneWording.isFinalCountdown(ttlMs: 10_001))
    }

    @Test("the six digits are grouped in threes and read one by one after the name")
    func digits() {
        #expect(PhoneWording.grouped("481062") == "481 062")
        #expect(PhoneWording.spoken("481062", from: "Sam's phone") == "Sam's phone, 4 8 1 0 6 2")
    }

    @Test("a phone is seen some time ago, or not yet")
    func seen() throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-09-26T14:04:40Z"))
        let english = Locale(identifier: "en_US")

        #expect(PhoneWording.seen(nil, now: now, locale: english) == "Not seen yet")
        #expect(PhoneWording.seen("2026-09-26T12:04:40Z", now: now, locale: english) == "Seen 2 hours ago")
        #expect(PhoneWording.seen("2026-09-26T12:04:39.750Z", now: now, locale: english) == "Seen 2 hours ago")
        #expect(PhoneWording.seen("yesterday", now: now, locale: english) == nil)
    }

    // MARK: - The platform

    /// The platform is named in exactly two strings, so the day another phone
    /// app ships is a two-string change (decision 2).
    @Test("Android is named in the setup row and the Scan line and nowhere else")
    func androidIsNamedTwice() {
        let naming = ProductStringKey.allCases.filter { ProductStrings[$0].contains("Android") }

        #expect(Set(naming) == [.readyNextPhone, .phoneScanLine])
        #expect(ProductStrings[.readyNextPhone] == "Pair your Android phone")
        #expect(ProductStrings[.phoneScanLine] == "On your Android phone, open Fermix and scan this code.")
    }

    // MARK: - Helpers

    static let unreadable = PhoneSheetStep.ended(
        PhoneEnding(sentence: ProductStrings[.phoneEndedUnreadable], action: .pairAgain)
    )

    /// The code a link that passes the guards draws.
    static func code(_ text: String?) throws -> PairingCode {
        let link = try #require(PairingGuards.link(text))

        return try #require(PairingCode.make(from: link))
    }

    private func scanning() throws -> PhoneSheetStep {
        PhonePairing.reduce(.waiting(session: nil), .started(try PairingGolden.start("mobile_pair_start"))).step
    }

    private func comparing() throws -> PhoneSheetStep {
        PhonePairing.reduce(try scanning(), .session(try PairingGolden.session("mobile_pair_get_awaiting_decision"))).step
    }

    private static func listener(_ status: inout [String: Any], _ value: String) {
        var listener = status["listener"] as? [String: Any] ?? [:]
        listener["status"] = value
        status["listener"] = listener
    }
}

/// Reads a drawn code back with Core Image's own detector, which is what
/// proves the modules are a code a scanner reads as the link.
enum PairingCodeReader {
    static func read(_ code: PairingCode) throws -> String? {
        let scale = 4
        let span = code.count + 8
        let side = span * scale
        var bytes = [UInt8](repeating: 255, count: side * side)
        for (row, modules) in code.modules.enumerated() {
            for (column, dark) in modules.enumerated() where dark {
                for y in 0..<scale {
                    for x in 0..<scale {
                        bytes[((row + 4) * scale + y) * side + (column + 4) * scale + x] = 0
                    }
                }
            }
        }
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        let image = try #require(CGImage(
            width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: side,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
        let detector = try #require(CIDetector(
            ofType: CIDetectorTypeQRCode,
            context: nil,
            options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
        ))

        return detector.features(in: CIImage(cgImage: image))
            .compactMap { ($0 as? CIQRCodeFeature)?.messageString }
            .first
    }

    /// Whether a seven-module finder pattern starts at this corner: a dark
    /// ring around a light ring around a dark three by three square.
    static func hasFinder(_ code: PairingCode, row: Int, column: Int) -> Bool {
        (0..<7).allSatisfy { y in
            (0..<7).allSatisfy { x in
                let ring = min(x, y, 6 - x, 6 - y)
                return code.modules[row + y][column + x] == (ring != 1)
            }
        }
    }
}

/// The phone methods' goldens, each changed in exactly the field a case needs.
enum PairingGolden {
    static func status(_ change: (inout [String: Any]) -> Void = { _ in }) throws -> ManagementMobileStatus {
        try decode("mobile_status", change)
    }

    static func start(
        _ name: String,
        _ change: (inout [String: Any]) -> Void = { _ in }
    ) throws -> ManagementPairingStart {
        try decode(name, change)
    }

    static func session(
        _ name: String,
        _ change: (inout [String: Any]) -> Void = { _ in }
    ) throws -> ManagementPairingSession {
        try decode(name, change)
    }

    static func devices(_ change: (inout [String: Any]) -> Void = { _ in }) throws -> ManagementMobileDevices {
        try decode("mobile_devices_list", change)
    }

    static func decode<Value: Decodable>(_ name: String, _ change: (inout [String: Any]) -> Void) throws -> Value {
        let fixture = try #require(try ManagementFixtures.load(.success).first { $0.name == name })
        var result = try #require(try fixture.object("response")["result"] as? [String: Any])
        change(&result)

        return try JSONDecoder().decode(Value.self, from: try JSONSerialization.data(withJSONObject: result))
    }
}
