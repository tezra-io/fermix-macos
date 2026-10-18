import AppKit
import Combine
import Foundation
import Testing
import UserNotifications

@testable import FermixAppCore

/// Fermix's notifications on this Mac, over a scripted center: the grant's
/// three words, the one prompt, what a post carries to the framework, and
/// what the person's answers become. No framework center is touched.
@MainActor
@Suite("Mac notifications")
struct MacNotificationsTests {
    @Test("the framework's statuses read as the wire's three words")
    func statusesReadAsTheWiresWords() {
        #expect(NotificationGrant(.authorized) == .granted)
        #expect(NotificationGrant(.provisional) == .granted)
        #expect(NotificationGrant(.denied) == .notGranted)
        #expect(NotificationGrant(.notDetermined) == .notAsked)
    }

    // MARK: - The one prompt

    @Test("authorize raises the prompt only while nobody has been asked, and answers the grant after it")
    func authorizePromptsOnlyWhenNotAsked() async {
        let center = FakeNotificationCenter(status: .notAsked, promptAnswer: .granted)
        let notifications = Self.make(center)

        let answered = await notifications.authorize()

        #expect(answered == .granted)
        #expect(center.promptsRaised == 1)
        #expect(notifications.grant == .granted)

        for decided in [NotificationGrant.granted, .notGranted] {
            let decidedCenter = FakeNotificationCenter(status: decided)
            let answer = await Self.make(decidedCenter).authorize()

            #expect(answer == decided)
            #expect(decidedCenter.promptsRaised == 0, "\(decided) is answered at once")
        }
    }

    /// The engine's `notifications.authorize` and the row's Grant… can both
    /// ask while the prompt is up; the second waits on the first's answer.
    @Test("a second ask while the prompt is up joins it rather than raising another")
    func concurrentAsksJoinOnePrompt() async {
        let center = FakeNotificationCenter(status: .notAsked, promptAnswer: nil)
        let notifications = Self.make(center)

        let first = Task { await notifications.authorize() }
        let second = Task { await notifications.authorize() }
        #expect(await yieldUntil { center.promptIsUp && center.grantReads >= 2 })

        center.answerPrompt(.notGranted)
        let firstAnswer = await first.value
        let secondAnswer = await second.value

        #expect(firstAnswer == .notGranted)
        #expect(secondAnswer == .notGranted)
        #expect(center.promptsRaised == 1)
    }

    /// A prompt the framework returned from without an answer leaves the
    /// grant unasked, and this process still never raises a second one.
    @Test("the prompt is never raised twice in one process")
    func promptIsNeverRaisedTwice() async {
        let center = FakeNotificationCenter(status: .notAsked, promptAnswer: .notAsked)
        let notifications = Self.make(center)

        _ = await notifications.authorize()
        let again = await notifications.authorize()

        #expect(again == .notAsked)
        #expect(center.promptsRaised == 1)
    }

    /// "Never twice" is about a prompt the person was shown. A request the
    /// framework refused before showing anything raised nothing, so the next
    /// ask, from the engine or the row's Grant…, asks again.
    @Test("a prompt request the framework refused is asked again")
    func refusedPromptRequestIsAskedAgain() async {
        let center = FakeNotificationCenter(status: .notAsked, promptAnswer: .granted)
        center.promptFailure = FrameworkRefusal(words: "Notifications are not allowed for this application")
        let notifications = Self.make(center)

        let first = await notifications.authorize()
        let second = await notifications.authorize()

        #expect(first == .notAsked)
        #expect(second == .granted)
        #expect(center.promptsRaised == 2)
    }

    // MARK: - Posting

    @Test("a post without the grant is refused not_authorized and never prompts")
    func postWithoutTheGrantIsRefused() async {
        for grant in [NotificationGrant.notAsked, .notGranted] {
            let center = FakeNotificationCenter(status: grant)

            let outcome = await Self.make(center).post(Self.tea)

            #expect(outcome == .notAuthorized(grant))
            #expect(center.promptsRaised == 0)
            #expect(center.added.isEmpty)
            #expect(center.calls.isEmpty, "nothing reaches the framework but the grant read")
        }
    }

    @Test("a post carries the engine's title, body, sound and reminder at the default level, behind its Snooze category")
    func postCarriesWhatTheEngineRendered() async throws {
        let center = FakeNotificationCenter(status: .granted)

        let outcome = await Self.make(center).post(Self.tea)

        let request = try #require(center.added.first)
        #expect(outcome == .posted(notificationID: request.identifier))
        #expect(request.identifier.count <= NativeHostProtocol.maximumIdentifierChars)
        #expect(request.trigger == nil, "it rings now")
        #expect(request.content.title == "Tea")
        #expect(request.content.body == "Tea, today at 16:05 (in 10 minutes).")
        #expect(request.content.sound == .default)
        #expect(request.content.interruptionLevel == .active, "decision D9: nothing breaks through Focus")
        #expect(request.content.userInfo[MacNotifications.reminderIDKey] as? String == "rem_8Kf2xQ1vT0w")

        let category = try #require(center.registered.first { $0.identifier == request.content.categoryIdentifier })
        #expect(category.actions.map(\.identifier) == ["snooze_10m"])
        #expect(category.actions.map(\.title) == ["Snooze 10 minutes"])
        #expect(category.actions.first?.options == [], "a press never opens the app or asks for a password")
        #expect(center.calls == ["categories", "setCategories", "categories", "add"], "the post goes out behind its category")
    }

