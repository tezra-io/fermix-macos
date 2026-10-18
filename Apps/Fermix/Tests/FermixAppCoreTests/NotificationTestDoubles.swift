import Foundation
import UserNotifications

@testable import FermixAppCore

/// A notification center a test scripts and reads back. No framework center,
/// no grant on this Mac read or changed, nothing shown.
///
/// The prompt either answers at once with `promptAnswer`, or, where that is
/// nil, stays up until the case calls `answerPrompt(_:)`, which is what a
/// person who has not answered yet looks like.
@MainActor
final class FakeNotificationCenter: UserNotificationCentering {
    var responses: ((NotificationResponse) -> Void)?

    /// The grant the framework reports.
    var status: NotificationGrant
    /// What the person answers the prompt with; nil holds it up.
    var promptAnswer: NotificationGrant?
    /// What the framework says when it refuses a post.
    var addFailure: (any Error)?
    /// What the framework throws on the next prompt request, before any
    /// prompt shows.
    var promptFailure: (any Error)?
    /// The categories the framework has registered.
    private(set) var registered: Set<UNNotificationCategory> = []

    /// Every request for the prompt that reached the framework, shown or not.
    private(set) var promptsRaised = 0
    private(set) var grantReads = 0
    private(set) var added: [UNNotificationRequest] = []
    /// Every call that reached the framework that registers or posts, in
    /// order, so a case can say the post went out behind its category.
    private(set) var calls: [String] = []
    /// Every prompt raised and not yet answered. More than one is the defect
    /// a case is looking for, and each is held so the case fails on the count
    /// rather than hanging on a prompt nobody answers.
    private var heldPrompts: [CheckedContinuation<Bool, Never>] = []

    init(status: NotificationGrant = .notAsked, promptAnswer: NotificationGrant? = .granted) {
        self.status = status
        self.promptAnswer = promptAnswer
    }

    func grant() async -> NotificationGrant {
        grantReads += 1
        return status
    }

    func requestAlertsWithSound() async throws -> Bool {
        promptsRaised += 1
        if let failure = promptFailure {
            promptFailure = nil
            throw failure
        }
        guard let answer = promptAnswer else {
            return await withCheckedContinuation { heldPrompts.append($0) }
        }

        status = answer
        return answer == .granted
    }

    /// The person answers every prompt that was held up.
    func answerPrompt(_ answer: NotificationGrant) {
        status = answer
        let held = heldPrompts
        heldPrompts = []
        for prompt in held {
            prompt.resume(returning: answer == .granted)
        }
    }

    var promptIsUp: Bool { !heldPrompts.isEmpty }

    func categories() async -> Set<UNNotificationCategory> {
        calls.append("categories")
        return registered
    }

    func setCategories(_ categories: Set<UNNotificationCategory>) {
        calls.append("setCategories")
        registered = categories
    }

    func add(_ request: UNNotificationRequest) async throws {
        calls.append("add")
        if let addFailure { throw addFailure }
        added.append(request)
    }

    /// The person did something with a notification.
    func deliver(_ response: NotificationResponse) {
        responses?(response)
    }
}

/// A framework refusal, in words of its own.
struct FrameworkRefusal: LocalizedError {
    let words: String
    var errorDescription: String? { words }
}
