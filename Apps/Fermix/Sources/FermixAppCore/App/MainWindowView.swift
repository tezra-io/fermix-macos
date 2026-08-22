import SwiftUI

/// The main window: the fixed sidebar and the surface it selects, on the same
/// window glass every other window surface draws.
///
/// The sidebar is the chat-ready shell — a future Chat row is one more entry in
/// `SidebarItem.mainWindow` and one more case here. It carries a hairline and no
/// fill, because the window is one glass card and a second opaque panel inside
/// it would flatten 200 points of that material.
struct MainWindowView: View {
    @ObservedObject var model: AppModel
    let surfaces: MainWindowSurfaces
    let coordinator: AppCoordinator

    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        GlassChrome(.required(for: .main)) {
            HStack(spacing: 0) {
                sidebar
                    .frame(width: WindowMetrics.sidebarWidth)

                Divider()
                    .overlay(Palette.hairline(.faint, increaseContrast: contrast == .increased).color)

                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(
            minWidth: WindowMetrics.mainDefaultSize.width,
            minHeight: WindowMetrics.mainDefaultSize.height
        )
        .fermixWindowEntrance()
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            Spacer()
                .frame(height: WindowMetrics.titlebarHeight)

            ForEach(SidebarItem.mainWindow) { item in
                SidebarRow(item: item, isSelected: isSelected(item)) {
                    select(item)
                }
            }

            Spacer(minLength: 0)

            SidebarFooter(version: surfaces.version, updateSummary: surfaces.home.snapshot.updateSummary)
        }
        .padding(.horizontal, Spacing.s)
        .padding(.bottom, Spacing.s)
        .frame(maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var detail: some View {
        switch model.route {
        case .home:
            HomeView(model: surfaces.home)
        case .setup:
            SetupSurfaceView(model: surfaces.setup)
        case .doctor:
            DoctorView(model: surfaces.doctor)
        case .logs:
            LogsView(model: surfaces.logs)
        case .pet:
            PetSurfaceView(model: surfaces.pet)
        case .update:
            UpdateSurfaceView(summary: surfaces.home.snapshot.updateSummary)
        case .uninstall:
            UninstallSurfaceView()
        case .recovery:
            // Recovery is a state of the onboarding window; the main window
            // never draws it, and the coordinator routes there instead.
            HomeView(model: surfaces.home)
        }
    }

    private func isSelected(_ item: SidebarItem) -> Bool {
        model.route.sidebarItemIdentifier == item.id
    }

    private func select(_ item: SidebarItem) {
        guard let route = AppRoute.allCases.first(where: { $0.sidebarItemIdentifier == item.id }) else { return }

        model.route = route
    }
}

/// The sidebar footer: the mascot, the product and version, and the update
/// state as the update seam reports it.
struct SidebarFooter: View {
    let version: String
    let updateSummary: String

    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(spacing: Spacing.xs) {
            MascotArtwork(size: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text(ProductStrings.middot(ProductStrings[.menuTitle], version))
                    .fermixType(Typography.style(.caption).weight(.semibold))
                    .foregroundStyle(Palette.secondary.color)

                Text(updateSummary)
                    .fermixType(Typography.style(.caption).weight(.regular))
                    .foregroundStyle(Palette.faint.color)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.top, 14)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Palette.hairline(.faint, increaseContrast: contrast == .increased).color)
                .frame(height: Stroke.hairline)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The update surface. Sparkle is M34 §6 work, so this reports what the update
/// seam can observe and offers nothing it cannot do.
struct UpdateSurfaceView: View {
    let summary: String

    var body: some View {
        VStack(spacing: 0) {
            SurfaceTitlebar(title: ProductStrings[.updateTitle])

            VStack(spacing: Spacing.s) {
                Text(summary)
                    .fermixType(Typography.style(.bodyCompact))
                    .foregroundStyle(Palette.secondary.color)

                Text(ProductStrings[.updateUnwired])
                    .fermixType(Typography.style(.calloutSmall))
                    .foregroundStyle(Palette.faint.color)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The uninstall surface. The transaction itself is §4 work; what exists today
/// is the route and the promise it will keep.
struct UninstallSurfaceView: View {
    var body: some View {
        VStack(spacing: 0) {
            SurfaceTitlebar(title: ProductStrings[.uninstallTitle])

            Text(ProductStrings[.uninstallBody])
                .fermixType(Typography.style(.bodyCompact))
                .foregroundStyle(Palette.secondary.color)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
