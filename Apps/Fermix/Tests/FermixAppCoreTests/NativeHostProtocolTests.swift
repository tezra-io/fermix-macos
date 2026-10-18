import Foundation
import Testing

@testable import FermixAppCore

/// The typed `native_host` wire, driven by the vendored golden fixtures.
///
/// `requests.jsonl` is decoded (the handshake reply, every daemon request and
/// every daemon error), `events.jsonl` and `responses.jsonl` are encoded
/// (everything this build sends). Every fixture in all three files is
/// exercised, and each direction asserts its fixtures cover every type the
/// schema publishes for it.
@Suite("Native host protocol")
struct NativeHostProtocolTests {
    @Test("this build declares the version, window and bounds the vendored contract publishes")
    func declaredConstantsMatchTheContract() throws {
        let schema = try NativeHostFixtures.schema()
        let range = schema["x-supported-version-range"] as? [String: Any]

        #expect(schema["x-protocol-version"] as? Int == NativeHostProtocol.version)
        #expect(range?["min"] as? Int == NativeHostProtocol.supportedWindow.minimum)
        #expect(range?["max"] as? Int == NativeHostProtocol.supportedWindow.maximum)
        #expect(NativeHostProtocol.supportedWindow.contains(NativeHostProtocol.version))
        #expect(schema["x-max-line-bytes"] as? Int == NativeHostProtocol.maximumLineBytes)
        #expect(schema["x-max-message-chars"] as? Int == NativeHostProtocol.maximumMessageChars)

        let title = try NativeHostFixtures.property("title", of: "notifications.post")
        let body = try NativeHostFixtures.property("body", of: "notifications.post")
        let actions = try NativeHostFixtures.property("actions", of: "notifications.post")
        let reminder = try NativeHostFixtures.property("reminder_id", of: "notifications.post")
        let actionTitle = try NativeHostFixtures.property("title", of: "action")
        #expect(title["maxLength"] as? Int == NativeHostProtocol.maximumTitleChars)
        #expect(body["maxLength"] as? Int == NativeHostProtocol.maximumBodyChars)
        #expect(actions["maxItems"] as? Int == NativeHostProtocol.maximumActions)
        #expect(reminder["maxLength"] as? Int == NativeHostProtocol.maximumIdentifierChars)
        #expect(actionTitle["maxLength"] as? Int == NativeHostProtocol.maximumActionTitleChars)
    }

