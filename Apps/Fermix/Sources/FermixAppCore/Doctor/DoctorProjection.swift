import Foundation

/// What a check row's one action does.
///
/// Only what this build performs is minted. A remediation whose action is a
/// sheet of commands carries none: the row still shows the daemon's remediation
/// title, which says what to do, and a button that opened nothing would be
/// worse than that sentence.
public enum DoctorRowAction: Equatable, Sendable {
    /// A System Settings pane, by the identifier the daemon named.
    case openSystemSettings(String)
    /// A Fermix settings pane, which decision D1 made a surface of this same
    /// window. It reads the same title as an Attention row's deep link, so the
    /// two doors into one pane cannot be spelled differently.
    case openSettings(SettingsPane)
    /// The sheet of commands for a gap answered outside Fermix, by the
    /// catalogue entry the daemon named. The same sheet Home's Attention row
    /// opens (M34 §15.2).
    case showInstructions(String)
    /// The one Restart sheet, which the coordinator owns. The daemon asks for a
    /// restart; how much work one interrupts and when to take it stays the
    /// sheet's (M34 §5.10).
    case restartDaemon
    /// `settings.reload`: read the settings file again, which is what lifts the
    /// external-change refusal.
    case reloadSettings
    /// The Recovery screen, which is where an unreadable settings file is
    /// answered. A reload here would re-run the read that just failed.
    case openRecovery

    public var title: String {
        switch self {
        case .openSystemSettings: return ProductStrings[.doctorActionSystemSettings]
        case .openSettings(let pane):
            return String(format: ProductStrings[.settingsOpenPaneFormat], pane.title)
        case .showInstructions: return ProductStrings[.attentionActionShowInstructions]
        case .restartDaemon: return ProductStrings[.attentionActionRestart]
        case .reloadSettings: return ProductStrings[.attentionActionReload]
        case .openRecovery: return ProductStrings[.settingsConfigUnreadableAction]
        }
    }
}

/// One Doctor check, as the list draws it.
public struct DoctorRowModel: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let detail: String
    /// The daemon's own remediation title and body, where protocol v2 carried
    /// one. The body is what says how, and dropping it left the row with a
    /// title and nothing under it.
    public let remediationTitle: String?
    public let remediationBody: String?
    public let action: DoctorRowAction?
    public let badge: CheckBadge
    public let status: ManagementCheckStatus

    public init(
        id: String,
        title: String,
        detail: String,
        remediationTitle: String? = nil,
        remediationBody: String? = nil,
        action: DoctorRowAction? = nil,
        badge: CheckBadge,
        status: ManagementCheckStatus
    ) {
        precondition(!id.isEmpty, "a check row needs an identifier")
        precondition(!title.isEmpty, "a check row needs a title")

        self.id = id
        self.title = title
        self.detail = detail
        self.remediationTitle = remediationTitle
        self.remediationBody = remediationBody
        self.action = action
        self.badge = badge
        self.status = status
    }

    public var accessibilityLabel: String { title }

    /// The status word, the summary, and the remediation read as one value, so
    /// VoiceOver leaves neither the finding nor the fix unspoken.
    public var accessibilityValue: String {
        [detail, remediationTitle ?? "", remediationBody ?? ""]
            .filter { !$0.isEmpty }
            .reduce(badge.letters) { ProductStrings.commaPair($0, $1) }
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
                title: checkName(check.id),
                detail: check.summary,
                remediationTitle: check.remediation?.title,
                remediationBody: check.remediation?.body,
                action: action(for: check),
                badge: CheckBadge.forStatus(check.status),
                status: check.status
            )
        }
    }

    /// The one action a row offers.
    ///
    /// The kinds are the daemon's closed set; the coverage is this build's, and
    /// every kind the engine's remediation table emits resolves to a surface
    /// this app owns. `job` does not: the table publishes no job remediation,
    /// and a button that started one would have to guess which job from a
    /// free-form target. A kind or a target this build cannot place carries no
    /// button rather than landing on a neighbour — the row still shows the
    /// daemon's own remediation title and body, which say what to do.
    static func action(for check: ManagementDoctorCheck) -> DoctorRowAction? {
        guard let remediation = check.remediation else { return nil }

        switch remediation.action.kind {
        case .systemSettings:
            guard let target = remediation.action.target, !target.isEmpty else { return nil }

            return .openSystemSettings(target)
        case .settingsPane:
            guard let target = remediation.action.target,
                  let pane = SettingsPane(rawValue: target)
            else { return nil }

            return .openSettings(pane)
        case .restart:
            return .restartDaemon
        case .reload:
            return .reloadSettings
        case .instructions:
            return instructions(remediation.action.target)
        // No remediation the engine publishes is a job, and a job is not
        // startable from a bare target: `job.*` addresses a run that already
        // exists and every start verb has its own method and parameters.
        case .job, .none, .unrecognized:
            return nil
        }
    }

    /// The two catalogue entries an `instructions` remediation can name. One is
    /// the sheet of removal commands; the other is the Recovery screen, which is
    /// where an unreadable settings file is answered.
    private static func instructions(_ target: String?) -> DoctorRowAction? {
        switch target {
        case CoexistenceInstructions.legacyServiceUnitRemoval:
            return .showInstructions(CoexistenceInstructions.legacyServiceUnitRemoval)
        case Self.externalConfigChangeRecovery:
            return .openRecovery
        default:
            return nil
        }
    }

    /// The engine's catalogue id for the unreadable-settings recovery, which is
    /// the app's Recovery screen (M34 §7.5).
    static let externalConfigChangeRecovery = "external_config_change.recovery"

    /// The check's name, from its id. The daemon publishes single snake_case
    /// words (`fallback_providers`, `auth_token_expiry`) and writes each
    /// summary to sit beside that name, so the name is the id with its
    /// underscores opened and its first letter raised: one transform for every
    /// row, so a check this build has never seen still has a name.
    static func checkName(_ id: String) -> String {
        let words = id.replacingOccurrences(of: "_", with: " ")

        return words.prefix(1).uppercased() + words.dropFirst()
    }

    public static func banner(for session: ManagementDoctorSession) -> DoctorBanner {
        let summary = session.summary
        let tone: StatusTone
        let title: String

        if summary.failed == 1 {
            tone = .fail
            title = ProductStrings[.doctorBannerFailingOne]
        } else if summary.failed > 1 {
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
}
