import Foundation

/// What Recovery says about an update that did not finish (M34 §6, R4).
///
/// It is built from the record alone, so the screen opens with no daemon, no
/// feed and no network. The one thing on it that needs a connection says so.
public struct UpdateRecoveryPresentation: Equatable, Sendable {
    /// Why the update could not be finished, in one sentence.
    public let sentence: String
    /// The two sides of the update, where a record named them.
    public let versions: String?
    /// The installer the previous version came from, named exactly.
    public let installerSentence: String?
    /// Where that installer is. Absent where the record named no address this
    /// app will hand to a browser.
    public let reinstallURL: URL?
    /// Everything else the screen has to say, in the order it says it.
    public let notices: [String]

    public init(report: UpdateRecoveryReport) {
        sentence = ProductStrings[Self.key(for: report.reason)]
        versions = report.source.map { source in
            String(
                format: ProductStrings[.updateRecoveryVersionsFormat],
                source.app.marketingVersion,
                report.target?.app.marketingVersion ?? source.app.marketingVersion
            )
        }
        installerSentence = report.priorInstaller.map { installer in
            String(
                format: ProductStrings[.updateRecoveryInstallerFormat],
                installer.version,
                installer.signingIdentity
            )
        }
        reinstallURL = report.priorInstaller.flatMap(Self.reinstallURL)
        notices = Self.notices(for: report)
    }

    /// The address the reinstall action opens.
    ///
    /// Only an `https` address: the record is written by this app, and handing
    /// anything else to the browser on the strength of a file read after a
    /// crash is not a promise this screen makes.
    private static func reinstallURL(_ installer: UpdateInstaller) -> URL? {
        guard let url = URL(string: installer.url), url.scheme == "https" else { return nil }

        return url
    }

    /// The lines under the sentence, most consequential first: a mutation that
    /// did not happen, then what going back would cost, then what it needs.
    private static func notices(for report: UpdateRecoveryReport) -> [String] {
        var lines: [String] = []

        if report.disableRefused { lines.append(ProductStrings[.updateRecoveryDisableRefused]) }
        guard report.priorInstaller != nil else { return lines }

        if !report.rollbackSupported { lines.append(ProductStrings[.updateRecoveryRollbackUnsafe]) }
        lines.append(ProductStrings[.updateRecoveryNeedsNetwork])

        return lines
    }

    /// One sentence per reason, in a closed switch: a reason added later has to
    /// be given copy rather than reaching the operator as the name of an enum
    /// case.
    private static func key(for reason: UpdateRecoveryReason) -> ProductStringKey {
        switch reason {
        case .reconcileInterrupted: return .updateRecoveryInterrupted
        case .journalUnusable: return .updateRecoveryJournalUnusable
        case .unexpectedApp: return .updateRecoveryUnexpectedApp
        case .unexpectedEngine: return .updateRecoveryUnexpectedEngine
        case .engineNotStopped: return .updateRecoveryEngineNotStopped
        case .sourceEngineUnverified: return .updateRecoverySourceUnverified
        case .targetEngineUnverified: return .updateRecoveryTargetUnverified
        case .registrationNotRestored: return .updateRecoveryRegistrationNotRestored
        case .conflictingRegistration: return .updateRecoveryConflictingRegistration
        case .registrationNeedsApproval: return .updateRecoveryRegistrationNeedsApproval
        case .noSharedProtocol: return .updateRecoveryNoSharedProtocol
        }
    }
}
