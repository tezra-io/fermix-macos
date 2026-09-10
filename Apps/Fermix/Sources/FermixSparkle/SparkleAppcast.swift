import FermixAppCore
import Foundation
import Sparkle

/// Reading Sparkle's own values into the app's vocabulary.
///
/// One direction only: nothing here decides anything, so every rule about what
/// an entry means lives in `FermixAppCore` where it can be proved.
enum SparkleAppcast {
    /// One appcast item, as the update transaction reads it.
    ///
    /// The four Fermix elements come out of `propertiesDictionary`, which is
    /// the whole parsed item and the documented way to reach a custom element.
    /// They are required rather than optional: the engine build is what the
    /// launch reconcile compares the arriving bundle against, and the artifact
    /// facts are the only copy of what Recovery would reinstall.
    static func entry(_ item: SUAppcastItem) -> UpdateFeedEntry {
        UpdateFeedEntry(
            displayVersion: item.displayVersionString,
            versionString: item.versionString,
            isCritical: item.isCriticalUpdate,
            isInformationOnly: item.isInformationOnlyUpdate,
            enclosureURL: item.fileURL?.absoluteString,
            elements: elements(item.propertiesDictionary)
        )
    }

    static func entries(_ appcast: SUAppcast) -> [UpdateFeedEntry] {
        appcast.items.map(entry)
    }

    /// The Fermix elements, as strings. A value the feed wrote as something
    /// other than text is left out rather than coerced: an element that cannot
    /// be read is missing, and the reader refuses on that.
    private static func elements(_ properties: [AnyHashable: Any]) -> [String: String] {
        var found: [String: String] = [:]

        for name in UpdateFeedElement.required {
            guard let value = properties[name] as? String else { continue }

            found[name] = value
        }

        return found
    }

    /// How one update cycle ended (M34 §6, R2).
    ///
    /// The benign codes are the ones that mean the person answered or the feed
    /// simply had nothing: they are a completed check, not a failed one. Every
    /// other code is a check that did not complete, and a check that did not
    /// complete is never rendered as up to date.
    static func outcome(_ error: (any Error)?) -> UpdateCycleOutcome {
        guard let error else { return .completed }

        let failure = error as NSError
        guard failure.domain == SUSparkleErrorDomain else {
            return .failed(failure.localizedDescription)
        }

        switch failure.code {
        case Int(SUError.noUpdateError.rawValue):
            return .completed
        case Int(SUError.installationCanceledError.rawValue),
             Int(SUError.installationAuthorizeLaterError.rawValue):
            return .dismissed
        default:
            return .failed(failure.localizedDescription)
        }
    }

    static func choice(_ choice: SPUUserUpdateChoice) -> UpdateUserChoice {
        switch choice {
        case .install: return .install
        case .skip: return .skip
        case .dismiss: return .dismiss
        @unknown default: return .dismiss
        }
    }

    static func stage(_ stage: SPUUserUpdateStage) -> UpdateUserStage {
        switch stage {
        case .notDownloaded: return .notDownloaded
        case .downloaded: return .downloaded
        case .installing: return .installing
        @unknown default: return .installing
        }
    }
}
