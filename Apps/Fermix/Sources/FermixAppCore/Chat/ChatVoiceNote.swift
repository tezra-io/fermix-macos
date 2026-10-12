import SwiftUI

/// A voice note from the phone, before its sound is in the app's hands
/// (M66 §3.4, stage 1): a chip on its row's side in the chip's fill, as the
/// phone draws one, with a waveform glyph and "Voice note" where the player
/// will be, and the transcript, the row's text, under them. A note with no
/// transcript, one still being transcribed or one that could not be, is the
/// chip alone.
struct ChatVoiceNote: View {
    let transcript: AttributedString
    /// Who sent it, which side it is drawn on and how VoiceOver names its
    /// transcript.
    let speaker: String?

    var body: some View {
        let user = ChatSpeaker.isUser(speaker)

        VStack(alignment: .leading, spacing: Spacing.xs) {
            Label(ProductStrings[.chatVoiceNote], systemImage: "waveform")
                .fermixType(Typography.style(.callout))
                .foregroundStyle(Palette.secondary.color)

            if !transcript.characters.isEmpty {
                Text(transcript)
                    .fermixType(Typography.style(.body))
                    .foregroundStyle(Palette.ink.color)
                    .textSelection(.enabled)
                    .accessibilityLabel(ChatSpeaker.name(role: speaker))
                    .accessibilityValue(String(transcript.characters))
            }
        }
        .padding(ChatMetrics.userChipPadding)
        .background(
            RoundedRectangle(cornerRadius: ChatMetrics.rowRadius, style: .continuous)
                .fill(Palette.chipFill.color)
        )
        .frame(maxWidth: .infinity, alignment: user ? .trailing : .leading)
        .padding(user ? .leading : .trailing, ChatMetrics.userRowLeadingRoom)
        .accessibilityElement(children: .contain)
    }
}