    /// The grant's three words, the action ids and the host's error reasons
    /// are the contract's closed sets, so this build models exactly those.
    @Test("the grant states, action ids and host error reasons are exactly the schema's")
    func vocabulariesMatchTheContract() throws {
        #expect(try NativeHostFixtures.enumeration("grantState") == Set(NotificationGrant.allCases.map(\.rawValue)))
        #expect(try NativeHostFixtures.enumeration("action", property: "id") == Set(NotificationActionID.allCases.map(\.rawValue)))
        #expect(
            try NativeHostFixtures.enumeration("notification.action", property: "action")
                == Set(NotificationActionID.allCases.map(\.rawValue))
        )
        #expect(try NativeHostFixtures.enumeration("hostError", property: "reason") == Set(NativeHostErrorReason.allCases.map(\.rawValue)))
    }

    // MARK: - requests.jsonl (decoded)

    @Test("every golden daemon frame decodes and writes back as itself")
    func roundTripsEveryDaemonFixture() throws {
        let fixtures = try NativeHostFixtures.load(.requests)
        let daemonFrameTypes = try NativeHostFixtures.enumeration("daemonFrame", property: "type")
        let seenTypes = Set(fixtures.compactMap { $0.object["type"] as? String })

        #expect(seenTypes == daemonFrameTypes, "the fixture file covers every type the schema publishes")

        for fixture in fixtures {
            let inbound = try NativeHostInbound.decode(fixture.line)
            let written = NativeHostDaemonWire.object(inbound)

            #expect(
                NSDictionary(dictionary: written).isEqual(to: fixture.object),
                "\(fixture.object["type"] ?? "?") came back as \(written)"
            )
        }
    }

    @Test("the handshake reply, the two posts and the refusals decode into their typed fields")
    func specificDaemonFixtureFields() throws {
        let decoded = try NativeHostFixtures.load(.requests).map { try NativeHostInbound.decode($0.line) }

        #expect(decoded.first == .serverHello(minVersion: 1, maxVersion: 1))
        #expect(decoded.contains(.request(.hostStatus(id: 1))))
        #expect(decoded.contains(.request(.notificationsAuthorize(id: 2))))
        #expect(decoded.contains(.request(.hostStopAck(id: 5))))
        #expect(decoded.contains(.request(.notificationsPost(id: 3, NativeHostPostRequest(
            title: "Tea",
            body: "Tea, today at 16:05 (in 10 minutes).",
            sound: true,
            actions: [NativeHostAction(id: "snooze_10m", title: "Snooze 10 minutes")],
            reminderId: "rem_8Kf2xQ1vT0w"
        )))))
        #expect(decoded.contains(.request(.notificationsPost(id: 4, NativeHostPostRequest(
            title: "Laundry",
            body: "Laundry, today at 18:30.",
            sound: false,
            actions: [],
            reminderId: nil
        )))))

        let refusals = decoded.compactMap { frame -> NativeHostDaemonError? in
            guard case .error(let error) = frame else { return nil }
            return error
        }
        let versionRefusal = try #require(refusals.first { $0.reason == "unsupported_protocol_version" })
        #expect(versionRefusal.direction == .clientTooNew)
        #expect(versionRefusal.clientVersion == 2)
        #expect(versionRefusal.window == NativeHostVersionWindow(minimum: 1, maximum: 1))
        let untrustedHost = try #require(refusals.first { $0.reason == "untrusted_host" })
        #expect(untrustedHost.message?.contains("daemon did not start") == true)
        #expect(refusals.first { $0.reason == "missing_field" }?.field == "host_version")
        #expect(refusals.first { $0.reason == "unknown_event" }?.event == "tab.closed")
    }

    // MARK: - events.jsonl (encoded)

    @Test("every golden event is produced by a typed value")
    func encodesEveryEventFixture() throws {
        let fixtures = try NativeHostFixtures.load(.events)
        let produced: [NativeHostEvent] = [
            .clientHello(protocolVersion: NativeHostProtocol.version),
            .attached(hostVersion: "0.6.0"),
            .capabilities(notifications: .notAsked),
            .capabilities(notifications: .granted),
            .capabilities(notifications: .notGranted),
            .notificationAction(reminderId: "rem_8Kf2xQ1vT0w", action: .snooze10m),
            .hostStopping
        ]

        #expect(produced.count == fixtures.count)
        let eventTypes = try NativeHostFixtures.enumeration("hostEvent", property: "type")
        #expect(Set(fixtures.compactMap { $0.object["type"] as? String }) == eventTypes)

        for (event, fixture) in zip(produced, fixtures) {
            let line = try event.line()

            #expect(!line.contains(0x0A), "\(event.wireType) must be exactly one line")
            #expect(event.wireType == fixture.object["type"] as? String)
            #expect(
                try NativeHostFixtures.sameObject(line, fixture.line),
                "\(event.wireType): \(String(decoding: line, as: UTF8.self))"
            )
        }
    }

    // MARK: - responses.jsonl (encoded)

    @Test("every golden response is produced by a typed value")
    func encodesEveryResponseFixture() throws {
        let fixtures = try NativeHostFixtures.load(.responses)
        let produced: [NativeHostResponse] = [
            NativeHostResponse(id: 1, result: .hostStatus(hostVersion: "0.6.0", notifications: .granted)),
            NativeHostResponse(id: 2, result: .authorize(state: .granted)),
            NativeHostResponse(id: 3, result: .post(notificationId: "7E1A3C1F-5B2D-4F7A-9C8E-2D41B6A0F311")),
            NativeHostResponse(id: 4, result: .post(notificationId: "0C9D2B44-1E7F-4A3B-8D5C-6F20A9E1B702")),
            NativeHostResponse(id: 5, result: .hostStopAck),
            NativeHostResponse(id: 3, error: NativeHostError(
                reason: .notAuthorized, message: "Notifications are turned off for Fermix in System Settings"
            )),
            NativeHostResponse(id: 4, error: NativeHostError(reason: .postFailed, message: "The notification could not be scheduled")),
            NativeHostResponse(id: 4, error: NativeHostError(reason: .invalidRequest, message: "the notification has no title")),
            NativeHostResponse(id: 1, error: NativeHostError(reason: .hostUnavailable, message: "the app is quitting"))
        ]

        #expect(produced.count == fixtures.count)
        let reasons = Set(fixtures.compactMap { ($0.object["error"] as? [String: Any])?["reason"] as? String })
        #expect(reasons == Set(NativeHostErrorReason.allCases.map(\.rawValue)), "the fixtures refuse with every host reason")

        for (response, fixture) in zip(produced, fixtures) {
            let line = try response.line()

            #expect(!line.contains(0x0A), "response \(response.id) must be exactly one line")
            #expect(
                try NativeHostFixtures.sameObject(line, fixture.line),
                "response \(response.id): \(String(decoding: line, as: UTF8.self))"
            )
        }
    }

    /// The refusal sentences the client sends are the goldens' own words, so
    /// the daemon records what the contract says it records.
    @Test("the refusal sentences are the contract's own")
    func refusalSentencesAreTheContracts() throws {
        let messages = try NativeHostFixtures.load(.responses)
            .compactMap { ($0.object["error"] as? [String: Any])?["message"] as? String }

        #expect(messages.contains(ProductStrings[.nativeHostRefusalTurnedOff]))
        #expect(messages.contains(ProductStrings[.nativeHostReasonAppQuitting]))
    }

    // MARK: - Failure shapes

    @Test("a missing required field is refused by its name")
    func missingFieldIsNamed() {
        let withoutTitle = #"{"id":3,"type":"notifications.post","body":"b","sound":true,"actions":[]}"#
        let withoutActionTitle = #"{"id":3,"type":"notifications.post","title":"t","body":"b","sound":true,"actions":[{"id":"snooze_10m"}],"reminder_id":"r"}"#

        #expect(throws: NativeHostDecodeFailure.missingField("title")) {
            _ = try NativeHostInbound.decode(Data(withoutTitle.utf8))
        }
        #expect(throws: NativeHostDecodeFailure.missingField("actions.0.title")) {
            _ = try NativeHostInbound.decode(Data(withoutActionTitle.utf8))
        }
        #expect(throws: NativeHostDecodeFailure.missingField("id")) {
            _ = try NativeHostInbound.decode(Data(#"{"type":"host.status"}"#.utf8))
        }
    }

    @Test("a field of the wrong shape is refused by its name")
    func wrongShapeIsNamed() {
        let soundAsText = #"{"id":3,"type":"notifications.post","title":"t","body":"b","sound":"yes","actions":[]}"#

        #expect(throws: NativeHostDecodeFailure.invalidField("sound")) {
            _ = try NativeHostInbound.decode(Data(soundAsText.utf8))
        }
    }

    @Test("a line that is not an object, carries no type, or names an unknown type is refused")
    func unusableLinesAreRefused() {
        #expect(throws: NativeHostDecodeFailure.malformedJSON) {
            _ = try NativeHostInbound.decode(Data("{not json".utf8))
        }
        #expect(throws: NativeHostDecodeFailure.notAnObject) {
            _ = try NativeHostInbound.decode(Data("[1,2]".utf8))
        }
        #expect(throws: NativeHostDecodeFailure.missingType) {
            _ = try NativeHostInbound.decode(Data(#"{"id":1}"#.utf8))
        }
        #expect(throws: NativeHostDecodeFailure.invalidField("type")) {
            _ = try NativeHostInbound.decode(Data(#"{"id":1,"type":"calendar.list"}"#.utf8))
        }
    }

    @Test("a line over the contract's cap is refused before it is sent")
    func oversizedLineIsRefused() {
        let event = NativeHostEvent.attached(hostVersion: String(repeating: "9", count: NativeHostProtocol.maximumLineBytes))

        #expect(throws: NativeHostEncodeFailure.self) {
            _ = try event.line()
        }
    }

    @Test("a version window names the side that must update")
    func versionWindowDirection() {
        let window = NativeHostVersionWindow(minimum: 2, maximum: 3)

        #expect(window.direction(for: 1) == .clientTooOld)
        #expect(window.direction(for: 4) == .clientTooNew)
        #expect(!window.contains(1))
        #expect(window.contains(2))
    }

    @Test("a host error's message is bounded to the contract's cap")
    func hostErrorMessageIsBounded() {
        let error = NativeHostError(reason: .postFailed, message: String(repeating: "x", count: 900))

        #expect(error.message.count == NativeHostProtocol.maximumMessageChars)
    }
}
