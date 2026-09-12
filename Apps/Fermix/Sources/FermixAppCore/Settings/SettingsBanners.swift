import SwiftUI

/// What the top of the Settings window is saying right now.
///
/// One value rather than two view conditions, because the three states are
/// mutually exclusive and the rule that keeps them so — an unreadable file is
/// never answered with a reload button — is worth reading in one place.
public enum SettingsBannerState: Equatable, Sendable {
    case none
    /// The settings file changed outside Fermix. One action: reload.
    case externalChange
    /// The daemon cannot read or parse the file. No reload action, because the
    /// reload would re-run the read that just failed; it routes to Recovery.
    ///
    /// The redline copy deck (§7) labels this action `Reveal settings file`,
    /// where M34 §5 routes it to Recovery. The route decides the label: this
    /// button opens Recovery, which shows the file and the copy from before, so
    /// naming it after a Finder reveal would say the wrong destination. The half
    /// both documents agree on — that no reload is offered — is what the gate
    /// asserts.
    case configUnreadable(String?)
    /// A restart is pending, with the daemon's own reason sentences.
    case restart([ManagementRestartReason])
    /// The daemon is one release behind the bundle, so every v2 method refuses
    /// and no pane can be served at all (M34 §7.1). The restart that fixes it is
    /// the one action, and without this state the panes stated the problem and
    /// offered nothing: the `Finish updating Fermix` sheet was unreachable in
    /// exactly the state it exists for.
    case finishUpdating
    /// The v2 methods refuse and the daemon in memory already is the engine
    /// this copy ships, so a restart brings the same engine back. It states
    /// that and offers nothing, because there is nothing here to offer: the
    /// remedy is a newer Fermix, not a restart of this one.
    case engineBehindApp

    /// Errors stay above the form. Saved changes use the Settings toolbar.
    var showsInlineBanner: Bool {
        switch self {
        case .none, .restart, .finishUpdating: return false
        case .externalChange, .configUnreadable, .engineBehindApp: return true
        }
    }

    var restartActionTitle: String? {
        switch self {
        case .restart, .finishUpdating: return ProductStrings[.settingsRestartAction]
        default: return nil
        }
    }

    var restartDetail: String? {
        switch self {
        case .restart(let reasons):
            let detail = reasons.map(\.sentence).joined(separator: " ")
            return detail.isEmpty ? ProductStrings[.settingsRestartTitle] : detail
        case .finishUpdating:
            return ProductStrings[.settingsRequiresNewerEngine]
        default:
            return nil
        }
    }

    /// - Parameter engine: what the running daemon can serve, as one value
    ///   (M34 §7.1, §7.2). It decides which of the two newer-engine states this
    ///   is, and that decision is the whole difference between a banner that
    ///   offers a restart and one that must not.
    public static func resolve(
        configState: ManagementConfigState,
        restart: ManagementRestartState,
        sentence: String?,
        engine: EngineReconcile = EngineReconcile()
    ) -> SettingsBannerState {
        switch configState {
        case .configUnreadable:
            return .configUnreadable(sentence)
        case .externalChange:
            return .externalChange
        case .clear, .unrecognized:
            // Before the restart case: an N-1 daemon reports no restart
            // requirement of its own, so nothing else would draw a banner.
            if engine.requiresNewerEngine {
                return engine.isFinishingUpdate ? .finishUpdating : .engineBehindApp
            }

            return restart.required ? .restart(restart.reasons) : .none
        }
    }
}

extension SettingsModel {
    var bannerState: SettingsBannerState {
        SettingsBannerState.resolve(
            configState: configState, restart: restart, sentence: configSentence, engine: engineReconcile
        )
    }
}

/// One persistent action for all Settings panes. Details stay in the existing
/// restart confirmation sheet instead of repeating above every form.
@MainActor
struct SettingsRestartControl: ToolbarContent {
    @ObservedObject var model: SettingsModel
    let router: any CommandPerforming

    var body: some ToolbarContent {
        if let title = model.bannerState.restartActionTitle {
            ToolbarItem(id: AppCommand.restartDaemon.rawValue, placement: .primaryAction) {
                Button(title, action: requestRestart)
                    .disabled(!router.canPerform(.restartDaemon))
                    .help(model.bannerState.restartDetail ?? title)
                    .accessibilityHint(model.bannerState.restartDetail ?? title)
            }
        }
    }

