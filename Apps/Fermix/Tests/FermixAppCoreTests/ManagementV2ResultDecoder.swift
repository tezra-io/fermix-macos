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
        case .imessagePermissionsGet:
            try read(ManagementIMessagePermissions.self, payload, identifier, method)
        case .mobileStatus:
            try read(ManagementMobileStatus.self, payload, identifier, method)
        case .mobilePairStart:
            try read(ManagementPairingStart.self, payload, identifier, method)
        case .mobilePairGet, .mobilePairDecide, .mobilePairCancel:
            try read(ManagementPairingSession.self, payload, identifier, method)
        case .mobileDevicesList:
            try read(ManagementMobileDevices.self, payload, identifier, method)
        case .mobileDevicesRevoke:
            try read(ManagementMobileDeviceRevoked.self, payload, identifier, method)
        case .mcpServersList:
            try read(ManagementMCPServerList.self, payload, identifier, method)
        case .mcpServersDraft:
            try read(ManagementMCPDrafts.self, payload, identifier, method)
        case .mcpServersImportScan:
            try read(ManagementMCPImportScan.self, payload, identifier, method)
        case .mcpServersImport:
            try read(ManagementMCPImported.self, payload, identifier, method)
        case .mcpServersGet, .mcpServersUpdate, .mcpServersEnable, .mcpServersDisable, .mcpServersToolSet:
            try read(ManagementMCPServerRow.self, payload, identifier, method)
        case .mcpServersAdd:
            try read(ManagementMCPServerAdded.self, payload, identifier, method)
        case .mcpServersRemove:
            try read(ManagementMCPServerRemoved.self, payload, identifier, method)
        case .cuesStatus:
            try read(ManagementCueStatus.self, payload, identifier, method)
        case .cuesSourcesList:
            try read(ManagementCueSourceList.self, payload, identifier, method)
        case .cuesSourcesGet:
            try read(ManagementCueSourceDetail.self, payload, identifier, method)
        case .cuesSourcesForm:
            try read(ManagementCueSourceForm.self, payload, identifier, method)
        case .cuesSourcesAdd:
            try read(ManagementCueSourceAdded.self, payload, identifier, method)
        case .cuesSourcesUpdate, .cuesSourcesEnable, .cuesSourcesDisable:
            try read(ManagementCueSourceAnswer.self, payload, identifier, method)
        case .cuesSourcesRemove:
            try read(ManagementCueSourceRemoved.self, payload, identifier, method)
        case .cuesSourcesTokenNew:
            try read(ManagementCueSourceToken.self, payload, identifier, method)
        case .cuesSourcesURLGet:
            try read(ManagementCueSourceAddress.self, payload, identifier, method)
        case .cuesWatchersList:
            try read(ManagementCueWatcherList.self, payload, identifier, method)
        case .cuesWatchersGet:
            try read(ManagementCueWatcherAnswer.self, payload, identifier, method)
        case .cuesMandatesList:
            try read(ManagementCueMandateList.self, payload, identifier, method)
        case .cuesMandatesChoices:
            try read(ManagementCueMandateChoices.self, payload, identifier, method)
        case .cuesMandatesAdd, .cuesMandatesUpdate, .cuesMandatesEnable, .cuesMandatesDisable, .cuesMandatesApprove:
            try read(ManagementCueMandateAnswer.self, payload, identifier, method)
        case .cuesMandatesRemove:
            try read(ManagementCueMandateRemoved.self, payload, identifier, method)
        case .cuesProposalsList:
            try read(ManagementCueProposalList.self, payload, identifier, method)
        case .cuesProposalsGet:
            try read(ManagementCueProposalCardAnswer.self, payload, identifier, method)
        case .cuesProposalsDecide:
            try read(ManagementCueProposalAnswer.self, payload, identifier, method)
        case .homeStatus:
            try read(ManagementHomeStatus.self, payload, identifier, method)
        case .homeEnrollOpen:
            try read(ManagementEnrollmentCode.self, payload, identifier, method)
        case .homeCandidatesList:
            try read(ManagementCandidates.self, payload, identifier, method)
        case .homeMoveReadiness:
            try read(ManagementMoveReadiness.self, payload, identifier, method)
        case .homeMoveStart:
            try read(ManagementMoveStarted.self, payload, identifier, method)
        case .homeSnapshotsStatus:
            try read(ManagementHomeSnapshots.self, payload, identifier, method)
        case .homeSnapshotsRun:
            try read(ManagementSnapshotsStarted.self, payload, identifier, method)
        case .homeSnapshotsPassphrase:
            try read(ManagementRecoveryKey.self, payload, identifier, method)

        // Every remaining method answers the uniform job view.
        case .providersProbeStart, .jobGet, .jobCancel, .authImportStart, .pluginsInstallStart,
             .pluginsCheckStart, .pluginsWorkspacesDiscoverStart, .pluginsWorkspaceSelectStart,
             .capabilitiesInstallStart, .meetingsSigninStart, .computerUseGrantStart,
             .browserInstallStart, .imessageGrantStart, .imessagePolicyConfirm, .mcpServersCheckStart:
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
