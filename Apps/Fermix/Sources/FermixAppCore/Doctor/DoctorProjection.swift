import Foundation

/// One Doctor check, as the list draws it.
public struct DoctorRowModel: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let fixHint: String?
    public let badge: CheckBadge
    public let status: ManagementCheckStatus

    public init(id: String, title: String, fixHint: String?, badge: CheckBadge, status: ManagementCheckStatus) {
        precondition(!id.isEmpty, "a check row needs an identifier")
        precondition(!title.isEmpty, "a check row needs a title")

        self.id = id
        self.title = title
        self.fixHint = fixHint
        self.badge = badge
        self.status = status
    }

    public var accessibilityLabel: String { title }

    /// The status word and the fix hint read as one value, so VoiceOver does not
    /// leave the remediation unspoken.
    public var accessibilityValue: String {
        guard let fixHint, !fixHint.isEmpty else { return badge.letters }

        return ProductStrings.commaPair(badge.letters, fixHint)
    }
}

/// The summary banner: what the run found, and where the answers came from.
public struct DoctorBanner: Equatable, Sendable {
    public let title: String
    public let explainer: String
    public let tone: StatusTone
    public let checkedLabel: String
}

/// Turning a typed Doctor session into rows and a banner.
///
/// Nothing here re-derives what a check means: the daemon already decided the
/// status, the severity, and the remediation, and this only decides how they
/// read. A status this build has never seen keeps its own wire value.
public enum DoctorProjection {
    public static func rows(for session: ManagementDoctorSession) -> [DoctorRowModel] {
        session.checks.map { check in
            DoctorRowModel(
                id: check.id,
                title: check.summary.isEmpty ? check.id : check.summary,
                fixHint: fixHint(for: check),
                badge: CheckBadge.forStatus(check.status),
                status: check.status
            )
        }
    }

    public static func banner(for session: ManagementDoctorSession) -> DoctorBanner {
        let summary = session.summary
        let tone: StatusTone
        let title: String

        if summary.failed > 0 {
            tone = .fail
            title = String(format: ProductStrings[.doctorBannerFailingFormat], summary.failed)
        } else if summary.warning == 1 {
            tone = .warn
            title = ProductStrings[.doctorBannerHealthyWithWarning]
        } else if summary.warning > 1 {
            tone = .warn
            title = String(format: ProductStrings[.doctorBannerWarningsFormat], summary.warning)
        } else {
            tone = .pass
            title = ProductStrings[.doctorBannerHealthy]
        }

        return DoctorBanner(
            title: title,
            explainer: ProductStrings[.doctorBannerExplainer],
            tone: tone,
            checkedLabel: ProductStrings[.doctorBannerCheckedJustNow]
        )
    }

    /// The daemon's remediation code, rendered as the imperative line the row
    /// carries. A check with no code carries no hint rather than an invented one.
    private static func fixHint(for check: ManagementDoctorCheck) -> String? {
        guard let code = check.remediationCode, !code.isEmpty else { return nil }

        return String(format: ProductStrings[.doctorFixHintFormat], code)
    }
}