    func requestRestart() {
        guard model.bannerState.restartActionTitle != nil, router.canPerform(.restartDaemon) else { return }

        router.perform(.restartDaemon)
    }
}

/// A configuration problem: one title, its detail, and one recovery action.
struct SettingsBanner: View {
    let title: String
    let detail: String
    let actionTitle: String?
    let action: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .fermixType(Typography.style(.bodyCompact))
                    .foregroundStyle(Palette.ink.color)

                if !detail.isEmpty {
                    Text(detail)
                        .fermixType(Typography.style(.calloutSmall))
                        .foregroundStyle(Palette.secondary.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: Spacing.s)

            if let actionTitle {
                Button(actionTitle, action: action)
                    .accessibilityLabel(actionTitle)
            }
        }
        .padding(.horizontal, WindowMetrics.settingsFormCardInset)
        .padding(.vertical, Spacing.s)
        // The pane's own measure, so the banner's first word and its button sit
        // on the same edges as the cards below rather than 60 points outside
        // them. The bar itself still spans the window; only its content is
        // bounded, which is what keeps the material edge to edge.
        .frame(maxWidth: WindowMetrics.settingsContentMaxWidth)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }
}

extension View {
    /// The error-banner slot every Settings pane carries. Pending restarts use
    /// the Settings toolbar instead of taking space above each form.
    ///
    /// A top safe-area bar carrying the `.bar` material, or a solid ground
    /// under Reduce Transparency so the reasons stay legible where the
    /// material is switched off. The material is the bar's on both systems:
    /// `safeAreaBar` places the content but paints nothing behind it, so
    /// without this the reasons read as an orphan line of text floating under
    /// the toolbar with nothing separating them from the form.
    func settingsBanners(
        model: SettingsModel,
        openRecovery: @escaping () -> Void
    ) -> some View {
        modifier(SettingsBannerSlot(model: model, openRecovery: openRecovery))
    }
}

private struct SettingsBannerSlot: ViewModifier {
    @ObservedObject var model: SettingsModel
    let openRecovery: () -> Void

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var reloadMessage: String?

    func body(content: Content) -> some View {
        bannered(content)
    }

    /// The availability split is the placement modifier and nothing else: both
    /// branches take the same bar, with the same material.
    @ViewBuilder
    private func bannered(_ content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.safeAreaBar(edge: .top) { material }
        } else {
            content.safeAreaInset(edge: .top, spacing: 0) { material }
        }
    }

    /// The bar's own ground, which is what makes it read as a bar rather than
    /// as a line of text over the pane. No material is drawn for a pending
    /// restart or an empty state.
    @ViewBuilder
    private var material: some View {
        if !state.showsInlineBanner {
            EmptyView()
        } else if reduceTransparency {
            bar.background(Palette.base200.color)
        } else {
            bar.background(.bar)
        }
    }

    @ViewBuilder
    private var bar: some View {
        switch state {
        case .none, .restart, .finishUpdating:
            EmptyView()
        case .externalChange:
            SettingsBanner(
                title: ProductStrings[.settingsExternalChangeTitle],
                detail: reloadMessage ?? ProductStrings[.settingsExternalChangeBody],
                actionTitle: ProductStrings[.settingsExternalChangeAction]
            ) {
                Task { reloadMessage = await model.reloadFromDisk() }
            }
        case .configUnreadable(let sentence):
            SettingsBanner(
                title: ProductStrings[.settingsConfigUnreadableTitle],
                detail: sentence ?? ProductStrings[.settingsConfigUnreadableBody],
                actionTitle: ProductStrings[.settingsConfigUnreadableAction],
                action: openRecovery
            )
        // One sentence and no action. A restart here brings the same engine
        // back, so a button offering one would be the defect this state exists
        // to remove.
        case .engineBehindApp:
            SettingsBanner(
                title: ProductStrings[.settingsEngineBehindApp],
                detail: "",
                actionTitle: nil
            ) {}
        }
    }

    private var state: SettingsBannerState {
        model.bannerState
    }
}
