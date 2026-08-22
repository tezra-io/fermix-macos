import SwiftUI

/// Home: the status hero, Runtime, Attention, and the update card.
///
/// The artboard's Recent Activity feed is gone. Every row is derived from
/// `overview.get` and `hello`, so nothing here can show an event the daemon did
/// not report.
struct HomeView: View {
    @ObservedObject var model: HomeModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.m) {
                StatusHeroCard(model: model)

                SectionCard(label: ProductStrings[.homeSectionRuntime]) {
                    rows(model.snapshot.runtime, empty: model.snapshot.runtimeEmpty)
                }

                SectionCard(label: ProductStrings[.homeSectionAttention]) {
                    rows(model.snapshot.attention, empty: model.snapshot.attentionEmpty)
                }

                UpdateCard(summary: model.snapshot.updateSummary)
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 22)
        }
        .task { await model.refresh() }
    }

    @ViewBuilder
    private func rows(_ models: [StatusRowModel], empty: EmptyStateModel) -> some View {
        if models.isEmpty {
            EmptyState(model: empty)
        } else {
            VStack(spacing: 0) {
                ForEach(Array(models.enumerated()), id: \.element.id) { index, row in
                    if index > 0 {
                        Divider().overlay(Palette.hairline(.faint).color)
                    }

                    StatusRow(model: row)
                }
            }
        }
    }
}

/// The status hero: the state, the uptime, the chips, and the actions.
struct StatusHeroCard: View {
    @ObservedObject var model: HomeModel

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                headline
                actions
                toggles
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 20)
        }
    }

    private var headline: some View {
        HStack(spacing: Spacing.s) {
            StatusDot(tone: model.snapshot.statusTone)

            Text(model.snapshot.statusTitle)
                .fermixType(Typography.style(.statusHeadline))
                .foregroundStyle(Palette.ink.color)

            if let uptime = model.snapshot.uptime {
                Text(uptime)
                    .fermixType(Typography.style(.callout).weight(.regular))
                    .foregroundStyle(Palette.faint.color)
            }

            Spacer(minLength: Spacing.s)

            ForEach(model.snapshot.chips, id: \.self) { chip in
                Chip(chip)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var actions: some View {
        HStack(spacing: 10) {
            PrimaryAction(ProductStrings[.homeOpenSetup], size: .inWindow) { model.openSetup() }

            Button(ProductStrings[.homeRunDoctor]) { model.runDoctor() }
                .buttonStyle(SecondaryButtonStyle(.inWindow))

            Button(ProductStrings[.homeRestartDaemon]) { model.restartDaemon() }
                .buttonStyle(SecondaryButtonStyle(.inWindow))
                .disabled(model.transactionInFlight)

            Spacer(minLength: 0)
        }
    }

    /// The two registrations, as two independent switches. M34 §4: the durable
    /// state is the registration, so the label is enable or disable and never
    /// start or stop.
    private var toggles: some View {
        HStack(spacing: Spacing.l) {
            Toggle(
                ProductStrings[.serviceEnable],
                isOn: Binding(
                    get: { model.backgroundServiceEnabled },
                    set: { model.setBackgroundService($0) }
                )
            )
            .disabled(model.transactionInFlight)

            Toggle(
                ProductStrings[.homeOpenAtLogin],
                isOn: Binding(
                    get: { model.openAtLogin },
                    set: { model.setOpenAtLogin($0) }
                )
            )

            Spacer(minLength: 0)
        }
        .toggleStyle(.switch)
        .fermixType(Typography.style(.callout))
        .foregroundStyle(Palette.secondary.color)
    }
}

/// The running dot with its soft halo. The word beside it carries the state;
/// the dot is decoration.
struct StatusDot: View {
    let tone: StatusTone

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 12, height: 12)
            .background(Circle().fill(halo).padding(-4))
            .accessibilityHidden(true)
    }

    private var color: Color {
        switch tone {
        case .pass: return Palette.success.color
        case .warn: return Palette.warning.color
        case .fail: return Palette.error.color
        case .neutral: return Palette.faint.color
        }
    }

    private var halo: Color {
        tone == .pass ? Palette.successGlow.color : .clear
    }
}

/// The update card. It is wired to the update seam and says only what that seam
/// can observe, which in this build is that nothing has checked yet.
struct UpdateCard: View {
    let summary: String

    var body: some View {
        Card {
            HStack(spacing: Spacing.s) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 15))
                    .foregroundStyle(Palette.secondary.color)
                    .accessibilityHidden(true)

                Text(summary)
                    .fermixType(Typography.style(.callout).weight(.regular))
                    .foregroundStyle(Palette.secondary.color)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .frame(height: 52)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summary)
    }
}
