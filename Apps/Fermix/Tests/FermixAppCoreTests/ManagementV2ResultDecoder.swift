import Foundation

@testable import FermixAppCore

/// Decodes a response envelope into the result type its method owes.
///
/// The switch is exhaustive on purpose: a method added to `ManagementMethod`
/// without a typed result fails to compile here, which is the only place that
/// pairing is written down once for every method rather than per call site.
enum ManagementV2ResultDecoder {
    static func decode(method: ManagementMethod, payload: Data, identifier: String) throws {
        switch method {
        case .hello:
            try read(ManagementHello.self, payload, identifier, method)
        case .overviewGet:
            try read(ManagementOverview.self, payload, identifier, method)
        case .setupSessionCreate:
            try read(ManagementSetupSession.self, payload, identifier, method)
        case .doctorStart, .doctorGet, .doctorCancel:
            try read(ManagementDoctorSession.self, payload, identifier, method)
        case .logsQuery:
            try read(ManagementLogPage.self, payload, identifier, method)
        case .lifecyclePrepare:
            try read(ManagementLifecyclePrepared.self, payload, identifier, method)
        case .lifecycleCommit, .lifecycleCancel:
            try read(ManagementLifecycleTransition.self, payload, identifier, method)
        case .diagnosticsBuild:
            try read(ManagementDiagnostics.self, payload, identifier, method)

        case .setupStateGet:
            try read(ManagementSetupState.self, payload, identifier, method)
        case .setupDetect:
            try read(ManagementDetections.self, payload, identifier, method)
        case .settingsSections:
            try read(ManagementSettingsInventory.self, payload, identifier, method)
        case .settingsGet:
            try read(ManagementSettingsSectionRows.self, payload, identifier, method)
        case .settingsApply:
            try read(ManagementSettingsApplied.self, payload, identifier, method)
        case .settingsReload:
            try read(ManagementSettingsReloaded.self, payload, identifier, method)
        case .secretSet, .secretClear:
            try read(ManagementSecretState.self, payload, identifier, method)
        case .providersSetPrimary:
            try read(ManagementPrimaryProviderResult.self, payload, identifier, method)
        case .providersModelsList:
            try read(ManagementProviderModels.self, payload, identifier, method)
        case .authStart:
            try read(ManagementAuthStart.self, payload, identifier, method)
        case .authLogout:
            try read(ManagementRestartOnly.self, payload, identifier, method)
        case .jobList:
            try read(ManagementJobList.self, payload, identifier, method)
        case .pluginsList:
            try read(ManagementPluginCatalog.self, payload, identifier, method)
        case .pluginsEnable, .pluginsDisable, .pluginsDisconnect, .pluginsSettingSet:
            try read(ManagementPluginRow.self, payload, identifier, method)
        case .pluginsOAuthClientSet:
            try read(ManagementPluginOAuthClientRow.self, payload, identifier, method)
        case .computerUsePermissionsGet:
            try read(ManagementComputerUsePermissions.self, payload, identifier, method)

        // Every remaining method answers the uniform job view.
        case .providersProbeStart, .jobGet, .jobCancel, .authImportStart, .pluginsInstallStart,
             .pluginsCheckStart, .pluginsWorkspacesDiscoverStart, .pluginsWorkspaceSelectStart,
             .capabilitiesInstallStart, .meetingsSigninStart, .computerUseGrantStart:
            try read(ManagementJob.self, payload, identifier, method)
        }
    }

    private static func read<Result: Decodable>(
        _ type: Result.Type,
        _ payload: Data,
        _ identifier: String,
        _ method: ManagementMethod
    ) throws {
        _ = try ManagementResponse.decode(
            payload,
            expecting: identifier,
            method: method,
            as: Result.self
        )
    }
}