    @Test("a post with no buttons names no category and no reminder, and a silent one plays nothing")
    func postWithoutButtons() async throws {
        let center = FakeNotificationCenter(status: .granted)
        let laundry = MacNotification(title: "Laundry", body: "Laundry, today at 18:30.", sound: false, reminderID: nil, actions: [])

        _ = await Self.make(center).post(laundry)

        let request = try #require(center.added.first)
        #expect(request.content.sound == nil)
        #expect(request.content.categoryIdentifier.isEmpty)
        #expect(request.content.userInfo.isEmpty)
        #expect(center.calls == ["add"])
    }

    @Test("posts with the same buttons share one category, and a registered one is kept beside a new one")
    func categoriesAreRegisteredOnce() async throws {
        let center = FakeNotificationCenter(status: .granted)
        let notifications = Self.make(center)
        let other = MacNotification(
            title: "Tea", body: "Tea.", sound: true, reminderID: "rem_2",
            actions: [MacNotificationAction(id: .snooze10m, title: "Snooze")]
        )

        _ = await notifications.post(Self.tea)
        _ = await notifications.post(Self.tea)
        _ = await notifications.post(other)

        #expect(center.calls.filter { $0 == "setCategories" }.count == 2)
        #expect(center.registered.count == 2)
        #expect(center.added.count == 3)
    }

    @Test("the framework's refusal is answered in its own words")
    func frameworkRefusalKeepsItsWords() async {
        let center = FakeNotificationCenter(status: .granted)
        center.addFailure = FrameworkRefusal(words: "The notification could not be scheduled")

        let outcome = await Self.make(center).post(Self.tea)

        #expect(outcome == .failed("The notification could not be scheduled"))
    }

    // MARK: - The person's answers

    @Test("a press on Snooze names its reminder, and a click on the notification brings the app forward")
    func responsesBecomePressesAndOpens() {
        let center = FakeNotificationCenter(status: .granted)
        let notifications = Self.make(center)
        var presses: [NotificationPress] = []
        var opened = 0
        notifications.onPress = { presses.append($0) }
        notifications.onOpened = { opened += 1 }

        center.deliver(NotificationResponse(actionIdentifier: "snooze_10m", reminderID: "rem_8Kf2xQ1vT0w"))
        center.deliver(NotificationResponse(actionIdentifier: UNNotificationDefaultActionIdentifier, reminderID: "rem_8Kf2xQ1vT0w"))
        // Nobody's: a button this build never posted, a press with no
        // reminder, and a dismissal this build never asked to hear.
        center.deliver(NotificationResponse(actionIdentifier: "snooze_1h", reminderID: "rem_8Kf2xQ1vT0w"))
        center.deliver(NotificationResponse(actionIdentifier: "snooze_10m", reminderID: nil))
        center.deliver(NotificationResponse(actionIdentifier: UNNotificationDismissActionIdentifier, reminderID: "rem_8Kf2xQ1vT0w"))

        #expect(presses == [NotificationPress(reminderID: "rem_8Kf2xQ1vT0w", action: .snooze10m)])
        #expect(opened == 1)
    }

    // MARK: - Reading the grant again

    @Test("a return to the app reads the grant again and publishes only a change")
    func activationReadsTheGrantAgain() async {
        let center = FakeNotificationCenter(status: .granted)
        let activations = NotificationCenter()
        let notifications = MacNotifications(center: center, bundleIdentifier: Self.bundleIdentifier, activations: activations)
        var changes: [NotificationGrant] = []
        let watching = notifications.grantChanged.sink { changes.append($0) }
        await notifications.refresh()

        center.status = .notGranted
        activations.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        #expect(await yieldUntil { notifications.grant == .notGranted })

        let reads = center.grantReads
        activations.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        #expect(await yieldUntil { center.grantReads > reads })

        #expect(changes == [.granted, .notGranted])
        watching.cancel()
    }

    // MARK: - Mechanics

    static let bundleIdentifier = "io.tezra.FermixPet.test"

    static let tea = MacNotification(
        title: "Tea",
        body: "Tea, today at 16:05 (in 10 minutes).",
        sound: true,
        reminderID: "rem_8Kf2xQ1vT0w",
        actions: [MacNotificationAction(id: .snooze10m, title: "Snooze 10 minutes")]
    )

    /// Over a private activation center, so nothing outside the case can
    /// make it read the grant.
    static func make(_ center: FakeNotificationCenter) -> MacNotifications {
        MacNotifications(center: center, bundleIdentifier: bundleIdentifier, activations: NotificationCenter())
    }
}
