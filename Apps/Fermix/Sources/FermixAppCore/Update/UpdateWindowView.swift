import SwiftUI

/// Every moment of an update, drawn the way the app draws its own popups: the
/// frame's glass, the one-ink mascot, the app's type, and its capsules.
///
/// It replaces the updater's own windows, which drew the application icon on a
/// tile of its own, a saturated blue default button and progress bar, and
/// copy this product did not write (owner, 2026-10-21: the update popup "doesnt
/// [have] the same aesthetics as [the] app").
struct UpdateWindowView: View {
    @ObservedObject var prompt: UpdatePrompt

    var body: some View {
        ZStack(alignment: .topLeading) {
            FrameGlass()

            if let phase = prompt.phase {
                UpdateWindowBody(
                    content: UpdateWindowContent(phase: phase, installedVersion: prompt.installedVersion),
                    perform: prompt.perform
                )
            }
        }
        // The window's size is its descriptor's, and the content fills it:
        // the host lays it out over the whole window, title bar included,
        // since the window draws no buttons there.
    }
}

private struct UpdateWindowBody: View {
    let content: UpdateWindowContent
    let perform: (UpdatePromptAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: Spacing.m) {
                UpdateMark()

                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(content.title)
                        .fermixType(Typography.sheetTitle)
                        .foregroundStyle(Palette.ink.color)
                        .accessibilityAddTraits(.isHeader)

                    if let body = content.body {
                        Text(body)
                            .fermixType(Typography.style(.bodyCompact))
                            .foregroundStyle(Palette.secondary.color)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    progress
                }
            }

            Spacer(minLength: Spacing.s)

            buttons
        }
        .padding(WindowMetrics.contentPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var progress: some View {
        switch content.progress {
        case .none:
            EmptyView()
        case .indeterminate:
            bar(ProgressView())
        case .fraction(let fraction):
            bar(ProgressView(value: fraction))
        }
    }

    private func bar(_ view: ProgressView<EmptyView, EmptyView>) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            view
                .progressViewStyle(.linear)
                .controlSize(.small)

            if let status = content.status {
                Text(status)
                    .fermixType(Typography.style(.calloutSmall))
                    .foregroundStyle(Palette.secondary.color)
                    .monospacedDigit()
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .padding(.top, Spacing.xs)
    }

    /// An alternative leads the row; the way out and the one thing to do sit
    /// together at the trailing edge, which is where macOS puts them.
    private var buttons: some View {
        HStack(spacing: Spacing.s) {
            ForEach(content.buttons.filter { $0.role == .alternative }, id: \.action) { button in
                Button(button.title) { perform(button.action) }
                    .buttonStyle(SecondaryButtonStyle(.row))
            }

            Spacer(minLength: 0)

            ForEach(content.buttons.filter { $0.role != .alternative }, id: \.action) { button in
                if button.role == .primary {
                    PrimaryAction(button.title, size: .row) { perform(button.action) }
                } else {
                    Button(button.title) { perform(button.action) }
                        .buttonStyle(SecondaryButtonStyle(.row))
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
    }
}
