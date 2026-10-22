import FermixAppCore
import Foundation
import Sparkle

/// Everything Sparkle shows, handed to the app's own update window.
///
/// Sparkle's standard driver draws its own windows: the application icon on a
/// tile of its own, a saturated blue default button and progress bar, and
/// English this product did not write, with exclamation marks and dashes the
/// copy rules refuse. A user driver is Sparkle's one seam for its interface,
/// so this is that seam and nothing more: each callback is translated into an
/// `UpdatePrompt` call and each answer sent back as Sparkle's type. It decides
/// nothing, as `SparkleUpdaterDelegate` decides nothing; what the window says
/// is `UpdateWindowContent`'s, and whether an update may happen at all is the
/// coordinator's.
///
/// Sparkle calls every method on the main thread (`NS_SWIFT_UI_ACTOR`).
@MainActor
final class SparkleUserDriver: NSObject, SPUUserDriver {
    private let prompt: UpdatePrompt

    init(prompt: UpdatePrompt) {
        self.prompt = prompt
    }

    // MARK: - Permission and checking

    /// The system profile is never sent: the feed is a static file, and what
    /// it could learn from a profile it has no use for.
    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        prompt.askPermission { allowed in
            reply(SUUpdatePermissionResponse(automaticUpdateChecks: allowed, sendSystemProfile: false))
        }
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        prompt.showChecking(cancel: cancellation)
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        let offer = UpdatePromptOffer(
            version: appcastItem.displayVersionString,
            isCritical: appcastItem.isCriticalUpdate,
            isInformationOnly: appcastItem.isInformationOnlyUpdate,
            infoURL: appcastItem.infoURL,
            stage: SparkleAppcast.stage(state.stage)
        )

        prompt.offer(offer, userInitiated: state.userInitiated) { choice in
            reply(Self.choice(choice))
        }
    }

    /// The feed links no release notes, so Sparkle never calls these two; an
    /// item that did would still be offered, with the window's own sentence.
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}

    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        prompt.showNotFound(Self.reason(error), acknowledge: acknowledgement)
    }

    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        prompt.showFailure(Self.failure(error), acknowledge: acknowledgement)
    }

    // MARK: - Download, extraction and installation

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        prompt.showDownloading(cancel: cancellation)
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        prompt.downloadExpected(expectedContentLength)
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        prompt.downloadReceived(length)
    }

    func showDownloadDidStartExtractingUpdate() {
        prompt.showPreparing()
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        prompt.preparingProgress(progress)
    }

    /// The standard driver's only answer here is install: the ready window has
    /// one button, and quitting from behind it installs the update anyway.
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        prompt.showReady { reply(.install) }
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        if applicationTerminated {
            prompt.showInstalling()
        } else {
            prompt.parkRelaunch(retry: retryTerminatingApplication)
        }
    }

    /// A relaunched app is its own announcement; only an install the system
    /// did not relaunch says so in a window.
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        guard !relaunched else {
            prompt.dismiss()
            acknowledgement()
            return
        }

        prompt.showInstalled(acknowledge: acknowledgement)
    }

    func showUpdateInFocus() {
        prompt.bringForward()
    }

    func dismissUpdateInstallation() {
        prompt.dismiss()
    }

    // MARK: - Translation

    private static func choice(_ choice: UpdateUserChoice) -> SPUUserUpdateChoice {
        switch choice {
        case .install: return .install
        case .dismiss: return .dismiss
        case .skip: return .skip
        }
    }

    private static func reason(_ error: any Error) -> UpdateNotFoundReason {
        let raw = (error as NSError).userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber

        switch raw.flatMap({ SPUNoUpdateFoundReason(rawValue: $0.int32Value) }) {
        case .onLatestVersion: return .onLatest
        case .onNewerThanLatestVersion: return .newerThanLatest
        case .systemIsTooOld: return .systemTooOld
        case .systemIsTooNew: return .systemTooNew
        case .hardwareDoesNotSupportARM64: return .hardwareUnsupported
        case .unknown, .none: return .unknown
        @unknown default: return .unknown
        }
    }

    /// Sparkle's codes, grouped by what a person can do about them. A check
    /// the coordinator refused comes back as its own error, through the
    /// delegate's throwing gates.
    private static func failure(_ error: any Error) -> UpdateFailure {
        if let refusal = error as? UpdateRefusal { return UpdateFailure(refusal) }

        let failure = error as NSError
        guard failure.domain == SUSparkleErrorDomain else { return .other }

        switch failure.code {
        case Int(SUError.appcastParseError.rawValue), Int(SUError.appcastError.rawValue):
            return .feedUnreachable
        case Int(SUError.downloadError.rawValue), Int(SUError.temporaryDirectoryError.rawValue):
            return .downloadFailed
        case Int(SUError.signatureError.rawValue), Int(SUError.validationError.rawValue),
             Int(SUError.insufficientSigningError.rawValue):
            return .notVerified
        case Int(SUError.unarchivingError.rawValue), Int(SUError.fileCopyFailure.rawValue),
             Int(SUError.installationError.rawValue), Int(SUError.missingInstallerToolError.rawValue),
             Int(SUError.installationWriteNoPermissionError.rawValue), Int(SUError.relaunchError.rawValue):
            return .installFailed
        default:
            return .other
        }
    }
}
