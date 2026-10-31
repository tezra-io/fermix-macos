import SwiftUI

/// Settings, System, Always On (M75 §14).
///
/// One line under the toolbar's title, then what `home.status` says this Mac
/// is. On the primary: the way to move Fermix to a server, the desktops it
/// serves, and its recovery. On a desktop: the server Fermix runs on, this
/// Mac's own switches, the way to replace the server, and the recovery the
/// server keeps, the last two from the server's own picture. Drawn at all
/// only where the daemon serves the home.
struct AlwaysOnPane: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var alwaysOn: AlwaysOnModel

    init(model: SettingsModel) {
        self.model = model
        self.alwaysOn = model.alwaysOn
    }

    var body: some View {
        SettingsPaneForm(title: SettingsPane.alwaysOn.title) {
            if model.requiresNewerEngine {
                NewerEngineSection(sentence: model.newerEngineSentence)
            } else {
                content
            }
        }
        .task { await alwaysOn.refresh() }
        // Followed only while something on it can move by itself, and only
        // while the pane shows; Check again follows once more.
        .task(id: AlwaysOnFollowKey(moves: alwaysOn.moves, run: alwaysOn.followRun)) {
            guard alwaysOn.moves else { return }

            await alwaysOn.follow()
        }
        // The code is shown once: leaving the pane forgets it.
        .onDisappear { alwaysOn.forgetCode() }
    }

    @ViewBuilder
    private var content: some View {
        switch alwaysOn.stage {
        case .unanswered:
            AlwaysOnLeadSection(model: model) {
                ProgressView().controlSize(.small).accessibilityHidden(true)
            }
        case .requiresNewerEngine:
            NewerEngineSection(sentence: model.newerEngineSentence)
        case .refused(let sentence):
            AlwaysOnLeadSection(model: model) { CueNote(text: sentence, attention: true) }
        case .unknownRole:
            AlwaysOnLeadSection(model: model) { EmptyView() }
        case .candidate:
            AlwaysOnLeadSection(model: model) {
                if let move = alwaysOn.status.value?.move {
                    CueStatusLine(text: move.sentence, tone: .neutral)
                }
            }
        case .primary:
            primary
        case .device:
            device
        }
    }

    @ViewBuilder
    private var primary: some View {
        if let home = alwaysOn.status.value {
            AlwaysOnLeadSection(model: model) { AlwaysOnExplanation() }
            AlwaysOnSetupSection(model: model, alwaysOn: alwaysOn)
            if !home.desktops.isEmpty {
                AlwaysOnDesktopsSection(alwaysOn: alwaysOn, desktops: home.desktops)
            }
            AlwaysOnRecoverySection(model: model, alwaysOn: alwaysOn, home: home)
        }
    }

    @ViewBuilder
    private var device: some View {
        if let home = alwaysOn.status.value {
            AlwaysOnLeadSection(model: model) {
                if let line = AlwaysOnPrimaryLine.line(home) {
                    AlwaysOnPrimaryRow(line: line)
                }
            }
            // This home's own move while it is still under way here, then
            // the server's replacement, from the server's picture.
            AlwaysOnSetupSection(model: model, alwaysOn: alwaysOn)
            AlwaysOnThisMacSection(model: model, alwaysOn: alwaysOn)
            AlwaysOnRecoverySection(model: model, alwaysOn: alwaysOn, home: home)
        }
    }
}

/// What the pane's follow is keyed on: whether anything moves, and how many
/// times Check again asked.
struct AlwaysOnFollowKey: Hashable {
    let moves: Bool
    let run: Int
}

/// The pane's first section: its one line and the way to the guide in the
/// header, then what the stage puts first.
struct AlwaysOnLeadSection<Content: View>: View {
    @ObservedObject var model: SettingsModel
    @ViewBuilder let content: Content

    @State private var guideRefusal: String?

