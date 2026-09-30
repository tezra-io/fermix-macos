import SwiftUI

/// What stands over the composer while the timeline is empty: the mark, a
/// greeting by the time of day with the person's first name where About you
/// saved one, and one quieter line.
///
/// Nothing here moves on its own. The greeting is read from the Mac's clock
/// when the surface is drawn, which is the app's own state, and the name is
/// the daemon's `personalization` row, read through the one settings model:
/// the same row the assistant writes and the Personality pane shows. A section
/// nobody has read yet is read here, once.
struct ChatGreetingView: View {
    @ObservedObject var settings: SettingsModel

    var body: some View {
        VStack(spacing: Spacing.s) {
            ChatMark()
                .padding(.bottom, Spacing.xs)

            Text(ChatGreeting.text(hour: Calendar.current.component(.hour, from: Date()), userName: userName))
                .fermixType(Typography.style(.title))
                .foregroundStyle(Palette.ink.color)

            Text(ProductStrings[.chatInvitation])
                .fermixType(Typography.style(.body))
                .foregroundStyle(Palette.secondary.color)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, Spacing.l)
        .task {
            guard !settings.isRead(AboutYouAnswers.personalizationSection) else { return }

            await settings.loadSection(AboutYouAnswers.personalizationSection)
        }
    }

    private var userName: String? {
        ChatGreeting.userName(in: settings)
    }
}
