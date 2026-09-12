import SwiftUI

/// Permissions: one row per right, with its principal named (M34 §5.9).
///
/// One consent never implies another, so the principal is on the row rather
/// than in a footnote. Nothing prompts on render: every row is read, and every
/// grant is a button.
struct PermissionsPane: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var permissions: PermissionLedger
    @StateObject private var grant: JobRunner

    init(model: SettingsModel) {
        self.model = model
        self.permissions = model.permissions
        _grant = StateObject(wrappedValue: model.makeJobRunner())
    }

    var body: some View {
        SettingsPaneForm(title: SettingsPane.permissions.title) {
            // This pane reads two protocol v2 sources — the helper's rights and
            // the keychain profile — so against an N-1 daemon it says so once
            // and draws only what this process can answer for itself.
            if model.requiresNewerEngine {
                NewerEngineSection(sentence: model.newerEngineSentence)
            }

            Section(ProductStrings[.permissionsRightsSection]) {
                ForEach(rights) { row in
                    PermissionRow(row: row, permissions: permissions, model: model, grant: grant)
                }
            }

            Section(ProductStrings[.permissionsFactsSection]) {
                Text(ProductStrings[.permissionsBrowserFact])
                    .fermixType(Typography.style(.calloutSmall))
                    .foregroundStyle(Palette.secondary.color)
                    .fixedSize(horizontal: false, vertical: true)

                if !model.requiresNewerEngine {
                    LabeledContent(ProductStrings[.permissionsKeychainProfile]) {
                        Text(profile)
                            .foregroundStyle(Palette.secondary.color)
                    }
                }
            }
        }
        .task { await model.refreshPermissions() }
    }

    private var rights: [PermissionRowModel] {
        PermissionVisibility.rights(permissions.rows, requiresNewerEngine: model.requiresNewerEngine)
    }

    /// The keychain namespace this home writes under, which the daemon reports.
    private var profile: String {
        model.setupState.value?.profile ?? ProductStrings[.permissionsProfileUnknown]
    }
}

/// One right: what it is, whose it is, where it stands, and the one thing to do.
///
/// Status is never colour alone: the state word carries it and VoiceOver reads
/// the principal beside it.
struct PermissionRow: View {
    let row: PermissionRowModel
    @ObservedObject var permissions: PermissionLedger
    @ObservedObject var model: SettingsModel
    @ObservedObject var grant: JobRunner

    var body: some View {
        LabeledContent {
            HStack(spacing: Spacing.xs) {
                Text(row.stateWord)
                    .foregroundStyle(row.state.tone.textColor.color)

                if let action = row.action {
                    Button(title(of: action)) { perform(action) }
                        .accessibilityLabel(ProductStrings.commaPair(title(of: action), row.title))
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                Text(row.principal)
                    .fermixType(Typography.style(.calloutSmall))
                    .foregroundStyle(Palette.secondary.color)
            }
            .accessibilityElement(children: .combine)
            .accessibilityValue(row.accessibilityValue)
        }
    }

    private func title(of action: PermissionAction) -> String {
        switch action {
        case .requestMicrophone: return ProductStrings[.permissionActionGrant]
        case .grantComputerUse: return ProductStrings[.permissionActionGrant]
        case .openSystemSettings: return ProductStrings[.permissionActionOpenSettings]
        case .openLoginItems: return ProductStrings[.permissionActionOpenLoginItems]
        }
    }

    /// Every branch is an explicit request the operator made. The microphone is
    /// the GUI's own right; the helper's two are the daemon's grant job; the
    /// rest are deep links into System Settings.
    private func perform(_ action: PermissionAction) {
        switch action {
        case .requestMicrophone:
            Task { await requestMicrophone() }
        case .grantComputerUse:
            Task { await model.startComputerUseGrant(on: grant) }
        case .openSystemSettings(let pane):
            open(pane)
        case .openLoginItems:
            open(PermissionLedger.loginItemsPane)
        }
    }

    private func requestMicrophone() async {
        await permissions.requestMicrophone()
    }

    private func open(_ pane: String) {
        permissions.openSystemSettings(pane)
    }
}