    var body: some View {
        Section {
            content

            if let guideRefusal {
                CueNote(text: guideRefusal, attention: true)
            }
        } header: {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                Text(ProductStrings[.alwaysOnSubtitle])
                    .fermixType(Typography.style(.calloutSmall))
                    .foregroundStyle(Palette.secondary.color)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: Spacing.s)

                LinkButton(title: ProductStrings[.alwaysOnLearnMore]) { guideRefusal = model.openAlwaysOnGuide() }
                    .fermixType(Typography.style(.calloutSmall))
            }
            .textCase(nil)
        }
    }
}

/// What moving does, before anything is asked: what goes to the server, what
/// this Mac keeps, and what is not there while Fermix runs on a server.
struct AlwaysOnExplanation: View {
    var body: some View {
        VStack(alignment: .leading, spacing: SettingsRowMetrics.captionGap) {
            CueNote(text: ProductStrings[.alwaysOnSetupMoves])
            CueNote(text: ProductStrings[.alwaysOnSetupStays])
            CueNote(text: ProductStrings[.alwaysOnSetupNotAvailable])
        }
    }
}

/// What replacing the server does, on a desktop, before anything is asked:
/// the new server takes over and the old one keeps nothing, and moving
/// Fermix back to this Mac is not something this version does.
struct AlwaysOnReplaceExplanation: View {
    var body: some View {
        VStack(alignment: .leading, spacing: SettingsRowMetrics.captionGap) {
            CueNote(text: ProductStrings[.alwaysOnReplaceBody])
            CueNote(text: ProductStrings[.alwaysOnReplaceNoMoveBack])
        }
    }
}

/// The server a desktop reaches: its name, the rail's sentence after the dot,
/// and since when it is connected.
struct AlwaysOnPrimaryRow: View {
    let line: AlwaysOnPrimaryLine

    var body: some View {
        CueRow(
            symbol: "server.rack",
            title: line.name,
            qualifier: since,
            status: line.sentence ?? "",
            tone: line.tone,
            attention: line.attention,
            accessibilityLabel: ProductStrings.commaPair(line.name, line.sentence ?? "")
        ) {
            EmptyView()
        }
    }

    private var since: String? {
        guard let since = line.since, let date = ManagementCueTime.date(since) else { return nil }

        return String(format: ProductStrings[.alwaysOnConnectedSinceFormat], CueTimes.time(date))
    }
}

/// This Mac's own engine, on a desktop: the daemon's `engine` section, which
/// carries the executor switch, where the daemon publishes it, and the
/// folders the server may read here, each with the way to take it back. Both
/// are this Mac's engine's, so they show while the server is away.
struct AlwaysOnThisMacSection: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var alwaysOn: AlwaysOnModel

    var body: some View {
        if drawsEngine || drawsGrants {
            Section(ProductStrings[.alwaysOnThisMacTitle]) {
                if drawsEngine {
                    DescriptorRows(model: model, section: AlwaysOnSections.engine)
                }
                if drawsGrants {
                    AlwaysOnReadGrants(alwaysOn: alwaysOn)
                }
            }
        }
    }

    private var drawsEngine: Bool {
        model.sections(for: .alwaysOn).contains { $0.id == AlwaysOnSections.engine }
    }

    private var drawsGrants: Bool {
        model.servedMethods.contains(.deviceGrantsList)
    }
}

/// The folders the server may read on this Mac beyond its sandbox, in the
/// daemon's sentence, each with when it was allowed and Remove.
struct AlwaysOnReadGrants: View {
    @ObservedObject var alwaysOn: AlwaysOnModel

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsRowMetrics.captionGap) {
            content

            if let notice = alwaysOn.grantNotice {
                CueNote(text: notice)
            }
        }
        .task { await alwaysOn.refreshGrants() }
    }

    @ViewBuilder
    private var content: some View {
        switch alwaysOn.grants {
        case .unread, .loading:
            ProgressView().controlSize(.small).accessibilityHidden(true)
        case .requiresNewerEngine:
            CueNote(text: ProductStrings[.daemonErrorRequiresNewerEngine], attention: true)
        case .unavailable(let sentence):
            CueNote(text: sentence, attention: true)
        case .loaded(let list):
            CueNote(text: list.sentence)
            ForEach(list.grants, id: \.path) { grant in
                AlwaysOnReadGrantRow(
                    grant: grant,
                    busy: alwaysOn.grantRemovals.contains(grant.path),
                    refusal: alwaysOn.grantRefusals[grant.path]
                ) {
                    Task { await alwaysOn.removeGrant(path: grant.path) }
                }
            }
        }
    }
}

