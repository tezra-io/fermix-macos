import Foundation

/// What the app says about a lifecycle transaction it started.
///
/// One wording per transaction, read by the toolbar's status sentence, Home's
/// Status row and the status item's state line, so the three cannot describe
/// one restart three ways (owner report of 2026-09-20: after `Restart now` the
/// sheet closed and nothing said a restart was running until it was over).
///
/// Every sentence here is about the app's own transaction, which is the only
/// reason the app may say it. The daemon is away for most of a restart and
/// publishes nothing about one, so none of this re-derives a state it reports:
/// the moment the transaction ends, every surface is back on the daemon's own
/// answers.
public enum LifecycleActivity {
    /// The sentence every surface shows while the transaction runs. The service
    /// wording stays enable and disable, never start or stop (M34 §4).
    public static func sentence(for kind: LifecycleTransactionKind) -> String {
        switch kind {
        case .restart: return ProductStrings[.lifecycleRestarting]
        case .enable: return ProductStrings[.lifecycleEnabling]
        case .disable: return ProductStrings[.lifecycleDisabling]
        }
    }

    /// What VoiceOver is told once the transaction has worked. The sentence on
    /// screen goes away without moving focus, so its end is spoken.
    public static func completion(of outcome: LifecycleOutcome) -> String {
        switch outcome {
        case .restarted: return ProductStrings[.lifecycleRestarted]
        case .enabled: return ProductStrings[.lifecycleEnabled]
        case .disabled: return ProductStrings[.lifecycleDisabled]
        }
    }

    /// The window toolbar's status sentence, or nil where it draws none.
    ///
    /// The Setup Assistant states its own restart as a ladder row with its own
    /// indicator (redlines §5.2), so the toolbar says nothing over it: progress
    /// belongs at the point of action, once.
    public static func toolbarSentence(
        for kind: LifecycleTransactionKind?,
        on route: AppRoute
    ) -> String? {
        guard let kind, route != .setup, route != .recovery else { return nil }

        return sentence(for: kind)
    }
}
