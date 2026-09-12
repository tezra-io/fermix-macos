import AppKit
import Foundation

/// Speaking a sentence to VoiceOver, behind a seam.
///
/// A live-region announcement is the one accessibility behavior that cannot be
/// read off a rendered view, so it is a call the product makes and a test can
/// see.
public protocol AccessibilityAnnouncing: Sendable {
    func announce(_ sentence: String)
}

/// The production announcer: a high-priority announcement on the key window,
/// which is what VoiceOver reads without moving focus.
public struct AppKitAccessibilityAnnouncer: AccessibilityAnnouncing {
    public init() {}

    public func announce(_ sentence: String) {
        guard !sentence.isEmpty else { return }

        MainActor.assumeIsolated {
            guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }

            NSAccessibility.post(
                element: window,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: sentence,
                    .priority: NSAccessibilityPriorityLevel.high.rawValue
                ]
            )
        }
    }
}

/// What VoiceOver is told when the activation ladder moves.
///
/// §5.2 and §9: focus stays on the window for the whole masked boot, so a row
/// that changed has to be spoken. Every sentence is the row's own label and its
/// own state word, which is exactly what a user landing on the row would hear.
public enum LadderAnnouncement {
    public static func sentences(
        from previous: ProgressLadderModel?,
        to current: ProgressLadderModel
    ) -> [String] {
        // The first draw is not a transition: every row is already readable, and
        // reading all three aloud would bury the one that is live.
        guard let previous else {
            return current.rows.filter { $0.state == .active }.map(sentence)
        }

        let before = Dictionary(uniqueKeysWithValues: previous.rows.map { ($0.id, $0.state) })

        return current.rows
            .filter { before[$0.id] != $0.state }
            .map(sentence)
    }

    private static func sentence(for row: LadderRowModel) -> String {
        ProductStrings.commaPair(row.accessibilityLabel, row.accessibilityValue)
    }
}