/// One folder the server may read: the folder, when it was allowed, Remove,
/// and the daemon's refusal of a removal under it.
struct AlwaysOnReadGrantRow: View {
    let grant: ManagementDeviceGrant
    let busy: Bool
    let refusal: String?
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsRowMetrics.captionGap) {
            CueRow(
                symbol: "folder",
                title: grant.path,
                status: allowed,
                tone: .neutral,
                accessibilityLabel: ProductStrings.commaPair(grant.path, allowed)
            ) {
                Button(ProductStrings[.alwaysOnGrantsRemove], action: remove)
                    .buttonStyle(SecondaryButtonStyle(.row))
                    .disabled(busy)
                    .accessibilityLabel(ProductStrings.commaPair(ProductStrings[.alwaysOnGrantsRemove], grant.path))
            }

            if let refusal {
                CueNote(text: refusal, attention: true)
            }
        }
    }

    private var allowed: String {
        let when = ManagementCueTime.date(grant.grantedAt).map { CueTimes.time($0) } ?? grant.grantedAt
        return String(format: ProductStrings[.alwaysOnGrantsAllowedFormat], when)
    }
}

/// On a primary, the desktops its home moved from, each with its executor
/// switch.
struct AlwaysOnDesktopsSection: View {
    @ObservedObject var alwaysOn: AlwaysOnModel
    let desktops: [ManagementHomeDesktop]

    var body: some View {
        Section {
            ForEach(desktops, id: \.deviceId) { desktop in
                AlwaysOnDesktopRow(
                    desktop: desktop,
                    busy: alwaysOn.executorWrites.contains(desktop.deviceId),
                    refusal: alwaysOn.executorRefusals[desktop.deviceId]
                ) { isOn in
                    Task { await alwaysOn.setExecutor(isOn, deviceId: desktop.deviceId) }
                }
            }
        } header: {
            CuesSectionHeader(
                title: .alwaysOnDesktopsTitle,
                count: desktops.count,
                info: .alwaysOnDesktopsExecutorInfo,
                action: nil
            ) {}
        }
    }
}

/// One desktop: its name, whether it is connected and since when, and the
/// switch that lets it run actions.
struct AlwaysOnDesktopRow: View {
    let desktop: ManagementHomeDesktop
    let busy: Bool
    let refusal: String?
    let setExecutor: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsRowMetrics.captionGap) {
            CueRow(
                symbol: "desktopcomputer",
                title: desktop.name,
                status: status,
                tone: desktop.connected ? .pass : .neutral,
                accessibilityLabel: ProductStrings.commaPair(desktop.name, status)
            ) {
                if let executor = desktop.executor {
                    Toggle(ProductStrings[.alwaysOnDesktopsExecutor], isOn: Binding(get: { executor }, set: setExecutor))
                        .toggleStyle(.switch)
                        .disabled(busy)
                        .accessibilityLabel(
                            ProductStrings.commaPair(ProductStrings[.alwaysOnDesktopsExecutor], desktop.name)
                        )
                }
            }

            if let refusal {
                CueNote(text: refusal, attention: true)
            }
        }
    }

    private var status: String {
        guard desktop.connected else { return ProductStrings[.alwaysOnDesktopsNotConnected] }
        guard let since = desktop.since, let date = ManagementCueTime.date(since) else {
            return ProductStrings[.alwaysOnDesktopsConnected]
        }

        return String(format: ProductStrings[.alwaysOnConnectedSinceFormat], CueTimes.time(date))
    }
}
