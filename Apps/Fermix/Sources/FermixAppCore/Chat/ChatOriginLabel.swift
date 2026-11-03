import SwiftUI

extension ChatMetrics {
    /// Over an origin's label, on top of the room the turn's seam keeps.
    static let originTopGap: Double = Spacing.xs
    /// Between the label and its hairline.
    static let originLineGap: Double = Spacing.xs
    /// Between the hairline and the message under it.
    static let originBottomGap: Double = Spacing.m
    static let originGlyph: Double = 12
    static let originChevron: Double = 10
}

/// Where a message Fermix sent on its own came from, over a hairline across
/// the column (owner, 2026-11-02, after the line Codex draws over a turn's
/// answer): a scheduled job by its name beside a clock, a cue by its
/// watcher's name beside the Cues glyph, with a chevron that opens that
/// watcher's page in Settings. The app has no page of its own for a job, so
/// a job's label opens nothing. A message with no origin, a reply to the
/// owner or a reminder, carries no label.
struct ChatOriginLabel: View {
    let origin: CompanionRowOrigin

    @Environment(\.openCueWatcher) private var openWatcher

    var body: some View {
        VStack(alignment: .leading, spacing: ChatMetrics.originLineGap) {
            if origin.kind == .cue, let openWatcher {
                Button { openWatcher(origin.name) } label: {
                    ChatOriginTitle(origin: origin, opens: true)
                }
                .buttonStyle(ChatOriginButtonStyle())
                .help(ProductStrings[.chatOriginOpenCue])
                .accessibilityLabel(spoken)
                .accessibilityHint(ProductStrings[.chatOriginOpenCue])
            } else {
                ChatOriginTitle(origin: origin, opens: false)
                    .foregroundStyle(Palette.secondary.color)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(spoken)
            }

            Rectangle()
                .fill(Palette.hairline(.standard).color)
                .frame(height: Stroke.hairline)
                .accessibilityHidden(true)
        }
        .padding(.top, ChatMetrics.originTopGap)
        .padding(.bottom, ChatMetrics.originBottomGap)
    }

    private var spoken: String {
        let format: ProductStringKey = origin.kind == .cue ? .chatOriginCueFormat : .chatOriginJobFormat
        return String(format: ProductStrings[format], origin.name)
    }
}

/// The label's line: the kind's glyph, the name, and a chevron where it
/// opens something.
struct ChatOriginTitle: View {
    let origin: CompanionRowOrigin
    let opens: Bool

    var body: some View {
        HStack(spacing: Spacing.xxs) {
            Image(systemName: Self.symbol(origin.kind))
                .font(.system(size: ChatMetrics.originGlyph))

            Text(origin.name)
                .fermixType(Typography.style(.bodyCompact))
                .lineLimit(1)
                .truncationMode(.tail)

            if opens {
                Image(systemName: "chevron.right")
                    .font(.system(size: ChatMetrics.originChevron, weight: .semibold))
            }
        }
    }

    /// A clock for the schedule, and for a cue the glyph Settings draws Cues
    /// with, which is where its chevron leads.
    static func symbol(_ kind: CompanionRowOrigin.Kind) -> String {
        switch kind {
        case .job: return "clock"
        case .cue: return SettingsPane.cues.systemImage
        }
    }
}

/// A cue's label: the secondary tone, the ink under the pointer, fainter
/// while pressed.
private struct ChatOriginButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ChatOriginFace(configuration: configuration)
    }
}

private struct ChatOriginFace: View {
    let configuration: ButtonStyleConfiguration

    @State private var hovering = false

    var body: some View {
        configuration.label
            .foregroundStyle(hovering ? Palette.ink.color : Palette.secondary.color)
            .opacity(configuration.isPressed ? ChatMetrics.tilePressedStrength : 1)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

/// Opens a cue's watcher page in Settings, by the watcher's name: what a
/// cue's label in Chat does. The chat surface sets it.
struct OpenCueWatcherAction {
    let open: (String) -> Void

    func callAsFunction(_ name: String) {
        open(name)
    }
}

extension EnvironmentValues {
    /// Absent where no chat surface sets it, as in tests, and a cue's label
    /// then opens nothing.
    var openCueWatcher: OpenCueWatcherAction? {
        get { self[OpenCueWatcherKey.self] }
        set { self[OpenCueWatcherKey.self] = newValue }
    }
}

private struct OpenCueWatcherKey: EnvironmentKey {
    static let defaultValue: OpenCueWatcherAction? = nil
}
