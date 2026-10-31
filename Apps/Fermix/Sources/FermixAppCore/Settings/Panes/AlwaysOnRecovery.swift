import SwiftUI

/// Recovery (M75 §8, §14): the secrets the home could not resolve where it
/// runs, the daemon's sentence about the snapshots, one row per place they go
/// with its last verified point and its newest failure, Back up now where
/// snapshots are configured, the `snapshots` section's own rows as the daemon
/// publishes them, so the owner sets the bucket and the keys, and the way to
/// set the recovery passphrase. On a linked desktop all of it is the server's,
/// reached through it, or the daemon's sentence while it is missing.
struct AlwaysOnRecoverySection: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var alwaysOn: AlwaysOnModel
    let home: ManagementHomeStatus

    var body: some View {
        Section {
            AlwaysOnSecretsMissing(ids: AlwaysOnRecoveryProjection.secretsMissing(home))

            switch AlwaysOnRecoveryProjection.source(home) {
            case .missing(let sentence):
                CueStatusLine(text: sentence, tone: .warn, attention: true)
            case .snapshots(let snapshots, let setsKey):
                facts(snapshots, setsKey: setsKey)
            }
        } header: {
            CuesSectionHeader(title: .alwaysOnRecoveryTitle, action: nil) {}
        }
    }

    @ViewBuilder
    private func facts(_ snapshots: ManagementHomeSnapshots, setsKey: Bool) -> some View {
        CueStatusLine(text: snapshots.sentence, tone: AlwaysOnRecoveryProjection.tone(snapshots))

        ForEach(snapshots.targets, id: \.id) { target in
            AlwaysOnTargetRow(target: target)
        }

        if AlwaysOnRecoveryProjection.offersBackup(snapshots) {
            backup(snapshots)
        }

        if hasSnapshotsSection {
            DescriptorRows(model: model, section: AlwaysOnSections.snapshots)

            if setsKey {
                AlwaysOnRecoveryPassphraseControl(alwaysOn: alwaysOn)
            }
        }
    }

    private var hasSnapshotsSection: Bool {
        model.sections(for: .alwaysOn).contains { $0.id == AlwaysOnSections.snapshots }
    }

    /// Back up now, with the snapshot under way beside it and the daemon's
    /// refusal under it.
    private func backup(_ snapshots: ManagementHomeSnapshots) -> some View {
        VStack(alignment: .leading, spacing: SettingsRowMetrics.captionGap) {
            HStack(spacing: Spacing.s) {
                Button(ProductStrings[.alwaysOnRecoveryBackUpNow]) {
                    Task { await alwaysOn.backUpNow() }
                }
                .buttonStyle(SecondaryButtonStyle(.row))
                .disabled(alwaysOn.isBackingUp || snapshots.running)

                if alwaysOn.isBackingUp || snapshots.running {
                    ProgressView().controlSize(.small).accessibilityHidden(true)
                }
            }

            if let refusal = alwaysOn.backupRefusal {
                CueNote(text: refusal, attention: true)
            }
        }
    }

}

/// The secrets the home's settings name that did not resolve where it runs,
/// by the ids the daemon published, and what to do about them in the app.
struct AlwaysOnSecretsMissing: View {
    let ids: [String]

    var body: some View {
        if !ids.isEmpty {
            VStack(alignment: .leading, spacing: SettingsRowMetrics.captionGap) {
                CueStatusLine(
                    text: String(format: ProductStrings[.alwaysOnSecretsMissingFormat], ids.joined(separator: ", ")),
                    tone: .warn,
                    attention: true
                )
                CueNote(text: ProductStrings[.alwaysOnSecretsMissingAction])
            }
        }
    }
}

/// One place snapshots go: its label and destination, the last verified point
/// after the dot, and the newest failure in the storage service's own words.
struct AlwaysOnTargetRow: View {
    let target: ManagementSnapshotTarget

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsRowMetrics.captionGap) {
            CueRow(
                symbol: "externaldrive",
                title: target.label,
                qualifier: target.destination,
                status: verified,
                tone: AlwaysOnRecoveryProjection.tone(target),
                accessibilityLabel: ProductStrings.commaPair(target.label, verified)
            ) {
                EmptyView()
            }

            if let error = target.lastError {
                CueNote(text: error, attention: true)
            }
            if let waiting = target.waiting {
                CueNote(text: waiting)
            }
            if let key = AlwaysOnRecoveryProjection.keyLine(target) {
                CueNote(text: key)
            }
        }
    }

    private var verified: String {
        AlwaysOnRecoveryProjection.verifiedLine(target) { CueTimes.time($0) }
    }
}

/// Set recovery passphrase…, under the `snapshots` section's rows: the
/// passphrase typed twice, then the daemon's refusal or its sentence that
/// snapshots from now on open with it.
struct AlwaysOnRecoveryPassphraseControl: View {
    @ObservedObject var alwaysOn: AlwaysOnModel

    @State private var entering = false
    @State private var entry = RecoveryPassphraseEntry()

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsRowMetrics.captionGap) {
            if entering {
                RecoveryPassphraseForm(entry: $entry, busy: alwaysOn.isSettingPassphrase, action: .alwaysOnPassphraseSave) {
                    entry.clear()
                    entering = false
                } submit: { passphrase in
                    Task { if await alwaysOn.setRecoveryPassphrase(passphrase) { entering = false } }
                }
            } else {
                Button(ProductStrings[.alwaysOnRecoverySetPassphrase]) { entering = true }
                    .buttonStyle(SecondaryButtonStyle(.row))
            }

            if let refusal = alwaysOn.passphraseRefusal {
                CueNote(text: refusal, attention: true)
            }
            if let notice = alwaysOn.passphraseNotice {
                CueNote(text: notice)
            }
        }
        // Whatever was typed goes with the control.
        .onDisappear { entry.clear() }
    }
}

/// The recovery passphrase, typed twice in secure fields, with what it is
/// for. It sends only when both entries match and nothing blocks the action
/// (a move's readiness report), and hands the passphrase over after
/// forgetting it here.
struct RecoveryPassphraseForm: View {
    @Binding var entry: RecoveryPassphraseEntry
    let busy: Bool
    var blocked = false
    let action: ProductStringKey
    let cancel: () -> Void
    let submit: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsRowMetrics.captionGap) {
            CueNote(text: ProductStrings[.alwaysOnPassphraseBody])

            LabeledContent(ProductStrings[.alwaysOnPassphraseField]) {
                SecretInput(label: ProductStrings[.alwaysOnPassphraseField], value: $entry.first, onSubmit: send)
            }
            LabeledContent(ProductStrings[.alwaysOnPassphraseAgain]) {
                SecretInput(label: ProductStrings[.alwaysOnPassphraseAgain], value: $entry.second, onSubmit: send)
            }

            if entry.showsMismatch {
                CueNote(text: ProductStrings[.alwaysOnPassphraseMismatch], attention: true)
            }

            HStack(spacing: Spacing.s) {
                Spacer(minLength: 0)
                Button(ProductStrings[.settingsSheetCancel], action: cancel)
                    .buttonStyle(SecondaryButtonStyle(.row))
                PrimaryAction(ProductStrings[action], size: .row, action: send)
                    .disabled(!entry.matches || busy || blocked)
            }
        }
    }

    private func send() {
        guard let passphrase = entry.passphrase, !busy, !blocked else { return }

        entry.clear()
        submit(passphrase)
    }
}
