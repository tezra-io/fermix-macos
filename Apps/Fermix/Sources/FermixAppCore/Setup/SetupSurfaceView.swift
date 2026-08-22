import SwiftUI

/// The hosted Setup surface: a titlebar, the inset opaque web surface, and the
/// footer that names the loopback origin.
///
/// Native chrome is glass and the web content is opaque, which is the design's
/// own statement: crisp content inside glass chrome.
struct SetupSurfaceView: View {
    @ObservedObject var model: SetupModel

    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(spacing: 0) {
            SurfaceTitlebar(title: ProductStrings[.setupTitle])

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 14)

            footer
        }
        .task(id: taskIdentity) {
            guard case .idle = model.state else { return }

            await model.open()
        }
        .onDisappear { model.close() }
    }

    /// One identity per presentation, so re-entering the surface mints a fresh
    /// session rather than reusing a spent token.
    private var taskIdentity: String {
        switch model.state {
        case .idle: return "idle"
        case .minting: return "minting"
        case .ready: return "ready"
        case .failed: return "failed"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle, .minting:
            LoadingSurface(message: ProductStrings[.setupOpening])
        case .ready(let session):
            webSurface(session)
        case .failed(let message):
            SurfaceFailure(
                message: message,
                actionTitle: ProductStrings[.setupRetry],
                action: { Task { await model.open() } }
            )
        }
    }

    private func webSurface(_ session: SetupSession) -> some View {
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: Radius.control,
            bottomLeadingRadius: 0,
            bottomTrailingRadius: 0,
            topTrailingRadius: Radius.control,
            style: .continuous
        )

        return Group {
            if let policy = model.navigationPolicy {
                SetupWebView(session: session, policy: policy, opener: WorkspaceExternalOpener())
            }
        }
        .background(Palette.webBackground.color)
        .clipShape(shape)
        .overlay(
            shape.strokeBorder(
                Palette.hairline(.standard, increaseContrast: contrast == .increased).color,
                lineWidth: Stroke.hairline
            )
        )
        .accessibilityLabel(ProductStrings[.setupTitle])
    }

    private var footer: some View {
        HStack(spacing: Spacing.xs) {
            Spacer(minLength: 0)

            Image(systemName: "macwindow")
                .font(.system(size: 12))
                .foregroundStyle(Palette.faint.color)
                .accessibilityHidden(true)

            Text(model.footerOrigin)
                .fermixType(Typography.style(.monoLog))
                .foregroundStyle(Palette.faint.color)

            LinkButton(title: ProductStrings[.setupFooterOpenInBrowser]) {
                Task { await model.openInSystemBrowser() }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.m)
        .frame(height: 34)
        .background(Palette.base200.color)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Palette.hairline(.faint, increaseContrast: contrast == .increased).color)
                .frame(height: Stroke.hairline)
        }
    }
}

/// The 52-point titlebar every main-window surface carries: the traffic lights
/// live at its leading edge, so the title is centred with a matching spacer.
struct SurfaceTitlebar: View {
    let title: String
    var trailing: AnyView?

    var body: some View {
        ZStack {
            Text(title)
                .fermixType(Typography.style(.callout).weight(.semibold))
                .foregroundStyle(Palette.secondary.color)

            HStack {
                Spacer(minLength: 0)
                if let trailing {
                    trailing.padding(.trailing, Spacing.m)
                }
            }
        }
        .frame(height: WindowMetrics.titlebarHeight)
        .accessibilityAddTraits(.isHeader)
    }
}

/// One loading state, shared by every surface that waits on the daemon.
struct LoadingSurface: View {
    let message: String

    var body: some View {
        VStack(spacing: Spacing.s) {
            ProgressView()
                .controlSize(.small)
                .accessibilityHidden(true)

            Text(message)
                .fermixType(Typography.style(.calloutSmall))
                .foregroundStyle(Palette.faint.color)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(message)
    }
}

/// One failure state, shared by every surface that can be refused: what
/// happened, in the daemon's own words, and the one next action.
struct SurfaceFailure: View {
    let message: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: Spacing.s) {
            Text(message)
                .fermixType(Typography.style(.bodyCompact))
                .foregroundStyle(Palette.secondary.color)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            Button(actionTitle, action: action)
                .buttonStyle(SecondaryButtonStyle(.inWindow))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}
